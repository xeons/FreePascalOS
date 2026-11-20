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
  Packet protection (RFC 9001 section 5): the keys of one direction of
  one encryption level, made from a TLS traffic secret with
  HKDF-Expand-Label ("quic key", "quic iv", "quic hp"), and what is done
  with them:

    payload   the AEAD of the suite (AES-128-GCM, AES-256-GCM or
              ChaCha20-Poly1305) with nonce = IV XOR the packet number
              and the header (packet number unprotected) as associated
              data
    header    a 5-byte mask from a 16-byte sample of the ciphertext,
              4 bytes after the packet number starts: AES-ECB of the
              sample, or ChaCha20 with the sample's first 4 bytes as
              the counter and the other 12 as nonce; it hides the low
              bits of the first byte (4 for a long header, 5 for a
              short one) and the packet number

  A key update (section 6) makes the next secret with "quic ku" and new
  AEAD keys from it; the header protection key stays.
}
unit Quic.PacketProtection;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Aes,
  Crypto.AesGcm,
  Crypto.Digests,
  Tls.CipherSuites;

type
  TQuicHeaderMask = array[0..4] of Byte;

  TQuicPacketKeys = record
    Ready: Boolean;
    Aead: TAeadKind;
    Hash: TDigestAlgorithm;
    Secret: array[0..MaximumDigestSize - 1] of Byte;
    SecretLength: Integer;
    Key: array[0..31] of Byte;
    KeyLength: Integer;
    Iv: array[0..11] of Byte;
    GcmKey: TAesGcmKey;
    HeaderKey: array[0..31] of Byte;
    HeaderAesKey: TAesKey;
  end;
  PQuicPacketKeys = ^TQuicPacketKeys;

{ Keys from a traffic secret of the suite (AeadAes128Gcm and SHA-256
  for Initial packets). }
procedure DerivePacketKeys(out Keys: TQuicPacketKeys; Aead: TAeadKind; Hash: TDigestAlgorithm; Secret: PByte;
  SecretLength: Integer);
{ The keys of the next key phase: a new secret and AEAD key and IV, the
  same header protection key. }
procedure DeriveNextPhaseKeys(constref Current: TQuicPacketKeys; out Next: TQuicPacketKeys);
procedure WipePacketKeys(var Keys: TQuicPacketKeys);
{ Encrypts PayloadLength bytes at Payload in place and appends the
  16-byte tag; Header (HeaderLength bytes, packet number in clear) is
  the associated data. }
procedure SealPayload(constref Keys: TQuicPacketKeys; PacketNumber: QWord; Header: PByte; HeaderLength: PtrUInt;
  Payload: PByte; PayloadLength: PtrUInt);
{ Decrypts in place (Length includes the tag): False when the tag does
  not match. The plaintext is Length - 16 bytes. }
function OpenPayload(constref Keys: TQuicPacketKeys; PacketNumber: QWord; Header: PByte; HeaderLength: PtrUInt;
  Payload: PByte; Length: PtrUInt): Boolean;
procedure ComputeHeaderMask(constref Keys: TQuicPacketKeys; Sample: PByte; out Mask: TQuicHeaderMask);
{ Masks (or unmasks) the first byte's low bits and the packet number
  of the packet at Packet. }
procedure ApplyHeaderMask(Packet: PByte; PacketNumberOffset: PtrUInt; PacketNumberLength: Integer;
  constref Mask: TQuicHeaderMask);

implementation

uses
  Crypto.Bits,
  Crypto.ChaCha20,
  Crypto.ChaCha20Poly1305,
  Tls.KeySchedule;

function AeadKeyLength(Aead: TAeadKind): Integer;
begin
  if Aead = AeadAes128Gcm then
    Result := 16
  else
    Result := 32;
end;

procedure PrepareAeadKeys(var Keys: TQuicPacketKeys);
begin
  if Keys.Aead <> AeadChaCha20Poly1305 then
    PrepareAesGcmKey(Keys.GcmKey, @Keys.Key[0], Keys.KeyLength);
end;

procedure DerivePacketKeys(out Keys: TQuicPacketKeys; Aead: TAeadKind; Hash: TDigestAlgorithm; Secret: PByte;
  SecretLength: Integer);
begin
  Keys := Default(TQuicPacketKeys);
  Keys.Aead := Aead;
  Keys.Hash := Hash;
  Keys.SecretLength := SecretLength;
  Move(Secret^, Keys.Secret[0], SecretLength);
  Keys.KeyLength := AeadKeyLength(Aead);
  ExpandLabel(Hash, Secret, 'quic key', nil, 0, @Keys.Key[0], Keys.KeyLength);
  ExpandLabel(Hash, Secret, 'quic iv', nil, 0, @Keys.Iv[0], 12);
  ExpandLabel(Hash, Secret, 'quic hp', nil, 0, @Keys.HeaderKey[0], Keys.KeyLength);
  PrepareAeadKeys(Keys);
  if Aead <> AeadChaCha20Poly1305 then
    ExpandAesKey(Keys.HeaderAesKey, @Keys.HeaderKey[0], Keys.KeyLength);
  Keys.Ready := True;
end;

procedure DeriveNextPhaseKeys(constref Current: TQuicPacketKeys; out Next: TQuicPacketKeys);
var
  NextSecret: array[0..MaximumDigestSize - 1] of Byte;
begin
  Next := Current;
  ExpandLabel(Current.Hash, @Current.Secret[0], 'quic ku', nil, 0, @NextSecret[0], Current.SecretLength);
  Move(NextSecret[0], Next.Secret[0], Current.SecretLength);
  ExpandLabel(Current.Hash, @NextSecret[0], 'quic key', nil, 0, @Next.Key[0], Next.KeyLength);
  ExpandLabel(Current.Hash, @NextSecret[0], 'quic iv', nil, 0, @Next.Iv[0], 12);
  PrepareAeadKeys(Next);
  WipeMemory(@NextSecret[0], SizeOf(NextSecret));
end;

procedure WipePacketKeys(var Keys: TQuicPacketKeys);
begin
  WipeMemory(@Keys, SizeOf(Keys));
end;

procedure MakeNonce(constref Keys: TQuicPacketKeys; PacketNumber: QWord; out Nonce: array of Byte);
var
  Index: Integer;
begin
  for Index := 0 to 11 do
    Nonce[Index] := Keys.Iv[Index];
  for Index := 0 to 7 do
    Nonce[11 - Index] := Nonce[11 - Index] xor Byte(PacketNumber shr (8 * Index));
end;

procedure SealPayload(constref Keys: TQuicPacketKeys; PacketNumber: QWord; Header: PByte; HeaderLength: PtrUInt;
  Payload: PByte; PayloadLength: PtrUInt);
var
  Nonce: array[0..11] of Byte;
begin
  MakeNonce(Keys, PacketNumber, Nonce);
  if Keys.Aead = AeadChaCha20Poly1305 then
    SealChaCha20Poly1305(@Keys.Key[0], @Nonce[0], Header, HeaderLength, Payload, PayloadLength, Payload,
      Payload + PayloadLength)
  else
    SealAesGcm(Keys.GcmKey, @Nonce[0], Header, HeaderLength, Payload, PayloadLength, Payload, Payload + PayloadLength);
end;

function OpenPayload(constref Keys: TQuicPacketKeys; PacketNumber: QWord; Header: PByte; HeaderLength: PtrUInt;
  Payload: PByte; Length: PtrUInt): Boolean;
var
  Nonce: array[0..11] of Byte;
  CipherLength: PtrUInt;
begin
  if Length < 16 then
    Exit(False);
  CipherLength := Length - 16;
  MakeNonce(Keys, PacketNumber, Nonce);
  if Keys.Aead = AeadChaCha20Poly1305 then
    Result := OpenChaCha20Poly1305(@Keys.Key[0], @Nonce[0], Header, HeaderLength, Payload, CipherLength,
      Payload + CipherLength, Payload)
  else
    Result := OpenAesGcm(Keys.GcmKey, @Nonce[0], Header, HeaderLength, Payload, CipherLength, Payload + CipherLength,
      Payload);
end;

procedure ComputeHeaderMask(constref Keys: TQuicPacketKeys; Sample: PByte; out Mask: TQuicHeaderMask);
var
  Block: TAesBlock;
  Context: TChaCha20Context;
  Zeros: array[0..4] of Byte;
  Counter: LongWord;
begin
  if Keys.Aead = AeadChaCha20Poly1305 then
  begin
    Counter := LoadLittleEndian32(Sample);
    FillChar(Zeros, SizeOf(Zeros), 0);
    BeginChaCha20(Context, @Keys.HeaderKey[0], Sample + 4, Counter);
    ApplyChaCha20(Context, @Zeros[0], @Mask[0], 5);
    EndChaCha20(Context);
    Exit;
  end;
  EncryptAesBlock(Keys.HeaderAesKey, Sample, @Block[0]);
  Move(Block[0], Mask[0], 5);
end;

procedure ApplyHeaderMask(Packet: PByte; PacketNumberOffset: PtrUInt; PacketNumberLength: Integer;
  constref Mask: TQuicHeaderMask);
var
  Index: Integer;
begin
  if (Packet[0] and $80) <> 0 then
    Packet[0] := Packet[0] xor (Mask[0] and $0F)
  else
    Packet[0] := Packet[0] xor (Mask[0] and $1F);
  for Index := 0 to PacketNumberLength - 1 do
    Packet[PacketNumberOffset + PtrUInt(Index)] := Packet[PacketNumberOffset + PtrUInt(Index)] xor Mask[1 + Index];
end;

end.
