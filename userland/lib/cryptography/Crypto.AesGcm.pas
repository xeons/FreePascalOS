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
  AES-GCM authenticated encryption with additional data (NIST SP
  800-38D) with 128, 192 or 256 bit keys, 96-bit nonces (the size TLS
  and most protocols use; other sizes are refused) and 16-byte tags.

    PrepareAesGcmKey(Key, KeyBytes, 16);
    SealAesGcm(Key, Nonce, Data, DataLength, Plain, Length, Cipher, Tag);
    if not OpenAesGcm(Key, Nonce, Data, DataLength, Cipher, Length, Tag, Plain) then ...
    WipeAesGcmKey(Key);

  Opening checks the tag (in constant time) before anything is
  decrypted. The plaintext and ciphertext may be the same buffer.
  Constant time as a whole only when the processor has AES instructions
  (AesIsConstantTime); GHASH always is.
}
unit Crypto.AesGcm;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Aes;

const
  AesGcmNonceSize = 12;
  AesGcmTagSize = 16;

type
  TAesGcmKey = record
    Cipher: TAesKey;
    { H = the cipher applied to the zero block. }
    HashKey: TAesBlock;
  end;

{ KeyLength 16, 24 or 32; False otherwise. }
function PrepareAesGcmKey(out Key: TAesGcmKey; KeyBytes: PByte; KeyLength: Integer): Boolean;
procedure WipeAesGcmKey(var Key: TAesGcmKey);

procedure SealAesGcm(const Key: TAesGcmKey; Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Plaintext: PByte; Length: QWord; Ciphertext: PByte; Tag: PByte);

{ False (and nothing written) when the tag does not match. }
function OpenAesGcm(const Key: TAesGcmKey; Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Ciphertext: PByte; Length: QWord; Tag: PByte; Plaintext: PByte): Boolean;

implementation

uses
  Crypto.Bits,
  Crypto.Ghash;

function PrepareAesGcmKey(out Key: TAesGcmKey; KeyBytes: PByte; KeyLength: Integer): Boolean;
var
  Index: Integer;
begin
  Result := ExpandAesKey(Key.Cipher, KeyBytes, KeyLength);
  for Index := 0 to AesBlockSize - 1 do
    Key.HashKey[Index] := 0;
  if Result then
    EncryptAesBlock(Key.Cipher, @Key.HashKey[0], @Key.HashKey[0]);
end;

procedure WipeAesGcmKey(var Key: TAesGcmKey);
begin
  WipeMemory(@Key, SizeOf(Key));
end;

{ J0 = nonce || 0^31 || 1. }
procedure MakeInitialCounter(Nonce: PByte; out Counter: TAesBlock);
begin
  Move(Nonce^, Counter[0], AesGcmNonceSize);
  StoreBigEndian32(@Counter[12], 1);
end;

{ Adds one to the low 32 bits of the counter block (inc32). }
procedure IncrementCounter(var Counter: TAesBlock);
begin
  StoreBigEndian32(@Counter[12], LoadBigEndian32(@Counter[12]) + 1);
end;

{ GCTR starting from the block after J0. }
procedure ApplyCounterMode(const Key: TAesGcmKey; const InitialCounter: TAesBlock; Source: PByte;
  Length: QWord; Destination: PByte);
var
  Counter: TAesBlock;
  KeyStream: TAesBlock;
  Take: QWord;
  Index: QWord;
begin
  Counter := InitialCounter;
  while Length > 0 do
  begin
    IncrementCounter(Counter);
    EncryptAesBlock(Key.Cipher, @Counter[0], @KeyStream[0]);
    Take := AesBlockSize;
    if Take > Length then
      Take := Length;
    Index := 0;
    while Index < Take do
    begin
      Destination[Index] := Source[Index] xor KeyStream[Index];
      Inc(Index);
    end;
    Source := Source + Take;
    Destination := Destination + Take;
    Length := Length - Take;
  end;
  WipeMemory(@KeyStream[0], SizeOf(KeyStream));
end;

procedure ComputeTag(const Key: TAesGcmKey; const InitialCounter: TAesBlock; AdditionalData: PByte;
  AdditionalLength: QWord; Ciphertext: PByte; Length: QWord; Tag: PByte);
var
  Hash: TGhashContext;
  Lengths: array[0..15] of Byte;
  HashValue: TAesBlock;
  Mask: TAesBlock;
  Index: Integer;
begin
  BeginGhash(Hash, @Key.HashKey[0]);
  if AdditionalLength > 0 then
    UpdateGhash(Hash, AdditionalData, AdditionalLength);
  PadGhash(Hash);
  if Length > 0 then
    UpdateGhash(Hash, Ciphertext, Length);
  PadGhash(Hash);
  StoreBigEndian64(@Lengths[0], AdditionalLength * 8);
  StoreBigEndian64(@Lengths[8], Length * 8);
  UpdateGhash(Hash, @Lengths[0], 16);
  FinishGhash(Hash, @HashValue[0]);
  EncryptAesBlock(Key.Cipher, @InitialCounter[0], @Mask[0]);
  for Index := 0 to AesGcmTagSize - 1 do
    Tag[Index] := HashValue[Index] xor Mask[Index];
  WipeMemory(@Mask[0], SizeOf(Mask));
end;

procedure SealAesGcm(const Key: TAesGcmKey; Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Plaintext: PByte; Length: QWord; Ciphertext: PByte; Tag: PByte);
var
  InitialCounter: TAesBlock;
begin
  MakeInitialCounter(Nonce, InitialCounter);
  ApplyCounterMode(Key, InitialCounter, Plaintext, Length, Ciphertext);
  ComputeTag(Key, InitialCounter, AdditionalData, AdditionalLength, Ciphertext, Length, Tag);
end;

function OpenAesGcm(const Key: TAesGcmKey; Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Ciphertext: PByte; Length: QWord; Tag: PByte; Plaintext: PByte): Boolean;
var
  InitialCounter: TAesBlock;
  ExpectedTag: array[0..AesGcmTagSize - 1] of Byte;
begin
  MakeInitialCounter(Nonce, InitialCounter);
  ComputeTag(Key, InitialCounter, AdditionalData, AdditionalLength, Ciphertext, Length, @ExpectedTag[0]);
  Result := ConstantTimeEqual(@ExpectedTag[0], Tag, AesGcmTagSize);
  WipeMemory(@ExpectedTag[0], SizeOf(ExpectedTag));
  if Result then
    ApplyCounterMode(Key, InitialCounter, Ciphertext, Length, Plaintext);
end;

end.
