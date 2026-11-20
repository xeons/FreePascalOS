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

"""HTTP/2 (RFC 9113) for scripts/test-web-server.py, in plain Python (no
h2 package): the frames a server needs, an HPACK decoder (RFC 7541:
the static and dynamic tables, Huffman coding from the code lengths of
appendix B, which form a canonical code) and an encoder that sends
literals without indexing. Requests are answered one stream at a time,
in the order they end, honouring the client's flow control windows;
the pages are the HTTP/1.1 server's (a stand-in connection collects
what it answers). The HTTP/1.1 server's chunked and connection-ending
pages are sent as plain bodies here."""

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION = range(10)
END_STREAM, ACK, END_HEADERS, PADDED, PRIORITY_FLAG = 0x1, 0x1, 0x4, 0x8, 0x20
SETTINGS_INITIAL_WINDOW_SIZE, SETTINGS_MAX_FRAME_SIZE = 0x4, 0x5
MAX_FRAME = 16384

STATIC_TABLE = [
    (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"), (":path", "/index.html"),
    (":scheme", "http"), (":scheme", "https"), (":status", "200"), (":status", "204"), (":status", "206"),
    (":status", "304"), (":status", "400"), (":status", "404"), (":status", "500"), ("accept-charset", ""),
    ("accept-encoding", "gzip, deflate"), ("accept-language", ""), ("accept-ranges", ""), ("accept", ""),
    ("access-control-allow-origin", ""), ("age", ""), ("allow", ""), ("authorization", ""), ("cache-control", ""),
    ("content-disposition", ""), ("content-encoding", ""), ("content-language", ""), ("content-length", ""),
    ("content-location", ""), ("content-range", ""), ("content-type", ""), ("cookie", ""), ("date", ""),
    ("etag", ""), ("expect", ""), ("expires", ""), ("from", ""), ("host", ""), ("if-match", ""),
    ("if-modified-since", ""), ("if-none-match", ""), ("if-range", ""), ("if-unmodified-since", ""),
    ("last-modified", ""), ("link", ""), ("location", ""), ("max-forwards", ""), ("proxy-authenticate", ""),
    ("proxy-authorization", ""), ("range", ""), ("referer", ""), ("refresh", ""), ("retry-after", ""),
    ("server", ""), ("set-cookie", ""), ("strict-transport-security", ""), ("transfer-encoding", ""),
    ("user-agent", ""), ("vary", ""), ("via", ""), ("www-authenticate", "")]

HUFFMAN_LENGTHS = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28,
    28, 28, 28, 28, 6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15,
    6, 12, 10, 13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14,
    6, 15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28, 20,
    22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23, 24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23,
    22, 23, 23, 24, 22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23, 21, 21, 22, 21, 23, 22, 23,
    23, 20, 22, 22, 22, 23, 22, 22, 23, 26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25, 19, 21,
    26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27, 20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24,
    24, 26, 23, 26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26, 30]


def _huffman_codes():
    codes = {}
    code = 0
    previous = None
    for symbol in sorted(range(257), key=lambda s: (HUFFMAN_LENGTHS[s], s)):
        length = HUFFMAN_LENGTHS[symbol]
        if previous is not None:
            code = (code + 1) << (length - previous)
        previous = length
        codes[(code, length)] = symbol
    return codes


HUFFMAN_DECODING = _huffman_codes()


class HpackError(Exception):
    pass


def huffman_decode(data):
    output = bytearray()
    code = length = 0
    for byte in data:
        for bit in range(7, -1, -1):
            code = (code << 1) | ((byte >> bit) & 1)
            length += 1
            symbol = HUFFMAN_DECODING.get((code, length))
            if symbol is not None:
                if symbol == 256:
                    raise HpackError("EOS in a string")
                output.append(symbol)
                code = length = 0
            elif length > 30:
                raise HpackError("bad Huffman code")
    if length > 7 or code != (1 << length) - 1:
        raise HpackError("bad Huffman padding")
    return bytes(output)


class HpackDecoder:
    def __init__(self):
        self.table = []
        self.size = 0
        self.maximum = 4096

    def _evict(self):
        while self.size > self.maximum and self.table:
            name, value = self.table.pop()
            self.size -= 32 + len(name) + len(value)

    def _add(self, name, value):
        self.table.insert(0, (name, value))
        self.size += 32 + len(name) + len(value)
        self._evict()

    def _entry(self, index):
        if 1 <= index <= len(STATIC_TABLE):
            name, value = STATIC_TABLE[index - 1]
            return name.encode(), value.encode()
        if 0 < index - len(STATIC_TABLE) <= len(self.table):
            return self.table[index - len(STATIC_TABLE) - 1]
        raise HpackError("index %d past the tables" % index)

    @staticmethod
    def _integer(data, position, prefix):
        mask = (1 << prefix) - 1
        value = data[position] & mask
        position += 1
        if value < mask:
            return value, position
        shift = 0
        while True:
            byte = data[position]
            position += 1
            value += (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                return value, position

    def _string(self, data, position):
        huffman = data[position] & 0x80
        length, position = self._integer(data, position, 7)
        text = data[position:position + length]
        if len(text) != length:
            raise HpackError("a string past the block")
        return (huffman_decode(text) if huffman else bytes(text)), position + length

    def decode(self, data):
        fields = []
        position = 0
        while position < len(data):
            byte = data[position]
            if byte & 0x80:
                index, position = self._integer(data, position, 7)
                fields.append(self._entry(index))
                continue
            if byte & 0xE0 == 0x20:
                self.maximum, position = self._integer(data, position, 5)
                self._evict()
                continue
            indexing = byte & 0xC0 == 0x40
            index, position = self._integer(data, position, 6 if indexing else 4)
            if index:
                name = self._entry(index)[0]
            else:
                name, position = self._string(data, position)
            value, position = self._string(data, position)
            if indexing:
                self._add(name, value)
            fields.append((name, value))
        return [(name.decode("latin-1"), value.decode("latin-1")) for name, value in fields]


def hpack_integer(value, prefix, flags=0):
    mask = (1 << prefix) - 1
    if value < mask:
        return bytes([flags | value])
    output = bytearray([flags | mask])
    value -= mask
    while value >= 128:
        output.append((value & 0x7F) | 0x80)
        value >>= 7
    output.append(value)
    return bytes(output)


def hpack_encode(fields):
    """Literals without indexing, names and values as they are."""
    output = bytearray()
    for name, value in fields:
        name, value = name.lower().encode("latin-1"), str(value).encode("latin-1")
        output += b"\x00" + hpack_integer(len(name), 7) + name + hpack_integer(len(value), 7) + value
    return bytes(output)


def frame(frame_type, flags, stream, payload=b""):
    return len(payload).to_bytes(3, "big") + bytes([frame_type, flags]) + stream.to_bytes(4, "big") + payload


class Http2Response:
    """Stands in for test-web-server's HTTP/1.1 connection: collects the
    status, fields and body serve_request writes."""

    def __init__(self, requests):
        self.requests = requests
        self.closing = False
        self.status = 500
        self.fields = []
        self.body = b""

    def respond(self, status, headers, body=b""):
        self.status = int(status.split(" ", 1)[0])
        self.fields = [(name, value) for name, value in headers
                       if name.lower() not in ("connection", "transfer-encoding", "content-length")]
        self.body += body

    def respond_body(self, status, content_type, body, extra=()):
        self.respond(status, [("Content-Type", content_type)] + list(extra), body)

    def write(self, data):
        self.body += data


class Http2Connection:
    def __init__(self, stream, serve_request, plain_pages):
        self.stream = stream
        self.serve_request = serve_request
        self.plain_pages = plain_pages
        self.pending = b""
        self.decoder = HpackDecoder()
        self.requests = 0
        self.streams = {}
        self.block = b""
        self.block_stream = 0
        self.block_end = False
        self.peer_window = 65535
        self.connection_window = 65535
        self.windows = {}
        self.peer_frame_size = MAX_FRAME
        self.done = False

    def read_frame(self):
        while len(self.pending) < 9 or len(self.pending) < 9 + int.from_bytes(self.pending[:3], "big"):
            more = self.stream.read()
            if not more:
                return None
            self.pending += more
        length = int.from_bytes(self.pending[:3], "big")
        frame_type, flags = self.pending[3], self.pending[4]
        stream = int.from_bytes(self.pending[5:9], "big") & 0x7FFFFFFF
        payload = self.pending[9:9 + length]
        self.pending = self.pending[9 + length:]
        return frame_type, flags, stream, payload

    def send(self, data):
        self.stream.write(data)

    def handle_control(self, frame_type, flags, stream, payload):
        """SETTINGS, PING, WINDOW_UPDATE, GOAWAY; True if it was one."""
        if frame_type == SETTINGS:
            if not flags & ACK:
                for offset in range(0, len(payload), 6):
                    identifier = int.from_bytes(payload[offset:offset + 2], "big")
                    value = int.from_bytes(payload[offset + 2:offset + 6], "big")
                    if identifier == SETTINGS_INITIAL_WINDOW_SIZE:
                        for key in self.windows:
                            self.windows[key] += value - self.peer_window
                        self.peer_window = value
                    elif identifier == SETTINGS_MAX_FRAME_SIZE:
                        self.peer_frame_size = value
                self.send(frame(SETTINGS, ACK, 0))
        elif frame_type == PING:
            if not flags & ACK:
                self.send(frame(PING, ACK, 0, payload))
        elif frame_type == WINDOW_UPDATE:
            increment = int.from_bytes(payload, "big") & 0x7FFFFFFF
            if stream == 0:
                self.connection_window += increment
            else:
                self.windows[stream] = self.windows.get(stream, self.peer_window) + increment
        elif frame_type == GOAWAY:
            self.done = True
        else:
            return False
        return True

    def send_data(self, stream, body):
        """The body in DATA frames within the windows, the last one ending
        the stream; waits for WINDOW_UPDATEs when they are spent."""
        self.windows.setdefault(stream, self.peer_window)
        position = 0
        while True:
            allowed = min(self.peer_frame_size, len(body) - position, self.windows[stream], self.connection_window)
            if allowed <= 0 and position < len(body):
                incoming = self.read_frame()
                if incoming is None:
                    return
                if not self.handle_control(*incoming):
                    self.handle_frame(*incoming)
                continue
            piece = body[position:position + allowed]
            position += allowed
            self.windows[stream] -= allowed
            self.connection_window -= allowed
            self.send(frame(DATA, END_STREAM if position >= len(body) else 0, stream, piece))
            if position >= len(body):
                return

    def answer(self, stream, fields):
        headers = {}
        for name, value in fields:
            if name in headers:
                headers[name] += ", " + value if name != "cookie" else "; " + value
            else:
                headers[name] = value
        method, path = headers.get(":method", "GET"), headers.get(":path", "/")
        self.requests += 1
        response = Http2Response(self.requests)
        if path in self.plain_pages:
            self.plain_pages[path](response, headers)
        else:
            self.serve_request(response, method, path, headers)
        body = b"" if method == "HEAD" else response.body
        out_fields = [(":status", response.status)] + response.fields + [("content-length", len(response.body))]
        block = hpack_encode(out_fields)
        self.send(frame(HEADERS, END_HEADERS | (0 if body else END_STREAM), stream, block))
        if body:
            self.send_data(stream, body)

    def handle_frame(self, frame_type, flags, stream, payload):
        if frame_type in (HEADERS, CONTINUATION):
            if frame_type == HEADERS:
                start, end = 0, len(payload)
                if flags & PADDED:
                    start, end = 1, len(payload) - payload[0]
                if flags & PRIORITY_FLAG:
                    start += 5
                self.block, self.block_stream, self.block_end = payload[start:end], stream, bool(flags & END_STREAM)
            else:
                self.block += payload
            if flags & END_HEADERS:
                self.streams[self.block_stream] = self.decoder.decode(self.block)
                if self.block_end:
                    self.answer(self.block_stream, self.streams.pop(self.block_stream))
        elif frame_type == DATA:
            if payload:
                self.send(frame(WINDOW_UPDATE, 0, 0, len(payload).to_bytes(4, "big")))
            if flags & END_STREAM and stream in self.streams:
                self.answer(stream, self.streams.pop(stream))
        elif frame_type == RST_STREAM:
            self.streams.pop(stream, None)

    def serve(self):
        while len(self.pending) < len(PREFACE):
            more = self.stream.read()
            if not more:
                return
            self.pending += more
        if not self.pending.startswith(PREFACE):
            return
        self.pending = self.pending[len(PREFACE):]
        self.send(frame(SETTINGS, 0, 0, (3).to_bytes(2, "big") + (100).to_bytes(4, "big")))
        while not self.done:
            incoming = self.read_frame()
            if incoming is None:
                return
            if not self.handle_control(*incoming):
                self.handle_frame(*incoming)
