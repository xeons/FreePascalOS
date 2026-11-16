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
  ChaCha20-Poly1305 authenticated encryption with additional data (RFC
  8439, section 2.8): a 32-byte key and a 12-byte nonce encrypt a
  message and authenticate it together with data sent in the clear,
  under a 16-byte tag.

  Opening checks the tag (in constant time) before anything is
  decrypted, and writes no plaintext when it does not match. The
  plaintext and ciphertext may be the same buffer.
}
unit Crypto.ChaCha20Poly1305;

{$mode objfpc}
{$pointermath on}

interface

const
  ChaCha20Poly1305KeySize = 32;
  ChaCha20Poly1305NonceSize = 12;
  ChaCha20Poly1305TagSize = 16;

procedure SealChaCha20Poly1305(Key, Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Plaintext: PByte; Length: QWord; Ciphertext: PByte; Tag: PByte);

{ False (and nothing written) when the tag does not match. }
function OpenChaCha20Poly1305(Key, Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Ciphertext: PByte; Length: QWord; Tag: PByte; Plaintext: PByte): Boolean;

implementation

uses
  Crypto.Bits,
  Crypto.ChaCha20,
  Crypto.Poly1305;

{ The Poly1305 key is the first half of the key stream block with
  counter 0. }
procedure DerivePoly1305Key(Key, Nonce: PByte; out OneTimeKey: array of Byte);
var
  Cipher: TChaCha20Context;
  Zeros: array[0..Poly1305KeySize - 1] of Byte;
  Index: Integer;
begin
  for Index := 0 to Poly1305KeySize - 1 do
    Zeros[Index] := 0;
  BeginChaCha20(Cipher, Key, Nonce, 0);
  ApplyChaCha20(Cipher, @Zeros[0], @OneTimeKey[0], Poly1305KeySize);
  EndChaCha20(Cipher);
end;

procedure UpdateWithPadding(var Authenticator: TPoly1305Context; Count: QWord);
var
  Zeros: array[0..15] of Byte;
  Index: Integer;
begin
  if (Count and 15) = 0 then
    Exit;
  for Index := 0 to 15 do
    Zeros[Index] := 0;
  UpdatePoly1305(Authenticator, @Zeros[0], 16 - (Count and 15));
end;

{ The tag over AAD | pad | ciphertext | pad | lengths. }
procedure ComputeTag(Key, Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Ciphertext: PByte; Length: QWord; Tag: PByte);
var
  OneTimeKey: array[0..Poly1305KeySize - 1] of Byte;
  Authenticator: TPoly1305Context;
  Lengths: array[0..15] of Byte;
begin
  DerivePoly1305Key(Key, Nonce, OneTimeKey);
  BeginPoly1305(Authenticator, @OneTimeKey[0]);
  WipeMemory(@OneTimeKey[0], SizeOf(OneTimeKey));
  if AdditionalLength > 0 then
    UpdatePoly1305(Authenticator, AdditionalData, AdditionalLength);
  UpdateWithPadding(Authenticator, AdditionalLength);
  if Length > 0 then
    UpdatePoly1305(Authenticator, Ciphertext, Length);
  UpdateWithPadding(Authenticator, Length);
  StoreLittleEndian64(@Lengths[0], AdditionalLength);
  StoreLittleEndian64(@Lengths[8], Length);
  UpdatePoly1305(Authenticator, @Lengths[0], 16);
  FinishPoly1305(Authenticator, Tag);
end;

procedure SealChaCha20Poly1305(Key, Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Plaintext: PByte; Length: QWord; Ciphertext: PByte; Tag: PByte);
var
  Cipher: TChaCha20Context;
begin
  BeginChaCha20(Cipher, Key, Nonce, 1);
  if Length > 0 then
    ApplyChaCha20(Cipher, Plaintext, Ciphertext, Length);
  EndChaCha20(Cipher);
  ComputeTag(Key, Nonce, AdditionalData, AdditionalLength, Ciphertext, Length, Tag);
end;

function OpenChaCha20Poly1305(Key, Nonce: PByte; AdditionalData: PByte; AdditionalLength: QWord;
  Ciphertext: PByte; Length: QWord; Tag: PByte; Plaintext: PByte): Boolean;
var
  ExpectedTag: array[0..ChaCha20Poly1305TagSize - 1] of Byte;
  Cipher: TChaCha20Context;
begin
  ComputeTag(Key, Nonce, AdditionalData, AdditionalLength, Ciphertext, Length, @ExpectedTag[0]);
  Result := ConstantTimeEqual(@ExpectedTag[0], Tag, ChaCha20Poly1305TagSize);
  WipeMemory(@ExpectedTag[0], SizeOf(ExpectedTag));
  if not Result then
    Exit;
  BeginChaCha20(Cipher, Key, Nonce, 1);
  if Length > 0 then
    ApplyChaCha20(Cipher, Ciphertext, Plaintext, Length);
  EndChaCha20(Cipher);
end;

end.
