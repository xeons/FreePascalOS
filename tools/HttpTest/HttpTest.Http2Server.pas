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
  A small HTTP/2 server for the loopback test, in a thread, on one pipe
  transport. It keeps its receive window at the default 65535 (so a
  client sending more must wait for its WINDOW_UPDATEs) and honours the
  client's windows when sending (so a body larger than the client's
  window needs the client's WINDOW_UPDATEs). Paths:

    /hello         "hello" with content-length (HEAD: the head only)
    /big           3 MiB, more than a stream's window
    /echo          the method and the request's content back
    /trailers      "body" then trailers
    /reset         RST_STREAM REFUSED_STREAM
    /malformed     a response with an upper case field name
    /continuation  a 30000-byte field value (HEADERS and CONTINUATION)
    /priority      the Priority field the request carried
    /hold          answered only after /release came (out of order)
    /release       answered at once, then /hold
    /goaway        GOAWAY naming the stream before it
    /count         how many requests this connection carried
    /redirect      302 to /hello
    /cache         as the HTTP/1.1 server's
}
unit HttpTest.Http2Server;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Classes,
  SysUtils,
  Http.ByteBuffers,
  Http.HpackDecoder,
  Http.HpackEncoder,
  Http.Http2Frames,
  Http.Transports;

type
  TTestStream = record
    Id: LongWord;
    Method, Path, Priority, Body, IfNoneMatch: string;
    Pending: string;
    PendingEnd: Boolean;
    SendWindow: Int64;
    Active: Boolean;
  end;

  THttp2TestServer = class(TThread)
  private
    FTransport: THttpTransport;
    FInput: THttpByteBuffer;
    FDecoder: THpackDecoder;
    FEncoder: THpackEncoder;
    FStreams: array of TTestStream;
    FConnectionWindow: Int64;
    FPeerInitialWindow: Int64;
    FHeaderBlock: THttpByteBuffer;
    FHeaderStream: LongWord;
    FHeaderEnd: Boolean;
    FHeldStream: LongWord;
    FRequests: Integer;
    FDone: Boolean;
    function StreamIndex(Id: LongWord): Integer;
    procedure Send(var Frames: THttpByteBuffer);
    procedure SendHeaders(Id: LongWord; const Status: string; const Extra: array of string; EndStream: Boolean);
    procedure Queue(Id: LongWord; const Data: string);
    procedure FlushPending;
    procedure Respond(Index: Integer);
    procedure HeaderBlockDone(Id: LongWord; EndStream: Boolean);
    procedure HandleFrame(constref Header: THttp2FrameHeader; Payload: PByte);
  protected
    procedure Execute; override;
  public
    constructor Create(Transport: THttpTransport);
    destructor Destroy; override;
  end;

implementation

uses
  Http.HpackTables;

const
  BigSize = 3 * 1024 * 1024;

constructor THttp2TestServer.Create(Transport: THttpTransport);
begin
  FTransport := Transport;
  FDecoder := THpackDecoder.Create;
  FEncoder := THpackEncoder.Create;
  FConnectionWindow := DefaultInitialWindowSize;
  FPeerInitialWindow := DefaultInitialWindowSize;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor THttp2TestServer.Destroy;
begin
  FDecoder.Free;
  FEncoder.Free;
  inherited Destroy;
end;

function THttp2TestServer.StreamIndex(Id: LongWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FStreams) do
    if FStreams[Index].Id = Id then
      Exit(Index);
  SetLength(FStreams, Length(FStreams) + 1);
  Result := High(FStreams);
  FStreams[Result] := Default(TTestStream);
  FStreams[Result].Id := Id;
  FStreams[Result].SendWindow := FPeerInitialWindow;
  FStreams[Result].Active := True;
end;

procedure THttp2TestServer.Send(var Frames: THttpByteBuffer);
begin
  if Frames.Length > 0 then
    FTransport.Write(@Frames.Data[0], Frames.Length);
  ClearBuffer(Frames);
end;

procedure THttp2TestServer.SendHeaders(Id: LongWord; const Status: string; const Extra: array of string;
  EndStream: Boolean);
var
  Fields: THpackHeaderList;
  Block, Frames: THttpByteBuffer;
  Index: Integer;
begin
  Fields := nil;
  if Status <> '' then
  begin
    SetLength(Fields, 1);
    Fields[0].Name := ':status';
    Fields[0].Value := Status;
  end;
  Index := 0;
  while Index < High(Extra) do
  begin
    SetLength(Fields, Length(Fields) + 1);
    Fields[High(Fields)].Name := Extra[Index];
    Fields[High(Fields)].Value := Extra[Index + 1];
    Inc(Index, 2);
  end;
  Block := Default(THttpByteBuffer);
  Frames := Default(THttpByteBuffer);
  FEncoder.Encode(Fields, Block);
  AppendHeaderBlock(Frames, Id, @Block.Data[0], Block.Length, EndStream, DefaultMaximumFrameSize);
  Send(Frames);
end;

procedure THttp2TestServer.Queue(Id: LongWord; const Data: string);
var
  Index: Integer;
begin
  Index := StreamIndex(Id);
  FStreams[Index].Pending := FStreams[Index].Pending + Data;
  FStreams[Index].PendingEnd := True;
  FlushPending;
end;

procedure THttp2TestServer.FlushPending;
var
  Index: Integer;
  Count: Int64;
  Frames: THttpByteBuffer;
begin
  Frames := Default(THttpByteBuffer);
  for Index := 0 to High(FStreams) do
    while FStreams[Index].Active and FStreams[Index].PendingEnd do
    begin
      Count := Length(FStreams[Index].Pending);
      if Count > DefaultMaximumFrameSize then
        Count := DefaultMaximumFrameSize;
      if Count > FStreams[Index].SendWindow then
        Count := FStreams[Index].SendWindow;
      if Count > FConnectionWindow then
        Count := FConnectionWindow;
      if (Count = 0) and (FStreams[Index].Pending <> '') then
        Break;
      AppendDataFrame(Frames, FStreams[Index].Id, PChar(FStreams[Index].Pending), Count,
        Count = Length(FStreams[Index].Pending));
      Dec(FStreams[Index].SendWindow, Count);
      Dec(FConnectionWindow, Count);
      Delete(FStreams[Index].Pending, 1, Count);
      if FStreams[Index].Pending = '' then
      begin
        FStreams[Index].PendingEnd := False;
        FStreams[Index].Active := False;
      end;
      Send(Frames);
    end;
end;

procedure THttp2TestServer.Respond(Index: Integer);
var
  Stream: TTestStream;
  Frames: THttpByteBuffer;
  Big: string;
  Position: Integer;
  HeldIndex: Integer;
begin
  Inc(FRequests);
  Stream := FStreams[Index];
  Frames := Default(THttpByteBuffer);
  if Stream.Path = '/hello' then
  begin
    if Stream.Method = 'HEAD' then
      SendHeaders(Stream.Id, '200', ['content-length', '5'], True)
    else
    begin
      SendHeaders(Stream.Id, '200', ['content-length', '5', 'content-type', 'text/plain'], False);
      Queue(Stream.Id, 'hello');
    end;
  end
  else if Stream.Path = '/big' then
  begin
    SetLength(Big, BigSize);
    for Position := 1 to BigSize do
      Big[Position] := Chr(Ord('a') + Position mod 26);
    SendHeaders(Stream.Id, '200', ['content-length', IntToStr(BigSize)], False);
    Queue(Stream.Id, Big);
  end
  else if Stream.Path = '/echo' then
  begin
    SendHeaders(Stream.Id, '200', [], False);
    Queue(Stream.Id, Stream.Method + ' ' + Stream.Body);
  end
  else if Stream.Path = '/trailers' then
  begin
    SendHeaders(Stream.Id, '200', [], False);
    AppendDataFrame(Frames, Stream.Id, PChar('body'), 4, False);
    Send(Frames);
    SendHeaders(Stream.Id, '', ['x-checksum', 'abc'], True);
    FStreams[Index].Active := False;
  end
  else if Stream.Path = '/reset' then
  begin
    AppendResetStream(Frames, Stream.Id, ErrorRefusedStream);
    Send(Frames);
    FStreams[Index].Active := False;
  end
  else if Stream.Path = '/malformed' then
    SendHeaders(Stream.Id, '200', ['X-Upper', 'no'], True)
  else if Stream.Path = '/continuation' then
  begin
    SetLength(Big, 30000);
    for Position := 1 to 30000 do
      Big[Position] := Chr(33 + (Position * 7919) mod 90);
    SendHeaders(Stream.Id, '200', ['x-large', Big, 'content-length', '2'], False);
    Queue(Stream.Id, 'ok');
  end
  else if Stream.Path = '/priority' then
  begin
    SendHeaders(Stream.Id, '200', [], False);
    Queue(Stream.Id, Stream.Priority);
  end
  else if Stream.Path = '/hold' then
    FHeldStream := Stream.Id
  else if Stream.Path = '/release' then
  begin
    SendHeaders(Stream.Id, '200', [], False);
    Queue(Stream.Id, 'released');
    if FHeldStream <> 0 then
    begin
      HeldIndex := StreamIndex(FHeldStream);
      SendHeaders(FHeldStream, '200', [], False);
      Queue(FStreams[HeldIndex].Id, 'held');
      FHeldStream := 0;
    end;
  end
  else if Stream.Path = '/goaway' then
  begin
    AppendGoAway(Frames, Stream.Id - 2, ErrorNoError, 'going');
    Send(Frames);
  end
  else if Stream.Path = '/count' then
  begin
    SendHeaders(Stream.Id, '200', [], False);
    Queue(Stream.Id, IntToStr(FRequests));
  end
  else if Stream.Path = '/redirect' then
    SendHeaders(Stream.Id, '302', ['location', '/hello', 'content-length', '0'], True)
  else if Stream.Path = '/cache' then
  begin
    if Stream.IfNoneMatch = '"v1"' then
      SendHeaders(Stream.Id, '304', ['etag', '"v1"', 'cache-control', 'max-age=60'], True)
    else
    begin
      SendHeaders(Stream.Id, '200', ['etag', '"v1"', 'cache-control', 'max-age=60'], False);
      Queue(Stream.Id, 'cached ' + IntToStr(FRequests));
    end;
  end
  else
  begin
    SendHeaders(Stream.Id, '404', [], False);
    Queue(Stream.Id, 'not found');
  end;
end;

procedure THttp2TestServer.HeaderBlockDone(Id: LongWord; EndStream: Boolean);
var
  Fields: THpackHeaderList;
  Field: THpackHeaderField;
  Index: Integer;
begin
  Fields := nil;
  FDecoder.Decode(@FHeaderBlock.Data[0], FHeaderBlock.Length, Fields);
  Index := StreamIndex(Id);
  for Field in Fields do
    if Field.Name = ':method' then
      FStreams[Index].Method := Field.Value
    else if Field.Name = ':path' then
      FStreams[Index].Path := Field.Value
    else if Field.Name = 'priority' then
      FStreams[Index].Priority := Field.Value
    else if Field.Name = 'if-none-match' then
      FStreams[Index].IfNoneMatch := Field.Value;
  if EndStream then
    Respond(Index);
end;

procedure THttp2TestServer.HandleFrame(constref Header: THttp2FrameHeader; Payload: PByte);
var
  Frames: THttpByteBuffer;
  Settings: THttp2SettingArray;
  Setting: THttp2Setting;
  Increment: LongWord;
  Index: Integer;
  Text: string;
  ContentStart, ContentCount: LongWord;
begin
  Frames := Default(THttpByteBuffer);
  case Header.FrameType of
    FrameSettings:
      if (Header.Flags and FlagAck) = 0 then
      begin
        ParseSettings(Payload, Header.Length, Settings);
        for Setting in Settings do
          if Setting.Identifier = SettingInitialWindowSize then
            FPeerInitialWindow := Setting.Value;
        AppendSettingsAck(Frames);
        Send(Frames);
      end;
    FrameWindowUpdate:
      begin
        ParseWindowUpdate(Payload, Header.Length, Increment);
        if Header.StreamId = 0 then
          Inc(FConnectionWindow, Increment)
        else
        begin
          Index := StreamIndex(Header.StreamId);
          Inc(FStreams[Index].SendWindow, Increment);
        end;
        FlushPending;
      end;
    FrameHeaders:
      begin
        FramePayloadContent(Header, Payload, ContentStart, ContentCount);
        ClearBuffer(FHeaderBlock);
        AppendBytes(FHeaderBlock, Payload + ContentStart, ContentCount);
        FHeaderEnd := (Header.Flags and FlagEndStream) <> 0;
        if (Header.Flags and FlagEndHeaders) <> 0 then
          HeaderBlockDone(Header.StreamId, FHeaderEnd)
        else
          FHeaderStream := Header.StreamId;
      end;
    FrameContinuation:
      begin
        AppendBytes(FHeaderBlock, Payload, Header.Length);
        if (Header.Flags and FlagEndHeaders) <> 0 then
          HeaderBlockDone(FHeaderStream, FHeaderEnd);
      end;
    FrameData:
      begin
        Index := StreamIndex(Header.StreamId);
        SetString(Text, PChar(Payload), Header.Length);
        FStreams[Index].Body := FStreams[Index].Body + Text;
        if Header.Length > 0 then
        begin
          AppendWindowUpdate(Frames, 0, Header.Length);
          AppendWindowUpdate(Frames, Header.StreamId, Header.Length);
          Send(Frames);
        end;
        if (Header.Flags and FlagEndStream) <> 0 then
          Respond(Index);
      end;
    FrameResetStream:
      begin
        Index := StreamIndex(Header.StreamId);
        FStreams[Index].Active := False;
        FStreams[Index].PendingEnd := False;
      end;
    FramePing:
      if (Header.Flags and FlagAck) = 0 then
      begin
        AppendPing(Frames, True, Payload);
        Send(Frames);
      end;
    FrameGoAway:
      FDone := True;
  end;
end;

procedure THttp2TestServer.Execute;
var
  Buffer: array[0..16383] of Byte;
  Count: Int64;
  Header: THttp2FrameHeader;
  Frames: THttpByteBuffer;
  Offset: Integer;
  Preface: Boolean;
begin
  Frames := Default(THttpByteBuffer);
  AppendFrameHeader(Frames, 6, FrameSettings, 0, 0);
  AppendUInt16(Frames, SettingMaximumConcurrentStreams);
  AppendUInt32(Frames, 16);
  Send(Frames);
  Preface := False;
  while not FDone do
  begin
    Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Break;
    AppendBytes(FInput, @Buffer[0], Count);
    if not Preface then
    begin
      if FInput.Length < Length(Http2Preface) then
        Continue;
      if not CompareMem(@FInput.Data[0], PChar(Http2Preface), Length(Http2Preface)) then
        Break;
      ConsumeBuffer(FInput, Length(Http2Preface));
      Preface := True;
    end;
    Offset := 0;
    while FInput.Length - Offset >= FrameHeaderSize do
    begin
      Header := ReadFrameHeader(@FInput.Data[Offset]);
      if FInput.Length - Offset < Integer(FrameHeaderSize + Header.Length) then
        Break;
      HandleFrame(Header, @FInput.Data[Offset + FrameHeaderSize]);
      Inc(Offset, FrameHeaderSize + Header.Length);
    end;
    ConsumeBuffer(FInput, Offset);
  end;
  FTransport.Close;
end;

end.
