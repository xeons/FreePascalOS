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
  The picture as the view shows it, zoomed: a part of the view at a
  time, into a surface of that part's size.

  Every view pixel shows the image pixel under it (Paint.ZoomMapping;
  nearest, so pixels stay square when zoomed in), with any floating
  selection's pixels drawn over the picture by their alpha. Where a
  pixel is not opaque a checkerboard shows through (squares of
  CheckerSize view pixels, light and lighter grey), so transparency can
  be seen. With the grid, the first view pixel of every image pixel's
  row and column is darkened a little, outlining each pixel. Outside the
  picture is the workspace colour.
}
unit Paint.ViewRendering;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Image.Model,
  Paint.ZoomMapping;

const
  CheckerSize = 8;
  CheckerLight: TColor = $FFFFFFFF;
  CheckerDark: TColor = $FFCCCCCC;
  GridColor: TColor = $50000000;

type
  TFloatingPixels = record
    Image: TImage;
    Left: LongInt;
    Top: LongInt;
    { Image.Width x Image.Height bytes, or empty for all. }
    Mask: array of Byte;
  end;

function NoFloatingPixels: TFloatingPixels;
{ Fills Target (Area's size) with what view pixels Area show. }
procedure RenderPictureView(const Target: TSurface; const Area: TRectangle; Image: TImage;
  const Floating: TFloatingPixels; const Mapping: TViewMapping; ShowGrid: Boolean; Workspace: TColor);
{ The colour a pixel of Color shows over the checkerboard at view pixel
  (X, Y) of the zoomed picture. }
function OverChecker(Color: TColor; ZoomedX, ZoomedY: LongInt): TColor;

implementation

function NoFloatingPixels: TFloatingPixels;
begin
  Result.Image := nil;
  Result.Left := 0;
  Result.Top := 0;
  Result.Mask := nil;
end;

function OverChecker(Color: TColor; ZoomedX, ZoomedY: LongInt): TColor;
var
  Square: TColor;
begin
  if (Color shr 24) = AlphaOpaque then
    Exit(Color);
  if ((ZoomedX div CheckerSize) + (ZoomedY div CheckerSize)) and 1 = 0 then
    Square := CheckerLight
  else
    Square := CheckerDark;
  Result := BlendColors(Square, Color);
end;

{ The colour of image pixel (Column, Row) with the floating pixels over
  it. }
function PixelColor(Image: TImage; const Floating: TFloatingPixels; Column, Row: LongInt): TColor;
var
  FloatX: LongInt;
  FloatY: LongInt;
  Index: LongInt;
begin
  Result := Image.Line(Row)[Column];
  if Floating.Image = nil then
    Exit;
  FloatX := Column - Floating.Left;
  FloatY := Row - Floating.Top;
  if (FloatX < 0) or (FloatY < 0) or (FloatX >= Floating.Image.Width) or (FloatY >= Floating.Image.Height) then
    Exit;
  Index := FloatY * Floating.Image.Width + FloatX;
  if (Length(Floating.Mask) = Floating.Image.Width * Floating.Image.Height) and (Floating.Mask[Index] = 0) then
    Exit;
  Result := BlendColors(Result, Floating.Image.Pixels[Index]);
end;

procedure RenderPictureView(const Target: TSurface; const Area: TRectangle; Image: TImage;
  const Floating: TFloatingPixels; const Mapping: TViewMapping; ShowGrid: Boolean; Workspace: TColor);
var
  Columns: array of LongInt;
  ColumnStarts: array of Boolean;
  Index: LongInt;
  X: LongInt;
  Y: LongInt;
  Row: LongInt;
  RowStarts: Boolean;
  Line: PLongWord;
  Color: TColor;
  Gridded: Boolean;
begin
  Columns := nil;
  ColumnStarts := nil;
  SetLength(Columns, Target.Width);
  SetLength(ColumnStarts, Target.Width);
  for Index := 0 to Target.Width - 1 do
  begin
    X := Area.Left + Index;
    Columns[Index] := ImageColumnAt(Mapping, X);
    ColumnStarts[Index] := PixelStartX(Mapping, Columns[Index]) = X;
  end;
  Gridded := ShowGrid and GridShows(Mapping.Zoom);
  for Y := 0 to Target.Height - 1 do
  begin
    Line := SurfaceLine(Target, Y);
    Row := ImageRowAt(Mapping, Area.Top + Y);
    RowStarts := PixelStartY(Mapping, Row) = Area.Top + Y;
    for Index := 0 to Target.Width - 1 do
    begin
      if (Row < 0) or (Row >= Image.Height) or (Columns[Index] < 0) or (Columns[Index] >= Image.Width) then
      begin
        Line[Index] := Workspace;
        Continue;
      end;
      Color := PixelColor(Image, Floating, Columns[Index], Row);
      Color := OverChecker(Color, Area.Left + Index - Mapping.OriginX + Mapping.ScrollX,
        Area.Top + Y - Mapping.OriginY + Mapping.ScrollY);
      if Gridded and (RowStarts or ColumnStarts[Index]) then
        Color := BlendColors(Color, GridColor);
      Line[Index] := Color;
    end;
  end;
end;

end.
