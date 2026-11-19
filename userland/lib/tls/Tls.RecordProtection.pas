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
  Protecting records (RFC 8446 section 5.2): the keys of one direction,
  set from a traffic secret, and the sealing and opening of a record's
  payload with its AEAD. The nonce is the IV XOR the record's 64-bit
  sequence number; the additional data is the record header. Each
  record moves the sequence number on; it never wraps (the connection
  fails first).

  TLS 1.2 (RFC 5288, RFC 7905) protects records differently: the
  additional data is the sequence number, the content type, the
  version and the plaintext length; AES-GCM's nonce is a 4-byte
  implicit IV and an 8-byte explicit part sent before the ciphertext
  (here the sequence number); ChaCha20-Poly1305's is the 12-byte IV XOR
  the sequence number, as in TLS 1.3. There is no inner content type.
}
unit Tls.RecordProtection;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.AesGcm,
  Tls.CipherSuites,
  Tls.KeySchedule;

const
  AeadTagLength = 16;
  AeadNonceLength = 12;

type
  TRecordProtection = record
    Active: Boolean;
    Suite: TCipherSuiteInfo;
    Key: array[0..31] of Byte;
    Iv: array[0..AeadNonceLength - 1] of Byte;
    Sequence: QWord;
    GcmKey: TAesGcmKey;
    { TLS 1.2's record format. }
    Tls12: Boolean;
  end;

const
  { The explicit nonce TLS 1.2's AES-GCM records carry. }
  Tls12ExplicitNonceLength = 8;

procedure SetRecordProtection(out Protection: TRecordProtection; constref Suite: TCipherSuiteInfo;
  constref Secret: TTlsSecret);
procedure WipeRecordProtection(var Protection: TRecordProtection);
{ TLS 1.2: a key and IV from the key block (4 bytes of IV for AES-GCM,
  12 for ChaCha20-Poly1305). }
procedure SetTls12RecordProtection(out Protection: TRecordProtection; constref Suite: TCipherSuiteInfo; Key: PByte;
  Iv: PByte; IvLength: Integer);
{ The bytes a TLS 1.2 record's payload adds to its plaintext. }
function Tls12RecordExpansion(constref Protection: TRecordProtection): PtrUInt;
{ TLS 1.2: seals Length bytes of ContentType into Payload (explicit
  nonce, ciphertext, tag): Length + Tls12RecordExpansion bytes. }
function SealTls12Record(var Protection: TRecordProtection; ContentType: Byte; Plaintext: PByte; Length: PtrUInt;
  Payload: PByte): Boolean;
{ TLS 1.2: opens a record's payload in place; the plaintext is at
  Plaintext. False when it does not authenticate. }
function OpenTls12Record(var Protection: TRecordProtection; ContentType: Byte; Payload: PByte; Length: PtrUInt;
  out Plaintext: PByte; out PlaintextLength: PtrUInt): Boolean;

{ Seals Length bytes at Plaintext (the inner plaintext: content and its
  type) into Ciphertext, followed by the tag. Header is the 5-byte
  record header (with the protected length). False when the sequence
  numbers have run out. }
function SealRecord(var Protection: TRecordProtection; Header: PByte; Plaintext: PByte; Length: PtrUInt;
  Ciphertext: PByte): Boolean;
{ Opens a record payload (ciphertext and tag) in place; PlaintextLength
  is Length - 16. False when it does not authenticate. }
function OpenRecord(var Protection: TRecordProtection; Header: PByte; Payload: PByte; Length: PtrUInt;
  out PlaintextLength: PtrUInt): Boolean;

implementation

uses
  Crypto.Bits,
  Crypto.ChaCha20Poly1305;

procedure SetRecordProtection(out Protection: TRecordProtection; constref Suite: TCipherSuiteInfo;
  constref Secret: TTlsSecret);
begin
  FillChar(Protection, SizeOf(Protection), 0);
  Protection.Suite := Suite;
  DeriveTrafficKeys(Suite.Hash, @Secret[0], @Protection.Key[0], Suite.KeyLength, @Protection.Iv[0],
    AeadNonceLength);
  if Suite.Aead in [AeadAes128Gcm, AeadAes256Gcm] then
    PrepareAesGcmKey(Protection.GcmKey, @Protection.Key[0], Suite.KeyLength);
  Protection.Sequence := 0;
  Protection.Active := True;
end;

procedure WipeRecordProtection(var Protection: TRecordProtection);
begin
  WipeMemory(@Protection, SizeOf(Protection));
end;

procedure MakeNonce(constref Protection: TRecordProtection; out Nonce: array of Byte);
var
  Index: Integer;
begin
  for Index := 0 to AeadNonceLength - 1 do
    Nonce[Index] := Protection.Iv[Index];
  for Index := 0 to 7 do
    Nonce[AeadNonceLength - 1 - Index] := Nonce[AeadNonceLength - 1 - Index] xor
      Byte(Protection.Sequence shr (8 * Index));
end;

function SealRecord(var Protection: TRecordProtection; Header: PByte; Plaintext: PByte; Length: PtrUInt;
  Ciphertext: PByte): Boolean;
var
  Nonce: array[0..AeadNonceLength - 1] of Byte;
begin
  if Protection.Sequence = High(QWord) then
    Exit(False);
  MakeNonce(Protection, Nonce);
  if Protection.Suite.Aead = AeadChaCha20Poly1305 then
    SealChaCha20Poly1305(@Protection.Key[0], @Nonce[0], Header, 5, Plaintext, Length, Ciphertext,
      Ciphertext + Length)
  else
    SealAesGcm(Protection.GcmKey, @Nonce[0], Header, 5, Plaintext, Length, Ciphertext, Ciphertext + Length);
  Inc(Protection.Sequence);
  Result := True;
end;

function OpenRecord(var Protection: TRecordProtection; Header: PByte; Payload: PByte; Length: PtrUInt;
  out PlaintextLength: PtrUInt): Boolean;
var
  Nonce: array[0..AeadNonceLength - 1] of Byte;
begin
  PlaintextLength := 0;
  if (Length < AeadTagLength) or (Protection.Sequence = High(QWord)) then
    Exit(False);
  MakeNonce(Protection, Nonce);
  PlaintextLength := Length - AeadTagLength;
  if Protection.Suite.Aead = AeadChaCha20Poly1305 then
    Result := OpenChaCha20Poly1305(@Protection.Key[0], @Nonce[0], Header, 5, Payload, PlaintextLength,
      Payload + PlaintextLength, Payload)
  else
    Result := OpenAesGcm(Protection.GcmKey, @Nonce[0], Header, 5, Payload, PlaintextLength,
      Payload + PlaintextLength, Payload);
  if Result then
    Inc(Protection.Sequence)
  else
    PlaintextLength := 0;
end;

procedure SetTls12RecordProtection(out Protection: TRecordProtection; constref Suite: TCipherSuiteInfo; Key: PByte;
  Iv: PByte; IvLength: Integer);
begin
  FillChar(Protection, SizeOf(Protection), 0);
  Protection.Suite := Suite;
  Move(Key^, Protection.Key[0], Suite.KeyLength);
  Move(Iv^, Protection.Iv[0], IvLength);
  if Suite.Aead in [AeadAes128Gcm, AeadAes256Gcm] then
    PrepareAesGcmKey(Protection.GcmKey, @Protection.Key[0], Suite.KeyLength);
  Protection.Sequence := 0;
  Protection.Tls12 := True;
  Protection.Active := True;
end;

function Tls12RecordExpansion(constref Protection: TRecordProtection): PtrUInt;
begin
  if Protection.Suite.Aead = AeadChaCha20Poly1305 then
    Result := AeadTagLength
  else
    Result := Tls12ExplicitNonceLength + AeadTagLength;
end;

{ seq_num + type + version + length }
procedure MakeTls12AdditionalData(constref Protection: TRecordProtection; ContentType: Byte; Length: PtrUInt;
  out Data: array of Byte);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    Data[Index] := Byte(Protection.Sequence shr (8 * (7 - Index)));
  Data[8] := ContentType;
  Data[9] := 3;
  Data[10] := 3;
  Data[11] := Byte(Length shr 8);
  Data[12] := Byte(Length);
end;

{ AES-GCM: the implicit IV, then the sequence number as the explicit
  part. }
procedure MakeGcmNonce(constref Protection: TRecordProtection; out Nonce: array of Byte);
var
  Index: Integer;
begin
  for Index := 0 to 3 do
    Nonce[Index] := Protection.Iv[Index];
  for Index := 0 to 7 do
    Nonce[4 + Index] := Byte(Protection.Sequence shr (8 * (7 - Index)));
end;

function SealTls12Record(var Protection: TRecordProtection; ContentType: Byte; Plaintext: PByte; Length: PtrUInt;
  Payload: PByte): Boolean;
var
  Nonce: array[0..AeadNonceLength - 1] of Byte;
  AdditionalData: array[0..12] of Byte;
  Ciphertext: PByte;
begin
  if Protection.Sequence = High(QWord) then
    Exit(False);
  MakeTls12AdditionalData(Protection, ContentType, Length, AdditionalData);
  if Protection.Suite.Aead = AeadChaCha20Poly1305 then
  begin
    MakeNonce(Protection, Nonce);
    SealChaCha20Poly1305(@Protection.Key[0], @Nonce[0], @AdditionalData[0], 13, Plaintext, Length, Payload,
      Payload + Length);
  end
  else
  begin
    MakeGcmNonce(Protection, Nonce);
    { The plaintext may already sit where the ciphertext goes, or where
      the explicit nonce goes: move it into place first. }
    Ciphertext := Payload + Tls12ExplicitNonceLength;
    if Length > 0 then
      Move(Plaintext^, Ciphertext^, Length);
    Move(Nonce[4], Payload^, Tls12ExplicitNonceLength);
    SealAesGcm(Protection.GcmKey, @Nonce[0], @AdditionalData[0], 13, Ciphertext, Length, Ciphertext,
      Ciphertext + Length);
  end;
  Inc(Protection.Sequence);
  Result := True;
end;

function OpenTls12Record(var Protection: TRecordProtection; ContentType: Byte; Payload: PByte; Length: PtrUInt;
  out Plaintext: PByte; out PlaintextLength: PtrUInt): Boolean;
var
  Nonce: array[0..AeadNonceLength - 1] of Byte;
  AdditionalData: array[0..12] of Byte;
begin
  Plaintext := Payload;
  PlaintextLength := 0;
  if (Length < Tls12RecordExpansion(Protection)) or (Protection.Sequence = High(QWord)) then
    Exit(False);
  PlaintextLength := Length - Tls12RecordExpansion(Protection);
  MakeTls12AdditionalData(Protection, ContentType, PlaintextLength, AdditionalData);
  if Protection.Suite.Aead = AeadChaCha20Poly1305 then
  begin
    MakeNonce(Protection, Nonce);
    Result := OpenChaCha20Poly1305(@Protection.Key[0], @Nonce[0], @AdditionalData[0], 13, Payload,
      PlaintextLength, Payload + PlaintextLength, Payload);
  end
  else
  begin
    Move(Protection.Iv[0], Nonce[0], 4);
    Move(Payload^, Nonce[4], Tls12ExplicitNonceLength);
    Plaintext := Payload + Tls12ExplicitNonceLength;
    Result := OpenAesGcm(Protection.GcmKey, @Nonce[0], @AdditionalData[0], 13, Plaintext, PlaintextLength,
      Plaintext + PlaintextLength, Plaintext);
  end;
  if Result then
    Inc(Protection.Sequence)
  else
    PlaintextLength := 0;
end;

end.
