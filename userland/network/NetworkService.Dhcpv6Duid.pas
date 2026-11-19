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
  The machine's DHCPv6 identity (its DUID, RFC 8415 11): one for every
  interface, made once and kept in /var/lib/network/dhcpv6.duid
  ("00:01:00:01:..." on one line, mode 0644), so servers know the
  machine again after a restart. The first time it is a DUID-LLT of the
  first interface that asks; if the file cannot be written, a DUID-LL
  (the same every time without being kept) is used instead.
}
unit NetworkService.Dhcpv6Duid;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  DuidFile = '/var/lib/network/dhcpv6.duid';

{ The DUID kept, or a new one made from HardwareAddress (6 bytes). }
function MachineDuid(const HardwareAddress: array of Byte): TBytes;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Files,
  NetworkService.Log,
  NetworkService.Dhcpv6Messages;

const
  FileMode = $1A4;     { rw-r--r-- }
  FolderMode = $1ED;   { rwxr-xr-x }
  ReadLimit = 256;

var
  KnownDuid: TBytes = nil;

function ReadKeptDuid(out Duid: TBytes): Boolean;
var
  Handle: Int64;
  Buffer: array[0..ReadLimit - 1] of Char;
  Count: Int64;
  Text: string;
begin
  Duid := nil;
  Handle := OpenFile(PChar(DuidFile), OpenRead);
  if Handle < 0 then
    Exit(False);
  Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
  CloseFile(Handle);
  if Count <= 0 then
    Exit(False);
  SetString(Text, PChar(@Buffer[0]), Count);
  Result := ColonHexToBytes(Trim(Text), Duid) and IsUsableClientDuid(Duid);
end;

procedure MakeFolder(const Path: string);
begin
  if IsDirectory(PChar(Path)) then
    Exit;
  if CreateDirectory(PChar(Path)) = ErrorNone then
    ChangeMode(PChar(Path), FolderMode);
end;

function KeepDuid(const Duid: TBytes): Boolean;
var
  Text: string;
  NewPath: string;
  Handle: Int64;
  Error: LongInt;
begin
  MakeFolder('/var/lib');
  MakeFolder(ExtractFileDir(DuidFile));
  Text := BytesToColonHex(Duid) + #10;
  NewPath := DuidFile + '.new';
  Handle := OpenFile(PChar(NewPath), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(False);
  Error := ChangeMode(PChar(NewPath), FileMode);
  if Error = ErrorNone then
    Error := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
  if Error = ErrorNone then
    Error := RenamePath(PChar(NewPath), PChar(DuidFile));
  if Error <> ErrorNone then
    RemovePath(PChar(NewPath));
  Result := Error = ErrorNone;
end;

function MachineDuid(const HardwareAddress: array of Byte): TBytes;
var
  Duid: TBytes;
begin
  if Length(KnownDuid) > 0 then
    Exit(KnownDuid);
  if not ReadKeptDuid(Duid) then
  begin
    Duid := MakeLinkLayerTimeDuid(HardwareAddress, KernelGetTime(TimeWallClock));
    if KeepDuid(Duid) then
      Say('DHCPv6 DUID made: ' + BytesToColonHex(Duid))
    else
    begin
      Duid := MakeLinkLayerDuid(HardwareAddress);
      Say('DHCPv6 DUID cannot be kept: using ' + BytesToColonHex(Duid));
    end;
  end;
  KnownDuid := Duid;
  Result := Duid;
end;

end.
