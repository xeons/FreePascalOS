#!/usr/bin/env python3
#LICENSE

"""Writes SshTest.ClientVectors.inc (at build time): known answers for
the parts of libssh added with the client, worked out with Python, the
cryptography package (OpenSSL) and the host's ssh-keygen:

  - mlkem768x25519-sha256: a client's ML-KEM key from a seed and its
    X25519 key, the server's reply (OpenSSL's encapsulation), the shared
    secret K as a string, the exchange hash and derived keys;
  - OpenSSH certificates made by ssh-keygen -s: user certificates of
    ed25519, ecdsa and rsa keys (principals, validity, force-command,
    source-address, no extensions on one), a host certificate, and a
    publickey signature made with the ed25519 certificate's key;
  - a hashed known_hosts line (HMAC-SHA1 of the name).

    python3 tools/SshTest/make-client-vectors.py WORKDIR > SshTest.ClientVectors.inc
"""

import base64
import hashlib
import hmac
import os
import shutil
import struct
import subprocess
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import mlkem, x25519


def string(data):
    return struct.pack(">I", len(data)) + data


def pattern(size, seed):
    return bytes((seed + i * 37 + (i >> 3)) & 0xFF for i in range(size))


lines = []


def constant(name, data):
    text = data.hex()
    pieces = [text[i:i + 64] for i in range(0, len(text), 64)] or [""]
    lines.append("  %s = '%s';" % (name, "' +\n    '".join(pieces)))


def text_constant(name, text):
    lines.append("  %s = '%s';" % (name, text.replace("'", "''")))


def number(name, value):
    lines.append("  %s = %d;" % (name, value))


# mlkem768x25519-sha256.
mlkem_seed = pattern(64, 9)
client_mlkem = mlkem.MLKEM768PrivateKey.from_seed_bytes(mlkem_seed)
client_mlkem_public = client_mlkem.public_key().public_bytes_raw()
client_x_private = pattern(32, 21)
server_x_private = pattern(32, 42)
client_x = x25519.X25519PrivateKey.from_private_bytes(client_x_private)
server_x = x25519.X25519PrivateKey.from_private_bytes(server_x_private)
raw = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)
client_x_public = client_x.public_key().public_bytes(*raw)
server_x_public = server_x.public_key().public_bytes(*raw)
mlkem_secret, ciphertext = client_mlkem.public_key().encapsulate()
x_secret = server_x.exchange(x25519.X25519PublicKey.from_public_bytes(client_x_public))
client_init = client_mlkem_public + client_x_public
server_reply = ciphertext + server_x_public
encoded_secret = string(hashlib.sha256(mlkem_secret + x_secret).digest())
host_blob = string(b"ssh-ed25519") + string(pattern(32, 3))
versions = (b"SSH-2.0-OpenSSH_9.9", b"SSH-2.0-FreePascalOS_1.0")
inits = (b"\x14" + pattern(50, 4), b"\x14" + pattern(60, 5))
exchange_hash = hashlib.sha256(string(versions[0]) + string(versions[1]) + string(inits[0]) + string(inits[1]) +
                               string(host_blob) + string(client_init) + string(server_reply) +
                               encoded_secret).digest()
constant("HybridMlKemSeed", mlkem_seed)
constant("HybridClientX25519", client_x_private)
constant("HybridClientInit", client_init)
constant("HybridServerReply", server_reply)
constant("HybridEncodedSecret", encoded_secret)
constant("HybridHostBlob", host_blob)
constant("HybridClientKexInit", inits[0])
constant("HybridServerKexInit", inits[1])
constant("HybridExchangeHash", exchange_hash)
derived = hashlib.sha256(encoded_secret + exchange_hash + b"C" + exchange_hash).digest()
derived += hashlib.sha256(encoded_secret + exchange_hash + derived).digest()
constant("HybridDerivedKeyC", derived)

# Certificates made by ssh-keygen.
work = sys.argv[1]
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)


def keygen(*arguments):
    subprocess.run(["ssh-keygen", "-q", *arguments], check=True, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def blob_of(path):
    with open(path) as file:
        return base64.b64decode(file.read().split()[1])


ca = os.path.join(work, "ca")
keygen("-t", "ed25519", "-N", "", "-C", "test-ca", "-f", ca)
constant("CertificateAuthorityBlob", blob_of(ca + ".pub"))
for name, kind, extra in (("Ed25519", "ed25519", []), ("Ecdsa", "ecdsa", ["-b", "256"]), ("Rsa", "rsa", ["-b", "2048"])):
    key = os.path.join(work, "user_" + kind)
    keygen("-t", kind, *extra, "-N", "", "-f", key)
    keygen("-s", ca, "-I", "id-" + kind, "-n", "tester,other", "-V", "20200101:20400101", "-z", "7",
           "-O", "force-command=/bin/echo forced", "-O", "source-address=10.0.0.0/8,::1", key + ".pub")
    constant("UserCertificate" + name, blob_of(key + "-cert.pub"))
    constant("UserKey" + name, blob_of(key + ".pub"))

# A certificate without extensions (no pty, forwarding or agent), and one
# that expired.
bare = os.path.join(work, "user_bare")
keygen("-t", "ed25519", "-N", "", "-f", bare)
keygen("-s", ca, "-I", "bare", "-n", "tester", "-V", "20200101:20400101", "-O", "clear", bare + ".pub")
constant("BareCertificate", blob_of(bare + "-cert.pub"))
old = os.path.join(work, "user_old")
keygen("-t", "ed25519", "-N", "", "-f", old)
keygen("-s", ca, "-I", "old", "-n", "tester", "-V", "20000101:20010101", old + ".pub")
constant("ExpiredCertificate", blob_of(old + "-cert.pub"))
host = os.path.join(work, "host")
keygen("-t", "ed25519", "-N", "", "-f", host)
keygen("-s", ca, "-I", "host", "-h", "-n", "fpos.example", host + ".pub")
constant("HostCertificate", blob_of(host + "-cert.pub"))
constant("HostCertifiedKey", blob_of(host + ".pub"))

# A publickey signature made with the ed25519 certificate's key over a
# request as the server rebuilds it.
with open(os.path.join(work, "user_ed25519"), "rb") as file:
    private = serialization.load_ssh_private_key(file.read(), password=None)
session_id = pattern(32, 77)
certificate_blob = blob_of(os.path.join(work, "user_ed25519-cert.pub"))
algorithm = b"ssh-ed25519-cert-v01@openssh.com"
signed = (string(session_id) + b"\x32" + string(b"tester") + string(b"ssh-connection") + string(b"publickey") +
          b"\x01" + string(algorithm) + string(certificate_blob))
constant("CertificateSessionId", session_id)
constant("CertificateSignedData", signed)
constant("CertificateSignature", string(b"ssh-ed25519") + string(private.sign(signed)))
number("CertificateCheckTime", 1767225600)

# A hashed known_hosts entry for [fpos.example]:2222.
salt = pattern(20, 5)
name = b"[fpos.example]:2222"
hashed = "|1|%s|%s" % (base64.b64encode(salt).decode(),
                       base64.b64encode(hmac.new(salt, name, hashlib.sha1).digest()).decode())
text_constant("HashedKnownHostsLine", hashed + " ssh-ed25519 " + base64.b64encode(blob_of(host + ".pub")).decode())

print("{ Made by tools/SshTest/make-client-vectors.py; do not edit. }")
print("const")
print("\n".join(lines))
