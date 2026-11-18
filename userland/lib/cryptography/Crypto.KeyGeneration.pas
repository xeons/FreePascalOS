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
  New private keys from the random number generator: an Ed25519 seed
  (32 random bytes, Crypto.Ed25519 gives its public key) and an ECDSA
  private key d, uniform in [1, n - 1] (Crypto.Ecdsa gives d G).
}
unit Crypto.KeyGeneration;

{$mode objfpc}

interface

uses
  Crypto.EllipticCurves;

procedure GenerateEd25519Seed(Seed: PByte);
{ Writes the curve's coordinate size in bytes (32 for P-256). }
procedure GenerateEcdsaPrivateKey(Curve: TCurveName; PrivateKey: PByte);

implementation

uses
  Crypto.Bits,
  Crypto.BigNumbers,
  Crypto.Random,
  Crypto.Ed25519;

procedure GenerateEd25519Seed(Seed: PByte);
begin
  RandomBytes(Seed, Ed25519SeedSize);
end;

procedure GenerateEcdsaPrivateKey(Curve: TCurveName; PrivateKey: PByte);
var
  Parameters: TEllipticCurve;
  Candidate: TBigNumber;
begin
  PrepareCurve(Curve, Parameters);
  { Rejection sampling: n is just below 2^(8 size) for these curves, so
    a retry is very rare. }
  repeat
    RandomBytes(PrivateKey, Parameters.CoordinateBytes);
    BigNumberFromBytes(Candidate, PrivateKey, Parameters.CoordinateBytes);
  until (not BigNumberIsZero(Candidate)) and (CompareBigNumbers(Candidate, Parameters.Order.Modulus) < 0);
  WipeMemory(@Candidate, SizeOf(Candidate));
end;

end.
