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

"""Fetching and checking sources: each distfile is downloaded once into
the distfile cache (DISTDIR, ~/Downloads/sources by default), from its
URL or, failing that, its mirrors, and is only used once its SHA-256
(and size, when given) match port.toml. A signature, when the port asks
for one, is checked too: gpg against a keyring kept in the port's folder,
or Ed25519 against a public key file there."""

import hashlib
import os
import shutil
import subprocess
import tempfile
import urllib.request

from . import ed25519, paths
from .portfile import PortError

USER_AGENT = "FreePascalOS-ports/1"


class FetchError(PortError):
    pass


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, target):
    """Downloads url into target through a temporary file."""
    directory = os.path.dirname(target)
    os.makedirs(directory, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".fetch-")
    try:
        with os.fdopen(handle, "wb") as output, urllib.request.urlopen(request, timeout=60) as response:
            shutil.copyfileobj(response, output, 1 << 20)
        os.replace(temporary, target)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def distfile_path(source):
    return os.path.join(paths.distfile_directory(), source.filename)


def check_distfile(source, path):
    """The problem with a downloaded file, or None when it is right."""
    if source.size >= 0 and os.path.getsize(path) != source.size:
        return f"{source.filename}: size {os.path.getsize(path)}, port.toml says {source.size}"
    actual = sha256_of(path)
    if actual != source.sha256:
        return f"{source.filename}: SHA-256 {actual}, port.toml says {source.sha256}"
    return None


def fetch_source(source, log=None, offline=False):
    """The distfile's path once it is in the cache and checks; downloads
    it (trying each URL) when it is missing or wrong."""
    path = distfile_path(source)
    if os.path.exists(path) and check_distfile(source, path) is None:
        return path
    if offline:
        raise FetchError(f"{source.filename} is not in {paths.distfile_directory()} (offline)")
    failures = []
    for url in source.urls:
        if log:
            log.note(f"fetching {url}")
        try:
            download(url, path)
        except Exception as error:  # network errors of every kind
            failures.append(f"{url}: {error}")
            continue
        problem = check_distfile(source, path)
        if problem is None:
            return path
        failures.append(f"{url}: {problem}")
        os.unlink(path)
    raise FetchError(f"cannot fetch {source.filename}:\n  " + "\n  ".join(failures))


def verify_signature(port, source, path, log=None, offline=False):
    """Checks the source's detached signature; does nothing without one."""
    signature = source.signature
    if signature is None:
        return
    signature_name = os.path.basename(signature.url.split("?", 1)[0].rstrip("/"))
    signature_path = os.path.join(os.path.dirname(path), signature_name)
    if not os.path.exists(signature_path):
        if offline:
            raise FetchError(f"{os.path.basename(signature_path)} is not in the distfile cache (offline)")
        download(signature.url, signature_path)
    key_path = os.path.join(port.directory, signature.key)
    if signature.type == "gpg":
        verify_gpg(path, signature_path, key_path, log)
    else:
        verify_ed25519(path, signature_path, key_path)
    if log:
        log.note(f"{source.filename}: {signature.type} signature good")


def verify_gpg(path, signature_path, keyring, log=None):
    if shutil.which("gpgv") is None:
        raise FetchError("gpgv is needed to check signatures and is not installed")
    result = subprocess.run(
        ["gpgv", "--keyring", os.path.abspath(keyring), signature_path, path],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        log.note(result.stdout)
    if result.returncode != 0:
        raise FetchError(f"{os.path.basename(path)}: bad gpg signature\n{result.stdout}")


def verify_ed25519(path, signature_path, key_path):
    """The signature file holds the 64 signature bytes in hex; the key
    file "ed25519 HEX" (a public key as pkg's key files are)."""
    public_key = ed25519.read_public_key(key_path)
    with open(signature_path, encoding="ascii") as stream:
        signature = bytes.fromhex(stream.read().split()[-1])
    with open(path, "rb") as stream:
        message = stream.read()
    if not ed25519.verify(public_key, message, signature):
        raise FetchError(f"{os.path.basename(path)}: bad Ed25519 signature")


def fetch_port(port, log=None, offline=False):
    """Every distfile of the port, fetched and checked: their paths."""
    found = []
    for source in port.sources:
        path = fetch_source(source, log, offline)
        verify_signature(port, source, path, log, offline)
        found.append(path)
    return found
