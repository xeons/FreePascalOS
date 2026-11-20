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

# Known answers for QuicTest, worked out independently of libquic with
# Python's cryptography package: whole protected packets (RFC 9001
# section 5) built the way RFC 9001 appendix A builds its examples, for
# AES-128-GCM Initial packets of both directions and an AES-256-GCM
# (SHA-384) short header packet; and the test server's certificate (a
# self-signed Ed25519 certificate for localhost and 127.0.0.1, valid
# from yesterday for ten years) with its key.
#
#   make-vectors.py OUTPUT.inc

import datetime
import hashlib
import hmac
import struct
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.x509.oid import NameOID
import ipaddress


def hkdf_extract(digest, salt, key):
    return hmac.new(salt, key, digest).digest()


def hkdf_expand(digest, prk, info, length):
    output = b''
    block = b''
    counter = 1
    while len(output) < length:
        block = hmac.new(prk, block + info + bytes([counter]), digest).digest()
        output += block
        counter += 1
    return output[:length]


def expand_label(digest, secret, label, length):
    full = b'tls13 ' + label
    info = struct.pack('>H', length) + bytes([len(full)]) + full + b'\x00'
    return hkdf_expand(digest, secret, info, length)


def packet_keys(digest, secret, key_length):
    return (expand_label(digest, secret, b'quic key', key_length),
            expand_label(digest, secret, b'quic iv', 12),
            expand_label(digest, secret, b'quic hp', key_length))


def protect(keys, header, packet_number, pn_length, payload):
    key, iv, hp = keys
    nonce = bytes(a ^ b for a, b in zip(iv, packet_number.to_bytes(12, 'big')))
    sealed = AESGCM(key).encrypt(nonce, payload, header)
    pn_offset = len(header) - pn_length
    sample = sealed[4 - pn_length:4 - pn_length + 16]
    encryptor = Cipher(algorithms.AES(hp), modes.ECB()).encryptor()
    mask = encryptor.update(sample)
    first = header[0] ^ (mask[0] & (0x0F if header[0] & 0x80 else 0x1F))
    protected_pn = bytes(a ^ b for a, b in zip(header[pn_offset:], mask[1:1 + pn_length]))
    return bytes([first]) + header[1:pn_offset] + protected_pn + sealed


def pascal_bytes(name, data):
    lines = ['  %s: array[0..%d] of Byte = (' % (name, len(data) - 1)]
    for start in range(0, len(data), 16):
        chunk = ', '.join('$%02x' % b for b in data[start:start + 16])
        lines.append('    ' + chunk + (',' if start + 16 < len(data) else ');'))
    return '\n'.join(lines)


def main():
    output = []
    salt = bytes.fromhex('38762cf7f55934b34d179ae6a4c80cadccbb7f0a')
    dcid = bytes.fromhex('8394c8f03e515708')
    initial = hkdf_extract(hashlib.sha256, salt, dcid)
    client = packet_keys(hashlib.sha256, expand_label(hashlib.sha256, initial, b'client in', 32), 16)
    server = packet_keys(hashlib.sha256, expand_label(hashlib.sha256, initial, b'server in', 32), 16)

    # The client's Initial: packet number 2 in 4 bytes, a CRYPTO frame of
    # 241 bytes, padded to 1162 bytes of payload (RFC 9001 A.2's shape).
    crypto_data = bytes((index * 7 + 3) & 0xFF for index in range(241))
    payload = bytes.fromhex('060040f1') + crypto_data
    payload += bytes(1162 - len(payload))
    header = bytes.fromhex('c300000001088394c8f03e5157080000449e00000002')
    output.append(pascal_bytes('ClientCryptoData', crypto_data))
    output.append(pascal_bytes('ClientInitialPacket', protect(client, header, 2, 4, payload)))

    # The server's Initial: packet number 1 in 2 bytes, an ACK of packet
    # 0 and a CRYPTO frame of 90 bytes (A.3's shape).
    server_crypto = bytes((index * 13 + 5) & 0xFF for index in range(90))
    payload = bytes.fromhex('02000000000600405a') + server_crypto
    header = bytes.fromhex('c1000000010008f067a5502a4262b5004075') + struct.pack('>H', 1)
    output.append(pascal_bytes('ServerCryptoData', server_crypto))
    output.append(pascal_bytes('ServerInitialPacket', protect(server, header, 1, 2, payload)))

    # A short header packet under an AES-256-GCM (SHA-384) secret:
    # packet number 0x1234 in 2 bytes, a PING and some padding.
    secret = bytes(range(48))
    keys = packet_keys(hashlib.sha384, secret, 32)
    header = bytes.fromhex('41') + bytes.fromhex('0102030405060708') + bytes.fromhex('1234')
    payload = bytes([1]) + bytes(20)
    output.append(pascal_bytes('Aes256Secret', secret))
    output.append(pascal_bytes('Aes256ShortPacket', protect(keys, header, 0x1234, 2, payload)))

    # The test server's certificate and key.
    key = ed25519.Ed25519PrivateKey.generate()
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
    now = datetime.datetime.now(datetime.timezone.utc)
    certificate = (x509.CertificateBuilder()
                   .subject_name(name).issuer_name(name)
                   .public_key(key.public_key())
                   .serial_number(x509.random_serial_number())
                   .not_valid_before(now - datetime.timedelta(days=1))
                   .not_valid_after(now + datetime.timedelta(days=3650))
                   .add_extension(x509.SubjectAlternativeName([
                       x509.DNSName('localhost'),
                       x509.IPAddress(ipaddress.ip_address('127.0.0.1')),
                       x509.IPAddress(ipaddress.ip_address('::1'))]), critical=False)
                   .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                   .sign(key, None))
    seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                             serialization.NoEncryption())
    output.append(pascal_bytes('ServerCertificate', certificate.public_bytes(serialization.Encoding.DER)))
    output.append(pascal_bytes('ServerKeySeed', seed))

    with open(sys.argv[1], 'w') as file:
        file.write('{ Made by tools/QuicTest/make-vectors.py. }\nconst\n')
        file.write('\n'.join(output) + '\n')


main()
