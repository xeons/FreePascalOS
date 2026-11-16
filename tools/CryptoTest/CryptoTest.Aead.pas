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
  Known answers for Poly1305 and ChaCha20-Poly1305 (RFC 8439 sections
  2.5.2, 2.8.2 and appendix A.3) and AES-GCM (the test cases of McGrew
  and Viega's GCM specification, which NIST SP 800-38D refers to), with
  and without the processor's AES instructions; tampered messages must
  be refused.
}
unit CryptoTest.Aead;

{$mode objfpc}
{$H+}

interface

procedure TestPoly1305;
procedure TestChaCha20Poly1305;
procedure TestAesGcm;

implementation

uses
  SysUtils,
  TestChecks,
  Crypto.Aes,
  Crypto.AesGcm,
  Crypto.Poly1305,
  Crypto.ChaCha20Poly1305;

{ A deterministic message of Count bytes: i * 7 mod 256. }
function PatternBytes(Count: Integer): TByteArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Byte(Index * 7);
end;

procedure CheckPoly1305(const KeyHex, DataHex, TagHex, Name: string);
var
  Key, Data: TByteArray;
  Tag: array[0..15] of Byte;
begin
  Key := HexToBytes(KeyHex);
  Data := HexToBytes(DataHex);
  ComputePoly1305(@Key[0], @Data[0], Length(Data), @Tag[0]);
  CheckBytes(@Tag[0], 16, TagHex, Name);
end;

procedure TestPoly1305;
var
  Key, Data: TByteArray;
  Tag: array[0..15] of Byte;
  Context: TPoly1305Context;
  Offset: Integer;
begin
  Key := HexToBytes('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b');
  Data := TextBytes('Cryptographic Forum Research Group');
  ComputePoly1305(@Key[0], @Data[0], Length(Data), @Tag[0]);
  CheckBytes(@Tag[0], 16, 'a8061dc1305136c6c22b8baf0c0127a9', 'Poly1305: RFC 8439 2.5.2');

  { Appendix A.3, the vectors about the reductions: key = r || s. }
  CheckPoly1305('02000000000000000000000000000000' + '00000000000000000000000000000000',
    'ffffffffffffffffffffffffffffffff', '03000000000000000000000000000000', 'Poly1305: A.3 #5');
  CheckPoly1305('02000000000000000000000000000000' + 'ffffffffffffffffffffffffffffffff',
    '02000000000000000000000000000000', '03000000000000000000000000000000', 'Poly1305: A.3 #6');
  CheckPoly1305('01000000000000000000000000000000' + '00000000000000000000000000000000',
    'ffffffffffffffffffffffffffffffff' + 'f0ffffffffffffffffffffffffffffff' + '11000000000000000000000000000000',
    '05000000000000000000000000000000', 'Poly1305: A.3 #7');
  CheckPoly1305('01000000000000000000000000000000' + '00000000000000000000000000000000',
    'ffffffffffffffffffffffffffffffff' + 'fbfefefefefefefefefefefefefefefe' + '01010101010101010101010101010101',
    '00000000000000000000000000000000', 'Poly1305: A.3 #8');
  CheckPoly1305('02000000000000000000000000000000' + '00000000000000000000000000000000',
    'fdffffffffffffffffffffffffffffff', 'faffffffffffffffffffffffffffffff', 'Poly1305: A.3 #9');
  CheckPoly1305('01000000000000000400000000000000' + '00000000000000000000000000000000',
    'e33594d7505e43b90000000000000000' + '3394d7505e4379cd0100000000000000' +
    '00000000000000000000000000000000' + '01000000000000000000000000000000',
    '14000000000000005500000000000000', 'Poly1305: A.3 #10');
  CheckPoly1305('01000000000000000400000000000000' + '00000000000000000000000000000000',
    'e33594d7505e43b90000000000000000' + '3394d7505e4379cd0100000000000000' +
    '00000000000000000000000000000000',
    '13000000000000000000000000000000', 'Poly1305: A.3 #11');

  { A long message fed in uneven pieces (the tag from OpenSSL). }
  Key := PatternBytes(0);
  SetLength(Key, 32);
  for Offset := 0 to 31 do
    Key[Offset] := Offset;
  Data := PatternBytes(1000);
  BeginPoly1305(Context, @Key[0]);
  Offset := 0;
  while Offset < 1000 do
  begin
    if 1000 - Offset >= 37 then
      UpdatePoly1305(Context, @Data[Offset], 37)
    else
      UpdatePoly1305(Context, @Data[Offset], 1000 - Offset);
    Offset := Offset + 37;
  end;
  FinishPoly1305(Context, @Tag[0]);
  CheckBytes(@Tag[0], 16, 'c101423b6c66ee591d4c2448293c728d', 'Poly1305: 1000 bytes in pieces of 37');
end;

procedure TestChaCha20Poly1305;
var
  Key, Nonce, Additional, Plaintext, Ciphertext, Opened: TByteArray;
  Tag: array[0..15] of Byte;
  Index: Integer;
begin
  { RFC 8439 2.8.2. }
  SetLength(Key, 32);
  for Index := 0 to 31 do
    Key[Index] := $80 + Index;
  Nonce := HexToBytes('070000004041424344454647');
  Additional := HexToBytes('50515253c0c1c2c3c4c5c6c7');
  Plaintext := TextBytes('Ladies and Gentlemen of the class of ''99: If I could offer you only one tip for ' +
    'the future, sunscreen would be it.');
  SetLength(Ciphertext, Length(Plaintext));
  SealChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Plaintext[0], Length(Plaintext),
    @Ciphertext[0], @Tag[0]);
  CheckBytes(@Ciphertext[0], Length(Ciphertext),
    'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e06' +
    '0b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d2' +
    '6586cec64b6116', 'ChaCha20-Poly1305: RFC 8439 2.8.2 ciphertext');
  CheckBytes(@Tag[0], 16, '1ae10b594f09e26a7e902ecbd0600691', 'ChaCha20-Poly1305: RFC 8439 2.8.2 tag');

  SetLength(Opened, Length(Ciphertext));
  Check(OpenChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0],
    Length(Ciphertext), @Tag[0], @Opened[0]) and (BytesToHex(@Opened[0], Length(Opened)) =
    BytesToHex(@Plaintext[0], Length(Plaintext))), 'ChaCha20-Poly1305: opens');
  { In place. }
  Check(OpenChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0],
    Length(Ciphertext), @Tag[0], @Ciphertext[0]) and (BytesToHex(@Ciphertext[0], Length(Ciphertext)) =
    BytesToHex(@Plaintext[0], Length(Plaintext))), 'ChaCha20-Poly1305: opens in place');

  SealChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Plaintext[0], Length(Plaintext),
    @Ciphertext[0], @Tag[0]);
  Ciphertext[5] := Ciphertext[5] xor 1;
  FillChar(Opened[0], Length(Opened), $AA);
  Check(not OpenChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0],
    Length(Ciphertext), @Tag[0], @Opened[0]) and (Opened[0] = $AA), 'ChaCha20-Poly1305: changed ciphertext refused');
  Ciphertext[5] := Ciphertext[5] xor 1;
  Additional[0] := Additional[0] xor $80;
  Check(not OpenChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0],
    Length(Ciphertext), @Tag[0], @Opened[0]), 'ChaCha20-Poly1305: changed additional data refused');
  Additional[0] := Additional[0] xor $80;
  Tag[15] := Tag[15] xor $10;
  Check(not OpenChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0],
    Length(Ciphertext), @Tag[0], @Opened[0]), 'ChaCha20-Poly1305: changed tag refused');

  { A longer message (the tag from OpenSSL). }
  for Index := 0 to 31 do
    Key[Index] := Index;
  Nonce := HexToBytes('000000000000000000000000');
  Additional := TextBytes('hdr');
  Plaintext := PatternBytes(1000);
  SetLength(Ciphertext, 1000);
  SealChaCha20Poly1305(@Key[0], @Nonce[0], @Additional[0], 3, @Plaintext[0], 1000, @Ciphertext[0], @Tag[0]);
  CheckBytes(@Tag[0], 16, 'b107bbdac605e6e0cab39ee00d9764bc', 'ChaCha20-Poly1305: 1000 bytes');
end;

procedure CheckGcmCase(const KeyHex, NonceHex, PlainHex, AdditionalHex, CipherHex, TagHex, Name: string;
  UseInstructions: Boolean);
var
  Key: TAesGcmKey;
  KeyBytes, Nonce, Plaintext, Additional, Ciphertext, Opened: TByteArray;
  Tag: array[0..15] of Byte;
  Suffix: string;
begin
  KeyBytes := HexToBytes(KeyHex);
  Nonce := HexToBytes(NonceHex);
  Plaintext := HexToBytes(PlainHex);
  Additional := HexToBytes(AdditionalHex);
  if UseInstructions then
    Suffix := ' (AES instructions)'
  else
    Suffix := ' (tables)';
  Check(PrepareAesGcmKey(Key, @KeyBytes[0], Length(KeyBytes)), Name + ': key' + Suffix);
  if not UseInstructions then
    Key.Cipher.UsesInstructions := False;
  SetLength(Ciphertext, Length(Plaintext));
  SealAesGcm(Key, @Nonce[0], @Additional[0], Length(Additional), @Plaintext[0], Length(Plaintext),
    @Ciphertext[0], @Tag[0]);
  CheckBytes(@Ciphertext[0], Length(Ciphertext), CipherHex, Name + ': ciphertext' + Suffix);
  CheckBytes(@Tag[0], 16, TagHex, Name + ': tag' + Suffix);
  SetLength(Opened, Length(Plaintext));
  Check(OpenAesGcm(Key, @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0], Length(Ciphertext),
    @Tag[0], @Opened[0]) and (BytesToHex(@Opened[0], Length(Opened)) = BytesToHex(@Plaintext[0],
    Length(Plaintext))), Name + ': opens' + Suffix);
  Tag[0] := Tag[0] xor 1;
  Check(not OpenAesGcm(Key, @Nonce[0], @Additional[0], Length(Additional), @Ciphertext[0], Length(Ciphertext),
    @Tag[0], @Opened[0]), Name + ': changed tag refused' + Suffix);
  WipeAesGcmKey(Key);
end;

procedure TestAesGcm;
const
  Key3 = 'feffe9928665731c6d6a8f9467308308';
  Nonce3 = 'cafebabefacedbaddecaf888';
  Plain3 = 'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72' +
    '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255';
  Plain4 = 'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72' +
    '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39';
  Additional4 = 'feedfacedeadbeeffeedfacedeadbeefabaddad2';
var
  Pass: Integer;
  UseInstructions: Boolean;
  Key: TAesGcmKey;
  KeyBytes, Nonce, Additional, Plaintext, Ciphertext: TByteArray;
  Tag: array[0..15] of Byte;
  Index: Integer;
begin
  Check(True, 'AES instructions on this processor: ' + BoolToStr(AesIsConstantTime, True));
  for Pass := 0 to 1 do
  begin
    UseInstructions := Pass = 1;
    if UseInstructions and not AesIsConstantTime then
      Break;
    CheckGcmCase('00000000000000000000000000000000', '000000000000000000000000', '00000000000000000000000000000000',
      '', '0388dace60b6a392f328c2b971b2fe78', 'ab6e47d42cec13bdf53a67b21257bddf', 'AES-128-GCM case 2',
      UseInstructions);
    CheckGcmCase(Key3, Nonce3, Plain3, '',
      '42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e' +
      '21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985',
      '4d5c2af327cd64a62cf35abd2ba6fab4', 'AES-128-GCM case 3', UseInstructions);
    CheckGcmCase(Key3, Nonce3, Plain4, Additional4,
      '42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e' +
      '21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091',
      '5bc94fbc3221a5db94fae95ae7121a47', 'AES-128-GCM case 4', UseInstructions);
    CheckGcmCase('0000000000000000000000000000000000000000000000000000000000000000', '000000000000000000000000', '',
      '', '', '530f8afbc74536b9a963b4f1c4cb738b', 'AES-256-GCM case 13', UseInstructions);
    CheckGcmCase('0000000000000000000000000000000000000000000000000000000000000000', '000000000000000000000000',
      '00000000000000000000000000000000', '', 'cea7403d4d606b6e074ec5d3baf39d18',
      'd0d1c8a799996bf0265b98b5d48ab919', 'AES-256-GCM case 14', UseInstructions);
    CheckGcmCase(Key3 + Key3, Nonce3, Plain3, '',
      '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa' +
      '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad',
      'b094dac5d93471bdec1a502270e3cc6c', 'AES-256-GCM case 15', UseInstructions);
    CheckGcmCase(Key3 + Key3, Nonce3, Plain4, Additional4,
      '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa' +
      '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662',
      '76fc6ece0f4e1768cddf8853bb2d551b', 'AES-256-GCM case 16', UseInstructions);
  end;

  { A longer message (the tag from OpenSSL). }
  SetLength(KeyBytes, 32);
  for Index := 0 to 31 do
    KeyBytes[Index] := Index;
  Nonce := HexToBytes('000000000000000000000000');
  Additional := TextBytes('hdr');
  Plaintext := PatternBytes(1000);
  SetLength(Ciphertext, 1000);
  PrepareAesGcmKey(Key, @KeyBytes[0], 32);
  SealAesGcm(Key, @Nonce[0], @Additional[0], 3, @Plaintext[0], 1000, @Ciphertext[0], @Tag[0]);
  CheckBytes(@Tag[0], 16, '4af704d01ea82a274baab107fc7c6d70', 'AES-256-GCM: 1000 bytes');
  Check(not PrepareAesGcmKey(Key, @KeyBytes[0], 20), 'AES-GCM: a 20-byte key is refused');
end;

end.
