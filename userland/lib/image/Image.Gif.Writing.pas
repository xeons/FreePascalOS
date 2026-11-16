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
  Writing a still image as a GIF89a of one frame.

  GIF holds at most 256 colours. A picture with no more than that
  (counting transparency as one) is written exactly; anything else is
  mapped to the nearest of a fixed palette of 6 x 7 x 6 levels of red,
  green and blue (no dithering). Pixels with alpha below 128 become the
  transparent index, written in a graphic control extension; the others
  are taken as opaque.
}
unit Image.Gif.Writing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Model,
  Image.ByteWriters,
  Image.Gif.LzwEncoding;

function EncodeGif(Image: TImage): TBytes;

implementation

const
  ColorHashSize = 1031;
  RedLevels = 6;
  GreenLevels = 7;
  BlueLevels = 6;

type
  TGifPaletteBuilder = record
    Colors: array[0..255] of TColor;
    Count: LongInt;
    HashKeys: array[0..ColorHashSize - 1] of TColor;
    HashIndices: array[0..ColorHashSize - 1] of SmallInt;
    TransparentIndex: LongInt;
    Exact: Boolean;
  end;

function IsTransparent(Pixel: TColor): Boolean; inline;
begin
  Result := (Pixel shr 24) < 128;
end;

{ The palette index of an opaque Color, added when new; -1 when the
  palette is full. }
function ExactIndex(var Builder: TGifPaletteBuilder; Color: TColor): LongInt;
var
  Slot: LongInt;
begin
  Color := Color or $FF000000;
  Slot := (Color and $FFFFFF) mod ColorHashSize;
  while Builder.HashIndices[Slot] >= 0 do
  begin
    if Builder.HashKeys[Slot] = Color then
      Exit(Builder.HashIndices[Slot]);
    Inc(Slot);
    if Slot = ColorHashSize then
      Slot := 0;
  end;
  if Builder.Count >= 256 then
    Exit(-1);
  Builder.Colors[Builder.Count] := Color;
  Builder.HashKeys[Slot] := Color;
  Builder.HashIndices[Slot] := Builder.Count;
  Result := Builder.Count;
  Inc(Builder.Count);
end;

function Level(Value: Byte; Levels: LongInt): LongInt; inline;
begin
  Result := (Value * (Levels - 1) + 127) div 255;
end;

function FixedIndex(Color: TColor): LongInt; inline;
begin
  Result := (Level(RedOf(Color), RedLevels) * GreenLevels + Level(GreenOf(Color), GreenLevels)) * BlueLevels +
    Level(BlueOf(Color), BlueLevels);
end;

procedure UseFixedPalette(var Builder: TGifPaletteBuilder);
var
  Red: LongInt;
  Green: LongInt;
  Blue: LongInt;
begin
  Builder.Count := 0;
  for Red := 0 to RedLevels - 1 do
    for Green := 0 to GreenLevels - 1 do
      for Blue := 0 to BlueLevels - 1 do
      begin
        Builder.Colors[Builder.Count] := RgbColor((Red * 255) div (RedLevels - 1),
          (Green * 255) div (GreenLevels - 1), (Blue * 255) div (BlueLevels - 1));
        Inc(Builder.Count);
      end;
  Builder.Exact := False;
end;

{ Every pixel's index, building the palette. }
function MapPixels(Image: TImage; out Builder: TGifPaletteBuilder): TBytes;
var
  Count: PtrInt;
  Position: PtrInt;
  Pixel: TColor;
  PaletteIndex: LongInt;
  HasTransparency: Boolean;
  Slot: LongInt;
begin
  Count := PtrInt(Image.Width) * Image.Height;
  Result := nil;
  SetLength(Result, Count);
  Builder.Count := 0;
  Builder.Exact := True;
  for Slot := 0 to ColorHashSize - 1 do
    Builder.HashIndices[Slot] := -1;
  HasTransparency := False;
  Position := 0;
  while Position < Count do
  begin
    if IsTransparent(Image.Pixels[Position]) then
      HasTransparency := True;
    Inc(Position);
  end;
  { The transparent index comes first, so it is there however many
    colours follow. }
  Builder.TransparentIndex := -1;
  if HasTransparency then
  begin
    Builder.Colors[0] := ColorBlack;
    Builder.Count := 1;
    Builder.TransparentIndex := 0;
  end;
  Position := 0;
  while Position < Count do
  begin
    Pixel := Image.Pixels[Position];
    if IsTransparent(Pixel) then
      Result[Position] := Builder.TransparentIndex
    else
    begin
      PaletteIndex := ExactIndex(Builder, Pixel);
      if PaletteIndex < 0 then
      begin
        Builder.Exact := False;
        Break;
      end;
      Result[Position] := PaletteIndex;
    end;
    Inc(Position);
  end;
  if Builder.Exact then
    Exit;
  { Too many colours: the fixed palette, the transparent index after it. }
  UseFixedPalette(Builder);
  if HasTransparency then
  begin
    Builder.TransparentIndex := Builder.Count;
    Builder.Colors[Builder.Count] := ColorBlack;
    Inc(Builder.Count);
  end;
  Position := 0;
  while Position < Count do
  begin
    Pixel := Image.Pixels[Position];
    if IsTransparent(Pixel) then
      Result[Position] := Builder.TransparentIndex
    else
      Result[Position] := FixedIndex(Pixel);
    Inc(Position);
  end;
end;

function PaletteBits(Count: LongInt): LongInt;
begin
  Result := 1;
  while (1 shl Result) < Count do
    Inc(Result);
end;

procedure WriteSubBlocks(Writer: TImageByteWriter; const Data: TBytes);
var
  Position: PtrInt;
  BlockSize: PtrInt;
begin
  Position := 0;
  while Position < Length(Data) do
  begin
    BlockSize := Length(Data) - Position;
    if BlockSize > 255 then
      BlockSize := 255;
    Writer.WriteByte(BlockSize);
    Writer.WriteBuffer(Data[Position], BlockSize);
    Inc(Position, BlockSize);
  end;
  Writer.WriteByte(0);
end;

function EncodeGif(Image: TImage): TBytes;
var
  Builder: TGifPaletteBuilder;
  Indices: TBytes;
  Bits: LongInt;
  MinimumCodeSize: LongInt;
  Writer: TImageByteWriter;
  CodeWriter: TImageByteWriter;
  Index: LongInt;
  Color: TColor;
begin
  Indices := MapPixels(Image, Builder);
  Bits := PaletteBits(Builder.Count);
  MinimumCodeSize := Bits;
  if MinimumCodeSize < 2 then
    MinimumCodeSize := 2;
  Writer := TImageByteWriter.Create;
  CodeWriter := TImageByteWriter.Create;
  try
    Writer.WriteText('GIF89a');
    Writer.WriteWordLittle(Image.Width);
    Writer.WriteWordLittle(Image.Height);
    Writer.WriteByte($80 or ((Bits - 1) shl 4) or (Bits - 1));
    Writer.WriteByte(0);
    Writer.WriteByte(0);
    for Index := 0 to (1 shl Bits) - 1 do
    begin
      if Index < Builder.Count then
        Color := Builder.Colors[Index]
      else
        Color := ColorBlack;
      Writer.WriteByte(RedOf(Color));
      Writer.WriteByte(GreenOf(Color));
      Writer.WriteByte(BlueOf(Color));
    end;
    if Builder.TransparentIndex >= 0 then
    begin
      Writer.WriteByte($21);
      Writer.WriteByte($F9);
      Writer.WriteByte(4);
      Writer.WriteByte(1);
      Writer.WriteWordLittle(0);
      Writer.WriteByte(Builder.TransparentIndex);
      Writer.WriteByte(0);
    end;
    Writer.WriteByte($2C);
    Writer.WriteWordLittle(0);
    Writer.WriteWordLittle(0);
    Writer.WriteWordLittle(Image.Width);
    Writer.WriteWordLittle(Image.Height);
    Writer.WriteByte(0);
    Writer.WriteByte(MinimumCodeSize);
    EncodeGifLzw(@Indices[0], Length(Indices), MinimumCodeSize, CodeWriter);
    WriteSubBlocks(Writer, CodeWriter.ToBytes);
    Writer.WriteByte($3B);
    Result := Writer.ToBytes;
  finally
    CodeWriter.Free;
    Writer.Free;
  end;
end;

end.
