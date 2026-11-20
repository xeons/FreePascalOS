#!/bin/sh
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

# libhttp against other implementations, on the host:
#
#   run-interop.sh HTTPTEST WORK-DIRECTORY
#
# 1. HPACK both ways with libnghttp2 (check-hpack-with-nghttp2.py),
#    skipped without libnghttp2;
# 2. the client against scripts/test-web-server.py in its https-h2 mode
#    (HTTP/2 over TLS, the server QEMU's wget test uses), started on a
#    local port by serve-on-port.py; when curl can speak HTTP/2 it checks
#    the server first.
# Prints "ok"/"FAIL" lines and a last line with the totals.

http_test="$1"
work="$2"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
mkdir -p "$work"
failed=0

"$http_test" hpack-export "$work/hpack-ours.txt"
python3 -I "$here/check-hpack-with-nghttp2.py" "$work/hpack-ours.txt" "$work/hpack-theirs.txt"
status=$?
if [ $status -eq 0 ]; then
    "$http_test" hpack-import "$work/hpack-theirs.txt" || failed=1
elif [ $status -ne 2 ]; then
    failed=1
fi

if ! python3 -c 'import ssl' 2> /dev/null; then
    echo "skipped: the HTTP/2 interop test needs Python 3 with its ssl module"
else
    port=$((30000 + $$ % 20000))
    (cd "$root/scripts" && exec python3 -I "$here/serve-on-port.py" "$port" python3 test-web-server.py https-h2 \
        server-chain.pem server.key) &
    server=$!
    trap 'kill $server 2> /dev/null' EXIT
    sleep 1
    if curl --version 2> /dev/null | grep -q HTTP2; then
        answer="$(curl -s -k --http2 -w ' %{http_version}' "https://127.0.0.1:$port/agent" -A curl-check)"
        if [ "$answer" = "curl-check
 2" ]; then
            echo "ok curl speaks HTTP/2 with the test server"
        else
            echo "FAIL curl and the test server: $answer"
            failed=1
        fi
    fi
    "$http_test" interop "$port" || failed=1
fi

if [ $failed -ne 0 ]; then
    echo "HTTP INTEROP TEST FAILED"
    exit 1
fi
echo "HTTP INTEROP TEST PASSED"
