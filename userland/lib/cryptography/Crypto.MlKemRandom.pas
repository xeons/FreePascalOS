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
  ML-KEM-768 key generation and encapsulation with their randomness
  drawn from Crypto.Random (ML-KEM.KeyGen and ML-KEM.Encaps of FIPS 203).
  Kept apart from Crypto.MlKem so that the deterministic algorithms build
  without the kernel.
}
unit Crypto.MlKemRandom;

{$mode objfpc}
{$pointermath on}

interface

{ Writes a fresh 1184 byte encapsulation key and 2400 byte decapsulation key. }
procedure MlKem768GenerateKeyPair(EncapsulationKey, DecapsulationKey: PByte);

{ Writes the 1088 byte ciphertext and 32 byte shared secret for
  EncapsulationKey; False when the key is malformed. }
function MlKem768EncapsulateRandom(EncapsulationKey: PByte; Ciphertext, SharedSecret: PByte): Boolean;

implementation

uses
  Crypto.Bits,
  Crypto.Random,
  Crypto.MlKem;

procedure MlKem768GenerateKeyPair(EncapsulationKey, DecapsulationKey: PByte);
var
  Seed: array[0..MlKemKeySeedLength - 1] of Byte;
begin
  RandomBytes(@Seed[0], SizeOf(Seed));
  MlKem768KeyPairFromSeed(@Seed[0], EncapsulationKey, DecapsulationKey);
  WipeMemory(@Seed[0], SizeOf(Seed));
end;

function MlKem768EncapsulateRandom(EncapsulationKey: PByte; Ciphertext, SharedSecret: PByte): Boolean;
var
  Randomness: array[0..MlKemEncapsulationRandomnessLength - 1] of Byte;
begin
  RandomBytes(@Randomness[0], SizeOf(Randomness));
  Result := MlKem768Encapsulate(EncapsulationKey, @Randomness[0], Ciphertext, SharedSecret);
  WipeMemory(@Randomness[0], SizeOf(Randomness));
end;

end.
