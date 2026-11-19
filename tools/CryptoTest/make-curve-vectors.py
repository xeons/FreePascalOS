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

"""Writes CryptoTest.CurveVectors.inc (at build time): ECDH on P-256,
P-384 and P-521 and ECDSA P-521 signatures, made by Python's
cryptography package (OpenSSL underneath) from fixed private keys.

    python3 -I tools/CryptoTest/make-curve-vectors.py > build/tools/crypto-test-units/CryptoTest.CurveVectors.inc
"""

import hashlib

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

CURVES = [("CurveP256", ec.SECP256R1(), 32), ("CurveP384", ec.SECP384R1(), 48), ("CurveP521", ec.SECP521R1(), 66)]


def pascal_hex(data):
    text = data.hex().upper()
    if not text:
        return "''"
    chunks = [text[i:i + 96] for i in range(0, len(text), 96)]
    return " +\n    ".join("'" + chunk + "'" for chunk in chunks)


def private_key(curve, size, label):
    """A fixed private key in [1, n - 1] made from a label."""
    digest = hashlib.shake_256(label.encode()).digest(size)
    value = int.from_bytes(digest, "big") >> (size * 8 - curve.key_size)
    return ec.derive_private_key(value % (2 ** curve.key_size - 2) + 1, curve)


def point(key):
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def scalar(key, size):
    return key.private_numbers().private_value.to_bytes(size, "big")


def main():
    print("{ Made by tools/CryptoTest/make-curve-vectors.py; do not edit. }")
    print("type")
    print("  TEcdhVector = record")
    print("    Curve: TCurveName;")
    print("    PrivateKey, PublicKey, PeerPublicKey, SharedSecret: string;")
    print("  end;")
    print("  TEcdsaVector = record")
    print("    Curve: TCurveName;")
    print("    Algorithm: TDigestAlgorithm;")
    print("    PrivateKey, PublicKey, Message, R, S: string;")
    print("    Deterministic: Boolean;")
    print("  end;")
    print()
    ecdh = []
    for name, curve, size in CURVES:
        for round_number in range(2):
            mine = private_key(curve, size, "ecdh %s %d mine" % (name, round_number))
            peer = private_key(curve, size, "ecdh %s %d peer" % (name, round_number))
            shared = mine.exchange(ec.ECDH(), peer.public_key())
            ecdh.append((name, scalar(mine, size), point(mine), point(peer), shared))
    print("const")
    print("  EcdhVectors: array[0..%d] of TEcdhVector = (" % (len(ecdh) - 1))
    entries = []
    for name, d, public, peer, shared in ecdh:
        entries.append("    (Curve: %s;\n    PrivateKey: %s;\n    PublicKey: %s;\n    PeerPublicKey: %s;\n"
                       "    SharedSecret: %s)" % (name, pascal_hex(d), pascal_hex(public), pascal_hex(peer),
                                                   pascal_hex(shared)))
    print(",\n".join(entries) + ");")
    print()

    signatures = []
    for name, curve, size in CURVES[2:]:
        for algorithm_name, algorithm in (("DigestSha512", hashes.SHA512()), ("DigestSha256", hashes.SHA256())):
            for message in (b"sample", b"test"):
                key = private_key(curve, size, "ecdsa %s %s" % (name, message.decode()))
                for deterministic in (True, False):
                    der = key.sign(message, ec.ECDSA(algorithm, deterministic_signing=deterministic))
                    r, s = decode_dss_signature(der)
                    signatures.append((name, algorithm_name, scalar(key, size), point(key), message,
                                       r.to_bytes(size, "big"), s.to_bytes(size, "big"), deterministic))
    print("  EcdsaVectors: array[0..%d] of TEcdsaVector = (" % (len(signatures) - 1))
    entries = []
    for name, algorithm_name, d, public, message, r, s, deterministic in signatures:
        entries.append("    (Curve: %s; Algorithm: %s;\n    PrivateKey: %s;\n    PublicKey: %s;\n"
                       "    Message: '%s';\n    R: %s;\n    S: %s;\n    Deterministic: %s)"
                       % (name, algorithm_name, pascal_hex(d), pascal_hex(public), message.decode(),
                          pascal_hex(r), pascal_hex(s), "True" if deterministic else "False"))
    print(",\n".join(entries) + ");")


main()
