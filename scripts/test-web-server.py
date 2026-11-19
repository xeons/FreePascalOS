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
no port is opened. The connection is kept alive: requests are answered
one after another until the client asks to close ("Connection: close")
or goes. The pages:

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
    /count              how many requests this connection has carried
    /accept-encoding    the Accept-Encoding sent
    /gzip.txt           100 lines of text, gzip encoded when gzip is
                        accepted; /gzip-chunked.txt the same, chunked;
                        /archive.gz the same encoded always (a .gz file
                        that --compression=auto leaves as it is);
                        /gzip-bad.txt damaged gzip data
    /cookie/set         sets "session" (Path=/cookie) and "persistent"
                        (Path=/, Max-Age=3600)
    /cookie/redirect    sets them and redirects to /cookie/show
    /cookie/show        the Cookie header sent, or "none"
    /basic              Basic authentication (user, secret)
    /digest             Digest authentication with SHA-256 or MD5, qop
                        auth (user, secret); /digest-md5 MD5 only
    /robots.txt         keeps robots out of /site/private/
    /site/...           a small site for wget -r (SITE below)
    anything else       404
"""

import base64
import gzip
import hashlib
import os
import re
import select
import socket
import ssl
import sys
import time

HELLO = b"Hello from the FreePascalOS test server\n"
DATA = bytes((i * 7 + i // 256) % 256 for i in range(200000))
LINES = b"".join(b"line %d of the compressible text\n" % number for number in range(1, 101))
CERTIFICATES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "TlsTest", "certificates")
USER = "user"
PASSWORD = "secret"
REALM = "wgettest"
NONCE = "dcd98b7102dd2f0e8b11d0f600bfb0c093"
OPAQUE = "5ccc069c403ebaf9f0171e9517f40e41"
ROBOTS = b"User-agent: *\nDisallow: /site/private/\n"

SITE = {
    "/site/index.html": ("text/html", b"<html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body>\n"
                         b"<a href=\"page1.html\">one</a> <a href=\"sub/page2.html\">two</a>\n"
                         b"<img src=\"pic.png\"> <a href=\"../hello.txt\">up</a>\n"
                         b"<a href=\"private/secret.html\">secret</a> <a href=\"notes.tmp\">notes</a>\n"
                         b"<a href=\"http://10.0.2.101/hello.txt\">elsewhere</a>\n</body></html>\n"),
    "/site/page1.html": ("text/html", b"<html><body><a href=\"index.html\">home</a>\n"
                         b"<a href=\"sub/page2.html#part\">two</a></body></html>\n"),
    "/site/sub/page2.html": ("text/html", b"<html><body><a href=\"deep/page3.html\">three</a>\n"
                             b"<img src=\"../pic.png\"></body></html>\n"),
    "/site/sub/deep/page3.html": ("text/html", b"<html><body><p>deep</p><img src=\"deep.png\"></body></html>\n"),
    "/site/style.css": ("text/css", b"body { color: navy }\n"),
    "/site/pic.png": ("image/png", b"\x89PNG\r\n\x1a\nnot really a picture\n"),
    "/site/sub/deep/deep.png": ("image/png", b"\x89PNG\r\n\x1a\ndeep picture\n"),
    "/site/notes.tmp": ("text/plain", b"scratch notes\n"),
    "/site/private/secret.html": ("text/html", b"<html><body>secret</body></html>\n"),
}


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


class Connection:
    """The requests of one connection, with what is left over between them."""

    def __init__(self, stream):
        self.stream = stream
        self.pending = b""
        self.requests = 0
        self.closing = False

    def read_request(self):
        while b"\r\n\r\n" not in self.pending:
            more = self.stream.read()
            if not more:
                return None, {}
            self.pending += more
        head, self.pending = self.pending.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        method, path, _ = lines[0].split(" ", 2)
        headers = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        self.requests += 1
        if "close" in headers.get("connection", "").lower():
            self.closing = True
        return (method, path), headers

    def write(self, data):
        self.stream.write(data)

    def respond(self, status, headers, body=b""):
        lines = [f"HTTP/1.1 {status}"] + [f"{name}: {value}" for name, value in headers]
        if self.closing:
            lines.append("Connection: close")
        self.stream.write("\r\n".join(lines + ["", ""]).encode("latin-1") + body)

    def respond_body(self, status, content_type, body, extra=()):
        self.respond(status, [("Content-Type", content_type), ("Content-Length", str(len(body)))] + list(extra),
                     body)


def send_chunked(connection, data, content_type="application/octet-stream", extra=()):
    connection.respond("200 OK", [("Content-Type", content_type), ("Transfer-Encoding", "chunked")] + list(extra))
    position = 0
    size = 1
    while position < len(data):
        piece = data[position:position + size]
        connection.write(b"%x;piece=%d\r\n" % (len(piece), size) + piece + b"\r\n")
        position += len(piece)
        size = size * 3 % 9973 + 1
    connection.write(b"0\r\nX-Trailer: done\r\n\r\n")


def send_data(connection, headers):
    start = 0
    requested = headers.get("range", "")
    if requested.startswith("bytes=") and requested.endswith("-"):
        start = int(requested[6:-1])
        if start >= len(DATA):
            connection.respond("416 Range Not Satisfiable", [("Content-Range", f"bytes */{len(DATA)}"),
                                                             ("Content-Length", "0")])
            return
        body = DATA[start:]
        connection.respond("206 Partial Content", [("Content-Type", "application/octet-stream"),
                                                   ("Content-Length", str(len(body))),
                                                   ("Content-Range", f"bytes {start}-{len(DATA) - 1}/{len(DATA)}")],
                           body)
        return
    connection.respond("200 OK", [("Content-Type", "application/octet-stream"), ("Content-Length", str(len(DATA))),
                                  ("Accept-Ranges", "bytes")], DATA)


def accepts_gzip(headers):
    return "gzip" in headers.get("accept-encoding", "").lower()


def send_gzip_pages(connection, path, headers):
    compressed = gzip.compress(LINES, mtime=0)
    if path == "/gzip.txt":
        if accepts_gzip(headers):
            connection.respond_body("200 OK", "text/plain", compressed, [("Content-Encoding", "gzip")])
        else:
            connection.respond_body("200 OK", "text/plain", LINES)
    elif path == "/gzip-chunked.txt":
        if accepts_gzip(headers):
            send_chunked(connection, compressed, "text/plain", [("Content-Encoding", "gzip")])
        else:
            send_chunked(connection, LINES, "text/plain")
    elif path == "/archive.gz":
        connection.respond_body("200 OK", "application/gzip", compressed, [("Content-Encoding", "gzip")])
    else:
        damaged = compressed[:20] + bytes(byte ^ 0x5A for byte in compressed[20:40]) + compressed[40:]
        connection.respond_body("200 OK", "text/plain", damaged, [("Content-Encoding", "gzip")])


def cookie_headers():
    return [("Set-Cookie", "session=abc123; Path=/cookie"),
            ("Set-Cookie", "persistent=yes; Path=/; Max-Age=3600")]


def send_cookie_pages(connection, path, headers):
    if path == "/cookie/set":
        connection.respond_body("200 OK", "text/plain", b"set\n", cookie_headers())
    elif path == "/cookie/redirect":
        connection.respond("302 Found", [("Location", "/cookie/show"), ("Content-Length", "0")] + cookie_headers())
    else:
        body = (headers.get("cookie", "") or "none").encode("latin-1") + b"\n"
        connection.respond_body("200 OK", "text/plain", body)


def digest_parameters(value):
    return {name.lower(): quoted if quoted else bare
            for name, quoted, bare in re.findall(r'(\w+)=(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))', value)}


def digest_is_right(value, method, algorithms):
    if not value.lower().startswith("digest "):
        return False
    given = digest_parameters(value[7:])
    algorithm = given.get("algorithm", "MD5")
    if algorithm not in algorithms or given.get("nonce") != NONCE or given.get("username") != USER:
        return False
    hash_name = "sha256" if algorithm == "SHA-256" else "md5"

    def digest_of(text):
        return hashlib.new(hash_name, text.encode("latin-1")).hexdigest()

    first = digest_of(f"{USER}:{REALM}:{PASSWORD}")
    second = digest_of(f"{method}:{given.get('uri', '')}")
    expected = digest_of(f"{first}:{NONCE}:{given.get('nc', '')}:{given.get('cnonce', '')}:auth:{second}")
    return given.get("qop") == "auth" and given.get("response") == expected and given.get("opaque") == OPAQUE


def send_authentication_pages(connection, method, path, headers):
    authorization = headers.get("authorization", "")
    if path == "/basic":
        expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        if authorization == expected:
            connection.respond_body("200 OK", "text/plain", b"basic ok\n")
        else:
            connection.respond_body("401 Unauthorized", "text/plain", b"who are you?\n",
                                    [("WWW-Authenticate", f'Basic realm="{REALM}"')])
        return
    algorithms = ["MD5"] if path == "/digest-md5" else ["SHA-256", "MD5"]
    if digest_is_right(authorization, method, algorithms):
        connection.respond_body("200 OK", "text/plain", b"digest ok\n")
        return
    challenges = [("WWW-Authenticate", f'Digest realm="{REALM}", qop="auth", algorithm={algorithm}, '
                                       f'nonce="{NONCE}", opaque="{OPAQUE}"') for algorithm in algorithms]
    connection.respond_body("401 Unauthorized", "text/plain", b"who are you?\n", challenges)


def serve_request(connection, method, path, headers):
    """Answers one request; False when the connection is to end."""
    if path == "/hello.txt":
        connection.respond_body("200 OK", "text/plain", HELLO)
    elif path == "/data.bin":
        send_data(connection, headers)
    elif path == "/chunked.bin":
        send_chunked(connection, DATA)
    elif path == "/stream.bin":
        connection.write(b"HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n" + DATA)
        return False
    elif path.startswith("/redirect/"):
        remaining = int(path[len("/redirect/"):])
        if remaining == 0:
            connection.respond("301 Moved Permanently", [("Location", "/hello.txt"), ("Content-Length", "0")])
        else:
            connection.respond("302 Found", [("Location", f"/redirect/{remaining - 1}"), ("Content-Length", "0")])
    elif path == "/relative":
        connection.respond("302 Found", [("Location", "hello.txt"), ("Content-Length", "0")])
    elif path == "/to-https":
        connection.respond("301 Moved Permanently", [("Location", "https://10.0.2.101/hello.txt"),
                                                     ("Content-Length", "0")])
    elif path == "/see-other":
        connection.respond("303 See Other", [("Location", "/hello.txt"), ("Content-Length", "0")])
    elif path == "/temporary":
        connection.respond("307 Temporary Redirect", [("Location", "/hello.txt"), ("Content-Length", "0")])
    elif path == "/permanent":
        connection.respond("308 Permanent Redirect", [("Location", "/hello.txt"), ("Content-Length", "0")])
    elif path == "/agent":
        connection.respond_body("200 OK", "text/plain", headers.get("user-agent", "").encode("latin-1") + b"\n")
    elif path == "/slow":
        time.sleep(20)
        return False
    elif path == "/ca.pem":
        with open(os.path.join(CERTIFICATES, "ca.pem"), "rb") as file:
            connection.respond_body("200 OK", "application/x-pem-file", file.read())
    elif path == "/count":
        connection.respond_body("200 OK", "text/plain", b"%d\n" % connection.requests)
    elif path == "/accept-encoding":
        connection.respond_body("200 OK", "text/plain", headers.get("accept-encoding", "").encode("latin-1") + b"\n")
    elif path in ("/gzip.txt", "/gzip-chunked.txt", "/archive.gz", "/gzip-bad.txt"):
        send_gzip_pages(connection, path, headers)
    elif path.startswith("/cookie/"):
        send_cookie_pages(connection, path, headers)
    elif path in ("/basic", "/digest", "/digest-md5"):
        send_authentication_pages(connection, method, path, headers)
    elif path == "/robots.txt":
        connection.respond_body("200 OK", "text/plain", ROBOTS)
    elif path in SITE:
        content_type, body = SITE[path]
        connection.respond_body("200 OK", content_type, body)
    elif path == "/site/":
        content_type, body = SITE["/site/index.html"]
        connection.respond_body("200 OK", content_type, body)
    else:
        connection.respond_body("404 Not Found", "text/plain", b"not found\n")
    return True


def serve(stream):
    connection = Connection(stream)
    while True:
        request, headers = connection.read_request()
        if request is None:
            return
        if not serve_request(connection, request[0], request[1], headers) or connection.closing:
            return


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
