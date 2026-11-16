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
  /etc/hosts: names this machine knows without asking a DNS server.

    # comments
    127.0.0.1   localhost localhost.localdomain
    ::1         localhost ip6-localhost
    10.0.2.2    gateway

  Each line is an address and the names it has, the first its canonical
  name, the others aliases; names are compared without case. The
  resolver looks here first (Sys.HostNames). The file is read again at
  each lookup: it is small, and a change counts at once.
}
unit Sys.HostsFile;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses;

const
  HostsFilePath = '/etc/hosts';

type
  THostsFileAddresses = record
    Addresses: TInternetAddressArray;
    { The first name of the first line that had the name. }
    CanonicalName: string;
  end;

{ The addresses /etc/hosts gives Name (of the families Families asks
  for: HostFamily* of Sys.HostNames, bits 1 IPv4 and 2 IPv6). False if
  it gives none. }
function LookUpHostsFileName(const Name: string; Families: LongWord; out Found: THostsFileAddresses): Boolean;
{ The first name /etc/hosts gives Address. }
function LookUpHostsFileAddress(constref Address: TInternetAddress; out Name: string): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Text,
  Sys.DnsNames;

const
  FamilyBitIpv4 = 1;
  FamilyBitIpv6 = 2;
  ReadChunkBytes = 4096;

type
  { The words of one line: the address, then its names. }
  THostsLine = array of string;
  THostsLines = array of THostsLine;

{ The whole file; '' if it cannot be read. }
function ReadHostsFile: string;
var
  Handle: Int64;
  Chunk: array[0..ReadChunkBytes - 1] of Char;
  ChunkText: string;
  Read: Int64;
begin
  Result := '';
  Handle := OpenFile(HostsFilePath, OpenRead);
  if Handle < 0 then
    Exit;
  repeat
    Read := ReadFile(Handle, @Chunk[0], SizeOf(Chunk));
    if Read > 0 then
    begin
      SetString(ChunkText, PChar(@Chunk[0]), Read);
      Result := Result + ChunkText;
    end;
  until Read <= 0;
  CloseFile(Handle);
end;

{ The words of Text, without its comment. }
function SplitLine(const Text: string): THostsLine;
var
  Position: Integer;
  WordStart: Integer;
  LineEnd: Integer;
begin
  Result := nil;
  LineEnd := Pos('#', Text);
  if LineEnd = 0 then
    LineEnd := Length(Text) + 1;
  Position := 1;
  while Position < LineEnd do
  begin
    while (Position < LineEnd) and IsSpace(Text[Position]) do
      Inc(Position);
    WordStart := Position;
    while (Position < LineEnd) and not IsSpace(Text[Position]) do
      Inc(Position);
    if Position > WordStart then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Text, WordStart, Position - WordStart);
    end;
  end;
end;

{ Every line with an address and a name. }
function ReadHostsLines: THostsLines;
var
  Text: string;
  LineStart: Integer;
  LineEnd: Integer;
  Line: THostsLine;
begin
  Result := nil;
  Text := ReadHostsFile;
  LineStart := 1;
  while LineStart <= Length(Text) do
  begin
    LineEnd := LineStart;
    while (LineEnd <= Length(Text)) and (Text[LineEnd] <> #10) do
      Inc(LineEnd);
    Line := SplitLine(Copy(Text, LineStart, LineEnd - LineStart));
    if Length(Line) >= 2 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Line;
    end;
    LineStart := LineEnd + 1;
  end;
end;

function FamilyIsWanted(constref Address: TInternetAddress; Families: LongWord): Boolean;
begin
  Result := ((Address.Family = AddressFamilyIPv4) and ((Families and FamilyBitIpv4) <> 0)) or
    ((Address.Family = AddressFamilyIPv6) and ((Families and FamilyBitIpv6) <> 0));
end;

function LineHasName(const Line: THostsLine; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to High(Line) do
    if DnsNamesAreEqual(Line[Index], Name) then
      Exit(True);
  Result := False;
end;

function LookUpHostsFileName(const Name: string; Families: LongWord; out Found: THostsFileAddresses): Boolean;
var
  Line: THostsLine;
  Address: TInternetAddress;
begin
  Found := Default(THostsFileAddresses);
  for Line in ReadHostsLines do
  begin
    if not TextToAddress(Line[0], Address) or not FamilyIsWanted(Address, Families) then
      Continue;
    if not LineHasName(Line, Name) then
      Continue;
    if Length(Found.Addresses) = 0 then
      Found.CanonicalName := Line[1];
    SetLength(Found.Addresses, Length(Found.Addresses) + 1);
    Found.Addresses[High(Found.Addresses)] := Address;
  end;
  Result := Length(Found.Addresses) > 0;
end;

function LookUpHostsFileAddress(constref Address: TInternetAddress; out Name: string): Boolean;
var
  Line: THostsLine;
  LineAddress: TInternetAddress;
begin
  Name := '';
  for Line in ReadHostsLines do
    if TextToAddress(Line[0], LineAddress) and AddressesAreEqual(LineAddress, Address) then
    begin
      Name := Line[1];
      Exit(True);
    end;
  Result := False;
end;

end.
