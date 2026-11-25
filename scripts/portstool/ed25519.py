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

"""Ed25519 (RFC 8032), for signing repository indexes on the build
machine and checking signed sources. Plain Python after the RFC's
reference code: slow (milliseconds a signature) but needing nothing the
build machine may lack. The system checks the same signatures with
libcryptography's Crypto.Ed25519.

Key files are one line of text:
    public:  "ed25519 HEX"         (32 bytes; /etc/pkg/keys/NAME.pub)
    secret:  "ed25519-secret HEX"  (the 32-byte seed; keep it private)
"""

import hashlib
import os

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _sha512(data):
    return hashlib.sha512(data).digest()


def _add(first, second):
    x1, y1, z1, t1 = first
    x2, y2, z2, t2 = second
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = 2 * t1 * t2 * _D % _P
    d = 2 * z1 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _multiply(scalar, point):
    result = (0, 1, 1, 0)
    while scalar > 0:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _equal(first, second):
    x1, y1, z1, _ = first
    x2, y2, z2, _ = second
    return (x1 * z2 - x2 * z1) % _P == 0 and (y1 * z2 - y2 * z1) % _P == 0


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * pow(5, _P - 2, _P) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _compress(point):
    x, y, z, _ = point
    inverse = pow(z, _P - 2, _P)
    x = x * inverse % _P
    y = y * inverse % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(data):
    if len(data) != 32:
        return None
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


def _expand(seed):
    if len(seed) != 32:
        raise ValueError("an Ed25519 seed is 32 bytes")
    digest = _sha512(seed)
    scalar = int.from_bytes(digest[:32], "little")
    scalar &= (1 << 254) - 8
    scalar |= 1 << 254
    return scalar, digest[32:]


def public_key(seed):
    scalar, _ = _expand(seed)
    return _compress(_multiply(scalar, _G))


def sign(seed, message):
    scalar, prefix = _expand(seed)
    public = _compress(_multiply(scalar, _G))
    r = int.from_bytes(_sha512(prefix + message), "little") % _L
    big_r = _compress(_multiply(r, _G))
    h = int.from_bytes(_sha512(big_r + public + message), "little") % _L
    s = (r + h * scalar) % _L
    return big_r + int.to_bytes(s, 32, "little")


def verify(public, message, signature):
    if len(public) != 32 or len(signature) != 64:
        return False
    point_a = _decompress(public)
    point_r = _decompress(signature[:32])
    if point_a is None or point_r is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    h = int.from_bytes(_sha512(signature[:32] + public + message), "little") % _L
    return _equal(_multiply(s, _G), _add(point_r, _multiply(h, point_a)))


def generate_seed():
    return os.urandom(32)


def write_key_pair(secret_path, public_path, seed=None):
    seed = seed or generate_seed()
    old_mask = os.umask(0o077)
    try:
        with open(secret_path, "w", encoding="ascii") as stream:
            stream.write(f"ed25519-secret {seed.hex()}\n")
    finally:
        os.umask(old_mask)
    with open(public_path, "w", encoding="ascii") as stream:
        stream.write(f"ed25519 {public_key(seed).hex()}\n")
    return seed


def _read_key(path, kind):
    with open(path, encoding="ascii") as stream:
        words = stream.read().split()
    if len(words) != 2 or words[0] != kind:
        raise ValueError(f"{path}: not an {kind} key file")
    value = bytes.fromhex(words[1])
    if len(value) != 32:
        raise ValueError(f"{path}: the key is not 32 bytes")
    return value


def read_public_key(path):
    return _read_key(path, "ed25519")


def read_secret_seed(path):
    return _read_key(path, "ed25519-secret")
