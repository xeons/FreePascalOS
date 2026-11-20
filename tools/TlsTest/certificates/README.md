# Test certificates

Certificates and keys for testing only: libtls's host test
(`make tls-test`, tools/TlsTest) and the HTTPS servers of the wget test
in QEMU (scripts/test-web-server.py, run by scripts/test-qemu.sh). The
private keys are published here on purpose; nothing should ever trust
these certificates outside the tests.

They were made by `make-certificates.sh` in this directory (OpenSSL 3.4
or later, for `-not_before` and `-not_after`):

    cd tools/TlsTest/certificates && ./make-certificates.sh

Running it again makes new keys and certificates; the tests use only
what is in the files, except wgettest, whose expected error messages
name the common names below. (`server.pem` and `server-rsa.pem` were
later issued again with their keys, to add 10.0.2.107; the other
certificates still name the four addresses before it.)

| File | What it is |
|---|---|
| `ca.pem`, `ca.key` | RSA-2048 root, "FreePascalOS Test Root CA" (self-signed, SHA-256) |
| `intermediate.pem` | P-384 intermediate under the root (RSA PKCS#1 SHA-256), path length 0 |
| `server.pem` | P-256 server under the intermediate (ECDSA SHA-384): DNS localhost, IP 127.0.0.1, 10.0.2.101, 10.0.2.103, 10.0.2.107 |
| `server-rsa.pem` | RSA-2048 server directly under the root, signed with RSA-PSS SHA-256 (salt 32), same names |
| `wrong-name.pem` | P-256 server under the intermediate for DNS other.example only |
| `expired.pem` | P-256 server under the intermediate, valid 2020-01-01 to 2021-01-01, CN "localhost expired" |
| `not-authority.pem` | P-256 server whose issuer is `server.pem` (which is not a CA) |
| `wildcard.pem` | P-256 server for `*.test.example` and `exact.example` |
| `other-ca.pem` | an RSA root nobody trusts, "Untrusted Test Root" |
| `other-server.pem` | a P-256 server under `other-ca` for the same names as `server.pem` |
| `*-chain.pem` | a server certificate followed by the intermediate, as a server sends them |

Every certificate except `expired.pem` is valid from 2026-01-01 to
2125-12-31; dates from 2050 on are GeneralizedTime, earlier ones
UTCTime, so both formats are exercised.
