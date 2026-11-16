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
  A JPEG's components, a line at a time, as libdrawing's opaque
  $AARRGGBB pixels.

  YCbCr (JFIF) goes to RGB the way libjpeg does it, with its constants
  scaled by 2^16 and its rounding, so the result is exact against it.
  Greyscale is grey; three components without a transform are RGB.

  CMYK has no single right answer without colour management: the
  usual simple rule is used, each of red, green and blue being
  (255 - ink) x (255 - black) / 255. Files with an Adobe segment (as
  Photoshop and libjpeg write them) store the inks inverted (255 is no
  ink), so for them the stored values are used straight. YCCK (Adobe
  transform 2) is YCbCr giving the inverted cyan, magenta and yellow, as
  libjpeg turns it into CMYK, then the same rule.
}
unit Image.Jpeg.Color;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure ConvertGreyLine(Grey: PByte; Output: PLongWord; Width: LongInt);
procedure ConvertYCbCrLine(Luma, BlueDifference, RedDifference: PByte; Output: PLongWord; Width: LongInt);
procedure ConvertRgbLine(Red, Green, Blue: PByte; Output: PLongWord; Width: LongInt);
{ InkInverted: the samples are 255 - ink (Adobe). }
procedure ConvertCmykLine(Cyan, Magenta, Yellow, Black: PByte; Output: PLongWord; Width: LongInt;
  InkInverted: Boolean);
procedure ConvertYcckLine(Luma, BlueDifference, RedDifference, Black: PByte; Output: PLongWord; Width: LongInt);

implementation

const
  RedFromCr = 91881;     { 1.40200 x 2^16 }
  GreenFromCb = 22554;   { 0.34414 x 2^16 }
  GreenFromCr = 46802;   { 0.71414 x 2^16 }
  BlueFromCb = 116130;   { 1.77200 x 2^16 }
  OneHalf = 32768;

function Clamp(Value: LongInt): LongWord; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

procedure YCbCrToRgb(Luma, Cb, Cr: LongInt; out Red, Green, Blue: LongWord); inline;
begin
  Cb := Cb - 128;
  Cr := Cr - 128;
  Red := Clamp(Luma + SarLongint(RedFromCr * Cr + OneHalf, 16));
  Green := Clamp(Luma + SarLongint(-GreenFromCb * Cb - GreenFromCr * Cr + OneHalf, 16));
  Blue := Clamp(Luma + SarLongint(BlueFromCb * Cb + OneHalf, 16));
end;

function Opaque(Red, Green, Blue: LongWord): LongWord; inline;
begin
  Result := $FF000000 or (Red shl 16) or (Green shl 8) or Blue;
end;

procedure ConvertGreyLine(Grey: PByte; Output: PLongWord; Width: LongInt);
var
  Column: LongInt;
  Value: LongWord;
begin
  for Column := 0 to Width - 1 do
  begin
    Value := Grey[Column];
    Output[Column] := Opaque(Value, Value, Value);
  end;
end;

procedure ConvertYCbCrLine(Luma, BlueDifference, RedDifference: PByte; Output: PLongWord; Width: LongInt);
var
  Column: LongInt;
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
begin
  for Column := 0 to Width - 1 do
  begin
    YCbCrToRgb(Luma[Column], BlueDifference[Column], RedDifference[Column], Red, Green, Blue);
    Output[Column] := Opaque(Red, Green, Blue);
  end;
end;

procedure ConvertRgbLine(Red, Green, Blue: PByte; Output: PLongWord; Width: LongInt);
var
  Column: LongInt;
begin
  for Column := 0 to Width - 1 do
    Output[Column] := Opaque(Red[Column], Green[Column], Blue[Column]);
end;

function InkToLight(Remaining, BlackRemaining: LongWord): LongWord; inline;
begin
  Result := (Remaining * BlackRemaining + 127) div 255;
end;

procedure ConvertCmykLine(Cyan, Magenta, Yellow, Black: PByte; Output: PLongWord; Width: LongInt;
  InkInverted: Boolean);
var
  Column: LongInt;
  C, M, Y, K: LongWord;
begin
  for Column := 0 to Width - 1 do
  begin
    C := Cyan[Column];
    M := Magenta[Column];
    Y := Yellow[Column];
    K := Black[Column];
    if not InkInverted then
    begin
      C := 255 - C;
      M := 255 - M;
      Y := 255 - Y;
      K := 255 - K;
    end;
    Output[Column] := Opaque(InkToLight(C, K), InkToLight(M, K), InkToLight(Y, K));
  end;
end;

procedure ConvertYcckLine(Luma, BlueDifference, RedDifference, Black: PByte; Output: PLongWord; Width: LongInt);
var
  Column: LongInt;
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
  K: LongWord;
begin
  for Column := 0 to Width - 1 do
  begin
    YCbCrToRgb(Luma[Column], BlueDifference[Column], RedDifference[Column], Red, Green, Blue);
    K := Black[Column];
    { libjpeg's CMYK from YCCK is 255 - R, 255 - G, 255 - B (inverted
      inks); the light left is then that times K. }
    Output[Column] := Opaque(InkToLight(255 - Red, K), InkToLight(255 - Green, K), InkToLight(255 - Blue, K));
  end;
end;

end.
