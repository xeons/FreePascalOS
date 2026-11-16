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
  YCbCr samples (not JPEG compressed) to RGB, as libtiff converts them:
  tables made once from the page's coefficients (YCbCrCoefficients,
  Rec. 601's by default) and reference black and white
  (ReferenceBlackWhite, full range by default), in 16-bit fixed point
  with single precision where libtiff uses it, so the colours are
  libtiff's to the last bit. With the defaults this is the same
  arithmetic as JPEG's conversion.
}
unit Image.Tiff.Color;

{$mode objfpc}
{$H+}

interface

type
  TTiffYCbCrConverter = record
    LumaTable: array[0..255] of LongInt;
    RedFromCr: array[0..255] of LongInt;
    BlueFromCb: array[0..255] of LongInt;
    GreenFromCr: array[0..255] of LongInt;
    GreenFromCb: array[0..255] of LongInt;
  end;

procedure PrepareYCbCrConverter(out Converter: TTiffYCbCrConverter; const Coefficients: array of Double;
  const ReferenceBlackWhite: array of Double);
{ The colour (opaque, $AARRGGBB) of one sample triple. }
function YCbCrToColor(constref Converter: TTiffYCbCrConverter; Luma, Cb, Cr: LongInt): LongWord;

implementation

const
  Shift = 16;
  OneHalf = LongInt(1) shl (Shift - 1);

function Fix(Value: Single): LongInt;
begin
  Result := Trunc(Value * (LongInt(1) shl Shift) + 0.5);
end;

function ClampSingle(Value, Lowest, Highest: Single): Single;
begin
  if Value < Lowest then
    Result := Lowest
  else if Value > Highest then
    Result := Highest
  else
    Result := Value;
end;

{ libtiff's Code2V: a code from its reference range to the nominal one. }
function CodeToValue(Code: LongInt; ReferenceBlack, ReferenceWhite: Single; Range: Single): Single;
var
  Black: LongInt;
  Span: Single;
begin
  Black := Trunc(ReferenceBlack);
  Span := ReferenceWhite - ReferenceBlack;
  if Span = 0 then
    Span := 1;
  Result := Single(Single(Code - Black) * Range) / Span;
end;

function ClampedTrunc(Value: Single): LongInt;
begin
  Result := Trunc(ClampSingle(Value, -128.0 * 32, 128.0 * 32));
end;

procedure PrepareYCbCrConverter(out Converter: TTiffYCbCrConverter; const Coefficients: array of Double;
  const ReferenceBlackWhite: array of Double);
var
  LumaRed: Single;
  LumaGreen: Single;
  LumaBlue: Single;
  F1, F2, F3, F4: Single;
  D1, D2, D3, D4: LongInt;
  Index: LongInt;
  Code: LongInt;
  Cr: LongInt;
  Cb: LongInt;
begin
  LumaRed := Coefficients[0];
  LumaGreen := Coefficients[1];
  LumaBlue := Coefficients[2];
  F1 := 2 - 2 * LumaRed;
  D1 := Fix(ClampSingle(F1, 0, 2));
  F2 := LumaRed * F1 / LumaGreen;
  D2 := -Fix(ClampSingle(F2, 0, 2));
  F3 := 2 - 2 * LumaBlue;
  D3 := Fix(ClampSingle(F3, 0, 2));
  F4 := LumaBlue * F3 / LumaGreen;
  D4 := -Fix(ClampSingle(F4, 0, 2));
  for Index := 0 to 255 do
  begin
    Code := Index - 128;
    Cr := ClampedTrunc(CodeToValue(Code, ReferenceBlackWhite[4] - 128.0, ReferenceBlackWhite[5] - 128.0, 127));
    Cb := ClampedTrunc(CodeToValue(Code, ReferenceBlackWhite[2] - 128.0, ReferenceBlackWhite[3] - 128.0, 127));
    Converter.RedFromCr[Index] := SarLongint(D1 * Cr + OneHalf, Shift);
    Converter.BlueFromCb[Index] := SarLongint(D3 * Cb + OneHalf, Shift);
    Converter.GreenFromCr[Index] := D2 * Cr;
    Converter.GreenFromCb[Index] := D4 * Cb + OneHalf;
    Converter.LumaTable[Index] := ClampedTrunc(CodeToValue(Code + 128, ReferenceBlackWhite[0],
      ReferenceBlackWhite[1], 255));
  end;
end;

function Clamp(Value: LongInt): LongWord; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

function YCbCrToColor(constref Converter: TTiffYCbCrConverter; Luma, Cb, Cr: LongInt): LongWord;
var
  Base: LongInt;
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
begin
  Base := Converter.LumaTable[Luma and $FF];
  Red := Clamp(Base + Converter.RedFromCr[Cr and $FF]);
  Green := Clamp(Base + SarLongint(Converter.GreenFromCb[Cb and $FF] + Converter.GreenFromCr[Cr and $FF], Shift));
  Blue := Clamp(Base + Converter.BlueFromCb[Cb and $FF]);
  Result := $FF000000 or (Red shl 16) or (Green shl 8) or Blue;
end;

end.
