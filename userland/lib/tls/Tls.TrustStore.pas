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
  A set of trusted certificates (trust anchors): the roots a chain must
  end at. They come from a PEM bundle (the system's is
  /etc/ssl/certs/ca-certificates.crt, read by Tls.SystemTrust) or one
  by one. A certificate that does not parse is left out; anchors are
  trusted for what they are, so their own signatures are never checked.
}
unit Tls.TrustStore;

{$mode objfpc}
{$H+}

interface

uses
  Tls.Certificates;

type
  TTlsTrustStore = record
    Certificates: array of PTlsCertificate;
    { Length(Certificates). }
    Count: Integer;
  end;
  PTlsTrustStore = ^TTlsTrustStore;

function CreateTrustStore: PTlsTrustStore;
procedure FreeTrustStore(var Store: PTlsTrustStore);
{ A DER certificate; TlsErrorNone or the parse error. }
function AddTrustedCertificate(Store: PTlsTrustStore; Der: PByte; Length: PtrUInt): LongInt;
{ Every certificate block of a PEM text; returns how many were added. }
function AddPemCertificates(Store: PTlsTrustStore; const Text: string): Integer;
function AddPemCertificates(Store: PTlsTrustStore; Text: PChar; Length: PtrUInt): Integer;
function TrustedCertificate(Store: PTlsTrustStore; Index: Integer): PTlsCertificate;
{ True when Store holds exactly this certificate (byte for byte). }
function StoreContainsCertificate(Store: PTlsTrustStore; constref Certificate: TTlsCertificate): Boolean;

implementation

uses
  SysUtils,
  Tls.ByteBuffers,
  Tls.Errors,
  Tls.Pem;

function CreateTrustStore: PTlsTrustStore;
begin
  { Zeroed memory is also an empty array. }
  Result := AllocMem(SizeOf(TTlsTrustStore));
end;

procedure FreeTrustStore(var Store: PTlsTrustStore);
var
  Index: Integer;
begin
  if Store = nil then
    Exit;
  for Index := 0 to Store^.Count - 1 do
    FreeCertificate(Store^.Certificates[Index]);
  Finalize(Store^);
  FreeMem(Store);
  Store := nil;
end;

function AddTrustedCertificate(Store: PTlsTrustStore; Der: PByte; Length: PtrUInt): LongInt;
var
  Certificate: PTlsCertificate;
begin
  if Store = nil then
    Exit(TlsErrorInvalidArgument);
  Result := ParseCertificate(Der, Length, Certificate);
  if Result <> TlsErrorNone then
    Exit;
  if StoreContainsCertificate(Store, Certificate^) then
  begin
    FreeCertificate(Certificate);
    Exit(TlsErrorNone);
  end;
  Insert(Certificate, Store^.Certificates, Store^.Count);
  Inc(Store^.Count);
end;

function AddPemCertificates(Store: PTlsTrustStore; const Text: string): Integer;
var
  Scanner: TPemScanner;
  Der: TBytes;
begin
  Result := 0;
  BeginPemScan(Scanner, Text);
  while NextPemCertificate(Scanner, Der) do
    if AddTrustedCertificate(Store, @Der[0], Length(Der)) = TlsErrorNone then
      Inc(Result);
end;

function AddPemCertificates(Store: PTlsTrustStore; Text: PChar; Length: PtrUInt): Integer;
var
  Contents: string;
begin
  SetString(Contents, Text, Length);
  Result := AddPemCertificates(Store, Contents);
end;

function TrustedCertificate(Store: PTlsTrustStore; Index: Integer): PTlsCertificate;
begin
  if (Store = nil) or (Index < 0) or (Index >= Store^.Count) then
    Exit(nil);
  Result := Store^.Certificates[Index];
end;

function StoreContainsCertificate(Store: PTlsTrustStore; constref Certificate: TTlsCertificate): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if Store = nil then
    Exit;
  for Index := 0 to Store^.Count - 1 do
    if ByteRangesEqual(Store^.Certificates[Index]^.Encoding, Certificate.Encoding) then
      Exit(True);
end;

end.
