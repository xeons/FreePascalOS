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
  HTTP/3 as one of libhttp's connections: THttp3Connection is a
  THttpConnection (Http.Connections) over libquic's
  THttp3ClientConnection, and each THttp3Exchange a THttp3Request, so
  libhttp's client, pool, redirects, cache and fetch tasks carry HTTP/3
  as they carry HTTP/1.1 and HTTP/2.

  Many exchanges share the connection, from any number of threads. A
  QUIC connection has no thread of its own and is not thread safe, so
  one lock guards it and every call into libquic is made holding it.
  A request that waits (for its head, for body data) runs the
  connection itself, in slices of at most 20 ms (WaitForProgress
  overridden): each slice sends what is due, takes in what came for any
  stream, and lets the lock go before the next, so the other threads'
  requests go out and read what arrived for them meanwhile. A thread
  blocked in libquic's own waits (room in a full send buffer, a stream
  the server does not allow yet) keeps the lock until they end.

  - Send: HEADERS (:method, :scheme, :authority, :path, then the fields
    less Host and the connection-specific ones; Priority when not the
    default; content-type and content-length from the content), then
    the content in DATA frames of 16 KiB, each written under the lock
    on its own; a server that stopped reading the request (STOP_SENDING)
    ends the sending and its response is read.
  - ReceiveHead: interim heads passed over; the head as libhttp's
    record, RawHead "HTTP/3 200" and the fields for wget -S.
  - ReadBody streams DATA as it comes; trailers kept at the end.
  - Abort (any thread): the waiting request notices within a slice and
    the stream is cancelled (STOP_SENDING, RESET_STREAM with
    H3_REQUEST_CANCELLED) when the exchange finishes.
  - GOAWAY: no new exchanges; a request at or above its stream ID, and
    one the server rejected (H3_REQUEST_REJECTED), fails as retryable
    so the client sends it again on another connection.
  - Reprioritize sends PRIORITY_UPDATE (RFC 9218).

  The connection is usable while the QUIC connection is open, no
  GOAWAY came and its idle timeout is more than a second away; the
  exchanges in flight at once are kept within the streams the server
  allows. Plain Pascal over a connected TQuicConnection, so it runs on
  the host too (tools/QuicTest); Http3.SystemConnections makes the
  system's.
}
unit Http3.HttpConnections;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.Connections,
  Http.HeaderFields,
  Http.Priorities,
  Http.Results,
  Http3.Connections,
  Http3.Requests,
  Quic.Connections;

const
  { The longest a request holds the connection's lock while it waits. }
  Http3PumpSliceMilliseconds = 20;
  { Exchanges at once on one connection, whatever the server allows. }
  Http3MaximumExchanges = 100;

type
  THttp3Connection = class;

  { The HTTP/3 connection whose waits go in slices, with the lock let go
    between them. }
  TSharedHttp3ClientConnection = class(THttp3ClientConnection)
  private
    FOwner: THttp3Connection;
  public
    function WaitForProgress(Deadline: Int64): LongInt; override;
  end;

  THttp3Exchange = class(THttpExchange)
  private
    FConnection: THttp3Connection;
    FRequest: THttp3Request;
    FReserved: Boolean;
    FAborted: Boolean;
    FFinished: Boolean;
    FHeadReceived: Boolean;
    FNoBody: Boolean;
    FBodyEnded: Boolean;
    FTrailers: THttpHeaderFieldArray;
    function OpenRequest(constref Head: THttpRequestHead): THttpResult;
    function SendBody(constref Head: THttpRequestHead): THttpResult;
    function RequestFailure(Error: LongInt; InBody: Boolean): THttpResult;
  public
    constructor Create(Connection: THttp3Connection);
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

  THttp3Connection = class(THttpConnection)
  private
    FLock: TRTLCriticalSection;
    FQuic: TQuicConnection;
    FHttp: TSharedHttp3ClientConnection;
    FOwner: TObject;
    FTimeout: Int64;
    FActive: Integer;
    FReservedStreams: Integer;
    FClosed: Boolean;
    FUsable: Boolean;
    FIdleDeadline: Int64;
    procedure Lock;
    procedure Unlock;
    { Under the lock: lets the other threads in for a moment. }
    procedure LetOthersIn;
    { Under the lock: FUsable and FIdleDeadline from the connection. }
    procedure Refresh;
    function StreamsAvailable: Int64;
  public
    { Quic is connected with ALPN "h3". Owner, when given, is freed last
      and frees Quic and what it runs over; else Quic is freed. Each
      wait of a request ends after TimeoutMilliseconds (0: no limit). }
    constructor Create(Quic: TQuicConnection; Owner: TObject; TimeoutMilliseconds: Int64);
    destructor Destroy; override;
    { Opens the control and QPACK streams. }
    function Start: THttpResult;
    function StartExchange: THttpExchange; override;
    function IsUsable: Boolean; override;
    function IsIdle: Boolean; override;
    function IsMultiplexed: Boolean; override;
    procedure Close; override;
    { What libquic says of an error (for messages). }
    function DescribeError(Error: LongInt): string;
    property Quic: TQuicConnection read FQuic;
    property Http: TSharedHttp3ClientConnection read FHttp;
  end;

implementation

uses
  Http.StatusCodes,
  Http3.Constants,
  Quic.DatagramTransports,
  Quic.Errors;

const
  UsableMarginMilliseconds = 1000;
  NoTimeoutMilliseconds = Int64(24) * 3600 * 1000;
  BodyPieceSize = 16384;

threadvar
  { The exchange whose call into libquic this thread is making. }
  WaitingExchange: THttp3Exchange;

function IsConnectionSpecific(const Name: string): Boolean;
begin
  Result := (Name = 'connection') or (Name = 'keep-alive') or (Name = 'proxy-connection') or
    (Name = 'transfer-encoding') or (Name = 'upgrade') or (Name = 'host');
end;

{ TSharedHttp3ClientConnection }

function TSharedHttp3ClientConnection.WaitForProgress(Deadline: Int64): LongInt;
var
  Slice: Int64;
  Exchange: THttp3Exchange;
begin
  Result := LastError;
  if Result <> 0 then
    Exit;
  Exchange := WaitingExchange;
  if (Exchange <> nil) and Exchange.FAborted then
    Exit(Http3ErrorCanceled);
  Slice := Deadline - QuicMilliseconds;
  if Slice <= 0 then
    Exit(QuicErrorTimedOut);
  if Slice > Http3PumpSliceMilliseconds then
    Slice := Http3PumpSliceMilliseconds;
  Quic.Pump(Slice);
  Result := Service;
  if Result <> 0 then
    Exit;
  FOwner.LetOthersIn;
  Result := LastError;
  if Result <> 0 then
    Exit;
  if (Exchange <> nil) and Exchange.FAborted then
    Exit(Http3ErrorCanceled);
  { Requests at or above GOAWAY's ID will not be answered (RFC 9114
    section 5.2). }
  if (Exchange <> nil) and (Exchange.FRequest <> nil) and GoawayReceived and
     (Exchange.FRequest.StreamId >= GoawayId) then
    Exit(Http3ErrorGoingAway);
end;

{ THttp3Connection }

constructor THttp3Connection.Create(Quic: TQuicConnection; Owner: TObject; TimeoutMilliseconds: Int64);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FProtocol := HttpProtocol3;
  FQuic := Quic;
  FOwner := Owner;
  FTimeout := TimeoutMilliseconds;
  if FTimeout <= 0 then
    FTimeout := NoTimeoutMilliseconds;
  FHttp := TSharedHttp3ClientConnection.Create(Quic, False);
  FHttp.FOwner := Self;
end;

destructor THttp3Connection.Destroy;
begin
  Close;
  FHttp.Free;
  if FOwner <> nil then
    FOwner.Free
  else
    FQuic.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure THttp3Connection.Lock;
begin
  EnterCriticalSection(FLock);
end;

procedure THttp3Connection.Unlock;
begin
  WaitingExchange := nil;
  Refresh;
  LeaveCriticalSection(FLock);
end;

procedure THttp3Connection.LetOthersIn;
begin
  Refresh;
  LeaveCriticalSection(FLock);
  ThreadSwitch;
  EnterCriticalSection(FLock);
end;

procedure THttp3Connection.Refresh;
begin
  FUsable := not FClosed and (FHttp.LastError = 0) and not FHttp.GoawayReceived;
  FIdleDeadline := FQuic.IdleDeadline;
end;

function THttp3Connection.StreamsAvailable: Int64;
begin
  Result := Int64(FQuic.State^.PeerMaxStreamsBidirectional) - Int64(FQuic.State^.LocalBidirectionalOpened) -
    FReservedStreams;
end;

function THttp3Connection.Start: THttpResult;
var
  Error: LongInt;
begin
  Lock;
  try
    Error := FHttp.Start;
    if Error <> 0 then
      Exit(HttpFailure(HttpConnectFailed, FHttp.ErrorDescription(Error), Error));
    FHttp.Service;
    Result := HttpOk;
  finally
    Unlock;
  end;
end;

function THttp3Connection.StartExchange: THttpExchange;
var
  Exchange: THttp3Exchange;
begin
  Result := nil;
  Lock;
  try
    { What came while the connection sat idle (a GOAWAY, a close, more
      streams allowed) is taken in first, without waiting. }
    if FUsable then
    begin
      FQuic.Pump(0);
      FHttp.Service;
      Refresh;
    end;
    if not FUsable or (FActive >= Http3MaximumExchanges) or (StreamsAvailable <= 0) then
      Exit;
    Inc(FActive);
    Inc(FReservedStreams);
    Inc(FExchangesStarted);
    Exchange := THttp3Exchange.Create(Self);
    Exchange.FReserved := True;
    Result := Exchange;
  finally
    Unlock;
  end;
end;

function THttp3Connection.IsUsable: Boolean;
begin
  Result := FUsable and (QuicMilliseconds + UsableMarginMilliseconds < FIdleDeadline);
end;

function THttp3Connection.IsIdle: Boolean;
begin
  Result := FActive = 0;
end;

function THttp3Connection.IsMultiplexed: Boolean;
begin
  Result := True;
end;

procedure THttp3Connection.Close;
begin
  Lock;
  try
    if FClosed then
      Exit;
    FClosed := True;
    FHttp.Close;
  finally
    Unlock;
  end;
end;

function THttp3Connection.DescribeError(Error: LongInt): string;
begin
  Lock;
  try
    Result := FHttp.ErrorDescription(Error);
  finally
    Unlock;
  end;
end;

{ THttp3Exchange }

constructor THttp3Exchange.Create(Connection: THttp3Connection);
begin
  inherited Create;
  FConnection := Connection;
end;

destructor THttp3Exchange.Destroy;
begin
  Finish;
  inherited Destroy;
end;

{ Under the lock: the result for an error of the request (InBody: while
  its body came). }
function THttp3Exchange.RequestFailure(Error: LongInt; InBody: Boolean): THttpResult;
var
  Text: string;
begin
  Text := FConnection.FHttp.ErrorDescription(Error);
  case Error of
    Http3ErrorCanceled:
      Result := HttpFailure(HttpCanceled, 'canceled');
    Http3ErrorMalformedResponse:
      if InBody then
        Result := HttpFailure(HttpMalformedBody, Text)
      else
        Result := HttpFailure(HttpMalformedResponse, Text);
    Http3ErrorRequestReset:
      begin
        Result := HttpFailure(HttpStreamReset, 'the server reset the request (' +
          Http3ErrorName(FRequest.ResetCode) + ')', LongInt(FRequest.ResetCode));
        { Rejected: the server did not act on it (RFC 9114 section 8.1). }
        Result.Retryable := not InBody and (FRequest.ResetCode = Http3RequestRejected);
      end;
    Http3ErrorGoingAway:
      begin
        Result := HttpFailure(HttpStreamReset, Text, Error);
        Result.Retryable := not InBody;
      end;
    Http3ErrorIncomplete:
      if InBody then
        Result := HttpFailure(HttpBodyEndedEarly, Text)
      else
        Result := HttpFailure(HttpNoResponse, 'no response (' + Text + ')');
    Http3ErrorConnection:
      Result := HttpFailure(HttpProtocolError, Text, Error);
    QuicErrorTimedOut:
      Result := HttpFailure(HttpTimedOut, 'timed out waiting for the server');
  else
    if InBody then
      Result := HttpFailure(HttpBodyEndedEarly, Text, Error)
    else
      Result := HttpFailure(HttpReadFailed, Text, Error);
  end;
end;

{ Under the lock: the request's HEADERS. }
function THttp3Exchange.OpenRequest(constref Head: THttpRequestHead): THttpResult;
var
  Fields: THttpHeaderFieldArray;
  Field: THttpHeaderField;
  PriorityText: string;

  procedure AddField(const Name, Value: string);
  begin
    SetLength(Fields, Length(Fields) + 1);
    Fields[High(Fields)].Name := Name;
    Fields[High(Fields)].Value := Value;
  end;

begin
  Fields := nil;
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
  FReserved := False;
  Dec(FConnection.FReservedStreams);
  if not FConnection.FUsable then
  begin
    Result := HttpFailure(HttpStreamReset, 'the connection takes no new requests');
    Result.Retryable := True;
    Exit;
  end;
  try
    FRequest := THttp3Request.Create(FConnection.FHttp, Head.Method, Head.Scheme, Head.Authority, Head.Target,
      Fields, Head.Body = nil);
  except
    on Problem: EQuicError do
    begin
      if (Problem.Code = Http3ErrorGoingAway) or (Problem.Code = QuicErrorStreamLimit) then
      begin
        Result := HttpFailure(HttpStreamReset, Problem.Message, Problem.Code);
        Result.Retryable := True;
      end
      else
        Result := HttpFailure(HttpSendFailed, Problem.Message, Problem.Code);
      Exit;
    end;
  end;
  FRequest.Timeout := FConnection.FTimeout;
  Result := HttpOk;
end;

function THttp3Exchange.SendBody(constref Head: THttpRequestHead): THttpResult;
var
  Piece: array[0..BodyPieceSize - 1] of Byte;
  Count: Integer;
  Written: Int64;
  Error: LongInt;
begin
  Result := HttpOk;
  repeat
    if FAborted then
      Exit(HttpFailure(HttpCanceled, 'canceled'));
    Count := Head.Body.Read(@Piece[0], SizeOf(Piece));
    if Count < 0 then
      Exit(HttpFailure(HttpSendFailed, 'the request content could not be read'));
    if Count = 0 then
      Break;
    FConnection.Lock;
    try
      WaitingExchange := Self;
      Written := FRequest.WriteBody(@Piece[0], Count);
      WaitingExchange := nil;
      { The server stopped reading: it has answered, or will. }
      if Written = QuicErrorStreamStopped then
        Exit(HttpOk);
      if Written < 0 then
        Exit(HttpFailure(HttpSendFailed, FConnection.FHttp.ErrorDescription(LongInt(Written)), LongInt(Written)));
    finally
      FConnection.Unlock;
    end;
  until False;
  FConnection.Lock;
  try
    Error := FRequest.FinishRequest;
    if (Error <> 0) and (Error <> QuicErrorStreamStopped) and (Error <> QuicErrorInvalidStream) then
      Result := HttpFailure(HttpSendFailed, FConnection.FHttp.ErrorDescription(Error), Error);
  finally
    FConnection.Unlock;
  end;
end;

function THttp3Exchange.Send(constref Head: THttpRequestHead): THttpResult;
begin
  if FAborted then
    Exit(Failed(HttpCanceled, 'canceled'));
  if FRequest <> nil then
    Exit(Failed(HttpSendFailed, 'the request was sent already'));
  FConnection.Lock;
  try
    WaitingExchange := Self;
    Result := OpenRequest(Head);
    WaitingExchange := nil;
  finally
    FConnection.Unlock;
  end;
  if HttpSucceeded(Result) and (Head.Body <> nil) then
    Result := SendBody(Head);
  FLastResult := Result;
end;

function THttp3Exchange.ReceiveHead(out Head: THttpResponseHeadInfo): THttpResult;
var
  Error: LongInt;
  Field: THttpHeaderField;
  Raw, Value: string;
  Length_: Int64;
begin
  Head := Default(THttpResponseHeadInfo);
  Head.ContentLength := -1;
  if FRequest = nil then
    Exit(Failed(HttpSendFailed, 'the request was not sent'));
  FConnection.Lock;
  try
    WaitingExchange := Self;
    Error := FRequest.ReadHead;
    WaitingExchange := nil;
    if Error <> 0 then
    begin
      FLastResult := RequestFailure(Error, False);
      Exit(FLastResult);
    end;
    Head.Status := FRequest.Status;
    Head.Version := 30;
    Head.Fields := Copy(FRequest.Headers);
  finally
    FConnection.Unlock;
  end;
  Raw := 'HTTP/3 ' + IntToStr(Head.Status) + #13#10;
  for Field in Head.Fields do
    Raw := Raw + Field.Name + ': ' + Field.Value + #13#10;
  Head.RawHead := Raw + #13#10;
  Value := FieldsValue(Head.Fields, 'content-length');
  if (Value <> '') and TryStrToInt64(Value, Length_) and (Length_ >= 0) then
    Head.ContentLength := Length_;
  FNoBody := StatusHasNoBody(Head.Status) or (FRequest.Phase = ResponseDone);
  if FNoBody then
    Head.ContentLength := 0;
  FHeadReceived := True;
  FLastResult := HttpOk;
  Result := HttpOk;
end;

function THttp3Exchange.ReadBody(Buffer: Pointer; Count: PtrUInt): Int64;
begin
  if (FRequest = nil) or FBodyEnded then
    Exit(0);
  if FAborted then
  begin
    Failed(HttpCanceled, 'canceled');
    Exit(-1);
  end;
  FConnection.Lock;
  try
    WaitingExchange := Self;
    Result := FRequest.ReadBody(Buffer, Count);
    WaitingExchange := nil;
    if Result = 0 then
    begin
      FBodyEnded := True;
      FTrailers := Copy(FRequest.Trailers);
    end
    else if Result < 0 then
    begin
      FLastResult := RequestFailure(LongInt(Result), True);
      Result := -1;
    end;
  finally
    FConnection.Unlock;
  end;
end;

function THttp3Exchange.BodyComplete: Boolean;
begin
  Result := FBodyEnded or (FHeadReceived and FNoBody);
end;

function THttp3Exchange.Trailers: THttpHeaderFieldArray;
begin
  Result := FTrailers;
end;

procedure THttp3Exchange.Finish;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FConnection.Lock;
  try
    if FReserved then
    begin
      FReserved := False;
      Dec(FConnection.FReservedStreams);
    end;
    { A request not answered in full is cancelled as it is freed. }
    FreeAndNil(FRequest);
    Dec(FConnection.FActive);
  finally
    FConnection.Unlock;
  end;
end;

procedure THttp3Exchange.Abort;
begin
  { The waiting thread sees it within a slice; nothing here touches the
    connection, which another thread may be running. }
  FAborted := True;
end;

procedure THttp3Exchange.Reprioritize(constref Priority: THttpPriority);
begin
  FConnection.Lock;
  try
    if (FRequest <> nil) and not FBodyEnded then
      FConnection.FHttp.SendPriorityUpdate(FRequest.StreamId, FormatPriorityField(Priority));
  finally
    FConnection.Unlock;
  end;
end;

end.
