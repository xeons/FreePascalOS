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
  list view has the focus. Details rows can have the small icon before
  the first column's text. Under a large icon a name that does not fit
  breaks onto a second line (after a space, dot, dash or underscore if
  there is one in reach, else where it stops fitting), and what does not
  fit on that is cut short with "...". A symbolic link's arrow is drawn
  over its icon (the item's Overlay).
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
  const Widths: array of LongInt; Highlighted, FocusFrame, ShowIcon: Boolean);
procedure PaintSmallIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame: Boolean);
procedure PaintLargeIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame, NameShown: Boolean);
{ Where an item's icon is drawn within its cell (pixels). }
function SmallIconBox(const Cell: TRectangle): TRectangle;
function LargeIconBox(const Cell: TRectangle): TRectangle;
{ Where an item's name is within its cell (pixels): the box an edit box
  for renaming it covers. }
function DetailsCaptionBox(const Cell: TRectangle; FirstColumnWidth: LongInt; ShowIcon: Boolean): TRectangle;
function SmallIconCaptionBox(const Cell: TRectangle): TRectangle;
function LargeIconCaptionBox(const Cell: TRectangle): TRectangle;
{ Splits Caption into the lines it takes under a large icon (one or
  two) for a width of Width pixels. }
procedure SplitLargeIconCaption(const Caption: string; Width: LongInt; out FirstLine, SecondLine: string);
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
  { Where a long name may break under a large icon. }
  BreakCharacters = [' ', '.', '-', '_'];

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

{ The icon of Item in Box, with its overlay. }
procedure PaintItemIcon(const Canvas: TCanvas; Item: TListItem; const Box: TRectangle);
begin
  DrawIcon(Canvas, Item.Icon, Item.IconKind, Box);
  DrawIconOverlay(Canvas, Item.Overlay, Box);
end;

function DetailsCaptionBox(const Cell: TRectangle; FirstColumnWidth: LongInt; ShowIcon: Boolean): TRectangle;
var
  Left: LongInt;
begin
  Left := Cell.Left + Scaled(CellPadding);
  if ShowIcon then
    Left := Left + Scaled(SmallIconSize + IconTextGap) - Scaled(2);
  Result := MakeRectangle(Left, Cell.Top, Cell.Left + FirstColumnWidth - Scaled(CellPadding) - Left,
    RectangleHeight(Cell));
end;

procedure PaintDetailsRow(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  const Widths: array of LongInt; Highlighted, FocusFrame, ShowIcon: Boolean);
var
  Column: LongInt;
  Left: LongInt;
  TextColor: TColor;
  TextBox: TRectangle;
  IconBox: TRectangle;
  Size: LongInt;
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
    if Column = 0 then
    begin
      TextBox := DetailsCaptionBox(Cell, Widths[0], ShowIcon);
      if ShowIcon then
      begin
        Size := Scaled(SmallIconSize);
        IconBox := MakeRectangle(Cell.Left + Scaled(2), Cell.Top + (RectangleHeight(Cell) - Size) div 2, Size, Size);
        PaintItemIcon(Canvas, Item, IconBox);
      end;
    end;
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
  { Room for a name on two lines. }
  Result := Scaled(CellPadding + LargeIconSize + IconTextGap) + 2 * TextHeight(ControlFace) + Scaled(2 + CellPadding);
end;

function SmallIconCaptionBox(const Cell: TRectangle): TRectangle;
var
  Left: LongInt;
begin
  Left := SmallIconBox(Cell).Right + Scaled(IconTextGap);
  Result := MakeRectangle(Left, Cell.Top, Cell.Right - Scaled(2) - Left, RectangleHeight(Cell));
end;

function LargeIconCaptionBox(const Cell: TRectangle): TRectangle;
begin
  Result := MakeRectangle(Cell.Left + Scaled(1), LargeIconBox(Cell).Bottom + Scaled(IconTextGap),
    RectangleWidth(Cell) - Scaled(2), TextHeight(ControlFace) + Scaled(4));
end;

{ How many bytes of Text (from its start, whole characters) fit in
  Width pixels. }
function BytesThatFit(const Text: string; Width: LongInt): LongInt;
var
  Count: LongInt;
begin
  Count := 0;
  while Count < Length(Text) do
  begin
    { The next whole UTF-8 character. }
    Inc(Count);
    while (Count < Length(Text)) and ((Ord(Text[Count + 1]) and $C0) = $80) do
      Inc(Count);
    if TextWidth(ControlFace, Copy(Text, 1, Count)) > Width then
    begin
      { Back to the end of the character before. }
      Dec(Count);
      while (Count > 0) and ((Ord(Text[Count + 1]) and $C0) = $80) do
        Dec(Count);
      Exit(Count);
    end;
  end;
  Result := Count;
end;

procedure SplitLargeIconCaption(const Caption: string; Width: LongInt; out FirstLine, SecondLine: string);
var
  Fitting: LongInt;
  BreakAt: LongInt;
begin
  SecondLine := '';
  if TextWidth(ControlFace, Caption) <= Width then
  begin
    FirstLine := Caption;
    Exit;
  end;
  Fitting := BytesThatFit(Caption, Width);
  if Fitting < 1 then
    Fitting := 1;
  { After the last break character within what fits (not the first
    character: that would leave the first line empty), else where it
    stops fitting. }
  BreakAt := Fitting;
  while (BreakAt > 1) and not (Caption[BreakAt] in BreakCharacters) do
    Dec(BreakAt);
  if BreakAt <= 1 then
    BreakAt := Fitting;
  FirstLine := Copy(Caption, 1, BreakAt);
  SecondLine := Copy(Caption, BreakAt + 1, Length(Caption));
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
  PaintItemIcon(Canvas, Item, Icon);
  TextLeft := Icon.Right + Scaled(IconTextGap);
  { The highlight fits the name, not the whole cell. }
  Width := TextWidth(ControlFace, Item.Caption) + Scaled(4);
  if TextLeft + Width > Cell.Right - Scaled(2) then
    Width := Cell.Right - Scaled(2) - TextLeft;
  TextBox := MakeRectangle(TextLeft, Cell.Top + Scaled(1), Width, RectangleHeight(Cell) - Scaled(2));
  PaintItemName(Canvas, Item.Caption, TextBox, AlignTextLeft, Highlighted, FocusFrame);
end;

procedure PaintLargeIconItem(const Canvas: TCanvas; Item: TListItem; const Cell: TRectangle;
  Highlighted, FocusFrame, NameShown: Boolean);
var
  Icon: TRectangle;
  TextBox: TRectangle;
  Width: LongInt;
  Room: LongInt;
  LineHeight: LongInt;
  FirstLine: string;
  SecondLine: string;
  TextColor: TColor;
begin
  Icon := LargeIconBox(Cell);
  PaintItemIcon(Canvas, Item, Icon);
  { (Not under an edit box renaming it: a second line would show.) }
  if not NameShown then
    Exit;
  Room := RectangleWidth(Cell) - Scaled(8);
  SplitLargeIconCaption(Item.Caption, Room, FirstLine, SecondLine);
  LineHeight := TextHeight(ControlFace);
  Width := TextWidth(ControlFace, FirstLine);
  if TextWidth(ControlFace, SecondLine) > Width then
    Width := TextWidth(ControlFace, SecondLine);
  if Width > Room then
    Width := Room;
  Width := Width + Scaled(4);
  TextBox := MakeRectangle(Cell.Left + (RectangleWidth(Cell) - Width) div 2, Icon.Bottom + Scaled(IconTextGap), Width,
    LineHeight + Scaled(2));
  if SecondLine = '' then
  begin
    PaintItemName(Canvas, FirstLine, TextBox, AlignTextCenter, Highlighted, FocusFrame);
    Exit;
  end;
  TextBox.Bottom := TextBox.Bottom + LineHeight;
  TextColor := Theme.FieldText;
  if Highlighted then
  begin
    FillRectangle(Canvas, TextBox, Theme.Selection);
    TextColor := Theme.SelectionText;
  end;
  DrawTextInBox(Canvas, ControlFace, FirstLine, MakeRectangle(TextBox.Left + Scaled(2), TextBox.Top + Scaled(1),
    Width - Scaled(4), LineHeight), AlignTextCenter, TextColor);
  DrawTextInBox(Canvas, ControlFace, SecondLine, MakeRectangle(TextBox.Left + Scaled(2), TextBox.Top + Scaled(1) +
    LineHeight, Width - Scaled(4), LineHeight), AlignTextCenter, TextColor);
  if FocusFrame then
    DrawFocusFrame(Canvas, TextBox, TextColor);
end;

end.
