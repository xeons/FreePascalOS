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
  Domain names as DNS carries them (RFC 1035, 4.1.4): a sequence of
  labels, each a length byte and up to 63 bytes, ended by a zero byte;
  in a message a name may end instead with a pointer (two bytes, the top
  bits set) to where the rest of it was written before.

  Text names are written with dots between the labels and without the
  final dot ("www.example.com"; the root is "."). Reading a name from a
  message follows its pointers, but only backwards and at most
  MaximumNamePointers of them, so a message whose pointers go round in
  a circle (or forwards) is refused rather than read forever; a name
  longer than 255 bytes is refused as well. Bytes in a label that are
  not printable, and dots and backslashes in one, are written \DDD in
  decimal as other tools do.
}
unit Sys.DnsNames;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Sys.InternetAddresses;

const
  { On the wire: the length bytes included. }
  MaximumDnsNameBytes = 255;
  MaximumDnsLabelBytes = 63;
  MaximumNamePointers = 64;

{ Writes Name (text, the final dot allowed) at Buffer[Position] in wire
  form, without compression; Position moves past it. False if a label
  is empty or too long, the name is too long, or it does not fit in
  Capacity. }
function EncodeDnsName(const Name: string; Buffer: PByte; Capacity: LongWord; var Position: LongWord): Boolean;
{ Reads the name at Message[Position] (Length bytes in all), following
  pointers; Position moves past the name where it was written (past its
  first pointer, if it has one). False for a damaged name. }
function DecodeDnsName(Message: PByte; Length: LongWord; var Position: LongWord; out Name: string): Boolean;
{ Steps over the name at Message[Position] without keeping it. }
function SkipDnsName(Message: PByte; Length: LongWord; var Position: LongWord): Boolean;

{ The same name: letters compared without case, a final dot ignored. }
function DnsNamesAreEqual(const First, Second: string): Boolean;
{ True if Name has no dot (but for a final one): a single label, which
  the search domain is tried for. }
function IsSingleLabelName(const Name: string): Boolean;
{ Name (without a final dot), a dot and Domain. }
function JoinDnsNames(const Name, Domain: string): string;
{ The name a reverse lookup asks for: "15.2.0.10.in-addr.arpa" for
  10.0.2.15, the nibbles under "ip6.arpa" for IPv6. }
function ReverseLookupName(constref Address: TInternetAddress; out Name: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls;

const
  PointerMask = $C0;
  LowerHexDigits = '0123456789abcdef';

function EncodeDnsName(const Name: string; Buffer: PByte; Capacity: LongWord; var Position: LongWord): Boolean;
var
  Start: LongWord;
  LabelStart: Integer;
  LabelLength: LongWord;
  Index: LongWord;
  Cursor: Integer;
begin
  Result := False;
  Start := Position;
  Cursor := 1;
  { The root, "." or "". }
  if Name = '.' then
    Cursor := 2;
  while Cursor <= Length(Name) do
  begin
    LabelStart := Cursor;
    while (Cursor <= Length(Name)) and (Name[Cursor] <> '.') do
      Inc(Cursor);
    LabelLength := LongWord(Cursor - LabelStart);
    if (LabelLength = 0) or (LabelLength > MaximumDnsLabelBytes) then
      Exit;
    if (Position - Start) + 1 + LabelLength + 1 > MaximumDnsNameBytes then
      Exit;
    if Position + 1 + LabelLength + 1 > Capacity then
      Exit;
    Buffer[Position] := Byte(LabelLength);
    Inc(Position);
    for Index := 0 to LabelLength - 1 do
      Buffer[Position + Index] := Byte(Name[LabelStart + Integer(Index)]);
    Position := Position + LabelLength;
    { Past the dot. }
    Inc(Cursor);
  end;
  if Position + 1 > Capacity then
    Exit;
  Buffer[Position] := 0;
  Inc(Position);
  Result := True;
end;

{ A label's byte as text: itself, or \DDD. }
function LabelByteText(Value: Byte): string;
begin
  if (Value > 32) and (Value < 127) and (Value <> Ord('.')) and (Value <> Ord('\')) then
    Result := Char(Value)
  else
    Result := '\' + Format('%.3d', [Value]);
end;

function DecodeDnsName(Message: PByte; Length: LongWord; var Position: LongWord; out Name: string): Boolean;
var
  Cursor: LongWord;
  LabelLength: LongWord;
  Target: LongWord;
  Pointers: Integer;
  WireBytes: LongWord;
  Index: LongWord;
  { Where the name continues in place once a pointer was taken. }
  EndInPlace: LongWord;
  { Pointers must go before this: strictly backwards. }
  Lowest: LongWord;
begin
  Result := False;
  Name := '';
  Cursor := Position;
  Lowest := Position;
  Pointers := 0;
  WireBytes := 0;
  EndInPlace := 0;
  repeat
    if Cursor >= Length then
      Exit;
    LabelLength := Message[Cursor];
    if (LabelLength and PointerMask) = PointerMask then
    begin
      if Cursor + 1 >= Length then
        Exit;
      Target := ((LabelLength and $3F) shl 8) or Message[Cursor + 1];
      if Pointers = 0 then
        EndInPlace := Cursor + 2;
      Inc(Pointers);
      if (Pointers > MaximumNamePointers) or (Target >= Lowest) then
        Exit;
      Lowest := Target;
      Cursor := Target;
      Continue;
    end;
    if (LabelLength and PointerMask) <> 0 then
      Exit;
    WireBytes := WireBytes + LabelLength + 1;
    if WireBytes > MaximumDnsNameBytes then
      Exit;
    if LabelLength = 0 then
    begin
      Inc(Cursor);
      Break;
    end;
    if Cursor + 1 + LabelLength > Length then
      Exit;
    if Name <> '' then
      Name := Name + '.';
    for Index := 1 to LabelLength do
      Name := Name + LabelByteText(Message[Cursor + Index]);
    Cursor := Cursor + 1 + LabelLength;
  until False;
  if Name = '' then
    Name := '.';
  if Pointers > 0 then
    Position := EndInPlace
  else
    Position := Cursor;
  Result := True;
end;

function SkipDnsName(Message: PByte; Length: LongWord; var Position: LongWord): Boolean;
var
  Name: string;
begin
  Result := DecodeDnsName(Message, Length, Position, Name);
end;

{ Name without a final dot (the root "." stays as it is). }
function WithoutFinalDot(const Name: string): string;
begin
  if (Length(Name) > 1) and (Name[Length(Name)] = '.') then
    Result := Copy(Name, 1, Length(Name) - 1)
  else
    Result := Name;
end;

function DnsNamesAreEqual(const First, Second: string): Boolean;
begin
  Result := SameText(WithoutFinalDot(First), WithoutFinalDot(Second));
end;

function IsSingleLabelName(const Name: string): Boolean;
var
  Position: Integer;
begin
  if Name = '' then
    Exit(False);
  Position := Pos('.', Name);
  Result := (Position = 0) or (Position = Length(Name));
end;

function JoinDnsNames(const Name, Domain: string): string;
begin
  if (Name <> '') and (Name[Length(Name)] = '.') then
    Result := Copy(Name, 1, Length(Name) - 1) + '.' + Domain
  else
    Result := Name + '.' + Domain;
end;

function ReverseLookupName(constref Address: TInternetAddress; out Name: string): Boolean;
var
  Index: Integer;
begin
  Name := '';
  case Address.Family of
    AddressFamilyIPv4:
      begin
        for Index := 3 downto 0 do
          Name := Name + IntToStr(Address.Bytes[Index]) + '.';
        Name := Name + 'in-addr.arpa';
      end;
    AddressFamilyIPv6:
      begin
        for Index := 15 downto 0 do
          Name := Name + LowerHexDigits[(Address.Bytes[Index] and $F) + 1] + '.' +
            LowerHexDigits[(Address.Bytes[Index] shr 4) + 1] + '.';
        Name := Name + 'ip6.arpa';
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

end.
