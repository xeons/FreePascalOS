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
  end;

procedure SetRecordProtection(out Protection: TRecordProtection; constref Suite: TCipherSuiteInfo;
  constref Secret: TTlsSecret);
procedure WipeRecordProtection(var Protection: TRecordProtection);

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

end.
