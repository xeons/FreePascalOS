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
  The QUIC mode of the client handshake (RFC 9001 section 4): with
  TTlsClientOptions.Quic set, the TLS 1.3 handshake runs without the
  record layer. Handshake messages go to the QUIC connection with the
  encryption level they belong to (SendHandshake) and come from it the
  same way (ReceiveHandshake, which waits for CRYPTO data of that
  level); each traffic secret is handed over when the handshake makes
  it (InstallSecret), for QUIC to derive its packet protection keys
  from. No alert is ever sent: the alert a failure stands for is
  TlsQuicAlert's (QUIC sends it as CRYPTO_ERROR 0x100 + alert).

  In this mode the ClientHello offers TLS 1.3 only, with an empty
  legacy_session_id (no middlebox compatibility mode, RFC 9001 section
  8.4), the quic_transport_parameters extension (0x39) with
  TransportParameters, and no session resumption; no
  change_cipher_spec is sent. The server must choose an ALPN protocol
  (section 8.1) and send its transport parameters in
  EncryptedExtensions (section 8.2). Messages after the handshake
  (NewSessionTicket in 1-RTT CRYPTO frames) are QUIC's to drop.
}
unit Tls.Quic;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  ExtensionQuicTransportParameters = $39;

type
  { The encryption levels, in QUIC's order (EarlyData is never used:
    no 0-RTT). }
  TTlsQuicLevel = (QuicLevelInitial, QuicLevelEarlyData, QuicLevelHandshake, QuicLevelApplication);
  TTlsQuicDirection = (QuicDirectionRead, QuicDirectionWrite);

  { Takes handshake bytes to send at Level: TlsErrorNone or an error. }
  TTlsQuicSendHandshake = function(Context: Pointer; Level: TTlsQuicLevel; Data: PByte; Length: PtrUInt): LongInt;
  { Waits for handshake bytes of Level and returns how many it put in
    Buffer (at most Length, at least 1), or an error (TlsErrorTimedOut,
    TlsErrorConnectionClosed ...). }
  TTlsQuicReceiveHandshake = function(Context: Pointer; Level: TTlsQuicLevel; Buffer: PByte;
    Length: PtrUInt): Int64;
  { A traffic secret for Level and Direction, made with CipherSuite
    (the secret is as long as the suite's hash): TlsErrorNone or an
    error. }
  TTlsQuicInstallSecret = function(Context: Pointer; Level: TTlsQuicLevel; Direction: TTlsQuicDirection;
    CipherSuite: Word; Secret: PByte; SecretLength: Integer): LongInt;

  TTlsQuicCallbacks = record
    Context: Pointer;
    SendHandshake: TTlsQuicSendHandshake;
    ReceiveHandshake: TTlsQuicReceiveHandshake;
    InstallSecret: TTlsQuicInstallSecret;
    { The client's transport parameters, encoded (RFC 9000 section 18). }
    TransportParameters: TBytes;
  end;
  PTlsQuicCallbacks = ^TTlsQuicCallbacks;

implementation

end.
