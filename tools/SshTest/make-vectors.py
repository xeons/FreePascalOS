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

"""Writes SshTest.Vectors.inc (at build time): known answers for libssh
worked out independently with Python's hashlib and the cryptography
package (OpenSSL): a chacha20-poly1305@openssh.com packet and two
aes256-gcm@openssh.com packets, the curve25519-sha256 exchange hash and
the keys derived from it, ssh-ed25519 and ecdsa-sha2-nistp256 host key
signatures, OpenSSH private key files of both, an RSA key with
rsa-sha2-256 and rsa-sha2-512 signatures, and authorized_keys lines.

    python3 tools/SshTest/make-vectors.py > build/tools/ssh-test-units/SshTest.Vectors.inc
"""

import hashlib
import struct

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa, x25519
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.poly1305 import Poly1305


def string(data):
    return struct.pack(">I", len(data)) + data


def mpint(value):
    if value == 0:
        return string(b"")
    data = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if data[0] & 0x80:
        data = b"\x00" + data
    return string(data)


def pattern(size, seed):
    return bytes((seed + i * 37 + (i >> 3)) & 0xFF for i in range(size))


lines = []


def constant(name, data):
    text = data.hex()
    pieces = [text[i:i + 64] for i in range(0, len(text), 64)] or [""]
    lines.append("  %s = '%s';" % (name, "' +\n    '".join(pieces)))


def number(name, value):
    lines.append("  %s = %d;" % (name, value))


def packet(payload, padding_length, padding_seed):
    padding_bytes = pattern(padding_length, padding_seed)
    body = bytes([padding_length]) + payload + padding_bytes
    return struct.pack(">I", len(body)) + body


# chacha20-poly1305@openssh.com: K_2 (main) then K_1 (header); nonce
# = the sequence number, 64 bits big endian; the original ChaCha20,
# which cryptography takes as a 16-byte nonce: counter (little endian)
# then nonce.
def chacha(key, counter, nonce, data):
    full_nonce = struct.pack("<Q", counter) + nonce
    return Cipher(algorithms.ChaCha20(key, full_nonce), mode=None).encryptor().update(data)


chacha_key = pattern(64, 11)
sequence = 7
nonce = struct.pack(">Q", sequence)
# 1 + 15 + 8 = 24: a multiple of 8.
chacha_packet = packet(b"\x5ehello, channel", 8, 3)
encrypted_length = chacha(chacha_key[32:], 0, nonce, chacha_packet[:4])
encrypted_body = chacha(chacha_key[:32], 1, nonce, chacha_packet[4:])
poly_key = chacha(chacha_key[:32], 0, nonce, b"\x00" * 32)
mac = Poly1305(poly_key)
mac.update(encrypted_length + encrypted_body)
constant("ChaChaKey", chacha_key)
number("ChaChaSequence", sequence)
constant("ChaChaPacket", chacha_packet)
constant("ChaChaWire", encrypted_length + encrypted_body + mac.finalize())

# aes256-gcm@openssh.com: the length is additional data; the invocation
# counter (the last 8 bytes of the nonce) goes up after each packet.
gcm_key = pattern(32, 5)
gcm_iv = pattern(12, 200)
gcm = AESGCM(gcm_key)
constant("GcmKey", gcm_key)
constant("GcmInitialValue", gcm_iv)
iv = gcm_iv
for index, (payload, pad) in enumerate([(b"\x5e" + pattern(26, 9), 4), (b"\x02ignore me", 21)], start=1):
    plain = packet(payload, pad, index)
    assert (len(plain) - 4) % 16 == 0
    constant("GcmPacket%d" % index, plain)
    constant("GcmWire%d" % index, plain[:4] + gcm.encrypt(iv, plain[4:], plain[:4]))
    counter = int.from_bytes(iv[4:], "big") + 1
    iv = iv[:4] + counter.to_bytes(8, "big")

# The host keys.
host_seed = pattern(32, 77)
host_key = ed25519.Ed25519PrivateKey.from_private_bytes(host_seed)
host_public = host_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
host_blob = string(b"ssh-ed25519") + string(host_public)
constant("Ed25519Seed", host_seed)
constant("Ed25519Blob", host_blob)

# curve25519-sha256.
client_private = pattern(32, 101)
server_private = pattern(32, 150)
client_key = x25519.X25519PrivateKey.from_private_bytes(client_private)
server_key = x25519.X25519PrivateKey.from_private_bytes(server_private)
client_public = client_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
server_public = server_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
shared = server_key.exchange(x25519.X25519PublicKey.from_public_bytes(client_public))
client_version = b"SSH-2.0-OpenSSH_9.9"
server_version = b"SSH-2.0-FreePascalOS_1.0"
client_init = b"\x14" + pattern(60, 1)
server_init = b"\x14" + pattern(70, 2)
shared_number = int.from_bytes(shared, "big")
exchange_hash = hashlib.sha256(string(client_version) + string(server_version) + string(client_init) +
                               string(server_init) + string(host_blob) + string(client_public) +
                               string(server_public) + mpint(shared_number)).digest()
constant("ClientPrivate", client_private)
constant("ClientPublic", client_public)
constant("ServerPrivate", server_private)
constant("ServerPublic", server_public)
constant("SharedSecret", shared)
lines.append("  ClientVersion = '%s';" % client_version.decode())
lines.append("  ServerVersion = '%s';" % server_version.decode())
constant("ClientInit", client_init)
constant("ServerInit", server_init)
constant("ExchangeHash", exchange_hash)
for letter in "ABCD":
    derived = hashlib.sha256(mpint(shared_number) + exchange_hash + letter.encode() + exchange_hash).digest()
    derived += hashlib.sha256(mpint(shared_number) + exchange_hash + derived).digest()
    constant("DerivedKey" + letter, derived)
constant("Ed25519SignatureOfHash", string(b"ssh-ed25519") + string(host_key.sign(exchange_hash)))

# ecdsa-sha2-nistp256, deterministic (RFC 6979).
ecdsa_secret = int.from_bytes(pattern(32, 33), "big") % (2 ** 255)
ecdsa_key = ec.derive_private_key(ecdsa_secret, ec.SECP256R1())
point = ecdsa_key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
ecdsa_blob = string(b"ecdsa-sha2-nistp256") + string(b"nistp256") + string(point)
signed_data = b"data signed by the host key"
r, s = decode_dss_signature(ecdsa_key.sign(signed_data, ec.ECDSA(hashes.SHA256(), deterministic_signing=True)))
constant("EcdsaPrivate", ecdsa_secret.to_bytes(32, "big"))
constant("EcdsaBlob", ecdsa_blob)
constant("SignedData", signed_data)
constant("EcdsaSignature", string(b"ecdsa-sha2-nistp256") + string(mpint(r) + mpint(s)))

# OpenSSH private key files of both.
for name, key, blob in (("Ed25519", host_key, host_blob), ("Ecdsa", ecdsa_key, ecdsa_blob)):
    text = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                             serialization.NoEncryption())
    constant(name + "KeyFile", text)

# A client's RSA key with both RSA SHA-2 signatures.
rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
numbers = rsa_key.public_key().public_numbers()
rsa_blob = string(b"ssh-rsa") + mpint(numbers.e) + mpint(numbers.n)
constant("RsaBlob", rsa_blob)
for name, algorithm, digest in (("Sha256", b"rsa-sha2-256", hashes.SHA256()), ("Sha512", b"rsa-sha2-512", hashes.SHA512())):
    signature = rsa_key.sign(signed_data, padding.PKCS1v15(), digest)
    constant("RsaSignature" + name, string(algorithm) + string(signature))

# authorized_keys lines.
client_ed25519 = ed25519.Ed25519PrivateKey.from_private_bytes(pattern(32, 55)).public_key()
openssh_line = client_ed25519.public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
client_raw = client_ed25519.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
lines.append("  AuthorizedLine = '%s user@laptop';" % openssh_line.decode())
lines.append("  AuthorizedLineWithOptions = 'from=\"10.0.0.1\",no-pty %s';" % openssh_line.decode())
constant("AuthorizedBlob", string(b"ssh-ed25519") + string(client_raw))
lines.append("  AuthorizedFingerprint = 'SHA256:%s';" %
             __import__("base64").b64encode(hashlib.sha256(string(b"ssh-ed25519") + string(client_raw)).digest())
             .decode().rstrip("="))

print("{ Made by tools/SshTest/make-vectors.py; do not edit. }")
print("const")
print("\n".join(lines))
