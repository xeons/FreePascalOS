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
  Parts of images: a rectangle of one copied out as an image of its
  own (a crop, a selection, the pixels an edit is about to change),
  and an image put into another at a place, either replacing what is
  there or drawn over it by its alpha; an area filled; an image put on
  an opaque background. Everything is cut at the
  images' sides, so a place partly (or wholly) outside is no error.
}
unit Image.Areas;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Image.Model;

{ The image's rectangle; empty if the image has no pixels. }
function ImageBounds(Image: TImage): TRectangle;
{ Area cut to the image (empty if none of it is on the image). }
function ClipToImage(Image: TImage; const Area: TRectangle): TRectangle;
{ A new image of the pixels of Area (cut to the image first); nil if
  nothing of Area is on the image. The properties are not copied. }
function CopyImageArea(Image: TImage; const Area: TRectangle): TImage;
{ Source's pixels replace Target's with Source's top left at (X, Y). }
procedure PutImage(Target, Source: TImage; X, Y: LongInt);
{ Source drawn over Target by its alpha, its top left at (X, Y). Mask
  (Source.Width x Source.Height bytes, or empty for all) says which of
  Source's pixels count (non-zero). }
procedure DrawImageOver(Target, Source: TImage; X, Y: LongInt; const Mask: array of Byte);
{ Every pixel of Area (cut to the image) where Mask (as above, the size
  of Area) is non-zero, or all of Area, set to Color. }
procedure FillImageArea(Image: TImage; const Area: TRectangle; Color: TColor; const Mask: array of Byte);
{ Every pixel drawn over Background (opaque): the image as a format
  without transparency shows it. }
procedure FlattenImageOnto(Image: TImage; Background: TColor);

implementation

function ImageBounds(Image: TImage): TRectangle;
begin
  Result := MakeRectangle(0, 0, Image.Width, Image.Height);
end;

function ClipToImage(Image: TImage; const Area: TRectangle): TRectangle;
begin
  IntersectRectangles(Area, ImageBounds(Image), Result);
end;

function CopyImageArea(Image: TImage; const Area: TRectangle): TImage;
var
  Inside: TRectangle;
  Row: LongInt;
begin
  Inside := ClipToImage(Image, Area);
  if RectangleIsEmpty(Inside) then
    Exit(nil);
  Result := TImage.Create(RectangleWidth(Inside), RectangleHeight(Inside));
  for Row := 0 to Result.Height - 1 do
    Move(Image.Line(Inside.Top + Row)[Inside.Left], Result.Line(Row)^, PtrUInt(Result.Width) * SizeOf(LongWord));
end;

{ The part of Source at (X, Y) that lands on Target, in Target's
  coordinates; False if none. }
function Overlap(Target, Source: TImage; X, Y: LongInt; out Common: TRectangle): Boolean;
begin
  Result := IntersectRectangles(MakeRectangle(X, Y, Source.Width, Source.Height), ImageBounds(Target), Common);
end;

procedure PutImage(Target, Source: TImage; X, Y: LongInt);
var
  Common: TRectangle;
  Row: LongInt;
begin
  if not Overlap(Target, Source, X, Y, Common) then
    Exit;
  for Row := Common.Top to Common.Bottom - 1 do
    Move(Source.Line(Row - Y)[Common.Left - X], Target.Line(Row)[Common.Left],
      PtrUInt(RectangleWidth(Common)) * SizeOf(LongWord));
end;

procedure DrawImageOver(Target, Source: TImage; X, Y: LongInt; const Mask: array of Byte);
var
  Common: TRectangle;
  Row: LongInt;
  Column: LongInt;
  SourceLine: PLongWord;
  TargetLine: PLongWord;
  HasMask: Boolean;
begin
  if not Overlap(Target, Source, X, Y, Common) then
    Exit;
  HasMask := Length(Mask) = Source.Width * Source.Height;
  for Row := Common.Top to Common.Bottom - 1 do
  begin
    SourceLine := Source.Line(Row - Y);
    TargetLine := Target.Line(Row);
    for Column := Common.Left to Common.Right - 1 do
      if not HasMask or (Mask[(Row - Y) * Source.Width + Column - X] <> 0) then
        TargetLine[Column] := BlendColors(TargetLine[Column], SourceLine[Column - X]);
  end;
end;

procedure FillImageArea(Image: TImage; const Area: TRectangle; Color: TColor; const Mask: array of Byte);
var
  Inside: TRectangle;
  Row: LongInt;
  Column: LongInt;
  Line: PLongWord;
  HasMask: Boolean;
  AreaWidth: LongInt;
begin
  Inside := ClipToImage(Image, Area);
  if RectangleIsEmpty(Inside) then
    Exit;
  AreaWidth := RectangleWidth(Area);
  HasMask := Length(Mask) = AreaWidth * RectangleHeight(Area);
  for Row := Inside.Top to Inside.Bottom - 1 do
  begin
    Line := Image.Line(Row);
    for Column := Inside.Left to Inside.Right - 1 do
      if not HasMask or (Mask[(Row - Area.Top) * AreaWidth + Column - Area.Left] <> 0) then
        Line[Column] := Color;
  end;
end;

procedure FlattenImageOnto(Image: TImage; Background: TColor);
var
  Index: PtrUInt;
  Count: PtrUInt;
begin
  Background := WithAlpha(Background, AlphaOpaque);
  Count := PtrUInt(Image.Width) * PtrUInt(Image.Height);
  Index := 0;
  while Index < Count do
  begin
    Image.Pixels[Index] := BlendColors(Background, Image.Pixels[Index]);
    Inc(Index);
  end;
end;

end.
