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
  Certificates: DER that is not DER, PEM, the host name rules, the test
  certificates of tools/TlsTest/certificates (parsed, then chains
  checked: good ones through an intermediate and with an RSA-PSS
  signature, and each way a chain can fail), and every root of the
  system's Mozilla bundle parsed, with the self-signatures checked of
  those whose algorithm is supported.
}
unit TlsTest.Certificates;

{$mode objfpc}
{$H+}

interface

procedure TestAsn1;
procedure TestHostNameRules;
procedure TestTestCertificates(const Directory: string);
procedure TestMozillaBundle(const Path: string);

implementation

uses
  SysUtils,
  TestChecks,
  Runtime.Time,
  Tls.Asn1,
  Tls.ByteBuffers,
  Tls.Certificates,
  Tls.CertificateChains,
  Tls.Errors,
  Tls.HostNames,
  Tls.Pem,
  Tls.Signatures,
  Tls.TrustStore;

function ReadWholeFile(const Path: string): string;
var
  Source: File of Byte;
  Size: Int64;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  Assign(Source, Path);
  Reset(Source);
  Size := FileSize(Source);
  SetLength(Result, Size);
  if Size > 0 then
    BlockRead(Source, Result[1], Size);
  Close(Source);
end;

procedure TestAsn1;
var
  Data: TByteArray;
  Reader: TAsn1Reader;
  Element: TAsn1Element;
  Time: Int64;
  Magnitude: PByte;
  MagnitudeLength: PtrUInt;
  Flags: LongWord;

  function ReadsOne(const Hex: string): Boolean;
  begin
    Data := HexToBytes(Hex);
    InitializeAsn1Reader(Reader, @Data[0], Length(Data));
    Result := ReadAsn1Element(Reader, Element) and Asn1ReaderAtEnd(Reader);
  end;

begin
  Check(ReadsOne('300403020500'), 'DER: a sequence');
  Check(not ReadsOne('3005030205'), 'DER: contents longer than the data refused');
  Check(not ReadsOne('308104030205 00'), 'DER: a long length for a short one refused');
  Check(not ReadsOne('3080030205000000'), 'DER: indefinite length refused');
  Check(not ReadsOne('1f2001ff'), 'DER: high tag numbers refused');
  Check(not ReadsOne('30820004 03020500'), 'DER: length with a leading zero byte refused');
  Check(ReadsOne('04820100' + StringOfChar('a', 512)), 'DER: two length bytes');

  Check(ReadsOne('170d3236313131363031303230335a') and ReadAsn1Time(Element, Time) and
    (Time = CalendarToUnixTime(2026, 11, 16, 1, 2, 3)), 'DER: UTCTime');
  Check(ReadsOne('170d3439313233313233353935395a') and ReadAsn1Time(Element, Time) and
    (Time = CalendarToUnixTime(2049, 12, 31, 23, 59, 59)), 'DER: UTCTime 49 is 2049');
  Check(ReadsOne('170d3530303130313030303030305a') and ReadAsn1Time(Element, Time) and
    (Time = CalendarToUnixTime(1950, 1, 1, 0, 0, 0)), 'DER: UTCTime 50 is 1950');
  Check(ReadsOne('180f32313235313233313233353935395a') and ReadAsn1Time(Element, Time) and
    (Time = CalendarToUnixTime(2125, 12, 31, 23, 59, 59)), 'DER: GeneralizedTime');
  Check(ReadsOne('170d3236303233303030303030305a') and not ReadAsn1Time(Element, Time),
    'DER: February 30 refused');
  Check(ReadsOne('17113236313131363031303230332b30313030') and not ReadAsn1Time(Element, Time),
    'DER: a time zone offset refused');

  Check(ReadsOne('020100') and ReadAsn1UnsignedInteger(Element, Magnitude, MagnitudeLength) and
    (MagnitudeLength = 1), 'DER: integer zero');
  Check(ReadsOne('02020080') and ReadAsn1UnsignedInteger(Element, Magnitude, MagnitudeLength) and
    (MagnitudeLength = 1) and (Magnitude[0] = $80), 'DER: leading zero for a high bit');
  Check(ReadsOne('02020001') and not ReadAsn1UnsignedInteger(Element, Magnitude, MagnitudeLength),
    'DER: needless leading zero refused');
  Check(ReadsOne('0201ff') and not ReadAsn1UnsignedInteger(Element, Magnitude, MagnitudeLength),
    'DER: negative integer refused');
  { KeyUsage digitalSignature | keyCertSign: bits 0 and 5. }
  Check(ReadsOne('03020284') and ReadAsn1BitFlags(Element, Flags) and (Flags = (1 or (1 shl 5))),
    'DER: named bits');
  Check(ReadsOne('03020285') and not ReadAsn1BitFlags(Element, Flags), 'DER: set unused bits refused');
end;

function DnsMatch(const Pattern, Host: string): Boolean;
begin
  Result := DnsNameMatches(PByte(PChar(Pattern)), Length(Pattern), PByte(PChar(Host)), Length(Host));
end;

procedure TestHostNameRules;
var
  Address: array[0..3] of Byte;
begin
  Check(DnsMatch('example.com', 'example.com'), 'names: exact');
  Check(DnsMatch('Example.COM', 'example.com'), 'names: case does not matter');
  Check(not DnsMatch('example.com', 'www.example.com'), 'names: no implied subdomains');
  Check(DnsMatch('*.example.com', 'www.example.com'), 'names: wildcard');
  Check(not DnsMatch('*.example.com', 'a.b.example.com'), 'names: a wildcard is one label');
  Check(not DnsMatch('*.example.com', 'example.com'), 'names: a wildcard is not empty');
  Check(not DnsMatch('*.com', 'example.com'), 'names: no wildcard over a top level domain');
  Check(not DnsMatch('w*.example.com', 'www.example.com'), 'names: partial wildcards refused');
  Check(not DnsMatch('www.*.com', 'www.example.com'), 'names: wildcards only on the left');
  Check(not DnsMatch('*.example.com', '.example.com'), 'names: empty host label');
  Check(not DnsMatch('exa_mple.com', 'exa_mple.com'), 'names: invalid characters in the pattern');
  Check(ParseIpv4Literal('10.0.2.101', Address) and (Address[3] = 101), 'names: IPv4 literal');
  Check(not ParseIpv4Literal('10.0.2', Address), 'names: three parts are not an address');
  Check(not ParseIpv4Literal('10.0.2.256', Address), 'names: 256 is not a part');
  Check(not ParseIpv4Literal('1.2.3.4.example', Address), 'names: a name is not an address');
end;

function LoadCertificate(const Path: string; out Certificate: PTlsCertificate): Boolean;
var
  Text: string;
  Scanner: TPemScanner;
  Der: PByte;
  DerLength: PtrUInt;
begin
  Certificate := nil;
  Text := ReadWholeFile(Path);
  Result := False;
  if Text = '' then
    Exit;
  BeginPemScan(Scanner, PChar(Text), Length(Text));
  if not NextPemCertificate(Scanner, Der, DerLength) then
    Exit;
  Result := ParseCertificate(Der, DerLength, Certificate) = TlsErrorNone;
  FreeMem(Der);
end;

type
  TCertificateList = array of PTlsCertificate;

function LoadAll(const Directory: string; const Names: array of string): TCertificateList;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Names));
  for Index := 0 to High(Names) do
    Check(LoadCertificate(Directory + '/' + Names[Index] + '.pem', Result[Index]), 'parse ' + Names[Index] + '.pem');
end;

procedure FreeAll(var List: TCertificateList);
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    FreeCertificate(List[Index]);
  List := nil;
end;

function ChainError(const Chain: array of PTlsCertificate; Store: PTlsTrustStore; const HostName: string;
  Time: Int64): LongInt;
var
  CheckData: TChainCheck;
  Presented: array[0..15] of PTlsCertificate;
  Index: Integer;
begin
  for Index := 0 to High(Chain) do
    Presented[Index] := Chain[Index];
  FillChar(CheckData, SizeOf(CheckData), 0);
  CheckData.Presented := @Presented[0];
  CheckData.PresentedCount := Length(Chain);
  CheckData.Anchors := Store;
  CheckData.Time := Time;
  if HostName <> '' then
    CheckData.HostName := PChar(HostName);
  Result := VerifyCertificateChain(CheckData).Error;
end;

procedure CheckChain(const Chain: array of PTlsCertificate; Store: PTlsTrustStore; const HostName: string;
  Time: Int64; Expected: LongInt; const Name: string);
var
  Error: LongInt;
begin
  Error := ChainError(Chain, Store, HostName, Time);
  Check(Error = Expected, 'chain: ' + Name);
  if Error <> Expected then
    WriteLn('     got ', Error, ' (', TlsErrorMessage(Error), '), expected ', Expected);
end;

procedure TestTestCertificates(const Directory: string);
const
  Names: array[0..9] of string = ('ca', 'intermediate', 'server', 'server-rsa', 'wrong-name', 'expired',
    'not-authority', 'wildcard', 'other-ca', 'other-server');
var
  List: TCertificateList;
  Ca, Intermediate, Server, ServerRsa, WrongName, Expired, NotAuthority, Wildcard, OtherCa, OtherServer:
    PTlsCertificate;
  Store, PinnedStore: PTlsTrustStore;
  Now: Int64;
  Text: string;
begin
  List := LoadAll(Directory, Names);
  Ca := List[0];
  Intermediate := List[1];
  Server := List[2];
  ServerRsa := List[3];
  WrongName := List[4];
  Expired := List[5];
  NotAuthority := List[6];
  Wildcard := List[7];
  OtherCa := List[8];
  OtherServer := List[9];
  if (Ca = nil) or (Intermediate = nil) or (Server = nil) or (ServerRsa = nil) or (WrongName = nil) or
     (Expired = nil) or (NotAuthority = nil) or (Wildcard = nil) or (OtherCa = nil) or (OtherServer = nil) then
  begin
    Check(False, 'test certificates missing in ' + Directory);
    FreeAll(List);
    Exit;
  end;

  Check(Ca^.PublicKeyKind = PublicKeyRsa, 'ca: RSA key');
  Check(Ca^.IsAuthority and Ca^.HasKeyUsage, 'ca: an authority');
  Check(Intermediate^.PublicKeyKind = PublicKeyEcP384, 'intermediate: P-384 key');
  Check(Intermediate^.PathLengthLimit = 0, 'intermediate: path length 0');
  Check(Intermediate^.SignatureAlgorithm = SignatureRsaPkcs1Sha256, 'intermediate: RSA SHA-256 signature');
  Check(Server^.PublicKeyKind = PublicKeyEcP256, 'server: P-256 key');
  Check(Server^.SignatureAlgorithm = SignatureEcdsaSha384, 'server: ECDSA SHA-384 signature');
  Check(Server^.Version = 3, 'server: version 3');
  Check(Server^.HasSubjectAlternativeNames and Server^.AllowsServerAuthentication, 'server: names and purpose');
  Check(Server^.NotAfter = CalendarToUnixTime(2125, 12, 31, 23, 59, 59), 'server: GeneralizedTime not after');
  Check(ServerRsa^.SignatureAlgorithm = SignatureRsaPss, 'server-rsa: RSA-PSS signature');
  Check(ServerRsa^.PssSaltLength = 32, 'server-rsa: salt 32');
  Check(CertificateMatchesHost(Server^, 'localhost'), 'server: for localhost');
  Check(CertificateMatchesHost(Server^, 'LOCALHOST.'), 'server: for LOCALHOST.');
  Check(CertificateMatchesHost(Server^, '10.0.2.101'), 'server: for 10.0.2.101');
  Check(not CertificateMatchesHost(Server^, '10.0.2.102'), 'server: not for 10.0.2.102');
  Check(not CertificateMatchesHost(Server^, 'example.com'), 'server: not for example.com');
  Check(CertificateMatchesHost(Wildcard^, 'a.test.example'), 'wildcard: a.test.example');
  Check(not CertificateMatchesHost(Wildcard^, 'test.example'), 'wildcard: not test.example');
  Check(CertificateMatchesHost(Wildcard^, 'exact.example'), 'wildcard: exact.example');

  Check(CheckCertificateSignature(Intermediate^, Server^) = SignatureValid, 'signature: intermediate on server');
  Check(CheckCertificateSignature(Ca^, Intermediate^) = SignatureValid, 'signature: ca on intermediate');
  Check(CheckCertificateSignature(Ca^, ServerRsa^) = SignatureValid, 'signature: ca on server-rsa (PSS)');
  Check(CheckCertificateSignature(Ca^, Ca^) = SignatureValid, 'signature: ca on itself');
  Check(CheckCertificateSignature(Ca^, Server^) = SignatureUnsupported, 'signature: RSA key for ECDSA refused');
  Check(CheckCertificateSignature(OtherCa^, ServerRsa^) = SignatureInvalid, 'signature: the wrong RSA key');

  Store := CreateTrustStore;
  Text := ReadWholeFile(Directory + '/ca.pem');
  Check(AddPemCertificates(Store, PChar(Text), Length(Text)) = 1, 'store: ca.pem added');
  Now := CalendarToUnixTime(2026, 11, 16, 12, 0, 0);

  CheckChain([Server, Intermediate], Store, 'localhost', Now, TlsErrorNone, 'server through the intermediate');
  CheckChain([Server, Intermediate], Store, '10.0.2.101', Now, TlsErrorNone, 'server by address');
  CheckChain([Server, OtherCa, Intermediate], Store, 'localhost', Now, TlsErrorNone,
    'an unrelated certificate in the way');
  CheckChain([Server, Intermediate, Ca], Store, 'localhost', Now, TlsErrorNone, 'the root sent too');
  CheckChain([ServerRsa], Store, 'localhost', Now, TlsErrorNone, 'RSA server under the root');
  CheckChain([Server, Intermediate], Store, 'example.com', Now, TlsErrorCertificateNameMismatch,
    'another host name');
  CheckChain([WrongName, Intermediate], Store, 'localhost', Now, TlsErrorCertificateNameMismatch,
    'a certificate for other.example');
  CheckChain([Expired, Intermediate], Store, 'localhost', Now, TlsErrorCertificateExpired, 'expired');
  CheckChain([Server, Intermediate], Store, 'localhost', CalendarToUnixTime(2025, 6, 1, 0, 0, 0),
    TlsErrorCertificateNotYetValid, 'before the certificates start');
  CheckChain([Server, Intermediate], Store, 'localhost', CalendarToUnixTime(2126, 6, 1, 0, 0, 0),
    TlsErrorCertificateExpired, 'after they end');
  CheckChain([Server], Store, 'localhost', Now, TlsErrorCertificateUnknownIssuer, 'the intermediate left out');
  CheckChain([OtherServer, OtherCa], Store, 'localhost', Now, TlsErrorCertificateUnknownIssuer,
    'an untrusted root');
  CheckChain([NotAuthority, Server, Intermediate], Store, 'localhost', Now, TlsErrorCertificateNotAuthority,
    'issued by a server certificate');
  CheckChain([Server, Intermediate], nil, 'localhost', Now, TlsErrorCertificateUnknownIssuer, 'no anchors');

  { A server certificate trusted as it is (wget --ca-certificate with
    the server's own certificate). }
  PinnedStore := CreateTrustStore;
  Text := ReadWholeFile(Directory + '/server.pem');
  AddPemCertificates(PinnedStore, PChar(Text), Length(Text));
  CheckChain([Server], PinnedStore, 'localhost', Now, TlsErrorNone, 'a pinned server certificate');
  CheckChain([Server], PinnedStore, 'example.com', Now, TlsErrorCertificateNameMismatch,
    'a pinned certificate still needs the right name');

  FreeTrustStore(PinnedStore);
  FreeTrustStore(Store);
  FreeAll(List);
end;

procedure TestMozillaBundle(const Path: string);
var
  Text: string;
  Scanner: TPemScanner;
  Der: PByte;
  DerLength: PtrUInt;
  Certificate: PTlsCertificate;
  Total, Parsed, SelfSigned, Valid, Unsupported, Invalid: Integer;
  Outcome: TSignatureCheck;
  Store: PTlsTrustStore;
begin
  Text := ReadWholeFile(Path);
  Check(Text <> '', 'Mozilla bundle read from ' + Path);
  if Text = '' then
    Exit;
  Total := 0;
  Parsed := 0;
  SelfSigned := 0;
  Valid := 0;
  Unsupported := 0;
  Invalid := 0;
  BeginPemScan(Scanner, PChar(Text), Length(Text));
  while NextPemCertificate(Scanner, Der, DerLength) do
  begin
    Inc(Total);
    if ParseCertificate(Der, DerLength, Certificate) = TlsErrorNone then
    begin
      Inc(Parsed);
      if ByteRangesEqual(Certificate^.Subject, Certificate^.Issuer) then
      begin
        Inc(SelfSigned);
        Outcome := CheckCertificateSignature(Certificate^, Certificate^);
        case Outcome of
          SignatureValid: Inc(Valid);
          SignatureUnsupported: Inc(Unsupported);
        else
          Inc(Invalid);
          WriteLn('     bad self-signature: root ', Total);
        end;
      end;
      FreeCertificate(Certificate);
    end
    else
      WriteLn('     root ', Total, ' does not parse');
    FreeMem(Der);
  end;
  WriteLn('     ', Total, ' roots, ', Parsed, ' parsed, ', SelfSigned, ' self-signed: ', Valid, ' signatures valid, ',
    Unsupported, ' unsupported (SHA-1, P-521), ', Invalid, ' invalid');
  Check(Total > 100, 'Mozilla bundle: over 100 roots');
  Check(Parsed = Total, 'Mozilla bundle: every root parses');
  Check(Invalid = 0, 'Mozilla bundle: no self-signature fails');
  Check(Valid > 80, 'Mozilla bundle: most self-signatures check');

  Store := CreateTrustStore;
  Check(AddPemCertificates(Store, PChar(Text), Length(Text)) = Total, 'Mozilla bundle: all go into a store');
  FreeTrustStore(Store);
end;

end.
