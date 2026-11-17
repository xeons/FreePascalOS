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
  Numbers as the calculator shows them and reads them back.

  Values are doubles, shown to 15 significant digits: enough for every
  digit the user can type, few enough that the binary fractions of a
  double do not show (0.1 + 0.2 is 0.3, 1 / 3 x 3 is 1). Trailing zeros
  are left out; numbers from 1e15 up, and below 1e-9, are shown with an
  exponent ("1.5e+20"). The decimal separator is always a full stop, and
  the text read back is exactly the number shown, so what is calculated
  next is what the user saw.

  Integers (the programmer mode) are Int64s kept to a word of 8, 16, 32
  or 64 bits (two's complement, so a byte holds -128 to 127), shown in
  base 2, 8, 10 or 16: in decimal signed, in the others as the word's
  bits (binary in groups of four).

  Plain logic: the host checks it (make apps-test).
}
unit Calculator.Numbers;

{$mode objfpc}
{$H+}
{ Integers wrap within their word on purpose. }
{$R-}
{$Q-}

interface

const
  ShownSignificantDigits = 15;
  { The most digits that may be typed for one number. }
  MaximumTypedDigits = 16;

{ Value as shown ('0' for zero; NaN and infinities are the caller's to
  report). }
function FormatCalculatorNumber(Value: Double): string;
{ Value rounded to the digits it is shown with. }
function RoundToShown(Value: Double): Double;
{ A number as FormatCalculatorNumber writes it (or as typed: digits, a
  point, an exponent); False if Text is not one. }
function ParseCalculatorNumber(const Text: string; out Value: Double): Boolean;

{ Value kept to a word of Bits bits, read as signed. }
function WrapToWord(Value: Int64; Bits: LongInt): Int64;
{ Value (wrapped to Bits) in Base: signed in base 10, the word's bits in
  the others; binary in groups of four. }
function FormatInBase(Value: Int64; Base, Bits: LongInt): string;
{ Digits of Base (spaces ignored, a leading minus in base 10) as an
  integer wrapped to Bits; False if Text is not a number of that base
  or does not fit in 64 bits. }
function ParseInBase(const Text: string; Base, Bits: LongInt; out Value: Int64): Boolean;
{ The value of digit character Character (0-9, A-F in either case), or
  -1. }
function DigitValue(Character: Char): LongInt;

implementation

uses
  SysUtils,
  Math;

const
  { Plain from 1e-9 up to (not including) 1e15. }
  SmallestPlainExponent = -9;

{ Digits (a string of decimal digits) rounded to Count digits; Exponent
  goes up by one when rounding carries past the first (9.99 to 10.0). }
procedure RoundDigits(var Digits: string; var Exponent: LongInt; Count: LongInt);
var
  Index: LongInt;
  RoundUp: Boolean;
begin
  if Length(Digits) <= Count then
    Exit;
  RoundUp := Digits[Count + 1] >= '5';
  SetLength(Digits, Count);
  if not RoundUp then
    Exit;
  Index := Count;
  while (Index >= 1) and (Digits[Index] = '9') do
  begin
    Digits[Index] := '0';
    Dec(Index);
  end;
  if Index >= 1 then
    Digits[Index] := Chr(Ord(Digits[Index]) + 1)
  else
  begin
    Digits := '1' + Copy(Digits, 1, Count - 1);
    Inc(Exponent);
  end;
end;

{ The significant digits of Abs(Value) (no trailing zeros) and the
  power of ten of the first. }
procedure SplitDigits(Value: Double; out Digits: string; out Exponent: LongInt);
var
  Text: string;
  ExponentAt: LongInt;
  Code: Word;
begin
  { Scientific notation with every digit the double has. }
  Str(Abs(Value): 28, Text);
  Text := Trim(Text);
  ExponentAt := Pos('E', Text);
  Val(Copy(Text, ExponentAt + 1, Length(Text) - ExponentAt), Exponent, Code);
  if Code <> 0 then
    Exponent := 0;
  Digits := StringReplace(Copy(Text, 1, ExponentAt - 1), '.', '', []);
  RoundDigits(Digits, Exponent, ShownSignificantDigits);
  while (Length(Digits) > 1) and (Digits[Length(Digits)] = '0') do
    SetLength(Digits, Length(Digits) - 1);
end;

function PlainText(const Digits: string; Exponent: LongInt): string;
var
  Whole: string;
  Fraction: string;
begin
  if Exponent < 0 then
    Exit('0.' + StringOfChar('0', -Exponent - 1) + Digits);
  if Length(Digits) <= Exponent + 1 then
    Exit(Digits + StringOfChar('0', Exponent + 1 - Length(Digits)));
  Whole := Copy(Digits, 1, Exponent + 1);
  Fraction := Copy(Digits, Exponent + 2, Length(Digits));
  Result := Whole + '.' + Fraction;
end;

function ExponentText(const Digits: string; Exponent: LongInt): string;
begin
  Result := Digits[1];
  if Length(Digits) > 1 then
    Result := Result + '.' + Copy(Digits, 2, Length(Digits));
  if Exponent < 0 then
    Result := Result + 'e-' + IntToStr(-Exponent)
  else
    Result := Result + 'e+' + IntToStr(Exponent);
end;

function FormatCalculatorNumber(Value: Double): string;
var
  Digits: string;
  Exponent: LongInt;
begin
  if Value = 0 then
    Exit('0');
  SplitDigits(Value, Digits, Exponent);
  if (Exponent >= ShownSignificantDigits) or (Exponent < SmallestPlainExponent) then
    Result := ExponentText(Digits, Exponent)
  else
    Result := PlainText(Digits, Exponent);
  if Value < 0 then
    Result := '-' + Result;
end;

function RoundToShown(Value: Double): Double;
begin
  if IsNan(Value) or IsInfinite(Value) or (Value = 0) then
    Exit(Value);
  if not ParseCalculatorNumber(FormatCalculatorNumber(Value), Result) then
    Result := Value;
end;

function ParseCalculatorNumber(const Text: string; out Value: Double): Boolean;
var
  Code: Word;
  Index: LongInt;
  SeenDigit: Boolean;
begin
  Value := 0;
  SeenDigit := False;
  for Index := 1 to Length(Text) do
    if Text[Index] in ['0'..'9'] then
      SeenDigit := True
    else if not (Text[Index] in ['.', 'e', 'E', '+', '-']) then
      Exit(False);
  if not SeenDigit then
    Exit(False);
  Val(Text, Value, Code);
  Result := (Code = 0) and not IsNan(Value) and not IsInfinite(Value);
end;

{ --- Integers -------------------------------------------------------------------- }

function WordMask(Bits: LongInt): QWord;
begin
  if Bits >= 64 then
    Result := High(QWord)
  else
    Result := (QWord(1) shl Bits) - 1;
end;

function WrapToWord(Value: Int64; Bits: LongInt): Int64;
var
  Unsigned: QWord;
begin
  if Bits >= 64 then
    Exit(Value);
  Unsigned := QWord(Value) and WordMask(Bits);
  if (Unsigned and (QWord(1) shl (Bits - 1))) <> 0 then
    Result := Int64(Unsigned) - Int64(QWord(1) shl Bits)
  else
    Result := Int64(Unsigned);
end;

function FormatInBase(Value: Int64; Base, Bits: LongInt): string;
const
  DigitCharacters: string = '0123456789ABCDEF';
var
  Unsigned: QWord;
  Count: LongInt;
begin
  if Base = 10 then
    Exit(IntToStr(WrapToWord(Value, Bits)));
  Unsigned := QWord(Value) and WordMask(Bits);
  Result := '';
  Count := 0;
  repeat
    if (Base = 2) and (Count > 0) and (Count mod 4 = 0) then
      Result := ' ' + Result;
    Result := DigitCharacters[(Unsigned mod QWord(Base)) + 1] + Result;
    Unsigned := Unsigned div QWord(Base);
    Inc(Count);
  until Unsigned = 0;
end;

function DigitValue(Character: Char): LongInt;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

function ParseInBase(const Text: string; Base, Bits: LongInt; out Value: Int64): Boolean;
var
  Index: LongInt;
  Digit: LongInt;
  Accumulated: QWord;
  Negative: Boolean;
  SeenDigit: Boolean;
begin
  Value := 0;
  Accumulated := 0;
  Negative := False;
  SeenDigit := False;
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = ' ' then
      Continue;
    if (Text[Index] = '-') and (Base = 10) and not SeenDigit and not Negative then
    begin
      Negative := True;
      Continue;
    end;
    Digit := DigitValue(Text[Index]);
    if (Digit < 0) or (Digit >= Base) then
      Exit(False);
    if Accumulated > (High(QWord) - QWord(Digit)) div QWord(Base) then
      Exit(False);
    Accumulated := Accumulated * QWord(Base) + QWord(Digit);
    SeenDigit := True;
  end;
  if not SeenDigit then
    Exit(False);
  if Negative then
    Value := WrapToWord(-Int64(Accumulated), Bits)
  else
    Value := WrapToWord(Int64(Accumulated), Bits);
  Result := True;
end;

end.
