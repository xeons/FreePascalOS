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
  The errors of the TLS library: every routine that can fail returns
  TlsErrorNone or one of these (negative) codes, and TlsErrorMessage
  says what it means. The certificate errors come first in the list a
  program may want to treat specially (wget's --no-check-certificate).
  Each error also says which alert goes to the peer (RFC 8446 section
  6.2) when the library gives up because of it.
}
unit Tls.Errors;

{$mode objfpc}

interface

const
  TlsErrorNone = 0;
  TlsErrorTransportFailed = -1;
  TlsErrorTimedOut = -2;
  TlsErrorConnectionClosed = -3;
  TlsErrorMalformedMessage = -4;
  TlsErrorUnexpectedMessage = -5;
  TlsErrorBadRecordMac = -6;
  TlsErrorRecordOverflow = -7;
  TlsErrorHandshakeFailure = -8;
  TlsErrorProtocolVersion = -9;
  TlsErrorIllegalParameter = -10;
  TlsErrorUnsupportedExtension = -11;
  TlsErrorMissingExtension = -12;
  TlsErrorAlertReceived = -13;
  TlsErrorBadCertificateVerify = -14;
  TlsErrorBadFinished = -15;
  TlsErrorNoApplicationProtocol = -16;
  TlsErrorOutOfMemory = -17;
  TlsErrorInternal = -18;
  TlsErrorClosed = -19;
  TlsErrorNoTrustStore = -20;
  TlsErrorInvalidArgument = -21;

  { Certificates. }
  TlsErrorCertificateExpired = -40;
  TlsErrorCertificateNotYetValid = -41;
  TlsErrorCertificateUnknownIssuer = -42;
  TlsErrorCertificateNameMismatch = -43;
  TlsErrorCertificateBadSignature = -44;
  TlsErrorCertificateNotAuthority = -45;
  TlsErrorCertificateMalformed = -46;
  TlsErrorCertificateUnsupported = -47;
  TlsErrorCertificateChainTooLong = -48;
  TlsErrorCertificateUsage = -49;
  TlsErrorCertificateMissing = -50;

  { Alert descriptions (RFC 8446 section 6). }
  TlsAlertCloseNotify = 0;
  TlsAlertUnexpectedMessage = 10;
  TlsAlertBadRecordMac = 20;
  TlsAlertRecordOverflow = 22;
  TlsAlertHandshakeFailure = 40;
  TlsAlertBadCertificate = 42;
  TlsAlertUnsupportedCertificate = 43;
  TlsAlertCertificateRevoked = 44;
  TlsAlertCertificateExpired = 45;
  TlsAlertCertificateUnknown = 46;
  TlsAlertIllegalParameter = 47;
  TlsAlertUnknownCa = 48;
  TlsAlertAccessDenied = 49;
  TlsAlertDecodeError = 50;
  TlsAlertDecryptError = 51;
  TlsAlertProtocolVersion = 70;
  TlsAlertInsufficientSecurity = 71;
  TlsAlertInternalError = 80;
  TlsAlertInappropriateFallback = 86;
  TlsAlertUserCanceled = 90;
  TlsAlertMissingExtension = 109;
  TlsAlertUnsupportedExtension = 110;
  TlsAlertUnrecognizedName = 112;
  TlsAlertBadCertificateStatusResponse = 113;
  TlsAlertUnknownPskIdentity = 115;
  TlsAlertCertificateRequired = 116;
  TlsAlertNoApplicationProtocol = 120;

function TlsErrorMessage(Error: LongInt): PChar;
{ True for the TlsErrorCertificate* codes. }
function TlsErrorIsCertificateError(Error: LongInt): Boolean;
{ The alert to send to the peer for Error, or -1 for none (the
  connection is gone, or the peer sent the alert). }
function TlsAlertForError(Error: LongInt): LongInt;
{ "handshake failure", "unknown CA", ... }
function TlsAlertName(Description: LongInt): PChar;

implementation

function TlsErrorMessage(Error: LongInt): PChar;
begin
  case Error of
    TlsErrorNone: Result := 'success';
    TlsErrorTransportFailed: Result := 'the connection failed';
    TlsErrorTimedOut: Result := 'the connection timed out';
    TlsErrorConnectionClosed: Result := 'the server closed the connection during the handshake';
    TlsErrorMalformedMessage: Result := 'the server sent a malformed message';
    TlsErrorUnexpectedMessage: Result := 'the server sent an unexpected message';
    TlsErrorBadRecordMac: Result := 'a record failed authentication';
    TlsErrorRecordOverflow: Result := 'the server sent a record that is too long';
    TlsErrorHandshakeFailure: Result := 'no common cipher suite, key exchange group or signature algorithm';
    TlsErrorProtocolVersion: Result := 'the server does not support TLS 1.3';
    TlsErrorIllegalParameter: Result := 'the server sent an illegal parameter';
    TlsErrorUnsupportedExtension: Result := 'the server sent an extension that was not offered';
    TlsErrorMissingExtension: Result := 'the server left out a required extension';
    TlsErrorAlertReceived: Result := 'the server sent an alert';
    TlsErrorBadCertificateVerify: Result := 'the server''s handshake signature does not match its certificate';
    TlsErrorBadFinished: Result := 'the server''s Finished message does not match the handshake';
    TlsErrorNoApplicationProtocol: Result := 'the server chose an application protocol that was not offered';
    TlsErrorOutOfMemory: Result := 'out of memory';
    TlsErrorInternal: Result := 'internal error';
    TlsErrorClosed: Result := 'the connection is closed';
    TlsErrorNoTrustStore: Result := 'no trusted certificates could be read';
    TlsErrorInvalidArgument: Result := 'invalid argument';
    TlsErrorCertificateExpired: Result := 'the certificate has expired';
    TlsErrorCertificateNotYetValid: Result := 'the certificate is not yet valid';
    TlsErrorCertificateUnknownIssuer: Result := 'the certificate was issued by an unknown authority';
    TlsErrorCertificateNameMismatch: Result := 'the certificate is not valid for this host name';
    TlsErrorCertificateBadSignature: Result := 'a certificate''s signature does not match its issuer';
    TlsErrorCertificateNotAuthority: Result := 'a certificate in the chain is not allowed to issue certificates';
    TlsErrorCertificateMalformed: Result := 'a certificate is malformed';
    TlsErrorCertificateUnsupported: Result := 'a certificate uses an unsupported algorithm or critical extension';
    TlsErrorCertificateChainTooLong: Result := 'the certificate chain is too long';
    TlsErrorCertificateUsage: Result := 'a certificate is not meant for TLS servers';
    TlsErrorCertificateMissing: Result := 'the server sent no certificate';
  else
    Result := 'unknown error';
  end;
end;

function TlsErrorIsCertificateError(Error: LongInt): Boolean;
begin
  Result := (Error <= TlsErrorCertificateExpired) and (Error >= TlsErrorCertificateMissing);
end;

function TlsAlertForError(Error: LongInt): LongInt;
begin
  case Error of
    TlsErrorMalformedMessage, TlsErrorCertificateMissing: Result := TlsAlertDecodeError;
    TlsErrorUnexpectedMessage: Result := TlsAlertUnexpectedMessage;
    TlsErrorBadRecordMac: Result := TlsAlertBadRecordMac;
    TlsErrorRecordOverflow: Result := TlsAlertRecordOverflow;
    TlsErrorHandshakeFailure: Result := TlsAlertHandshakeFailure;
    TlsErrorProtocolVersion: Result := TlsAlertProtocolVersion;
    TlsErrorIllegalParameter: Result := TlsAlertIllegalParameter;
    TlsErrorUnsupportedExtension: Result := TlsAlertUnsupportedExtension;
    TlsErrorMissingExtension: Result := TlsAlertMissingExtension;
    TlsErrorBadCertificateVerify, TlsErrorBadFinished: Result := TlsAlertDecryptError;
    TlsErrorNoApplicationProtocol: Result := TlsAlertNoApplicationProtocol;
    TlsErrorOutOfMemory, TlsErrorInternal, TlsErrorNoTrustStore, TlsErrorInvalidArgument:
      Result := TlsAlertInternalError;
    TlsErrorCertificateExpired, TlsErrorCertificateNotYetValid: Result := TlsAlertCertificateExpired;
    TlsErrorCertificateUnknownIssuer: Result := TlsAlertUnknownCa;
    TlsErrorCertificateNameMismatch, TlsErrorCertificateNotAuthority, TlsErrorCertificateUsage,
    TlsErrorCertificateChainTooLong: Result := TlsAlertCertificateUnknown;
    TlsErrorCertificateBadSignature, TlsErrorCertificateMalformed: Result := TlsAlertBadCertificate;
    TlsErrorCertificateUnsupported: Result := TlsAlertUnsupportedCertificate;
  else
    Result := -1;
  end;
end;

function TlsAlertName(Description: LongInt): PChar;
begin
  case Description of
    TlsAlertCloseNotify: Result := 'close notify';
    TlsAlertUnexpectedMessage: Result := 'unexpected message';
    TlsAlertBadRecordMac: Result := 'bad record MAC';
    TlsAlertRecordOverflow: Result := 'record overflow';
    TlsAlertHandshakeFailure: Result := 'handshake failure';
    TlsAlertBadCertificate: Result := 'bad certificate';
    TlsAlertUnsupportedCertificate: Result := 'unsupported certificate';
    TlsAlertCertificateRevoked: Result := 'certificate revoked';
    TlsAlertCertificateExpired: Result := 'certificate expired';
    TlsAlertCertificateUnknown: Result := 'certificate unknown';
    TlsAlertIllegalParameter: Result := 'illegal parameter';
    TlsAlertUnknownCa: Result := 'unknown CA';
    TlsAlertAccessDenied: Result := 'access denied';
    TlsAlertDecodeError: Result := 'decode error';
    TlsAlertDecryptError: Result := 'decrypt error';
    TlsAlertProtocolVersion: Result := 'protocol version';
    TlsAlertInsufficientSecurity: Result := 'insufficient security';
    TlsAlertInternalError: Result := 'internal error';
    TlsAlertInappropriateFallback: Result := 'inappropriate fallback';
    TlsAlertUserCanceled: Result := 'user canceled';
    TlsAlertMissingExtension: Result := 'missing extension';
    TlsAlertUnsupportedExtension: Result := 'unsupported extension';
    TlsAlertUnrecognizedName: Result := 'unrecognized name';
    TlsAlertBadCertificateStatusResponse: Result := 'bad certificate status response';
    TlsAlertUnknownPskIdentity: Result := 'unknown PSK identity';
    TlsAlertCertificateRequired: Result := 'certificate required';
    TlsAlertNoApplicationProtocol: Result := 'no application protocol';
  else
    Result := 'unknown alert';
  end;
end;

end.
