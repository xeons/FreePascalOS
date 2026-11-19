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
  Session resumption against RFC 8448: the ticket of section 3 gives
  the resumption master secret and the PSK; section 4's ClientHello
  carries the binder this library computes from them (the early
  secret, the binder key and the hash of the truncated ClientHello);
  the ServerHello takes the PSK and the handshake secrets follow. Then
  the session cache: tickets are kept per key, taken once, dropped when
  they expire.
}
unit TlsTest.Resumption;

{$mode objfpc}
{$H+}

interface

procedure TestRfc8448Resumption;
procedure TestSessionCache;

implementation

uses
  SysUtils,
  TestChecks,
  Crypto.Digests,
  Tls.ByteBuffers,
  Tls.Constants,
  Tls.Errors,
  Tls.KeySchedule,
  Tls.ServerMessages,
  Tls.SessionCache,
  Tls.Transcript;

{$i TlsTest.Rfc8448.inc}
{$i TlsTest.Rfc8448Resumption.inc}

procedure TestRfc8448Resumption;
var
  Schedule: TTlsKeySchedule;
  Hash, BinderHash, Binder: TDigestOutput;
  Ticket, ClientHello, ServerHello, Shared, Bytes: TByteArray;
  Lifetime, AgeAdd: LongWord;
  Nonce, TicketBytes: TTlsByteRange;
  Psk, BinderKey: TTlsSecret;
  Truncated: PtrUInt;
  Transcript: TTlsTranscript;
  Hello: TServerHello;
begin
  { Section 3: the ticket and the secrets behind it. }
  Ticket := HexToBytes(NewSessionTicketMessage);
  Check(ParseNewSessionTicket(@Ticket[4], Length(Ticket) - 4, Lifetime, AgeAdd, Nonce, TicketBytes) = TlsErrorNone,
    'resumption: RFC 8448 NewSessionTicket parses');
  Check(Lifetime = 30, 'resumption: ticket lifetime 30 seconds');
  Check(Nonce.Length = 2, 'resumption: two-byte ticket nonce');
  BeginKeySchedule(Schedule, DigestSha256);
  Bytes := HexToBytes(MasterSecret);
  Move(Bytes[0], Schedule.MasterSecret[0], 32);
  Hash := Default(TDigestOutput);
  Bytes := HexToBytes(ResumptionHash);
  Move(Bytes[0], Hash[0], 32);
  DeriveResumptionMasterSecret(Schedule, @Hash[0]);
  CheckBytes(@Schedule.ResumptionMasterSecret[0], 32, ResumptionMasterSecret,
    'resumption: resumption master secret (section 3)');
  DeriveResumptionPsk(DigestSha256, @Schedule.ResumptionMasterSecret[0], Nonce.Data, Nonce.Length, Psk);
  CheckBytes(@Psk[0], 32, ResumptionPsk, 'resumption: the ticket''s PSK (section 3)');

  { Section 4: the early secret and the binder. }
  BeginKeyScheduleWithPsk(Schedule, DigestSha256, @Psk[0], 32);
  CheckBytes(@Schedule.EarlySecret[0], 32, ResumedEarlySecret, 'resumption: early secret from the PSK (section 4)');
  ClientHello := HexToBytes(ResumedClientHello);
  { The binders: a 2-byte list length, a 1-byte binder length, 32 bytes;
    RFC 8448 shows the ClientHello without them too. }
  Truncated := Length(ClientHello) - (2 + 1 + 32);
  Check(Truncated = PtrUInt(Length(ResumedClientHelloPrefix)) div 2, 'resumption: the truncated ClientHello''s length');
  InitializeTranscript(Transcript);
  PeekTranscriptHash(Transcript, DigestSha256, @ClientHello[0], Truncated, BinderHash);
  CheckBytes(@BinderHash[0], 32, ResumedBinderHash, 'resumption: hash of the truncated ClientHello');
  DeriveBinderKey(Schedule, BinderKey);
  ComputeFinishedData(DigestSha256, @BinderKey[0], @BinderHash[0], Binder);
  CheckBytes(@Binder[0], 32, ResumedBinder, 'resumption: PSK binder');
  Check(CompareByte(Binder[0], ClientHello[Truncated + 3], 32) = 0, 'resumption: the binder ends the ClientHello');

  { The server takes the PSK; the handshake secrets come from PSK and
    (EC)DHE together. }
  ServerHello := HexToBytes(ResumedServerHello);
  Check(ParseServerHello(@ServerHello[4], Length(ServerHello) - 4, '', Hello) = TlsErrorNone,
    'resumption: ServerHello parses');
  Check(Hello.HasPreSharedKey and (Hello.SelectedIdentity = 0), 'resumption: the server took the first PSK');
  AddToTranscript(Transcript, @ClientHello[0], Length(ClientHello));
  StartTranscript(Transcript, DigestSha256);
  AddToTranscript(Transcript, @ServerHello[0], Length(ServerHello));
  TranscriptHash(Transcript, Hash);
  CheckBytes(@Hash[0], 32, ResumedHelloHash, 'resumption: transcript hash ClientHello..ServerHello');
  Shared := HexToBytes(ResumedSharedSecret);
  DeriveHandshakeSecrets(Schedule, @Shared[0], Length(Shared), @Hash[0]);
  CheckBytes(@Schedule.HandshakeSecret[0], 32, ResumedHandshakeSecret, 'resumption: handshake secret');
  CheckBytes(@Schedule.ClientHandshakeTraffic[0], 32, ResumedClientHandshakeTraffic,
    'resumption: client handshake traffic secret');
  CheckBytes(@Schedule.ServerHandshakeTraffic[0], 32, ResumedServerHandshakeTraffic,
    'resumption: server handshake traffic secret');
  FreeTranscript(Transcript);
end;

function MakeTicket(Marker: Byte; ReceivedAt: Int64; Lifetime: LongWord): TTlsSessionTicket;
begin
  Result := Default(TTlsSessionTicket);
  SetLength(Result.Ticket, 4);
  FillChar(Result.Ticket[0], 4, Marker);
  Result.Hash := DigestSha256;
  Result.Suite := $1301;
  Result.LifetimeSeconds := Lifetime;
  Result.ReceivedAt := ReceivedAt;
end;

procedure TestSessionCache;
var
  Ticket: TTlsSessionTicket;
  Index: Integer;
begin
  ClearSessionCache;
  Check(not TakeSessionTicket('example.com:443', 1000, Ticket), 'cache: empty at first');
  StoreSessionTicket('example.com:443', MakeTicket(1, 1000, 60));
  StoreSessionTicket('example.com:443', MakeTicket(2, 2000, 60));
  StoreSessionTicket('example.org:443', MakeTicket(3, 2000, 60));
  Check(CachedTicketCount('example.com:443') = 2, 'cache: two tickets for one key');
  Check(TakeSessionTicket('example.com:443', 3000, Ticket) and (Ticket.Ticket[0] = 2),
    'cache: the newest ticket first');
  Check(TakeSessionTicket('example.com:443', 3000, Ticket) and (Ticket.Ticket[0] = 1), 'cache: then the older one');
  Check(not TakeSessionTicket('example.com:443', 3000, Ticket), 'cache: each ticket is used once');
  Check(not TakeSessionTicket('example.org:443', 2000 + 60 * 1000, Ticket), 'cache: an expired ticket is dropped');
  for Index := 1 to 10 do
    StoreSessionTicket('many:443', MakeTicket(Index, Index, 60));
  Check(CachedTicketCount('many:443') = MaximumTicketsPerKey, 'cache: at most a few tickets per key');
  StoreSessionTicket('long:443', MakeTicket(9, 0, 30 * 24 * 60 * 60));
  Check(TakeSessionTicket('long:443', 0, Ticket) and (Ticket.LifetimeSeconds = MaximumTicketLifetimeSeconds),
    'cache: lifetimes over seven days are cut');
  ClearSessionCache;
  Check(CachedTicketCount('many:443') = 0, 'cache: cleared');
end;

end.
