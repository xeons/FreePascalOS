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
  HelloRetryRequest: the transcript after a retry (message_hash in place
  of the first ClientHello) against RFC 8448 section 5, and the client
  itself answering a scripted server in memory: a retry with a cookie
  gets a second ClientHello that is the first plus the cookie; a retry
  that asks for x25519 again, one that changes nothing and a second
  retry are refused with the right alert.
}
unit TlsTest.Retry;

{$mode objfpc}
{$H+}

interface

procedure TestRetryTranscript;
procedure TestRetryExchange;

implementation

uses
  TestChecks,
  Crypto.Digests,
  Tls.ByteBuffers,
  Tls.Client,
  Tls.Connections,
  Tls.Constants,
  Tls.Errors,
  Tls.KeySchedule,
  Tls.ServerMessages,
  Tls.Transcript,
  Tls.Transport;

{$i TlsTest.Rfc8448Retry.inc}

procedure TestRetryTranscript;
var
  FirstHello, Retry, SecondHello, ServerHello, Shared: TByteArray;
  Hello: TServerHello;
  Transcript: TTlsTranscript;
  Hash: TDigestOutput;
  Schedule: TTlsKeySchedule;
begin
  FirstHello := HexToBytes(RetryClientHello1);
  Retry := HexToBytes(RetryRequestMessage);
  SecondHello := HexToBytes(RetryClientHello2);
  ServerHello := HexToBytes(RetryServerHello);
  Shared := HexToBytes(RetrySharedSecret);

  Check(ParseServerHello(@Retry[4], Length(Retry) - 4, Hello) = TlsErrorNone, 'retry: RFC 8448 HelloRetryRequest parses');
  Check(Hello.IsRetryRequest, 'retry: recognized by its random');
  Check(Hello.HasCookie and (Hello.Cookie.Length > 0), 'retry: with a cookie');
  Check(Hello.HasKeyShare and (Hello.KeyShareGroup = $0017), 'retry: asks for secp256r1');

  InitializeTranscript(Transcript);
  AddToTranscript(Transcript, @FirstHello[0], Length(FirstHello));
  StartTranscript(Transcript, DigestSha256);
  ReplaceWithMessageHash(Transcript);
  AddToTranscript(Transcript, @Retry[0], Length(Retry));
  AddToTranscript(Transcript, @SecondHello[0], Length(SecondHello));
  AddToTranscript(Transcript, @ServerHello[0], Length(ServerHello));
  TranscriptHash(Transcript, Hash);
  CheckBytes(@Hash[0], 32, RetryHelloHash, 'retry: transcript hash with message_hash (RFC 8448 section 5)');
  BeginKeySchedule(Schedule, DigestSha256);
  DeriveHandshakeSecrets(Schedule, @Shared[0], Length(Shared), @Hash[0]);
  CheckBytes(@Schedule.ClientHandshakeTraffic[0], 32, RetryClientHandshakeTraffic,
    'retry: client handshake traffic secret');
  CheckBytes(@Schedule.ServerHandshakeTraffic[0], 32, RetryServerHandshakeTraffic,
    'retry: server handshake traffic secret');
  FreeTranscript(Transcript);
end;

type
  TRetryScript = (ScriptRetryWithCookie, ScriptRetrySameGroup, ScriptRetryNoChange, ScriptRetryTwice);

  TScriptedServer = record
    Script: TRetryScript;
    { Everything the client sent. }
    Sent: TTlsBuilder;
    { What the server sends next, and how much of it has gone. }
    Reply: TTlsBuilder;
    ReplyPosition: PtrUInt;
    Round: Integer;
    FirstHello, SecondHello: TByteArray;
  end;
  PScriptedServer = ^TScriptedServer;

const
  Cookie = 'cookie from the scripted server';

function ScriptedSend(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
begin
  AppendBytes(PScriptedServer(Context)^.Sent, Buffer, Length);
  Result := Length;
end;

{ The handshake message in the client's Count-th record. }
function SentHandshake(var Server: TScriptedServer; Index: Integer): TByteArray;
var
  Position: PtrUInt;
  RecordLength: PtrUInt;
  Seen: Integer;
begin
  Result := nil;
  Position := 0;
  Seen := 0;
  while Position + 5 <= Server.Sent.Length do
  begin
    RecordLength := (PtrUInt(Server.Sent.Data[Position + 3]) shl 8) or Server.Sent.Data[Position + 4];
    if Server.Sent.Data[Position] = ContentHandshake then
    begin
      if Seen = Index then
      begin
        SetLength(Result, RecordLength);
        Move(Server.Sent.Data[Position + 5], Result[0], RecordLength);
        Exit;
      end;
      Inc(Seen);
    end;
    Position := Position + 5 + RecordLength;
  end;
end;

{ The alert in the client's last record, or -1. }
function LastAlert(var Server: TScriptedServer): Integer;
var
  Position, RecordLength: PtrUInt;
begin
  Result := -1;
  Position := 0;
  while Position + 5 <= Server.Sent.Length do
  begin
    RecordLength := (PtrUInt(Server.Sent.Data[Position + 3]) shl 8) or Server.Sent.Data[Position + 4];
    if (Server.Sent.Data[Position] = ContentAlert) and (RecordLength = 2) then
      Result := Server.Sent.Data[Position + 6];
    Position := Position + 5 + RecordLength;
  end;
end;

procedure AppendRetryRecord(var Server: TScriptedServer; constref Hello: TByteArray; WithCookie, WithGroup: Boolean);
var
  RecordStart, Body, SessionId, Extensions, Extension, Value: PtrUInt;
  CookieText: string;
begin
  { The client's session id is at offset 4 + 2 + 32 of its ClientHello. }
  AppendByte(Server.Reply, ContentHandshake);
  AppendUInt16(Server.Reply, VersionTls12);
  RecordStart := BeginVector(Server.Reply, 2);
  AppendByte(Server.Reply, HandshakeServerHello);
  Body := BeginVector(Server.Reply, 3);
  AppendUInt16(Server.Reply, VersionTls12);
  AppendBytes(Server.Reply, @HelloRetryRequestRandom[0], 32);
  SessionId := BeginVector(Server.Reply, 1);
  AppendBytes(Server.Reply, @Hello[4 + 2 + 32 + 1], Hello[4 + 2 + 32]);
  EndVector(Server.Reply, SessionId, 1);
  AppendUInt16(Server.Reply, $1301);
  AppendByte(Server.Reply, 0);
  Extensions := BeginVector(Server.Reply, 2);
  AppendUInt16(Server.Reply, ExtensionSupportedVersions);
  AppendUInt16(Server.Reply, 2);
  AppendUInt16(Server.Reply, VersionTls13);
  if WithGroup then
  begin
    AppendUInt16(Server.Reply, ExtensionKeyShare);
    AppendUInt16(Server.Reply, 2);
    AppendUInt16(Server.Reply, GroupX25519);
  end;
  if WithCookie then
  begin
    CookieText := Cookie;
    AppendUInt16(Server.Reply, ExtensionCookie);
    Extension := BeginVector(Server.Reply, 2);
    Value := BeginVector(Server.Reply, 2);
    AppendBytes(Server.Reply, @CookieText[1], Length(CookieText));
    EndVector(Server.Reply, Value, 2);
    EndVector(Server.Reply, Extension, 2);
  end;
  EndVector(Server.Reply, Extensions, 2);
  EndVector(Server.Reply, Body, 3);
  EndVector(Server.Reply, RecordStart, 2);
end;

procedure AppendAlertRecord(var Server: TScriptedServer; Description: Byte);
begin
  AppendByte(Server.Reply, ContentAlert);
  AppendUInt16(Server.Reply, VersionTls12);
  AppendUInt16(Server.Reply, 2);
  AppendByte(Server.Reply, 2);
  AppendByte(Server.Reply, Description);
end;

{ The server's side: called whenever the client waits for input. }
function ScriptedReceive(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Server: PScriptedServer;
begin
  Server := PScriptedServer(Context);
  if Server^.ReplyPosition >= Server^.Reply.Length then
  begin
    ClearBuilder(Server^.Reply);
    Server^.ReplyPosition := 0;
    Inc(Server^.Round);
    if Server^.Round = 1 then
    begin
      Server^.FirstHello := SentHandshake(Server^, 0);
      case Server^.Script of
        ScriptRetryWithCookie, ScriptRetryTwice: AppendRetryRecord(Server^, Server^.FirstHello, True, False);
        ScriptRetrySameGroup: AppendRetryRecord(Server^, Server^.FirstHello, True, True);
        ScriptRetryNoChange: AppendRetryRecord(Server^, Server^.FirstHello, False, False);
      end;
    end
    else if Server^.Round = 2 then
    begin
      Server^.SecondHello := SentHandshake(Server^, 1);
      if Server^.Script = ScriptRetryTwice then
        AppendRetryRecord(Server^, Server^.FirstHello, True, False)
      else
        AppendAlertRecord(Server^, TlsAlertHandshakeFailure);
    end
    else
      Exit(0);
  end;
  Result := Server^.Reply.Length - Server^.ReplyPosition;
  if Result > Int64(Length) then
    Result := Length;
  Move(Server^.Reply.Data[Server^.ReplyPosition], Buffer^, Result);
  Server^.ReplyPosition := Server^.ReplyPosition + PtrUInt(Result);
end;

function RunScript(Script: TRetryScript; var Server: TScriptedServer): LongInt;
var
  Transport: TTlsTransport;
  Options: TTlsClientOptions;
  Connection: PTlsConnection;
begin
  FillChar(Server, SizeOf(Server), 0);
  Server.Script := Script;
  InitializeBuilder(Server.Sent);
  InitializeBuilder(Server.Reply);
  Transport.Context := @Server;
  Transport.Send := @ScriptedSend;
  Transport.Receive := @ScriptedReceive;
  FillChar(Options, SizeOf(Options), 0);
  Options.ServerName := 'retry.test';
  Options.VerifyCertificates := False;
  CreateTlsClient(Transport, Options, Connection);
  Result := TlsHandshake(Connection);
  FreeTlsClient(Connection);
end;

procedure FreeScript(var Server: TScriptedServer);
begin
  FreeBuilder(Server.Sent);
  FreeBuilder(Server.Reply);
end;

procedure TestRetryExchange;
var
  Server: TScriptedServer;
  Error: LongInt;
  SuitesLength: Integer;
  CookieText: string;
  CookieAt: Integer;
  Index: Integer;
begin
  Error := RunScript(ScriptRetryWithCookie, Server);
  Check(Error = TlsErrorAlertReceived, 'retry exchange: the client answered the retry (the server then gave up)');
  Check((Length(Server.FirstHello) > 0) and (Length(Server.SecondHello) > 0), 'retry exchange: two ClientHellos');
  CookieText := Cookie;
  { The second ClientHello is the first with the cookie extension added
    at the end: 2 + 2 + 2 + the cookie. }
  Check(Length(Server.SecondHello) = Length(Server.FirstHello) + 6 + Length(CookieText),
    'retry exchange: the second ClientHello is longer by the cookie extension');
  if Length(Server.SecondHello) = Length(Server.FirstHello) + 6 + Length(CookieText) then
  begin
    CookieAt := Length(Server.SecondHello) - Length(CookieText);
    Check(CompareByte(Server.SecondHello[CookieAt], CookieText[1], Length(CookieText)) = 0,
      'retry exchange: the cookie comes back');
    { Random, session id, suites and the key share are unchanged. }
    Check(CompareByte(Server.SecondHello[6], Server.FirstHello[6], 32 + 33) = 0,
      'retry exchange: the same random and session id');
    { The cipher suites and compression methods are the same too. }
    Index := 4 + 2 + 32 + 33;
    SuitesLength := (Integer(Server.FirstHello[Index]) shl 8) or Server.FirstHello[Index + 1];
    Check(CompareByte(Server.SecondHello[Index], Server.FirstHello[Index], 2 + SuitesLength + 2) = 0,
      'retry exchange: the same cipher suites');
  end;
  FreeScript(Server);

  Error := RunScript(ScriptRetrySameGroup, Server);
  Check((Error = TlsErrorIllegalParameter) and (LastAlert(Server) = TlsAlertIllegalParameter),
    'retry exchange: a retry asking for the group already sent is refused (illegal_parameter)');
  FreeScript(Server);

  Error := RunScript(ScriptRetryNoChange, Server);
  Check((Error = TlsErrorIllegalParameter) and (LastAlert(Server) = TlsAlertIllegalParameter),
    'retry exchange: a retry that would change nothing is refused');
  FreeScript(Server);

  Error := RunScript(ScriptRetryTwice, Server);
  Check((Error = TlsErrorUnexpectedMessage) and (LastAlert(Server) = TlsAlertUnexpectedMessage),
    'retry exchange: a second retry is refused (unexpected_message)');
  FreeScript(Server);
end;

end.
