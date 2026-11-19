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
  Reading the handshake messages a TLS 1.2 server sends after its
  ServerHello (RFC 5246 section 7.4, RFC 8422 section 5.4): Certificate
  (a plain list), CertificateStatus (RFC 6066), ServerKeyExchange for
  ECDHE over a named curve, CertificateRequest and ServerHelloDone.
  Each takes the message body (after the 4-byte header).
}
unit Tls.ServerMessages12;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.ByteBuffers,
  Tls.ServerMessages;

type
  TServerKeyExchange = record
    Group: Word;
    PublicKey: TTlsByteRange;
    { The ServerECDHParams as sent: what the signature covers after the
      two randoms. }
    Parameters: TTlsByteRange;
    Scheme: Word;
    Signature: TTlsByteRange;
  end;

function ParseTls12CertificateMessage(Body: PByte; Length: PtrUInt; out Certificates: TServerCertificates): LongInt;
function ParseCertificateStatus(Body: PByte; Length: PtrUInt; out Response: TTlsByteRange): LongInt;
function ParseServerKeyExchange(Body: PByte; Length: PtrUInt; out Exchange: TServerKeyExchange): LongInt;
function ParseTls12CertificateRequest(Body: PByte; Length: PtrUInt): LongInt;
function ParseServerHelloDone(Length: PtrUInt): LongInt;

implementation

uses
  Tls.Constants,
  Tls.Errors;

function ParseTls12CertificateMessage(Body: PByte; Length: PtrUInt; out Certificates: TServerCertificates): LongInt;
var
  Reader, List: TTlsReader;
  Entry: TTlsByteRange;
begin
  Certificates := Default(TServerCertificates);
  InitializeReader(Reader, Body, Length);
  if not ReadVector(Reader, 3, List) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  while not ReaderAtEnd(List) do
  begin
    if not ReadVectorBytes(List, 3, Entry) or (Entry.Length = 0) then
      Exit(TlsErrorMalformedMessage);
    if Certificates.Count >= MaximumServerCertificates then
      Exit(TlsErrorCertificateChainTooLong);
    Insert(Entry, Certificates.Entries, Certificates.Count);
    Inc(Certificates.Count);
  end;
  if Certificates.Count = 0 then
    Exit(TlsErrorCertificateMissing);
  Result := TlsErrorNone;
end;

function ParseCertificateStatus(Body: PByte; Length: PtrUInt; out Response: TTlsByteRange): LongInt;
var
  Reader: TTlsReader;
begin
  InitializeReader(Reader, Body, Length);
  Result := ParseCertificateStatusBody(Reader, Response);
end;

(* ServerKeyExchange for ECDHE:
     ServerECDHParams { ECParameters { curve_type = named_curve (3),
       NamedCurve }, ECPoint public<1..255> }
     DigitallySigned { SignatureAndHashAlgorithm, opaque signature<0..2^16-1> } *)
function ParseServerKeyExchange(Body: PByte; Length: PtrUInt; out Exchange: TServerKeyExchange): LongInt;
var
  Reader: TTlsReader;
  CurveType: Byte;
  ParametersStart: PByte;
begin
  Exchange := Default(TServerKeyExchange);
  InitializeReader(Reader, Body, Length);
  ParametersStart := Body;
  if not ReadUInt8(Reader, CurveType) then
    Exit(TlsErrorMalformedMessage);
  { Explicit curves are not supported (and RFC 8422 forbids them). }
  if CurveType <> CurveTypeNamedCurve then
    Exit(TlsErrorIllegalParameter);
  if not ReadUInt16(Reader, Exchange.Group) or not ReadVectorBytes(Reader, 1, Exchange.PublicKey) or
     (Exchange.PublicKey.Length = 0) then
    Exit(TlsErrorMalformedMessage);
  Exchange.Parameters := ByteRange(ParametersStart, 3 + 1 + Exchange.PublicKey.Length);
  if not ReadUInt16(Reader, Exchange.Scheme) or not ReadVectorBytes(Reader, 2, Exchange.Signature) or
     (Exchange.Signature.Length = 0) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  Result := TlsErrorNone;
end;

(* CertificateRequest: certificate_types<1..2^8-1>,
   supported_signature_algorithms<2..2^16-2>, certificate_authorities<0..2^16-1>.
   Only checked: this client answers with no certificate. *)
function ParseTls12CertificateRequest(Body: PByte; Length: PtrUInt): LongInt;
var
  Reader, Types, Algorithms, Authorities: TTlsReader;
begin
  InitializeReader(Reader, Body, Length);
  if not ReadVector(Reader, 1, Types) or ReaderAtEnd(Types) or not ReadVector(Reader, 2, Algorithms) or
     (ReaderRemaining(Algorithms) < 2) or ((ReaderRemaining(Algorithms) and 1) <> 0) or
     not ReadVector(Reader, 2, Authorities) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  Result := TlsErrorNone;
end;

function ParseServerHelloDone(Length: PtrUInt): LongInt;
begin
  if Length <> 0 then
    Exit(TlsErrorMalformedMessage);
  Result := TlsErrorNone;
end;

end.
