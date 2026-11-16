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
# s_server on 127.0.0.1 with the test certificates: every cipher suite,
# ECDSA and RSA-PSS servers, a certificate request, key updates both
# ways, and the failures (wrong name, unknown CA, expired, an alert from
# the server). (s_server cannot be made to send a HelloRetryRequest to
# a client that offers only x25519; TlsTest checks retries against a
# scripted server instead.)
#
#   run-interop.sh TLSTEST-PROGRAM
#
# Without openssl it says so and does nothing (exit 0).

set -uo pipefail

program="$1"
certificates="$(dirname "$0")/certificates"
port=44330
failures=0
server_process=""

if ! command -v openssl > /dev/null; then
    echo "TLS INTEROP TEST SKIPPED: openssl is not installed"
    exit 0
fi

start_server() {
    port=$((port + 1))
    openssl s_server -quiet -accept "$port" -tls1_3 -www "$@" > /dev/null 2>&1 &
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

if (( failures > 0 )); then
    echo "TLS INTEROP TEST FAILED: $failures"
    exit 1
fi
echo "TLS INTEROP TEST PASSED"
