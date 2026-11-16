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
{$pointermath on}

interface

uses
  Sys.InternetAddresses,
  Sys.DnsNames;

const
  HostsFilePath: PChar = '/etc/hosts';
  { The most of the file read. }
  MaximumHostsFileBytes = 65536;

type
  THostsFileAddresses = record
    Count: Integer;
    Addresses: array[0..15] of TInternetAddress;
    { The first name of the first line that had the name. }
    CanonicalName: TDnsName;
  end;

{ The addresses /etc/hosts gives Name (of the families Families asks
  for: HostFamily* of Sys.HostNames, bits 1 IPv4 and 2 IPv6). False if
  it gives none. }
function LookUpHostsFileName(Name: PChar; Families: LongWord; out Found: THostsFileAddresses): Boolean;
{ The first name /etc/hosts gives Address. }
function LookUpHostsFileAddress(constref Address: TInternetAddress; out Name: TDnsName): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Text,
  Sys.Files;

const
  FamilyBitIpv4 = 1;
  FamilyBitIpv6 = 2;

type
  { One line, split: the words point into the line, which was cut at
    their ends. }
  THostsLine = record
    WordCount: Integer;
    Words: array[0..15] of PChar;
  end;

  TLineVisitor = function(constref Line: THostsLine; Context: Pointer): Boolean;

{ Reads the file into a new buffer (with a final #0); nil if it cannot
  be read. }
function ReadHostsFile: PChar;
var
  Handle: Int64;
  Used: Int64;
  Read: Int64;
begin
  Result := nil;
  Handle := OpenFile(HostsFilePath, OpenRead);
  if Handle < 0 then
    Exit;
  Result := GetMem(MaximumHostsFileBytes + 1);
  Used := 0;
  repeat
    Read := ReadFile(Handle, Result + Used, MaximumHostsFileBytes - Used);
    if Read > 0 then
      Used := Used + Read;
  until (Read <= 0) or (Used >= MaximumHostsFileBytes);
  CloseFile(Handle);
  Result[Used] := #0;
end;

{ Splits Text[Start..] up to the line's end into words (cutting them
  in place); the next line's start is returned. }
function SplitLine(Text: PChar; Start: PtrUInt; out Line: THostsLine): PtrUInt;
var
  Position: PtrUInt;
  InComment: Boolean;
begin
  Line.WordCount := 0;
  Position := Start;
  InComment := False;
  while (Text[Position] <> #0) and (Text[Position] <> #10) do
  begin
    if Text[Position] = '#' then
      InComment := True;
    if InComment or IsSpace(Text[Position]) then
    begin
      Text[Position] := #0;
      Inc(Position);
      Continue;
    end;
    if (Position = Start) or (Text[Position - 1] = #0) then
      if Line.WordCount <= High(Line.Words) then
      begin
        Line.Words[Line.WordCount] := @Text[Position];
        Inc(Line.WordCount);
      end;
    Inc(Position);
  end;
  if Text[Position] = #10 then
  begin
    Text[Position] := #0;
    Inc(Position);
  end;
  Result := Position;
end;

{ Calls Visitor for every line with an address and a name, until it
  returns False. }
procedure VisitHostsFile(Visitor: TLineVisitor; Context: Pointer);
var
  Text: PChar;
  Position: PtrUInt;
  Line: THostsLine;
begin
  Text := ReadHostsFile;
  if Text = nil then
    Exit;
  try
    Position := 0;
    while Text[Position] <> #0 do
    begin
      Position := SplitLine(Text, Position, Line);
      if (Line.WordCount >= 2) and not Visitor(Line, Context) then
        Break;
    end;
  finally
    FreeMem(Text);
  end;
end;

type
  TNameSearch = record
    Name: PChar;
    Families: LongWord;
    Found: ^THostsFileAddresses;
  end;
  PNameSearch = ^TNameSearch;

  TAddressSearch = record
    Address: TInternetAddress;
    Name: ^TDnsName;
    Found: Boolean;
  end;
  PAddressSearch = ^TAddressSearch;

function FamilyIsWanted(constref Address: TInternetAddress; Families: LongWord): Boolean;
begin
  Result := ((Address.Family = AddressFamilyIPv4) and ((Families and FamilyBitIpv4) <> 0)) or
    ((Address.Family = AddressFamilyIPv6) and ((Families and FamilyBitIpv6) <> 0));
end;

function VisitForName(constref Line: THostsLine; Context: Pointer): Boolean;
var
  Search: PNameSearch;
  Address: TInternetAddress;
  Index: Integer;
begin
  Result := True;
  Search := PNameSearch(Context);
  if not ParseInternetAddress(Line.Words[0], Address) or not FamilyIsWanted(Address, Search^.Families) then
    Exit;
  for Index := 1 to Line.WordCount - 1 do
    if DnsNamesAreEqual(Line.Words[Index], Search^.Name) then
    begin
      if Search^.Found^.Count = 0 then
        CopyText(@Search^.Found^.CanonicalName[0], Line.Words[1], DnsNameCapacity);
      if Search^.Found^.Count <= High(Search^.Found^.Addresses) then
      begin
        Search^.Found^.Addresses[Search^.Found^.Count] := Address;
        Inc(Search^.Found^.Count);
      end;
      Exit;
    end;
end;

function VisitForAddress(constref Line: THostsLine; Context: Pointer): Boolean;
var
  Search: PAddressSearch;
  Address: TInternetAddress;
begin
  Search := PAddressSearch(Context);
  Result := True;
  if ParseInternetAddress(Line.Words[0], Address) and AddressesAreEqual(Address, Search^.Address) then
  begin
    CopyText(@Search^.Name^[0], Line.Words[1], DnsNameCapacity);
    Search^.Found := True;
    Result := False;
  end;
end;

function LookUpHostsFileName(Name: PChar; Families: LongWord; out Found: THostsFileAddresses): Boolean;
var
  Search: TNameSearch;
begin
  Found.Count := 0;
  Found.CanonicalName[0] := #0;
  Search.Name := Name;
  Search.Families := Families;
  Search.Found := @Found;
  VisitHostsFile(@VisitForName, @Search);
  Result := Found.Count > 0;
end;

function LookUpHostsFileAddress(constref Address: TInternetAddress; out Name: TDnsName): Boolean;
var
  Search: TAddressSearch;
begin
  Name[0] := #0;
  Search.Address := Address;
  Search.Name := @Name;
  Search.Found := False;
  VisitHostsFile(@VisitForAddress, @Search);
  Result := Search.Found;
end;

end.
