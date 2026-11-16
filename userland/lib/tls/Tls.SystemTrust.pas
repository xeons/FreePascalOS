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
  The system's trusted roots: the PEM bundle
  /etc/ssl/certs/ca-certificates.crt (the Mozilla CA list, installed
  with the system), or any other PEM file of certificates a program
  names (wget --ca-certificate).
}
unit Tls.SystemTrust;

{$mode objfpc}
{$H+}

interface

uses
  Tls.TrustStore;

const
  SystemTrustBundlePath = '/etc/ssl/certs/ca-certificates.crt';

{ TlsErrorNone with a new store of every certificate in the PEM file,
  or TlsErrorNoTrustStore when it cannot be read or holds none. }
function LoadTrustStoreFile(const Path: string; out Store: PTlsTrustStore): LongInt;
function LoadSystemTrustStore(out Store: PTlsTrustStore): LongInt;

implementation

uses
  SysUtils,
  Tls.Errors;

const
  MaximumBundleSize = 16 * 1024 * 1024;
  ChunkSize = 16384;

{ The whole file, or False when it cannot be read or is too big. }
function ReadBundle(const Path: string; out Contents: string): Boolean;
var
  Handle: THandle;
  Total: Integer;
  Count: LongInt;
begin
  Contents := '';
  Handle := FileOpen(Path, fmOpenRead);
  if Handle = feInvalidHandle then
    Exit(False);
  Total := 0;
  try
    repeat
      if Total + ChunkSize > Length(Contents) then
        SetLength(Contents, 2 * (Total + ChunkSize));
      Count := FileRead(Handle, Contents[Total + 1], ChunkSize);
      if Count > 0 then
        Total := Total + Count;
    until (Count <= 0) or (Total > MaximumBundleSize);
  finally
    FileClose(Handle);
  end;
  SetLength(Contents, Total);
  Result := (Count = 0) and (Total <= MaximumBundleSize);
end;

function LoadTrustStoreFile(const Path: string; out Store: PTlsTrustStore): LongInt;
var
  Contents: string;
begin
  Store := nil;
  if not ReadBundle(Path, Contents) then
    Exit(TlsErrorNoTrustStore);
  Store := CreateTrustStore;
  AddPemCertificates(Store, Contents);
  if Store^.Count = 0 then
  begin
    FreeTrustStore(Store);
    Exit(TlsErrorNoTrustStore);
  end;
  Result := TlsErrorNone;
end;

function LoadSystemTrustStore(out Store: PTlsTrustStore): LongInt;
begin
  Result := LoadTrustStoreFile(SystemTrustBundlePath, Store);
end;

end.
