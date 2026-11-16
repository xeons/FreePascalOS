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
  HKDF (RFC 5869), the HMAC based key derivation function, over any
  digest of Crypto.Digests (TLS 1.3 uses SHA-256 and SHA-384):

    HkdfExtract(DigestSha256, Salt, SaltLength, Secret, SecretLength, Key);
    HkdfExpand(DigestSha256, @Key[0], 32, Info, InfoLength, Output, 42);
}
unit Crypto.Hkdf;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Digests;

{ PRK = HMAC-Hash(salt, IKM); an empty salt stands for a string of zeros
  as long as the digest. Writes DigestSize bytes to PseudoRandomKey. }
procedure HkdfExtract(Algorithm: TDigestAlgorithm; Salt: PByte; SaltLength: QWord; InputKey: PByte;
  InputKeyLength: QWord; out PseudoRandomKey: TDigestOutput);

{ OKM = T(1) | T(2) | ... cut to OutputLength bytes. False (nothing
  written) when OutputLength is more than 255 digests. }
function HkdfExpand(Algorithm: TDigestAlgorithm; PseudoRandomKey: PByte; PseudoRandomKeyLength: QWord;
  Info: PByte; InfoLength: QWord; Output: PByte; OutputLength: QWord): Boolean;

implementation

uses
  Crypto.Bits,
  Crypto.Hmac;

procedure HkdfExtract(Algorithm: TDigestAlgorithm; Salt: PByte; SaltLength: QWord; InputKey: PByte;
  InputKeyLength: QWord; out PseudoRandomKey: TDigestOutput);
var
  Zeros: TDigestOutput;
begin
  if SaltLength = 0 then
  begin
    FillChar(Zeros, SizeOf(Zeros), 0);
    ComputeHmac(Algorithm, @Zeros[0], QWord(DigestSize(Algorithm)), InputKey, InputKeyLength, PseudoRandomKey);
  end
  else
    ComputeHmac(Algorithm, Salt, SaltLength, InputKey, InputKeyLength, PseudoRandomKey);
end;

function HkdfExpand(Algorithm: TDigestAlgorithm; PseudoRandomKey: PByte; PseudoRandomKeyLength: QWord;
  Info: PByte; InfoLength: QWord; Output: PByte; OutputLength: QWord): Boolean;
var
  HashLength: QWord;
  Previous: TDigestOutput;
  PreviousLength: QWord;
  Mac: THmacContext;
  BlockNumber: Byte;
  Written: QWord;
  Take: QWord;
begin
  HashLength := QWord(DigestSize(Algorithm));
  if OutputLength > 255 * HashLength then
    Exit(False);
  PreviousLength := 0;
  BlockNumber := 0;
  Written := 0;
  while Written < OutputLength do
  begin
    Inc(BlockNumber);
    BeginHmac(Mac, Algorithm, PseudoRandomKey, PseudoRandomKeyLength);
    if PreviousLength > 0 then
      UpdateHmac(Mac, @Previous[0], PreviousLength);
    if InfoLength > 0 then
      UpdateHmac(Mac, Info, InfoLength);
    UpdateHmac(Mac, @BlockNumber, 1);
    FinishHmac(Mac, Previous);
    PreviousLength := HashLength;
    Take := OutputLength - Written;
    if Take > HashLength then
      Take := HashLength;
    Move(Previous[0], Output[Written], Take);
    Written := Written + Take;
  end;
  WipeMemory(@Previous[0], SizeOf(Previous));
  Result := True;
end;

end.
