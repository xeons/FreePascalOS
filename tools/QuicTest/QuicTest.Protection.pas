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
  Packet protection against RFC 9001 appendix A: the Initial secrets
  and keys of A.1, the header protection sample of A.2, the ChaCha20
  short header packet of A.5 (whole), the Retry integrity tag of A.4,
  and whole Initial and AES-256-GCM packets protected the same way by
  make-vectors.py (Python's cryptography), sealed here and opened again.
}
unit QuicTest.Protection;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure RunProtectionTests;

implementation

uses
  SysUtils,
  TestChecks,
  Crypto.Digests,
  Tls.CipherSuites,
  Quic.ConnectionIds,
  Quic.PacketHeaders,
  Quic.PacketProtection,
  Quic.InitialSecrets;

{$I QuicTest.Generated.inc}

function IdFromHex(const Hex: string): TQuicConnectionId;
var
  Bytes: TByteArray;
begin
  Bytes := HexToBytes(Hex);
  MakeConnectionId(@Bytes[0], Length(Bytes), Result);
end;

procedure TestInitialKeys;
var
  ClientSecret, ServerSecret: TQuicInitialSecret;
  ClientKeys, ServerKeys: TQuicPacketKeys;
  Mask: TQuicHeaderMask;
  Sample: TByteArray;
begin
  DeriveInitialSecrets(IdFromHex('8394c8f03e515708'), ClientSecret, ServerSecret);
  CheckBytes(@ClientSecret[0], 32, 'c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea',
    'A.1 client_initial_secret');
  CheckBytes(@ServerSecret[0], 32, '3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b',
    'A.1 server_initial_secret');
  DeriveInitialKeys(IdFromHex('8394c8f03e515708'), ClientKeys, ServerKeys);
  CheckBytes(@ClientKeys.Key[0], 16, '1f369613dd76d5467730efcbe3b1a22d', 'A.1 client key');
  CheckBytes(@ClientKeys.Iv[0], 12, 'fa044b2f42a3fd3b46fb255c', 'A.1 client iv');
  CheckBytes(@ClientKeys.HeaderKey[0], 16, '9f50449e04a0e810283a1e9933adedd2', 'A.1 client hp');
  CheckBytes(@ServerKeys.Key[0], 16, 'cf3a5331653c364c88f0f379b6067e37', 'A.1 server key');
  CheckBytes(@ServerKeys.Iv[0], 12, '0ac1493ca1905853b0bba03e', 'A.1 server iv');
  CheckBytes(@ServerKeys.HeaderKey[0], 16, 'c206b8d9b9f0f37644430b490eeaa314', 'A.1 server hp');
  Sample := HexToBytes('d1b1c98dd7689fb8ec11d242b123dc9b');
  ComputeHeaderMask(ClientKeys, @Sample[0], Mask);
  CheckBytes(@Mask[0], 5, '437b9aec36', 'A.2 header protection mask');
end;

{ Builds a long header packet the way the sender does: header, payload,
  seal, mask; then takes it apart again. }
procedure CheckLongPacket(constref Keys: TQuicPacketKeys; const HeaderHex: string; PacketNumber: QWord;
  PacketNumberLength: Integer; Payload: PByte; PayloadLength: Integer; Expected: PByte; ExpectedLength: Integer;
  ShortIdLength: Integer; const Name: string);
var
  Header: TByteArray;
  Packet: array of Byte;
  HeaderLength: Integer;
  Mask: TQuicHeaderMask;
  Parsed: TQuicPacketHeader;
  Truncated: QWord;
  Index: Integer;
begin
  Header := HexToBytes(HeaderHex);
  HeaderLength := Length(Header);
  Packet := nil;
  SetLength(Packet, HeaderLength + PayloadLength + 16);
  Move(Header[0], Packet[0], HeaderLength);
  Move(Payload^, Packet[HeaderLength], PayloadLength);
  SealPayload(Keys, PacketNumber, @Packet[0], HeaderLength, @Packet[HeaderLength], PayloadLength);
  ComputeHeaderMask(Keys, @Packet[HeaderLength - PacketNumberLength + 4], Mask);
  ApplyHeaderMask(@Packet[0], HeaderLength - PacketNumberLength, PacketNumberLength, Mask);
  Check((Length(Packet) = ExpectedLength) and (CompareByte(Packet[0], Expected^, ExpectedLength) = 0),
    Name + ': protected packet');

  { The receiving side. }
  Check(ParsePacketHeader(Expected, ExpectedLength, ShortIdLength, Parsed), Name + ': header parses');
  Check(Parsed.PacketLength = PtrUInt(ExpectedLength), Name + ': packet length');
  Move(Expected^, Packet[0], ExpectedLength);
  ComputeHeaderMask(Keys, @Packet[Parsed.PacketNumberOffset + 4], Mask);
  if (Packet[0] and $80) <> 0 then
    Packet[0] := Packet[0] xor (Mask[0] and $0F)
  else
    Packet[0] := Packet[0] xor (Mask[0] and $1F);
  Check((Packet[0] and 3) + 1 = PacketNumberLength, Name + ': packet number length');
  Truncated := 0;
  for Index := 0 to PacketNumberLength - 1 do
    Truncated := (Truncated shl 8) or (Packet[Parsed.PacketNumberOffset + PtrUInt(Index)] xor Mask[1 + Index]);
  for Index := 0 to PacketNumberLength - 1 do
    Packet[Parsed.PacketNumberOffset + PtrUInt(Index)] := Packet[Parsed.PacketNumberOffset + PtrUInt(Index)] xor
      Mask[1 + Index];
  Check(DecodePacketNumber(-1, Truncated, PacketNumberLength) = PacketNumber, Name + ': packet number');
  Check(OpenPayload(Keys, PacketNumber, @Packet[0], HeaderLength, @Packet[HeaderLength],
    ExpectedLength - HeaderLength), Name + ': opens');
  Check(CompareByte(Packet[HeaderLength], Payload^, PayloadLength) = 0, Name + ': payload');
end;

procedure TestWholePackets;
var
  ClientKeys, ServerKeys, Keys: TQuicPacketKeys;
  Payload: array of Byte;
begin
  DeriveInitialKeys(IdFromHex('8394c8f03e515708'), ClientKeys, ServerKeys);
  Payload := nil;
  SetLength(Payload, 1162);
  FillChar(Payload[0], 1162, 0);
  Payload[0] := $06;
  Payload[1] := $00;
  Payload[2] := $40;
  Payload[3] := $F1;
  Move(ClientCryptoData[0], Payload[4], SizeOf(ClientCryptoData));
  CheckLongPacket(ClientKeys, 'c300000001088394c8f03e5157080000449e00000002', 2, 4, @Payload[0], 1162,
    @ClientInitialPacket[0], SizeOf(ClientInitialPacket), 0, 'client Initial');

  SetLength(Payload, 9 + SizeOf(ServerCryptoData));
  Move(HexToBytes('02000000000600405a')[0], Payload[0], 9);
  Move(ServerCryptoData[0], Payload[9], SizeOf(ServerCryptoData));
  CheckLongPacket(ServerKeys, 'c1000000010008f067a5502a4262b50040750001', 1, 2, @Payload[0], Length(Payload),
    @ServerInitialPacket[0], SizeOf(ServerInitialPacket), 0, 'server Initial');

  DerivePacketKeys(Keys, AeadAes256Gcm, DigestSha384, @Aes256Secret[0], SizeOf(Aes256Secret));
  SetLength(Payload, 21);
  FillChar(Payload[0], 21, 0);
  Payload[0] := 1;
  CheckLongPacket(Keys, '4101020304050607081234', $1234, 2, @Payload[0], 21, @Aes256ShortPacket[0],
    SizeOf(Aes256ShortPacket), 8, 'AES-256-GCM short header');
end;

procedure TestChaChaShortPacket;
var
  Secret, Expected: TByteArray;
  Keys, Next: TQuicPacketKeys;
  Packet: array[0..20] of Byte;
  Mask: TQuicHeaderMask;
begin
  Secret := HexToBytes('9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b');
  DerivePacketKeys(Keys, AeadChaCha20Poly1305, DigestSha256, @Secret[0], 32);
  CheckBytes(@Keys.Key[0], 32, 'c6d98ff3441c3fe1b2182094f69caa2ed4b716b65488960a7a984979fb23e1c8', 'A.5 key');
  CheckBytes(@Keys.Iv[0], 12, 'e0459b3474bdd0e44a41c144', 'A.5 iv');
  CheckBytes(@Keys.HeaderKey[0], 32, '25a282b9e82f06f21f488917a4fc8f1b73573685608597d0efcb076b0ab7a7a4', 'A.5 hp');
  DeriveNextPhaseKeys(Keys, Next);
  CheckBytes(@Next.Secret[0], 32, '1223504755036d556342ee9361d253421a826c9ecdf3c7148684b36b714881f9', 'A.5 ku');
  Check(CompareByte(Next.HeaderKey[0], Keys.HeaderKey[0], 32) = 0, 'key update keeps the header key');
  { Header 4200bff4 (packet number 654360564 in 3 bytes), payload 01. }
  Packet[0] := $42;
  Packet[1] := $00;
  Packet[2] := $BF;
  Packet[3] := $F4;
  Packet[4] := $01;
  SealPayload(Keys, 654360564, @Packet[0], 4, @Packet[4], 1);
  ComputeHeaderMask(Keys, @Packet[1 + 4], Mask);
  CheckBytes(@Mask[0], 5, 'aefefe7d03', 'A.5 mask');
  ApplyHeaderMask(@Packet[0], 1, 3, Mask);
  Expected := HexToBytes('4cfe4189655e5cd55c41f69080575d7999c25a5bfb');
  CheckBytes(@Packet[0], 21, BytesToHex(@Expected[0], Length(Expected)), 'A.5 ChaCha20 short header packet');
  Check(DecodePacketNumber(654360563, $BFF4, 3) = 654360564, 'A.5 packet number decoded');
end;

procedure TestRetry;
var
  Packet: TByteArray;
begin
  Packet := HexToBytes('ff000000010008f067a5502a4262b5746f6b656e04a265ba2eff4d829058fb3f0f2496ba');
  Check(RetryIntegrityTagIsValid(IdFromHex('8394c8f03e515708'), @Packet[0], Length(Packet)), 'A.4 Retry tag');
  Packet[Length(Packet) - 1] := Packet[Length(Packet) - 1] xor 1;
  Check(not RetryIntegrityTagIsValid(IdFromHex('8394c8f03e515708'), @Packet[0], Length(Packet)),
    'A.4 Retry tag tampered');
end;

procedure TestPacketNumbers;
begin
  { RFC 9000 A.3's example. }
  Check(DecodePacketNumber($a82f30ea, $9b32, 2) = $a82f9b32, 'A.3 packet number decoding');
  Check(PacketNumberLength($ac5c02, $abe8b3) = 2, 'A.2 packet number length: 2 bytes');
  Check(PacketNumberLength($ace8fe, $abe8b3) = 3, 'A.2 packet number length: 3 bytes');
  Check(DecodePacketNumber(-1, 0, 1) = 0, 'first packet number');
  Check(DecodePacketNumber(255, 0, 1) = 256, 'packet number wraps forward');
end;

procedure RunProtectionTests;
begin
  TestInitialKeys;
  TestWholePackets;
  TestChaChaShortPacket;
  TestRetry;
  TestPacketNumbers;
end;

end.
