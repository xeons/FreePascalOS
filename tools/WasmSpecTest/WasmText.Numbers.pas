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
  Number literals of the text format (core specification 2.0, section
  6.3.1): integers in decimal or hexadecimal with single underscores
  between digits, and floats as decimal or hexadecimal literals, inf,
  nan and nan:0x payloads.

  A float literal is rounded to the nearest value of its own precision
  (ties to even) straight from the exact rational number it denotes,
  with big integers: an f32 literal is never rounded through f64, which
  could round twice. A literal that rounds to infinity is out of range.
  Results are the IEEE bit patterns.

  Every malformed or out of range literal raises EWasmTextError.
}
unit WasmText.Numbers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Lexer;

type
  TFloatPrecision = (fpSingle, fpDouble);

{ An integer of Bits (8, 16, 32 or 64) bits, signed or unsigned
  notation; the result is the two's complement pattern. }
function ParseIntegerBits(const Text: AnsiString; Bits: Integer): QWord;
{ An unsigned integer (an index, an offset, a limit) below 2^Bits. }
function ParseUnsigned(const Text: AnsiString; Bits: Integer): QWord;
{ A float of either precision; f32 results are in the low 32 bits. }
function ParseFloatBits(const Text: AnsiString; Precision: TFloatPrecision): QWord;
{ True when Text is shaped like a number (for telling indices apart). }
function LooksLikeUnsigned(const Text: AnsiString): Boolean;

implementation

uses
  WasmText.BigNumbers;

procedure OutOfRange(const Text: AnsiString);
begin
  raise EWasmTextError.Create('constant out of range: ' + Text);
end;

procedure Malformed(const Text: AnsiString);
begin
  raise EWasmTextError.Create('unknown operator: malformed number ' + Text);
end;

function DigitValue(Character: AnsiChar; Hexadecimal: Boolean): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': if Hexadecimal then Result := Ord(Character) - Ord('a') + 10 else Result := -1;
    'A'..'F': if Hexadecimal then Result := Ord(Character) - Ord('A') + 10 else Result := -1;
  else
    Result := -1;
  end;
end;

{ Reads digits with single underscores between them from Position on;
  returns them without the underscores ('' when there is none). A
  leading, trailing or doubled underscore is malformed. }
function ReadDigits(const Text: AnsiString; var Position: Integer; Hexadecimal: Boolean): AnsiString;
begin
  Result := '';
  while Position <= Length(Text) do
  begin
    if Text[Position] = '_' then
    begin
      if (Result = '') or (Position = Length(Text)) or (DigitValue(Text[Position + 1], Hexadecimal) < 0) then
        Malformed(Text);
    end
    else if DigitValue(Text[Position], Hexadecimal) >= 0 then
      Result := Result + Text[Position]
    else
      Break;
    Inc(Position);
  end;
end;

{ The magnitude of an unsigned literal (num or 0x hexnum); False when it
  does not fit 64 bits. }
function ReadMagnitude(const Text: AnsiString; Start: Integer; out Value: QWord): Boolean;
var
  Position, Index, Digit: Integer;
  Hexadecimal: Boolean;
  Digits: AnsiString;
  Base: QWord;
begin
  Position := Start;
  Hexadecimal := (Position + 1 <= Length(Text)) and (Text[Position] = '0') and (Text[Position + 1] = 'x');
  if Hexadecimal then
    Inc(Position, 2);
  Digits := ReadDigits(Text, Position, Hexadecimal);
  if (Digits = '') or (Position <= Length(Text)) then
    Malformed(Text);
  if Hexadecimal then
    Base := 16
  else
    Base := 10;
  Value := 0;
  Result := True;
  for Index := 1 to Length(Digits) do
  begin
    Digit := DigitValue(Digits[Index], Hexadecimal);
    if Value > (High(QWord) - QWord(Digit)) div Base then
      Result := False;
    if Result then
      Value := Value * Base + QWord(Digit);
  end;
end;

function LooksLikeUnsigned(const Text: AnsiString): Boolean;
begin
  Result := (Text <> '') and (Text[1] in ['0'..'9']);
end;

function ParseUnsigned(const Text: AnsiString; Bits: Integer): QWord;
begin
  if not LooksLikeUnsigned(Text) then
    Malformed(Text);
  if not ReadMagnitude(Text, 1, Result) then
    OutOfRange(Text);
  if (Bits < 64) and (Result >= (QWord(1) shl Bits)) then
    OutOfRange(Text);
end;

{ Two's complement negation wraps on purpose. }
{$push}{$R-}{$Q-}
function Negate(Value: QWord): QWord;
begin
  Result := QWord(0) - Value;
end;
{$pop}

function ParseIntegerBits(const Text: AnsiString; Bits: Integer): QWord;
var
  Negative, Signed: Boolean;
  Magnitude, Limit: QWord;
begin
  if Text = '' then
    Malformed(Text);
  Negative := Text[1] = '-';
  Signed := Text[1] in ['+', '-'];
  if Signed then
  begin
    if (Length(Text) < 2) or not (Text[2] in ['0'..'9']) then
      Malformed(Text);
    if not ReadMagnitude(Text, 2, Magnitude) then
      OutOfRange(Text);
  end
  else
  begin
    if not LooksLikeUnsigned(Text) then
      Malformed(Text);
    if not ReadMagnitude(Text, 1, Magnitude) then
      OutOfRange(Text);
  end;
  if Negative then
  begin
    Limit := QWord(1) shl (Bits - 1);
    if Magnitude > Limit then
      OutOfRange(Text);
    Result := Negate(Magnitude);
  end
  else
  begin
    if (Bits < 64) and (Magnitude >= (QWord(1) shl Bits)) then
      OutOfRange(Text);
    Result := Magnitude;
  end;
  if Bits < 64 then
    Result := Result and ((QWord(1) shl Bits) - 1);
end;

{ The exponent of a float literal, saturated far beyond any that could
  matter. }
function ReadExponent(const Text: AnsiString; var Position: Integer): Int64;
var
  Negative: Boolean;
  Digits: AnsiString;
  Index: Integer;
begin
  Negative := False;
  if (Position <= Length(Text)) and (Text[Position] in ['+', '-']) then
  begin
    Negative := Text[Position] = '-';
    Inc(Position);
  end;
  Digits := ReadDigits(Text, Position, False);
  if Digits = '' then
    Malformed(Text);
  Result := 0;
  for Index := 1 to Length(Digits) do
    if Result < 1000000000 then
      Result := Result * 10 + (Ord(Digits[Index]) - Ord('0'));
  if Negative then
    Result := -Result;
end;

type
  TFloatFormat = record
    MantissaBits: Integer;   { Precision with the hidden bit: 24 or 53. }
    MinimumExponent: Integer;
    MaximumExponent: Integer;
    Bias: Integer;
  end;

function FormatOf(Precision: TFloatPrecision): TFloatFormat;
begin
  if Precision = fpSingle then
  begin
    Result.MantissaBits := 24;
    Result.MinimumExponent := -126;
    Result.MaximumExponent := 127;
    Result.Bias := 127;
  end
  else
  begin
    Result.MantissaBits := 53;
    Result.MinimumExponent := -1022;
    Result.MaximumExponent := 1023;
    Result.Bias := 1023;
  end;
end;

{ Rounds Numerator / Denominator (Numerator > 0) to the nearest float,
  ties to even; the bits without the sign. }
function RoundRational(const Numerator, Denominator: TBigNumber; const Format: TFloatFormat;
  const Text: AnsiString): QWord;
var
  LengthDifference, LeadingExponent, Exponent, Shift, Bit, Comparison: Integer;
  Dividend, Divisor, Shifted: TBigNumber;
  Quotient, HiddenBit: QWord;
begin
  LengthDifference := BigBitLength(Numerator) - BigBitLength(Denominator);
  if LengthDifference >= 0 then
    Comparison := BigCompare(Numerator, BigShiftLeft(Denominator, LengthDifference))
  else
    Comparison := BigCompare(BigShiftLeft(Numerator, -LengthDifference), Denominator);
  if Comparison >= 0 then
    LeadingExponent := LengthDifference
  else
    LeadingExponent := LengthDifference - 1;
  Exponent := LeadingExponent;
  if Exponent < Format.MinimumExponent then
    Exponent := Format.MinimumExponent;
  if Exponent > Format.MaximumExponent + 1 then
    OutOfRange(Text);
  Shift := Format.MantissaBits - 1 - Exponent;
  if Shift >= 0 then
  begin
    Dividend := BigShiftLeft(Numerator, Shift);
    Divisor := Copy(Denominator);
  end
  else
  begin
    Dividend := Copy(Numerator);
    Divisor := BigShiftLeft(Denominator, -Shift);
  end;
  Quotient := 0;
  for Bit := Format.MantissaBits downto 0 do
  begin
    Shifted := BigShiftLeft(Divisor, Bit);
    if BigCompare(Dividend, Shifted) >= 0 then
    begin
      BigSubtract(Dividend, Shifted);
      Quotient := Quotient or (QWord(1) shl Bit);
    end;
  end;
  { Dividend is now the remainder. }
  Comparison := BigCompare(BigShiftLeft(Dividend, 1), Divisor);
  if (Comparison > 0) or ((Comparison = 0) and Odd(Quotient)) then
    Inc(Quotient);
  HiddenBit := QWord(1) shl (Format.MantissaBits - 1);
  if Quotient = HiddenBit shl 1 then
  begin
    Quotient := HiddenBit;
    Inc(Exponent);
  end;
  if Quotient >= HiddenBit then
  begin
    if Exponent > Format.MaximumExponent then
      OutOfRange(Text);
    Result := (QWord(Exponent + Format.Bias) shl (Format.MantissaBits - 1)) or (Quotient - HiddenBit);
  end
  else
    Result := Quotient;
end;

function InfinityBits(const Format: TFloatFormat): QWord;
begin
  Result := QWord(2 * Format.Bias + 1) shl (Format.MantissaBits - 1);
end;

function ParseFloatBits(const Text: AnsiString; Precision: TFloatPrecision): QWord;
var
  Format: TFloatFormat;
  SignBit, Payload: QWord;
  Position, Index, SignificantDigits: Integer;
  Body, IntegerDigits, FractionDigits, Digits: AnsiString;
  Hexadecimal: Boolean;
  Exponent: Int64;
  Numerator, Denominator: TBigNumber;
begin
  Format := FormatOf(Precision);
  if Precision = fpSingle then
    SignBit := QWord(1) shl 31
  else
    SignBit := QWord(1) shl 63;
  Body := Text;
  if (Body <> '') and (Body[1] in ['+', '-']) then
  begin
    if Body[1] = '+' then
      SignBit := 0;
    Delete(Body, 1, 1);
  end
  else
    SignBit := 0;
  if Body = 'inf' then
    Exit(SignBit or InfinityBits(Format));
  if Body = 'nan' then
    Exit(SignBit or InfinityBits(Format) or (QWord(1) shl (Format.MantissaBits - 2)));
  if Copy(Body, 1, 4) = 'nan:' then
  begin
    if Copy(Body, 5, 2) <> '0x' then
      Malformed(Text);
    if not ReadMagnitude(Body, 5, Payload) then
      OutOfRange(Text);
    if (Payload = 0) or (Payload >= (QWord(1) shl (Format.MantissaBits - 1))) then
      OutOfRange(Text);
    Exit(SignBit or InfinityBits(Format) or Payload);
  end;
  if (Body = '') or not (Body[1] in ['0'..'9']) then
    Malformed(Text);
  Position := 1;
  Hexadecimal := (Length(Body) >= 2) and (Body[1] = '0') and (Body[2] = 'x');
  if Hexadecimal then
    Inc(Position, 2);
  IntegerDigits := ReadDigits(Body, Position, Hexadecimal);
  if IntegerDigits = '' then
    Malformed(Text);
  FractionDigits := '';
  if (Position <= Length(Body)) and (Body[Position] = '.') then
  begin
    Inc(Position);
    FractionDigits := ReadDigits(Body, Position, Hexadecimal);
  end;
  Exponent := 0;
  if Position <= Length(Body) then
  begin
    if (Hexadecimal and (Body[Position] in ['p', 'P'])) or
       (not Hexadecimal and (Body[Position] in ['e', 'E'])) then
    begin
      Inc(Position);
      Exponent := ReadExponent(Body, Position);
    end;
  end;
  if Position <= Length(Body) then
    Malformed(Text);
  Digits := IntegerDigits + FractionDigits;
  Index := 1;
  while (Index < Length(Digits)) and (Digits[Index] = '0') do
    Inc(Index);
  Digits := Copy(Digits, Index, Length(Digits));
  if Digits = '0' then
    Exit(SignBit);
  Numerator := nil;
  if Hexadecimal then
  begin
    for Index := 1 to Length(Digits) do
      BigMultiplyAdd(Numerator, 16, DigitValue(Digits[Index], True));
    Exponent := Exponent - 4 * Length(FractionDigits);
    if BigBitLength(Numerator) + Exponent > 1100 then
      OutOfRange(Text);
    if BigBitLength(Numerator) + Exponent < -1200 then
      Exit(SignBit);
    if Exponent >= 0 then
    begin
      Numerator := BigShiftLeft(Numerator, Exponent);
      Denominator := BigFromSmall(1);
    end
    else
      Denominator := BigShiftLeft(BigFromSmall(1), -Exponent);
  end
  else
  begin
    for Index := 1 to Length(Digits) do
      BigMultiplyAdd(Numerator, 10, Ord(Digits[Index]) - Ord('0'));
    Exponent := Exponent - Length(FractionDigits);
    SignificantDigits := Length(Digits);
    if SignificantDigits + Exponent > 400 then
      OutOfRange(Text);
    if SignificantDigits + Exponent < -400 then
      Exit(SignBit);
    if Exponent >= 0 then
    begin
      for Index := 1 to Exponent do
        BigMultiplyAdd(Numerator, 10, 0);
      Denominator := BigFromSmall(1);
    end
    else
      Denominator := BigPowerOfTen(-Exponent);
  end;
  Result := SignBit or RoundRational(Numerator, Denominator, Format, Text);
end;

end.
