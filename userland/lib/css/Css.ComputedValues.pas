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
  Computed values: what layout and painting read.

  One computed value is a 24 byte record: a kind, a keyword, two
  single precision numbers (px and percent; or a 16 bit per channel
  sRGB color), and a reference to a value tree for what does not fit
  (font families, transforms, shadows, gradients, grid templates, a
  calc() with min() in it ...). Lengths are absolute (px); percentages
  stay percentages until layout gives them a basis (Resolve).
}
unit Css.ComputedValues;

{$mode objfpc}
{$H+}

interface

uses
  Css.Keywords, Css.Colors, Css.Values;

type
  TCssComputedKind = (
    { unset: only seen before a value is stored }
    cvNone,
    cvKeyword,
    { Number px }
    cvLength,
    { Percent }
    cvPercentage,
    { Number px + Percent percent }
    cvLengthPercentage,
    { Data is a calc() whose lengths are px; percentages need a basis }
    cvCalc,
    cvNumber,
    cvInteger,
    { Red, Green, Blue, Alpha (16 bit sRGB) }
    cvColor,
    { currentcolor, resolved when used }
    cvCurrentColor,
    { Data holds the value }
    cvValue);

  PCssComputedValue = ^TCssComputedValue;
  TCssComputedValue = record
    Kind: TCssComputedKind;
    Flags: Byte;
    Keyword: Word;
    case Integer of
      0: (Number: Single; Percent: Single; Data: TCssValue);
      1: (Red, Green, Blue, Alpha: Word);
  end;

function ComputedKeyword(Keyword: TCssKeyword): TCssComputedValue;
function ComputedLength(Pixels: Double): TCssComputedValue;
function ComputedPercentage(Percent: Double): TCssComputedValue;
function ComputedLengthPercentage(Pixels, Percent: Double): TCssComputedValue;
function ComputedNumber(Number: Double): TCssComputedValue;
function ComputedInteger(Number: Integer): TCssComputedValue;
function ComputedColor(const Color: TCssColor): TCssComputedValue;
function ComputedCurrentColor: TCssComputedValue;
{ Takes Value's reference. }
function ComputedTree(Value: TCssValue): TCssComputedValue;
function ComputedCalc(Value: TCssValue): TCssComputedValue;

{ The keyword of a value (kwInvalid if it is no keyword). }
function KeywordOfComputed(const Value: TCssComputedValue): TCssKeyword; inline;
function IsComputedKeyword(const Value: TCssComputedValue; Keyword: TCssKeyword): Boolean; inline;
{ A length-percentage (or calc) resolved against a percentage basis. }
function ResolveComputed(const Value: TCssComputedValue; Basis: Double): Double;
{ The color, currentcolor given. }
function ComputedToColor(const Value: TCssComputedValue; const CurrentColor: TCssColor): TCssColor;
function ComputedToRgba8(const Value: TCssComputedValue): TCssRgba8;
function SameComputed(const A, B: TCssComputedValue): Boolean;
function HashComputed(const Value: TCssComputedValue): LongWord;
procedure AddRefComputed(const Value: TCssComputedValue); inline;
procedure ReleaseComputed(var Value: TCssComputedValue); inline;
function SerializeComputed(const Value: TCssComputedValue): string;
function HasData(const Value: TCssComputedValue): Boolean; inline;

implementation

uses
  SysUtils, Css.Units, Css.Calc, Css.Serialization;

function HasData(const Value: TCssComputedValue): Boolean;
begin
  Result := (Value.Kind in [cvCalc, cvValue]) and (Value.Data <> nil);
end;

function Blank(Kind: TCssComputedKind): TCssComputedValue; inline;
begin
  Result := Default(TCssComputedValue);
  Result.Kind := Kind;
end;

function ComputedKeyword(Keyword: TCssKeyword): TCssComputedValue;
begin
  Result := Blank(cvKeyword);
  Result.Keyword := Ord(Keyword);
end;

function ComputedLength(Pixels: Double): TCssComputedValue;
begin
  Result := Blank(cvLength);
  Result.Number := Pixels;
end;

function ComputedPercentage(Percent: Double): TCssComputedValue;
begin
  Result := Blank(cvPercentage);
  Result.Percent := Percent;
end;

function ComputedLengthPercentage(Pixels, Percent: Double): TCssComputedValue;
begin
  if Percent = 0 then
    Exit(ComputedLength(Pixels));
  if Pixels = 0 then
    Exit(ComputedPercentage(Percent));
  Result := Blank(cvLengthPercentage);
  Result.Number := Pixels;
  Result.Percent := Percent;
end;

function ComputedNumber(Number: Double): TCssComputedValue;
begin
  Result := Blank(cvNumber);
  Result.Number := Number;
end;

function ComputedInteger(Number: Integer): TCssComputedValue;
begin
  Result := Blank(cvInteger);
  Result.Number := Number;
end;

function Channel16(Value: Double): Word;
begin
  if Value <= 0 then
    Result := 0
  else if Value >= 1 then
    Result := 65535
  else
    Result := Round(Value * 65535);
end;

function ComputedColor(const Color: TCssColor): TCssComputedValue;
var
  Red, Green, Blue, Alpha: Double;
begin
  Result := Blank(cvColor);
  ColorToSrgb(Color, Red, Green, Blue, Alpha);
  Result.Red := Channel16(Red);
  Result.Green := Channel16(Green);
  Result.Blue := Channel16(Blue);
  Result.Alpha := Channel16(Alpha);
end;

function ComputedCurrentColor: TCssComputedValue;
begin
  Result := Blank(cvCurrentColor);
  Result.Keyword := Ord(kwCurrentcolor);
end;

function ComputedTree(Value: TCssValue): TCssComputedValue;
begin
  Result := Blank(cvValue);
  Result.Data := Value;
end;

function ComputedCalc(Value: TCssValue): TCssComputedValue;
begin
  Result := Blank(cvCalc);
  Result.Data := Value;
end;

function KeywordOfComputed(const Value: TCssComputedValue): TCssKeyword;
begin
  if Value.Kind = cvKeyword then
    Result := TCssKeyword(Value.Keyword)
  else
    Result := kwInvalid;
end;

function IsComputedKeyword(const Value: TCssComputedValue; Keyword: TCssKeyword): Boolean;
begin
  Result := (Value.Kind = cvKeyword) and (Value.Keyword = Ord(Keyword));
end;

function PercentResolver(Value: Double; UnitValue: TCssUnit; Data: Pointer): Double;
begin
  Result := Value * PDouble(Data)^ / 100;
end;

function ResolveComputed(const Value: TCssComputedValue; Basis: Double): Double;
var
  BasisCopy: Double;
begin
  case Value.Kind of
    cvLength, cvNumber, cvInteger: Result := Value.Number;
    cvPercentage: Result := Value.Percent * Basis / 100;
    cvLengthPercentage: Result := Value.Number + Value.Percent * Basis / 100;
    cvCalc:
      begin
        BasisCopy := Basis;
        Result := EvaluateCalc(Value.Data.Calc, @PercentResolver, @BasisCopy);
      end;
  else
    Result := 0;
  end;
end;

function ComputedToColor(const Value: TCssComputedValue; const CurrentColor: TCssColor): TCssColor;
begin
  case Value.Kind of
    cvColor: Result := MakeRgbColor(Value.Red / 65535, Value.Green / 65535, Value.Blue / 65535, Value.Alpha / 65535);
    cvCurrentColor: Result := CurrentColor;
  else
    Result := TransparentColor;
  end;
end;

function Channel8(Value: Word): Integer;
begin
  Result := (Value * 255 + 32767) div 65535;
end;

function ComputedToRgba8(const Value: TCssComputedValue): TCssRgba8;
begin
  Result.Red := Channel8(Value.Red);
  Result.Green := Channel8(Value.Green);
  Result.Blue := Channel8(Value.Blue);
  Result.Alpha := Channel8(Value.Alpha);
end;

function SameComputed(const A, B: TCssComputedValue): Boolean;
begin
  if (A.Kind <> B.Kind) or (A.Keyword <> B.Keyword) or (A.Flags <> B.Flags) then
    Exit(False);
  case A.Kind of
    cvColor: Result := (A.Red = B.Red) and (A.Green = B.Green) and (A.Blue = B.Blue) and (A.Alpha = B.Alpha);
    cvCalc, cvValue: Result := (A.Data = B.Data) or ((A.Data <> nil) and A.Data.Equals(B.Data));
    cvKeyword, cvCurrentColor, cvNone: Result := True;
  else
    Result := (A.Number = B.Number) and (A.Percent = B.Percent);
  end;
end;

function HashComputed(const Value: TCssComputedValue): LongWord;
var
  Bits: LongWord;
begin
  Result := LongWord(Ord(Value.Kind)) * 31 + Value.Keyword;
  case Value.Kind of
    cvColor: Bits := LongWord(Value.Red) xor (LongWord(Value.Green) shl 8) xor (LongWord(Value.Blue) shl 16) xor
      (LongWord(Value.Alpha) shl 3);
    cvLength, cvPercentage, cvLengthPercentage, cvNumber, cvInteger:
      Bits := PLongWord(@Value.Number)^ xor LongWord((QWord(PLongWord(@Value.Percent)^) * 7) and $FFFFFFFF);
    cvValue, cvCalc:
      if Value.Data <> nil then
        Bits := LongWord(Ord(Value.Data.Kind)) * 131 + LongWord(Value.Data.Count)
      else
        Bits := 0;
  else
    Bits := 0;
  end;
  Result := LongWord((QWord(Result) * 16777619 + Bits) and $FFFFFFFF);
end;

procedure AddRefComputed(const Value: TCssComputedValue);
begin
  if HasData(Value) then
    Value.Data.AddRef;
end;

procedure ReleaseComputed(var Value: TCssComputedValue);
begin
  if HasData(Value) then
  begin
    Value.Data.Release;
    Value.Data := nil;
  end;
end;

{ A single precision number with the digits it really has (six
  significant ones), so 28.8 does not come out as 28.799999. }
function SerializeSingle(Value: Single): string;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := SerializeNumber(StrToFloat(FloatToStrF(Value, ffExponent, 6, 0, Settings), Settings));
end;

function SerializeComputed(const Value: TCssComputedValue): string;
begin
  case Value.Kind of
    cvKeyword: Result := KeywordName(TCssKeyword(Value.Keyword));
    cvLength: Result := SerializeSingle(Value.Number) + 'px';
    cvPercentage: Result := SerializeSingle(Value.Percent) + '%';
    cvLengthPercentage:
      if Value.Number < 0 then
        Result := 'calc(' + SerializeSingle(Value.Percent) + '% - ' + SerializeSingle(-Value.Number) + 'px)'
      else
        Result := 'calc(' + SerializeSingle(Value.Percent) + '% + ' + SerializeSingle(Value.Number) + 'px)';
    cvNumber: Result := SerializeSingle(Value.Number);
    cvInteger: Result := IntToStr(Round(Value.Number));
    cvColor:
      if Value.Alpha = 65535 then
        Result := Format('rgb(%d, %d, %d)', [Channel8(Value.Red), Channel8(Value.Green), Channel8(Value.Blue)])
      else
        Result := Format('rgba(%d, %d, %d, %s)', [Channel8(Value.Red), Channel8(Value.Green),
          Channel8(Value.Blue), SerializeNumber(Round(Value.Alpha / 65535 * 1000) / 1000)]);
    cvCurrentColor: Result := 'currentcolor';
    cvCalc, cvValue:
      if Value.Data <> nil then
        Result := Value.Data.Serialize
      else
        Result := '';
  else
    Result := '';
  end;
end;

end.
