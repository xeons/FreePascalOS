#!/usr/bin/env bash
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

#
# Makes the test certificates of TlsTest and of the HTTPS test in QEMU
# (see README.md here). Needs OpenSSL 3.4 or later (-not_before and
# -not_after). Run from this directory; it overwrites every file.
#
#   ca              RSA-2048 root, "FreePascalOS Test Root CA"
#   intermediate    P-384 intermediate under ca (RSA PKCS#1 SHA-256),
#                   path length 0
#   server          P-256 server under intermediate (ECDSA SHA-384) for
#                   localhost, 127.0.0.1, 10.0.2.101 and 10.0.2.103
#   server-rsa      RSA-2048 server under ca, signed with RSA-PSS SHA-256,
#                   for the same names
#   wrong-name      P-256 server under intermediate for other.example only
#   expired         P-256 server under intermediate, valid in 2020 only
#   not-authority   P-256 server whose issuer is "server" (not a CA)
#   wildcard        P-256 server under intermediate for *.test.example
#   other-ca        a root nobody trusts, and other-server under it for
#                   the same names as server
#
# Every certificate but expired is valid from 2026 to 2125 (dates after
# 2049 are written as GeneralizedTime, so both time formats are used).

set -euo pipefail
cd "$(dirname "$0")"

not_before=20260101000000Z
not_after=21251231235959Z
server_names="subjectAltName=DNS:localhost,IP:127.0.0.1,IP:10.0.2.101,IP:10.0.2.103"
server_usage="keyUsage=critical,digitalSignature"
server_purpose="extendedKeyUsage=serverAuth"

make_ec_key() {
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:"$2" -out "$1.key"
}

make_rsa_key() {
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1.key"
}

# make_certificate NAME SUBJECT ISSUER DIGEST EXTENSIONS... (issuer "self")
make_certificate() {
    local name="$1" subject="$2" issuer="$3" digest="$4"
    shift 4
    local extensions_file
    extensions_file=$(mktemp)
    printf '%s\n' "$@" > "$extensions_file"
    openssl req -new -key "$name.key" -subj "$subject" -out "$name.csr"
    if [[ "$issuer" == self ]]; then
        openssl x509 -req -in "$name.csr" -key "$name.key" -"$digest" \
            -not_before "$not_before" -not_after "$not_after" \
            -extfile "$extensions_file" -set_serial "0x$(openssl rand -hex 8)" -out "$name.pem"
    else
        openssl x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" -"$digest" \
            ${SIGNATURE_OPTIONS:-} -not_before "$not_before" -not_after "$not_after" \
            -extfile "$extensions_file" -set_serial "0x$(openssl rand -hex 8)" -out "$name.pem"
    fi
    rm -f "$name.csr" "$extensions_file"
}

make_rsa_key ca
make_certificate ca "/O=FreePascalOS/CN=FreePascalOS Test Root CA" self sha256 \
    "basicConstraints=critical,CA:TRUE" "keyUsage=critical,keyCertSign,cRLSign" \
    "subjectKeyIdentifier=hash"

make_ec_key intermediate secp384r1
make_certificate intermediate "/O=FreePascalOS/CN=FreePascalOS Test Intermediate CA" ca sha256 \
    "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" \
    "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid"

make_ec_key server prime256v1
make_certificate server "/O=FreePascalOS/CN=localhost" intermediate sha384 \
    "basicConstraints=critical,CA:FALSE" "$server_usage" "$server_purpose" "$server_names" \
    "authorityKeyIdentifier=keyid"

make_rsa_key server-rsa
SIGNATURE_OPTIONS="-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32" \
    make_certificate server-rsa "/O=FreePascalOS/CN=localhost RSA" ca sha256 \
    "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
    "$server_purpose" "$server_names"

make_ec_key wrong-name prime256v1
make_certificate wrong-name "/O=FreePascalOS/CN=other.example" intermediate sha256 \
    "basicConstraints=critical,CA:FALSE" "$server_usage" "$server_purpose" "subjectAltName=DNS:other.example"

make_ec_key expired prime256v1
not_before=20200101000000Z not_after=20210101000000Z \
    make_certificate expired "/O=FreePascalOS/CN=localhost expired" intermediate sha256 \
    "basicConstraints=critical,CA:FALSE" "$server_usage" "$server_purpose" "$server_names"

make_ec_key not-authority prime256v1
make_certificate not-authority "/O=FreePascalOS/CN=localhost under a server" server sha256 \
    "basicConstraints=critical,CA:FALSE" "$server_usage" "$server_purpose" "$server_names"

make_ec_key wildcard prime256v1
make_certificate wildcard "/O=FreePascalOS/CN=*.test.example" intermediate sha256 \
    "basicConstraints=critical,CA:FALSE" "$server_usage" "$server_purpose" \
    "subjectAltName=DNS:*.test.example,DNS:exact.example"

make_rsa_key other-ca
make_certificate other-ca "/O=Nobody/CN=Untrusted Test Root" self sha256 \
    "basicConstraints=critical,CA:TRUE" "keyUsage=critical,keyCertSign"
make_ec_key other-server prime256v1
make_certificate other-server "/O=Nobody/CN=localhost" other-ca sha256 \
    "basicConstraints=critical,CA:FALSE" "$server_usage" "$server_purpose" "$server_names"

# What the servers present: their certificate and the intermediate.
cat server.pem intermediate.pem > server-chain.pem
cat wrong-name.pem intermediate.pem > wrong-name-chain.pem
cat expired.pem intermediate.pem > expired-chain.pem
rm -f ./*.srl
