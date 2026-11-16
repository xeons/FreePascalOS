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
{$pointermath on}

interface

uses
  Sys.InternetAddresses;

const
  { A name as text, with its terminator: the longest name, with room for
    some \DDD (more are cut off). }
  DnsNameCapacity = 320;
  { On the wire: the length bytes included. }
  MaximumDnsNameBytes = 255;
  MaximumDnsLabelBytes = 63;
  MaximumNamePointers = 64;

type
  TDnsName = array[0..DnsNameCapacity - 1] of Char;

{ Writes Name (text, the final dot allowed) at Buffer[Position] in wire
  form, without compression; Position moves past it. False if a label
  is empty or too long, the name is too long, or it does not fit in
  Capacity. }
function EncodeDnsName(Name: PChar; Buffer: PByte; Capacity: LongWord; var Position: LongWord): Boolean;
{ Reads the name at Message[Position] (Length bytes in all), following
  pointers; Position moves past the name where it was written (past its
  first pointer, if it has one). False for a damaged name. }
function DecodeDnsName(Message: PByte; Length: LongWord; var Position: LongWord; out Name: TDnsName): Boolean;
{ Steps over the name at Message[Position] without reading it. }
function SkipDnsName(Message: PByte; Length: LongWord; var Position: LongWord): Boolean;

{ The same name: letters compared without case, a final dot ignored. }
function DnsNamesAreEqual(First, Second: PChar): Boolean;
{ True if Name has no dot (but for a final one): a single label, which
  the search domain is tried for. }
function IsSingleLabelName(Name: PChar): Boolean;
{ Name, a dot and Domain. False if it does not fit. }
function JoinDnsNames(Name, Domain: PChar; out Joined: TDnsName): Boolean;
{ The name a reverse lookup asks for: "15.2.0.10.in-addr.arpa" for
  10.0.2.15, the nibbles under "ip6.arpa" for IPv6. }
function ReverseLookupName(constref Address: TInternetAddress; out Name: TDnsName): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Text;

const
  PointerMask = $C0;

function EncodeDnsName(Name: PChar; Buffer: PByte; Capacity: LongWord; var Position: LongWord): Boolean;
var
  Start: LongWord;
  LabelStart: PtrUInt;
  LabelLength: PtrUInt;
  Index: PtrUInt;
  Cursor: PtrUInt;
begin
  Result := False;
  Start := Position;
  Cursor := 0;
  { The root, "." or "". }
  if (Name[0] = '.') and (Name[1] = #0) then
    Cursor := 1;
  while Name[Cursor] <> #0 do
  begin
    LabelStart := Cursor;
    while (Name[Cursor] <> #0) and (Name[Cursor] <> '.') do
      Inc(Cursor);
    LabelLength := Cursor - LabelStart;
    if (LabelLength = 0) or (LabelLength > MaximumDnsLabelBytes) then
      Exit;
    if (Position - Start) + 1 + LabelLength + 1 > MaximumDnsNameBytes then
      Exit;
    if Position + 1 + LabelLength + 1 > Capacity then
      Exit;
    Buffer[Position] := Byte(LabelLength);
    Inc(Position);
    for Index := 0 to LabelLength - 1 do
      Buffer[Position + Index] := Byte(Name[LabelStart + Index]);
    Position := Position + LongWord(LabelLength);
    if Name[Cursor] = '.' then
      Inc(Cursor);
  end;
  if Position + 1 > Capacity then
    Exit;
  Buffer[Position] := 0;
  Inc(Position);
  Result := True;
end;

procedure AppendNameCharacter(var Name: TDnsName; var Used: PtrUInt; Character: Char);
begin
  if Used + 1 < DnsNameCapacity then
  begin
    Name[Used] := Character;
    Inc(Used);
    Name[Used] := #0;
  end;
end;

{ A label's byte as text: itself, or \DDD. }
procedure AppendLabelByte(var Name: TDnsName; var Used: PtrUInt; Value: Byte);
begin
  if (Value > 32) and (Value < 127) and (Value <> Ord('.')) and (Value <> Ord('\')) then
  begin
    AppendNameCharacter(Name, Used, Char(Value));
    Exit;
  end;
  AppendNameCharacter(Name, Used, '\');
  AppendNameCharacter(Name, Used, Char(Ord('0') + Value div 100));
  AppendNameCharacter(Name, Used, Char(Ord('0') + (Value div 10) mod 10));
  AppendNameCharacter(Name, Used, Char(Ord('0') + Value mod 10));
end;

function DecodeDnsName(Message: PByte; Length: LongWord; var Position: LongWord; out Name: TDnsName): Boolean;
var
  Cursor: LongWord;
  LabelLength: LongWord;
  Target: LongWord;
  Pointers: Integer;
  WireBytes: LongWord;
  Used: PtrUInt;
  Index: LongWord;
  { Where the name continues in place once a pointer was taken. }
  EndInPlace: LongWord;
  { Pointers must go before this: strictly backwards. }
  Lowest: LongWord;
begin
  Result := False;
  Name[0] := #0;
  Used := 0;
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
    if Used > 0 then
      AppendNameCharacter(Name, Used, '.');
    for Index := 1 to LabelLength do
      AppendLabelByte(Name, Used, Message[Cursor + Index]);
    Cursor := Cursor + 1 + LabelLength;
  until False;
  if Used = 0 then
    AppendNameCharacter(Name, Used, '.');
  if Pointers > 0 then
    Position := EndInPlace
  else
    Position := Cursor;
  Result := True;
end;

function SkipDnsName(Message: PByte; Length: LongWord; var Position: LongWord): Boolean;
var
  Name: TDnsName;
begin
  Result := DecodeDnsName(Message, Length, Position, Name);
end;

function DnsNamesAreEqual(First, Second: PChar): Boolean;
var
  Index: PtrUInt;
  FirstLength: PtrUInt;
  SecondLength: PtrUInt;
begin
  FirstLength := TextLength(First);
  SecondLength := TextLength(Second);
  if (FirstLength > 1) and (First[FirstLength - 1] = '.') then
    Dec(FirstLength);
  if (SecondLength > 1) and (Second[SecondLength - 1] = '.') then
    Dec(SecondLength);
  if FirstLength <> SecondLength then
    Exit(False);
  Index := 0;
  while Index < FirstLength do
  begin
    if ToLowerCase(First[Index]) <> ToLowerCase(Second[Index]) then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function IsSingleLabelName(Name: PChar): Boolean;
var
  Position: PtrInt;
  Length: PtrUInt;
begin
  Length := TextLength(Name);
  if Length = 0 then
    Exit(False);
  Position := FindCharacter(Name, '.');
  Result := (Position < 0) or (PtrUInt(Position) = Length - 1);
end;

function JoinDnsNames(Name, Domain: PChar; out Joined: TDnsName): Boolean;
var
  NameLength: PtrUInt;
  DomainLength: PtrUInt;
begin
  Joined[0] := #0;
  NameLength := TextLength(Name);
  if (NameLength > 0) and (Name[NameLength - 1] = '.') then
    Dec(NameLength);
  DomainLength := TextLength(Domain);
  if NameLength + 1 + DomainLength + 1 > DnsNameCapacity then
    Exit(False);
  CopyMemory(@Joined[0], Name, NameLength);
  Joined[NameLength] := '.';
  CopyMemory(@Joined[NameLength + 1], Domain, DomainLength);
  Joined[NameLength + 1 + DomainLength] := #0;
  Result := True;
end;

procedure AppendText(var Name: TDnsName; var Used: PtrUInt; Text: PChar);
var
  Index: PtrUInt;
begin
  Index := 0;
  while Text[Index] <> #0 do
  begin
    AppendNameCharacter(Name, Used, Text[Index]);
    Inc(Index);
  end;
end;

function ReverseLookupName(constref Address: TInternetAddress; out Name: TDnsName): Boolean;
const
  LowerDigits: PChar = '0123456789abcdef';
var
  Used: PtrUInt;
  Index: Integer;
  Number: TNumberText;
begin
  Name[0] := #0;
  Used := 0;
  case Address.Family of
    AddressFamilyIPv4:
      begin
        for Index := 3 downto 0 do
        begin
          AppendText(Name, Used, FormatDecimal(Address.Bytes[Index], Number));
          AppendNameCharacter(Name, Used, '.');
        end;
        AppendText(Name, Used, 'in-addr.arpa');
      end;
    AddressFamilyIPv6:
      begin
        for Index := 15 downto 0 do
        begin
          AppendNameCharacter(Name, Used, LowerDigits[Address.Bytes[Index] and $F]);
          AppendNameCharacter(Name, Used, '.');
          AppendNameCharacter(Name, Used, LowerDigits[Address.Bytes[Index] shr 4]);
          AppendNameCharacter(Name, Used, '.');
        end;
        AppendText(Name, Used, 'ip6.arpa');
      end;
  else
    Exit(False);
  end;
  Result := True;
end;

end.
