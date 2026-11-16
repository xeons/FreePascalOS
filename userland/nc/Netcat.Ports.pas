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
  Ports as nc takes them: "80", or a range "20-30".
}
unit Netcat.Ports;

{$mode objfpc}

interface

{ A port from 1 to 65535. }
function ParsePort(Text: PChar; out Port: Word): Boolean;
{ "PORT" (First = Last) or "FIRST-LAST" with First <= Last. }
function ParsePortRange(Text: PChar; out First, Last: Word): Boolean;

implementation

uses
  Runtime.Text,
  Sys.Text;

const
  RangeTextCapacity = 16;

function ParsePort(Text: PChar; out Port: Word): Boolean;
var
  Value: QWord;
begin
  Port := 0;
  if not ParseUnsigned(Text, Value) or (Value = 0) or (Value > 65535) then
    Exit(False);
  Port := Word(Value);
  Result := True;
end;

function ParsePortRange(Text: PChar; out First, Last: Word): Boolean;
var
  Dash: PtrInt;
  FirstText: array[0..RangeTextCapacity - 1] of Char;
begin
  First := 0;
  Last := 0;
  Dash := FindCharacter(Text, '-');
  if Dash < 0 then
  begin
    Result := ParsePort(Text, First);
    Last := First;
    Exit;
  end;
  if Dash >= RangeTextCapacity then
    Exit(False);
  CopyText(@FirstText[0], Text, Dash + 1);
  Result := ParsePort(@FirstText[0], First) and ParsePort(Text + Dash + 1, Last) and (First <= Last);
end;

end.
