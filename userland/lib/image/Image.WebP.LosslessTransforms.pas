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
  VP8L's four transforms, undone the way libwebp undoes them (RFC 9649
  section 4). Pixels are ARGB LongWords ($AARRGGBB), as libdrawing's.

  - Predictor: each pixel is a difference (per channel, modulo 256)
    from one of fourteen predictions made from the pixels to its left
    and above, the mode chosen per tile of 2^Bits x 2^Bits by the green
    of a sub-image. The first pixel predicts black, the rest of the
    first line its left neighbour, the first column its upper one.
  - Colour: per tile, red was taken (green_to_red * green) / 32 from
    and blue (green_to_blue * green + red_to_blue * red) / 32, the
    multipliers signed bytes of a sub-image's pixels.
  - Subtract green: green was taken from red and blue.
  - Colour indexing: pixels are indices (in green) into a palette of up
    to 256 colours, packed 2, 4 or 8 to a pixel when there are at most
    16, 4 or 2 colours. The palette is stored as differences from the
    previous entry and padded with transparent black, so any index is
    a colour.
}
unit Image.WebP.LosslessTransforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

const
  TransformPredictor = 0;
  TransformColor = 1;
  TransformSubtractGreen = 2;
  TransformColorIndexing = 3;

type
  TLongWordArray = array of LongWord;

  TLosslessTransform = record
    Kind: LongInt;
    Bits: LongInt;
    { The width of the image the transform gives back (before packing,
      for colour indexing). }
    Width: LongInt;
    { The tiles' sub-image, or the palette. }
    Data: TLongWordArray;
  end;

{ Per channel sums and differences modulo 256. }
function AddPixels(First, Second: LongWord): LongWord; inline;
function SubtractPixels(First, Second: LongWord): LongWord; inline;
{ (Width + 2^Bits - 1) div 2^Bits. }
function SubsampledSize(Size, Bits: LongInt): LongInt; inline;

{ The prediction of mode Mode (0 to 13; 14 and 15 are black) from Left,
  Top, TopLeft and TopRight. }
function PredictPixel(Mode: LongInt; Left, Top, TopLeft, TopRight: LongWord): LongWord;

procedure UndoPredictor(Pixels: PLongWord; Width, Height: LongInt; constref Transform: TLosslessTransform);
procedure UndoColorTransform(Pixels: PLongWord; Width, Height: LongInt; constref Transform: TLosslessTransform);
procedure UndoSubtractGreen(Pixels: PLongWord; Count: PtrInt);
{ The palette's colours for the (packed) indices of Indices, IndexWidth
  x Height, into Output (Transform.Width x Height); Output may be
  Indices when nothing is packed. }
procedure UndoColorIndexing(Indices: PLongWord; IndexWidth, Height: LongInt; constref Transform: TLosslessTransform;
  Output: PLongWord);
{ Turns a palette of differences into colours, padded to the 2^(8 >>
  Bits) entries indices of that many bits can reach. }
procedure ExpandPalette(var Transform: TLosslessTransform; ColorCount: LongInt);

{ The multipliers of the colour transform from a tile's pixel. }
procedure ColorMultipliers(Code: LongWord; out GreenToRed, GreenToBlue, RedToBlue: LongInt);
function ColorTransformDelta(Multiplier, Color: LongInt): LongInt; inline;

implementation

function AddPixels(First, Second: LongWord): LongWord;
var
  AlphaGreen: QWord;
  RedBlue: QWord;
begin
  AlphaGreen := QWord(First and $FF00FF00) + QWord(Second and $FF00FF00);
  RedBlue := QWord(First and $00FF00FF) + QWord(Second and $00FF00FF);
  Result := LongWord(AlphaGreen and $FF00FF00) or LongWord(RedBlue and $00FF00FF);
end;

function SubtractPixels(First, Second: LongWord): LongWord;
var
  AlphaGreen: QWord;
  RedBlue: QWord;
begin
  AlphaGreen := QWord($00FF00FF) + QWord(First and $FF00FF00) - QWord(Second and $FF00FF00);
  RedBlue := QWord($FF00FF00) + QWord(First and $00FF00FF) - QWord(Second and $00FF00FF);
  Result := LongWord(AlphaGreen and $FF00FF00) or LongWord(RedBlue and $00FF00FF);
end;

function SubsampledSize(Size, Bits: LongInt): LongInt;
begin
  Result := (Size + (1 shl Bits) - 1) shr Bits;
end;

function Average2(First, Second: LongWord): LongWord; inline;
begin
  Result := (((First xor Second) and $FEFEFEFE) shr 1) + (First and Second);
end;

function ClipByte(Value: LongInt): LongWord; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

function Channel(Pixel: LongWord; Shift: LongInt): LongInt; inline;
begin
  Result := (Pixel shr Shift) and $FF;
end;

function ClampedAddSubtractFull(First, Second, Third: LongWord): LongWord;
var
  Shift: LongInt;
begin
  Result := 0;
  Shift := 0;
  while Shift < 32 do
  begin
    Result := Result or (ClipByte(Channel(First, Shift) + Channel(Second, Shift) - Channel(Third, Shift)) shl Shift);
    Inc(Shift, 8);
  end;
end;

function ClampedAddSubtractHalf(First, Second, Third: LongWord): LongWord;
var
  Average: LongWord;
  Shift: LongInt;
  Value: LongInt;
begin
  Average := Average2(First, Second);
  Result := 0;
  Shift := 0;
  while Shift < 32 do
  begin
    Value := Channel(Average, Shift);
    Result := Result or (ClipByte(Value + (Value - Channel(Third, Shift)) div 2) shl Shift);
    Inc(Shift, 8);
  end;
end;

{ Top if it is closer to the gradient Left + Top - TopLeft than Left
  is (by the sum of the channels' distances), else Left. }
function Select(Top, Left, TopLeft: LongWord): LongWord;
var
  Shift: LongInt;
  Difference: LongInt;
begin
  Difference := 0;
  Shift := 0;
  while Shift < 32 do
  begin
    Difference := Difference + Abs(Channel(Left, Shift) - Channel(TopLeft, Shift)) -
      Abs(Channel(Top, Shift) - Channel(TopLeft, Shift));
    Inc(Shift, 8);
  end;
  if Difference <= 0 then
    Result := Top
  else
    Result := Left;
end;

function PredictPixel(Mode: LongInt; Left, Top, TopLeft, TopRight: LongWord): LongWord;
begin
  case Mode of
    0: Result := $FF000000;
    1: Result := Left;
    2: Result := Top;
    3: Result := TopRight;
    4: Result := TopLeft;
    5: Result := Average2(Average2(Left, TopRight), Top);
    6: Result := Average2(Left, TopLeft);
    7: Result := Average2(Left, Top);
    8: Result := Average2(TopLeft, Top);
    9: Result := Average2(Top, TopRight);
    10: Result := Average2(Average2(Left, TopLeft), Average2(Top, TopRight));
    11: Result := Select(Top, Left, TopLeft);
    12: Result := ClampedAddSubtractFull(Left, Top, TopLeft);
    13: Result := ClampedAddSubtractHalf(Left, Top, TopLeft);
  else
    Result := $FF000000;
  end;
end;

procedure UndoPredictor(Pixels: PLongWord; Width, Height: LongInt; constref Transform: TLosslessTransform);
var
  X: LongInt;
  Y: LongInt;
  TilesPerRow: LongInt;
  Line: PLongWord;
  Above: PLongWord;
  Mode: LongInt;
  TileRow: LongInt;
begin
  Pixels[0] := AddPixels(Pixels[0], $FF000000);
  for X := 1 to Width - 1 do
    Pixels[X] := AddPixels(Pixels[X], Pixels[X - 1]);
  TilesPerRow := SubsampledSize(Width, Transform.Bits);
  for Y := 1 to Height - 1 do
  begin
    Line := Pixels + PtrInt(Y) * Width;
    Above := Line - Width;
    TileRow := (Y shr Transform.Bits) * TilesPerRow;
    Line[0] := AddPixels(Line[0], Above[0]);
    for X := 1 to Width - 1 do
    begin
      Mode := (Transform.Data[TileRow + (X shr Transform.Bits)] shr 8) and $F;
      { At the last column the pixel above and to the right is the
        first of this line, as libwebp has it. }
      Line[X] := AddPixels(Line[X], PredictPixel(Mode, Line[X - 1], Above[X], Above[X - 1], Above[X + 1]));
    end;
  end;
end;

function ColorTransformDelta(Multiplier, Color: LongInt): LongInt;
begin
  Result := SarLongint(Multiplier * Color, 5);
end;

function SignedByte(Value: LongWord): LongInt; inline;
begin
  Result := ShortInt(Byte(Value and $FF));
end;

procedure ColorMultipliers(Code: LongWord; out GreenToRed, GreenToBlue, RedToBlue: LongInt);
begin
  GreenToRed := SignedByte(Code);
  GreenToBlue := SignedByte(Code shr 8);
  RedToBlue := SignedByte(Code shr 16);
end;

procedure UndoColorTransform(Pixels: PLongWord; Width, Height: LongInt; constref Transform: TLosslessTransform);
var
  X: LongInt;
  Y: LongInt;
  TilesPerRow: LongInt;
  Pixel: LongWord;
  Line: PLongWord;
  GreenToRed: LongInt;
  GreenToBlue: LongInt;
  RedToBlue: LongInt;
  Green: LongInt;
  Red: LongInt;
  Blue: LongInt;
begin
  TilesPerRow := SubsampledSize(Width, Transform.Bits);
  for Y := 0 to Height - 1 do
  begin
    Line := Pixels + PtrInt(Y) * Width;
    for X := 0 to Width - 1 do
    begin
      ColorMultipliers(Transform.Data[(Y shr Transform.Bits) * TilesPerRow + (X shr Transform.Bits)], GreenToRed,
        GreenToBlue, RedToBlue);
      Pixel := Line[X];
      Green := SignedByte(Pixel shr 8);
      Red := (Pixel shr 16) and $FF;
      Blue := Pixel and $FF;
      Red := (Red + ColorTransformDelta(GreenToRed, Green)) and $FF;
      Blue := (Blue + ColorTransformDelta(GreenToBlue, Green) + ColorTransformDelta(RedToBlue, SignedByte(Red))) and
        $FF;
      Line[X] := (Pixel and $FF00FF00) or (LongWord(Red) shl 16) or LongWord(Blue);
    end;
  end;
end;

procedure UndoSubtractGreen(Pixels: PLongWord; Count: PtrInt);
var
  Index: PtrInt;
  Pixel: LongWord;
  Green: LongWord;
begin
  for Index := 0 to Count - 1 do
  begin
    Pixel := Pixels[Index];
    Green := (Pixel shr 8) and $FF;
    Pixels[Index] := (Pixel and $FF00FF00) or (((Pixel and $00FF00FF) + ((Green shl 16) or Green)) and $00FF00FF);
  end;
end;

procedure UndoColorIndexing(Indices: PLongWord; IndexWidth, Height: LongInt; constref Transform: TLosslessTransform;
  Output: PLongWord);
var
  X: LongInt;
  Y: LongInt;
  BitsPerPixel: LongInt;
  PixelsPerByteMask: LongInt;
  IndexMask: LongWord;
  PackedPixels: LongWord;
  Source: PLongWord;
  Target: PLongWord;
begin
  BitsPerPixel := 8 shr Transform.Bits;
  if Transform.Bits = 0 then
  begin
    for X := 0 to IndexWidth * Height - 1 do
      Output[X] := Transform.Data[(Indices[X] shr 8) and $FF];
    Exit;
  end;
  PixelsPerByteMask := (1 shl Transform.Bits) - 1;
  IndexMask := (LongWord(1) shl BitsPerPixel) - 1;
  for Y := 0 to Height - 1 do
  begin
    Source := Indices + PtrInt(Y) * IndexWidth;
    Target := Output + PtrInt(Y) * Transform.Width;
    PackedPixels := 0;
    for X := 0 to Transform.Width - 1 do
    begin
      if (X and PixelsPerByteMask) = 0 then
      begin
        PackedPixels := (Source^ shr 8) and $FF;
        Inc(Source);
      end;
      Target[X] := Transform.Data[PackedPixels and IndexMask];
      PackedPixels := PackedPixels shr BitsPerPixel;
    end;
  end;
end;

procedure ExpandPalette(var Transform: TLosslessTransform; ColorCount: LongInt);
var
  FinalCount: LongInt;
  Expanded: TLongWordArray;
  Index: LongInt;
begin
  FinalCount := 1 shl (8 shr Transform.Bits);
  Expanded := nil;
  SetLength(Expanded, FinalCount);
  Expanded[0] := Transform.Data[0];
  for Index := 1 to FinalCount - 1 do
    if Index < ColorCount then
      Expanded[Index] := AddPixels(Transform.Data[Index], Expanded[Index - 1])
    else
      Expanded[Index] := 0;
  Transform.Data := Expanded;
end;

end.
