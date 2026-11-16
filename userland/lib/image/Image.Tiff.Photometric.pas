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
  TIFF samples turned into colours, by the page's photometric
  interpretation:

    WhiteIsZero, BlackIsZero  grey, 0 white or 0 black
    RGB                       red, green, blue
    Palette                   an index into ColorMap (red values, then
                              green, then blue, 16 bits each: the high
                              byte is taken, unless every entry is below
                              256, an 8-bit map as libtiff accepts it)
    Separated (CMYK inks)     light = (255 - ink) x (255 - black) / 255
    YCbCr                     libtiff's conversion (Image.Tiff.Color)

  A sample of N bits is scaled to 8 by rounding: v x 255 / (2^N - 1),
  so 16-bit samples become (v x 255 + 32767) div 65535 and 4-bit ones
  v x 17. An extra sample that is alpha gives the alpha; associated
  (premultiplied) alpha is divided out as Pillow does it, colour x 255
  div alpha, at most 255, and left as it is where alpha is 0 or 255.
  Other extra samples are ignored.
}
unit Image.Tiff.Photometric;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model,
  Image.Tiff.Pages,
  Image.Tiff.Strips;

{ Image's pixels from the page's planes. }
procedure ConvertTiffPlanes(constref Page: TTiffPage; constref Planes: TTiffPlanes; Image: TImage);

implementation

uses
  Image.Tiff.Tags,
  Image.Tiff.Color,
  Image.Tiff.Samples;

type
  TTiffColorContext = record
    Maximum: LongWord;
    Scale: array of Byte;
    Palette: array of LongWord;
    Converter: TTiffYCbCrConverter;
    AlphaSample: LongInt;
    AlphaAssociated: Boolean;
  end;

function ScaleSample(Value, Maximum: LongWord): LongWord;
begin
  Result := (QWord(Value) * 255 + Maximum div 2) div Maximum;
end;

procedure PreparePalette(constref Page: TTiffPage; var Context: TTiffColorContext);
var
  Count: LongInt;
  Index: LongInt;
  EightBit: Boolean;
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
begin
  Count := 1 shl Page.BitsPerSample;
  EightBit := True;
  for Index := 0 to 3 * Count - 1 do
    if Page.ColorMap[Index] > 255 then
      EightBit := False;
  SetLength(Context.Palette, Count);
  for Index := 0 to Count - 1 do
  begin
    Red := Page.ColorMap[Index] and $FFFF;
    Green := Page.ColorMap[Count + Index] and $FFFF;
    Blue := Page.ColorMap[2 * Count + Index] and $FFFF;
    if not EightBit then
    begin
      Red := Red shr 8;
      Green := Green shr 8;
      Blue := Blue shr 8;
    end;
    Context.Palette[Index] := $FF000000 or (Red shl 16) or (Green shl 8) or Blue;
  end;
end;

procedure PrepareContext(constref Page: TTiffPage; var Context: TTiffColorContext);
var
  Value: LongWord;
begin
  Context.Maximum := (LongWord(1) shl Page.BitsPerSample) - 1;
  SetLength(Context.Scale, Context.Maximum + 1);
  for Value := 0 to Context.Maximum do
    Context.Scale[Value] := ScaleSample(Value, Context.Maximum);
  Context.AlphaSample := TiffAlphaSample(Page, Context.AlphaAssociated);
  if Page.Photometric = TiffPhotometricPalette then
    PreparePalette(Page, Context);
  if Page.Photometric = TiffPhotometricYCbCr then
    PrepareYCbCrConverter(Context.Converter, Page.YCbCrCoefficients, Page.ReferenceBlackWhite);
end;

function InkToLight(Ink, Black: LongWord): LongWord; inline;
begin
  Result := ((255 - Ink) * (255 - Black) + 127) div 255;
end;

function Unpremultiply(Value, Alpha: LongWord): LongWord; inline;
begin
  Result := (255 * Value) div Alpha;
  if Result > 255 then
    Result := 255;
end;

function ApplyAlpha(Color, Alpha: LongWord; Associated: Boolean): LongWord;
var
  Red: LongWord;
  Green: LongWord;
  Blue: LongWord;
begin
  if Associated and (Alpha <> 0) and (Alpha <> 255) then
  begin
    Red := Unpremultiply((Color shr 16) and $FF, Alpha);
    Green := Unpremultiply((Color shr 8) and $FF, Alpha);
    Blue := Unpremultiply(Color and $FF, Alpha);
    Color := (Red shl 16) or (Green shl 8) or Blue;
  end;
  Result := (Color and $FFFFFF) or (Alpha shl 24);
end;

function Grey(Value: LongWord): LongWord; inline;
begin
  Result := $FF000000 or (Value shl 16) or (Value shl 8) or Value;
end;

function PixelColor(constref Page: TTiffPage; constref Context: TTiffColorContext; Pixel: PLongWord): LongWord;
var
  Scale: PByte;
begin
  Scale := @Context.Scale[0];
  case Page.Photometric of
    TiffPhotometricWhiteIsZero:
      Result := Grey(255 - Scale[Pixel[0]]);
    TiffPhotometricBlackIsZero:
      Result := Grey(Scale[Pixel[0]]);
    TiffPhotometricRgb:
      Result := $FF000000 or (LongWord(Scale[Pixel[0]]) shl 16) or (LongWord(Scale[Pixel[1]]) shl 8) or
        Scale[Pixel[2]];
    TiffPhotometricPalette:
      Result := Context.Palette[Pixel[0]];
    TiffPhotometricSeparated:
      Result := $FF000000 or (InkToLight(Scale[Pixel[0]], Scale[Pixel[3]]) shl 16) or
        (InkToLight(Scale[Pixel[1]], Scale[Pixel[3]]) shl 8) or InkToLight(Scale[Pixel[2]], Scale[Pixel[3]]);
    TiffPhotometricYCbCr:
      Result := YCbCrToColor(Context.Converter, Pixel[0], Pixel[1], Pixel[2]);
  else
    Result := $FF000000;
  end;
  if Context.AlphaSample >= 0 then
    Result := ApplyAlpha(Result, Scale[Pixel[Context.AlphaSample]], Context.AlphaAssociated);
end;

procedure ConvertTiffPlanes(constref Page: TTiffPage; constref Planes: TTiffPlanes; Image: TImage);
var
  Context: TTiffColorContext;
  Samples: TTiffSampleLine;
  Y: LongInt;
  X: LongInt;
  Line: PLongWord;
  Count: LongInt;
begin
  Context := Default(TTiffColorContext);
  PrepareContext(Page, Context);
  Samples := nil;
  Count := Page.SamplesPerPixel;
  for Y := 0 to Page.Height - 1 do
  begin
    ExtractSampleLine(Page, Planes, Y, Samples);
    Line := Image.Line(Y);
    for X := 0 to Page.Width - 1 do
      Line[X] := PixelColor(Page, Context, @Samples[PtrInt(X) * Count]);
  end;
end;

end.
