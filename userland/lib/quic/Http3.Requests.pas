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
  One HTTP/3 request and its response (RFC 9114 section 4) on a
  bidirectional stream:

    Request := THttp3Request.Create(Connection, 'GET', 'https',
      'example.org', '/', Headers, True);
    if Request.ReadHead = Http3ErrorNone then ... Request.Status,
      Request.Headers ...
    Count := Request.ReadBody(@Buffer, SizeOf(Buffer));   (0: the end)
    Request.Free;

  The request is HEADERS (pseudo-header fields :method, :scheme,
  :authority, :path, then the caller's fields), then the body in DATA
  frames (WriteBody, FinishRequest) unless it ended with the HEADERS.
  The response: interim (1xx) heads are passed over, the final head is
  checked (one :status of three digits first, no other pseudo-header,
  lower case names, no connection-specific fields), the body streams out
  of the DATA frames as it arrives and must match Content-Length, and
  trailers may follow. A malformed response resets the stream with
  H3_MESSAGE_ERROR; a request freed before its response ended is
  cancelled (H3_REQUEST_CANCELLED).
}
unit Http3.Requests;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http3.Connections,
  Http3.FrameParser,
  Qpack.StaticTable;

type
  THttp3ResponsePhase = (ResponseHead, ResponseBody, ResponseTrailers, ResponseDone, ResponseFailed);

  THttp3Request = class
  private
    FConnection: THttp3ClientConnection;
    FStreamId: QWord;
    FMethod: string;
    FParser: THttp3FrameParser;
    FPhase: THttp3ResponsePhase;
    FStatus: Integer;
    FHeaders: TQpackFieldList;
    FTrailers: TQpackFieldList;
    FInterimStatuses: array of Integer;
    FPendingSection: TBytes;
    FHasPendingSection: Boolean;
    FLeftover: TBytes;
    FLeftoverStart: Integer;
    FBodyReceived: QWord;
    FContentLength: Int64;
    FRequestEnded: Boolean;
    FError: LongInt;
    FResetCode: QWord;
    FTimeout: Int64;
    function Fail(Error: LongInt; StreamErrorCode: QWord): LongInt;
    function HandleSection(Data: PByte; Length: PtrUInt): LongInt;
    function AcceptHead(constref Fields: TQpackFieldList): LongInt;
    function AcceptTrailers(constref Fields: TQpackFieldList): LongInt;
    function Advance(Buffer: PByte; Capacity: PtrUInt; out Delivered: PtrUInt): LongInt;
    function FillParser(Deadline: Int64): LongInt;
    function WaitForMore(Deadline: Int64): LongInt;
    function GetInterimStatus(Index: Integer): Integer;
    function GetInterimCount: Integer;
  public
    { Opens a stream and sends the request's HEADERS (and its end when
      EndRequest: a request without a body). Raises EQuicError when
      the stream cannot be opened. }
    constructor Create(Connection: THttp3ClientConnection; const Method, Scheme, Authority, Path: string;
      constref Headers: TQpackFieldList; EndRequest: Boolean);
    destructor Destroy; override;
    { Body bytes in a DATA frame: Length, or an error. }
    function WriteBody(Data: Pointer; Length: PtrUInt): Int64;
    function FinishRequest: LongInt;
    { Waits for the final response head. }
    function ReadHead: LongInt;
    { Body bytes (at most Capacity): the count, 0 at the end (trailers
      read), or an error. }
    function ReadBody(Buffer: Pointer; Capacity: PtrUInt): Int64;
    { The whole body as a string (for small responses). }
    function ReadAll(out Body: string): LongInt;
    { Gives up on the response: STOP_SENDING and RESET_STREAM with
      H3_REQUEST_CANCELLED. }
    procedure Cancel;
    property StreamId: QWord read FStreamId;
    property Status: Integer read FStatus;
    property Headers: TQpackFieldList read FHeaders;
    property Trailers: TQpackFieldList read FTrailers;
    property InterimCount: Integer read GetInterimCount;
    property InterimStatus[Index: Integer]: Integer read GetInterimStatus;
    property BodyReceived: QWord read FBodyReceived;
    { The server's code when it reset the stream. }
    property ResetCode: QWord read FResetCode;
    property LastError: LongInt read FError;
    property Phase: THttp3ResponsePhase read FPhase;
    { For each wait; the connection's QUIC timeout unless set. }
    property Timeout: Int64 read FTimeout write FTimeout;
  end;

implementation

uses
  Http3.Constants,
  Http3.Frames,
  Qpack.Decoder,
  Qpack.Encoder,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.Streams,
  Quic.StreamTable;

constructor THttp3Request.Create(Connection: THttp3ClientConnection; const Method, Scheme, Authority, Path: string;
  constref Headers: TQpackFieldList; EndRequest: Boolean);
var
  Fields: TQpackFieldList;
  Index: Integer;
  Section, Frame: TBytes;
  Error: LongInt;
  Written: Int64;
begin
  inherited Create;
  FConnection := Connection;
  FMethod := Method;
  FContentLength := -1;
  FTimeout := Connection.Quic.Timeout;
  FParser := THttp3FrameParser.Create(Http3MaximumFieldSectionSize + 1024);
  Error := Connection.LastError;
  if (Error = 0) and Connection.GoawayReceived then
    Error := Http3ErrorGoingAway;
  if Error = 0 then
    Error := Connection.Quic.OpenStream(True, FStreamId);
  if (Error = 0) and Connection.GoawayReceived and (FStreamId >= Connection.GoawayId) then
    Error := Http3ErrorGoingAway;
  if Error <> 0 then
    raise EQuicError.CreateCode(Error, Connection.ErrorDescription(Error));
  Fields := nil;
  AddField(Fields, ':method', Method);
  AddField(Fields, ':scheme', Scheme);
  AddField(Fields, ':authority', Authority);
  AddField(Fields, ':path', Path);
  for Index := 0 to High(Headers) do
    AddField(Fields, Headers[Index].Name, Headers[Index].Value);
  Section := EncodeFieldSection(Fields);
  Frame := MakeFrame(Http3FrameHeaders, @Section[0], Length(Section));
  Written := Connection.Quic.Write(FStreamId, @Frame[0], Length(Frame), EndRequest);
  FRequestEnded := EndRequest;
  if Written < 0 then
    raise EQuicError.CreateCode(LongInt(Written), Connection.ErrorDescription(LongInt(Written)));
end;

destructor THttp3Request.Destroy;
begin
  if not (FPhase in [ResponseDone, ResponseFailed]) and (FConnection.LastError = 0) then
    Cancel;
  FParser.Free;
  inherited Destroy;
end;

function THttp3Request.GetInterimCount: Integer;
begin
  Result := Length(FInterimStatuses);
end;

function THttp3Request.GetInterimStatus(Index: Integer): Integer;
begin
  Result := FInterimStatuses[Index];
end;

function THttp3Request.WriteBody(Data: Pointer; Length: PtrUInt): Int64;
var
  Header: TBytes;
begin
  if FRequestEnded then
    Exit(Http3ErrorInvalidState);
  if Length = 0 then
    Exit(0);
  Header := FrameHeader(Http3FrameData, Length);
  Result := FConnection.Quic.Write(FStreamId, @Header[0], System.Length(Header));
  if Result < 0 then
    Exit;
  Result := FConnection.Quic.Write(FStreamId, Data, Length);
end;

function THttp3Request.FinishRequest: LongInt;
begin
  if FRequestEnded then
    Exit(Http3ErrorNone);
  FRequestEnded := True;
  Result := FConnection.Quic.FinishStream(FStreamId);
end;

procedure THttp3Request.Cancel;
begin
  if FPhase in [ResponseDone, ResponseFailed] then
    Exit;
  FConnection.Quic.StopSending(FStreamId, Http3RequestCancelled);
  if not FRequestEnded then
    FConnection.Quic.ResetStream(FStreamId, Http3RequestCancelled);
  FConnection.Decoder.CancelStream(FStreamId);
  FPhase := ResponseFailed;
  if FError = 0 then
    FError := Http3ErrorInvalidState;
end;

function THttp3Request.Fail(Error: LongInt; StreamErrorCode: QWord): LongInt;
begin
  if FPhase <> ResponseFailed then
  begin
    if StreamErrorCode <> 0 then
    begin
      FConnection.Quic.StopSending(FStreamId, StreamErrorCode);
      FConnection.Quic.ResetStream(FStreamId, StreamErrorCode);
    end;
    FPhase := ResponseFailed;
    FError := Error;
  end;
  Result := FError;
end;

function FieldNameIsValid(const Name: string): Boolean;
var
  Index: Integer;
begin
  if Name = '' then
    Exit(False);
  for Index := 1 to Length(Name) do
    if Name[Index] in ['A'..'Z', #0..#32, #127] then
      Exit(False);
  Result := True;
end;

function FieldIsConnectionSpecific(const Name: string): Boolean;
begin
  Result := (Name = 'connection') or (Name = 'keep-alive') or (Name = 'proxy-connection') or
    (Name = 'transfer-encoding') or (Name = 'upgrade');
end;

function THttp3Request.AcceptHead(constref Fields: TQpackFieldList): LongInt;
var
  Index, Code: Integer;
  StatusText: string;
  SeenRegular, SeenStatus: Boolean;
  Regular: TQpackFieldList;
begin
  SeenRegular := False;
  SeenStatus := False;
  StatusText := '';
  Regular := nil;
  for Index := 0 to High(Fields) do
  begin
    if not FieldNameIsValid(Fields[Index].Name) then
      Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
    if Fields[Index].Name[1] = ':' then
    begin
      if SeenRegular or SeenStatus or (Fields[Index].Name <> ':status') then
        Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
      SeenStatus := True;
      StatusText := Fields[Index].Value;
      Continue;
    end;
    if FieldIsConnectionSpecific(Fields[Index].Name) then
      Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
    SeenRegular := True;
    SetLength(Regular, Length(Regular) + 1);
    Regular[High(Regular)] := Fields[Index];
  end;
  if not SeenStatus or (Length(StatusText) <> 3) or not TryStrToInt(StatusText, Code) or (Code < 100) or
     (Code > 599) then
    Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
  if Code < 200 then
  begin
    { Interim: noted, and the final head is still to come. }
    SetLength(FInterimStatuses, Length(FInterimStatuses) + 1);
    FInterimStatuses[High(FInterimStatuses)] := Code;
    Exit(Http3ErrorNone);
  end;
  FStatus := Code;
  FHeaders := Regular;
  StatusText := FieldValue(FHeaders, 'content-length');
  if StatusText <> '' then
    if not TryStrToInt64(StatusText, FContentLength) or (FContentLength < 0) then
      Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
  { Bodies that are never there whatever Content-Length says. }
  if (FMethod = 'HEAD') or (Code = 204) or (Code = 304) then
    FContentLength := -1;
  FPhase := ResponseBody;
  Result := Http3ErrorNone;
end;

function THttp3Request.AcceptTrailers(constref Fields: TQpackFieldList): LongInt;
var
  Index: Integer;
begin
  for Index := 0 to High(Fields) do
    if not FieldNameIsValid(Fields[Index].Name) or (Fields[Index].Name[1] = ':') then
      Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
  FTrailers := Copy(Fields);
  FPhase := ResponseTrailers;
  Result := Http3ErrorNone;
end;

function THttp3Request.HandleSection(Data: PByte; Length: PtrUInt): LongInt;
var
  Fields: TQpackFieldList;
  Code: QWord;
begin
  case FConnection.Decoder.DecodeFieldSection(FStreamId, Data, Length, Fields, Code) of
    DecodeBlocked:
      begin
        { Kept until the encoder stream brings the entries. }
        SetLength(FPendingSection, Length);
        Move(Data^, FPendingSection[0], Length);
        FHasPendingSection := True;
        Exit(Http3ErrorNone);
      end;
    DecodeFailed:
      begin
        FConnection.Fail(Code, 'a field section that does not decode');
        Exit(Fail(Http3ErrorConnection, 0));
      end;
  end;
  FHasPendingSection := False;
  FPendingSection := nil;
  if FPhase = ResponseHead then
    Result := AcceptHead(Fields)
  else
    Result := AcceptTrailers(Fields);
end;

{ Reads what the stream has into the parser, waiting until Deadline;
  ends the response at the stream's end. }
function THttp3Request.FillParser(Deadline: Int64): LongInt;
var
  Buffer: array[0..16383] of Byte;
  Count: Int64;
  Stream: PQuicStream;
begin
  while True do
  begin
    Count := FConnection.Quic.ReadWithin(FStreamId, @Buffer[0], SizeOf(Buffer), 0);
    if Count > 0 then
    begin
      FParser.Append(@Buffer[0], Count);
      Exit(Http3ErrorNone);
    end;
    if Count = 0 then
    begin
      { The end of the stream. }
      if not FParser.AtFrameBoundary then
      begin
        FConnection.Fail(Http3FrameError, 'a frame cut short by the end of the stream');
        Exit(Fail(Http3ErrorConnection, 0));
      end;
      if FPhase = ResponseHead then
        Exit(Fail(Http3ErrorIncomplete, 0));
      if (FContentLength >= 0) and (FBodyReceived <> QWord(FContentLength)) then
        Exit(Fail(Http3ErrorMalformedResponse, 0));
      FPhase := ResponseDone;
      Exit(Http3ErrorNone);
    end;
    if Count = QuicErrorStreamReset then
    begin
      Stream := FindStream(FConnection.Quic.State, FStreamId);
      if Stream <> nil then
        FResetCode := Stream^.PeerResetCode;
      FConnection.Decoder.CancelStream(FStreamId);
      Exit(Fail(Http3ErrorRequestReset, 0));
    end;
    if Count <> QuicErrorTimedOut then
      Exit(Fail(LongInt(Count), 0));
    Count := FConnection.WaitForProgress(Deadline);
    if Count <> 0 then
      Exit(Fail(LongInt(Count), 0));
  end;
end;

{ A blocked field section waits for the encoder stream; otherwise
  more of the request stream is read. }
function THttp3Request.WaitForMore(Deadline: Int64): LongInt;
begin
  if not FHasPendingSection then
    Exit(FillParser(Deadline));
  Result := FConnection.WaitForProgress(Deadline);
  if Result <> 0 then
    Result := Fail(Result, 0);
end;

{ Moves the response on: frames out of the parser until a piece of body
  went into Buffer, the head or the end came, or more is needed. }
function THttp3Request.Advance(Buffer: PByte; Capacity: PtrUInt; out Delivered: PtrUInt): LongInt;
var
  FrameType: QWord;
  Data: PByte;
  Length, Take: PtrUInt;
  Outcome: THttp3ParseResult;
  Before: THttp3ResponsePhase;
begin
  Delivered := 0;
  Result := Http3ErrorNone;
  while FPhase in [ResponseHead, ResponseBody, ResponseTrailers] do
  begin
    if FHasPendingSection then
    begin
      Before := FPhase;
      Result := HandleSection(@FPendingSection[0], System.Length(FPendingSection));
      if (Result <> 0) or FHasPendingSection or (FPhase <> Before) then
        Exit;
      Continue;
    end;
    Outcome := FParser.Next(FrameType, Data, Length);
    case Outcome of
      ParseNeedMore:
        Exit(Http3ErrorNone);
      ParseFrameTooLarge:
        Exit(Fail(Http3ErrorMalformedResponse, Http3ExcessiveLoad));
      ParseData:
        begin
          if FPhase <> ResponseBody then
          begin
            FConnection.Fail(Http3FrameUnexpected, 'DATA outside a response body');
            Exit(Fail(Http3ErrorConnection, 0));
          end;
          FBodyReceived := FBodyReceived + Length;
          if (FContentLength >= 0) and (FBodyReceived > QWord(FContentLength)) then
            Exit(Fail(Http3ErrorMalformedResponse, Http3MessageError));
          Take := Length;
          if Take > Capacity then
            Take := Capacity;
          Move(Data^, Buffer^, Take);
          Delivered := Take;
          if Take < Length then
          begin
            SetLength(FLeftover, Length - Take);
            Move(Data[Take], FLeftover[0], Length - Take);
            FLeftoverStart := 0;
          end;
          Exit(Http3ErrorNone);
        end;
      ParseFrame:
        case FrameType of
          Http3FrameHeaders:
            begin
              if FPhase = ResponseTrailers then
              begin
                FConnection.Fail(Http3FrameUnexpected, 'HEADERS after the trailers');
                Exit(Fail(Http3ErrorConnection, 0));
              end;
              Before := FPhase;
              Result := HandleSection(Data, Length);
              if (Result <> 0) or (FPhase <> Before) then
                Exit;
            end;
          Http3FramePushPromise:
            begin
              FConnection.Fail(Http3IdError, 'PUSH_PROMISE without MAX_PUSH_ID');
              Exit(Fail(Http3ErrorConnection, 0));
            end;
        else
          begin
            FConnection.Fail(Http3FrameUnexpected, 'a frame not allowed on a request stream');
            Exit(Fail(Http3ErrorConnection, 0));
          end;
        end;
    end;
  end;
end;

function THttp3Request.ReadHead: LongInt;
var
  Delivered: PtrUInt;
  Deadline: Int64;
begin
  if FPhase = ResponseFailed then
    Exit(FError);
  Deadline := QuicMilliseconds + FTimeout;
  while FPhase = ResponseHead do
  begin
    Result := Advance(nil, 0, Delivered);
    if Result <> 0 then
      Exit;
    if FPhase <> ResponseHead then
      Break;
    Result := WaitForMore(Deadline);
    if Result <> 0 then
      Exit;
  end;
  if FPhase = ResponseFailed then
    Exit(FError);
  Result := Http3ErrorNone;
end;

function THttp3Request.ReadBody(Buffer: Pointer; Capacity: PtrUInt): Int64;
var
  Delivered, Take: PtrUInt;
  Deadline: Int64;
  Error: LongInt;
begin
  if FPhase = ResponseHead then
  begin
    Error := ReadHead;
    if Error <> 0 then
      Exit(Error);
  end;
  if FLeftoverStart < Length(FLeftover) then
  begin
    Take := Length(FLeftover) - FLeftoverStart;
    if Take > Capacity then
      Take := Capacity;
    Move(FLeftover[FLeftoverStart], Buffer^, Take);
    FLeftoverStart := FLeftoverStart + Integer(Take);
    if FLeftoverStart >= Length(FLeftover) then
    begin
      FLeftover := nil;
      FLeftoverStart := 0;
    end;
    Exit(Take);
  end;
  Deadline := QuicMilliseconds + FTimeout;
  while True do
  begin
    if FPhase = ResponseFailed then
      Exit(FError);
    if FPhase = ResponseDone then
      Exit(0);
    Error := Advance(Buffer, Capacity, Delivered);
    if Error <> 0 then
      Exit(Error);
    if Delivered > 0 then
      Exit(Delivered);
    if FPhase in [ResponseDone, ResponseFailed] then
      Continue;
    Error := WaitForMore(Deadline);
    if Error <> 0 then
      Exit(Error);
  end;
end;

function THttp3Request.ReadAll(out Body: string): LongInt;
var
  Buffer: array[0..16383] of Byte;
  Count: Int64;
  Chunk: string;
begin
  Body := '';
  repeat
    Count := ReadBody(@Buffer[0], SizeOf(Buffer));
    if Count > 0 then
    begin
      SetString(Chunk, PChar(@Buffer[0]), Count);
      Body := Body + Chunk;
    end;
  until Count <= 0;
  if Count < 0 then
    Exit(LongInt(Count));
  Result := Http3ErrorNone;
end;

end.
