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
  A small WebSocket server for the tests (the server's side of RFC 6455
  written apart from libhttp's client, so the two check each other):
  it answers the handshake as the scenario says, unmasks the client's
  frames (and requires them masked), inflates and deflates with
  permessage-deflate when it was agreed, echoes messages, answers the
  close handshake and logs what it saw ("text:hello", "binary:3",
  "pong:abc", "close:1000:bye", "unmasked").

  Shared by tools/HttpTest and tools/WebLoadTest (whose test site hands
  ws: connections to it).
}
unit HttpTest.WebSocketServer;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Classes,
  SysUtils,
  Http.Transports;

type
  TWebSocketScenario = (
    { Accept, echo every message, answer pings, echo the close. }
    ScenarioEcho,
    { Accept, then send a ping, wait for its pong, then close 4001. }
    ScenarioServerCloses,
    { Accept, then send a text message that is not UTF-8. }
    ScenarioBadUtf8,
    { Answer 403. }
    ScenarioRefuse,
    { Answer 101 with a wrong Sec-WebSocket-Accept. }
    ScenarioWrongAccept);

  TWebSocketTestServer = class(TThread)
  private
    FTransport: THttpTransport;
    FScenario: TWebSocketScenario;
    FPending: TBytes;
    FLogLock: TRTLCriticalSection;
    FLog: TStringList;
    FRequestHead: string;
    FDeflate: Boolean;
    FProtocol: string;
    function Fill: Boolean;
    function ReadHead(out Head: string): Boolean;
    function ReadFrame(out Opcode: Byte; out Rsv1: Boolean; out Payload: TBytes): Boolean;
    procedure SendFrame(Opcode: Byte; Rsv1: Boolean; const Payload: TBytes);
    procedure SendText(const Text: string);
    procedure Note(const Line: string);
    procedure Serve;
  protected
    procedure Execute; override;
  public
    { Transport: the server's end of a pipe (not owned). Protocol: the
      subprotocol to choose when the client offers it ('' none). }
    constructor Create(Transport: THttpTransport; Scenario: TWebSocketScenario; const Protocol: string;
      Deflate: Boolean);
    destructor Destroy; override;
    function LogText: string;
    function RequestHead: string;
  end;

implementation

uses
  Http.WebSocketFrames,
  Http.WebSocketDeflate,
  Http.WebSocketHandshake;

constructor TWebSocketTestServer.Create(Transport: THttpTransport; Scenario: TWebSocketScenario;
  const Protocol: string; Deflate: Boolean);
begin
  FTransport := Transport;
  FScenario := Scenario;
  FProtocol := Protocol;
  FDeflate := Deflate;
  InitCriticalSection(FLogLock);
  FLog := TStringList.Create;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TWebSocketTestServer.Destroy;
begin
  FLog.Free;
  DoneCriticalSection(FLogLock);
  inherited Destroy;
end;

procedure TWebSocketTestServer.Note(const Line: string);
begin
  EnterCriticalSection(FLogLock);
  try
    FLog.Add(Line);
  finally
    LeaveCriticalSection(FLogLock);
  end;
end;

function TWebSocketTestServer.LogText: string;
begin
  EnterCriticalSection(FLogLock);
  try
    Result := FLog.CommaText;
  finally
    LeaveCriticalSection(FLogLock);
  end;
end;

function TWebSocketTestServer.RequestHead: string;
begin
  EnterCriticalSection(FLogLock);
  try
    Result := FRequestHead;
  finally
    LeaveCriticalSection(FLogLock);
  end;
end;

function TWebSocketTestServer.Fill: Boolean;
var
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  Old: Integer;
begin
  FTransport.TimeoutMilliseconds := 10000;
  Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
  if Count <= 0 then
    Exit(False);
  Old := Length(FPending);
  SetLength(FPending, Old + Count);
  Move(Buffer[0], FPending[Old], Count);
  Result := True;
end;

function TWebSocketTestServer.ReadHead(out Head: string): Boolean;
var
  Text: string;
  Ending: Integer;
begin
  Head := '';
  repeat
    SetString(Text, PChar(PByte(FPending)), Length(FPending));
    Ending := Pos(#13#10#13#10, Text);
    if Ending > 0 then
    begin
      Head := Copy(Text, 1, Ending + 3);
      FPending := Copy(FPending, Ending + 3, MaxInt);
      Exit(True);
    end;
  until not Fill;
  Result := False;
end;

function TWebSocketTestServer.ReadFrame(out Opcode: Byte; out Rsv1: Boolean; out Payload: TBytes): Boolean;
var
  Header: TWebSocketFrameHeader;
  HeaderLength: Integer;
  Message: TBytes;
  First: Boolean;
begin
  Message := nil;
  First := True;
  Opcode := 0;
  Rsv1 := False;
  repeat
    while ParseWebSocketFrameHeader(PByte(FPending), Length(FPending), Header, HeaderLength) = HeaderIncomplete do
      if not Fill then
        Exit(False);
    while QWord(Length(FPending)) < QWord(HeaderLength) + Header.PayloadLength do
      if not Fill then
        Exit(False);
    if not Header.Masked then
      Note('unmasked');
    Payload := Copy(FPending, HeaderLength, Header.PayloadLength);
    FPending := Copy(FPending, HeaderLength + Integer(Header.PayloadLength), MaxInt);
    if Header.Masked then
      ApplyWebSocketMask(PByte(Payload), Length(Payload), Header.MaskKey);
    if Header.Opcode >= 8 then
    begin
      Opcode := Header.Opcode;
      Exit(True);
    end;
    if First then
    begin
      Opcode := Header.Opcode;
      Rsv1 := Header.Rsv1;
      First := False;
    end;
    Message := Concat(Message, Payload);
  until Header.Fin;
  Payload := Message;
  Result := True;
end;

procedure TWebSocketTestServer.SendFrame(Opcode: Byte; Rsv1: Boolean; const Payload: TBytes);
var
  Wire: TBytes;
  Key: TWebSocketMaskKey;
begin
  Key[0] := 0;
  Key[1] := 0;
  Key[2] := 0;
  Key[3] := 0;
  Wire := EncodeWebSocketFrame(Opcode, True, Rsv1, PByte(Payload), Length(Payload), False, Key);
  FTransport.Write(PByte(Wire), Length(Wire));
end;

procedure TWebSocketTestServer.SendText(const Text: string);
var
  Payload: TBytes;
begin
  Payload := nil;
  SetLength(Payload, Length(Text));
  if Text <> '' then
    Move(Text[1], Payload[0], Length(Text));
  SendFrame(WebSocketOpText, False, Payload);
end;

function FieldOf(const Head, Name: string): string;
var
  Lines: TStringArray;
  Index, Colon: Integer;
begin
  Result := '';
  Lines := Head.Split([#13#10]);
  for Index := 1 to High(Lines) do
  begin
    Colon := Pos(':', Lines[Index]);
    if (Colon > 0) and SameText(Trim(Copy(Lines[Index], 1, Colon - 1)), Name) then
      Exit(Trim(Copy(Lines[Index], Colon + 1, MaxInt)));
  end;
end;

procedure TWebSocketTestServer.Serve;
var
  Head, Answer, Text: string;
  Opcode: Byte;
  Rsv1, UseDeflate: Boolean;
  Payload, Echo: TBytes;
  Compressor: TWebSocketCompressor;
  Decompressor: TWebSocketDecompressor;
  Code: Integer;
begin
  if not ReadHead(Head) then
    Exit;
  EnterCriticalSection(FLogLock);
  FRequestHead := Head;
  LeaveCriticalSection(FLogLock);
  if FScenario = ScenarioRefuse then
  begin
    Answer := 'HTTP/1.1 403 Forbidden'#13#10'Content-Length: 0'#13#10#13#10;
    FTransport.Write(PChar(Answer), Length(Answer));
    FTransport.Close;
    Exit;
  end;
  Answer := 'HTTP/1.1 101 Switching Protocols'#13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10;
  if FScenario = ScenarioWrongAccept then
    Answer := Answer + 'Sec-WebSocket-Accept: ' + WebSocketAcceptFor('wrong') + #13#10
  else
    Answer := Answer + 'Sec-WebSocket-Accept: ' + WebSocketAcceptFor(FieldOf(Head, 'Sec-WebSocket-Key')) + #13#10;
  if (FProtocol <> '') and (Pos(FProtocol, FieldOf(Head, 'Sec-WebSocket-Protocol')) > 0) then
    Answer := Answer + 'Sec-WebSocket-Protocol: ' + FProtocol + #13#10;
  UseDeflate := FDeflate and (Pos('permessage-deflate', FieldOf(Head, 'Sec-WebSocket-Extensions')) > 0);
  if UseDeflate then
    Answer := Answer + 'Sec-WebSocket-Extensions: permessage-deflate'#13#10;
  Answer := Answer + 'Set-Cookie: socket=1; Path=/'#13#10#13#10;
  FTransport.Write(PChar(Answer), Length(Answer));
  if FScenario = ScenarioWrongAccept then
  begin
    Fill;
    Exit;
  end;
  Compressor := nil;
  Decompressor := nil;
  if UseDeflate then
  begin
    Compressor := TWebSocketCompressor.Create(False);
    Decompressor := TWebSocketDecompressor.Create(False);
  end;
  try
    if FScenario = ScenarioBadUtf8 then
    begin
      SetLength(Payload, 2);
      Payload[0] := $C0;
      Payload[1] := $80;
      SendFrame(WebSocketOpText, False, Payload);
    end;
    if FScenario = ScenarioServerCloses then
      SendFrame(WebSocketOpPing, False, TBytes.Create(Ord('a'), Ord('b'), Ord('c')));
    while ReadFrame(Opcode, Rsv1, Payload) do
      case Opcode of
        WebSocketOpText, WebSocketOpBinary:
          begin
            if Rsv1 and (Decompressor <> nil) then
            begin
              Decompressor.Decompress(PByte(Payload), Length(Payload), 1 shl 24, Echo);
              Payload := Echo;
            end;
            if Opcode = WebSocketOpText then
            begin
              SetString(Text, PChar(PByte(Payload)), Length(Payload));
              Note('text:' + Text);
            end
            else
              Note('binary:' + IntToStr(Length(Payload)));
            if Compressor <> nil then
            begin
              Echo := Compressor.Compress(PByte(Payload), Length(Payload));
              SendFrame(Opcode, True, Echo);
            end
            else
              SendFrame(Opcode, False, Payload);
          end;
        WebSocketOpPing:
          SendFrame(WebSocketOpPong, False, Payload);
        WebSocketOpPong:
          begin
            SetString(Text, PChar(PByte(Payload)), Length(Payload));
            Note('pong:' + Text);
            if FScenario = ScenarioServerCloses then
              SendFrame(WebSocketOpClose, False, EncodeClosePayload(4001, 'done'));
          end;
        WebSocketOpClose:
          begin
            Code := 0;
            Text := '';
            if Length(Payload) >= 2 then
            begin
              Code := (Payload[0] shl 8) or Payload[1];
              SetString(Text, PChar(@Payload[2]), Length(Payload) - 2);
            end;
            Note('close:' + IntToStr(Code) + ':' + Text);
            if FScenario = ScenarioEcho then
              SendFrame(WebSocketOpClose, False, Payload);
            FTransport.Close;
            Exit;
          end;
      end;
  finally
    Compressor.Free;
    Decompressor.Free;
  end;
end;

procedure TWebSocketTestServer.Execute;
begin
  try
    Serve;
  except
    on Error: Exception do
      Note('exception:' + Error.Message);
  end;
  FTransport.Close;
end;

end.
