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

"""Writes CryptoTest.RsaVectors.inc: RSA public keys and signatures made
by Python's cryptography package (OpenSSL), which CryptoTest checks.

    python3 tools/CryptoTest/make-rsa-vectors.py > tools/CryptoTest/CryptoTest.RsaVectors.inc

The keys are new on every run; the committed file is one such run.
"""

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

MESSAGE = b"FreePascalOS RSA signature test"

CASES = [
    # (key bits, hash, padding)
    (2048, "SHA256", "pkcs1"),
    (2048, "SHA256", "pss"),
    (3072, "SHA384", "pss"),
    (3072, "SHA384", "pkcs1"),
    (4096, "SHA512", "pkcs1"),
    (4096, "SHA512", "pss"),
]


def pascal_hex(data):
    text = data.hex()
    lines = [text[i:i + 96] for i in range(0, len(text), 96)]
    return " +\n      ".join("'" + line + "'" for line in lines)


def main():
    print("{ Made by tools/CryptoTest/make-rsa-vectors.py. }")
    print("type")
    print("  TRsaVector = record")
    print("    Modulus, Signature: PChar;")
    print("    Algorithm: TDigestAlgorithm;")
    print("    UsesPss: Boolean;")
    print("  end;")
    print("const")
    print(f"  RsaTestMessage: PChar = '{MESSAGE.decode()}';")
    keys = {}
    entries = []
    for bits, hash_name, scheme in CASES:
        if bits not in keys:
            keys[bits] = rsa.generate_private_key(public_exponent=65537, key_size=bits)
        key = keys[bits]
        algorithm = getattr(hashes, hash_name)()
        if scheme == "pss":
            pad = padding.PSS(mgf=padding.MGF1(algorithm), salt_length=algorithm.digest_size)
        else:
            pad = padding.PKCS1v15()
        signature = key.sign(MESSAGE, pad, algorithm)
        modulus = key.public_key().public_numbers().n.to_bytes(bits // 8, "big")
        entries.append((modulus, signature, hash_name, scheme))
    print(f"  RsaVectors: array[0..{len(CASES) - 1}] of TRsaVector = (")
    lines = []
    for modulus, signature, hash_name, scheme in entries:
        pss = "True" if scheme == "pss" else "False"
        lines.append(f"    (Modulus:\n      {pascal_hex(modulus)};\n"
                     f"     Signature:\n      {pascal_hex(signature)};\n"
                     f"     Algorithm: Digest{hash_name.capitalize()}; UsesPss: {pss})")
    print(",\n".join(lines) + ");")


if __name__ == "__main__":
    main()
