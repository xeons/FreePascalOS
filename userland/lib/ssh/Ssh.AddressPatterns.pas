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
  OpenSSH's pattern lists, as authorized_keys from=, sshd_config Match
  and a certificate's source-address use them:

    pattern      * matches any run of characters, ? any one
    list         patterns separated by commas; one with ! in front
                 that matches refuses the whole list
    address      a pattern, or ADDRESS/BITS (CIDR) for IPv4 or IPv6

  An IPv4 address mapped into IPv6 (::ffff:10.0.0.1) is matched as the
  IPv4 address. Nothing here looks names up: an address is matched as
  the text of its numbers (as OpenSSH does with UseDNS no, its default).
}
unit Ssh.AddressPatterns;

{$mode objfpc}{$H+}

interface

type
  TPatternListResult = (PatternListNoMatch, PatternListMatch, PatternListRefused);

{ Text against a pattern with * and ?. }
function MatchWildcard(const Text, Pattern: string; CaseSensitive: Boolean): Boolean;
{ Text against a comma separated list with ! negations. }
function MatchPatternList(const Text, List: string; CaseSensitive: Boolean): TPatternListResult;
{ An address (text) against a list of patterns and CIDR blocks. }
function MatchAddressList(const Address, List: string): TPatternListResult;
{ Whether every entry of List is an address or a CIDR block (no
  wildcards): the form of source-address. }
function IsAddressList(const List: string): Boolean;
{ IPv4 as 4 bytes, IPv6 as 16 (a mapped IPv4 address as its 4). }
function ParseAddressBytes(const Text: string; out Bytes: string): Boolean;
function AddressInBlock(const Address, Block: string): Boolean;

implementation

uses
  SysUtils;

function MatchWildcard(const Text, Pattern: string; CaseSensitive: Boolean): Boolean;
var
  TextIndex, PatternIndex, StarPattern, StarText: Integer;
  Subject, Shape: string;
begin
  if CaseSensitive then
  begin
    Subject := Text;
    Shape := Pattern;
  end
  else
  begin
    Subject := LowerCase(Text);
    Shape := LowerCase(Pattern);
  end;
  TextIndex := 1;
  PatternIndex := 1;
  StarPattern := 0;
  StarText := 0;
  while TextIndex <= Length(Subject) do
  begin
    if (PatternIndex <= Length(Shape)) and ((Shape[PatternIndex] = '?') or
      ((Shape[PatternIndex] <> '*') and (Shape[PatternIndex] = Subject[TextIndex]))) then
    begin
      Inc(TextIndex);
      Inc(PatternIndex);
    end
    else if (PatternIndex <= Length(Shape)) and (Shape[PatternIndex] = '*') then
    begin
      StarPattern := PatternIndex;
      StarText := TextIndex;
      Inc(PatternIndex);
    end
    else if StarPattern > 0 then
    begin
      PatternIndex := StarPattern + 1;
      Inc(StarText);
      TextIndex := StarText;
    end
    else
      Exit(False);
  end;
  while (PatternIndex <= Length(Shape)) and (Shape[PatternIndex] = '*') do
    Inc(PatternIndex);
  Result := PatternIndex > Length(Shape);
end;

function SplitList(const List: string): TStringArray;
var
  Start, Index: Integer;
  Entry: string;
begin
  Result := nil;
  Start := 1;
  for Index := 1 to Length(List) + 1 do
    if (Index > Length(List)) or (List[Index] = ',') then
    begin
      Entry := Trim(Copy(List, Start, Index - Start));
      if Entry <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Entry;
      end;
      Start := Index + 1;
    end;
end;

function MatchPatternList(const Text, List: string; CaseSensitive: Boolean): TPatternListResult;
var
  Entries: TStringArray;
  Index: Integer;
  Entry: string;
  Negated: Boolean;
begin
  Result := PatternListNoMatch;
  Entries := SplitList(List);
  for Index := 0 to High(Entries) do
  begin
    Entry := Entries[Index];
    Negated := Entry[1] = '!';
    if Negated then
      Delete(Entry, 1, 1);
    if MatchWildcard(Text, Entry, CaseSensitive) then
    begin
      if Negated then
        Exit(PatternListRefused);
      Result := PatternListMatch;
    end;
  end;
end;

function ParseIpv4(const Text: string; out Bytes: string): Boolean;
var
  Parts: TStringArray;
  Index, Value: Integer;
begin
  Bytes := '';
  Parts := Text.Split(['.']);
  if Length(Parts) <> 4 then
    Exit(False);
  for Index := 0 to 3 do
  begin
    if (Parts[Index] = '') or (Length(Parts[Index]) > 3) or not TryStrToInt(Parts[Index], Value) or
      (Value < 0) or (Value > 255) or (Parts[Index][1] in ['+', '-']) then
      Exit(False);
    Bytes := Bytes + Chr(Value);
  end;
  Result := True;
end;

function ParseHexGroup(const Text: string; out Value: Integer): Boolean;
var
  Index: Integer;
begin
  Value := 0;
  if (Text = '') or (Length(Text) > 4) then
    Exit(False);
  for Index := 1 to Length(Text) do
    case Text[Index] of
      '0'..'9': Value := Value * 16 + Ord(Text[Index]) - Ord('0');
      'a'..'f': Value := Value * 16 + Ord(Text[Index]) - Ord('a') + 10;
      'A'..'F': Value := Value * 16 + Ord(Text[Index]) - Ord('A') + 10;
    else
      Exit(False);
    end;
  Result := True;
end;

{ Groups of hexadecimal (and a dotted IPv4 tail) into bytes. }
function ParseGroups(const Text: string; out Bytes: string): Boolean;
var
  Groups: TStringArray;
  Index, Value: Integer;
  Tail: string;
begin
  Bytes := '';
  if Text = '' then
    Exit(True);
  Groups := Text.Split([':']);
  for Index := 0 to High(Groups) do
  begin
    if (Index = High(Groups)) and (Pos('.', Groups[Index]) > 0) then
    begin
      if not ParseIpv4(Groups[Index], Tail) then
        Exit(False);
      Bytes := Bytes + Tail;
      Continue;
    end;
    if not ParseHexGroup(Groups[Index], Value) then
      Exit(False);
    Bytes := Bytes + Chr(Value shr 8) + Chr(Value and $FF);
  end;
  Result := True;
end;

function ParseIpv6(const Text: string; out Bytes: string): Boolean;
var
  Gap: Integer;
  Head, Tail: string;
begin
  Bytes := '';
  Gap := Pos('::', Text);
  if Gap > 0 then
  begin
    if Pos('::', Copy(Text, Gap + 2, MaxInt)) > 0 then
      Exit(False);
    if not ParseGroups(Copy(Text, 1, Gap - 1), Head) or not ParseGroups(Copy(Text, Gap + 2, MaxInt), Tail) then
      Exit(False);
    if Length(Head) + Length(Tail) > 14 then
      Exit(False);
    Bytes := Head + StringOfChar(#0, 16 - Length(Head) - Length(Tail)) + Tail;
  end
  else
  begin
    if not ParseGroups(Text, Bytes) then
      Exit(False);
  end;
  Result := Length(Bytes) = 16;
end;

function ParseAddressBytes(const Text: string; out Bytes: string): Boolean;
var
  Bare: string;
  Percent: Integer;
begin
  Bare := Text;
  if (Bare <> '') and (Bare[1] = '[') and (Bare[Length(Bare)] = ']') then
    Bare := Copy(Bare, 2, Length(Bare) - 2);
  { A zone (fe80::1%eth0) does not take part. }
  Percent := Pos('%', Bare);
  if Percent > 0 then
    Bare := Copy(Bare, 1, Percent - 1);
  if Pos(':', Bare) = 0 then
    Exit(ParseIpv4(Bare, Bytes));
  Result := ParseIpv6(Bare, Bytes);
  if Result and (Copy(Bytes, 1, 12) = StringOfChar(#0, 10) + #$FF#$FF) then
    Bytes := Copy(Bytes, 13, 4);
end;

function AddressInBlock(const Address, Block: string): Boolean;
var
  Slash, Bits, Index: Integer;
  AddressBytes, BlockBytes: string;
  Mask: Byte;
begin
  Result := False;
  Slash := Pos('/', Block);
  if Slash = 0 then
  begin
    Result := ParseAddressBytes(Address, AddressBytes) and ParseAddressBytes(Block, BlockBytes) and
      (AddressBytes = BlockBytes);
    Exit;
  end;
  if not TryStrToInt(Copy(Block, Slash + 1, MaxInt), Bits) then
    Exit;
  if not ParseAddressBytes(Address, AddressBytes) or not ParseAddressBytes(Copy(Block, 1, Slash - 1), BlockBytes) then
    Exit;
  if (Length(AddressBytes) <> Length(BlockBytes)) or (Bits < 0) or (Bits > 8 * Length(BlockBytes)) then
    Exit;
  for Index := 1 to Length(BlockBytes) do
  begin
    if Bits >= 8 then
      Mask := $FF
    else if Bits <= 0 then
      Mask := 0
    else
      Mask := Byte($FF shl (8 - Bits));
    if (Ord(AddressBytes[Index]) and Mask) <> (Ord(BlockBytes[Index]) and Mask) then
      Exit;
    Dec(Bits, 8);
  end;
  Result := True;
end;

function MatchAddressList(const Address, List: string): TPatternListResult;
var
  Entries: TStringArray;
  Index: Integer;
  Entry: string;
  Negated, Matches: Boolean;
begin
  Result := PatternListNoMatch;
  Entries := SplitList(List);
  for Index := 0 to High(Entries) do
  begin
    Entry := Entries[Index];
    Negated := Entry[1] = '!';
    if Negated then
      Delete(Entry, 1, 1);
    if Pos('/', Entry) > 0 then
      Matches := AddressInBlock(Address, Entry)
    else if (Pos('*', Entry) = 0) and (Pos('?', Entry) = 0) then
      Matches := AddressInBlock(Address, Entry) or MatchWildcard(Address, Entry, False)
    else
      Matches := MatchWildcard(Address, Entry, False);
    if Matches then
    begin
      if Negated then
        Exit(PatternListRefused);
      Result := PatternListMatch;
    end;
  end;
end;

function IsAddressList(const List: string): Boolean;
var
  Entries: TStringArray;
  Index, Slash: Integer;
  Bytes: string;
begin
  Entries := SplitList(List);
  Result := Length(Entries) > 0;
  for Index := 0 to High(Entries) do
  begin
    Slash := Pos('/', Entries[Index]);
    if Slash = 0 then
      Slash := Length(Entries[Index]) + 1;
    if not ParseAddressBytes(Copy(Entries[Index], 1, Slash - 1), Bytes) then
      Exit(False);
  end;
end;

end.
