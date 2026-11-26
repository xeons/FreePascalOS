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
  libhttp's WebSockets: the examples of RFC 6455 (section 1.3's accept
  value, section 5.7's frames) and RFC 7692 (section 7.2.3's compressed
  messages), the frame reader's failures, UTF-8 checks, the extension
  answer, the handshake's checks, then whole connections against
  HttpTest.WebSocketServer over pipes: echo with a subprotocol and
  permessage-deflate, the server closing, invalid UTF-8, a refused and
  a wrongly accepted handshake.
}
unit HttpTest.WebSockets;

{$mode objfpc}
{$H+}

interface

procedure TestWebSockets;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  HttpTest.Pipes,
  HttpTest.WebSocketServer,
  Url.Records,
  Url.Parser,
  Http.Client,
  Http.Connectors,
  Http.Cookies,
  Http.Observers,
  Http.Results,
  Http.Transports,
  Http.ResponseHeads,
  Http.WebSocketFrames,
  Http.WebSocketDeflate,
  Http.WebSocketHandshake,
  Http.WebSockets;

type
  TSocketConnector = class(THttpConnector)
  public
    Scenario: TWebSocketScenario;
    Deflate: Boolean;
    Pair: TPipePair;
    Server: TWebSocketTestServer;
    destructor Destroy; override;
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
  end;

  TRecordingObserver = class(TWebSocketObserver)
  public
    Lock: TRTLCriticalSection;
    Log: TStringList;
    Done: Boolean;
    Sent: QWord;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Line: string);
    function LogText: string;
    procedure Opened(Connection: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome); override;
    procedure MessageReceived(Connection: TWebSocketConnection; IsText: Boolean; const Data: TBytes); override;
    procedure BytesSent(Connection: TWebSocketConnection; Count: QWord); override;
    procedure Closed(Connection: TWebSocketConnection; WasClean: Boolean; Code: Word; const Reason: string;
      Failed: Boolean; const ErrorText: string); override;
  end;

destructor TSocketConnector.Destroy;
begin
  if Server <> nil then
  begin
    Server.WaitFor;
    Server.Free;
  end;
  Pair.Free;
  inherited Destroy;
end;

function TSocketConnector.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
begin
  Pair := TPipePair.Create('http/1.1');
  Server := TWebSocketTestServer.Create(Pair.Server, Scenario, 'chat', Deflate);
  Transport := Pair.Client;
  Result := HttpOk;
end;

constructor TRecordingObserver.Create;
begin
  inherited Create;
  InitCriticalSection(Lock);
  Log := TStringList.Create;
end;

destructor TRecordingObserver.Destroy;
begin
  Log.Free;
  DoneCriticalSection(Lock);
  inherited Destroy;
end;

procedure TRecordingObserver.Add(const Line: string);
begin
  EnterCriticalSection(Lock);
  try
    Log.Add(Line);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function TRecordingObserver.LogText: string;
begin
  EnterCriticalSection(Lock);
  try
    Result := Log.CommaText;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure TRecordingObserver.Opened(Connection: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome);
begin
  Add('open:' + Outcome.Protocol + ':' + Outcome.Extensions);
end;

procedure TRecordingObserver.MessageReceived(Connection: TWebSocketConnection; IsText: Boolean; const Data: TBytes);
var
  Text: string;
begin
  if IsText then
  begin
    SetString(Text, PChar(PByte(Data)), Length(Data));
    Add('text:' + Text);
  end
  else
    Add('binary:' + IntToStr(Length(Data)));
end;

procedure TRecordingObserver.BytesSent(Connection: TWebSocketConnection; Count: QWord);
begin
  EnterCriticalSection(Lock);
  Inc(Sent, Count);
  LeaveCriticalSection(Lock);
end;

procedure TRecordingObserver.Closed(Connection: TWebSocketConnection; WasClean: Boolean; Code: Word;
  const Reason: string; Failed: Boolean; const ErrorText: string);
begin
  Add('closed:' + BoolToStr(WasClean, 'clean', 'unclean') + ':' + IntToStr(Code) + ':' + Reason + ':' +
    BoolToStr(Failed, 'failed', 'ok'));
  EnterCriticalSection(Lock);
  Done := True;
  LeaveCriticalSection(Lock);
end;

function UrlOf(const Text: string): TUrlRecord;
begin
  if not ParseUrl(Text, Result) then
    Result := EmptyUrl;
end;

function BytesOfText(const Text: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Text <> '' then
    Move(Text[1], Result[0], Length(Text));
end;

procedure TestAcceptAndFrames;
var
  Key: TWebSocketMaskKey;
  Wire, Payload: TBytes;
begin
  Check(WebSocketAcceptFor('dGhlIHNhbXBsZSBub25jZQ==') = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=',
    'websocket: the accept value of RFC 6455 section 1.3');
  Check(Length(NewWebSocketKey) = 24, 'websocket: a key is 16 bytes in base64');
  Key[0] := $37;
  Key[1] := $FA;
  Key[2] := $21;
  Key[3] := $3D;
  Payload := BytesOfText('Hello');
  Wire := EncodeWebSocketFrame(WebSocketOpText, True, False, PByte(Payload), 5, False, Key);
  CheckBytes(PByte(Wire), Length(Wire), '810548656c6c6f', 'websocket: an unmasked text frame (5.7)');
  Wire := EncodeWebSocketFrame(WebSocketOpText, True, False, PByte(Payload), 5, True, Key);
  CheckBytes(PByte(Wire), Length(Wire), '818537fa213d7f9f4d5158', 'websocket: a masked text frame (5.7)');
  SetLength(Payload, 256);
  Wire := EncodeWebSocketFrame(WebSocketOpBinary, True, False, PByte(Payload), 256, False, Key);
  CheckBytes(PByte(Wire), 4, '827e0100', 'websocket: a 256-byte binary frame''s 16-bit length');
  SetLength(Payload, 65536);
  Wire := EncodeWebSocketFrame(WebSocketOpBinary, True, False, PByte(Payload), 65536, False, Key);
  CheckBytes(PByte(Wire), 10, '827f0000000000010000', 'websocket: a 64 KiB frame''s 64-bit length');
  Check(Length(Wire) = 65546, 'websocket: the 64 KiB frame''s size');
end;

function ReadAll(const Hex: string; out Items: TStringList; AllowRsv1: Boolean = False;
  Limit: QWord = 0): TWebSocketFrameReader;
var
  Bytes: TByteArray;
  Index: Integer;
  Item: TWebSocketItem;
  Step: TReaderStep;
  Text: string;
begin
  Items := TStringList.Create;
  Result := TWebSocketFrameReader.Create;
  Result.AllowRsv1 := AllowRsv1;
  if Limit > 0 then
    Result.MaximumMessageBytes := Limit;
  Bytes := HexToBytes(Hex);
  { One byte at a time: every split of a frame. }
  for Index := 0 to High(Bytes) do
  begin
    Result.Feed(@Bytes[Index], 1);
    repeat
      Step := Result.Next(Item);
      if Step = ReaderItem then
      begin
        SetString(Text, PChar(PByte(Item.Payload)), Length(Item.Payload));
        case Item.Kind of
          WebSocketItemMessage: Items.Add(BoolToStr(Item.IsText, 'text', 'binary') + ':' + Text);
          WebSocketItemPing: Items.Add('ping:' + Text);
          WebSocketItemPong: Items.Add('pong:' + Text);
          WebSocketItemClose: Items.Add('close:' + IntToStr(Item.Code) + ':' + Item.Reason);
        end;
      end;
    until Step <> ReaderItem;
    if Step = ReaderFailed then
      Exit;
  end;
end;

procedure CheckFailure(const Hex: string; Code: Word; const Name: string; AllowRsv1: Boolean = False;
  Limit: QWord = 0);
var
  Reader: TWebSocketFrameReader;
  Items: TStringList;
  Item: TWebSocketItem;
begin
  Reader := ReadAll(Hex, Items, AllowRsv1, Limit);
  try
    Check((Reader.Next(Item) = ReaderFailed) and (Reader.FailCode = Code), Name);
  finally
    Reader.Free;
    Items.Free;
  end;
end;

procedure TestReader;
var
  Reader: TWebSocketFrameReader;
  Items: TStringList;
begin
  Reader := ReadAll('010348656c' + '890548656c6c6f' + '80026c6f' + '8a00' + '880503e8686921', Items);
  try
    Check(Items.CommaText = 'ping:Hello,text:Hello,pong:,close:1000:hi!',
      'websocket: fragments around a ping, a pong and a close, a byte at a time (' + Items.CommaText + ')');
  finally
    Reader.Free;
    Items.Free;
  end;
  CheckFailure('818537fa213d7f9f4d5158', WebSocketCloseProtocolError, 'websocket: a masked frame from the server');
  CheckFailure('8300', WebSocketCloseProtocolError, 'websocket: a reserved opcode');
  CheckFailure('897e007e' + StringOfChar('0', 252), WebSocketCloseProtocolError,
    'websocket: a control frame of 126 bytes');
  CheckFailure('0900', WebSocketCloseProtocolError, 'websocket: a fragmented ping');
  CheckFailure('800161', WebSocketCloseProtocolError, 'websocket: a continuation with no message');
  CheckFailure('010161810161', WebSocketCloseProtocolError, 'websocket: a new message inside a fragmented one');
  CheckFailure('880203ed', WebSocketCloseProtocolError, 'websocket: close code 1005 may not be sent');
  CheckFailure('880103', WebSocketCloseProtocolError, 'websocket: a close payload of one byte');
  CheckFailure('880403e8c080', WebSocketCloseInvalidData, 'websocket: a close reason that is not UTF-8');
  CheckFailure('c10161', WebSocketCloseProtocolError, 'websocket: RSV1 without an extension');
  CheckFailure('a10161', WebSocketCloseProtocolError, 'websocket: RSV2');
  CheckFailure('c90161', WebSocketCloseProtocolError, 'websocket: RSV1 on a ping', True);
  CheckFailure('827f8000000000000000', WebSocketCloseProtocolError, 'websocket: a 64-bit length with the top bit');
  CheckFailure('820a', WebSocketCloseTooBig, 'websocket: a message past the limit', False, 8);
  Reader := ReadAll('c10161', Items, True);
  try
    Check(Items.CommaText = 'text:a', 'websocket: RSV1 with permessage-deflate');
  finally
    Reader.Free;
    Items.Free;
  end;
end;

procedure TestUtf8;
var
  Bytes: TByteArray;

  function Valid(const Hex: string): Boolean;
  begin
    Bytes := HexToBytes(Hex);
    Result := IsValidUtf8(PByte(Bytes), Length(Bytes));
  end;

begin
  Check(Valid('cebae1bdb9cf83cebcceb5'), 'websocket: UTF-8 κόσμε');
  Check(Valid('f48fbfbf') and Valid('ee8080'), 'websocket: UTF-8 U+10FFFF and U+E000');
  Check(not Valid('c080'), 'websocket: an overlong NUL is not UTF-8');
  Check(not Valid('eda080'), 'websocket: a surrogate is not UTF-8');
  Check(not Valid('f4908080'), 'websocket: past U+10FFFF is not UTF-8');
  Check(not Valid('cebae1bd'), 'websocket: a cut sequence is not UTF-8');
  Check(not Valid('ff'), 'websocket: 0xFF is not UTF-8');
end;

procedure TestDeflate;
var
  Decompressor: TWebSocketDecompressor;
  Compressor: TWebSocketCompressor;
  Bytes: TByteArray;
  Output, First, Second: TBytes;
  Text: string;
  Enabled: Boolean;
  Parameters: TPerMessageDeflateParameters;
  Reason: string;
begin
  Decompressor := TWebSocketDecompressor.Create(False);
  try
    Bytes := HexToBytes('f248cdc9c90700');
    Check(Decompressor.Decompress(PByte(Bytes), Length(Bytes), 100, Output), 'websocket: inflate RFC 7692 7.2.3.1');
    SetString(Text, PChar(PByte(Output)), Length(Output));
    Check(Text = 'Hello', 'websocket: 7.2.3.1 is Hello');
    Bytes := HexToBytes('f200110000');
    Check(Decompressor.Decompress(PByte(Bytes), Length(Bytes), 100, Output), 'websocket: inflate 7.2.3.2 (context)');
    SetString(Text, PChar(PByte(Output)), Length(Output));
    Check(Text = 'Hello', 'websocket: 7.2.3.2 refers back into the first message');
    Bytes := HexToBytes('0005 00faff48656c6c6f00'.Replace(' ', ''));
    Check(Decompressor.Decompress(PByte(Bytes), Length(Bytes), 100, Output) and (Length(Output) = 5),
      'websocket: inflate 7.2.3.3 (a stored block)');
    Bytes := HexToBytes('f248cdc9c90700');
    Check(not Decompressor.Decompress(PByte(Bytes), Length(Bytes), 3, Output), 'websocket: inflating past the limit');
  finally
    Decompressor.Free;
  end;
  Compressor := TWebSocketCompressor.Create(False);
  Decompressor := TWebSocketDecompressor.Create(False);
  try
    Text := 'Hello, Hello, Hello, websocket';
    First := Compressor.Compress(@Text[1], Length(Text));
    Second := Compressor.Compress(@Text[1], Length(Text));
    Check(Length(Second) < Length(First), 'websocket: the second message refers back into the first');
    Check(Decompressor.Decompress(PByte(First), Length(First), 1000, Output) and (Length(Output) = Length(Text)) and
      Decompressor.Decompress(PByte(Second), Length(Second), 1000, Output) and
      (CompareMem(PByte(Output), @Text[1], Length(Text))), 'websocket: deflate and inflate round trip');
    First := Compressor.Compress(nil, 0);
    Check(Decompressor.Decompress(PByte(First), Length(First), 1000, Output) and (Length(Output) = 0),
      'websocket: an empty compressed message');
  finally
    Compressor.Free;
    Decompressor.Free;
  end;
  Check(ParseExtensionsAnswer('permessage-deflate', Enabled, Parameters, Reason) and Enabled,
    'websocket: permessage-deflate accepted');
  Check(ParseExtensionsAnswer('permessage-deflate; server_no_context_takeover; client_no_context_takeover; ' +
    'server_max_window_bits=10', Enabled, Parameters, Reason) and Parameters.ServerNoContextTakeover and
    Parameters.ClientNoContextTakeover and (Parameters.ServerMaxWindowBits = 10),
    'websocket: permessage-deflate parameters');
  Check(not ParseExtensionsAnswer('permessage-deflate; client_max_window_bits=10', Enabled, Parameters, Reason),
    'websocket: client_max_window_bits was not offered');
  Check(not ParseExtensionsAnswer('permessage-deflate; server_max_window_bits=16', Enabled, Parameters, Reason),
    'websocket: server_max_window_bits past 15');
  Check(not ParseExtensionsAnswer('permessage-deflate, permessage-deflate', Enabled, Parameters, Reason),
    'websocket: permessage-deflate twice');
  Check(not ParseExtensionsAnswer('x-webkit-deflate-frame', Enabled, Parameters, Reason),
    'websocket: an extension not offered');
  Check(not ParseExtensionsAnswer('permessage-deflate; foo', Enabled, Parameters, Reason),
    'websocket: an unknown parameter');
end;

procedure TestHandshakeChecks;
var
  Offer: TWebSocketHandshakeOffer;
  Head: THttpResponseHead;
  Outcome: TWebSocketHandshakeOutcome;
  Reason, Request: string;

  function Answer(const Text: string): Boolean;
  begin
    ParseResponseHead(Text, Head);
    Result := CheckHandshakeResponse(Offer, Head, Outcome, Reason);
  end;

begin
  Offer := Default(TWebSocketHandshakeOffer);
  Offer.Target := '/chat';
  Offer.Authority := 'server.example.com';
  Offer.Key := 'dGhlIHNhbXBsZSBub25jZQ==';
  Offer.Origin := 'http://example.com';
  SetLength(Offer.Protocols, 2);
  Offer.Protocols[0] := 'chat';
  Offer.Protocols[1] := 'superchat';
  Request := BuildHandshakeRequest(Offer);
  Check((Pos('GET /chat HTTP/1.1'#13#10'Host: server.example.com'#13#10, Request) = 1) and
    (Pos('Sec-WebSocket-Version: 13'#13#10, Request) > 0) and
    (Pos('Sec-WebSocket-Protocol: chat, superchat'#13#10, Request) > 0) and
    (Pos('Origin: http://example.com'#13#10, Request) > 0), 'websocket: the handshake request');
  Check(Answer('HTTP/1.1 101 Switching Protocols'#13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='#13#10'Sec-WebSocket-Protocol: chat'#13#10#13#10) and
    (Outcome.Protocol = 'chat'), 'websocket: the answer of RFC 6455 section 1.3');
  Check(not Answer('HTTP/1.1 200 OK'#13#10#13#10), 'websocket: a 200 is not an upgrade');
  Check(not Answer('HTTP/1.1 101 Switching Protocols'#13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: xxx'#13#10#13#10), 'websocket: a wrong accept value');
  Check(not Answer('HTTP/1.1 101 Switching Protocols'#13#10'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='#13#10#13#10), 'websocket: no Upgrade field');
  Check(not Answer('HTTP/1.1 101 Switching Protocols'#13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='#13#10'Sec-WebSocket-Protocol: other'#13#10#13#10),
    'websocket: a subprotocol not offered');
  Check(not Answer('HTTP/1.1 101 Switching Protocols'#13#10'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='#13#10'Sec-WebSocket-Extensions: permessage-deflate'#13#10#13#10),
    'websocket: an extension not offered');
  Check(IsProtocolToken('chat.v2') and not IsProtocolToken('a b') and not IsProtocolToken(''),
    'websocket: subprotocol tokens');
end;

function WaitDone(Observer: TRecordingObserver): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    EnterCriticalSection(Observer.Lock);
    Result := Observer.Done;
    LeaveCriticalSection(Observer.Lock);
    if Result then
      Exit;
    Sleep(5);
  until GetTickCount64 - Started > 10000;
end;

function WaitFor(Observer: TRecordingObserver; const Text: string): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  repeat
    if Pos(Text, Observer.LogText) > 0 then
      Exit(True);
    Sleep(5);
  until GetTickCount64 - Started > 10000;
  Result := False;
end;

procedure RunConnection(Scenario: TWebSocketScenario; Deflate: Boolean; const Name: string);
var
  Connector: TSocketConnector;
  Client: THttpClient;
  Jar: TCookieJar;
  Observer: TRecordingObserver;
  Connection: TWebSocketConnection;
  Options: TWebSocketOptions;
  Binary: array[0..2] of Byte;
begin
  Connector := TSocketConnector.Create;
  Connector.Scenario := Scenario;
  Connector.Deflate := Deflate;
  Client := THttpClient.Create(DefaultClientSettings, Connector, False);
  Jar := TCookieJar.Create;
  Client.Cookies := Jar;
  Observer := TRecordingObserver.Create;
  Options := Default(TWebSocketOptions);
  Options.Url := UrlOf('http://socket.test/echo?x=1');
  SetLength(Options.Protocols, 2);
  Options.Protocols[0] := 'chat';
  Options.Protocols[1] := 'other';
  Options.Origin := 'http://page.test';
  Options.OfferDeflate := True;
  Options.SendCookies := True;
  Options.CookieContext.HttpApi := True;
  Options.CookieContext.SameSite := True;
  Options.CookieContext.SafeMethod := True;
  Connection := TWebSocketConnection.Create(Client, Options, Observer);
  try
    case Scenario of
      ScenarioEcho:
        begin
          Check(WaitFor(Observer, 'open:'), Name + ': opens');
          Connection.SendText('hello');
          Binary[0] := 1;
          Binary[1] := 2;
          Binary[2] := 3;
          Connection.SendBinary(@Binary[0], 3);
          Check(WaitFor(Observer, 'binary:3'), Name + ': both messages echoed');
          Connection.Close(1000, 'bye');
          Check(WaitDone(Observer), Name + ': closes');
          if Deflate then
            Check(Pos('open:chat:permessage-deflate', Observer.LogText) = 1, Name + ': subprotocol and extension (' +
              Observer.LogText + ')')
          else
            Check(Pos('open:chat:,', Observer.LogText) = 1, Name + ': subprotocol, no extension');
          Check(Pos('text:hello,binary:3,closed:clean:1000:bye:ok', Observer.LogText) > 0,
            Name + ': echoes, then a clean close (' + Observer.LogText + ')');
          Check(Observer.Sent = 8, Name + ': every byte reported sent');
          Check(Pos('GET /echo?x=1 HTTP/1.1', Connector.Server.RequestHead) = 1, Name + ': the request target');
          Check(Pos('text:hello,binary:3,close:1000:bye', Connector.Server.LogText) = 1,
            Name + ': the server saw masked frames (' + Connector.Server.LogText + ')');
          Check(Jar.CookieFieldFor(Options.Url, Options.CookieContext, Client.UnixTimeNow) = 'socket=1',
            Name + ': Set-Cookie of the handshake kept');
        end;
      ScenarioServerCloses:
        begin
          Check(WaitDone(Observer), Name + ': ends');
          Check(Pos('closed:clean:4001:done:ok', Observer.LogText) > 0, Name + ': a clean close with the server''s code (' +
            Observer.LogText + ')');
          Check(Pos('pong:abc,close:4001:', Connector.Server.LogText) = 1,
            Name + ': the ping answered, the close echoed (' + Connector.Server.LogText + ')');
        end;
      ScenarioBadUtf8:
        begin
          Check(WaitDone(Observer), Name + ': ends');
          Check(Pos('closed:unclean:1006::failed', Observer.LogText) > 0, Name + ': fails (' + Observer.LogText + ')');
          Check(Pos('close:1007:', Connector.Server.LogText) > 0, Name + ': the close frame says 1007 (' +
            Connector.Server.LogText + ')');
        end;
      ScenarioRefuse, ScenarioWrongAccept:
        begin
          Check(WaitDone(Observer), Name + ': ends');
          Check((Pos('open:', Observer.LogText) = 0) and (Pos('closed:unclean:1006::failed', Observer.LogText) > 0),
            Name + ': fails without opening (' + Observer.LogText + ')');
        end;
    end;
  finally
    Connection.Free;
    Observer.Free;
    Client.Free;
    Jar.Free;
    Connector.Free;
  end;
end;

procedure TestWebSockets;
begin
  TestAcceptAndFrames;
  TestReader;
  TestUtf8;
  TestDeflate;
  TestHandshakeChecks;
  RunConnection(ScenarioEcho, False, 'websocket echo');
  RunConnection(ScenarioEcho, True, 'websocket echo with permessage-deflate');
  RunConnection(ScenarioServerCloses, False, 'websocket server closes');
  RunConnection(ScenarioBadUtf8, False, 'websocket invalid UTF-8');
  RunConnection(ScenarioRefuse, False, 'websocket refused');
  RunConnection(ScenarioWrongAccept, False, 'websocket wrong accept');
end;

end.
