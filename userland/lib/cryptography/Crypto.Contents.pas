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
  The contents of libcryptography.so: hashes, checksums, ciphers,
  authenticated encryption, key derivation and exchange, signature
  checks and random numbers. Compiling this unit compiles all of them.
}
unit Crypto.Contents;

{$mode objfpc}

interface

uses
  Crypto.Bits,
  Crypto.Md5,
  Crypto.Sha1,
  Crypto.Sha256,
  Crypto.Sha512,
  Crypto.Blake2b,
  Crypto.Digests,
  Crypto.Hmac,
  Crypto.Checksums,
  Crypto.ChaCha20,
  Crypto.Aes,
  Crypto.AesInstructions,
  Crypto.Random,
  Crypto.Poly1305,
  Crypto.ChaCha20Poly1305,
  Crypto.Ghash,
  Crypto.AesGcm,
  Crypto.Hkdf,
  Crypto.Curve25519Field,
  Crypto.X25519,
  Crypto.Ed25519,
  Crypto.BigNumbers,
  Crypto.Rsa,
  Crypto.EllipticCurves,
  Crypto.Ecdsa,
  Crypto.KeyGeneration,
  Crypto.Ecdh,
  Crypto.Sha3,
  Crypto.MlKemPolynomials,
  Crypto.MlKem,
  Crypto.MlKemRandom,
  Crypto.P256;

implementation

end.
