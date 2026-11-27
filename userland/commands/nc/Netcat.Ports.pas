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
{$H+}

interface

{ A port from 1 to 65535. }
function ParsePort(const Text: string; out Port: Word): Boolean;
{ "PORT" (First = Last) or "FIRST-LAST" with First <= Last. }
function ParsePortRange(const Text: string; out First, Last: Word): Boolean;

implementation

uses
  Util.Numbers;

function ParsePort(const Text: string; out Port: Word): Boolean;
var
  Value: QWord;
begin
  Port := 0;
  if not ParseUnsignedDecimal(Text, Value) or (Value = 0) or (Value > 65535) then
    Exit(False);
  Port := Word(Value);
  Result := True;
end;

function ParsePortRange(const Text: string; out First, Last: Word): Boolean;
var
  Dash: Integer;
begin
  First := 0;
  Last := 0;
  Dash := Pos('-', Text);
  if Dash = 0 then
  begin
    Result := ParsePort(Text, First);
    Last := First;
    Exit;
  end;
  Result := ParsePort(Copy(Text, 1, Dash - 1), First) and ParsePort(Copy(Text, Dash + 1, MaxInt), Last) and
    (First <= Last);
end;

end.
