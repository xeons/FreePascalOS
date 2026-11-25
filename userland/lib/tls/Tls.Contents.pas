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
  The contents of libtls.so: a TLS 1.3 and TLS 1.2 client with X.509
  certificate checking (name constraints, OCSP stapling) and session
  resumption. Compiling this unit compiles all of them.

  Everything but Tls.SocketTransport, Tls.SystemTrust and Tls.Sessions
  is plain Pascal over a transport and builds on the host too (make
  tls-test).
}
unit Tls.Contents;

{$mode objfpc}

interface

uses
  Tls.Errors,
  Tls.Constants,
  Tls.ByteBuffers,
  Tls.Asn1,
  Tls.ObjectIdentifiers,
  Tls.Pem,
  Tls.Certificates,
  Tls.CertificateSummaries,
  Tls.CertificateExtensions,
  Tls.NameConstraints,
  Tls.HostNames,
  Tls.Signatures,
  Tls.TrustStore,
  Tls.CertificateChains,
  Tls.Ocsp,
  Tls.CipherSuites,
  Tls.KeyShares,
  Tls.KeySchedule,
  Tls.KeySchedule12,
  Tls.SessionCache,
  Tls.Transcript,
  Tls.RecordProtection,
  Tls.Transport,
  Tls.Quic,
  Tls.ClientHello,
  Tls.ServerMessages,
  Tls.ServerMessages12,
  Tls.Connections,
  Tls.RecordLayer,
  Tls.HandshakeMessages,
  Tls.ServerAuthentication,
  Tls.Handshake12,
  Tls.Handshake,
  Tls.Client,
  Tls.ClientConnections,
  Tls.SocketTransport,
  Tls.SystemTrust,
  Tls.Sessions;

implementation

end.
