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
  Painting an item view's items in each view, and its group headers.

  Sizes come from the view (ItemIconSize, the cell sizes below), in
  logical units scaled to the display's pixels:

    extra large, large, medium icons  the icon (or thumbnail) above its
                                      name (two lines, then "...")
    small icons, list                 a small icon with its name beside
    details                           a row of columns, a small icon first
    tiles                             a medium icon, the name and two
                                      more lines (Tile columns) beside it
    content                           a medium icon, the name and type,
                                      and two more columns at the right
                                      with their captions, a line under

  A thumbnail is drawn instead of the icon where the icon is 32 or more
  units, fitted into the icon's square keeping its shape, with a thin
  frame. A selected item is filled with the selection colour (the whole
  cell), one under the pointer with a tint of it, a drop target like a
  selected one; the focused item has a dotted frame while the view has
  the focus; a dimmed item (cut) is drawn faded. With check boxes on,
  each item has one at its top left (icon views) or before its icon,
  checked when it is selected.

  A group header is the group's caption and its count, a chevron
  (pointing down when open), and a line along the rest of the width.
}
unit Controls.ItemViewPainting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.ItemViewItems,
  Controls.ItemViewLayout;

type
  TItemPaintState = record
    Selected: Boolean;
    Hot: Boolean;
    Focused: Boolean;
    DropTarget: Boolean;
    CheckBox: Boolean;
    { The name is left out (an edit box covers it). }
    NameHidden: Boolean;
  end;

  { What painting needs of the view's columns: the visible ones, in
    order, their pixel widths and their captions. }
  TItemPaintColumns = record
    Indexes: array of LongInt;
    Widths: array of LongInt;
    Captions: array of string;
    Alignments: array of LongInt;
  end;

{ Logical units. }
function ItemIconSize(Mode: TItemViewMode): LongInt;
{ Pixels: the cell of an item in the views of equal cells. }
function IconCellWidth(Mode: TItemViewMode): LongInt;
function IconCellHeight(Mode: TItemViewMode): LongInt;
function RowHeight(Mode: TItemViewMode; Compact: Boolean): LongInt;
function GroupHeaderHeight: LongInt;
{ A small-icon cell wide enough for Caption (list, small icons). }
function SmallCellWidthFor(const Caption: string): LongInt;
{ Where the icon and the name are within a cell (pixels). }
function ItemIconBox(Mode: TItemViewMode; const Cell: TRectangle; FirstColumnWidth: LongInt;
  CheckBoxes: Boolean): TRectangle;
function ItemNameBox(Mode: TItemViewMode; const Cell: TRectangle; FirstColumnWidth: LongInt;
  CheckBoxes: Boolean): TRectangle;
function ItemCheckBox(Mode: TItemViewMode; const Cell: TRectangle): TRectangle;
procedure PaintItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState; const Columns: TItemPaintColumns; const TileColumns: array of LongInt);
procedure PaintGroupHeader(const Canvas: TCanvas; const Box: TRectangle; const Caption: string; Count: LongInt;
  Collapsed, Hot: Boolean);

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Drawing.Surfaces,
  Drawing.Scaling,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Icons,
  Controls.IconTheme,
  Controls.CheckMarks,
  Controls.ListViewPainting,
  Controls.Painting;

const
  CellPadding = 4;
  IconTextGap = 4;
  CheckBoxRoom = 18;
  TileWidth = 250;
  { Weight of the selection colour in a hover tint (of 255). }
  HotTint = 60;

function ItemIconSize(Mode: TItemViewMode): LongInt;
begin
  case Mode of
    ItemViewExtraLargeIcons: Result := 160;
    ItemViewLargeIcons: Result := 96;
    ItemViewMediumIcons, ItemViewTiles, ItemViewContent: Result := 48;
  else
    Result := SmallIconSize;
  end;
end;

function IconCellWidth(Mode: TItemViewMode): LongInt;
begin
  case Mode of
    ItemViewExtraLargeIcons: Result := Scaled(184);
    ItemViewLargeIcons: Result := Scaled(120);
    ItemViewMediumIcons: Result := Scaled(88);
    ItemViewTiles: Result := Scaled(TileWidth);
  else
    Result := Scaled(200);
  end;
end;

function IconCellHeight(Mode: TItemViewMode): LongInt;
begin
  case Mode of
    ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons:
      Result := Scaled(CellPadding + ItemIconSize(Mode) + IconTextGap) + 2 * TextHeight(ControlFace) +
        Scaled(2 + CellPadding);
    ItemViewTiles, ItemViewContent: Result := Scaled(ItemIconSize(Mode) + 2 * CellPadding + 6);
  else
    Result := RowHeight(Mode, False);
  end;
end;

function RowHeight(Mode: TItemViewMode; Compact: Boolean): LongInt;
begin
  if Compact then
    Result := TextHeight(ControlFace) + Scaled(2)
  else
    Result := TextHeight(ControlFace) + Scaled(8);
  if Result < Scaled(SmallIconSize + 2) then
    Result := Scaled(SmallIconSize + 2);
end;

function GroupHeaderHeight: LongInt;
begin
  Result := TextHeight(ControlBoldFace) + Scaled(10);
end;

function SmallCellWidthFor(const Caption: string): LongInt;
begin
  Result := Scaled(CheckBoxRoom + SmallIconSize + IconTextGap + 2 * CellPadding + 8) + TextWidth(ControlFace, Caption);
end;

function ItemCheckBox(Mode: TItemViewMode; const Cell: TRectangle): TRectangle;
var
  Size: LongInt;
begin
  Size := CheckMarkSize;
  if Mode in [ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons, ItemViewTiles, ItemViewContent] then
    Result := MakeRectangle(Cell.Left + Scaled(3), Cell.Top + Scaled(3), Size, Size)
  else
    Result := MakeRectangle(Cell.Left + Scaled(2), Cell.Top + (RectangleHeight(Cell) - Size) div 2, Size, Size);
end;

function ItemIconBox(Mode: TItemViewMode; const Cell: TRectangle; FirstColumnWidth: LongInt;
  CheckBoxes: Boolean): TRectangle;
var
  Size: LongInt;
  Left: LongInt;
begin
  Size := Scaled(ItemIconSize(Mode));
  case Mode of
    ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons:
      Result := MakeRectangle(Cell.Left + (RectangleWidth(Cell) - Size) div 2, Cell.Top + Scaled(CellPadding), Size,
        Size);
    ItemViewTiles, ItemViewContent:
      begin
        Left := Cell.Left + Scaled(CellPadding);
        if CheckBoxes then
          Left := Left + Scaled(CheckBoxRoom);
        Result := MakeRectangle(Left, Cell.Top + (RectangleHeight(Cell) - Size) div 2, Size, Size);
      end;
  else
    begin
      Left := Cell.Left + Scaled(CellPadding);
      if CheckBoxes then
        Left := Left + Scaled(CheckBoxRoom);
      Result := MakeRectangle(Left, Cell.Top + (RectangleHeight(Cell) - Size) div 2, Size, Size);
    end;
  end;
end;

function ItemNameBox(Mode: TItemViewMode; const Cell: TRectangle; FirstColumnWidth: LongInt;
  CheckBoxes: Boolean): TRectangle;
var
  Icon: TRectangle;
  Left: LongInt;
  Right: LongInt;
  LineHeight: LongInt;
begin
  Icon := ItemIconBox(Mode, Cell, FirstColumnWidth, CheckBoxes);
  LineHeight := TextHeight(ControlFace);
  case Mode of
    ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons:
      Result := MakeRectangle(Cell.Left + Scaled(2), Icon.Bottom + Scaled(IconTextGap), RectangleWidth(Cell) - Scaled(4),
        LineHeight + Scaled(4));
    ItemViewTiles, ItemViewContent:
      begin
        Left := Icon.Right + Scaled(IconTextGap * 2);
        Right := Cell.Right - Scaled(CellPadding);
        if Mode = ItemViewContent then
          Right := Cell.Left + RectangleWidth(Cell) div 2;
        Result := MakeRectangle(Left, Cell.Top + Scaled(CellPadding + 2), Right - Left, LineHeight + Scaled(2));
      end;
    ItemViewDetails:
      begin
        Left := Icon.Right + Scaled(IconTextGap);
        Result := MakeRectangle(Left, Cell.Top, Cell.Left + FirstColumnWidth - Scaled(CellPadding) - Left,
          RectangleHeight(Cell));
      end;
  else
    begin
      Left := Icon.Right + Scaled(IconTextGap);
      Result := MakeRectangle(Left, Cell.Top, Cell.Right - Scaled(2) - Left, RectangleHeight(Cell));
    end;
  end;
end;

{ The item's picture in Box: its thumbnail (fitted, framed) at the
  larger sizes, else its theme icon or stock icon; its overlay over it. }
procedure PaintItemPicture(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Box: TRectangle);
var
  Thumbnail: TSurface;
  Width: LongInt;
  Height: LongInt;
  Fitted: TRectangle;
  Frame: TRectangle;
begin
  if Item.HasThumbnail and (ItemIconSize(Mode) >= 32) then
  begin
    Thumbnail := Item.Thumbnail;
    if Thumbnail.Width >= Thumbnail.Height then
    begin
      Width := RectangleWidth(Box);
      Height := Thumbnail.Height * Width div Thumbnail.Width;
    end
    else
    begin
      Height := RectangleHeight(Box);
      Width := Thumbnail.Width * Height div Thumbnail.Height;
    end;
    if Width < 1 then
      Width := 1;
    if Height < 1 then
      Height := 1;
    Fitted := MakeRectangle(Box.Left + (RectangleWidth(Box) - Width) div 2, Box.Bottom - Height, Width, Height);
    DrawSurfaceScaled(Canvas, Thumbnail, SurfaceBounds(Thumbnail), Fitted, True);
    Frame := InflateRectangle(Fitted, 1);
    DrawRectangleOutline(Canvas, Frame, Theme.Shadow);
  end
  else if (Item.IconName = '') or not DrawThemeIcon(Canvas, Item.IconName, Box) then
    DrawStockIcon(Canvas, Item.IconKind, Box);
  DrawIconOverlay(Canvas, Item.Overlay, Box);
end;

function TextColorFor(const State: TItemPaintState; Dimmed: Boolean): TColor;
begin
  if State.Selected or State.DropTarget then
    Result := Theme.SelectionText
  else if Dimmed then
    Result := MixColors(Theme.Field, Theme.FieldText, 140)
  else
    Result := Theme.FieldText;
end;

function QuieterColorFor(const State: TItemPaintState): TColor;
begin
  if State.Selected or State.DropTarget then
    Result := Theme.SelectionText
  else
    Result := MixColors(Theme.Field, Theme.FieldText, 150);
end;

procedure PaintBackground(const Canvas: TCanvas; const Box: TRectangle; const State: TItemPaintState);
begin
  if State.Selected or State.DropTarget then
    FillRectangle(Canvas, Box, Theme.Selection)
  else if State.Hot then
    FillRectangle(Canvas, Box, MixColors(Theme.Field, Theme.Selection, HotTint));
end;

procedure PaintCheck(const Canvas: TCanvas; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState);
var
  StateOfBox: TCheckState;
begin
  if not State.CheckBox then
    Exit;
  { In the icon views only on items selected or under the pointer, as
    the boxes would crowd the pictures otherwise. }
  if (Mode in [ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons]) and not State.Selected and
     not State.Hot then
    Exit;
  if State.Selected then
    StateOfBox := CheckChecked
  else
    StateOfBox := CheckUnchecked;
  DrawCheckMark(Canvas, ItemCheckBox(Mode, Cell), StateOfBox, True);
end;

procedure PaintIconViewItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState);
var
  Icon: TRectangle;
  NameBox: TRectangle;
  FirstLine: string;
  SecondLine: string;
  LineHeight: LongInt;
  Room: LongInt;
  Color: TColor;
begin
  PaintBackground(Canvas, InflateRectangle(Cell, -Scaled(1)), State);
  Icon := ItemIconBox(Mode, Cell, 0, False);
  PaintItemPicture(Canvas, Item, Mode, Icon);
  PaintCheck(Canvas, Mode, Cell, State);
  if not State.NameHidden then
  begin
    Room := RectangleWidth(Cell) - Scaled(8);
    SplitLargeIconCaption(Item.Caption, Room, FirstLine, SecondLine);
    LineHeight := TextHeight(ControlFace);
    NameBox := ItemNameBox(Mode, Cell, 0, False);
    Color := TextColorFor(State, Item.Dimmed);
    DrawTextInBox(Canvas, ControlFace, FirstLine, MakeRectangle(NameBox.Left, NameBox.Top, RectangleWidth(NameBox),
      LineHeight), AlignTextCenter, Color);
    if SecondLine <> '' then
      DrawTextInBox(Canvas, ControlFace, SecondLine, MakeRectangle(NameBox.Left, NameBox.Top + LineHeight,
        RectangleWidth(NameBox), LineHeight), AlignTextCenter, Color);
  end;
  if State.Focused then
    DrawFocusFrame(Canvas, InflateRectangle(Cell, -Scaled(1)), TextColorFor(State, False));
end;

procedure PaintSmallItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState);
var
  Icon: TRectangle;
  NameBox: TRectangle;
  Highlight: TRectangle;
  Width: LongInt;
begin
  Icon := ItemIconBox(Mode, Cell, 0, State.CheckBox);
  NameBox := ItemNameBox(Mode, Cell, 0, State.CheckBox);
  Width := TextWidth(ControlFace, Item.Caption) + Scaled(6);
  if NameBox.Left + Width > Cell.Right then
    Width := Cell.Right - NameBox.Left;
  Highlight := MakeRectangle(Cell.Left, Cell.Top + Scaled(1), NameBox.Left + Width - Cell.Left,
    RectangleHeight(Cell) - Scaled(2));
  PaintBackground(Canvas, Highlight, State);
  PaintCheck(Canvas, Mode, Cell, State);
  PaintItemPicture(Canvas, Item, Mode, Icon);
  if not State.NameHidden then
    DrawTextInBox(Canvas, ControlFace, Item.Caption, MakeRectangle(NameBox.Left + Scaled(2), NameBox.Top,
      RectangleWidth(NameBox) - Scaled(2), RectangleHeight(NameBox)), AlignTextLeft, TextColorFor(State, Item.Dimmed));
  if State.Focused then
    DrawFocusFrame(Canvas, Highlight, TextColorFor(State, False));
end;

function AlignmentOf(Value: LongInt): THorizontalAlignment;
begin
  Result := THorizontalAlignment(Value);
end;

procedure PaintDetailsItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState; const Columns: TItemPaintColumns);
var
  Index: LongInt;
  Left: LongInt;
  FirstWidth: LongInt;
  TextBox: TRectangle;
  Color: TColor;
  Row: TRectangle;
begin
  FirstWidth := RectangleWidth(Cell);
  if Length(Columns.Widths) > 0 then
    FirstWidth := Columns.Widths[0];
  Row := Cell;
  Left := Cell.Left;
  for Index := 0 to High(Columns.Widths) do
    Left := Left + Columns.Widths[Index];
  if Left < Row.Right then
    Row.Right := Left;
  PaintBackground(Canvas, Row, State);
  PaintCheck(Canvas, Mode, Cell, State);
  PaintItemPicture(Canvas, Item, Mode, ItemIconBox(Mode, Cell, FirstWidth, State.CheckBox));
  Color := TextColorFor(State, Item.Dimmed);
  Left := Cell.Left;
  for Index := 0 to High(Columns.Widths) do
  begin
    if Index = 0 then
    begin
      if not State.NameHidden then
        DrawTextInBox(Canvas, ControlFace, Item.Caption, ItemNameBox(Mode, Cell, FirstWidth, State.CheckBox),
          AlignTextLeft, Color);
    end
    else
    begin
      TextBox := MakeRectangle(Left + Scaled(CellPadding), Cell.Top, Columns.Widths[Index] - 2 * Scaled(CellPadding),
        RectangleHeight(Cell));
      DrawTextInBox(Canvas, ControlFace, Item.Cells[Columns.Indexes[Index]], TextBox,
        AlignmentOf(Columns.Alignments[Index]), QuieterColorFor(State));
    end;
    Left := Left + Columns.Widths[Index];
  end;
  if State.Focused then
    DrawFocusFrame(Canvas, Row, Color);
end;

procedure PaintTileItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState; const TileColumns: array of LongInt);
var
  NameBox: TRectangle;
  LineHeight: LongInt;
  Index: LongInt;
  Line: TRectangle;
begin
  PaintBackground(Canvas, InflateRectangle(Cell, -Scaled(1)), State);
  PaintCheck(Canvas, Mode, Cell, State);
  PaintItemPicture(Canvas, Item, Mode, ItemIconBox(Mode, Cell, 0, State.CheckBox));
  NameBox := ItemNameBox(Mode, Cell, 0, State.CheckBox);
  LineHeight := TextHeight(ControlFace);
  if not State.NameHidden then
    DrawTextInBox(Canvas, ControlFace, Item.Caption, NameBox, AlignTextLeft, TextColorFor(State, Item.Dimmed));
  for Index := 0 to High(TileColumns) do
  begin
    Line := MakeRectangle(NameBox.Left, NameBox.Bottom + Index * LineHeight, RectangleWidth(NameBox), LineHeight);
    DrawTextInBox(Canvas, ControlFace, Item.Cells[TileColumns[Index]], Line, AlignTextLeft, QuieterColorFor(State));
  end;
  if State.Focused then
    DrawFocusFrame(Canvas, InflateRectangle(Cell, -Scaled(1)), TextColorFor(State, False));
end;

procedure PaintContentItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState; const Columns: TItemPaintColumns; const TileColumns: array of LongInt);
var
  NameBox: TRectangle;
  LineHeight: LongInt;
  Index: LongInt;
  Line: TRectangle;
  RightLeft: LongInt;
  Caption: string;
  Column: LongInt;
  Position: LongInt;
begin
  PaintBackground(Canvas, MakeRectangle(Cell.Left, Cell.Top, RectangleWidth(Cell), RectangleHeight(Cell) - 1), State);
  PaintCheck(Canvas, Mode, Cell, State);
  PaintItemPicture(Canvas, Item, Mode, ItemIconBox(Mode, Cell, 0, State.CheckBox));
  NameBox := ItemNameBox(Mode, Cell, 0, State.CheckBox);
  LineHeight := TextHeight(ControlFace);
  if not State.NameHidden then
    DrawTextInBox(Canvas, ControlFace, Item.Caption, NameBox, AlignTextLeft, TextColorFor(State, Item.Dimmed));
  if Length(TileColumns) > 0 then
    DrawTextInBox(Canvas, ControlFace, Item.Cells[TileColumns[0]], MakeRectangle(NameBox.Left, NameBox.Bottom,
      RectangleWidth(NameBox), LineHeight), AlignTextLeft, QuieterColorFor(State));
  { The other tile columns at the right, with their captions. }
  RightLeft := Cell.Left + RectangleWidth(Cell) div 2 + Scaled(8);
  for Index := 1 to High(TileColumns) do
  begin
    Column := TileColumns[Index];
    Caption := '';
    for Position := 0 to High(Columns.Indexes) do
      if Columns.Indexes[Position] = Column then
        Caption := Columns.Captions[Position];
    if Item.Cells[Column] = '' then
      Continue;
    if Caption <> '' then
      Caption := Caption + ': ';
    Line := MakeRectangle(RightLeft, NameBox.Top + (Index - 1) * LineHeight, Cell.Right - Scaled(CellPadding) - RightLeft,
      LineHeight);
    DrawTextInBox(Canvas, ControlFace, Caption + Item.Cells[Column], Line, AlignTextLeft, QuieterColorFor(State));
  end;
  DrawHorizontalLine(Canvas, Cell.Left, Cell.Right, Cell.Bottom - 1, MixColors(Theme.Field, Theme.Shadow, 110));
  if State.Focused then
    DrawFocusFrame(Canvas, MakeRectangle(Cell.Left, Cell.Top, RectangleWidth(Cell), RectangleHeight(Cell) - 1),
      TextColorFor(State, False));
end;

procedure PaintItem(const Canvas: TCanvas; Item: TItemViewItem; Mode: TItemViewMode; const Cell: TRectangle;
  const State: TItemPaintState; const Columns: TItemPaintColumns; const TileColumns: array of LongInt);
begin
  case Mode of
    ItemViewExtraLargeIcons, ItemViewLargeIcons, ItemViewMediumIcons:
      PaintIconViewItem(Canvas, Item, Mode, Cell, State);
    ItemViewDetails: PaintDetailsItem(Canvas, Item, Mode, Cell, State, Columns);
    ItemViewTiles: PaintTileItem(Canvas, Item, Mode, Cell, State, TileColumns);
    ItemViewContent: PaintContentItem(Canvas, Item, Mode, Cell, State, Columns, TileColumns);
  else
    PaintSmallItem(Canvas, Item, Mode, Cell, State);
  end;
end;

procedure PaintGroupHeader(const Canvas: TCanvas; const Box: TRectangle; const Caption: string; Count: LongInt;
  Collapsed, Hot: Boolean);
var
  Text: string;
  TextLeft: LongInt;
  Width: LongInt;
  Middle: LongInt;
  Chevron: TRectangle;
  Accent: TColor;
begin
  if Hot then
    FillRectangle(Canvas, Box, MixColors(Theme.Field, Theme.Selection, HotTint div 2));
  if Theme.HeaderBandsShown then
    Accent := Theme.HeaderBandEdge
  else
    Accent := Theme.Selection;
  Chevron := MakeRectangle(Box.Left + Scaled(2), Box.Top, Scaled(14), RectangleHeight(Box));
  if Collapsed then
    DrawArrowGlyph(Canvas, Chevron, ArrowRight, Scaled(4), Accent)
  else
    DrawArrowGlyph(Canvas, Chevron, ArrowDown, Scaled(4), Accent);
  Text := Caption + ' (' + IntToStr(Count) + ')';
  TextLeft := Chevron.Right + Scaled(4);
  Width := TextWidth(ControlBoldFace, Text);
  DrawTextInBox(Canvas, ControlBoldFace, Text, MakeRectangle(TextLeft, Box.Top, Width + Scaled(2),
    RectangleHeight(Box)), AlignTextLeft, Theme.FieldText);
  Middle := Box.Top + RectangleHeight(Box) div 2;
  if TextLeft + Width + Scaled(8) < Box.Right - Scaled(4) then
    DrawHorizontalLine(Canvas, TextLeft + Width + Scaled(8), Box.Right - Scaled(4), Middle,
      MixColors(Theme.Field, Accent, 120));
end;

end.
