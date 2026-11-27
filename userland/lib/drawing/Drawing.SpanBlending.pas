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
  Blending runs of pixels: the inner loops of filling and of drawing one
  surface on another, with Drawing.Colors' BlendColors on every pixel
  but the work that is the same for the whole run done once.

  A colour over a run works out its own share of every channel before
  the loop, so an opaque pixel under it costs two multiplies and a few
  shifts; runs of the same pixel (a plain background) reuse the last
  result. Surface over surface skips invisible source pixels and copies
  opaque ones, which between them are most pixels of most images.
  Results are exactly BlendColors'.
}
unit Drawing.SpanBlending;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors;

{ Color drawn over each of Count pixels from Pixels. }
procedure BlendColorSpan(Pixels: PLongWord; Count: LongInt; Color: TColor);
{ Each of Count pixels from Source drawn over the one at the same place
  from Target. }
procedure BlendPixelSpan(Target, Source: PLongWord; Count: LongInt);
{ The same with every source pixel's alpha multiplied by Opacity
  (0-255) first. }
procedure BlendFadedPixelSpan(Target, Source: PLongWord; Count: LongInt; Opacity: Byte);

implementation

procedure BlendColorSpan(Pixels: PLongWord; Count: LongInt; Color: TColor);
var
  SourceRedBlue: LongWord;
  SourceGreen: LongWord;
  DestinationWeight: LongWord;
  Index: LongInt;
  Pixel: LongWord;
  RedBlue: LongWord;
  Green: LongWord;
  LastPixel: LongWord;
  LastResult: LongWord;
begin
  if (Count <= 0) or (AlphaOf(Color) = 0) then
    Exit;
  if AlphaOf(Color) = AlphaOpaque then
  begin
    FillDWord(Pixels^, Count, Color);
    Exit;
  end;
  { BlendOverOpaque with the colour's side (and the rounding) added up
    once: what is left per pixel is the destination's side. }
  DestinationWeight := 255 - AlphaOf(Color);
  SourceRedBlue := (Color and $00FF00FF) * AlphaOf(Color) + $00800080;
  SourceGreen := GreenOf(Color) * AlphaOf(Color) + 128;
  LastPixel := Pixels[0];
  LastResult := BlendColors(LastPixel, Color);
  for Index := 0 to Count - 1 do
  begin
    Pixel := Pixels[Index];
    if Pixel <> LastPixel then
    begin
      LastPixel := Pixel;
      if Pixel >= $FF000000 then
      begin
        RedBlue := SourceRedBlue + (Pixel and $00FF00FF) * DestinationWeight;
        RedBlue := ((RedBlue + ((RedBlue shr 8) and $00FF00FF)) shr 8) and $00FF00FF;
        Green := SourceGreen + ((Pixel shr 8) and $FF) * DestinationWeight;
        Green := (Green + (Green shr 8)) shr 8;
        LastResult := $FF000000 or RedBlue or (Green shl 8);
      end
      else
        LastResult := BlendColors(Pixel, Color);
    end;
    Pixels[Index] := LastResult;
  end;
end;

procedure BlendPixelSpan(Target, Source: PLongWord; Count: LongInt);
var
  Index: LongInt;
  Pixel: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Pixel := Source[Index];
    if Pixel >= $FF000000 then
      Target[Index] := Pixel
    else if Pixel > $00FFFFFF then
      Target[Index] := BlendColors(Target[Index], Pixel);
  end;
end;

procedure BlendFadedPixelSpan(Target, Source: PLongWord; Count: LongInt; Opacity: Byte);
var
  Index: LongInt;
  Pixel: LongWord;
begin
  if Opacity = 0 then
    Exit;
  if Opacity = AlphaOpaque then
  begin
    BlendPixelSpan(Target, Source, Count);
    Exit;
  end;
  for Index := 0 to Count - 1 do
  begin
    Pixel := Source[Index];
    if Pixel > $00FFFFFF then
      Target[Index] := BlendColors(Target[Index], FadeColor(Pixel, Opacity));
  end;
end;

end.
