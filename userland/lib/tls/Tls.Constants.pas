{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The numbers of the TLS 1.3 protocol (RFC 8446): record content types,
  handshake message types, extensions, versions, groups and the limits
  on records.
}
unit Tls.Constants;

{$mode objfpc}

interface

const
  { Record content types. }
  ContentChangeCipherSpec = 20;
  ContentAlert = 21;
  ContentHandshake = 22;
  ContentApplicationData = 23;

  { Handshake message types. }
  HandshakeClientHello = 1;
  HandshakeServerHello = 2;
  HandshakeNewSessionTicket = 4;
  HandshakeEndOfEarlyData = 5;
  HandshakeEncryptedExtensions = 8;
  HandshakeCertificate = 11;
  HandshakeCertificateRequest = 13;
  HandshakeCertificateVerify = 15;
  HandshakeFinished = 20;
  HandshakeKeyUpdate = 24;
  { The stand-in for the first ClientHello after a HelloRetryRequest. }
  HandshakeMessageHash = 254;

  { Extensions. }
  ExtensionServerName = 0;
  ExtensionSupportedGroups = 10;
  ExtensionSignatureAlgorithms = 13;
  ExtensionApplicationLayerProtocol = 16;
  ExtensionPreSharedKey = 41;
  ExtensionSupportedVersions = 43;
  ExtensionCookie = 44;
  ExtensionKeyShare = 51;

  { Versions. }
  VersionTls12 = $0303;
  VersionTls13 = $0304;
  { The record version of the first ClientHello, which older servers
    expect. }
  VersionTls10 = $0301;

  { Named groups. }
  GroupX25519 = $001D;

  { Records: a plaintext fragment is at most 2^14 bytes, a protected
    record 2^14 + 256. }
  MaximumPlaintextLength = 16384;
  MaximumCiphertextLength = 16384 + 256;
  RecordHeaderLength = 5;

  { Handshake messages longer than this are refused (certificate chains
    are the longest). }
  MaximumHandshakeMessageLength = 256 * 1024;

  { The random of a HelloRetryRequest: SHA-256 of
    "HelloRetryRequest". }
  HelloRetryRequestRandom: array[0..31] of Byte = (
    $CF, $21, $AD, $74, $E5, $9A, $61, $11, $BE, $1D, $8C, $02, $1E, $65, $B8, $91,
    $C2, $A2, $11, $16, $7A, $BB, $8C, $5E, $07, $9E, $09, $E2, $C8, $A8, $33, $9C);

implementation

end.
