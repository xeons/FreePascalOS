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
  Icons: a program's own (a surface) or a stock one drawn as shapes.

  Stock icons (a document, a folder) are drawn for the box they are
  given, so they are sharp at any size and display scale; there are no
  pictures of them to load. A program's own icon is a surface stretched
  to the box (and blended by its alpha), so one picture serves the small
  and the large size.
}
unit Controls.Icons;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas;

type
  TStockIcon = (StockIconDocument, StockIconFolder);

const
  { Sizes in logical units: small icons (beside text), large icons
    (above it). }
  SmallIconSize = 16;
  LargeIconSize = 32;

procedure DrawStockIcon(const Canvas: TCanvas; Icon: TStockIcon; const Box: TRectangle);
{ Icon if it has pixels, else the stock icon Fallback. }
procedure DrawIcon(const Canvas: TCanvas; const Icon: TSurface; Fallback: TStockIcon; const Box: TRectangle);

implementation

uses
  Drawing.Colors,
  Drawing.Shapes;

const
  { The stock icons are designed on a grid this many steps across. }
  GridSize = 32;
  PageColor = $FFFFFFFF;
  PageOutlineColor = $FF4A4F57;
  PageFoldColor = $FFD5D9DF;
  PageLinesColor = $FF5B87C0;
  FolderColor = $FFE9C153;
  FolderTabColor = $FFD9A93A;
  FolderOutlineColor = $FF8A6418;

{ Grid point (Column, Row) of the design in Box's pixels. }
function GridPoint(const Box: TRectangle; Column, Row: LongInt): TPoint;
begin
  Result := MakePoint(Box.Left + Column * RectangleWidth(Box) div GridSize,
    Box.Top + Row * RectangleHeight(Box) div GridSize);
end;

procedure DrawDocument(const Canvas: TCanvas; const Box: TRectangle);
var
  Page: array[0..4] of TPoint;
  Fold: array[0..2] of TPoint;
  Row: LongInt;
  Step: LongInt;
  Left: LongInt;
  Right: LongInt;
begin
  { A page with its top right corner folded over. }
  Page[0] := GridPoint(Box, 6, 1);
  Page[1] := GridPoint(Box, 19, 1);
  Page[2] := GridPoint(Box, 26, 8);
  Page[3] := GridPoint(Box, 26, 31);
  Page[4] := GridPoint(Box, 6, 31);
  FillPolygon(Canvas, Page, PageColor);
  DrawPolygonOutline(Canvas, Page, PageOutlineColor);
  Fold[0] := GridPoint(Box, 19, 1);
  Fold[1] := GridPoint(Box, 19, 8);
  Fold[2] := GridPoint(Box, 26, 8);
  FillPolygon(Canvas, Fold, PageFoldColor);
  DrawPolygonOutline(Canvas, Fold, PageOutlineColor);
  { Lines of text: fewer of them on a small page, so they stay apart. }
  Step := 4;
  if RectangleHeight(Box) < 24 then
    Step := 6;
  Left := GridPoint(Box, 10, 0).X;
  Right := GridPoint(Box, 23, 0).X;
  Row := 12;
  while Row <= 27 do
  begin
    DrawHorizontalLine(Canvas, Left, Right, GridPoint(Box, 0, Row).Y, PageLinesColor);
    Row := Row + Step;
  end;
end;

procedure DrawFolder(const Canvas: TCanvas; const Box: TRectangle);
var
  Tab: array[0..3] of TPoint;
  Body: array[0..3] of TPoint;
begin
  { A tab sticking up behind the body, at the left. }
  Tab[0] := GridPoint(Box, 2, 9);
  Tab[1] := GridPoint(Box, 4, 5);
  Tab[2] := GridPoint(Box, 13, 5);
  Tab[3] := GridPoint(Box, 15, 9);
  FillPolygon(Canvas, Tab, FolderTabColor);
  DrawPolygonOutline(Canvas, Tab, FolderOutlineColor);
  Body[0] := GridPoint(Box, 2, 9);
  Body[1] := GridPoint(Box, 30, 9);
  Body[2] := GridPoint(Box, 30, 27);
  Body[3] := GridPoint(Box, 2, 27);
  FillPolygon(Canvas, Body, FolderColor);
  DrawPolygonOutline(Canvas, Body, FolderOutlineColor);
end;

procedure DrawStockIcon(const Canvas: TCanvas; Icon: TStockIcon; const Box: TRectangle);
begin
  if RectangleIsEmpty(Box) then
    Exit;
  case Icon of
    StockIconDocument: DrawDocument(Canvas, Box);
    StockIconFolder: DrawFolder(Canvas, Box);
  end;
end;

procedure DrawIcon(const Canvas: TCanvas; const Icon: TSurface; Fallback: TStockIcon; const Box: TRectangle);
begin
  if (Icon.Pixels <> nil) and (Icon.Width > 0) and (Icon.Height > 0) then
    DrawSurfaceStretched(Canvas, Icon, SurfaceBounds(Icon), Box, True)
  else
    DrawStockIcon(Canvas, Fallback, Box);
end;

end.
