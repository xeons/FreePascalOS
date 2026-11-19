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

"""Writes TlsTest.Rfc8448.inc (or TlsTest.Rfc8448Retry.inc) from the text of RFC 8448 ("Example
Handshake Traces for TLS 1.3"): the values of its section 3, "Simple
1-RTT Handshake", that TlsTest checks the key schedule, the transcript
hash, the record protection and the Finished messages against, of
section 5, "HelloRetryRequest", for the transcript after a retry, and
of sections 3 and 4 ("Resumed 0-RTT Handshake") for resumption: the
resumption secret and PSK of the first connection's ticket, the early
secret and PSK binder of the second ClientHello and the handshake
secrets that follow.

    curl -o rfc8448.txt https://www.rfc-editor.org/rfc/rfc8448.txt
    python3 tools/TlsTest/make-rfc8448-vectors.py rfc8448.txt > tools/TlsTest/TlsTest.Rfc8448.inc
    python3 tools/TlsTest/make-rfc8448-vectors.py rfc8448.txt retry > tools/TlsTest/TlsTest.Rfc8448Retry.inc
    python3 tools/TlsTest/make-rfc8448-vectors.py rfc8448.txt resumption > tools/TlsTest/TlsTest.Rfc8448Resumption.inc
"""

import re
import sys

# (Pascal name, context the value appears under, its label)
WANTED = [
    ("ClientPrivateKey", "client: create an ephemeral x25519 key pair:", "private key"),
    ("ClientHelloMessage", "client: construct a ClientHello handshake message:", "ClientHello"),
    ("ServerPublicKey", "server: create an ephemeral x25519 key pair:", "public key"),
    ("ServerHelloMessage", "server: construct a ServerHello handshake message:", "ServerHello"),
    ("SharedSecret", 'server: extract secret "handshake":', "IKM"),
    ("HandshakeSecret", 'server: extract secret "handshake":', "secret"),
    ("HelloHash", 'server: derive secret "tls13 c hs traffic":', "hash"),
    ("ClientHandshakeTraffic", 'server: derive secret "tls13 c hs traffic":', "expanded"),
    ("ServerHandshakeTraffic", 'server: derive secret "tls13 s hs traffic":', "expanded"),
    ("MasterSecret", 'server: extract secret "master":', "secret"),
    ("ServerHandshakeKey", "server: derive write traffic keys for handshake data:", "key expanded"),
    ("ServerHandshakeIv", "server: derive write traffic keys for handshake data:", "iv expanded"),
    ("EncryptedExtensionsMessage", "server: construct an EncryptedExtensions handshake message:",
     "EncryptedExtensions"),
    ("CertificateMessage", "server: construct a Certificate handshake message:", "Certificate"),
    ("CertificateVerifyMessage", "server: construct a CertificateVerify handshake message:", "CertificateVerify"),
    ("ServerFinishedData", 'server: calculate finished "tls13 finished":', "finished"),
    ("ServerFinishedMessage", "server: construct a Finished handshake message:", "Finished"),
    ("ServerHandshakeRecord", "server: send handshake record:", "complete record", 2),
    ("ClientApplicationTraffic", 'server: derive secret "tls13 c ap traffic":', "expanded"),
    ("ServerApplicationTraffic", 'server: derive secret "tls13 s ap traffic":', "expanded"),
    ("ClientFinishedData", 'client: calculate finished "tls13 finished":', "finished"),
    ("ClientFinishedMessage", "client: construct a Finished handshake message:", "Finished"),
    ("ClientFinishedRecord", "client: send handshake record:", "complete record", 2),
    ("NewSessionTicketMessage", "server: construct a NewSessionTicket handshake message:", "NewSessionTicket"),
    ("NewSessionTicketRecord", "server: send handshake record:", "complete record", 3),
    ("ClientApplicationData", "client: send application_data record:", "payload"),
    ("ClientApplicationRecord", "client: send application_data record:", "complete record"),
    ("ServerApplicationData", "server: send application_data record:", "payload"),
    ("ServerApplicationRecord", "server: send application_data record:", "complete record"),
    ("ClientAlertRecord", "client: send alert record:", "complete record"),
    ("ServerAlertRecord", "server: send alert record:", "complete record"),
]

# Section 5, "HelloRetryRequest": the transcript with message_hash.
RETRY_WANTED = [
    ("RetryClientHello1", "client: construct a ClientHello handshake message:", "ClientHello", 1),
    ("RetryRequestMessage", "server: construct a ServerHello handshake message:", "ServerHello", 1),
    ("RetryClientHello2", "client: construct a ClientHello handshake message:", "ClientHello", 2),
    ("RetryServerHello", "server: construct a ServerHello handshake message:", "ServerHello", 2),
    ("RetrySharedSecret", 'server: extract secret "handshake":', "IKM"),
    ("RetryHelloHash", 'server: derive secret "tls13 c hs traffic":', "hash"),
    ("RetryClientHandshakeTraffic", 'server: derive secret "tls13 c hs traffic":', "expanded"),
    ("RetryServerHandshakeTraffic", 'server: derive secret "tls13 s hs traffic":', "expanded"),
]

# Sections 3 and 4: resumption (the section each value comes from).
RESUMPTION_WANTED = [
    (3, "ResumptionHash", 'client: derive secret "tls13 res master":', "hash"),
    (3, "ResumptionMasterSecret", 'client: derive secret "tls13 res master":', "expanded"),
    (3, "ResumptionPsk", 'server: generate resumption secret "tls13 resumption":', "expanded"),
    (4, "ResumedEarlySecret", 'client: extract secret "early":', "secret"),
    (4, "ResumedClientHelloPrefix", "client: construct a ClientHello handshake message:", "ClientHello"),
    (4, "ResumedClientHello", "client: send handshake record:", "payload"),
    (4, "ResumedBinderHash", "client: calculate PSK binder:", "binder hash"),
    (4, "ResumedBinder", "client: calculate PSK binder:", "finished"),
    (4, "ResumedServerHello", "server: construct a ServerHello handshake message:", "ServerHello"),
    (4, "ResumedSharedSecret", 'server: extract secret "handshake":', "IKM"),
    (4, "ResumedHandshakeSecret", 'server: extract secret "handshake":', "secret"),
    (4, "ResumedHelloHash", 'server: derive secret "tls13 c hs traffic":', "hash"),
    (4, "ResumedClientHandshakeTraffic", 'server: derive secret "tls13 c hs traffic":', "expanded"),
    (4, "ResumedServerHandshakeTraffic", 'server: derive secret "tls13 s hs traffic":', "expanded"),
]

SECTION_HEADINGS = {
    3: ("3.  Simple 1-RTT Handshake", "4.  Resumed 0-RTT Handshake"),
    4: ("4.  Resumed 0-RTT Handshake", "5.  HelloRetryRequest"),
}


def read_entries(path, first_heading, next_heading):
    text = open(path).read().split("\n")
    start = next(i for i, line in enumerate(text) if line.startswith(first_heading))
    end = next(i for i, line in enumerate(text) if line.startswith(next_heading))
    lines = [line for line in text[start:end]
             if not line.startswith("RFC 8448") and not line.startswith("Thomson") and "\x0c" not in line]
    hex_line = re.compile(r"^         [0-9a-f]{2}( [0-9a-f]{2})*\s*$")
    entries = []
    context = ""
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^   \{(client|server)\}\s+(.*)$", line)
        if match:
            context = match.group(1) + ": " + match.group(2).strip()
            follow = index + 1
            while follow < len(lines) and lines[follow].strip() and not lines[follow].startswith("      "):
                context += " " + lines[follow].strip()
                follow += 1
        match = re.match(r"^      ([A-Za-z_ \-]+) \((\d+) octets\):\s*(.*)$", line)
        if match and re.match(r"^([0-9a-f]{2}( |$))+$", match.group(3).strip() + " "):
            label, count, digits = match.group(1), int(match.group(2)), match.group(3)
            follow = index + 1
            while len(bytes.fromhex(digits.replace(" ", ""))) < count:
                skip = follow
                while skip < len(lines) and not lines[skip].strip():
                    skip += 1
                if skip >= len(lines) or not hex_line.match(lines[skip]):
                    break
                digits += " " + lines[skip].strip()
                follow = skip + 1
            data = bytes.fromhex(digits.replace(" ", ""))
            if len(data) != count:
                raise SystemExit(f"{label}: expected {count} octets, read {len(data)}")
            entries.append((context, label, data))
            index = follow
            continue
        index += 1
    return entries


def find(entries, context, label, occurrence=1):
    seen = 0
    for entry_context, entry_label, data in entries:
        if entry_context == context and entry_label == label:
            seen += 1
            if seen == occurrence:
                return data
    raise SystemExit(f"not found: {context} {label}")


def pascal_constant(name, data):
    text = data.hex()
    lines = [text[i:i + 96] for i in range(0, len(text), 96)]
    body = " +\n    ".join("'" + line + "'" for line in lines)
    return f"  {name}: PChar =\n    {body};\n"


def main_resumption():
    print("{ Made by tools/TlsTest/make-rfc8448-vectors.py from RFC 8448 sections 3 and 4. }")
    print("const")
    sections = {number: read_entries(sys.argv[1], *headings) for number, headings in SECTION_HEADINGS.items()}
    for section, name, context, label in RESUMPTION_WANTED:
        print(pascal_constant(name, find(sections[section], context, label)), end="")


def main():
    if len(sys.argv) > 2 and sys.argv[2] == "resumption":
        main_resumption()
        return
    if len(sys.argv) > 2 and sys.argv[2] == "retry":
        wanted_list, section = RETRY_WANTED, 5
        first_heading, next_heading = "5.  HelloRetryRequest", "6.  Client Authentication"
    else:
        wanted_list, section = WANTED, 3
        first_heading, next_heading = "3.  Simple 1-RTT Handshake", "4.  Resumed 0-RTT Handshake"
    print(f"{{ Made by tools/TlsTest/make-rfc8448-vectors.py from RFC 8448 section {section}. }}")
    print("const")
    entries = read_entries(sys.argv[1], first_heading, next_heading)
    for wanted in wanted_list:
        name, context, label = wanted[0], wanted[1], wanted[2]
        occurrence = wanted[3] if len(wanted) > 3 else 1
        print(pascal_constant(name, find(entries, context, label, occurrence)), end="")


if __name__ == "__main__":
    main()
