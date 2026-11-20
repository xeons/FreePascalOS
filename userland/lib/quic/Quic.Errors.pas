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
  The errors of libquic: routines return QuicErrorNone or one of these
  negative codes. A connection that fails keeps the reason (the
  transport error code and text it sent or received, the TLS error) for
  a fuller description (TQuicConnection.ErrorDescription).
}
unit Quic.Errors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  QuicErrorNone = 0;
  { Nothing came from the peer for the idle timeout. }
  QuicErrorIdleTimeout = -1;
  { The socket failed. }
  QuicErrorTransportFailed = -2;
  { The peer closed the connection (CONNECTION_CLOSE). }
  QuicErrorClosedByPeer = -3;
  { The peer broke the protocol; this side closed the connection. }
  QuicErrorProtocolViolation = -4;
  { The TLS handshake failed. }
  QuicErrorHandshakeFailed = -5;
  { The server speaks no version this side does. }
  QuicErrorVersionNegotiation = -6;
  { The peer sent a stateless reset: it has lost the connection. }
  QuicErrorStatelessReset = -7;
  { The peer allows no more streams of that kind now. }
  QuicErrorStreamLimit = -8;
  { The peer reset the stream (RESET_STREAM): no more data comes. }
  QuicErrorStreamReset = -9;
  { The peer asked this side to stop sending (STOP_SENDING). }
  QuicErrorStreamStopped = -10;
  { No such stream, or not one that may be read or written here. }
  QuicErrorInvalidStream = -11;
  { The connection was closed by this side. }
  QuicErrorClosed = -12;
  QuicErrorInvalidArgument = -13;
  { The wait asked for ended first. }
  QuicErrorTimedOut = -14;
  { The host name could not be resolved. }
  QuicErrorHostNotFound = -15;
  QuicErrorOutOfMemory = -16;
  QuicErrorInternal = -17;
  { The handshake did not finish in time. }
  QuicErrorHandshakeTimedOut = -18;

type
  EQuicError = class(Exception)
  private
    FCode: LongInt;
  public
    constructor CreateCode(Code: LongInt; const Text: string);
    property Code: LongInt read FCode;
  end;

function QuicErrorMessage(Error: LongInt): string;
{ "PROTOCOL_VIOLATION", "CRYPTO_ERROR (handshake failure)" ... }
function TransportErrorName(Code: QWord): string;

implementation

uses
  Quic.Constants,
  Tls.Errors;

constructor EQuicError.CreateCode(Code: LongInt; const Text: string);
begin
  inherited Create(Text);
  FCode := Code;
end;

function QuicErrorMessage(Error: LongInt): string;
begin
  case Error of
    QuicErrorNone: Result := 'success';
    QuicErrorIdleTimeout: Result := 'the connection timed out (nothing came from the peer)';
    QuicErrorTransportFailed: Result := 'the network failed';
    QuicErrorClosedByPeer: Result := 'the peer closed the connection';
    QuicErrorProtocolViolation: Result := 'the peer broke the QUIC protocol';
    QuicErrorHandshakeFailed: Result := 'the TLS handshake failed';
    QuicErrorVersionNegotiation: Result := 'the server does not speak QUIC version 1';
    QuicErrorStatelessReset: Result := 'the peer reset the connection';
    QuicErrorStreamLimit: Result := 'the peer allows no more streams';
    QuicErrorStreamReset: Result := 'the peer reset the stream';
    QuicErrorStreamStopped: Result := 'the peer stopped reading the stream';
    QuicErrorInvalidStream: Result := 'no such stream';
    QuicErrorClosed: Result := 'the connection is closed';
    QuicErrorInvalidArgument: Result := 'invalid argument';
    QuicErrorTimedOut: Result := 'timed out';
    QuicErrorHostNotFound: Result := 'the host was not found';
    QuicErrorOutOfMemory: Result := 'out of memory';
    QuicErrorInternal: Result := 'internal error';
    QuicErrorHandshakeTimedOut: Result := 'the handshake timed out';
  else
    Result := 'unknown error';
  end;
end;

function TransportErrorName(Code: QWord): string;
begin
  if (Code >= TransportCryptoError) and (Code <= TransportCryptoError + $FF) then
    Exit('CRYPTO_ERROR (' + TlsAlertName(LongInt(Code - TransportCryptoError)) + ')');
  case Code of
    TransportNoError: Result := 'NO_ERROR';
    TransportInternalError: Result := 'INTERNAL_ERROR';
    TransportConnectionRefused: Result := 'CONNECTION_REFUSED';
    TransportFlowControlError: Result := 'FLOW_CONTROL_ERROR';
    TransportStreamLimitError: Result := 'STREAM_LIMIT_ERROR';
    TransportStreamStateError: Result := 'STREAM_STATE_ERROR';
    TransportFinalSizeError: Result := 'FINAL_SIZE_ERROR';
    TransportFrameEncodingError: Result := 'FRAME_ENCODING_ERROR';
    TransportParameterError: Result := 'TRANSPORT_PARAMETER_ERROR';
    TransportConnectionIdLimitError: Result := 'CONNECTION_ID_LIMIT_ERROR';
    TransportProtocolViolation: Result := 'PROTOCOL_VIOLATION';
    TransportInvalidToken: Result := 'INVALID_TOKEN';
    TransportApplicationError: Result := 'APPLICATION_ERROR';
    TransportCryptoBufferExceeded: Result := 'CRYPTO_BUFFER_EXCEEDED';
    TransportKeyUpdateError: Result := 'KEY_UPDATE_ERROR';
    TransportAeadLimitReached: Result := 'AEAD_LIMIT_REACHED';
    TransportNoViablePath: Result := 'NO_VIABLE_PATH';
  else
    Result := '0x' + IntToHex(Code, 1);
  end;
end;

end.
