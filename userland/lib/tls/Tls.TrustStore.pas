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
{$pointermath on}

interface

uses
  Tls.Certificates;

type
  TTlsTrustStore = record
    Certificates: ^PTlsCertificate;
    Count: Integer;
    Capacity: Integer;
  end;
  PTlsTrustStore = ^TTlsTrustStore;

function CreateTrustStore: PTlsTrustStore;
procedure FreeTrustStore(var Store: PTlsTrustStore);
{ A DER certificate; TlsErrorNone or the parse error. }
function AddTrustedCertificate(Store: PTlsTrustStore; Der: PByte; Length: PtrUInt): LongInt;
{ Every certificate block of a PEM text; returns how many were added. }
function AddPemCertificates(Store: PTlsTrustStore; Text: PChar; Length: PtrUInt): Integer;
function TrustedCertificate(Store: PTlsTrustStore; Index: Integer): PTlsCertificate;
{ True when Store holds exactly this certificate (byte for byte). }
function StoreContainsCertificate(Store: PTlsTrustStore; constref Certificate: TTlsCertificate): Boolean;

implementation

uses
  Tls.ByteBuffers,
  Tls.Errors,
  Tls.Pem;

function CreateTrustStore: PTlsTrustStore;
begin
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
  if Store^.Certificates <> nil then
    FreeMem(Store^.Certificates);
  FreeMem(Store);
  Store := nil;
end;

function AddTrustedCertificate(Store: PTlsTrustStore; Der: PByte; Length: PtrUInt): LongInt;
var
  Certificate: PTlsCertificate;
  NewCapacity: Integer;
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
  if Store^.Count = Store^.Capacity then
  begin
    NewCapacity := Store^.Capacity * 2;
    if NewCapacity < 64 then
      NewCapacity := 64;
    ReAllocMem(Store^.Certificates, NewCapacity * SizeOf(PTlsCertificate));
    Store^.Capacity := NewCapacity;
  end;
  Store^.Certificates[Store^.Count] := Certificate;
  Inc(Store^.Count);
end;

function AddPemCertificates(Store: PTlsTrustStore; Text: PChar; Length: PtrUInt): Integer;
var
  Scanner: TPemScanner;
  Der: PByte;
  DerLength: PtrUInt;
begin
  Result := 0;
  BeginPemScan(Scanner, Text, Length);
  while NextPemCertificate(Scanner, Der, DerLength) do
  begin
    if AddTrustedCertificate(Store, Der, DerLength) = TlsErrorNone then
      Inc(Result);
    FreeMem(Der);
  end;
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
