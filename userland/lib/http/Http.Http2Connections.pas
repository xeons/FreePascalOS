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
  An HTTP/2 connection of a client (RFC 9113), many requests at once:

  - opening: the preface, SETTINGS (no server push, a 1 MiB window per
    stream, RFC 9218 priorities instead of RFC 7540's) and a
    WINDOW_UPDATE raising the connection's window to 16 MiB; the
    server's SETTINGS must come first and are acknowledged;
  - no thread of its own: an exchange that needs something from the
    server reads the connection itself when no other thread is, and
    deals out every frame to its stream (waking the exchange waiting on
    it); when it has what it needed it hands reading over to another
    waiting exchange. A program with one thread just reads;
  - flow control both ways: DATA waits for the stream's and the
    connection's send windows; received data is given back with
    WINDOW_UPDATE as exchanges take it (half a window at a time), so a
    slow reader holds the server back instead of filling memory;
  - SETTINGS, PING (answered), GOAWAY (no new streams; those above its
    last stream id fail as retryable), RST_STREAM (REFUSED_STREAM is
    retryable), WINDOW_UPDATE, header blocks put together across
    CONTINUATION and decoded by HPACK even for streams already gone;
    PUSH_PROMISE is a protocol error (push is off), unknown frames are
    skipped;
  - a response is checked as section 8 says (:status first and once,
    no other pseudo-headers, lower case names, no connection-specific
    fields, content-length matching the data); a malformed one resets
    its stream;
  - a connection error sends GOAWAY and fails every stream.

  Locks: FWriteLock (the transport's writing side, the HPACK encoder and
  stream id order) is taken before FLock (everything else) when both
  are needed; the reading exchange never takes FWriteLock while holding
  FLock.

  Plain Pascal over Http.Transports, checked on the host by
  tools/HttpTest (frames, and exchanges with a small server).
}
unit Http.Http2Connections;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Http.ByteBuffers,
  Http.Connections,
  Http.HeaderFields,
  Http.HpackDecoder,
  Http.HpackEncoder,
  Http.Http2Frames,
  Http.Http2Streams,
  Http.Priorities,
  Http.Results,
  Http.Transports;

const
  LocalStreamWindow = 1024 * 1024;
  LocalConnectionWindow = 16 * 1024 * 1024;
  LocalMaximumConcurrentStreams = 100;

type
  THttp2Connection = class;

  THttp2Condition = function(Stream: THttp2Stream): Boolean of object;

  THttp2Exchange = class(THttpExchange)
  private
    FConnection: THttp2Connection;
    FStream: THttp2Stream;
    FAborted: Boolean;
    FFinished: Boolean;
    function SendData(Buffer: PByte; Count: Integer; EndStream: Boolean): THttpResult;
    function SendBody(constref Head: THttpRequestHead): THttpResult;
    function HeadArrived(Stream: THttp2Stream): Boolean;
    function DataArrived(Stream: THttp2Stream): Boolean;
    function SendWindowOpen(Stream: THttp2Stream): Boolean;
  public
    constructor Create(Connection: THttp2Connection);
    destructor Destroy; override;
    function Send(constref Head: THttpRequestHead): THttpResult; override;
    function ReceiveHead(out Head: THttpResponseHeadInfo): THttpResult; override;
    function ReadBody(Buffer: Pointer; Count: PtrUInt): Int64; override;
    function BodyComplete: Boolean; override;
    function Trailers: THttpHeaderFieldArray; override;
    procedure Finish; override;
    procedure Abort; override;
    procedure Reprioritize(constref Priority: THttpPriority); override;
  end;

  THttp2Connection = class(THttpConnection)
  private
    FTransport: THttpTransport;
    FLock: TRTLCriticalSection;
    FWriteLock: TRTLCriticalSection;
    FStreams: array of THttp2Stream;
    FReserved: Integer;
    FNextStreamId: LongWord;
    FReading: Boolean;
    FReadBuffer: THttpByteBuffer;
    FEncoder: THpackEncoder;
    FDecoder: THpackDecoder;
    FPendingPeerTableSize: Integer;
    FPeerTableSizeChanged: Boolean;
    FPeerMaximumConcurrentStreams: LongWord;
    FPeerInitialWindow: Int64;
    FPeerMaximumFrameSize: LongWord;
    FSendWindow: Int64;
    FReceiveWindow: Int64;
    FUnacknowledged: Int64;
    FSettingsReceived: Boolean;
    FGoingAway: Boolean;
    FGoAwayLastStreamId: LongWord;
    FFailed: Boolean;
    FFailure: THttpResult;
    FClosed: Boolean;
    FHeaderStream: LongWord;
    FHeaderBlock: THttpByteBuffer;
    FHeaderEndStream: Boolean;
    { Control frames the reader answers with, sent after dispatching. }
    FOutgoing: THttpByteBuffer;
    function FindStream(Id: LongWord): THttp2Stream;
    function ActiveStreamCount: Integer;
    procedure RemoveStream(Stream: THttp2Stream);
    procedure WakeAll;
    procedure WakeOneWaiter(Except_: THttp2Stream);
    procedure FailConnection(constref Reason: THttpResult);
    procedure ConnectionError(ErrorCode: LongWord; const Text: string);
    procedure StreamError(Stream: THttp2Stream; ErrorCode: LongWord; const Text: string);
    function WriteFrames(var Frames: THttpByteBuffer): Boolean;
    procedure FlushOutgoing;
    function ReadAndDispatch: Boolean;
    function DispatchFrames: Integer;
    procedure DispatchFrame(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleData(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleHeaders(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleContinuation(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleHeaderBlock(StreamId: LongWord; EndStream: Boolean);
    procedure ApplyResponseFields(Stream: THttp2Stream; constref Fields: THpackHeaderList; EndStream: Boolean);
    procedure HandleResetStream(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleSettings(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandlePing(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleGoAway(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure HandleWindowUpdate(constref Header: THttp2FrameHeader; Payload: PByte);
    procedure GiveBackWindow(Stream: THttp2Stream; Count: Integer);
    function WaitFor(Stream: THttp2Stream; Condition: THttp2Condition; out Failure: THttpResult): Boolean;
    function OpenStream(Exchange: THttp2Exchange; constref Head: THttpRequestHead; EndStream: Boolean): THttpResult;
    procedure ReleaseExchange(Exchange: THttp2Exchange);
  public
    { Takes over the transport (TLS with "h2" chosen by ALPN). }
    constructor Create(Transport: THttpTransport; const Origin: string);
    destructor Destroy; override;
    { Sends the preface, SETTINGS and the connection's WINDOW_UPDATE. }
    function Open: THttpResult;
    function StartExchange: THttpExchange; override;
    function IsUsable: Boolean; override;
    function IsIdle: Boolean; override;
    function IsMultiplexed: Boolean; override;
    procedure Close; override;
    property Transport: THttpTransport read FTransport;
    property PeerMaximumConcurrentStreams: LongWord read FPeerMaximumConcurrentStreams;
  end;

implementation

uses
  SysUtils,
  Http.StatusCodes;

const
  { What a server may send before its SETTINGS raise it. }
  InitialPeerConcurrentStreams = 100;

function Elapsed(Since: QWord): QWord;
begin
  Result := GetTickCount64 - Since;
end;

function IsConnectionSpecific(const Name: string): Boolean;
begin
  Result := (Name = 'connection') or (Name = 'keep-alive') or (Name = 'proxy-connection') or
    (Name = 'transfer-encoding') or (Name = 'upgrade') or (Name = 'host');
end;

function HasUpperCase(const Name: string): Boolean;
var
  Character: Char;
begin
  for Character in Name do
    if Character in ['A'..'Z'] then
      Exit(True);
  Result := False;
end;

{ THttp2Connection: streams and waiting }

constructor THttp2Connection.Create(Transport: THttpTransport; const Origin: string);
begin
  inherited Create;
  FTransport := Transport;
  FProtocol := HttpProtocol2;
  FOriginKey := Origin;
  InitCriticalSection(FLock);
  InitCriticalSection(FWriteLock);
  FNextStreamId := 1;
  FEncoder := THpackEncoder.Create;
  FDecoder := THpackDecoder.Create;
  FPeerMaximumConcurrentStreams := InitialPeerConcurrentStreams;
  FPeerInitialWindow := DefaultInitialWindowSize;
  FPeerMaximumFrameSize := DefaultMaximumFrameSize;
  FSendWindow := DefaultInitialWindowSize;
  FReceiveWindow := LocalConnectionWindow;
end;

destructor THttp2Connection.Destroy;
var
  Stream: THttp2Stream;
begin
  Close;
  for Stream in FStreams do
    Stream.Free;
  FEncoder.Free;
  FDecoder.Free;
  FTransport.Free;
  DoneCriticalSection(FWriteLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function THttp2Connection.FindStream(Id: LongWord): THttp2Stream;
var
  Stream: THttp2Stream;
begin
  for Stream in FStreams do
    if Stream.Id = Id then
      Exit(Stream);
  Result := nil;
end;

function THttp2Connection.ActiveStreamCount: Integer;
begin
  Result := Length(FStreams) + FReserved;
end;

procedure THttp2Connection.RemoveStream(Stream: THttp2Stream);
var
  Index: Integer;
begin
  for Index := 0 to High(FStreams) do
    if FStreams[Index] = Stream then
    begin
      Delete(FStreams, Index, 1);
      Exit;
    end;
end;

procedure THttp2Connection.WakeAll;
var
  Stream: THttp2Stream;
begin
  for Stream in FStreams do
    Stream.Wake;
end;

procedure THttp2Connection.WakeOneWaiter(Except_: THttp2Stream);
var
  Stream: THttp2Stream;
begin
  for Stream in FStreams do
    if Stream.Waiting and (Stream <> Except_) then
    begin
      Stream.Wake;
      Exit;
    end;
end;

procedure THttp2Connection.FailConnection(constref Reason: THttpResult);
var
  Stream: THttp2Stream;
begin
  if not FFailed then
  begin
    FFailed := True;
    FFailure := Reason;
  end;
  { A stream already answered in full keeps its response. }
  for Stream in FStreams do
    if not Stream.RemoteEnded then
      Stream.Fail(Reason);
  WakeAll;
end;

procedure THttp2Connection.ConnectionError(ErrorCode: LongWord; const Text: string);
begin
  if FFailed then
    Exit;
  AppendGoAway(FOutgoing, 0, ErrorCode, Text);
  FailConnection(HttpFailure(HttpProtocolError, 'HTTP/2 ' + Http2ErrorName(ErrorCode) + ': ' + Text));
end;

procedure THttp2Connection.StreamError(Stream: THttp2Stream; ErrorCode: LongWord; const Text: string);
begin
  AppendResetStream(FOutgoing, Stream.Id, ErrorCode);
  Stream.Fail(HttpFailure(HttpMalformedResponse, 'HTTP/2 ' + Http2ErrorName(ErrorCode) + ': ' + Text));
  Stream.RemoteEnded := True;
  Stream.Wake;
end;

function THttp2Connection.WriteFrames(var Frames: THttpByteBuffer): Boolean;
var
  Failure: THttpResult;
begin
  Result := True;
  if Frames.Length = 0 then
    Exit;
  EnterCriticalSection(FWriteLock);
  try
    if not FClosed then
      Result := FTransport.Write(@Frames.Data[0], Frames.Length)
    else
      Result := False;
  finally
    LeaveCriticalSection(FWriteLock);
  end;
  ClearBuffer(Frames);
  if not Result then
  begin
    if FTransport.Failure = TransportFailureTimeout then
      Failure := HttpFailure(HttpTimedOut, FTransport.ErrorText, FTransport.ErrorCode)
    else
      Failure := HttpFailure(HttpSendFailed, FTransport.ErrorText, FTransport.ErrorCode);
    EnterCriticalSection(FLock);
    FailConnection(Failure);
    LeaveCriticalSection(FLock);
  end;
end;

{ Sends what dispatching queued (called without FLock). }
procedure THttp2Connection.FlushOutgoing;
var
  Frames: THttpByteBuffer;
begin
  EnterCriticalSection(FLock);
  Frames := Default(THttpByteBuffer);
  if FOutgoing.Length > 0 then
  begin
    AppendBytes(Frames, @FOutgoing.Data[0], FOutgoing.Length);
    ClearBuffer(FOutgoing);
  end;
  LeaveCriticalSection(FLock);
  if Frames.Length > 0 then
    WriteFrames(Frames);
end;

function THttp2Connection.WaitFor(Stream: THttp2Stream; Condition: THttp2Condition; out Failure: THttpResult): Boolean;
var
  Started: QWord;
  Timeout: Int64;
  Remaining: Int64;
begin
  Failure := HttpOk;
  Started := GetTickCount64;
  Timeout := FTransport.TimeoutMilliseconds;
  while True do
  begin
    EnterCriticalSection(FLock);
    if Condition(Stream) then
    begin
      LeaveCriticalSection(FLock);
      Exit(True);
    end;
    if Stream.Failed or FFailed then
    begin
      if Stream.Failed then
        Failure := Stream.Failure
      else
        Failure := FFailure;
      LeaveCriticalSection(FLock);
      Exit(False);
    end;
    if not FReading then
    begin
      FReading := True;
      LeaveCriticalSection(FLock);
      ReadAndDispatch;
      FlushOutgoing;
      EnterCriticalSection(FLock);
      FReading := False;
      WakeOneWaiter(Stream);
      LeaveCriticalSection(FLock);
      Continue;
    end;
    Stream.Waiting := True;
    RTLEventResetEvent(Stream.Event);
    LeaveCriticalSection(FLock);
    if Timeout > 0 then
    begin
      Remaining := Timeout - Int64(Elapsed(Started));
      if Remaining <= 0 then
        Remaining := 1;
      RTLEventWaitFor(Stream.Event, Remaining);
    end
    else
      RTLEventWaitFor(Stream.Event);
    EnterCriticalSection(FLock);
    Stream.Waiting := False;
    LeaveCriticalSection(FLock);
    if (Timeout > 0) and (Int64(Elapsed(Started)) >= Timeout) and not FReading then
    begin
      { Nobody is reading and the time is up. }
      EnterCriticalSection(FLock);
      if Condition(Stream) then
      begin
        LeaveCriticalSection(FLock);
        Exit(True);
      end;
      LeaveCriticalSection(FLock);
      Failure := HttpFailure(HttpTimedOut, 'Connection timed out');
      Exit(False);
    end;
  end;
end;

{ THttp2Connection: reading and dispatching }

function THttp2Connection.ReadAndDispatch: Boolean;
var
  Received: Int64;
  Failure: THttpResult;
begin
  Result := True;
  EnterCriticalSection(FLock);
  try
    if DispatchFrames > 0 then
      Exit;
    if FFailed then
      Exit(False);
  finally
    LeaveCriticalSection(FLock);
  end;
  ReserveBuffer(FReadBuffer, DefaultMaximumFrameSize + FrameHeaderSize);
  Received := FTransport.Read(@FReadBuffer.Data[FReadBuffer.Length], System.Length(FReadBuffer.Data) -
    FReadBuffer.Length);
  EnterCriticalSection(FLock);
  try
    if Received <= 0 then
    begin
      if Received = 0 then
        Failure := HttpFailure(HttpReadFailed, 'the server closed the connection')
      else if FTransport.Failure = TransportFailureTimeout then
        Failure := HttpFailure(HttpTimedOut, FTransport.ErrorText, FTransport.ErrorCode)
      else
        Failure := HttpFailure(HttpReadFailed, FTransport.ErrorText, FTransport.ErrorCode);
      { Streams the server never answered can go again elsewhere. }
      Failure.Retryable := Received = 0;
      FailConnection(Failure);
      Exit(False);
    end;
    Inc(FReadBuffer.Length, Received);
    DispatchFrames;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ Every whole frame in the read buffer; returns how many (under FLock). }
function THttp2Connection.DispatchFrames: Integer;
var
  Header: THttp2FrameHeader;
  Offset: Integer;
begin
  Result := 0;
  Offset := 0;
  while not FFailed and (FReadBuffer.Length - Offset >= FrameHeaderSize) do
  begin
    Header := ReadFrameHeader(@FReadBuffer.Data[Offset]);
    if Header.Length > DefaultMaximumFrameSize then
    begin
      ConnectionError(ErrorFrameSize, 'a frame larger than allowed');
      Break;
    end;
    if FReadBuffer.Length - Offset < Integer(FrameHeaderSize + Header.Length) then
      Break;
    DispatchFrame(Header, @FReadBuffer.Data[Offset + FrameHeaderSize]);
    Inc(Offset, FrameHeaderSize + Header.Length);
    Inc(Result);
  end;
  if Offset > 0 then
    ConsumeBuffer(FReadBuffer, Offset);
end;

procedure THttp2Connection.DispatchFrame(constref Header: THttp2FrameHeader; Payload: PByte);
begin
  if not FSettingsReceived and ((Header.FrameType <> FrameSettings) or ((Header.Flags and FlagAck) <> 0)) then
  begin
    ConnectionError(ErrorProtocol, 'the server did not start with SETTINGS');
    Exit;
  end;
  if (FHeaderStream <> 0) and (Header.FrameType <> FrameContinuation) then
  begin
    ConnectionError(ErrorProtocol, 'a header block interrupted');
    Exit;
  end;
  case Header.FrameType of
    FrameData: HandleData(Header, Payload);
    FrameHeaders: HandleHeaders(Header, Payload);
    FramePriority:
      if Header.StreamId = 0 then
        ConnectionError(ErrorProtocol, 'PRIORITY on stream 0');
    FrameResetStream: HandleResetStream(Header, Payload);
    FrameSettings: HandleSettings(Header, Payload);
    FramePushPromise: ConnectionError(ErrorProtocol, 'PUSH_PROMISE with push disabled');
    FramePing: HandlePing(Header, Payload);
    FrameGoAway: HandleGoAway(Header, Payload);
    FrameWindowUpdate: HandleWindowUpdate(Header, Payload);
    FrameContinuation: HandleContinuation(Header, Payload);
  end;
end;

procedure THttp2Connection.HandleData(constref Header: THttp2FrameHeader; Payload: PByte);
var
  Stream: THttp2Stream;
  Start, Count: LongWord;
begin
  if Header.StreamId = 0 then
  begin
    ConnectionError(ErrorProtocol, 'DATA on stream 0');
    Exit;
  end;
  if Header.Length > FReceiveWindow then
  begin
    ConnectionError(ErrorFlowControl, 'more data than the connection window');
    Exit;
  end;
  Dec(FReceiveWindow, Header.Length);
  if not FramePayloadContent(Header, Payload, Start, Count) then
  begin
    ConnectionError(ErrorProtocol, 'bad padding');
    Exit;
  end;
  Stream := FindStream(Header.StreamId);
  if (Stream = nil) or Stream.Abandoned or Stream.Failed then
  begin
    { Data for a stream given up: only the connection window counts. }
    if Header.StreamId >= FNextStreamId then
      ConnectionError(ErrorProtocol, 'DATA on a stream never opened')
    else
    begin
      Inc(FUnacknowledged, Header.Length);
      GiveBackWindow(nil, 0);
    end;
    Exit;
  end;
  if not Stream.HeadReceived or Stream.RemoteEnded then
  begin
    StreamError(Stream, ErrorProtocol, 'DATA before the head or after the end');
    Exit;
  end;
  if Header.Length > Stream.ReceiveWindow then
  begin
    StreamError(Stream, ErrorFlowControl, 'more data than the stream window');
    Exit;
  end;
  Dec(Stream.ReceiveWindow, Header.Length);
  { Padding is given back at once. }
  Inc(Stream.Unacknowledged, Header.Length - Count);
  Inc(FUnacknowledged, Header.Length - Count);
  AppendBytes(Stream.Data, Payload + Start, Count);
  Inc(Stream.ReceivedLength, Count);
  if (Stream.ExpectedLength >= 0) and (Stream.ReceivedLength > Stream.ExpectedLength) then
  begin
    StreamError(Stream, ErrorProtocol, 'more data than content-length');
    Exit;
  end;
  if (Header.Flags and FlagEndStream) <> 0 then
  begin
    Stream.RemoteEnded := True;
    if (Stream.ExpectedLength >= 0) and (Stream.ReceivedLength <> Stream.ExpectedLength) and not Stream.IsHead then
    begin
      StreamError(Stream, ErrorProtocol, 'less data than content-length');
      Exit;
    end;
  end;
  Stream.Wake;
end;

procedure THttp2Connection.HandleHeaders(constref Header: THttp2FrameHeader; Payload: PByte);
var
  Start, Count: LongWord;
begin
  if (Header.StreamId = 0) or not Odd(Header.StreamId) or (Header.StreamId >= FNextStreamId) then
  begin
    ConnectionError(ErrorProtocol, 'HEADERS on a stream the client did not open');
    Exit;
  end;
  if not FramePayloadContent(Header, Payload, Start, Count) then
  begin
    ConnectionError(ErrorProtocol, 'bad padding');
    Exit;
  end;
  ClearBuffer(FHeaderBlock);
  AppendBytes(FHeaderBlock, Payload + Start, Count);
  FHeaderEndStream := (Header.Flags and FlagEndStream) <> 0;
  if (Header.Flags and FlagEndHeaders) <> 0 then
    HandleHeaderBlock(Header.StreamId, FHeaderEndStream)
  else
    FHeaderStream := Header.StreamId;
end;

procedure THttp2Connection.HandleContinuation(constref Header: THttp2FrameHeader; Payload: PByte);
var
  StreamId: LongWord;
begin
  if (FHeaderStream = 0) or (Header.StreamId <> FHeaderStream) then
  begin
    ConnectionError(ErrorProtocol, 'CONTINUATION without HEADERS');
    Exit;
  end;
  AppendBytes(FHeaderBlock, Payload, Header.Length);
  if FHeaderBlock.Length > 1024 * 1024 then
  begin
    ConnectionError(ErrorEnhanceYourCalm, 'a header block too large');
    Exit;
  end;
  if (Header.Flags and FlagEndHeaders) <> 0 then
  begin
    StreamId := FHeaderStream;
    FHeaderStream := 0;
    HandleHeaderBlock(StreamId, FHeaderEndStream);
  end;
end;

procedure THttp2Connection.HandleHeaderBlock(StreamId: LongWord; EndStream: Boolean);
var
  Fields: THpackHeaderList;
  Stream: THttp2Stream;
begin
  Fields := nil;
  if (FHeaderBlock.Length > 0) and not FDecoder.Decode(@FHeaderBlock.Data[0], FHeaderBlock.Length, Fields) then
  begin
    ConnectionError(ErrorCompression, FDecoder.ErrorText);
    Exit;
  end;
  Stream := FindStream(StreamId);
  if (Stream = nil) or Stream.Abandoned or Stream.Failed then
    Exit;
  if FDecoder.ListTooLarge then
  begin
    StreamError(Stream, ErrorRefusedStream, 'the response head is too large');
    Stream.Failure := HttpFailure(HttpHeadTooLarge, 'the response head is too large');
    Exit;
  end;
  if Stream.RemoteEnded then
  begin
    StreamError(Stream, ErrorStreamClosed, 'HEADERS after the end of the stream');
    Exit;
  end;
  ApplyResponseFields(Stream, Fields, EndStream);
end;

procedure THttp2Connection.ApplyResponseFields(Stream: THttp2Stream; constref Fields: THpackHeaderList;
  EndStream: Boolean);
var
  Field: THpackHeaderField;
  Status: Integer;
  StatusSeen, RegularSeen: Boolean;
  Regular: THttpHeaderFieldArray;
  Raw: string;
  Length_: Int64;
begin
  Regular := nil;
  Status := 0;
  StatusSeen := False;
  RegularSeen := False;
  Raw := '';
  for Field in Fields do
  begin
    if (Field.Name <> '') and (Field.Name[1] = ':') then
    begin
      if Stream.HeadReceived or RegularSeen or StatusSeen or (Field.Name <> ':status') or
         (Length(Field.Value) <> 3) or not TryStrToInt(Field.Value, Status) or (Status < 100) then
      begin
        StreamError(Stream, ErrorProtocol, 'bad pseudo-header ' + Field.Name);
        Exit;
      end;
      StatusSeen := True;
      Continue;
    end;
    if (Field.Name = '') or HasUpperCase(Field.Name) or IsConnectionSpecific(Field.Name) or
       ((Field.Name = 'te') and (Field.Value <> 'trailers')) then
    begin
      StreamError(Stream, ErrorProtocol, 'bad field ' + Field.Name);
      Exit;
    end;
    RegularSeen := True;
    SetLength(Regular, System.Length(Regular) + 1);
    Regular[High(Regular)].Name := InternFieldName(Field.Name);
    Regular[High(Regular)].Value := Field.Value;
    Raw := Raw + Field.Name + ': ' + Field.Value + #13#10;
  end;
  if Stream.HeadReceived then
  begin
    { Trailers: they end the stream. }
    if not EndStream then
    begin
      StreamError(Stream, ErrorProtocol, 'trailers without END_STREAM');
      Exit;
    end;
    Stream.Trailers := Regular;
    Stream.RemoteEnded := True;
    Stream.Wake;
    Exit;
  end;
  if not StatusSeen then
  begin
    StreamError(Stream, ErrorProtocol, 'no :status');
    Exit;
  end;
  if StatusIsInformational(Status) then
  begin
    if EndStream then
      StreamError(Stream, ErrorProtocol, 'an interim response ending the stream');
    Exit;
  end;
  Stream.HeadReceived := True;
  Stream.Head.Status := Status;
  Stream.Head.Reason := '';
  Stream.Head.Version := 20;
  Stream.Head.Fields := Regular;
  Stream.Head.RawHead := 'HTTP/2 ' + IntToStr(Status) + #13#10 + Raw + #13#10;
  Stream.Head.ContentLength := -1;
  if FieldsHave(Regular, 'content-length') and TryStrToInt64(FieldsValue(Regular, 'content-length'), Length_) and
     (Length_ >= 0) then
  begin
    Stream.ExpectedLength := Length_;
    Stream.Head.ContentLength := Length_;
  end;
  if Stream.IsHead or StatusHasNoBody(Status) then
  begin
    Stream.ExpectedLength := -1;
    Stream.Head.ContentLength := 0;
  end;
  if EndStream then
  begin
    Stream.RemoteEnded := True;
    if (Stream.ExpectedLength > 0) then
    begin
      StreamError(Stream, ErrorProtocol, 'less data than content-length');
      Exit;
    end;
  end;
  Stream.Wake;
end;

procedure THttp2Connection.HandleResetStream(constref Header: THttp2FrameHeader; Payload: PByte);
var
  ErrorCode: LongWord;
  Stream: THttp2Stream;
  Failure: THttpResult;
begin
  if Header.StreamId = 0 then
  begin
    ConnectionError(ErrorProtocol, 'RST_STREAM on stream 0');
    Exit;
  end;
  if not ParseResetStream(Payload, Header.Length, ErrorCode) then
  begin
    ConnectionError(ErrorFrameSize, 'RST_STREAM of the wrong size');
    Exit;
  end;
  Stream := FindStream(Header.StreamId);
  if Stream = nil then
    Exit;
  Failure := HttpFailure(HttpStreamReset, 'the server reset the request (' + Http2ErrorName(ErrorCode) + ')',
    ErrorCode);
  Failure.Retryable := ErrorCode = ErrorRefusedStream;
  Stream.Fail(Failure);
  Stream.RemoteEnded := True;
  Stream.Wake;
end;

procedure THttp2Connection.HandleSettings(constref Header: THttp2FrameHeader; Payload: PByte);
var
  Settings: THttp2SettingArray;
  Setting: THttp2Setting;
  Delta: Int64;
  Stream: THttp2Stream;
begin
  if Header.StreamId <> 0 then
  begin
    ConnectionError(ErrorProtocol, 'SETTINGS on a stream');
    Exit;
  end;
  if (Header.Flags and FlagAck) <> 0 then
  begin
    if Header.Length <> 0 then
      ConnectionError(ErrorFrameSize, 'a SETTINGS acknowledgement with content');
    Exit;
  end;
  if not ParseSettings(Payload, Header.Length, Settings) then
  begin
    ConnectionError(ErrorFrameSize, 'SETTINGS of the wrong size');
    Exit;
  end;
  for Setting in Settings do
    case Setting.Identifier of
      SettingHeaderTableSize:
        begin
          FPendingPeerTableSize := Setting.Value;
          FPeerTableSizeChanged := True;
        end;
      SettingEnablePush:
        if Setting.Value > 1 then
        begin
          ConnectionError(ErrorProtocol, 'SETTINGS_ENABLE_PUSH above 1');
          Exit;
        end;
      SettingMaximumConcurrentStreams:
        FPeerMaximumConcurrentStreams := Setting.Value;
      SettingInitialWindowSize:
        begin
          if Setting.Value > LargestWindowSize then
          begin
            ConnectionError(ErrorFlowControl, 'SETTINGS_INITIAL_WINDOW_SIZE too large');
            Exit;
          end;
          Delta := Int64(Setting.Value) - FPeerInitialWindow;
          FPeerInitialWindow := Setting.Value;
          for Stream in FStreams do
            Inc(Stream.SendWindow, Delta);
        end;
      SettingMaximumFrameSize:
        begin
          if (Setting.Value < DefaultMaximumFrameSize) or (Setting.Value > LargestMaximumFrameSize) then
          begin
            ConnectionError(ErrorProtocol, 'SETTINGS_MAX_FRAME_SIZE out of range');
            Exit;
          end;
          FPeerMaximumFrameSize := Setting.Value;
        end;
    end;
  FSettingsReceived := True;
  AppendSettingsAck(FOutgoing);
  WakeAll;
end;

procedure THttp2Connection.HandlePing(constref Header: THttp2FrameHeader; Payload: PByte);
begin
  if Header.StreamId <> 0 then
  begin
    ConnectionError(ErrorProtocol, 'PING on a stream');
    Exit;
  end;
  if Header.Length <> 8 then
  begin
    ConnectionError(ErrorFrameSize, 'PING of the wrong size');
    Exit;
  end;
  if (Header.Flags and FlagAck) = 0 then
    AppendPing(FOutgoing, True, Payload);
end;

procedure THttp2Connection.HandleGoAway(constref Header: THttp2FrameHeader; Payload: PByte);
var
  LastStreamId, ErrorCode: LongWord;
  Debug: string;
  Stream: THttp2Stream;
  Failure: THttpResult;
begin
  if (Header.StreamId <> 0) or not ParseGoAway(Payload, Header.Length, LastStreamId, ErrorCode, Debug) then
  begin
    ConnectionError(ErrorProtocol, 'a bad GOAWAY');
    Exit;
  end;
  FGoingAway := True;
  FGoAwayLastStreamId := LastStreamId;
  Failure := HttpFailure(HttpStreamReset, 'the server is closing the connection (' + Http2ErrorName(ErrorCode) + ')',
    ErrorCode);
  Failure.Retryable := True;
  for Stream in FStreams do
    if Stream.Id > LastStreamId then
    begin
      Stream.Fail(Failure);
      Stream.Wake;
    end;
end;

procedure THttp2Connection.HandleWindowUpdate(constref Header: THttp2FrameHeader; Payload: PByte);
var
  Increment: LongWord;
  Stream: THttp2Stream;
begin
  if not ParseWindowUpdate(Payload, Header.Length, Increment) then
  begin
    ConnectionError(ErrorFrameSize, 'WINDOW_UPDATE of the wrong size');
    Exit;
  end;
  if Header.StreamId = 0 then
  begin
    if Increment = 0 then
    begin
      ConnectionError(ErrorProtocol, 'a zero WINDOW_UPDATE');
      Exit;
    end;
    Inc(FSendWindow, Increment);
    if FSendWindow > LargestWindowSize then
      ConnectionError(ErrorFlowControl, 'the connection window above 2^31-1');
    WakeAll;
    Exit;
  end;
  Stream := FindStream(Header.StreamId);
  if (Stream = nil) or Stream.Failed then
    Exit;
  if Increment = 0 then
  begin
    StreamError(Stream, ErrorProtocol, 'a zero WINDOW_UPDATE');
    Exit;
  end;
  Inc(Stream.SendWindow, Increment);
  if Stream.SendWindow > LargestWindowSize then
  begin
    StreamError(Stream, ErrorFlowControl, 'the stream window above 2^31-1');
    Exit;
  end;
  Stream.Wake;
end;

{ Queues WINDOW_UPDATEs once half a window was taken (under FLock). }
procedure THttp2Connection.GiveBackWindow(Stream: THttp2Stream; Count: Integer);
begin
  if Stream <> nil then
  begin
    Inc(Stream.Unacknowledged, Count);
    Inc(FUnacknowledged, Count);
    if (Stream.Unacknowledged >= LocalStreamWindow div 2) and not Stream.RemoteEnded then
    begin
      AppendWindowUpdate(FOutgoing, Stream.Id, Stream.Unacknowledged);
      Inc(Stream.ReceiveWindow, Stream.Unacknowledged);
      Stream.Unacknowledged := 0;
    end;
  end;
  if FUnacknowledged >= LocalConnectionWindow div 2 then
  begin
    AppendWindowUpdate(FOutgoing, 0, FUnacknowledged);
    Inc(FReceiveWindow, FUnacknowledged);
    FUnacknowledged := 0;
  end;
end;

{ THttp2Connection: opening and streams }

function THttp2Connection.Open: THttpResult;
var
  Frames: THttpByteBuffer;
  Settings: array[0..3] of THttp2Setting;
begin
  Frames := Default(THttpByteBuffer);
  AppendText(Frames, Http2Preface);
  Settings[0].Identifier := SettingEnablePush;
  Settings[0].Value := 0;
  Settings[1].Identifier := SettingMaximumConcurrentStreams;
  Settings[1].Value := LocalMaximumConcurrentStreams;
  Settings[2].Identifier := SettingInitialWindowSize;
  Settings[2].Value := LocalStreamWindow;
  Settings[3].Identifier := SettingNoRfc7540Priorities;
  Settings[3].Value := 1;
  AppendSettingsFrame(Frames, Settings);
  AppendWindowUpdate(Frames, 0, LocalConnectionWindow - DefaultInitialWindowSize);
  if not WriteFrames(Frames) then
    Exit(FFailure);
  Result := HttpOk;
end;

function THttp2Connection.StartExchange: THttpExchange;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    if not IsUsable or (ActiveStreamCount >= Integer(FPeerMaximumConcurrentStreams)) or
       (FNextStreamId > $7FFFFFF0) then
      Exit;
    Inc(FReserved);
    Inc(FExchangesStarted);
    Result := THttp2Exchange.Create(Self);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THttp2Connection.IsUsable: Boolean;
begin
  Result := not FFailed and not FGoingAway and not FClosed;
end;

function THttp2Connection.IsIdle: Boolean;
begin
  EnterCriticalSection(FLock);
  Result := ActiveStreamCount = 0;
  LeaveCriticalSection(FLock);
end;

function THttp2Connection.IsMultiplexed: Boolean;
begin
  Result := True;
end;

procedure THttp2Connection.Close;
var
  Frames: THttpByteBuffer;
begin
  if FClosed then
    Exit;
  if not FFailed then
  begin
    Frames := Default(THttpByteBuffer);
    AppendGoAway(Frames, 0, ErrorNoError, '');
    WriteFrames(Frames);
  end
  else
    FlushOutgoing;
  EnterCriticalSection(FWriteLock);
  FClosed := True;
  FTransport.Close;
  LeaveCriticalSection(FWriteLock);
  EnterCriticalSection(FLock);
  FailConnection(HttpFailure(HttpCanceled, 'the connection was closed'));
  LeaveCriticalSection(FLock);
end;

function THttp2Connection.OpenStream(Exchange: THttp2Exchange; constref Head: THttpRequestHead;
  EndStream: Boolean): THttpResult;
var
  Fields: THpackHeaderList;
  Block, Frames: THttpByteBuffer;
  Field: THttpHeaderField;
  Stream: THttp2Stream;
  PriorityText: string;

  procedure AddField(const Name, Value: string);
  begin
    SetLength(Fields, System.Length(Fields) + 1);
    Fields[High(Fields)].Name := Name;
    Fields[High(Fields)].Value := Value;
  end;

begin
  Fields := nil;
  AddField(':method', Head.Method);
  AddField(':scheme', Head.Scheme);
  AddField(':authority', Head.Authority);
  AddField(':path', Head.Target);
  for Field in Head.Fields do
    if not IsConnectionSpecific(Field.Name) and ((Field.Name <> 'te') or (Field.Value = 'trailers')) then
      AddField(Field.Name, Field.Value);
  PriorityText := FormatPriorityField(Head.Priority);
  if (PriorityText <> '') and not FieldsHave(Head.Fields, 'priority') then
    AddField('priority', PriorityText);
  if Head.Body <> nil then
  begin
    if (Head.Body.ContentType <> '') and not FieldsHave(Head.Fields, 'content-type') then
      AddField('content-type', Head.Body.ContentType);
    if Head.Body.Length >= 0 then
      AddField('content-length', IntToStr(Head.Body.Length));
  end;
  Block := Default(THttpByteBuffer);
  Frames := Default(THttpByteBuffer);
  EnterCriticalSection(FWriteLock);
  try
    EnterCriticalSection(FLock);
    try
      Dec(FReserved);
      if not IsUsable then
        Exit(HttpFailure(HttpStreamReset, 'the connection cannot take more requests'));
      Stream := THttp2Stream.Create(FNextStreamId);
      Inc(FNextStreamId, 2);
      Stream.IsHead := Head.Method = 'HEAD';
      Stream.ReceiveWindow := LocalStreamWindow;
      Stream.SendWindow := FPeerInitialWindow;
      Stream.LocalEnded := EndStream;
      SetLength(FStreams, System.Length(FStreams) + 1);
      FStreams[High(FStreams)] := Stream;
      Exchange.FStream := Stream;
      if FPeerTableSizeChanged then
      begin
        FEncoder.SetPeerTableSize(FPendingPeerTableSize);
        FPeerTableSizeChanged := False;
      end;
    finally
      LeaveCriticalSection(FLock);
    end;
    FEncoder.Encode(Fields, Block);
    AppendHeaderBlock(Frames, Stream.Id, @Block.Data[0], Block.Length, EndStream, FPeerMaximumFrameSize);
    if FClosed or not FTransport.Write(@Frames.Data[0], Frames.Length) then
      Result := HttpFailure(HttpSendFailed, FTransport.ErrorText, FTransport.ErrorCode)
    else
      Result := HttpOk;
  finally
    LeaveCriticalSection(FWriteLock);
  end;
  if not HttpSucceeded(Result) then
  begin
    EnterCriticalSection(FLock);
    FailConnection(Result);
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttp2Connection.ReleaseExchange(Exchange: THttp2Exchange);
var
  Stream: THttp2Stream;
  Unread: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Stream := Exchange.FStream;
    if Stream = nil then
    begin
      Dec(FReserved);
      Exit;
    end;
    if FFailed or FClosed then
      { Nothing more goes out on this connection. }
    else if not (Stream.RemoteEnded and Stream.LocalEnded) and not Stream.Failed then
      AppendResetStream(FOutgoing, Stream.Id, ErrorCancel)
    else if not Stream.RemoteEnded and Stream.Failed and (Stream.Failure.Code = HttpCanceled) then
      AppendResetStream(FOutgoing, Stream.Id, ErrorCancel);
    { What it never read goes back to the connection's window. }
    Unread := Stream.AvailableData;
    Inc(FUnacknowledged, Unread + Stream.Unacknowledged);
    GiveBackWindow(nil, 0);
    RemoveStream(Stream);
    if Stream.Waiting then
      Stream.Wake;
    WakeOneWaiter(nil);
    Stream.Free;
    Exchange.FStream := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  if not FClosed then
    FlushOutgoing;
end;

{ THttp2Exchange }

constructor THttp2Exchange.Create(Connection: THttp2Connection);
begin
  inherited Create;
  FConnection := Connection;
end;

destructor THttp2Exchange.Destroy;
begin
  Finish;
  inherited Destroy;
end;

function THttp2Exchange.HeadArrived(Stream: THttp2Stream): Boolean;
begin
  Result := Stream.HeadReceived;
end;

function THttp2Exchange.DataArrived(Stream: THttp2Stream): Boolean;
begin
  Result := (Stream.AvailableData > 0) or (Stream.RemoteEnded and not Stream.Failed);
end;

function THttp2Exchange.SendWindowOpen(Stream: THttp2Stream): Boolean;
begin
  { A server that answered in full wants no more content. }
  Result := ((Stream.SendWindow > 0) and (FConnection.FSendWindow > 0)) or Stream.RemoteEnded;
end;

function THttp2Exchange.SendData(Buffer: PByte; Count: Integer; EndStream: Boolean): THttpResult;
var
  Allowed: Int64;
  Frames: THttpByteBuffer;
  Failure: THttpResult;
begin
  Frames := Default(THttpByteBuffer);
  while (Count > 0) or EndStream do
  begin
    Allowed := 0;
    if Count > 0 then
    begin
      if not FConnection.WaitFor(FStream, @SendWindowOpen, Failure) then
        Exit(Failed(Failure.Code, Failure.Text, Failure.ErrorCode));
      if FStream.RemoteEnded then
        Exit(HttpOk);
      EnterCriticalSection(FConnection.FLock);
      Allowed := Count;
      if Allowed > FStream.SendWindow then
        Allowed := FStream.SendWindow;
      if Allowed > FConnection.FSendWindow then
        Allowed := FConnection.FSendWindow;
      if Allowed > FConnection.FPeerMaximumFrameSize then
        Allowed := FConnection.FPeerMaximumFrameSize;
      Dec(FStream.SendWindow, Allowed);
      Dec(FConnection.FSendWindow, Allowed);
      LeaveCriticalSection(FConnection.FLock);
    end;
    ClearBuffer(Frames);
    AppendDataFrame(Frames, FStream.Id, Buffer, Allowed, EndStream and (Allowed = Count));
    if not FConnection.WriteFrames(Frames) then
      Exit(Failed(HttpSendFailed, FConnection.FTransport.ErrorText, FConnection.FTransport.ErrorCode));
    Inc(Buffer, Allowed);
    Dec(Count, Allowed);
    if Count = 0 then
      Break;
  end;
  Result := HttpOk;
end;

function THttp2Exchange.SendBody(constref Head: THttpRequestHead): THttpResult;
var
  Piece: array[0..16383] of Byte;
  Count, NextCount: Integer;
  Next: array[0..16383] of Byte;
begin
  Count := Head.Body.Read(@Piece[0], SizeOf(Piece));
  while True do
  begin
    if Count < 0 then
      Exit(Failed(HttpSendFailed, 'the request content could not be read'));
    if Count = 0 then
    begin
      Result := SendData(nil, 0, True);
      Break;
    end;
    { One piece ahead, so the last one carries END_STREAM. }
    NextCount := Head.Body.Read(@Next[0], SizeOf(Next));
    Result := SendData(@Piece[0], Count, NextCount = 0);
    if not HttpSucceeded(Result) or (NextCount = 0) then
      Break;
    Move(Next[0], Piece[0], NextCount);
    Count := NextCount;
  end;
  if HttpSucceeded(Result) then
  begin
    EnterCriticalSection(FConnection.FLock);
    FStream.LocalEnded := True;
    LeaveCriticalSection(FConnection.FLock);
  end;
end;

function THttp2Exchange.Send(constref Head: THttpRequestHead): THttpResult;
begin
  Result := FConnection.OpenStream(Self, Head, Head.Body = nil);
  if not HttpSucceeded(Result) then
  begin
    FLastResult := Result;
    Exit;
  end;
  if Head.Body <> nil then
    Result := SendBody(Head);
  FLastResult := Result;
end;

function THttp2Exchange.ReceiveHead(out Head: THttpResponseHeadInfo): THttpResult;
var
  Failure: THttpResult;
begin
  Head := Default(THttpResponseHeadInfo);
  Head.ContentLength := -1;
  if FStream = nil then
    Exit(Failed(HttpSendFailed, 'the request was not sent'));
  if not FConnection.WaitFor(FStream, @HeadArrived, Failure) then
  begin
    { A stream that failed before any answer, on a connection that ended,
      is the same as no response. }
    FLastResult := Failure;
    if (Failure.Code = HttpReadFailed) and Failure.Retryable then
      FLastResult := HttpFailure(HttpNoResponse, 'no data received');
    Exit(FLastResult);
  end;
  EnterCriticalSection(FConnection.FLock);
  Head := FStream.Head;
  LeaveCriticalSection(FConnection.FLock);
  FLastResult := HttpOk;
  Result := HttpOk;
end;

function THttp2Exchange.ReadBody(Buffer: Pointer; Count: PtrUInt): Int64;
var
  Failure: THttpResult;
  Taken: Integer;
begin
  if FStream = nil then
    Exit(0);
  if Count > High(Integer) then
    Count := High(Integer);
  if not FConnection.WaitFor(FStream, @DataArrived, Failure) then
  begin
    FLastResult := Failure;
    if Failure.Code in [HttpReadFailed, HttpStreamReset] then
    begin
      if FStream.ExpectedLength >= 0 then
        FLastResult.Code := HttpBodyEndedEarly
      else
        FLastResult.Code := HttpReadFailed;
    end;
    Exit(-1);
  end;
  EnterCriticalSection(FConnection.FLock);
  Taken := FStream.TakeData(Buffer, Count);
  if Taken > 0 then
    FConnection.GiveBackWindow(FStream, Taken);
  LeaveCriticalSection(FConnection.FLock);
  if Taken > 0 then
    FConnection.FlushOutgoing;
  Result := Taken;
end;

function THttp2Exchange.BodyComplete: Boolean;
begin
  Result := (FStream <> nil) and FStream.RemoteEnded and not FStream.Failed and (FStream.AvailableData = 0);
end;

function THttp2Exchange.Trailers: THttpHeaderFieldArray;
begin
  if FStream <> nil then
    Result := FStream.Trailers
  else
    Result := nil;
end;

procedure THttp2Exchange.Finish;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FConnection.ReleaseExchange(Self);
end;

procedure THttp2Exchange.Abort;
var
  Opaque: array[0..7] of Byte;
begin
  FAborted := True;
  EnterCriticalSection(FConnection.FLock);
  if FStream <> nil then
  begin
    FStream.Fail(HttpFailure(HttpCanceled, 'canceled'));
    FStream.Wake;
    { A PING wakes a thread blocked reading for this stream. }
    FillChar(Opaque, SizeOf(Opaque), 0);
    AppendPing(FConnection.FOutgoing, False, @Opaque[0]);
  end;
  LeaveCriticalSection(FConnection.FLock);
  FConnection.FlushOutgoing;
end;

procedure THttp2Exchange.Reprioritize(constref Priority: THttpPriority);
var
  Frames: THttpByteBuffer;
begin
  if FStream = nil then
    Exit;
  Frames := Default(THttpByteBuffer);
  AppendPriorityUpdate(Frames, FStream.Id, FormatPriorityField(Priority));
  FConnection.WriteFrames(Frames);
end;

end.
