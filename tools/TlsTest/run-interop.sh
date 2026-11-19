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
# Runs libtls's client (TlsTest --connect, on the host) against OpenSSL's
# s_server on 127.0.0.1 with the test certificates: every cipher suite
# of TLS 1.3 and TLS 1.2, ECDSA, RSA-PSS, Ed25519 and P-521 servers, the
# key exchange groups (a server that wants secp256r1 or secp384r1 sends
# a HelloRetryRequest; X25519MLKEM768), session resumption, stapled OCSP
# responses (good, revoked, must-staple), a certificate request, key
# updates both ways, and the failures (wrong name, unknown CA, expired,
# an alert from the server).
#
#   run-interop.sh TLSTEST-PROGRAM FIXTURE-DIRECTORY
#
# FIXTURE-DIRECTORY holds what tools/TlsTest/make-fixtures.py made.
#
# Without openssl it says so and does nothing (exit 0).

set -uo pipefail

program="$1"
fixtures="${2:-}"
certificates="$(dirname "$0")/certificates"
port=44330
failures=0
server_process=""

if ! command -v openssl > /dev/null; then
    echo "TLS INTEROP TEST SKIPPED: openssl is not installed"
    exit 0
fi

# start_server [OPENSSL-OPTIONS]: TLS 1.3 only unless the options say
# -tls1_2 or -min_protocol (TLS 1.2 and 1.3).
start_server() {
    local version=(-tls1_3)
    port=$((port + 1))
    if [[ " $* " == *" -tls1_2 "* || " $* " == *" -min_protocol "* ]]; then
        version=()
    fi
    openssl s_server -quiet -accept "$port" "${version[@]}" -www "$@" > /dev/null 2>&1 &
    server_process=$!
    # Wait until it listens.
    for _ in $(seq 1 50); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2> /dev/null; then
            return
        fi
        sleep 0.1
    done
}

stop_server() {
    kill "$server_process" 2> /dev/null
    wait "$server_process" 2> /dev/null
}

# expect NAME PATTERN CLIENT-ARGUMENTS...
expect() {
    local name="$1" pattern="$2" output
    shift 2
    output=$("$program" --connect "$port" "$@" 2>&1)
    if [[ "$output" =~ $pattern ]]; then
        echo "ok   $name: $output" | head -n 1
    else
        echo "FAIL $name: expected /$pattern/, got: $output"
        failures=$((failures + 1))
    fi
}

ecdsa_server=(-cert "$certificates/server.pem" -key "$certificates/server.key"
    -cert_chain "$certificates/intermediate.pem")

start_server "${ecdsa_server[@]}"
expect "ECDSA server, default suites" '^ok TLS_AES_128_GCM_SHA256 [0-9]+ ' localhost "$certificates/ca.pem"
expect "ChaCha20-Poly1305" '^ok TLS_CHACHA20_POLY1305_SHA256 [0-9]+ ' localhost "$certificates/ca.pem" \
    TLS_CHACHA20_POLY1305_SHA256
expect "AES-256-GCM" '^ok TLS_AES_256_GCM_SHA384 [0-9]+ ' localhost "$certificates/ca.pem" TLS_AES_256_GCM_SHA384
expect "by address" '^ok ' 127.0.0.1 "$certificates/ca.pem"
expect "wrong host name" '^error -43 ' example.com "$certificates/ca.pem"
expect "unknown CA" '^error -42 ' localhost "$certificates/other-ca.pem"
expect "unknown CA, not verified" '^ok .*' localhost "$certificates/other-ca.pem" --no-verify
stop_server

start_server -cert "$certificates/server-rsa.pem" -key "$certificates/server-rsa.key"
expect "RSA server (RSA-PSS)" '^ok TLS_AES_128_GCM_SHA256 ' localhost "$certificates/ca.pem"
stop_server

start_server -cert "$certificates/expired.pem" -key "$certificates/expired.key" \
    -cert_chain "$certificates/intermediate.pem"
expect "expired certificate" '^error -40 ' localhost "$certificates/ca.pem"
stop_server

start_server -cert "$certificates/other-server.pem" -key "$certificates/other-server.key"
expect "untrusted root" '^error -42 ' localhost "$certificates/ca.pem"
stop_server

start_server "${ecdsa_server[@]}" -verify 1
expect "certificate request answered empty" '^ok ' localhost "$certificates/ca.pem"
stop_server

start_server "${ecdsa_server[@]}" -Verify 1
expect "server alert" '^error -13 .*alert' localhost "$certificates/ca.pem"
stop_server

# Key updates: s_server (without -www) sends what it reads, and on "K"
# a KeyUpdate asking for one back, on "k" one that does not. The client
# must read the lines sent under the new keys (21 + 14 bytes).
port=$((port + 1))
{ sleep 1; echo K; sleep 0.3; echo "after the key update"; sleep 0.3; echo k; sleep 0.3; echo "after another"
  sleep 0.5; echo Q; } | openssl s_server -accept "$port" -tls1_3 "${ecdsa_server[@]}" > /dev/null 2>&1 &
server_process=$!
sleep 0.5
expect "key updates" '^ok TLS_AES_128_GCM_SHA256 35 ' localhost "$certificates/ca.pem"
wait "$server_process" 2> /dev/null

# TLS 1.2: every suite, an RSA server, a group, a client that wants 1.2.
start_server "${ecdsa_server[@]}" -tls1_2
expect "TLS 1.2, ECDSA server" '^ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 [0-9]+ (yes|no) TLSv1.2 x25519 ' localhost \
    "$certificates/ca.pem"
expect "TLS 1.2 ChaCha20-Poly1305" '^ok TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 [0-9]+ (yes|no) TLSv1.2 ' \
    localhost "$certificates/ca.pem" ECDHE-ECDSA-CHACHA20-POLY1305
expect "TLS 1.2 AES-256-GCM" '^ok TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 [0-9]+ (yes|no) TLSv1.2 ' localhost \
    "$certificates/ca.pem" TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
expect "TLS 1.2 secp256r1" '^ok .* TLSv1.2 secp256r1 ' localhost "$certificates/ca.pem" --groups=secp256r1
expect "TLS 1.2 wrong host name" '^error -43 ' example.com "$certificates/ca.pem"
stop_server

start_server -cert "$certificates/server-rsa.pem" -key "$certificates/server-rsa.key" -tls1_2
expect "TLS 1.2, RSA server" '^ok TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 [0-9]+ (yes|no) TLSv1.2 ' localhost \
    "$certificates/ca.pem"
expect "TLS 1.2, RSA, ChaCha20-Poly1305" '^ok TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 ' localhost \
    "$certificates/ca.pem" ECDHE-RSA-CHACHA20-POLY1305
stop_server

# A server with both versions: TLS 1.3 unless the client wants 1.2 (the
# server's random then carries the downgrade sentinel, which a client
# that offered only 1.2 does not hold against it).
start_server "${ecdsa_server[@]}" -min_protocol TLSv1.2
expect "client limited to TLS 1.2" '^ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 .* TLSv1.2 ' localhost \
    "$certificates/ca.pem" --tls1.2
expect "TLS 1.3 by default" '^ok TLS_AES_128_GCM_SHA256 [0-9]+ (yes|no) TLSv1.3 ' localhost "$certificates/ca.pem"
expect "x25519 when only it is offered" '^ok .* TLSv1.3 x25519 ' localhost "$certificates/ca.pem" --groups=x25519
stop_server

# Key exchange groups: a server that takes only another group asks for
# it with a HelloRetryRequest.
start_server "${ecdsa_server[@]}" -groups P-256
expect "secp256r1 after a HelloRetryRequest" '^ok .* TLSv1.3 secp256r1 ' localhost "$certificates/ca.pem"
stop_server
start_server "${ecdsa_server[@]}" -groups P-384
expect "secp384r1 after a HelloRetryRequest" '^ok .* TLSv1.3 secp384r1 ' localhost "$certificates/ca.pem"
stop_server
start_server "${ecdsa_server[@]}" -groups X25519MLKEM768
expect "X25519MLKEM768 after a HelloRetryRequest" '^ok .* TLSv1.3 X25519MLKEM768 ' localhost "$certificates/ca.pem"
stop_server
start_server "${ecdsa_server[@]}"
expect "X25519MLKEM768 offered first" '^ok .* TLSv1.3 X25519MLKEM768 ' localhost "$certificates/ca.pem" \
    --groups=X25519MLKEM768,x25519
stop_server
start_server "${ecdsa_server[@]}" -groups P-256
expect "no group in common" '^error -13 .*handshake failure' localhost "$certificates/ca.pem" --groups=secp384r1
stop_server

# Resumption: the second connection uses the first one's ticket.
start_server "${ecdsa_server[@]}"
expect "session resumption" '^ok .* no'$'\n''ok .* TLSv1.3 [^ ]+ none yes' localhost "$certificates/ca.pem" --resume
stop_server
start_server "${ecdsa_server[@]}" -groups P-256
expect "session resumption after a HelloRetryRequest" '^ok .* no'$'\n''ok .* secp256r1 none yes' localhost \
    "$certificates/ca.pem" --resume
stop_server

if [[ -n "$fixtures" && -f "$fixtures/ocsp-good.der" ]]; then
    # Stapled OCSP responses.
    start_server "${ecdsa_server[@]}" -status_file "$fixtures/ocsp-good.der" -min_protocol TLSv1.2
    expect "OCSP staple, good" '^ok .* TLSv1.3 [^ ]+ good ' localhost "$certificates/ca.pem"
    expect "OCSP staple, good, TLS 1.2" '^ok .* TLSv1.2 x25519 good ' localhost "$certificates/ca.pem" --tls1.2
    stop_server
    start_server "${ecdsa_server[@]}" -status_file "$fixtures/ocsp-revoked.der" -min_protocol TLSv1.2
    expect "OCSP staple, revoked" '^error -52 ' localhost "$certificates/ca.pem"
    expect "OCSP staple, revoked, TLS 1.2" '^error -52 ' localhost "$certificates/ca.pem" --tls1.2
    expect "OCSP staple, revoked, not verified" '^ok .*'$'\n''ignored ' localhost "$certificates/ca.pem" --no-verify
    stop_server
    start_server -cert "$fixtures/must-staple.pem" -key "$fixtures/must-staple.key" \
        -cert_chain "$certificates/intermediate.pem"
    expect "must staple, no staple" '^error -54 ' localhost "$certificates/ca.pem"
    stop_server
    start_server -cert "$fixtures/must-staple.pem" -key "$fixtures/must-staple.key" \
        -cert_chain "$certificates/intermediate.pem" -status_file "$fixtures/ocsp-must-staple-good.der"
    expect "must staple, stapled" '^ok .* good ' localhost "$certificates/ca.pem"
    stop_server

    # Ed25519 and P-521 servers.
    for algorithm in ed25519 p521; do
        start_server -cert "$fixtures/$algorithm-server.pem" -key "$fixtures/$algorithm-server.key"
        expect "$algorithm server" '^ok TLS_AES_128_GCM_SHA256 .* TLSv1.3 ' localhost "$fixtures/$algorithm-root.pem"
        stop_server
        start_server -cert "$fixtures/$algorithm-server.pem" -key "$fixtures/$algorithm-server.key" -tls1_2
        expect "$algorithm server, TLS 1.2" '^ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 .* TLSv1.2 ' localhost \
            "$fixtures/$algorithm-root.pem"
        stop_server
    done
else
    echo "skipped: OCSP, Ed25519 and P-521 servers (no fixtures)"
fi

if (( failures > 0 )); then
    echo "TLS INTEROP TEST FAILED: $failures"
    exit 1
fi
echo "TLS INTEROP TEST PASSED"
