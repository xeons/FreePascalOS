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
  CryptoTest - checks the algorithms libcryptography gained for TLS on
  the host (make crypto-test): Poly1305, ChaCha20-Poly1305, AES-GCM,
  SHA-384, HKDF, X25519, big numbers, RSA, ECDSA (checking and
  signing) and Ed25519, each against
  published known answers. Prints one line per check and the totals;
  exits with 1 if any failed.
}
program CryptoTest;

{$mode objfpc}
{$H+}

uses
  TestChecks,
  CryptoTest.Aead,
  CryptoTest.KeyDerivation,
  CryptoTest.Signatures,
  CryptoTest.SshSignatures;

begin
  TestPoly1305;
  TestChaCha20Poly1305;
  TestAesGcm;
  TestDigests;
  TestHkdf;
  TestX25519;
  TestBigNumbers;
  TestRsa;
  TestEcdsa;
  TestEd25519;
  TestEcdsaSigning;
  FinishChecks('crypto test');
end.
