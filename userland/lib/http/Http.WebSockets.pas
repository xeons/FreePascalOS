{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  A WebSocket connection of a client (RFC 6455) over a connection of
  its own made by a client's connector (TCP, TLS for https; HTTP/1.1
  only, so "h2" is not offered by ALPN), with the client's cookie jar
  and user agent.

  Two threads: the reader connects, sends the handshake
  (Http.WebSocketHandshake), checks the answer and then reads frames
  (Http.WebSocketFrames), answering pings and the server's close; the
  writer sends what the owner queued, in order - messages (compressed
  with permessage-deflate when it was agreed), pongs and the close
  frame - and tells the observer how many bytes of each message went
  out (what a page's bufferedAmount counts down).

  The closing handshake: the side that closes first sends a close
  frame; the other echoes its code; the server then ends the TCP
  connection, which the client waits for (CloseWaitMilliseconds) before
  ending it itself. A failure (a protocol error, invalid UTF-8, a
  message too large) sends a close frame with its code when the
  connection was open and drops the connection at once.

  The observer is called from the threads, never after Abort or the
  destructor: Opened once (or nothing when the handshake fails), each
  message, BytesSent, and Closed exactly once at the end (WasClean
  when both close frames went; else code 1006).

  Plain Pascal over Http.Transports, checked on the host by
  tools/HttpTest against a small server over pipes.
}
unit Http.WebSockets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Http.Client,
  Http.Cookies,
  Http.Transports,
  Http.WebSocketFrames,
  Http.WebSocketDeflate,
  Http.WebSocketHandshake;

const
  CloseWaitMilliseconds = 5000;
  WebSocketConnectTimeoutMilliseconds = 30000;

type
  TWebSocketConnection = class;

  TWebSocketObserver = class
  public
    procedure Opened(Connection: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome); virtual; abstract;
    procedure MessageReceived(Connection: TWebSocketConnection; IsText: Boolean; const Data: TBytes); virtual; abstract;
    { Count bytes of queued message payload went out. }
    procedure BytesSent(Connection: TWebSocketConnection; Count: QWord); virtual; abstract;
    { The server's close frame arrived (Code 1005: it had none); the
      connection still finishes closing. }
    procedure CloseReceived(Connection: TWebSocketConnection; Code: Word; const Reason: string); virtual;
    { The end. Failed: the connection failed (the handshake, a protocol
      error, the network) rather than being closed; ErrorText says why. }
    procedure Closed(Connection: TWebSocketConnection; WasClean: Boolean; Code: Word; const Reason: string;
      Failed: Boolean; const ErrorText: string); virtual; abstract;
  end;

  TWebSocketOptions = record
    { The http or https form of the ws: or wss: URL. }
    Url: TUrlRecord;
    Protocols: array of string;
    { The serialized origin of what opened it. }
    Origin: string;
    OfferDeflate: Boolean;
    SendCookies: Boolean;
    CookieContext: TCookieRequestContext;
    ExtraFields: array of string;
    MaximumMessageBytes: QWord;
  end;

  TOutgoingFrame = class
  public
    Opcode: Byte;
    Payload: TBytes;
    { Message payload bytes to report once it went (0 for control). }
    Reported: QWord;
  end;

  TWebSocketThread = class(TThread)
  private
    FOwner: TWebSocketConnection;
    FWriter: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TWebSocketConnection; Writer: Boolean);
  end;

  TWebSocketConnection = class
  private
    FClient: THttpClient;
    FOptions: TWebSocketOptions;
    FObserver: TWebSocketObserver;
    FLock: TRTLCriticalSection;
    FWake: PRTLEvent;
    FQueue: TList;
    FTransport: THttpTransport;
    FReader, FWriterThread: TWebSocketThread;
    FOutcome: TWebSocketHandshakeOutcome;
    FCompressor: TWebSocketCompressor;
    FDecompressor: TWebSocketDecompressor;
    FOpen: Boolean;
    FAborted: Boolean;
    FStopWriting: Boolean;
    FCloseQueued: Boolean;
    FCloseSent: Boolean;
    FCloseReceived: Boolean;
    FCloseDeadline: QWord;
    FReportedClose: Boolean;
    FReceivedCode: Word;
    FReceivedReason: string;
    FFailed: Boolean;
    FErrorText: string;
    procedure RunReader;
    procedure RunWriter;
    function Connect: Boolean;
    function Handshake(out Leftover: TBytes): Boolean;
    procedure ReadFrames(const Leftover: TBytes);
    function HandleItem(constref Item: TWebSocketItem): Boolean;
    procedure Fail(Code: Word; const Text: string);
    procedure QueueFrame(Opcode: Byte; const Payload: TBytes; Reported: QWord; First: Boolean = False);
    function TakeFrame: TOutgoingFrame;
    function WriteFrame(Frame: TOutgoingFrame): Boolean;
    procedure ReportClosed;
    procedure ShutdownTransport;
  public
    { Starts connecting at once (on its own thread). Client must outlive
      the connection. }
    constructor Create(Client: THttpClient; constref Options: TWebSocketOptions; Observer: TWebSocketObserver);
    { Aborts and waits for the threads. }
    destructor Destroy; override;
    { Any thread: queue a message (text is UTF-8). }
    procedure SendText(const Text: string);
    procedure SendBinary(Data: Pointer; Count: PtrUInt);
    { Starts the closing handshake (Code 0: a close frame without one).
      Before it opened, the connection is dropped instead. }
    procedure Close(Code: Word; const Reason: string);
    { Drops everything; the observer hears nothing more. }
    procedure Abort;
    property Outcome: TWebSocketHandshakeOutcome read FOutcome;
  end;

{ The http(s) URL a ws(s) URL is fetched as (and the other way). }
function WebSocketFetchUrl(constref Url: TUrlRecord): TUrlRecord;
{ Aborts Connection and frees it, then Companion (its observer, say), on
  a thread of its own once the connection's threads are over: whoever
  lets go of a connection never waits for the network. }
procedure DiscardWebSocketConnection(Connection: TWebSocketConnection; Companion: TObject);

implementation

uses
  Http.Connectors,
  Http.Observers,
  Http.Results,
  Http.ResponseHeads,
  Crypto.Random;

function WebSocketFetchUrl(constref Url: TUrlRecord): TUrlRecord;
begin
  Result := Url;
  if Url.Scheme = 'ws' then
    Result.Scheme := 'http'
  else if Url.Scheme = 'wss' then
    Result.Scheme := 'https';
end;

type
  TConnectionReaper = class(TThread)
  private
    FConnection: TWebSocketConnection;
    FCompanion: TObject;
  protected
    procedure Execute; override;
  public
    constructor Create(Connection: TWebSocketConnection; Companion: TObject);
  end;

constructor TConnectionReaper.Create(Connection: TWebSocketConnection; Companion: TObject);
begin
  FConnection := Connection;
  FCompanion := Companion;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TConnectionReaper.Execute;
begin
  FConnection.Free;
  FCompanion.Free;
end;

procedure DiscardWebSocketConnection(Connection: TWebSocketConnection; Companion: TObject);
begin
  if Connection = nil then
  begin
    Companion.Free;
    Exit;
  end;
  Connection.Abort;
  try
    TConnectionReaper.Create(Connection, Companion);
  except
    { No thread to be had: wait here instead. }
    Connection.Free;
    Companion.Free;
  end;
end;

procedure TWebSocketObserver.CloseReceived(Connection: TWebSocketConnection; Code: Word; const Reason: string);
begin
end;

constructor TWebSocketThread.Create(Owner: TWebSocketConnection; Writer: Boolean);
begin
  FOwner := Owner;
  FWriter := Writer;
  inherited Create(False);
end;

procedure TWebSocketThread.Execute;
begin
  if FWriter then
    FOwner.RunWriter
  else
    FOwner.RunReader;
end;

constructor TWebSocketConnection.Create(Client: THttpClient; constref Options: TWebSocketOptions;
  Observer: TWebSocketObserver);
begin
  inherited Create;
  FClient := Client;
  FOptions := Options;
  if FOptions.MaximumMessageBytes = 0 then
    FOptions.MaximumMessageBytes := DefaultWebSocketMessageLimit;
  FObserver := Observer;
  InitCriticalSection(FLock);
  FWake := RTLEventCreate;
  FQueue := TList.Create;
  FReader := TWebSocketThread.Create(Self, False);
end;

destructor TWebSocketConnection.Destroy;
var
  Index: Integer;
begin
  Abort;
  if FReader <> nil then
  begin
    FReader.WaitFor;
    FReader.Free;
  end;
  if FWriterThread <> nil then
  begin
    FWriterThread.WaitFor;
    FWriterThread.Free;
  end;
  for Index := 0 to FQueue.Count - 1 do
    TOutgoingFrame(FQueue[Index]).Free;
  FQueue.Free;
  FTransport.Free;
  FCompressor.Free;
  FDecompressor.Free;
  RTLEventDestroy(FWake);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TWebSocketConnection.ShutdownTransport;
begin
  EnterCriticalSection(FLock);
  try
    if FTransport <> nil then
      FTransport.Shutdown;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TWebSocketConnection.Abort;
begin
  EnterCriticalSection(FLock);
  try
    FAborted := True;
    FStopWriting := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  ShutdownTransport;
  RTLEventSetEvent(FWake);
end;

procedure TWebSocketConnection.QueueFrame(Opcode: Byte; const Payload: TBytes; Reported: QWord; First: Boolean);
var
  Frame: TOutgoingFrame;
begin
  Frame := TOutgoingFrame.Create;
  Frame.Opcode := Opcode;
  Frame.Payload := Payload;
  Frame.Reported := Reported;
  EnterCriticalSection(FLock);
  try
    if First then
      FQueue.Insert(0, Frame)
    else
      FQueue.Add(Frame);
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
end;

procedure TWebSocketConnection.SendText(const Text: string);
var
  Payload: TBytes;
begin
  Payload := nil;
  SetLength(Payload, Length(Text));
  if Text <> '' then
    Move(Text[1], Payload[0], Length(Text));
  EnterCriticalSection(FLock);
  try
    if FCloseQueued or FAborted then
      Exit;
  finally
    LeaveCriticalSection(FLock);
  end;
  QueueFrame(WebSocketOpText, Payload, Length(Payload));
end;

procedure TWebSocketConnection.SendBinary(Data: Pointer; Count: PtrUInt);
var
  Payload: TBytes;
begin
  Payload := nil;
  SetLength(Payload, Count);
  if Count > 0 then
    Move(Data^, Payload[0], Count);
  EnterCriticalSection(FLock);
  try
    if FCloseQueued or FAborted then
      Exit;
  finally
    LeaveCriticalSection(FLock);
  end;
  QueueFrame(WebSocketOpBinary, Payload, Count);
end;

procedure TWebSocketConnection.Close(Code: Word; const Reason: string);
var
  Open: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    if FCloseQueued or FAborted then
      Exit;
    FCloseQueued := True;
    Open := FOpen;
    if not Open then
    begin
      FFailed := False;
      FErrorText := 'closed before it opened';
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Open then
    QueueFrame(WebSocketOpClose, EncodeClosePayload(Code, Reason), 0)
  else
    ShutdownTransport;
end;

{ ---- the reader ---- }

function TWebSocketConnection.Connect: Boolean;
var
  Settings: THttpClientSettings;
  Transport: THttpTransport;
  Connected: THttpResult;
begin
  Settings := FClient.Settings;
  Settings.AllowHttp2 := False;
  if Settings.TimeoutMilliseconds = 0 then
    Settings.TimeoutMilliseconds := WebSocketConnectTimeoutMilliseconds;
  Transport := nil;
  Connected := FClient.Connector.Connect(FOptions.Url, Settings, FClient.CurrentObserver, Transport);
  if not HttpSucceeded(Connected) then
  begin
    Transport.Free;
    FFailed := True;
    FErrorText := Connected.Text;
    Exit(False);
  end;
  EnterCriticalSection(FLock);
  try
    FTransport := Transport;
    Result := not FAborted and not FCloseQueued;
  finally
    LeaveCriticalSection(FLock);
  end;
  if not Result then
    FErrorText := 'closed before it opened';
end;

function TWebSocketConnection.Handshake(out Leftover: TBytes): Boolean;
var
  Offer: TWebSocketHandshakeOffer;
  Text, Reason: string;
  Buffer: array[0..4095] of Byte;
  Received: TBytes;
  Count: Int64;
  Filled, HeadEnd: PtrUInt;
  Head: THttpResponseHead;
  Index: Integer;
begin
  Leftover := nil;
  Result := False;
  Offer := Default(TWebSocketHandshakeOffer);
  Offer.Target := FOptions.Url.Path;
  if Offer.Target = '' then
    Offer.Target := '/';
  if FOptions.Url.HasQuery then
    Offer.Target := Offer.Target + '?' + FOptions.Url.Query;
  Offer.Authority := AuthorityOf(FOptions.Url);
  Offer.Key := NewWebSocketKey;
  Offer.Origin := FOptions.Origin;
  Offer.Protocols := FOptions.Protocols;
  Offer.OfferDeflate := FOptions.OfferDeflate;
  Offer.UserAgent := FClient.Settings.UserAgent;
  Offer.ExtraFields := FOptions.ExtraFields;
  if FOptions.SendCookies and (FClient.Cookies <> nil) then
    Offer.Cookie := FClient.Cookies.CookieFieldFor(FOptions.Url, FOptions.CookieContext, FClient.UnixTimeNow);
  Text := BuildHandshakeRequest(Offer);
  FTransport.TimeoutMilliseconds := WebSocketConnectTimeoutMilliseconds;
  if not FTransport.Write(PChar(Text), Length(Text)) then
  begin
    FFailed := True;
    FErrorText := 'the handshake could not be sent: ' + FTransport.ErrorText;
    Exit;
  end;
  Received := nil;
  Filled := 0;
  HeadEnd := 0;
  repeat
    Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
    begin
      FFailed := True;
      FErrorText := 'the server ended the connection during the handshake';
      Exit;
    end;
    SetLength(Received, Filled + PtrUInt(Count));
    Move(Buffer[0], Received[Filled], Count);
    Inc(Filled, Count);
    HeadEnd := FindHeadEnd(PChar(@Received[0]), Filled);
    if (HeadEnd = 0) and (Filled > MaximumHeadLength) then
    begin
      FFailed := True;
      FErrorText := 'the handshake answer is too long';
      Exit;
    end;
  until HeadEnd > 0;
  SetString(Text, PChar(@Received[0]), HeadEnd);
  if ParseResponseHead(Text, Head) <> HeadParsed then
  begin
    FFailed := True;
    FErrorText := 'a malformed handshake answer';
    Exit;
  end;
  if FOptions.SendCookies and (FClient.Cookies <> nil) then
    for Index := 0 to High(Head.SetCookies) do
      FClient.Cookies.SetCookieFromResponse(FOptions.Url, Head.SetCookies[Index], FOptions.CookieContext,
        FClient.UnixTimeNow);
  if not CheckHandshakeResponse(Offer, Head, FOutcome, Reason) then
  begin
    FFailed := True;
    FErrorText := Reason;
    Exit;
  end;
  if Filled > HeadEnd then
  begin
    SetLength(Leftover, Filled - HeadEnd);
    Move(Received[HeadEnd], Leftover[0], Filled - HeadEnd);
  end;
  Result := True;
end;

procedure TWebSocketConnection.Fail(Code: Word; const Text: string);
var
  Open: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    FFailed := True;
    if FErrorText = '' then
      FErrorText := Text;
    Open := FOpen and not FCloseQueued;
    FCloseQueued := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Open then
  begin
    { The close frame goes ahead of anything still queued; the writer
      ends the connection once it is out. }
    QueueFrame(WebSocketOpClose, EncodeClosePayload(Code, ''), 0, True);
    EnterCriticalSection(FLock);
    try
      FCloseDeadline := GetTickCount64 + 1000;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
end;

function TWebSocketConnection.HandleItem(constref Item: TWebSocketItem): Boolean;
var
  Data: TBytes;
  Echo: Boolean;
  Code: Word;
begin
  Result := True;
  case Item.Kind of
    WebSocketItemPing:
      if not FCloseReceived then
        QueueFrame(WebSocketOpPong, Item.Payload, 0);
    WebSocketItemPong: ;
    WebSocketItemMessage:
      begin
        if FCloseReceived then
          Exit;
        Data := Item.Payload;
        if Item.Compressed then
          if not FDecompressor.Decompress(PByte(Item.Payload), Length(Item.Payload), FOptions.MaximumMessageBytes,
            Data) then
          begin
            Fail(WebSocketCloseInvalidData, 'a compressed message that does not decompress');
            Exit(False);
          end;
        if Item.IsText and not IsValidUtf8(PByte(Data), Length(Data)) then
        begin
          Fail(WebSocketCloseInvalidData, 'a text message that is not UTF-8');
          Exit(False);
        end;
        EnterCriticalSection(FLock);
        try
          if FAborted then
            Exit(False);
        finally
          LeaveCriticalSection(FLock);
        end;
        FObserver.MessageReceived(Self, Item.IsText, Data);
      end;
    WebSocketItemClose:
      begin
        FCloseReceived := True;
        if Item.HasCode then
        begin
          FReceivedCode := Item.Code;
          FReceivedReason := Item.Reason;
        end
        else
          FReceivedCode := WebSocketCloseNoStatus;
        EnterCriticalSection(FLock);
        try
          Echo := not FCloseQueued;
          FCloseQueued := True;
          if FCloseDeadline = 0 then
            FCloseDeadline := GetTickCount64 + CloseWaitMilliseconds;
          if FAborted then
            Exit(False);
        finally
          LeaveCriticalSection(FLock);
        end;
        FObserver.CloseReceived(Self, FReceivedCode, FReceivedReason);
        if Echo then
        begin
          Code := 0;
          if Item.HasCode then
            Code := Item.Code;
          QueueFrame(WebSocketOpClose, EncodeClosePayload(Code, ''), 0);
        end;
      end;
  end;
end;

procedure TWebSocketConnection.ReadFrames(const Leftover: TBytes);
var
  Reader: TWebSocketFrameReader;
  Buffer: array[0..16383] of Byte;
  Count: Int64;
  Item: TWebSocketItem;
  Step: TReaderStep;
begin
  Reader := TWebSocketFrameReader.Create;
  try
    Reader.AllowRsv1 := FOutcome.Deflate;
    Reader.MaximumMessageBytes := FOptions.MaximumMessageBytes;
    Reader.Feed(PByte(Leftover), Length(Leftover));
    repeat
      repeat
        Step := Reader.Next(Item);
        if Step = ReaderFailed then
        begin
          Fail(Reader.FailCode, Reader.FailReason);
          Exit;
        end;
        if (Step = ReaderItem) and not HandleItem(Item) then
          Exit;
      until Step <> ReaderItem;
      Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
      if Count <= 0 then
        Exit;
      { After the server's close frame nothing more is taken. }
      if FCloseReceived then
        Continue;
      Reader.Feed(@Buffer[0], Count);
    until False;
  finally
    Reader.Free;
  end;
end;

procedure TWebSocketConnection.ReportClosed;
var
  Clean: Boolean;
  Code: Word;
  Reason: string;
begin
  EnterCriticalSection(FLock);
  try
    if FReportedClose or FAborted then
      Exit;
    FReportedClose := True;
    Clean := FCloseSent and FCloseReceived and not FFailed;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Clean then
  begin
    Code := FReceivedCode;
    Reason := FReceivedReason;
  end
  else
  begin
    Code := WebSocketCloseAbnormal;
    Reason := '';
  end;
  FObserver.Closed(Self, Clean, Code, Reason, FFailed, FErrorText);
end;

procedure TWebSocketConnection.RunReader;
var
  Leftover: TBytes;
  Opened: Boolean;
begin
  Opened := False;
  try
    if Connect and Handshake(Leftover) then
    begin
      if FOutcome.Deflate then
      begin
        FCompressor := TWebSocketCompressor.Create(FOutcome.DeflateParameters.ClientNoContextTakeover);
        FDecompressor := TWebSocketDecompressor.Create(FOutcome.DeflateParameters.ServerNoContextTakeover);
      end;
      FTransport.TimeoutMilliseconds := 0;
      EnterCriticalSection(FLock);
      try
        Opened := not FAborted and not FCloseQueued;
        FOpen := Opened;
      finally
        LeaveCriticalSection(FLock);
      end;
      if Opened then
      begin
        FWriterThread := TWebSocketThread.Create(Self, True);
        FObserver.Opened(Self, FOutcome);
        ReadFrames(Leftover);
      end;
    end;
  except
    on Error: Exception do
    begin
      FFailed := True;
      FErrorText := Error.Message;
    end;
  end;
  { Reading ended: the server closed the connection, or it failed, or
    it was shut down. The writer ends too. }
  EnterCriticalSection(FLock);
  try
    FStopWriting := True;
  finally
    LeaveCriticalSection(FLock);
  end;
  RTLEventSetEvent(FWake);
  if FWriterThread <> nil then
    FWriterThread.WaitFor;
  if FTransport <> nil then
    FTransport.Close;
  ReportClosed;
end;

{ ---- the writer ---- }

function TWebSocketConnection.TakeFrame: TOutgoingFrame;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    if FQueue.Count > 0 then
    begin
      Result := TOutgoingFrame(FQueue[0]);
      FQueue.Delete(0);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TWebSocketConnection.WriteFrame(Frame: TOutgoingFrame): Boolean;
var
  Payload, Wire: TBytes;
  MaskKey: TWebSocketMaskKey;
  Compressed: Boolean;
begin
  Payload := Frame.Payload;
  Compressed := False;
  if (FCompressor <> nil) and (Frame.Opcode in [WebSocketOpText, WebSocketOpBinary]) then
  begin
    Payload := FCompressor.Compress(PByte(Frame.Payload), Length(Frame.Payload));
    Compressed := True;
  end;
  RandomBytes(@MaskKey[0], SizeOf(MaskKey));
  Wire := EncodeWebSocketFrame(Frame.Opcode, True, Compressed, PByte(Payload), Length(Payload), True, MaskKey);
  Result := FTransport.Write(@Wire[0], Length(Wire));
end;

procedure TWebSocketConnection.RunWriter;
var
  Frame: TOutgoingFrame;
  Stop: Boolean;
  Deadline: QWord;
begin
  repeat
    Frame := TakeFrame;
    if Frame <> nil then
    begin
      try
        EnterCriticalSection(FLock);
        try
          Stop := FAborted or FCloseSent;
        finally
          LeaveCriticalSection(FLock);
        end;
        if not Stop then
        begin
          if not WriteFrame(Frame) then
          begin
            FFailed := True;
            if FErrorText = '' then
              FErrorText := 'the connection broke while sending';
            ShutdownTransport;
            Exit;
          end;
          if Frame.Opcode = WebSocketOpClose then
          begin
            EnterCriticalSection(FLock);
            try
              FCloseSent := True;
              if FCloseDeadline = 0 then
                FCloseDeadline := GetTickCount64 + CloseWaitMilliseconds;
              { A failure or the echo of the server's close: the
                connection ends now (the server may already have). }
              if FFailed then
                FCloseDeadline := GetTickCount64;
            finally
              LeaveCriticalSection(FLock);
            end;
          end
          else if (Frame.Reported > 0) and not FAborted then
            FObserver.BytesSent(Self, Frame.Reported);
        end;
      finally
        Frame.Free;
      end;
      Continue;
    end;
    EnterCriticalSection(FLock);
    try
      Stop := FStopWriting;
      Deadline := FCloseDeadline;
    finally
      LeaveCriticalSection(FLock);
    end;
    if Stop then
      Exit;
    if (Deadline <> 0) and (GetTickCount64 >= Deadline) then
    begin
      { The server did not end the connection after the close frames
        (or did not answer ours): end it. }
      ShutdownTransport;
      Exit;
    end;
    RTLEventWaitFor(FWake, 100);
  until False;
end;

end.
