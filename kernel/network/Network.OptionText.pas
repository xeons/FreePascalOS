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
  Reading addresses written in kernel options: "192.168.1.20",
  "192.168.1.20:5140", "192.168.1.50/24". Each reader takes the text at
  Position, moves Position past what it read, and fails (leaving the
  result zero) on anything else.
}
unit Network.OptionText;

{$mode objfpc}

interface

uses
  Network.Addresses;

{ A dotted IPv4 address. }
function ReadIpv4Text(var Position: PChar; out Address: TIpv4Address): Boolean;
{ A decimal number no larger than Largest. }
function ReadNumberText(var Position: PChar; Largest: LongWord; out Number: LongWord): Boolean;
{ Writes Address as dotted text into Text (at least 16 characters). }
procedure FormatIpv4Text(Address: TIpv4Address; Text: PChar);

implementation

uses
  Runtime.Text;

function ReadNumberText(var Position: PChar; Largest: LongWord; out Number: LongWord): Boolean;
var
  Value: QWord;
  Digits: Integer;
begin
  Number := 0;
  Value := 0;
  Digits := 0;
  while (Position^ in ['0'..'9']) and (Digits < 10) do
  begin
    Value := Value * 10 + QWord(Ord(Position^) - Ord('0'));
    Inc(Position);
    Inc(Digits);
  end;
  Result := (Digits > 0) and (Value <= Largest);
  if Result then
    Number := LongWord(Value);
end;

function ReadIpv4Text(var Position: PChar; out Address: TIpv4Address): Boolean;
var
  Part: LongWord;
  Index: Integer;
  Value: TIpv4Address;
begin
  Address := AnyAddress;
  Value := 0;
  for Index := 1 to 4 do
  begin
    if not ReadNumberText(Position, 255, Part) then
      Exit(False);
    Value := (Value shl 8) or Part;
    if Index < 4 then
    begin
      if Position^ <> '.' then
        Exit(False);
      Inc(Position);
    end;
  end;
  Address := Value;
  Result := True;
end;

procedure FormatIpv4Text(Address: TIpv4Address; Text: PChar);
var
  Index: Integer;
  Number: TNumberText;
  Part: PChar;
begin
  Text^ := #0;
  for Index := 3 downto 0 do
  begin
    Part := FormatDecimal((Address shr (Index * 8)) and $FF, Number);
    while Part^ <> #0 do
    begin
      Text^ := Part^;
      Inc(Text);
      Inc(Part);
    end;
    if Index > 0 then
    begin
      Text^ := '.';
      Inc(Text);
    end;
  end;
  Text^ := #0;
end;

end.
