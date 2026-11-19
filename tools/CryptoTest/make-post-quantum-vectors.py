#!/usr/bin/env python3
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Writes CryptoTest.PostQuantumVectors.inc (at build time): known
answers for SHA-3 and SHAKE from Python's hashlib, and for ML-KEM-768
(FIPS 203) from the cryptography package (OpenSSL 3.5 or later):

  - encapsulation keys made from fixed seeds d || z;
  - ciphertexts OpenSSL encapsulated to them, with the shared secret;
  - a changed ciphertext, with the secret implicit rejection gives
    (OpenSSL's own decapsulation of it).

    python3 tools/CryptoTest/make-post-quantum-vectors.py > build/tools/crypto-test-units/CryptoTest.PostQuantumVectors.inc
"""

import hashlib

from cryptography.hazmat.primitives.asymmetric import mlkem


def pattern(size, seed):
    return bytes((seed + i * 37 + (i >> 3)) & 0xFF for i in range(size))


lines = []


def constant(name, data):
    text = data.hex()
    pieces = [text[i:i + 64] for i in range(0, len(text), 64)] or [""]
    lines.append("  %s = '%s';" % (name, "' +\n    '".join(pieces)))


long_input = pattern(500, 3)
constant("KeccakLongInput", long_input)
constant("Sha3_256Empty", hashlib.sha3_256(b"").digest())
constant("Sha3_256Abc", hashlib.sha3_256(b"abc").digest())
constant("Sha3_256Long", hashlib.sha3_256(long_input).digest())
constant("Sha3_512Abc", hashlib.sha3_512(b"abc").digest())
constant("Sha3_512Long", hashlib.sha3_512(long_input).digest())
constant("Shake128Empty", hashlib.shake_128(b"").digest(32))
constant("Shake128Long", hashlib.shake_128(long_input).digest(400))
constant("Shake256Abc", hashlib.shake_256(b"abc").digest(64))
constant("Shake256Long", hashlib.shake_256(long_input).digest(300))

for index, seed_byte in enumerate((1, 77, 200), start=1):
    seed = pattern(64, seed_byte)
    private_key = mlkem.MLKEM768PrivateKey.from_seed_bytes(seed)
    public_key = private_key.public_key()
    shared_secret, ciphertext = public_key.encapsulate()
    assert private_key.decapsulate(ciphertext) == shared_secret
    changed = bytearray(ciphertext)
    changed[(index * 397) % len(changed)] ^= 0x10
    changed = bytes(changed)
    constant("MlKemSeed%d" % index, seed)
    constant("MlKemEncapsulationKey%d" % index, public_key.public_bytes_raw())
    constant("MlKemCiphertext%d" % index, ciphertext)
    constant("MlKemSharedSecret%d" % index, shared_secret)
    constant("MlKemChangedCiphertext%d" % index, changed)
    constant("MlKemRejectionSecret%d" % index, private_key.decapsulate(changed))

print("{ Made by tools/CryptoTest/make-post-quantum-vectors.py; do not edit. }")
print("const")
print("\n".join(lines))
