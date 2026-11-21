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

{ TlsTest: certificates as text (Tls.CertificateSummaries) on the
  repository's test certificates, whose values openssl gives. }
unit TlsTest.Summaries;

{$mode objfpc}
{$H+}

interface

procedure TestCertificateSummaries(const Directory: string);
{ Every root of a PEM bundle summarized: names, no exceptions. }
procedure TestBundleSummaries(const Path: string);

implementation

uses
  SysUtils,
  Classes,
  TestChecks,
  Crypto.Digests,
  Tls.ByteBuffers,
  Tls.Certificates,
  Tls.CertificateSummaries,
  Tls.Errors,
  Tls.Pem,
  Tls.TrustStore;

function LoadTestCertificate(const Path: string; out Certificate: PTlsCertificate): Boolean;
var
  Lines: TStringList;
  Text: string;
  Scanner: TPemScanner;
  Der: PByte;
  DerLength: PtrUInt;
begin
  Certificate := nil;
  Result := False;
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Text := Lines.Text;
  finally
    Lines.Free;
  end;
  BeginPemScan(Scanner, PChar(Text), Length(Text));
  if not NextPemCertificate(Scanner, Der, DerLength) then
    Exit;
  Result := ParseCertificate(Der, DerLength, Certificate) = TlsErrorNone;
  FreeMem(Der);
end;

procedure TestCertificateSummaries(const Directory: string);
var
  Certificate: PTlsCertificate;
  Summary: TTlsCertificateSummary;
  Digest: TDigestOutput;
  Empty: TTlsByteRange;
  Garbage: array[0..5] of Byte;
begin
  if not LoadTestCertificate(IncludeTrailingPathDelimiter(Directory) + 'server.pem', Certificate) then
  begin
    Check(False, 'summaries: the test server certificate loads');
    Exit;
  end;
  try
    Summary := SummarizeCertificate(Certificate^);
    Check(Summary.Subject = 'O=FreePascalOS, CN=localhost', 'summaries: the subject in order');
    Check(Summary.Issuer = 'O=FreePascalOS, CN=FreePascalOS Test Intermediate CA', 'summaries: the issuer');
    Check((Summary.CommonName = 'localhost') and (Summary.Organization = 'FreePascalOS'),
      'summaries: common name and organization');
    Check((Summary.ValidFrom = '2026-01-01 00:00:00 UTC') and (Summary.ValidUntil = '2125-12-31 23:59:59 UTC'),
      'summaries: the validity');
    Check(Summary.SerialNumber = '14:16:26:8A:12:DB:90:71', 'summaries: the serial number');
    ComputeDigest(DigestSha256, Certificate^.Encoding.Data, Certificate^.Encoding.Length, Digest);
    Check((Length(Summary.Sha256Fingerprint) = 95) and
      (Summary.Sha256Fingerprint = ColonHexText(@Digest[0], 32)) and
      (Summary.Sha256Fingerprint = '94:2C:97:21:79:EC:B6:A0:CB:34:50:5F:23:51:55:AE:57:5D:A3:18:9C:04:E9:DC:04:D9:45:5C:'
      + 'E0:BB:7B:A1'), 'summaries: the SHA-256 fingerprint');
  finally
    FreeCertificate(Certificate);
  end;
  Empty := Default(TTlsByteRange);
  Check(DistinguishedNameText(Empty) = '', 'summaries: no name');
  Garbage[0] := $30;
  Garbage[1] := $7F;
  Garbage[2] := $31;
  Garbage[3] := $02;
  Garbage[4] := $30;
  Garbage[5] := $00;
  Empty.Data := @Garbage[0];
  Empty.Length := SizeOf(Garbage);
  Check(DistinguishedNameText(Empty) = '', 'summaries: a name cut short gives nothing, raises nothing');
end;

procedure TestBundleSummaries(const Path: string);
var
  Lines: TStringList;
  Store: PTlsTrustStore;
  Index, Named: Integer;
  Summary: TTlsCertificateSummary;
begin
  if not FileExists(Path) then
    Exit;
  Store := CreateTrustStore;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    AddPemCertificates(Store, Lines.Text);
    Named := 0;
    for Index := 0 to Store^.Count - 1 do
    begin
      Summary := SummarizeCertificate(TrustedCertificate(Store, Index)^);
      if (Summary.Subject <> '') and (Summary.Issuer <> '') and (Length(Summary.Sha256Fingerprint) = 95) then
        Inc(Named);
    end;
    Check((Store^.Count > 50) and (Named = Store^.Count), 'summaries: every root of the bundle (' +
      IntToStr(Named) + ' of ' + IntToStr(Store^.Count) + ')');
  finally
    Lines.Free;
    FreeTrustStore(Store);
  end;
end;

end.
