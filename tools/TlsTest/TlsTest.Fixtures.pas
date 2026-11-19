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
  The fixtures make-fixtures.py makes at build time with Python's
  cryptography package: chains under name constraints and of Ed25519
  and P-521 keys (chains.txt: each with the error it should get), OCSP
  responses about the test server certificate (ocsp.txt), the TLS 1.2
  PRF (prf.txt), and the name constraint matching rules one by one.
}
unit TlsTest.Fixtures;

{$mode objfpc}
{$H+}

interface

procedure TestNameConstraintRules;
procedure TestFixtureChains(const CertificateDirectory, FixtureDirectory: string);
procedure TestOcspResponses(const CertificateDirectory, FixtureDirectory: string);
procedure TestTls12Prf(const FixtureDirectory: string);

implementation

uses
  Classes,
  SysUtils,
  DateUtils,
  TestChecks,
  Crypto.Digests,
  Tls.ByteBuffers,
  Tls.Certificates,
  Tls.CertificateChains,
  Tls.Errors,
  Tls.KeySchedule12,
  Tls.NameConstraints,
  Tls.Ocsp,
  Tls.Pem,
  Tls.TrustStore;

type
  TCertificateList = array of PTlsCertificate;

function ReadWholeFile(const Path: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

{ Every certificate of a PEM file, in order. }
function LoadPemFile(const Path: string): TCertificateList;
var
  Text: string;
  Scanner: TPemScanner;
  Der: PByte;
  DerLength: PtrUInt;
  Certificate: PTlsCertificate;
begin
  Result := nil;
  Text := ReadWholeFile(Path);
  if Text = '' then
    Exit;
  BeginPemScan(Scanner, PChar(Text), Length(Text));
  while NextPemCertificate(Scanner, Der, DerLength) do
  begin
    if ParseCertificate(Der, DerLength, Certificate) = TlsErrorNone then
      Insert(Certificate, Result, Length(Result));
    FreeMem(Der);
  end;
end;

procedure FreeList(var List: TCertificateList);
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    FreeCertificate(List[Index]);
  List := nil;
end;

function NowSeconds: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

procedure TestNameConstraintRules;
var
  Address, Network: TByteArray;
begin
  Check(DnsNameInSubtree('www.example.com', 'example.com'), 'name constraints: a name below the subtree');
  Check(DnsNameInSubtree('EXAMPLE.com', 'example.COM'), 'name constraints: the subtree itself, any case');
  Check(not DnsNameInSubtree('badexample.com', 'example.com'), 'name constraints: only whole labels');
  Check(not DnsNameInSubtree('example.com', '.example.com'), 'name constraints: ".example.com" is only below');
  Check(DnsNameInSubtree('a.example.com', '.example.com'), 'name constraints: ".example.com" holds a.example.com');
  Check(DnsNameInSubtree('anything.org', ''), 'name constraints: an empty constraint holds every name');
  Check(DnsNameTouchesSubtree('*.example.com', 'www.example.com'),
    'name constraints: a wildcard can stand for an excluded name');
  Check(not DnsNameTouchesSubtree('*.example.com', 'a.b.example.com'),
    'name constraints: a wildcard is one label only');
  Check(MailboxInSubtree('root@example.com', 'example.com'), 'name constraints: a mailbox at the host');
  Check(not MailboxInSubtree('root@mail.example.com', 'example.com'), 'name constraints: not at another host');
  Check(MailboxInSubtree('root@mail.example.com', '.example.com'), 'name constraints: a mailbox at a host below');
  Check(MailboxInSubtree('Root@Example.com', 'root@example.com'), 'name constraints: one mailbox');
  Check(not MailboxInSubtree('other@example.com', 'root@example.com'), 'name constraints: not another mailbox');
  Address := HexToBytes('0a010203');
  Network := HexToBytes('0a000000ff000000');
  Check(AddressInSubtree(@Address[0], 4, @Network[0], 8), 'name constraints: 10.1.2.3 in 10.0.0.0/8');
  Address := HexToBytes('0b010203');
  Check(not AddressInSubtree(@Address[0], 4, @Network[0], 8), 'name constraints: 11.1.2.3 not in 10.0.0.0/8');
  Address := HexToBytes('20010db8000000000000000000000001');
  Check(not AddressInSubtree(@Address[0], 16, @Network[0], 8), 'name constraints: IPv6 not in an IPv4 subtree');
end;

function SplitLine(const Line: string): TStringArray;
begin
  Result := Line.Split(['|']);
end;

procedure TestFixtureChains(const CertificateDirectory, FixtureDirectory: string);
var
  Lines: TStringList;
  Parts: TStringArray;
  Index: Integer;
  Chain, Anchors: TCertificateList;
  Store: PTlsTrustStore;
  Check_: TChainCheck;
  Outcome: TChainResult;
  Expected: LongInt;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureDirectory + '/chains.txt');
    Check(Lines.Count > 10, 'fixtures: chains listed');
    for Index := 0 to Lines.Count - 1 do
    begin
      Parts := SplitLine(Lines[Index]);
      if Length(Parts) <> 5 then
        Continue;
      Chain := LoadPemFile(FixtureDirectory + '/' + Parts[1]);
      Anchors := LoadPemFile(FixtureDirectory + '/' + Parts[2]);
      Expected := StrToInt(Parts[4]);
      Store := CreateTrustStore;
      if Length(Anchors) > 0 then
        AddTrustedCertificate(Store, Anchors[0]^.Encoding.Data, Anchors[0]^.Encoding.Length);
      Check_ := Default(TChainCheck);
      if Length(Chain) > 0 then
        Check_.Presented := @Chain[0];
      Check_.PresentedCount := Length(Chain);
      Check_.Anchors := Store;
      Check_.Time := NowSeconds;
      Check_.HostName := Parts[3];
      Outcome := VerifyCertificateChain(Check_);
      Check(Outcome.Error = Expected, 'fixture chain ' + Parts[0] + ': ' + TlsErrorMessage(Expected));
      if Outcome.Error <> Expected then
        WriteLn('     got ', Outcome.Error, ' (', TlsErrorMessage(Outcome.Error), ')');
      if Expected = TlsErrorNone then
        Check(Length(Outcome.Path) = Length(Chain) + 1, 'fixture chain ' + Parts[0] + ': the path ends at the root');
      FreeTrustStore(Store);
      FreeList(Chain);
      FreeList(Anchors);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TestOcspResponses(const CertificateDirectory, FixtureDirectory: string);
var
  Lines: TStringList;
  Parts: TStringArray;
  Index: Integer;
  Subject, Issuer: TCertificateList;
  Response: string;
  Status: TOcspStatus;
  Error, Expected: LongInt;
  StatusText: string;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureDirectory + '/ocsp.txt');
    Check(Lines.Count > 5, 'fixtures: OCSP responses listed');
    for Index := 0 to Lines.Count - 1 do
    begin
      Parts := SplitLine(Lines[Index]);
      if Length(Parts) <> 6 then
        Continue;
      Response := ReadWholeFile(FixtureDirectory + '/' + Parts[1]);
      Subject := LoadPemFile(CertificateDirectory + '/' + Parts[2]);
      Issuer := LoadPemFile(CertificateDirectory + '/' + Parts[3]);
      Expected := StrToInt(Parts[4]);
      if (Response = '') or (Length(Subject) = 0) or (Length(Issuer) = 0) then
      begin
        Check(False, 'OCSP ' + Parts[0] + ': fixture readable');
        Continue;
      end;
      Error := CheckOcspResponse(PByte(PChar(Response)), Length(Response), Subject[0]^, Issuer[0]^, NowSeconds,
        Status);
      Check(Error = Expected, 'OCSP ' + Parts[0] + ': ' + TlsErrorMessage(Expected));
      if Error <> Expected then
        WriteLn('     got ', Error, ' (', TlsErrorMessage(Error), ')');
      if (Error = TlsErrorNone) and (Parts[5] <> '-') then
      begin
        if Status = OcspGood then
          StatusText := 'good'
        else
          StatusText := 'unknown';
        Check(StatusText = Parts[5], 'OCSP ' + Parts[0] + ': status ' + Parts[5]);
      end;
      FreeList(Subject);
      FreeList(Issuer);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TestTls12Prf(const FixtureDirectory: string);
var
  Lines: TStringList;
  Parts: TStringArray;
  Index: Integer;
  Secret, Seed: TByteArray;
  Output: TByteArray;
  Hash: TDigestAlgorithm;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FixtureDirectory + '/prf.txt');
    Check(Lines.Count > 3, 'fixtures: PRF vectors listed');
    for Index := 0 to Lines.Count - 1 do
    begin
      Parts := SplitLine(Lines[Index]);
      if Length(Parts) <> 5 then
        Continue;
      if Parts[0] = 'sha384' then
        Hash := DigestSha384
      else
        Hash := DigestSha256;
      Secret := HexToBytes(Parts[1]);
      Seed := HexToBytes(Parts[3]);
      Output := nil;
      SetLength(Output, Length(Parts[4]) div 2);
      Tls12Prf(Hash, @Secret[0], Length(Secret), Parts[2], @Seed[0], Length(Seed), @Output[0], Length(Output));
      CheckBytes(@Output[0], Length(Output), Parts[4], 'TLS 1.2 PRF ' + Parts[0] + ' "' + Parts[2] + '" ' +
        IntToStr(Length(Output)) + ' bytes');
    end;
  finally
    Lines.Free;
  end;
end;

end.
