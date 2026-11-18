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
  What the SSH host tests share: byte strings from and to hexadecimal,
  and checking two byte strings are equal.
}
unit SshTest.Helpers;

{$mode objfpc}
{$H+}

interface

function FromHex(const Hex: string): string;
function ToHex(const Data: string): string;
procedure CheckEqual(const Actual, Expected: string; const Name: string);

implementation

uses
  TestChecks;

function FromHex(const Hex: string): string;
var
  Bytes: TByteArray;
  Index: Integer;
begin
  Bytes := HexToBytes(Hex);
  Result := '';
  SetLength(Result, Length(Bytes));
  for Index := 0 to High(Bytes) do
    Result[Index + 1] := Chr(Bytes[Index]);
end;

function ToHex(const Data: string): string;
begin
  if Data = '' then
    Result := ''
  else
    Result := BytesToHex(@Data[1], Length(Data));
end;

procedure CheckEqual(const Actual, Expected: string; const Name: string);
begin
  Check(Actual = Expected, Name);
  if Actual <> Expected then
  begin
    WriteLn('     expected ', ToHex(Expected));
    WriteLn('     got      ', ToHex(Actual));
  end;
end;

end.
