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
# libquic's connection core (in the server role, under the test's TLS
# and HTTP/3 server) against an independent QUIC and HTTP/3 stack: curl
# built with HTTP/3 (ngtcp2, nghttp3) fetches from QuicTest serve on
# 127.0.0.1: a small response, 3 MB, a 200 KB upload echoed back, and
# several requests over one connection (nghttp3's encoder may use the
# QPACK dynamic table, which libquic's decoder then follows).
#
#   run-curl-interop.sh QUICTEST-PROGRAM WORK-DIRECTORY
#
# Without a curl that speaks HTTP/3 it says so and does nothing (exit 0).

set -uo pipefail

program="$1"
work="$2"
port=48500
failures=0

if ! command -v curl > /dev/null || ! curl --version | grep -q 'HTTP3'; then
    echo "QUIC CURL INTEROP SKIPPED: no curl with HTTP/3"
    exit 0
fi
mkdir -p "$work"

check() {
    local name="$1"
    shift
    if "$@"; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        failures=$((failures + 1))
    fi
}

# serve: one connection to the test server on a new port.
serve() {
    port=$((port + 1))
    "$program" serve "$port" > "$work/server-$port.out" 2>&1 &
    server_process=$!
    sleep 0.3
}

finish_server() {
    wait "$server_process"
    check "server on $port had no trouble" grep -q 'requests served' "$work/server-$port.out"
}

head -c 200000 /dev/urandom > "$work/upload.bin"

serve
curl -sS --http3-only -k --max-time 20 "https://127.0.0.1:$port/hello" -o "$work/hello.txt"
check "GET /hello" grep -qx 'Hello, HTTP/3!' "$work/hello.txt"
finish_server

serve
curl -sS --http3-only -k --max-time 30 \
    "https://127.0.0.1:$port/size/3000000" -o "$work/big.bin" \
    "https://127.0.0.1:$port/hello" -o "$work/hello2.txt" \
    "https://127.0.0.1:$port/status/204" -o "$work/empty.txt" \
    "https://127.0.0.1:$port/hello" -o "$work/hello3.txt"
check "GET 3 MB" python3 -I -c "
import sys
data = open(sys.argv[1], 'rb').read()
sys.exit(0 if len(data) == 3000000 and all(data[i] == (i * 7 + 3) & 255 for i in range(len(data))) else 1)
" "$work/big.bin"
check "requests on one connection" cmp -s "$work/hello2.txt" "$work/hello3.txt"
finish_server

serve
curl -sS --http3-only -k --max-time 20 --data-binary "@$work/upload.bin" \
    "https://127.0.0.1:$port/echo" -o "$work/echo.bin"
check "POST 200 KB echoed" cmp -s "$work/upload.bin" "$work/echo.bin"
finish_server

if [ "$failures" -ne 0 ]; then
    echo "QUIC CURL INTEROP FAILED: $failures failures"
    exit 1
fi
echo "QUIC CURL INTEROP PASSED"
