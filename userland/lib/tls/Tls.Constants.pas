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
  The numbers of the TLS 1.3 protocol (RFC 8446) and of TLS 1.2 (RFC
  5246) where it differs: record content types, handshake message
  types, extensions, versions, groups and the limits on records.
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

  { Handshake message types (HelloRequest, ServerKeyExchange,
    ServerHelloDone, ClientKeyExchange and CertificateStatus are TLS
    1.2's). }
  HandshakeHelloRequest = 0;
  HandshakeClientHello = 1;
  HandshakeServerHello = 2;
  HandshakeNewSessionTicket = 4;
  HandshakeEndOfEarlyData = 5;
  HandshakeEncryptedExtensions = 8;
  HandshakeCertificate = 11;
  HandshakeServerKeyExchange = 12;
  HandshakeCertificateRequest = 13;
  HandshakeServerHelloDone = 14;
  HandshakeCertificateVerify = 15;
  HandshakeClientKeyExchange = 16;
  HandshakeFinished = 20;
  HandshakeCertificateStatus = 22;
  HandshakeKeyUpdate = 24;
  { The stand-in for the first ClientHello after a HelloRetryRequest. }
  HandshakeMessageHash = 254;

  { Extensions. }
  ExtensionServerName = 0;
  ExtensionStatusRequest = 5;
  ExtensionSupportedGroups = 10;
  ExtensionEcPointFormats = 11;
  ExtensionSignatureAlgorithms = 13;
  ExtensionApplicationLayerProtocol = 16;
  ExtensionExtendedMasterSecret = 23;
  ExtensionSessionTicket = 35;
  ExtensionPreSharedKey = 41;
  ExtensionEarlyData = 42;
  ExtensionSupportedVersions = 43;
  ExtensionCookie = 44;
  ExtensionPskKeyExchangeModes = 45;
  ExtensionKeyShare = 51;
  ExtensionRenegotiationInfo = $FF01;

  { status_request's type: an OCSP response. }
  CertificateStatusOcsp = 1;
  { psk_key_exchange_modes: a PSK with (EC)DHE. }
  PskModeDheKeyExchange = 1;

  { Versions. }
  VersionTls12 = $0303;
  VersionTls13 = $0304;
  { The record version of the first ClientHello, which older servers
    expect. }
  VersionTls10 = $0301;

  { Named groups. X25519MLKEM768 is the hybrid of ML-KEM-768 and X25519
    (draft-ietf-tls-ecdhe-mlkem). }
  GroupSecp256r1 = $0017;
  GroupSecp384r1 = $0018;
  GroupSecp521r1 = $0019;
  GroupX25519 = $001D;
  GroupX25519MlKem768 = $11EC;

  { TLS 1.2's ECParameters curve_type for a named curve, and the
    uncompressed point format. }
  CurveTypeNamedCurve = 3;
  PointFormatUncompressed = 0;

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

  { The last 8 bytes of a TLS 1.3 server's random when it answers with
    TLS 1.2 (RFC 8446 section 4.1.3): a downgrade. }
  DowngradeToTls12Sentinel: array[0..7] of Byte = ($44, $4F, $57, $4E, $47, $52, $44, $01);
  DowngradeToTls11Sentinel: array[0..7] of Byte = ($44, $4F, $57, $4E, $47, $52, $44, $00);

  { Handshake messages of TLS 1.2: the Finished verify data is 12 bytes. }
  Tls12VerifyDataLength = 12;

implementation

end.
