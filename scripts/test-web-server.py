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

"""The web server of the wget test in QEMU (wgettest), one connection
per run on standard input and output: QEMU's user network starts it for
each TCP connection the guest makes to a guestfwd address
(scripts/test-qemu.sh).

    test-web-server.py http
    test-web-server.py https CERTIFICATE-CHAIN KEY
    test-web-server.py relay PORT        (to a server on the host, such
                                          as openssl s_server)

TLS runs through Python's ssl module (OpenSSL) over memory buffers, so
no port is opened. The pages:

    /hello.txt          a line of text
    /data.bin           200000 bytes (byte i is (i * 7 + i // 256) mod 256),
                        with Content-Length; ranges ("bytes=N-") answered
    /chunked.bin        the same bytes, chunked
    /stream.bin         the same bytes ending with the connection
    /redirect/N         302 to /redirect/N-1; /redirect/0 is 301 to /hello.txt
    /relative           302 to "hello.txt"
    /to-https           301 to https://10.0.2.101/hello.txt
    /see-other          303 to /hello.txt
    /temporary          307 to /hello.txt, /permanent 308 to /hello.txt
    /agent              the User-Agent sent
    /slow               no answer for 20 seconds
    /ca.pem             the test root certificate
    anything else       404
"""

import os
import select
import socket
import ssl
import sys
import time

HELLO = b"Hello from the FreePascalOS test server\n"
DATA = bytes((i * 7 + i // 256) % 256 for i in range(200000))
CERTIFICATES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "TlsTest", "certificates")


class PlainStream:
    def read(self):
        return os.read(0, 16384)

    def write(self, data):
        while data:
            written = os.write(1, data)
            data = data[written:]

    def close(self):
        pass


class TlsStream:
    """TLS over standard input and output through memory buffers."""

    def __init__(self, chain, key):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(chain, key)
        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.tls = context.wrap_bio(self.incoming, self.outgoing, server_side=True)
        self.plain = PlainStream()
        self.run(self.tls.do_handshake)

    def flush(self):
        data = self.outgoing.read()
        if data:
            self.plain.write(data)

    def run(self, operation, *arguments):
        while True:
            try:
                result = operation(*arguments)
                self.flush()
                return result
            except ssl.SSLWantReadError:
                self.flush()
                data = self.plain.read()
                if not data:
                    raise EOFError
                self.incoming.write(data)

    def read(self):
        try:
            return self.run(self.tls.read, 16384)
        except (EOFError, ssl.SSLZeroReturnError):
            return b""

    def write(self, data):
        self.run(self.tls.write, data)

    def close(self):
        try:
            self.tls.unwrap()
        except (ssl.SSLError, EOFError):
            pass
        self.flush()


def read_request(stream):
    data = b""
    while b"\r\n\r\n" not in data:
        more = stream.read()
        if not more:
            return None, {}
        data += more
    head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
    method, path, _ = head[0].split(" ", 2)
    headers = {}
    for line in head[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return (method, path), headers


def respond(stream, status, headers, body=b""):
    lines = [f"HTTP/1.1 {status}"] + [f"{name}: {value}" for name, value in headers] + ["Connection: close", "", ""]
    stream.write("\r\n".join(lines).encode("latin-1") + body)


def send_chunked(stream, data):
    respond(stream, "200 OK", [("Content-Type", "application/octet-stream"), ("Transfer-Encoding", "chunked")])
    position = 0
    size = 1
    while position < len(data):
        piece = data[position:position + size]
        stream.write(b"%x;piece=%d\r\n" % (len(piece), size) + piece + b"\r\n")
        position += len(piece)
        size = size * 3 % 9973 + 1
    stream.write(b"0\r\nX-Trailer: done\r\n\r\n")


def send_data(stream, headers):
    start = 0
    requested = headers.get("range", "")
    if requested.startswith("bytes=") and requested.endswith("-"):
        start = int(requested[6:-1])
        if start >= len(DATA):
            respond(stream, "416 Range Not Satisfiable", [("Content-Range", f"bytes */{len(DATA)}")])
            return
        body = DATA[start:]
        respond(stream, "206 Partial Content", [("Content-Type", "application/octet-stream"),
                                                ("Content-Length", str(len(body))),
                                                ("Content-Range", f"bytes {start}-{len(DATA) - 1}/{len(DATA)}")], body)
        return
    respond(stream, "200 OK", [("Content-Type", "application/octet-stream"), ("Content-Length", str(len(DATA))),
                               ("Accept-Ranges", "bytes")], DATA)


def serve(stream):
    request, headers = read_request(stream)
    if request is None:
        return
    path = request[1]
    if path == "/hello.txt":
        respond(stream, "200 OK", [("Content-Type", "text/plain"), ("Content-Length", str(len(HELLO)))], HELLO)
    elif path == "/data.bin":
        send_data(stream, headers)
    elif path == "/chunked.bin":
        send_chunked(stream, DATA)
    elif path == "/stream.bin":
        stream.write(b"HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n" + DATA)
    elif path.startswith("/redirect/"):
        remaining = int(path[len("/redirect/"):])
        if remaining == 0:
            respond(stream, "301 Moved Permanently", [("Location", "/hello.txt"), ("Content-Length", "0")])
        else:
            respond(stream, "302 Found", [("Location", f"/redirect/{remaining - 1}"), ("Content-Length", "0")])
    elif path == "/relative":
        respond(stream, "302 Found", [("Location", "hello.txt"), ("Content-Length", "0")])
    elif path == "/to-https":
        respond(stream, "301 Moved Permanently", [("Location", "https://10.0.2.101/hello.txt"),
                                                  ("Content-Length", "0")])
    elif path == "/see-other":
        respond(stream, "303 See Other", [("Location", "/hello.txt"), ("Content-Length", "0")])
    elif path == "/temporary":
        respond(stream, "307 Temporary Redirect", [("Location", "/hello.txt"), ("Content-Length", "0")])
    elif path == "/permanent":
        respond(stream, "308 Permanent Redirect", [("Location", "/hello.txt"), ("Content-Length", "0")])
    elif path == "/agent":
        body = headers.get("user-agent", "").encode("latin-1") + b"\n"
        respond(stream, "200 OK", [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))], body)
    elif path == "/slow":
        time.sleep(20)
    elif path == "/ca.pem":
        with open(os.path.join(CERTIFICATES, "ca.pem"), "rb") as file:
            body = file.read()
        respond(stream, "200 OK", [("Content-Type", "application/x-pem-file"), ("Content-Length", str(len(body)))],
                body)
    else:
        body = b"not found\n"
        respond(stream, "404 Not Found", [("Content-Type", "text/plain"), ("Content-Length", str(len(body)))], body)


def relay(port):
    connection = socket.create_connection(("127.0.0.1", port))
    while True:
        ready, _, _ = select.select([0, connection], [], [])
        if 0 in ready:
            data = os.read(0, 16384)
            if not data:
                connection.shutdown(socket.SHUT_WR)
                break
            connection.sendall(data)
        if connection in ready:
            data = connection.recv(16384)
            if not data:
                return
            os.write(1, data)
    while True:
        data = connection.recv(16384)
        if not data:
            return
        os.write(1, data)


def main():
    mode = sys.argv[1]
    if mode == "relay":
        relay(int(sys.argv[2]))
        return
    try:
        if mode == "https":
            stream = TlsStream(os.path.join(CERTIFICATES, sys.argv[2]), os.path.join(CERTIFICATES, sys.argv[3]))
        else:
            stream = PlainStream()
        serve(stream)
        stream.close()
    except (EOFError, ssl.SSLError, BrokenPipeError, ConnectionResetError):
        pass


if __name__ == "__main__":
    main()
