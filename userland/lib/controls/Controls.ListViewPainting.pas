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
  Painting a list view's parts: the header of the details view (with an
  arrow on the column the items are sorted by), and an item in each
  view: a row of columns, a small icon with its name beside it, a large
  icon with its name under it.

  A selected item is highlighted (the whole row in details, the name in
  the icon views); the item with the focus gets a dotted frame while the
  list view has the focus.
}
unit Controls.ListViewPainting;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.ListItems;

{ The header across Box: a button face per column (Widths in pixels),
  then one for the rest; SortColumn (-1: none) has an arrow pointing up
  when ascending. }
procedure PaintListHeader(const Canvas: TCanvas; const Box: TRectangle; Captions: TStrings;
  const Widths: array of LongInt; SortColumn: LongInt; SortAscending: Boolean);
procedure PaintDetailsRow(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  const Widths: array of LongInt; Highlighted, FocusFrame: Boolean);
procedure PaintSmallIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame: Boolean);
procedure PaintLargeIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame: Boolean);
{ Where an item's icon is drawn within its cell (pixels). }
function SmallIconBox(const Cell: TRectangle): TRectangle;
function LargeIconBox(const Cell: TRectangle): TRectangle;
{ How wide a cell of the small icon and list views is for Caption. }
function SmallIconCellWidthFor(const Caption: string): LongInt;
function LargeIconCellWidth: LongInt;
function LargeIconCellHeight: LongInt;

implementation

uses
  Drawing.Colors,
  Drawing.Shapes,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Buttons,
  Controls.Icons;

const
  { Logical units. }
  CellPadding = 4;
  IconTextGap = 4;
  LargeCellWidth = 76;
  ArrowRoom = 16;

procedure PaintSortArrow(const Canvas: TCanvas; const Cell: TRectangle; Ascending: Boolean);
var
  Arrow: array[0..2] of TPoint;
  Middle: LongInt;
  Centre: LongInt;
  Half: LongInt;
begin
  Half := Scaled(4);
  Centre := Cell.Right - Scaled(ArrowRoom) div 2 - Scaled(2);
  Middle := Cell.Top + RectangleHeight(Cell) div 2;
  if Ascending then
  begin
    Arrow[0] := MakePoint(Centre - Half, Middle + Half div 2);
    Arrow[1] := MakePoint(Centre + Half, Middle + Half div 2);
    Arrow[2] := MakePoint(Centre, Middle - Half div 2 - 1);
  end
  else
  begin
    Arrow[0] := MakePoint(Centre - Half, Middle - Half div 2);
    Arrow[1] := MakePoint(Centre + Half, Middle - Half div 2);
    Arrow[2] := MakePoint(Centre, Middle + Half div 2 + 1);
  end;
  FillPolygon(Canvas, Arrow, Theme.Shadow);
end;

procedure PaintListHeader(const Canvas: TCanvas; const Box: TRectangle; Captions: TStrings;
  const Widths: array of LongInt; SortColumn: LongInt; SortAscending: Boolean);
var
  Column: LongInt;
  Left: LongInt;
  Cell: TRectangle;
  TextBox: TRectangle;
begin
  Left := Box.Left;
  for Column := 0 to Captions.Count - 1 do
  begin
    Cell := MakeRectangle(Left, Box.Top, Widths[Column], RectangleHeight(Box));
    DrawButtonFace(Canvas, Cell, False, False);
    TextBox := InflateRectangle(Cell, -Scaled(CellPadding));
    if Column = SortColumn then
    begin
      TextBox.Right := TextBox.Right - Scaled(ArrowRoom);
      PaintSortArrow(Canvas, Cell, SortAscending);
    end;
    DrawTextInBox(Canvas, ControlFace, Captions[Column], TextBox, AlignTextLeft, Theme.FaceText);
    Left := Left + Widths[Column];
  end;
  DrawButtonFace(Canvas, MakeRectangle(Left, Box.Top, Box.Right - Left + Scaled(4), RectangleHeight(Box)), False, False);
end;

procedure PaintDetailsRow(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  const Widths: array of LongInt; Highlighted, FocusFrame: Boolean);
var
  Column: LongInt;
  Left: LongInt;
  TextColor: TColor;
  TextBox: TRectangle;
begin
  TextColor := Theme.FieldText;
  if Highlighted then
  begin
    FillRectangle(Canvas, Cell, Theme.Selection);
    TextColor := Theme.SelectionText;
  end;
  Left := Cell.Left;
  for Column := 0 to High(Widths) do
  begin
    TextBox := MakeRectangle(Left + Scaled(CellPadding), Cell.Top, Widths[Column] - 2 * Scaled(CellPadding),
      RectangleHeight(Cell));
    DrawTextInBox(Canvas, ControlFace, Item.Cells[Column], TextBox, AlignTextLeft, TextColor);
    Left := Left + Widths[Column];
  end;
  if FocusFrame then
    DrawFocusFrame(Canvas, Cell, TextColor);
end;

function SmallIconBox(const Cell: TRectangle): TRectangle;
var
  Size: LongInt;
begin
  Size := Scaled(SmallIconSize);
  Result := MakeRectangle(Cell.Left + Scaled(2), Cell.Top + (RectangleHeight(Cell) - Size) div 2, Size, Size);
end;

function LargeIconBox(const Cell: TRectangle): TRectangle;
var
  Size: LongInt;
begin
  Size := Scaled(LargeIconSize);
  Result := MakeRectangle(Cell.Left + (RectangleWidth(Cell) - Size) div 2, Cell.Top + Scaled(CellPadding), Size, Size);
end;

function SmallIconCellWidthFor(const Caption: string): LongInt;
begin
  Result := Scaled(2 + SmallIconSize + IconTextGap) + TextWidth(ControlFace, Caption) + Scaled(2 * CellPadding + 8);
end;

function LargeIconCellWidth: LongInt;
begin
  Result := Scaled(LargeCellWidth);
end;

function LargeIconCellHeight: LongInt;
begin
  Result := Scaled(CellPadding + LargeIconSize + IconTextGap) + TextHeight(ControlFace) + Scaled(2 + CellPadding);
end;

{ The name in TextBox, highlighted if selected, framed if focused. }
procedure PaintItemName(const Canvas: TCanvas; const Caption: string; const TextBox: TRectangle;
  Alignment: THorizontalAlignment; Highlighted, FocusFrame: Boolean);
var
  TextColor: TColor;
begin
  TextColor := Theme.FieldText;
  if Highlighted then
  begin
    FillRectangle(Canvas, TextBox, Theme.Selection);
    TextColor := Theme.SelectionText;
  end;
  DrawTextInBox(Canvas, ControlFace, Caption, InflateRectangle(TextBox, -Scaled(2)), Alignment, TextColor);
  if FocusFrame then
    DrawFocusFrame(Canvas, TextBox, TextColor);
end;

procedure PaintSmallIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame: Boolean);
var
  Icon: TRectangle;
  TextLeft: LongInt;
  TextBox: TRectangle;
  Width: LongInt;
begin
  Icon := SmallIconBox(Cell);
  DrawIcon(Canvas, Item.Icon, Item.IconKind, Icon);
  TextLeft := Icon.Right + Scaled(IconTextGap);
  { The highlight fits the name, not the whole cell. }
  Width := TextWidth(ControlFace, Item.Caption) + Scaled(4);
  if TextLeft + Width > Cell.Right - Scaled(2) then
    Width := Cell.Right - Scaled(2) - TextLeft;
  TextBox := MakeRectangle(TextLeft, Cell.Top + Scaled(1), Width, RectangleHeight(Cell) - Scaled(2));
  PaintItemName(Canvas, Item.Caption, TextBox, AlignTextLeft, Highlighted, FocusFrame);
end;

procedure PaintLargeIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame: Boolean);
var
  Icon: TRectangle;
  TextBox: TRectangle;
  Width: LongInt;
begin
  Icon := LargeIconBox(Cell);
  DrawIcon(Canvas, Item.Icon, Item.IconKind, Icon);
  Width := TextWidth(ControlFace, Item.Caption) + Scaled(4);
  if Width > RectangleWidth(Cell) - Scaled(4) then
    Width := RectangleWidth(Cell) - Scaled(4);
  TextBox := MakeRectangle(Cell.Left + (RectangleWidth(Cell) - Width) div 2, Icon.Bottom + Scaled(IconTextGap), Width,
    TextHeight(ControlFace) + Scaled(2));
  PaintItemName(Canvas, Item.Caption, TextBox, AlignTextCenter, Highlighted, FocusFrame);
end;

end.
