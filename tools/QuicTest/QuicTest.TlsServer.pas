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
  The smallest TLS 1.3 server that serves the loopback tests over a
  QUIC connection's CRYPTO streams (RFC 9001): it reads the ClientHello,
  takes its x25519 share, the first suite it offers, its ALPN and its
  transport parameters, and answers with ServerHello, then
  EncryptedExtensions (ALPN, quic_transport_parameters), Certificate
  (the self-signed Ed25519 certificate make-vectors.py made),
  CertificateVerify and Finished; then it checks the client's Finished.
  It uses libtls's key schedule and transcript and libcryptography; it
  is no general server (no retry requests, no other groups or keys).
}
unit QuicTest.TlsServer;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Quic.ConnectionState;

{ Runs the server's handshake on State (a server connection that has
  its client's first Initial): '' when it completed, else what went
  wrong. }
function RunServerHandshake(State: PQuicConnectionState; const Protocol: string): string;

implementation

uses
  Crypto.Bits,
  Crypto.Digests,
  Crypto.Ed25519,
  Crypto.Random,
  Crypto.X25519,
  Tls.CipherSuites,
  Tls.KeySchedule,
  Tls.Transcript,
  Quic.Buffers,
  Quic.ConnectionCore,
  Quic.Constants,
  Quic.DatagramTransports;

{$I QuicTest.Generated.inc}

type
  TClientHelloSummary = record
    SuiteCount: Integer;
    Suites: array[0..31] of Word;
    HasShare: Boolean;
    Share: array[0..31] of Byte;
    OffersProtocol: Boolean;
    TransportParameters: TBytes;
    OffersTls13: Boolean;
  end;

  TMessageBuilder = record
    Data: array of Byte;
    Length: Integer;
  end;

procedure AddByte(var Builder: TMessageBuilder; Value: Byte);
begin
  if Builder.Length >= System.Length(Builder.Data) then
    SetLength(Builder.Data, Builder.Length * 2 + 256);
  Builder.Data[Builder.Length] := Value;
  Inc(Builder.Length);
end;

procedure AddWord(var Builder: TMessageBuilder; Value: Word);
begin
  AddByte(Builder, Byte(Value shr 8));
  AddByte(Builder, Byte(Value));
end;

procedure AddBytes(var Builder: TMessageBuilder; Data: PByte; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    AddByte(Builder, Data[Index]);
end;

{ Room for a length of Size bytes, filled in by CloseLength. }
function OpenLength(var Builder: TMessageBuilder; Size: Integer): Integer;
var
  Index: Integer;
begin
  Result := Builder.Length;
  for Index := 1 to Size do
    AddByte(Builder, 0);
end;

procedure CloseLength(var Builder: TMessageBuilder; Position, Size: Integer);
var
  Value, Index: Integer;
begin
  Value := Builder.Length - Position - Size;
  for Index := Size - 1 downto 0 do
  begin
    Builder.Data[Position + Index] := Byte(Value);
    Value := Value shr 8;
  end;
end;

{ Waits for one whole handshake message at a level. }
function ReceiveMessage(State: PQuicConnectionState; Space: Integer; out Message: TBytes): Boolean;
var
  Header: array[0..3] of Byte;
  Got, Count: PtrUInt;
  BodyLength: PtrUInt;

  function Fill(Target: PByte; Needed: PtrUInt): Boolean;
  begin
    Got := 0;
    while Got < Needed do
    begin
      Count := ReadCryptoData(State, Space, Target + Got, Needed - Got);
      Got := Got + Count;
      if Got = Needed then
        Break;
      if not ConnectionIsOpen(State) or (QuicMilliseconds >= State^.HandshakeDeadline) then
        Exit(False);
      PumpConnection(State, State^.HandshakeDeadline);
    end;
    Result := True;
  end;

begin
  Message := nil;
  if not Fill(@Header[0], 4) then
    Exit(False);
  BodyLength := (PtrUInt(Header[1]) shl 16) or (PtrUInt(Header[2]) shl 8) or Header[3];
  SetLength(Message, 4 + BodyLength);
  Move(Header[0], Message[0], 4);
  Result := (BodyLength = 0) or Fill(@Message[4], BodyLength);
end;

function ParseClientHello(constref Message: TBytes; const Protocol: string; out Summary: TClientHelloSummary): Boolean;
var
  Reader, Extensions, Data, List: TQuicReader;
  Version, SuitesLength, ExtensionType, ExtensionLength, Group, ShareLength, ListLength: Word;
  SessionIdLength, CompressionLength, NameLength: Byte;
  Skipped: PByte;
  Index: Integer;
  Name: string;
begin
  Summary := Default(TClientHelloSummary);
  Reader.Initialize(@Message[4], Length(Message) - 4);
  if not Reader.ReadUInt16(Version) or not Reader.Skip(32) or not Reader.ReadByte(SessionIdLength) or
     (SessionIdLength <> 0) or not Reader.ReadUInt16(SuitesLength) then
    Exit(False);
  for Index := 0 to SuitesLength div 2 - 1 do
  begin
    if not Reader.ReadUInt16(Version) then
      Exit(False);
    if Summary.SuiteCount <= High(Summary.Suites) then
    begin
      Summary.Suites[Summary.SuiteCount] := Version;
      Inc(Summary.SuiteCount);
    end;
  end;
  if not Reader.ReadByte(CompressionLength) or not Reader.Skip(CompressionLength) or
     not Reader.ReadUInt16(ExtensionLength) or not Reader.ReadBytes(ExtensionLength, Skipped) then
    Exit(False);
  Extensions.Initialize(Skipped, ExtensionLength);
  while not Extensions.AtEnd do
  begin
    if not Extensions.ReadUInt16(ExtensionType) or not Extensions.ReadUInt16(ExtensionLength) or
       not Extensions.ReadBytes(ExtensionLength, Skipped) then
      Exit(False);
    Data.Initialize(Skipped, ExtensionLength);
    case ExtensionType of
      $002B:
        begin
          Data.ReadByte(CompressionLength);
          while Data.ReadUInt16(Version) do
            if Version = $0304 then
              Summary.OffersTls13 := True;
        end;
      $0033:
        begin
          Data.ReadUInt16(ListLength);
          while Data.ReadUInt16(Group) and Data.ReadUInt16(ShareLength) and Data.ReadBytes(ShareLength, Skipped) do
            if (Group = $001D) and (ShareLength = 32) then
            begin
              Summary.HasShare := True;
              Move(Skipped^, Summary.Share[0], 32);
            end;
        end;
      $0010:
        begin
          Data.ReadUInt16(ListLength);
          List := Data;
          while List.ReadByte(NameLength) and List.ReadBytes(NameLength, Skipped) do
          begin
            SetString(Name, PChar(Skipped), NameLength);
            if Name = Protocol then
              Summary.OffersProtocol := True;
          end;
        end;
      $0039:
        begin
          SetLength(Summary.TransportParameters, ExtensionLength);
          if ExtensionLength > 0 then
            Move(Skipped^, Summary.TransportParameters[0], ExtensionLength);
        end;
    end;
  end;
  Result := True;
end;

function ChooseSuite(constref Summary: TClientHelloSummary; out Suite: TCipherSuiteInfo): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Summary.SuiteCount - 1 do
    if FindCipherSuite(Summary.Suites[Index], Suite) and not Suite.IsTls12 then
      Exit(True);
  Result := False;
end;

function BuildServerHello(Suite: Word; PublicKey: PByte): TMessageBuilder;
var
  Body, Extensions, Extension, Share: Integer;
  Random: array[0..31] of Byte;
begin
  Result := Default(TMessageBuilder);
  AddByte(Result, 2);
  Body := OpenLength(Result, 3);
  AddWord(Result, $0303);
  RandomBytes(@Random[0], 32);
  AddBytes(Result, @Random[0], 32);
  AddByte(Result, 0);
  AddWord(Result, Suite);
  AddByte(Result, 0);
  Extensions := OpenLength(Result, 2);
  AddWord(Result, $002B);
  AddWord(Result, 2);
  AddWord(Result, $0304);
  AddWord(Result, $0033);
  Extension := OpenLength(Result, 2);
  AddWord(Result, $001D);
  Share := OpenLength(Result, 2);
  AddBytes(Result, PublicKey, 32);
  CloseLength(Result, Share, 2);
  CloseLength(Result, Extension, 2);
  CloseLength(Result, Extensions, 2);
  CloseLength(Result, Body, 3);
end;

function BuildFlight(State: PQuicConnectionState; const Protocol: string; Hash: TDigestAlgorithm;
  var Transcript: TTlsTranscript; constref Schedule: TTlsKeySchedule): TMessageBuilder;
var
  Start, Body, Extensions, Extension, List, Name, Entries, Entry, Signature: Integer;
  Parameters: TBytes;
  TranscriptDigest, VerifyData: TDigestOutput;
  Content: array[0..64 + 33 + 1 + MaximumDigestSize - 1] of Byte;
  Signed: array[0..63] of Byte;
  ContextText: string;
  HashLength: Integer;
begin
  Result := Default(TMessageBuilder);
  HashLength := DigestSize(Hash);
  { EncryptedExtensions. }
  Start := Result.Length;
  AddByte(Result, 8);
  Body := OpenLength(Result, 3);
  Extensions := OpenLength(Result, 2);
  AddWord(Result, $0010);
  Extension := OpenLength(Result, 2);
  List := OpenLength(Result, 2);
  Name := OpenLength(Result, 1);
  AddBytes(Result, PByte(PChar(Protocol)), Length(Protocol));
  CloseLength(Result, Name, 1);
  CloseLength(Result, List, 2);
  CloseLength(Result, Extension, 2);
  AddWord(Result, $0039);
  Extension := OpenLength(Result, 2);
  Parameters := EncodedLocalParameters(State);
  AddBytes(Result, @Parameters[0], Length(Parameters));
  CloseLength(Result, Extension, 2);
  CloseLength(Result, Extensions, 2);
  CloseLength(Result, Body, 3);
  AddToTranscript(Transcript, @Result.Data[Start], Result.Length - Start);

  { Certificate. }
  Start := Result.Length;
  AddByte(Result, 11);
  Body := OpenLength(Result, 3);
  AddByte(Result, 0);
  Entries := OpenLength(Result, 3);
  Entry := OpenLength(Result, 3);
  AddBytes(Result, @ServerCertificate[0], SizeOf(ServerCertificate));
  CloseLength(Result, Entry, 3);
  AddWord(Result, 0);
  CloseLength(Result, Entries, 3);
  CloseLength(Result, Body, 3);
  AddToTranscript(Transcript, @Result.Data[Start], Result.Length - Start);

  { CertificateVerify: Ed25519 over the RFC 8446 section 4.4.3 content. }
  TranscriptHash(Transcript, TranscriptDigest);
  FillChar(Content[0], 64, $20);
  ContextText := 'TLS 1.3, server CertificateVerify';
  Move(ContextText[1], Content[64], 33);
  Content[97] := 0;
  Move(TranscriptDigest[0], Content[98], HashLength);
  Ed25519Sign(@ServerKeySeed[0], @Content[0], 98 + HashLength, @Signed[0]);
  Start := Result.Length;
  AddByte(Result, 15);
  Body := OpenLength(Result, 3);
  AddWord(Result, $0807);
  Signature := OpenLength(Result, 2);
  AddBytes(Result, @Signed[0], 64);
  CloseLength(Result, Signature, 2);
  CloseLength(Result, Body, 3);
  AddToTranscript(Transcript, @Result.Data[Start], Result.Length - Start);

  { Finished. }
  TranscriptHash(Transcript, TranscriptDigest);
  ComputeFinishedData(Hash, @Schedule.ServerHandshakeTraffic[0], @TranscriptDigest[0], VerifyData);
  Start := Result.Length;
  AddByte(Result, 20);
  Body := OpenLength(Result, 3);
  AddBytes(Result, @VerifyData[0], HashLength);
  CloseLength(Result, Body, 3);
  AddToTranscript(Transcript, @Result.Data[Start], Result.Length - Start);
end;

function RunServerHandshake(State: PQuicConnectionState; const Protocol: string): string;
var
  Message: TBytes;
  Summary: TClientHelloSummary;
  Suite: TCipherSuiteInfo;
  PrivateKey, PublicKey, Shared: array[0..31] of Byte;
  Transcript: TTlsTranscript;
  Schedule: TTlsKeySchedule;
  Hello, Flight: TMessageBuilder;
  Digest, Expected: TDigestOutput;
  HashLength: Integer;
begin
  if not ReceiveMessage(State, SpaceInitial, Message) or (Message[0] <> 1) then
    Exit('no ClientHello');
  if not ParseClientHello(Message, Protocol, Summary) then
    Exit('a malformed ClientHello');
  if not Summary.OffersTls13 or not Summary.HasShare or not Summary.OffersProtocol then
    Exit('the ClientHello lacks TLS 1.3, an x25519 share or the protocol');
  if not ChooseSuite(Summary, Suite) then
    Exit('no common suite');
  if (Length(Summary.TransportParameters) = 0) or
     (ApplyPeerTransportParameters(State, @Summary.TransportParameters[0], Length(Summary.TransportParameters)) <> 0) then
    Exit('bad transport parameters');
  HashLength := DigestSize(Suite.Hash);

  InitializeTranscript(Transcript);
  StartTranscript(Transcript, Suite.Hash);
  AddToTranscript(Transcript, @Message[0], Length(Message));
  RandomBytes(@PrivateKey[0], 32);
  X25519PublicKey(@PrivateKey[0], @PublicKey[0]);
  if not X25519SharedSecret(@PrivateKey[0], @Summary.Share[0], @Shared[0]) then
    Exit('a bad key share');
  Hello := BuildServerHello(Suite.Identifier, @PublicKey[0]);
  AddToTranscript(Transcript, @Hello.Data[0], Hello.Length);
  AppendCryptoData(State, SpaceInitial, @Hello.Data[0], Hello.Length);

  BeginKeySchedule(Schedule, Suite.Hash);
  TranscriptHash(Transcript, Digest);
  DeriveHandshakeSecrets(Schedule, @Shared[0], 32, @Digest[0]);
  InstallTrafficSecret(State, SpaceHandshake, True, Suite.Identifier, @Schedule.ClientHandshakeTraffic[0], HashLength);
  InstallTrafficSecret(State, SpaceHandshake, False, Suite.Identifier, @Schedule.ServerHandshakeTraffic[0],
    HashLength);

  Flight := BuildFlight(State, Protocol, Suite.Hash, Transcript, Schedule);
  AppendCryptoData(State, SpaceHandshake, @Flight.Data[0], Flight.Length);
  TranscriptHash(Transcript, Digest);
  DeriveApplicationSecrets(Schedule, @Digest[0]);
  InstallTrafficSecret(State, SpaceApplication, False, Suite.Identifier, @Schedule.ServerApplicationTraffic[0],
    HashLength);
  InstallTrafficSecret(State, SpaceApplication, True, Suite.Identifier, @Schedule.ClientApplicationTraffic[0],
    HashLength);
  FlushConnection(State);

  if not ReceiveMessage(State, SpaceHandshake, Message) or (Message[0] <> 20) then
  begin
    FreeTranscript(Transcript);
    Exit('no client Finished');
  end;
  ComputeFinishedData(Suite.Hash, @Schedule.ClientHandshakeTraffic[0], @Digest[0], Expected);
  FreeTranscript(Transcript);
  if (Length(Message) <> 4 + HashLength) or not ConstantTimeEqual(@Expected[0], @Message[4], HashLength) then
    Exit('the client Finished does not match');
  WipeKeySchedule(Schedule);
  CompleteHandshake(State);
  FlushConnection(State);
  Result := '';
end;

end.
