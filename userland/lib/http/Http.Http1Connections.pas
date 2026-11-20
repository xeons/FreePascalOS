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
  HTTP/1.1 (RFC 9112) over a transport, one exchange at a time
  (pipelining is not used):

  - the request: the request line, Host, the fields as given, and
    Content-Length or "Transfer-Encoding: chunked" for content of
    unknown length (sent in pieces as it is read);
  - the response head read through a 16 KiB buffer (interim 1xx
    responses skipped, but kept in RawHead), parsed by
    Http.ResponseHeads;
  - the body (section 6.3): none for HEAD, 1xx, 204 and 304; chunked;
    Content-Length bytes; or everything until the server closes;
  - the connection goes on after an exchange only when its body had a
    known end, was read whole, and the server did not close
    (ConnectionPersists).

  Plain Pascal over Http.Transports, checked on the host by
  tools/HttpTest (a loopback exchange with a small server).
}
unit Http.Http1Connections;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Http.Chunks,
  Http.Connections,
  Http.ResponseHeads,
  Http.Results,
  Http.Transports;

const
  Http1BufferSize = 16 * 1024;

type
  THttp1Exchange = class;

  THttp1Connection = class(THttpConnection)
  private
    FTransport: THttpTransport;
    FBuffer: array[0..Http1BufferSize - 1] of Byte;
    FBufferStart, FBufferEnd: Integer;
    FBusy: Boolean;
    FBroken: Boolean;
    function BufferedCount: Integer;
    function FillBuffer: Int64;
    procedure Consume(Count: Integer);
    function TransportFailure(const Context: string): THttpResult;
  public
    { Takes over the transport. }
    constructor Create(Transport: THttpTransport; const Origin: string);
    destructor Destroy; override;
    function StartExchange: THttpExchange; override;
    function IsUsable: Boolean; override;
    function IsIdle: Boolean; override;
    procedure Close; override;
    property Transport: THttpTransport read FTransport;
  end;

  TBodyFraming = (FramingNone, FramingLength, FramingChunked, FramingClose);

  THttp1Exchange = class(THttpExchange)
  private
    FConnection: THttp1Connection;
    FHeadRequest: Boolean;
    FCloseRequested: Boolean;
    FHead: THttpResponseHead;
    FHeadReceived: Boolean;
    FFraming: TBodyFraming;
    FRemaining: Int64;
    FChunks: TChunkDecoder;
    FComplete: Boolean;
    FAborted: Boolean;
    FFinished: Boolean;
    function SendBody(constref Head: THttpRequestHead): THttpResult;
    function ReadChunked(Buffer: PByte; Count: PtrUInt): Int64;
  public
    constructor Create(Connection: THttp1Connection);
    function Send(constref Head: THttpRequestHead): THttpResult; override;
    function ReceiveHead(out Head: THttpResponseHeadInfo): THttpResult; override;
    function ReadBody(Buffer: Pointer; Count: PtrUInt): Int64; override;
    function BodyComplete: Boolean; override;
    procedure Finish; override;
    procedure Abort; override;
  end;

{ "user-agent" as "User-Agent". }
function DisplayFieldName(const Name: string): string;

implementation

uses
  SysUtils,
  Http.ByteBuffers,
  Http.HeaderFields,
  Http.StatusCodes;

const
  LineEnd = #13#10;
  BodyPieceSize = 16 * 1024;

function DisplayFieldName(const Name: string): string;
var
  Index: Integer;
  StartOfWord: Boolean;
begin
  Result := Name;
  StartOfWord := True;
  for Index := 1 to Length(Result) do
  begin
    if StartOfWord and (Result[Index] in ['a'..'z']) then
      Result[Index] := UpCase(Result[Index]);
    StartOfWord := Result[Index] = '-';
  end;
end;

{ THttp1Connection }

constructor THttp1Connection.Create(Transport: THttpTransport; const Origin: string);
begin
  inherited Create;
  FTransport := Transport;
  FProtocol := HttpProtocol11;
  FOriginKey := Origin;
end;

destructor THttp1Connection.Destroy;
begin
  Close;
  FTransport.Free;
  inherited Destroy;
end;

function THttp1Connection.BufferedCount: Integer;
begin
  Result := FBufferEnd - FBufferStart;
end;

function THttp1Connection.FillBuffer: Int64;
begin
  if FBufferStart > 0 then
  begin
    if FBufferEnd > FBufferStart then
      Move(FBuffer[FBufferStart], FBuffer[0], FBufferEnd - FBufferStart);
    Dec(FBufferEnd, FBufferStart);
    FBufferStart := 0;
  end;
  if FBufferEnd >= Http1BufferSize then
    Exit(0);
  Result := FTransport.Read(@FBuffer[FBufferEnd], Http1BufferSize - FBufferEnd);
  if Result > 0 then
    Inc(FBufferEnd, Result);
end;

procedure THttp1Connection.Consume(Count: Integer);
begin
  if Count > BufferedCount then
    Count := BufferedCount;
  Inc(FBufferStart, Count);
end;

function THttp1Connection.TransportFailure(const Context: string): THttpResult;
begin
  if FTransport.Failure = TransportFailureTimeout then
    Result := HttpFailure(HttpTimedOut, FTransport.ErrorText, FTransport.ErrorCode)
  else if Context = 'send' then
    Result := HttpFailure(HttpSendFailed, FTransport.ErrorText, FTransport.ErrorCode)
  else
    Result := HttpFailure(HttpReadFailed, FTransport.ErrorText, FTransport.ErrorCode);
end;

function THttp1Connection.StartExchange: THttpExchange;
begin
  Result := nil;
  if FBusy or FBroken then
    Exit;
  FBusy := True;
  Inc(FExchangesStarted);
  Result := THttp1Exchange.Create(Self);
end;

function THttp1Connection.IsUsable: Boolean;
begin
  Result := not FBroken;
end;

function THttp1Connection.IsIdle: Boolean;
begin
  Result := not FBusy;
end;

procedure THttp1Connection.Close;
begin
  if FBroken then
    Exit;
  FBroken := True;
  FTransport.Close;
end;

{ THttp1Exchange }

constructor THttp1Exchange.Create(Connection: THttp1Connection);
begin
  inherited Create;
  FConnection := Connection;
end;

function THttp1Exchange.SendBody(constref Head: THttpRequestHead): THttpResult;
var
  Piece: array[0..BodyPieceSize - 1] of Byte;
  Count: Integer;
  Chunked: Boolean;
  Framed: THttpByteBuffer;
begin
  Result := HttpOk;
  Chunked := Head.Body.Length < 0;
  Framed := Default(THttpByteBuffer);
  repeat
    Count := Head.Body.Read(@Piece[0], SizeOf(Piece));
    if Count < 0 then
      Exit(Failed(HttpSendFailed, 'the request content could not be read'));
    if Count = 0 then
      Break;
    if Chunked then
    begin
      ClearBuffer(Framed);
      EncodeChunk(@Piece[0], Count, Framed);
      if not FConnection.FTransport.Write(@Framed.Data[0], Framed.Length) then
        Exit(FConnection.TransportFailure('send'));
    end
    else if not FConnection.FTransport.Write(@Piece[0], Count) then
      Exit(FConnection.TransportFailure('send'));
  until False;
  if Chunked then
  begin
    ClearBuffer(Framed);
    EncodeLastChunk(Framed);
    if not FConnection.FTransport.Write(@Framed.Data[0], Framed.Length) then
      Exit(FConnection.TransportFailure('send'));
  end;
end;

function THttp1Exchange.Send(constref Head: THttpRequestHead): THttpResult;
var
  Request: string;
  Field: THttpHeaderField;
  ContentType: string;
begin
  FHeadRequest := Head.Method = 'HEAD';
  FCloseRequested := Head.CloseConnection;
  Request := Head.Method + ' ' + Head.Target + ' HTTP/1.1' + LineEnd + 'Host: ' + Head.Authority + LineEnd;
  for Field in Head.Fields do
    Request := Request + DisplayFieldName(Field.Name) + ': ' + Field.Value + LineEnd;
  if Head.Body <> nil then
  begin
    ContentType := Head.Body.ContentType;
    if (ContentType <> '') and not FieldsHave(Head.Fields, 'content-type') then
      Request := Request + 'Content-Type: ' + ContentType + LineEnd;
    if Head.Body.Length >= 0 then
      Request := Request + 'Content-Length: ' + IntToStr(Head.Body.Length) + LineEnd
    else
      Request := Request + 'Transfer-Encoding: chunked' + LineEnd;
  end;
  if Head.CloseConnection and not FieldsHave(Head.Fields, 'connection') then
    Request := Request + 'Connection: close' + LineEnd;
  Request := Request + LineEnd;
  if not FConnection.FTransport.Write(PChar(Request), Length(Request)) then
  begin
    FLastResult := FConnection.TransportFailure('send');
    Exit(FLastResult);
  end;
  if Head.Body <> nil then
  begin
    Result := SendBody(Head);
    if not HttpSucceeded(Result) then
      Exit;
  end;
  Result := HttpOk;
end;

function THttp1Exchange.ReceiveHead(out Head: THttpResponseHeadInfo): THttpResult;
var
  HeadLength: PtrUInt;
  Received: Int64;
  Text: string;
  Parsed: THeadParseResult;
begin
  Head := Default(THttpResponseHeadInfo);
  Head.ContentLength := -1;
  while True do
  begin
    repeat
      HeadLength := FindHeadEnd(PChar(@FConnection.FBuffer[FConnection.FBufferStart]), FConnection.BufferedCount);
      if HeadLength > 0 then
        Break;
      if FConnection.BufferedCount >= Http1BufferSize then
        Exit(Failed(HttpHeadTooLarge, 'the response head is too large'));
      Received := FConnection.FillBuffer;
      if FAborted then
        Exit(Failed(HttpCanceled, 'canceled'));
      if Received < 0 then
      begin
        FLastResult := FConnection.TransportFailure('receive');
        Exit(FLastResult);
      end;
      if Received = 0 then
        Exit(Failed(HttpNoResponse, 'no data received'));
    until False;
    SetString(Text, PChar(@FConnection.FBuffer[FConnection.FBufferStart]), HeadLength);
    Head.RawHead := Head.RawHead + Text;
    Parsed := ParseResponseHead(Text, FHead);
    FConnection.Consume(HeadLength);
    if Parsed = HeadUnsupportedCoding then
      Exit(Failed(HttpUnsupportedTransferCoding, 'a transfer coding other than chunked'));
    if Parsed <> HeadParsed then
      Exit(Failed(HttpMalformedResponse, 'a malformed response head'));
    if StatusIsInformational(FHead.StatusCode) then
      Continue;
    Break;
  end;
  FHeadReceived := True;
  Head.Status := FHead.StatusCode;
  Head.Reason := FHead.Reason;
  Head.Version := FHead.MajorVersion * 10 + FHead.MinorVersion;
  Head.Fields := FHead.Fields;
  if FHeadRequest or StatusHasNoBody(FHead.StatusCode) then
  begin
    FFraming := FramingNone;
    FComplete := True;
  end
  else if FHead.Chunked then
  begin
    FFraming := FramingChunked;
    BeginChunkDecoder(FChunks);
  end
  else if FHead.ContentLength >= 0 then
  begin
    FFraming := FramingLength;
    FRemaining := FHead.ContentLength;
    Head.ContentLength := FHead.ContentLength;
    FComplete := FRemaining = 0;
  end
  else
    FFraming := FramingClose;
  if FFraming = FramingNone then
    Head.ContentLength := 0;
  FLastResult := HttpOk;
  Result := HttpOk;
end;

function THttp1Exchange.ReadChunked(Buffer: PByte; Count: PtrUInt): Int64;
var
  Received: Int64;
  Input: PtrUInt;
  Produced, Consumed: PtrUInt;
begin
  while not ChunkDecoderFinished(FChunks) do
  begin
    if FConnection.BufferedCount = 0 then
    begin
      Received := FConnection.FillBuffer;
      if FAborted then
        Exit(-1);
      if Received < 0 then
      begin
        FLastResult := FConnection.TransportFailure('receive');
        Exit(-1);
      end;
      if Received = 0 then
      begin
        Failed(HttpBodyEndedEarly, 'the connection closed in the body');
        Exit(-1);
      end;
    end;
    Input := FConnection.BufferedCount;
    if Input > Count then
      Input := Count;
    if not DecodeChunks(FChunks, @FConnection.FBuffer[FConnection.FBufferStart], Input, Buffer, Produced, Consumed) then
    begin
      Failed(HttpMalformedBody, 'a malformed chunked body');
      Exit(-1);
    end;
    FConnection.Consume(Consumed);
    if Produced > 0 then
      Exit(Produced);
  end;
  FComplete := True;
  Result := 0;
end;

function THttp1Exchange.ReadBody(Buffer: Pointer; Count: PtrUInt): Int64;
var
  Available: PtrUInt;
  Received: Int64;
begin
  if FAborted then
  begin
    Failed(HttpCanceled, 'canceled');
    Exit(-1);
  end;
  if FComplete or not FHeadReceived or (Count = 0) then
    Exit(0);
  if FFraming = FramingChunked then
    Exit(ReadChunked(Buffer, Count));
  if (FFraming = FramingLength) and (Int64(Count) > FRemaining) then
    Count := FRemaining;
  if FConnection.BufferedCount = 0 then
  begin
    Received := FConnection.FillBuffer;
    if FAborted then
    begin
      Failed(HttpCanceled, 'canceled');
      Exit(-1);
    end;
    if Received < 0 then
    begin
      FLastResult := FConnection.TransportFailure('receive');
      Exit(-1);
    end;
    if Received = 0 then
    begin
      if FFraming = FramingClose then
      begin
        FComplete := True;
        Exit(0);
      end;
      Failed(HttpBodyEndedEarly, 'the connection closed in the body');
      Exit(-1);
    end;
  end;
  Available := FConnection.BufferedCount;
  if Available > Count then
    Available := Count;
  Move(FConnection.FBuffer[FConnection.FBufferStart], Buffer^, Available);
  FConnection.Consume(Available);
  if FFraming = FramingLength then
  begin
    Dec(FRemaining, Available);
    FComplete := FRemaining = 0;
  end;
  Result := Available;
end;

function THttp1Exchange.BodyComplete: Boolean;
begin
  Result := FComplete;
end;

procedure THttp1Exchange.Finish;
var
  Persists: Boolean;
begin
  if FFinished then
    Exit;
  FFinished := True;
  Persists := FHeadReceived and FComplete and not FAborted and not FCloseRequested and
    (FFraming <> FramingClose) and ConnectionPersists(FHead);
  if not Persists then
    FConnection.Close;
  FConnection.FBusy := False;
end;

procedure THttp1Exchange.Abort;
begin
  FAborted := True;
  FConnection.FTransport.Shutdown;
end;

end.
