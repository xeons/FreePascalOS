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
  How an image list (Controls.ImageList) draws a picture of something
  disabled or selected: new images made from the picture, which it
  keeps.

  - Greyed: each pixel's brightness as a grey, lightened a little, at
    half its opacity, so it reads as unavailable on any background.
  - Tinted: each pixel mixed with a colour (the selection's) by Weight
    (0-255), its opacity kept, as a selected item's picture is shown.
}
unit Controls.ImageEffects;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Image.Model;

function GreyedImage(Image: TImage): TImage;
function TintedImage(Image: TImage; Tint: TColor; Weight: Byte): TImage;
{ One pixel of each (for tests). }
function GreyedColor(Color: TColor): TColor;
function TintedColor(Color, Tint: TColor; Weight: Byte): TColor;

implementation

const
  { How far the grey goes towards white (of 255), and the opacity kept. }
  GreyLightening = 64;
  GreyOpacity = 128;

function GreyedColor(Color: TColor): TColor;
var
  Brightness: LongWord;
begin
  { Rec. 601 weights, out of 1024. }
  Brightness := (RedOf(Color) * 306 + GreenOf(Color) * 601 + BlueOf(Color) * 117 + 512) shr 10;
  Brightness := Brightness + ((255 - Brightness) * GreyLightening + 127) div 255;
  Result := FadeColor(ArgbColor(AlphaOf(Color), Brightness, Brightness, Brightness), GreyOpacity);
end;

function TintedColor(Color, Tint: TColor; Weight: Byte): TColor;
begin
  Result := WithAlpha(MixColors(WithAlpha(Color, AlphaOpaque), WithAlpha(Tint, AlphaOpaque), Weight), AlphaOf(Color));
end;

function GreyedImage(Image: TImage): TImage;
var
  Index: PtrInt;
  Count: PtrInt;
begin
  Result := TImage.Create(Image.Width, Image.Height);
  Count := PtrInt(Image.Width) * Image.Height;
  for Index := 0 to Count - 1 do
    Result.Pixels[Index] := GreyedColor(Image.Pixels[Index]);
end;

function TintedImage(Image: TImage; Tint: TColor; Weight: Byte): TImage;
var
  Index: PtrInt;
  Count: PtrInt;
begin
  Result := TImage.Create(Image.Width, Image.Height);
  Count := PtrInt(Image.Width) * Image.Height;
  for Index := 0 to Count - 1 do
    Result.Pixels[Index] := TintedColor(Image.Pixels[Index], Tint, Weight);
end;

end.
