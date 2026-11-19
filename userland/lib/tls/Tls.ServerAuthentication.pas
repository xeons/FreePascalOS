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
  What both handshakes do with the server's certificates: parse them,
  check the chain (Tls.CertificateChains) against the connection's
  roots, time and host name, then check the revocation status:

  - an OCSP response the server stapled is checked (Tls.Ocsp) against
    the certificate and the issuer the path went through: revoked or
    invalid fails the connection;
  - with no staple the connection goes on (soft fail), unless the
    certificate demands one (must staple, RFC 7633);
  - "unknown" is accepted, except for a must-staple certificate.

  With VerifyCertificates off the first error is kept as the ignored
  one (TlsIgnoredCertificateError) and the connection goes on.
}
unit Tls.ServerAuthentication;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.ByteBuffers,
  Tls.Connections,
  Tls.ServerMessages;

{ Parses the entries into Connection^.ServerCertificates and checks the
  chain (and the host name). }
function AcceptServerCertificates(Connection: PTlsConnection; constref Entries: TServerCertificates): LongInt;
{ After AcceptServerCertificates: the stapled response (empty: none). }
function CheckRevocationStatus(Connection: PTlsConnection; constref Staple: TTlsByteRange): LongInt;

implementation

uses
  Tls.Certificates,
  Tls.CertificateChains,
  Tls.Errors,
  Tls.Ocsp;

procedure DescribeCertificate(Connection: PTlsConnection; Certificate: PTlsCertificate; UseIssuer: Boolean);
begin
  if Certificate = nil then
    Exit;
  if UseIssuer then
    SetErrorDetail(Connection, 'issuer: ' + CommonNameText(Certificate^.IssuerCommonName))
  else
    SetErrorDetail(Connection, 'certificate: ' + CommonNameText(Certificate^.SubjectCommonName));
end;

{ A certificate error: fatal, or kept as ignored when certificates are
  not verified. }
function CertificateFailure(Connection: PTlsConnection; Error: LongInt): LongInt;
begin
  if not Connection^.Options.VerifyCertificates then
  begin
    if Connection^.IgnoredCertificateError = TlsErrorNone then
      Connection^.IgnoredCertificateError := Error;
    Exit(TlsErrorNone);
  end;
  Result := Error;
end;

function AcceptServerCertificates(Connection: PTlsConnection; constref Entries: TServerCertificates): LongInt;
var
  Index: Integer;
  Certificate: PTlsCertificate;
  Check: TChainCheck;
  Outcome: TChainResult;
begin
  for Index := 0 to Entries.Count - 1 do
  begin
    Result := ParseCertificate(Entries.Entries[Index].Data, Entries.Entries[Index].Length, Certificate);
    if Result <> TlsErrorNone then
      Exit;
    Insert(Certificate, Connection^.ServerCertificates, Length(Connection^.ServerCertificates));
  end;
  if Connection^.Options.VerifyCertificates and (Connection^.Options.TrustStore = nil) then
    Exit(TlsErrorNoTrustStore);

  Check := Default(TChainCheck);
  Check.Presented := @Connection^.ServerCertificates[0];
  Check.PresentedCount := Length(Connection^.ServerCertificates);
  Check.Anchors := Connection^.Options.TrustStore;
  Check.Time := Connection^.Options.VerificationTime;
  Check.HostName := Connection^.Options.ServerName;
  Outcome := VerifyCertificateChain(Check);
  Connection^.ServerIssuer := nil;
  if Outcome.Error = TlsErrorNone then
  begin
    if Length(Outcome.Path) >= 2 then
      Connection^.ServerIssuer := Outcome.Path[1];
    Exit(TlsErrorNone);
  end;
  if Outcome.Error = TlsErrorCertificateNameMismatch then
    SetErrorDetail(Connection, 'host: ' + Connection^.Options.ServerName)
  else
    DescribeCertificate(Connection, Outcome.Culprit, Outcome.Error = TlsErrorCertificateUnknownIssuer);
  Result := CertificateFailure(Connection, Outcome.Error);
end;

function CheckRevocationStatus(Connection: PTlsConnection; constref Staple: TTlsByteRange): LongInt;
var
  Leaf: PTlsCertificate;
  Status: TOcspStatus;
  Error: LongInt;
begin
  Result := TlsErrorNone;
  if Length(Connection^.ServerCertificates) = 0 then
    Exit;
  Leaf := Connection^.ServerCertificates[0];
  if Staple.Length = 0 then
  begin
    Connection^.CertificateStatus := StatusNoResponse;
    if Leaf^.RequiresStapledStatus then
    begin
      DescribeCertificate(Connection, Leaf, False);
      Result := CertificateFailure(Connection, TlsErrorCertificateStatusMissing);
    end;
    Exit;
  end;
  { Without a path there is no issuer to check the response with (the
    chain error is already the ignored one). }
  if Connection^.ServerIssuer = nil then
    Exit;
  Error := CheckOcspResponse(Staple.Data, Staple.Length, Leaf^, Connection^.ServerIssuer^,
    Connection^.Options.VerificationTime, Status);
  if Error = TlsErrorNone then
  begin
    if Status = OcspGood then
      Connection^.CertificateStatus := StatusGood
    else
    begin
      Connection^.CertificateStatus := StatusUnknown;
      if Leaf^.RequiresStapledStatus then
        Error := TlsErrorCertificateStatusMissing;
    end;
  end;
  if Error <> TlsErrorNone then
  begin
    DescribeCertificate(Connection, Leaf, False);
    Result := CertificateFailure(Connection, Error);
  end;
end;

end.
