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
  The test's HTTP/3 server, over the test QUIC server's connection: a
  control stream with SETTINGS (a 4 KiB QPACK table, so a client's
  encoder may use it), QPACK encoder and decoder streams, the client's
  control and QPACK streams read, and requests answered one after the
  other:

    /hello          "Hello, HTTP/3!"
    /size/N         N bytes of a pattern, in 16 KiB DATA frames
    /echo           the request body back, with a trailer x-body-length
    /status/N       status N, no body
    /interim        103 first, then 200 "ok"
    /dynamic        a head that refers to a dynamic table entry the
                    encoder stream inserts only 100 ms later (the client
                    must wait for it)
    /malformed      a :status of four digits
    /reset          the stream reset with H3_REQUEST_REJECTED
    /goaway         "ok", then GOAWAY: no requests after this one
    /headers        the request's fields, one per line
}
unit QuicTest.Http3Server;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  QuicTest.Server;

procedure InstallHttp3Server(Server: TTestServer);

implementation

uses
  SysUtils,
  Http3.Constants,
  Http3.FrameParser,
  Http3.Frames,
  Qpack.Decoder,
  Qpack.Encoder,
  Qpack.StaticTable,
  Quic.Connections,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.Streams;

type
  TUniStream = record
    Id: QWord;
    StreamType: Integer;
    Parser: THttp3FrameParser;
  end;

  THttp3TestServer = class
    Server: TTestServer;
    Connection: TQuicConnection;
    Decoder: TQpackDecoder;
    ControlStream, EncoderStream, DecoderStream: QWord;
    UniStreams: array of TUniStream;
    GoawaySent: Boolean;
    procedure ServiceUniStreams;
    function SendFrame(StreamId: QWord; FrameType: QWord; Data: PByte; Length: PtrUInt; Fin: Boolean): Boolean;
    procedure SendHead(StreamId: QWord; constref Fields: TQpackFieldList; Fin: Boolean);
    procedure SendBody(StreamId: QWord; Data: PByte; Length: PtrUInt);
    procedure Answer(StreamId: QWord; constref Request: TQpackFieldList; const Body: string);
    procedure ServeRequest(StreamId: QWord);
    procedure Run;
  end;

function OpenUni(Connection: TQuicConnection; StreamType: Byte): QWord;
begin
  Connection.OpenStream(False, Result);
  Connection.Write(Result, @StreamType, 1);
end;

procedure THttp3TestServer.ServiceUniStreams;
var
  StreamId: QWord;
  Index: Integer;
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  Offset: Integer;
  FrameType: QWord;
  Data: PByte;
  Length: PtrUInt;
  Settings: THttp3Settings;
begin
  for Index := 0 to High(UniStreams) do
    while True do
    begin
      Count := Connection.ReadWithin(UniStreams[Index].Id, @Buffer[0], SizeOf(Buffer), 0);
      if Count <= 0 then
        Break;
      Offset := 0;
      if UniStreams[Index].StreamType < 0 then
      begin
        UniStreams[Index].StreamType := Buffer[0];
        Offset := 1;
        if UniStreams[Index].StreamType = Http3StreamControl then
          UniStreams[Index].Parser := THttp3FrameParser.Create(65536);
      end;
      case UniStreams[Index].StreamType of
        Http3StreamControl:
          begin
            UniStreams[Index].Parser.Append(@Buffer[Offset], Count - Offset);
            while UniStreams[Index].Parser.Next(FrameType, Data, Length) = ParseFrame do
              if FrameType = Http3FrameSettings then
                if not DecodeSettings(Data, Length, Settings) then
                  Server.Failure := 'the client''s SETTINGS do not decode';
          end;
        Http3StreamQpackEncoder:
          if Decoder.ProcessEncoderStream(@Buffer[Offset], Count - Offset) <> 0 then
            Server.Failure := 'the client''s encoder stream is malformed';
      end;
    end;
  { New streams of the client. }
  while Connection.AcceptStream(StreamId, 0) = QuicErrorNone do
  begin
    if StreamIsBidirectional(StreamId) then
    begin
      ServeRequest(StreamId);
      Continue;
    end;
    Index := System.Length(UniStreams);
    SetLength(UniStreams, Index + 1);
    UniStreams[Index].Id := StreamId;
    UniStreams[Index].StreamType := -1;
    UniStreams[Index].Parser := nil;
  end;
end;

function THttp3TestServer.SendFrame(StreamId: QWord; FrameType: QWord; Data: PByte; Length: PtrUInt;
  Fin: Boolean): Boolean;
var
  Frame: TBytes;
begin
  Frame := MakeFrame(FrameType, Data, Length);
  Result := Connection.Write(StreamId, @Frame[0], System.Length(Frame), Fin) >= 0;
end;

procedure THttp3TestServer.SendHead(StreamId: QWord; constref Fields: TQpackFieldList; Fin: Boolean);
var
  Section: TBytes;
begin
  Section := EncodeFieldSection(Fields);
  SendFrame(StreamId, Http3FrameHeaders, @Section[0], Length(Section), Fin);
end;

procedure THttp3TestServer.SendBody(StreamId: QWord; Data: PByte; Length: PtrUInt);
var
  Piece: PtrUInt;
begin
  while Length > 0 do
  begin
    Piece := Length;
    if Piece > 16384 then
      Piece := 16384;
    SendFrame(StreamId, Http3FrameData, Data, Piece, False);
    Data := Data + Piece;
    Length := Length - Piece;
  end;
end;

procedure THttp3TestServer.Answer(StreamId: QWord; constref Request: TQpackFieldList; const Body: string);
var
  Path, Text: string;
  Fields, Trailer: TQpackFieldList;
  Size, Index: Integer;
  Data: array of Byte;
  DynamicSection: array[0..3] of Byte;
  Instructions: array of Byte;
  Started: Int64;
  Identifier: array[0..7] of Byte;
  Count: Integer;
begin
  Path := FieldValue(Request, ':path');
  Fields := nil;
  Trailer := nil;
  if Path = '/hello' then
  begin
    AddField(Fields, ':status', '200');
    AddField(Fields, 'content-type', 'text/plain');
    AddField(Fields, 'content-length', '14');
    SendHead(StreamId, Fields, False);
    Text := 'Hello, HTTP/3!';
    SendBody(StreamId, PByte(PChar(Text)), Length(Text));
  end
  else if Copy(Path, 1, 6) = '/size/' then
  begin
    Size := StrToIntDef(Copy(Path, 7, 20), 0);
    AddField(Fields, ':status', '200');
    AddField(Fields, 'content-length', IntToStr(Size));
    SendHead(StreamId, Fields, False);
    Data := nil;
    SetLength(Data, Size + 1);
    for Index := 0 to Size - 1 do
      Data[Index] := Byte((Index * 7 + 3) and $FF);
    SendBody(StreamId, @Data[0], Size);
  end
  else if Path = '/echo' then
  begin
    AddField(Fields, ':status', '200');
    SendHead(StreamId, Fields, False);
    SendBody(StreamId, PByte(PChar(Body)), Length(Body));
    AddField(Trailer, 'x-body-length', IntToStr(Length(Body)));
    SendHead(StreamId, Trailer, True);
    Exit;
  end
  else if Copy(Path, 1, 8) = '/status/' then
  begin
    AddField(Fields, ':status', Copy(Path, 9, 3));
    SendHead(StreamId, Fields, True);
    Exit;
  end
  else if Path = '/interim' then
  begin
    AddField(Fields, ':status', '103');
    AddField(Fields, 'link', '</style.css>; rel=preload');
    SendHead(StreamId, Fields, False);
    Fields := nil;
    AddField(Fields, ':status', '200');
    SendHead(StreamId, Fields, False);
    SendBody(StreamId, PByte(PChar('ok')), 2);
  end
  else if Path = '/dynamic' then
  begin
    { Required Insert Count 1 (encoded 2), Base 1, :status 200 (static
      25), then dynamic entry 0. }
    DynamicSection[0] := $02;
    DynamicSection[1] := $00;
    DynamicSection[2] := $C0 or 25;
    DynamicSection[3] := $80;
    SendFrame(StreamId, Http3FrameHeaders, @DynamicSection[0], 4, False);
    SendFrame(StreamId, Http3FrameData, PByte(PChar('dynamic')), 7, True);
    Started := QuicMilliseconds;
    while QuicMilliseconds - Started < 100 do
      Connection.Pump(20);
    { Set Dynamic Table Capacity 4096, Insert With Literal Name
      x-dynamic: yes. }
    Text := #$3f#$e1#$1f + #$49 + 'x-dynamic' + #$03 + 'yes';
    Instructions := nil;
    SetLength(Instructions, Length(Text));
    Move(Text[1], Instructions[0], Length(Text));
    Connection.Write(EncoderStream, @Instructions[0], Length(Instructions));
    Exit;
  end
  else if Path = '/malformed' then
  begin
    AddField(Fields, ':status', '2000');
    SendHead(StreamId, Fields, True);
    Exit;
  end
  else if Path = '/reset' then
  begin
    Connection.ResetStream(StreamId, Http3RequestRejected);
    Exit;
  end
  else if Path = '/goaway' then
  begin
    AddField(Fields, ':status', '200');
    SendHead(StreamId, Fields, False);
    SendBody(StreamId, PByte(PChar('ok')), 2);
    Connection.FinishStream(StreamId);
    { GOAWAY with the next request stream's ID. }
    Count := 8;
    Identifier[0] := $C0;
    for Index := 1 to 7 do
      Identifier[Index] := Byte((StreamId + 4) shr (8 * (7 - Index)));
    SendFrame(ControlStream, Http3FrameGoaway, @Identifier[0], Count, False);
    GoawaySent := True;
    Exit;
  end
  else if Path = '/headers' then
  begin
    Text := '';
    for Index := 0 to High(Request) do
      Text := Text + Request[Index].Name + ': ' + Request[Index].Value + #10;
    AddField(Fields, ':status', '200');
    SendHead(StreamId, Fields, False);
    SendBody(StreamId, PByte(PChar(Text)), Length(Text));
  end
  else
  begin
    AddField(Fields, ':status', '404');
    SendHead(StreamId, Fields, False);
    SendBody(StreamId, PByte(PChar('not found')), 9);
  end;
  Connection.FinishStream(StreamId);
end;

procedure THttp3TestServer.ServeRequest(StreamId: QWord);
var
  Parser: THttp3FrameParser;
  Buffer: array[0..16383] of Byte;
  Count: Int64;
  FrameType, Error: QWord;
  Data: PByte;
  Length: PtrUInt;
  Fields: TQpackFieldList;
  Section: TBytes;
  HaveHead, Ended: Boolean;
  Body, Piece: string;
  Deadline: Int64;
begin
  Parser := THttp3FrameParser.Create(65536);
  try
    HaveHead := False;
    Ended := False;
    Section := nil;
    Body := '';
    Deadline := QuicMilliseconds + Server.Patience;
    while not Ended do
    begin
      Count := Connection.ReadWithin(StreamId, @Buffer[0], SizeOf(Buffer), 0);
      if Count > 0 then
        Parser.Append(@Buffer[0], Count)
      else if Count = 0 then
        Ended := True
      else if Count = QuicErrorTimedOut then
      begin
        if QuicMilliseconds > Deadline then
          Exit;
        Connection.Pump(50);
        ServiceUniStreams;
        Continue;
      end
      else
        Exit;
      while True do
        case Parser.Next(FrameType, Data, Length) of
          ParseData:
            begin
              SetString(Piece, PChar(Data), Length);
              Body := Body + Piece;
            end;
          ParseFrame:
            if (FrameType = Http3FrameHeaders) and not HaveHead then
            begin
              SetLength(Section, Length);
              Move(Data^, Section[0], Length);
              HaveHead := True;
            end;
        else
          Break;
        end;
    end;
    if not HaveHead then
      Exit;
    { The client's encoder may have used its dynamic table. }
    while True do
      case Decoder.DecodeFieldSection(StreamId, @Section[0], System.Length(Section), Fields, Error) of
        DecodeDone:
          Break;
        DecodeFailed:
          begin
            Server.Failure := 'a request head does not decode';
            Exit;
          end;
        DecodeBlocked:
          begin
            if QuicMilliseconds > Deadline then
              Exit;
            Connection.Pump(50);
            ServiceUniStreams;
          end;
      end;
    Section := Decoder.TakeDecoderStreamBytes;
    if System.Length(Section) > 0 then
      Connection.Write(DecoderStream, @Section[0], System.Length(Section));
    Inc(Server.StreamsServed);
    Answer(StreamId, Fields, Body);
  finally
    Parser.Free;
  end;
end;

procedure THttp3TestServer.Run;
var
  Settings: THttp3Settings;
  Frame: TBytes;
  Index: Integer;
begin
  Decoder := TQpackDecoder.Create(4096, 16);
  try
    ControlStream := OpenUni(Connection, Http3StreamControl);
    Settings.QpackMaxTableCapacity := 4096;
    Settings.QpackBlockedStreams := 16;
    Settings.MaxFieldSectionSize := 0;
    Frame := EncodeSettings(Settings);
    Connection.Write(ControlStream, @Frame[0], Length(Frame));
    EncoderStream := OpenUni(Connection, Http3StreamQpackEncoder);
    DecoderStream := OpenUni(Connection, Http3StreamQpackDecoder);
    { Until the client goes. }
    while Connection.LastError = QuicErrorNone do
    begin
      Connection.Pump(50);
      ServiceUniStreams;
    end;
  finally
    for Index := 0 to High(UniStreams) do
      UniStreams[Index].Parser.Free;
    Decoder.Free;
  end;
end;

procedure ServeHttp3(Server: TTestServer; Connection: TQuicConnection);
var
  Handler: THttp3TestServer;
begin
  Handler := THttp3TestServer.Create;
  try
    Handler.Server := Server;
    Handler.Connection := Connection;
    Handler.Run;
  finally
    Handler.Free;
  end;
end;

procedure InstallHttp3Server(Server: TTestServer);
begin
  Server.Http3Handler := @ServeHttp3;
end;

end.
