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
  Numeric values: what a numeric up/down box shows and reads, with
  nothing of the screen in it (it builds for the host too, and is
  checked there).

  A value has a number of decimal places (0 to MaximumDecimalPlaces);
  it is rounded to them (halves away from zero) and kept between a
  minimum and a maximum. It is shown with a point before the decimals,
  optionally with a comma between each three digits of the whole part
  (1,234,567.89), or in hexadecimal (whole numbers only, upper case,
  no prefix). Reading takes what showing gives, and is lenient about
  spaces around it and the thousands commas wherever they are; a
  hexadecimal text may start with "0x" or "$".
}
unit Controls.NumericValues;

{$mode objfpc}
{$H+}

interface

const
  MaximumDecimalPlaces = 9;

type
  TNumberFormat = record
    DecimalPlaces: LongInt;
    Hexadecimal: Boolean;
    ThousandsSeparator: Boolean;
  end;

function MakeNumberFormat(DecimalPlaces: LongInt; Hexadecimal, ThousandsSeparator: Boolean): TNumberFormat;
{ Rounded to the format's decimal places (whole numbers in hexadecimal). }
function RoundToFormat(Value: Double; const Format: TNumberFormat): Double;
function ClampValue(Value, Minimum, Maximum: Double): Double;
{ Value moved by Steps increments, rounded and kept within the limits. }
function StepValue(Value, Increment: Double; Steps: LongInt; Minimum, Maximum: Double;
  const Format: TNumberFormat): Double;
function FormatNumber(Value: Double; const Format: TNumberFormat): string;
{ False if Text is not a number in the format. }
function TryParseNumber(const Text: string; const Format: TNumberFormat; out Value: Double): Boolean;
{ Whether Character may be typed into a box of the format (digits, the
  sign, the point, the comma; hexadecimal digits). }
function IsNumberCharacter(Character: LongWord; const Format: TNumberFormat): Boolean;

implementation

function MakeNumberFormat(DecimalPlaces: LongInt; Hexadecimal, ThousandsSeparator: Boolean): TNumberFormat;
begin
  if DecimalPlaces < 0 then
    DecimalPlaces := 0;
  if DecimalPlaces > MaximumDecimalPlaces then
    DecimalPlaces := MaximumDecimalPlaces;
  Result.DecimalPlaces := DecimalPlaces;
  Result.Hexadecimal := Hexadecimal;
  Result.ThousandsSeparator := ThousandsSeparator;
end;

function EffectivePlaces(const Format: TNumberFormat): LongInt;
begin
  if Format.Hexadecimal then
    Result := 0
  else
    Result := Format.DecimalPlaces;
end;

function PowerOfTen(Places: LongInt): Double;
var
  Index: LongInt;
begin
  Result := 1;
  for Index := 1 to Places do
    Result := Result * 10;
end;

const
  LargestUnits = 1E18;

{ The value as a whole number of the smallest unit the format shows
  (hundredths with two places), rounded half away from zero. }
function ScaledUnits(Value: Double; Places: LongInt): Int64;
var
  Scaled: Double;
begin
  Scaled := Abs(Value) * PowerOfTen(Places);
  { Beyond what a whole number holds: as far as it goes. }
  if Scaled >= LargestUnits then
    Scaled := LargestUnits;
  { A hair more than a half, so 2.675 (2.67499999... as a double) still
    rounds up to 2.68. }
  Result := Trunc(Scaled + 0.5 + Scaled * 1E-12);
  if Value < 0 then
    Result := -Result;
end;

function RoundToFormat(Value: Double; const Format: TNumberFormat): Double;
var
  Places: LongInt;
begin
  Places := EffectivePlaces(Format);
  Result := ScaledUnits(Value, Places) / PowerOfTen(Places);
end;

function ClampValue(Value, Minimum, Maximum: Double): Double;
begin
  Result := Value;
  if Result < Minimum then
    Result := Minimum;
  if Result > Maximum then
    Result := Maximum;
end;

function StepValue(Value, Increment: Double; Steps: LongInt; Minimum, Maximum: Double;
  const Format: TNumberFormat): Double;
begin
  Result := ClampValue(RoundToFormat(Value + Increment * Steps, Format), Minimum, Maximum);
end;

function GroupedDigits(const Digits: string): string;
var
  Index: LongInt;
  FromEnd: LongInt;
begin
  Result := '';
  for Index := 1 to Length(Digits) do
  begin
    FromEnd := Length(Digits) - Index + 1;
    Result := Result + Digits[Index];
    if (FromEnd > 1) and ((FromEnd - 1) mod 3 = 0) then
      Result := Result + ',';
  end;
end;

function HexadecimalOf(Value: Int64): string;
const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';
var
  Magnitude: QWord;
begin
  if Value = 0 then
    Exit('0');
  if Value < 0 then
    Magnitude := QWord(-(Value + 1)) + 1
  else
    Magnitude := QWord(Value);
  Result := '';
  while Magnitude > 0 do
  begin
    Result := HexDigits[Magnitude and 15] + Result;
    Magnitude := Magnitude shr 4;
  end;
  if Value < 0 then
    Result := '-' + Result;
end;

function FormatNumber(Value: Double; const Format: TNumberFormat): string;
var
  Places: LongInt;
  Units: Int64;
  Negative: Boolean;
  Digits: string;
  WholePart: string;
  Fraction: string;
begin
  Places := EffectivePlaces(Format);
  Units := ScaledUnits(Value, Places);
  if Format.Hexadecimal then
    Exit(HexadecimalOf(Units));
  Negative := Units < 0;
  Units := Abs(Units);
  Str(Units, Digits);
  while Length(Digits) <= Places do
    Digits := '0' + Digits;
  WholePart := Copy(Digits, 1, Length(Digits) - Places);
  Fraction := Copy(Digits, Length(Digits) - Places + 1, Places);
  if Format.ThousandsSeparator then
    WholePart := GroupedDigits(WholePart);
  Result := WholePart;
  if Places > 0 then
    Result := Result + '.' + Fraction;
  if Negative then
    Result := '-' + Result;
end;

function HexadecimalDigitValue(Character: Char): LongInt;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function Trimmed(const Text: string): string;
var
  First: LongInt;
  Last: LongInt;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and (Text[First] <= ' ') do
    Inc(First);
  while (Last >= First) and (Text[Last] <= ' ') do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
end;

function TryParseHexadecimal(const Text: string; out Value: Double): Boolean;
var
  Index: LongInt;
  Negative: Boolean;
  Digit: LongInt;
  Magnitude: Double;
  Body: string;
begin
  Result := False;
  Value := 0;
  Body := Text;
  Negative := (Body <> '') and (Body[1] = '-');
  if Negative then
    Delete(Body, 1, 1);
  if (Length(Body) > 2) and (Body[1] = '0') and ((Body[2] = 'x') or (Body[2] = 'X')) then
    Delete(Body, 1, 2)
  else if (Body <> '') and (Body[1] = '$') then
    Delete(Body, 1, 1);
  if Body = '' then
    Exit;
  Magnitude := 0;
  for Index := 1 to Length(Body) do
  begin
    Digit := HexadecimalDigitValue(Body[Index]);
    if Digit < 0 then
      Exit;
    Magnitude := Magnitude * 16 + Digit;
  end;
  if Negative then
    Magnitude := -Magnitude;
  Value := Magnitude;
  Result := True;
end;

function TryParseDecimal(const Text: string; out Value: Double): Boolean;
var
  Index: LongInt;
  Negative: Boolean;
  SeenPoint: Boolean;
  SeenDigit: Boolean;
  Magnitude: Double;
  FractionScale: Double;
  Character: Char;
  Body: string;
begin
  Result := False;
  Value := 0;
  Body := Text;
  Negative := (Body <> '') and (Body[1] = '-');
  if Negative or ((Body <> '') and (Body[1] = '+')) then
    Delete(Body, 1, 1);
  Magnitude := 0;
  FractionScale := 1;
  SeenPoint := False;
  SeenDigit := False;
  for Index := 1 to Length(Body) do
  begin
    Character := Body[Index];
    if (Character >= '0') and (Character <= '9') then
    begin
      SeenDigit := True;
      if SeenPoint then
      begin
        FractionScale := FractionScale / 10;
        Magnitude := Magnitude + (Ord(Character) - Ord('0')) * FractionScale;
      end
      else
        Magnitude := Magnitude * 10 + (Ord(Character) - Ord('0'));
    end
    else if (Character = '.') and not SeenPoint then
      SeenPoint := True
    else if (Character = ',') and not SeenPoint then
      { (A thousands separator: wherever it is, it says nothing.) }
    else
      Exit;
  end;
  if not SeenDigit then
    Exit;
  if Negative then
    Magnitude := -Magnitude;
  Value := Magnitude;
  Result := True;
end;

function TryParseNumber(const Text: string; const Format: TNumberFormat; out Value: Double): Boolean;
begin
  if Format.Hexadecimal then
    Result := TryParseHexadecimal(Trimmed(Text), Value)
  else
    Result := TryParseDecimal(Trimmed(Text), Value);
end;

function IsNumberCharacter(Character: LongWord; const Format: TNumberFormat): Boolean;
begin
  if (Character >= Ord('0')) and (Character <= Ord('9')) then
    Exit(True);
  if Character = Ord('-') then
    Exit(True);
  if Format.Hexadecimal then
    Exit(((Character >= Ord('a')) and (Character <= Ord('f'))) or ((Character >= Ord('A')) and
      (Character <= Ord('F'))) or (Character = Ord('x')) or (Character = Ord('X')) or (Character = Ord('$')));
  Result := (Character = Ord('+')) or (Character = Ord(',')) or ((Character = Ord('.')) and
    (Format.DecimalPlaces > 0));
end;

end.
