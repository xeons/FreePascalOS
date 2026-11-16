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
  What the host side tests of the cryptography and TLS libraries share:
  counting checks, printing failures, and hexadecimal test vectors.
}
unit TestChecks;

{$mode objfpc}
{$H+}

interface

type
  TByteArray = array of Byte;

var
  PassedChecks: Integer = 0;
  FailedChecks: Integer = 0;

procedure Check(Condition: Boolean; const Name: string);
{ Checks that Count bytes at Actual are the hexadecimal Expected. }
procedure CheckBytes(Actual: PByte; Count: Integer; const ExpectedHex: string; const Name: string);
function HexToBytes(const Hex: string): TByteArray;
function BytesToHex(Bytes: PByte; Count: Integer): string;
function TextBytes(const Text: string): TByteArray;
{ Prints the totals; the exit code is 1 if anything failed. }
procedure FinishChecks(const Title: string);

implementation

procedure Check(Condition: Boolean; const Name: string);
begin
  if Condition then
  begin
    Inc(PassedChecks);
    WriteLn('ok   ', Name);
  end
  else
  begin
    Inc(FailedChecks);
    WriteLn('FAIL ', Name);
  end;
end;

function HexDigit(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function HexToBytes(const Hex: string): TByteArray;
var
  Digits: string;
  Index: Integer;
begin
  Result := nil;
  Digits := '';
  for Index := 1 to Length(Hex) do
    if HexDigit(Hex[Index]) >= 0 then
      Digits := Digits + Hex[Index];
  SetLength(Result, Length(Digits) div 2);
  for Index := 0 to Length(Result) - 1 do
    Result[Index] := HexDigit(Digits[2 * Index + 1]) * 16 + HexDigit(Digits[2 * Index + 2]);
end;

function BytesToHex(Bytes: PByte; Count: Integer): string;
const
  Digits: array[0..15] of Char = '0123456789abcdef';
var
  Index: Integer;
begin
  Result := '';
  SetLength(Result, 2 * Count);
  for Index := 0 to Count - 1 do
  begin
    Result[2 * Index + 1] := Digits[Bytes[Index] shr 4];
    Result[2 * Index + 2] := Digits[Bytes[Index] and 15];
  end;
end;

function TextBytes(const Text: string): TByteArray;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
end;

procedure CheckBytes(Actual: PByte; Count: Integer; const ExpectedHex: string; const Name: string);
var
  Expected: TByteArray;
  ActualHex: string;
begin
  Expected := HexToBytes(ExpectedHex);
  ActualHex := BytesToHex(Actual, Count);
  Check((Length(Expected) = Count) and (ActualHex = BytesToHex(@Expected[0], Length(Expected))), Name);
  if ActualHex <> BytesToHex(@Expected[0], Length(Expected)) then
  begin
    WriteLn('     expected ', BytesToHex(@Expected[0], Length(Expected)));
    WriteLn('     got      ', ActualHex);
  end;
end;

procedure FinishChecks(const Title: string);
begin
  WriteLn(Title, ': ', PassedChecks, ' passed, ', FailedChecks, ' failed');
  if FailedChecks > 0 then
    Halt(1);
end;

end.
