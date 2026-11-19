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

"""Makes the TLS test's certificate fixtures at build time with Python's
cryptography package, valid from a day ago for ten years:

  - chains under authorities with name constraints (DNS names, IP
    addresses, mailboxes, directory names; permitted and excluded; on
    an intermediate and on a root) and the verdict each should get;
  - Ed25519 and P-521 chains (also served by OpenSSL in the interop
    test);
  - OCSP responses about tools/TlsTest/certificates/server.pem (good,
    revoked, unknown, from a delegated responder, stale, for another
    certificate, badly signed) and a must-staple server certificate;
  - TLS 1.2 PRF outputs (RFC 5246 section 5) made with Python's hmac:
    the extended master secret, the key block and Finished data.

    python3 -I tools/TlsTest/make-fixtures.py CERTIFICATE-DIRECTORY OUTPUT-DIRECTORY

chains.txt lists "name|chain file|anchor file|host|expected error";
ocsp.txt "name|response file|subject file|issuer file|expected error|
expected status (good, unknown or -)"; prf.txt "hash|secret|label|
seed|output" (hexadecimal but the label). Errors are libtls's codes.
"""

import datetime
import hashlib
import hmac
import ipaddress
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.x509 import ocsp
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

NONE = 0
NAME_MISMATCH = -43
UNSUPPORTED = -47
NAME_CONSTRAINT = -51
REVOKED = -52
STATUS_INVALID = -53

NOW = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
NOT_BEFORE = NOW - datetime.timedelta(days=1)
NOT_AFTER = NOW + datetime.timedelta(days=3650)


def name(common_name, organization="FreePascalOS Fixtures", email=None):
    attributes = [x509.NameAttribute(NameOID.ORGANIZATION_NAME, organization),
                  x509.NameAttribute(NameOID.COMMON_NAME, common_name)]
    if email:
        attributes.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email))
    return x509.Name(attributes)


def signing_hash(key):
    if isinstance(key, ed25519.Ed25519PrivateKey):
        return None
    if isinstance(key, ec.EllipticCurvePrivateKey) and key.curve.key_size == 521:
        return hashes.SHA512()
    return hashes.SHA256()


def certificate(subject, public_key, issuer_name, issuer_key, authority, names=None, constraints=None,
                extra=None, serial=None):
    builder = (x509.CertificateBuilder()
               .subject_name(subject)
               .issuer_name(issuer_name)
               .public_key(public_key)
               .serial_number(serial or x509.random_serial_number())
               .not_valid_before(NOT_BEFORE)
               .not_valid_after(NOT_AFTER)
               .add_extension(x509.BasicConstraints(ca=authority, path_length=None), critical=True))
    if authority:
        builder = builder.add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False),
                                        critical=True)
    else:
        builder = builder.add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False),
                                        critical=True)
        builder = builder.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    if names:
        builder = builder.add_extension(x509.SubjectAlternativeName(names), critical=False)
    if constraints:
        builder = builder.add_extension(constraints, critical=True)
    for extension, critical in extra or []:
        builder = builder.add_extension(extension, critical=critical)
    return builder.sign(issuer_key, signing_hash(issuer_key))


def pem(*certificates):
    return b"".join(item.public_bytes(serialization.Encoding.PEM) for item in certificates)


def write(directory, file_name, data):
    with open(os.path.join(directory, file_name), "wb") as output:
        output.write(data)


def write_key(directory, file_name, key):
    write(directory, file_name, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                  serialization.NoEncryption()))


def p256():
    return ec.generate_private_key(ec.SECP256R1())


def dns(*values):
    return [x509.DNSName(value) for value in values]


def make_name_constraint_chains(directory, chains):
    root_key = p256()
    root = certificate(name("Constraint Test Root"), root_key.public_key(), name("Constraint Test Root"), root_key,
                       True)
    write(directory, "nc-root.pem", pem(root))

    intermediate_key = p256()
    intermediate_constraints = x509.NameConstraints(
        permitted_subtrees=[x509.DNSName("example.com"), x509.IPAddress(ipaddress.ip_network("10.0.0.0/8")),
                            x509.RFC822Name(".example.com"),
                            x509.DirectoryName(name("Constraint Test Intermediate")),
                            x509.DirectoryName(x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME,
                                                                             "FreePascalOS Fixtures")]))],
        excluded_subtrees=[x509.DNSName("bad.example.com"), x509.IPAddress(ipaddress.ip_network("10.9.0.0/16"))])
    intermediate = certificate(name("Constraint Test Intermediate"), intermediate_key.public_key(), root.subject,
                               root_key, True, constraints=intermediate_constraints)

    def leaf(file_name, host, expected, names, subject=None):
        key = p256()
        made = certificate(subject or name(host), key.public_key(), intermediate.subject, intermediate_key, False,
                           names=names)
        write(directory, file_name, pem(made, intermediate))
        chains.append((file_name[:-4], file_name, "nc-root.pem", host, expected))

    leaf("nc-good.pem", "www.example.com", NONE,
         dns("www.example.com", "example.com") + [x509.IPAddress(ipaddress.ip_address("10.1.2.3")),
                                                  x509.RFC822Name("admin@mail.example.com")])
    leaf("nc-outside.pem", "www.example.org", NAME_CONSTRAINT, dns("www.example.org"))
    leaf("nc-excluded.pem", "bad.example.com", NAME_CONSTRAINT, dns("bad.example.com"))
    leaf("nc-excluded-below.pem", "x.bad.example.com", NAME_CONSTRAINT, dns("x.bad.example.com"))
    leaf("nc-wildcard-excluded.pem", "www.example.com", NAME_CONSTRAINT, dns("*.example.com"))
    leaf("nc-wildcard-good.pem", "a.www.example.com", NONE, dns("*.www.example.com"))
    leaf("nc-address-outside.pem", "www.example.com", NAME_CONSTRAINT,
         dns("www.example.com") + [x509.IPAddress(ipaddress.ip_address("192.168.1.1"))])
    leaf("nc-address-excluded.pem", "www.example.com", NAME_CONSTRAINT,
         dns("www.example.com") + [x509.IPAddress(ipaddress.ip_address("10.9.1.1"))])
    leaf("nc-ipv6-outside.pem", "www.example.com", NAME_CONSTRAINT,
         dns("www.example.com") + [x509.IPAddress(ipaddress.ip_address("2001:db8::1"))])
    leaf("nc-mail-outside.pem", "www.example.com", NAME_CONSTRAINT,
         dns("www.example.com") + [x509.RFC822Name("admin@example.org")])
    leaf("nc-subject-mail-outside.pem", "www.example.com", NAME_CONSTRAINT, dns("www.example.com"),
         subject=name("www.example.com", email="admin@example.net"))
    leaf("nc-directory-outside.pem", "www.example.com", NAME_CONSTRAINT, dns("www.example.com"),
         subject=name("www.example.com", organization="Somebody Else"))
    leaf("nc-uri.pem", "www.example.com", NONE,
         dns("www.example.com") + [x509.UniformResourceIdentifier("https://www.example.com/")])

    # A constraint that cannot be checked meets a name of its type.
    uri_key = p256()
    uri_intermediate = certificate(name("URI Constraint Intermediate"), uri_key.public_key(), root.subject, root_key,
                                   True, constraints=x509.NameConstraints(
                                       permitted_subtrees=[x509.UniformResourceIdentifier(".example.com")],
                                       excluded_subtrees=None))
    key = p256()
    made = certificate(name("www.example.com"), key.public_key(), uri_intermediate.subject, uri_key, False,
                       names=dns("www.example.com") + [x509.UniformResourceIdentifier("https://www.example.com/")])
    write(directory, "nc-uri-unsupported.pem", pem(made, uri_intermediate))
    chains.append(("nc-uri-unsupported", "nc-uri-unsupported.pem", "nc-root.pem", "www.example.com", UNSUPPORTED))
    made = certificate(name("www.example.com"), key.public_key(), uri_intermediate.subject, uri_key, False,
                       names=dns("www.example.com"))
    write(directory, "nc-uri-unmet.pem", pem(made, uri_intermediate))
    chains.append(("nc-uri-unmet", "nc-uri-unmet.pem", "nc-root.pem", "www.example.com", NONE))

    # Constraints on the root (the trust anchor) apply too.
    constrained_root_key = p256()
    constrained_root = certificate(name("Constrained Test Root"), constrained_root_key.public_key(),
                                   name("Constrained Test Root"), constrained_root_key, True,
                                   constraints=x509.NameConstraints(permitted_subtrees=[x509.DNSName(".test")],
                                                                    excluded_subtrees=None))
    write(directory, "nc-constrained-root.pem", pem(constrained_root))
    for file_name, host, expected in (("nc-root-good.pem", "host.test", NONE),
                                      ("nc-root-outside.pem", "host.example", NAME_CONSTRAINT)):
        key = p256()
        made = certificate(name(host), key.public_key(), constrained_root.subject, constrained_root_key, False,
                           names=dns(host))
        write(directory, file_name, pem(made))
        chains.append((file_name[:-4], file_name, "nc-constrained-root.pem", host, expected))


def make_algorithm_chains(directory, chains):
    for prefix, make_key in (("ed25519", ed25519.Ed25519PrivateKey.generate),
                             ("p521", lambda: ec.generate_private_key(ec.SECP521R1()))):
        root_key = make_key()
        root = certificate(name(prefix + " Test Root"), root_key.public_key(), name(prefix + " Test Root"), root_key,
                           True)
        leaf_key = make_key()
        leaf = certificate(name("localhost"), leaf_key.public_key(), root.subject, root_key, False,
                           names=dns("localhost") + [x509.IPAddress(ipaddress.ip_address("127.0.0.1"))])
        write(directory, prefix + "-root.pem", pem(root))
        write(directory, prefix + "-server.pem", pem(leaf))
        write_key(directory, prefix + "-server.key", leaf_key)
        chains.append((prefix, prefix + "-server.pem", prefix + "-root.pem", "localhost", NONE))
        chains.append((prefix + "-wrong-host", prefix + "-server.pem", prefix + "-root.pem", "example.com",
                       NAME_MISMATCH))


def load_pem_certificate(path):
    with open(path, "rb") as source:
        return x509.load_pem_x509_certificate(source.read())


def load_key(path):
    with open(path, "rb") as source:
        return serialization.load_pem_private_key(source.read(), password=None)


def ocsp_response(subject, issuer, signer_key, status, this_update=None, next_update=True, responder=None,
                  by_hash=True, delegate=None):
    this_update = this_update or (NOW - datetime.timedelta(hours=1))
    builder = ocsp.OCSPResponseBuilder().add_response(
        cert=subject, issuer=issuer, algorithm=hashes.SHA1(), cert_status=status, this_update=this_update,
        next_update=(this_update + datetime.timedelta(days=7)) if next_update else None,
        revocation_time=(NOW - datetime.timedelta(days=2)) if status == ocsp.OCSPCertStatus.REVOKED else None,
        revocation_reason=x509.ReasonFlags.key_compromise if status == ocsp.OCSPCertStatus.REVOKED else None)
    encoding = ocsp.OCSPResponderEncoding.HASH if by_hash else ocsp.OCSPResponderEncoding.NAME
    builder = builder.responder_id(encoding, responder or issuer)
    if delegate is not None:
        builder = builder.certificates([delegate])
    return builder.sign(signer_key, hashes.SHA256()).public_bytes(serialization.Encoding.DER)


def make_ocsp_fixtures(certificates, directory, responses):
    server = load_pem_certificate(os.path.join(certificates, "server.pem"))
    intermediate = load_pem_certificate(os.path.join(certificates, "intermediate.pem"))
    intermediate_key = load_key(os.path.join(certificates, "intermediate.key"))
    wildcard = load_pem_certificate(os.path.join(certificates, "wildcard.pem"))
    good = ocsp.OCSPCertStatus.GOOD

    def add(file_name, data, expected, status, subject="server.pem"):
        write(directory, file_name, data)
        responses.append((file_name[:-4], file_name, subject, expected, status))

    add("ocsp-good.der", ocsp_response(server, intermediate, intermediate_key, good), NONE, "good")
    add("ocsp-good-by-name.der", ocsp_response(server, intermediate, intermediate_key, good, by_hash=False), NONE,
        "good")
    add("ocsp-good-no-next-update.der", ocsp_response(server, intermediate, intermediate_key, good,
                                                      next_update=False), NONE, "good")
    add("ocsp-revoked.der", ocsp_response(server, intermediate, intermediate_key, ocsp.OCSPCertStatus.REVOKED),
        REVOKED, "-")
    add("ocsp-unknown.der", ocsp_response(server, intermediate, intermediate_key, ocsp.OCSPCertStatus.UNKNOWN),
        NONE, "unknown")
    add("ocsp-stale.der", ocsp_response(server, intermediate, intermediate_key, good,
                                        this_update=NOW - datetime.timedelta(days=30)), STATUS_INVALID, "-")
    add("ocsp-future.der", ocsp_response(server, intermediate, intermediate_key, good,
                                         this_update=NOW + datetime.timedelta(days=1)), STATUS_INVALID, "-")
    add("ocsp-other-certificate.der", ocsp_response(wildcard, intermediate, intermediate_key, good),
        STATUS_INVALID, "-")

    # Delegated responders: one the intermediate made for OCSP, one
    # without the OCSP signing purpose, one from nobody it knows.
    def responder(purposes, issuer_name, issuer_key):
        key = p256()
        extra = [(x509.ExtendedKeyUsage(purposes), False)] if purposes else []
        made = (x509.CertificateBuilder().subject_name(name("OCSP Responder")).issuer_name(issuer_name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(NOT_BEFORE).not_valid_after(NOT_AFTER))
        for extension, critical in extra:
            made = made.add_extension(extension, critical=critical)
        return made.sign(issuer_key, hashes.SHA256()), key

    delegate, delegate_key = responder([ExtendedKeyUsageOID.OCSP_SIGNING], intermediate.subject, intermediate_key)
    add("ocsp-delegated.der", ocsp_response(server, intermediate, delegate_key, good, responder=delegate,
                                            delegate=delegate), NONE, "good")
    plain, plain_key = responder([ExtendedKeyUsageOID.SERVER_AUTH], intermediate.subject, intermediate_key)
    add("ocsp-delegate-not-for-ocsp.der", ocsp_response(server, intermediate, plain_key, good, responder=plain,
                                                        delegate=plain), STATUS_INVALID, "-")
    stranger_key = p256()
    stranger, stranger_key = responder([ExtendedKeyUsageOID.OCSP_SIGNING], name("Stranger"), stranger_key)
    add("ocsp-stranger.der", ocsp_response(server, intermediate, stranger_key, good, responder=stranger,
                                           delegate=stranger), STATUS_INVALID, "-")
    # A good response whose signature was changed (its last byte, in s).
    damaged = bytearray(ocsp_response(server, intermediate, intermediate_key, good))
    damaged[-1] ^= 1
    add("ocsp-bad-signature.der", bytes(damaged), STATUS_INVALID, "-")

    # A server certificate that must have a staple (RFC 7633).
    must_staple_key = p256()
    must_staple = certificate(name("localhost must staple", "FreePascalOS"), must_staple_key.public_key(),
                              intermediate.subject, intermediate_key, False,
                              names=dns("localhost") + [x509.IPAddress(ipaddress.ip_address("127.0.0.1"))],
                              extra=[(x509.TLSFeature([x509.TLSFeatureType.status_request]), False)])
    write(directory, "must-staple.pem", pem(must_staple))
    write_key(directory, "must-staple.key", must_staple_key)
    write(directory, "ocsp-must-staple-good.der", ocsp_response(must_staple, intermediate, intermediate_key, good))


def tls12_prf(digest, secret, label, seed, length):
    """P_hash of RFC 5246 section 5."""
    label_seed = label + seed
    output = b""
    a = hmac.new(secret, label_seed, digest).digest()
    while len(output) < length:
        output += hmac.new(secret, a + label_seed, digest).digest()
        a = hmac.new(secret, a, digest).digest()
    return output[:length]


def make_prf_vectors(directory):
    lines = []
    cases = [
        ("sha256", 48, b"extended master secret", 32, 48),
        ("sha384", 48, b"extended master secret", 48, 48),
        ("sha256", 48, b"key expansion", 64, 40),
        ("sha256", 48, b"key expansion", 64, 88),
        ("sha384", 48, b"key expansion", 64, 136),
        ("sha256", 48, b"client finished", 32, 12),
        ("sha384", 48, b"server finished", 48, 12),
        ("sha256", 13, b"test label", 100, 300),
    ]
    for number, (digest, secret_length, label, seed_length, output_length) in enumerate(cases):
        secret = hashlib.shake_256(b"prf secret %d" % number).digest(secret_length)
        seed = hashlib.shake_256(b"prf seed %d" % number).digest(seed_length)
        output = tls12_prf(getattr(hashlib, digest), secret, label, seed, output_length)
        lines.append("|".join([digest, secret.hex(), label.decode(), seed.hex(), output.hex()]))
    with open(os.path.join(directory, "prf.txt"), "w") as manifest:
        manifest.write("\n".join(lines) + "\n")


def main():
    certificates, directory = sys.argv[1], sys.argv[2]
    os.makedirs(directory, exist_ok=True)
    chains = []
    responses = []
    make_name_constraint_chains(directory, chains)
    make_algorithm_chains(directory, chains)
    make_ocsp_fixtures(certificates, directory, responses)
    make_prf_vectors(directory)
    with open(os.path.join(directory, "chains.txt"), "w") as manifest:
        for entry in chains:
            manifest.write("|".join(str(part) for part in entry) + "\n")
    with open(os.path.join(directory, "ocsp.txt"), "w") as manifest:
        for entry_name, file_name, subject, expected, status in responses:
            manifest.write("|".join([entry_name, file_name, subject, "intermediate.pem", str(expected), status]) + "\n")


main()
