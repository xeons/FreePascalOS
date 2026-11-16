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
{$pointermath on}

interface

uses
  Tls.TrustStore;

const
  SystemTrustBundlePath: PChar = '/etc/ssl/certs/ca-certificates.crt';

{ TlsErrorNone with a new store of every certificate in the PEM file,
  or TlsErrorNoTrustStore when it cannot be read or holds none. }
function LoadTrustStoreFile(Path: PChar; out Store: PTlsTrustStore): LongInt;
function LoadSystemTrustStore(out Store: PTlsTrustStore): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Tls.ByteBuffers,
  Tls.Errors;

const
  MaximumBundleSize = 16 * 1024 * 1024;

function LoadTrustStoreFile(Path: PChar; out Store: PTlsTrustStore): LongInt;
var
  Handle: Int64;
  Contents: TTlsBuilder;
  Chunk: array[0..16383] of Byte;
  Count: Int64;
begin
  Store := nil;
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
    Exit(TlsErrorNoTrustStore);
  InitializeBuilder(Contents);
  repeat
    Count := ReadFile(Handle, @Chunk[0], SizeOf(Chunk));
    if Count > 0 then
      AppendBytes(Contents, @Chunk[0], Count);
  until (Count <= 0) or (Contents.Length > MaximumBundleSize) or Contents.Failed;
  CloseFile(Handle);
  if (Count < 0) or Contents.Failed or (Contents.Length > MaximumBundleSize) then
  begin
    FreeBuilder(Contents);
    Exit(TlsErrorNoTrustStore);
  end;
  Store := CreateTrustStore;
  AddPemCertificates(Store, PChar(Contents.Data), Contents.Length);
  FreeBuilder(Contents);
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
