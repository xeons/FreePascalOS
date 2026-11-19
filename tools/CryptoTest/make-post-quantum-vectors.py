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

"""Writes CryptoTest.PostQuantumVectors.inc (at build time): SHA3-256,
SHA3-512, SHAKE128 and SHAKE256 answers from hashlib, and ML-KEM-768
keys, ciphertexts and shared secrets from Python's cryptography package
(OpenSSL), with the implicit rejection secret SHAKE256(z || c', 32) of a
ciphertext with one byte flipped.

    python3 -I tools/CryptoTest/make-post-quantum-vectors.py > build/tools/crypto-test-units/CryptoTest.PostQuantumVectors.inc
"""

import hashlib
import sys

from cryptography.hazmat.primitives.asymmetric import mlkem

# The rate boundaries of SHA3-512 (72), SHA3-256 and SHAKE256 (136) and
# SHAKE128 (168), and some multi-block lengths.
INPUT_LENGTHS = [0, 3, 71, 72, 73, 135, 136, 137, 167, 168, 169, 500, 1000]
SHAKE_OUTPUT_LENGTHS = [16, 32, 168, 200, 1000]
ALGORITHMS = ["Sha3_256", "Sha3_512", "Shake128", "Shake256"]
SEED_COUNT = 4


def test_input(length):
    """The same bytes CryptoTest.PostQuantum's TestInput makes."""
    return bytes((index * 7 + 3) % 251 for index in range(length))


def pascal_hex(data, indent="      "):
    """A PChar constant, split into lines of 96 hex digits."""
    text = data.hex()
    if not text:
        return "''"
    pieces = [text[offset:offset + 96] for offset in range(0, len(text), 96)]
    return (" +\n" + indent).join("'" + piece + "'" for piece in pieces)


def hash_output(algorithm, data, output_length):
    if algorithm == "Sha3_256":
        return hashlib.sha3_256(data).digest()
    if algorithm == "Sha3_512":
        return hashlib.sha3_512(data).digest()
    if algorithm == "Shake128":
        return hashlib.shake_128(data).digest(output_length)
    return hashlib.shake_256(data).digest(output_length)


def write_hash_vectors(out):
    vectors = []
    for algorithm in ALGORITHMS:
        output_lengths = SHAKE_OUTPUT_LENGTHS if algorithm.startswith("Shake") else [0]
        for input_length in INPUT_LENGTHS:
            for output_length in output_lengths:
                output = hash_output(algorithm, test_input(input_length), output_length)
                vectors.append((algorithm, input_length, len(output), output))
    out.write("  Sha3Vectors: array[0..%d] of TSha3Vector = (\n" % (len(vectors) - 1))
    lines = []
    for algorithm, input_length, output_length, output in vectors:
        lines.append("    (Algorithm: Hash%s; InputLength: %d; OutputLength: %d;\n     Output:\n      %s)"
                     % (algorithm, input_length, output_length, pascal_hex(output)))
    out.write(",\n".join(lines) + ");\n")


def write_kem_vectors(out):
    lines = []
    for index in range(SEED_COUNT):
        seed = hashlib.sha512(b"FreePascalOS ML-KEM seed %d" % index).digest()
        private_key = mlkem.MLKEM768PrivateKey.from_seed_bytes(seed)
        encapsulation_key = private_key.public_key().public_bytes_raw()
        shared_secret, ciphertext = private_key.public_key().encapsulate()
        assert private_key.decapsulate(ciphertext) == shared_secret
        flipped_index = (index * 397) % len(ciphertext)
        flipped = bytearray(ciphertext)
        flipped[flipped_index] ^= 1 << (index % 8)
        flipped = bytes(flipped)
        rejection_secret = hashlib.shake_256(seed[32:] + flipped).digest(32)
        assert private_key.decapsulate(flipped) == rejection_secret
        lines.append(
            "    (Seed:\n      %s;\n     EncapsulationKey:\n      %s;\n     Ciphertext:\n      %s;\n"
            "     SharedSecret:\n      %s;\n     FlippedIndex: %d; FlippedMask: %d;\n     RejectionSecret:\n      %s)"
            % (pascal_hex(seed), pascal_hex(encapsulation_key), pascal_hex(ciphertext),
               pascal_hex(shared_secret), flipped_index, 1 << (index % 8), pascal_hex(rejection_secret)))
    out.write("  MlKemVectors: array[0..%d] of TMlKemVector = (\n" % (SEED_COUNT - 1))
    out.write(",\n".join(lines) + ");\n")


def main():
    out = sys.stdout
    out.write("{ Made by tools/CryptoTest/make-post-quantum-vectors.py. }\n")
    out.write("type\n")
    out.write("  THashAlgorithm = (HashSha3_256, HashSha3_512, HashShake128, HashShake256);\n")
    out.write("  TSha3Vector = record\n")
    out.write("    Algorithm: THashAlgorithm;\n")
    out.write("    InputLength, OutputLength: Integer;\n")
    out.write("    Output: PChar;\n")
    out.write("  end;\n")
    out.write("  TMlKemVector = record\n")
    out.write("    Seed, EncapsulationKey, Ciphertext, SharedSecret: PChar;\n")
    out.write("    FlippedIndex, FlippedMask: Integer;\n")
    out.write("    RejectionSecret: PChar;\n")
    out.write("  end;\n")
    out.write("const\n")
    write_hash_vectors(out)
    write_kem_vectors(out)


main()
