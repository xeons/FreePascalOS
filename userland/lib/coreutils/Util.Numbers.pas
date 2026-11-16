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
  Numbers in command line arguments and input, on strings.

  These accept exactly what the tools have always accepted (Sys.Text's
  parsing): decimal digits only, an optional sign for signed numbers,
  surrounding spaces allowed. SysUtils' TryStrToInt also takes "$FF",
  "0x1F" and other forms the tools must reject.
}
unit Util.Numbers;

{$mode objfpc}{$H+}

interface

{ An optionally signed decimal integer; the whole text must be a number. }
function ParseDecimal(const Text: string; out Value: Int64): Boolean;
{ An unsigned decimal integer; the whole text must be a number. }
function ParseUnsignedDecimal(const Text: string; out Value: QWord): Boolean;
{ Hexadecimal digits (no prefix), the whole text. }
function ParseHexadecimalDigits(const Text: string; out Value: QWord): Boolean;

{ Value in octal, at least Digits digits (zero filled): what Sys.Format's
  "%04o" printed, which SysUtils' Format cannot. }
function OctalText(Value: QWord; Digits: Integer): string;
{ Bytes in lower case hexadecimal, two digits each. }
function HexText(const Bytes: array of Byte; Count: Integer): string;

implementation

uses
  Sys.Text;

function ParseDecimal(const Text: string; out Value: Int64): Boolean;
begin
  Result := ParseInteger(PChar(Text), Value);
end;

function ParseUnsignedDecimal(const Text: string; out Value: QWord): Boolean;
begin
  Result := ParseUnsigned(PChar(Text), Value);
end;

function ParseHexadecimalDigits(const Text: string; out Value: QWord): Boolean;
begin
  Result := ParseHexadecimal(PChar(Text), Value);
end;

function OctalText(Value: QWord; Digits: Integer): string;
begin
  Result := '';
  repeat
    Result := Char(Ord('0') + (Value and 7)) + Result;
    Value := Value shr 3;
  until Value = 0;
  while Length(Result) < Digits do
    Result := '0' + Result;
end;

function HexText(const Bytes: array of Byte; Count: Integer): string;
const
  HexDigits: array[0..15] of Char = '0123456789abcdef';
var
  Index: Integer;
begin
  Result := '';
  SetLength(Result, 2 * Count);
  for Index := 0 to Count - 1 do
  begin
    Result[2 * Index + 1] := HexDigits[Bytes[Index] shr 4];
    Result[2 * Index + 2] := HexDigits[Bytes[Index] and 15];
  end;
end;

end.
