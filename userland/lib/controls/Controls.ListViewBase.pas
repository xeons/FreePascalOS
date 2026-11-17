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
  The parts of a list view that hold and show its items: the columns,
  the items (Controls.ListItems), the view they are shown in, scrolling,
  and painting. Choosing items (selection, sorting, the pointer and the
  keys) is TListView's (Controls.ListView), built on this.

  Every view is a grid of cells (Controls.ListViewLayout); this works
  out the grid for the view and the control's size: one row per line in
  details, cells as wide as the widest name in the list and small icon
  views, cells of a fixed size for large icons. A scroll bar shows when
  the lines do not fit: down the side, or along the bottom in the list
  view, which grows across.

  The item under a drag that a drop would go to (DropTarget) is shown
  highlighted like a selected one; details rows show the items' small
  icons too if IconsInDetails.
}
unit Controls.ListViewBase;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Messages,
  Controls.Base,
  Controls.ScrollBar,
  Controls.ListItems,
  Controls.ListViewLayout;

type
  TListViewMode = (ViewDetails, ViewList, ViewSmallIcons, ViewLargeIcons);
  TPixelWidths = array of LongInt;

  TListViewBase = class(TListItemOwner)
  protected
    FCaptions: TStringList;
    FWidths: array of LongInt;
    FNumericColumns: array of Boolean;
    FItems: TList;
    FViewMode: TListViewMode;
    { The item with the focus, and where a Shift range starts. }
    FItemIndex: LongInt;
    FAnchor: LongInt;
    FFirstLine: LongInt;
    FScrollBar: TScrollBar;
    FSortColumn: LongInt;
    FSortAscending: Boolean;
    FDropTarget: LongInt;
    FIconsInDetails: Boolean;
    { The item being renamed in place (-1: none): its name is left to
      the edit box over it. }
    FEditIndex: LongInt;
    procedure SetDropTarget(Value: LongInt);
    procedure SetIconsInDetails(Value: Boolean);
    function HeaderHeight: LongInt;
    function RowHeight: LongInt;
    function ShowsHeader: Boolean;
    function ColumnLeft(Column: LongInt): LongInt;
    { The column whose right edge is at X (within a grip), or -1. }
    function ColumnEdgeAt(X: LongInt): LongInt;
    function ColumnAt(X: LongInt): LongInt;
    function PixelWidths: TPixelWidths;
    function ItemArea(WithScrollBar: Boolean): TRectangle;
    function MakeGrid(WithScrollBar: Boolean): TListViewGrid;
    { The grid as shown now. }
    function Grid: TListViewGrid;
    function NeedsScrollBar: Boolean;
    function GetItem(Row: LongInt): TListItem;
    function GetCell(Row, Column: LongInt): string;
    procedure SetCell(Row, Column: LongInt; const Value: string);
    function GetRowCount: LongInt;
    function GetSelected(Row: LongInt): Boolean;
    function GetColumnNumeric(Column: LongInt): Boolean;
    procedure SetColumnNumeric(Column: LongInt; Value: Boolean);
    procedure SetViewMode(Value: TListViewMode);
    procedure SetFirstLine(Value: LongInt);
    procedure UpdateScrollBar;
    procedure EnsureVisible(Index: LongInt);
    procedure ItemChanged(Item: TListItem; SelectionChanged: Boolean); override;
    procedure Paint(var Canvas: TCanvas); override;
    procedure Wheel(Steps: LongInt); override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Width in logical units. }
    procedure AddColumn(const Caption: string; Width: LongInt);
    { A row with these texts (the first column's first); its index. }
    function AddRow(const Texts: array of string): LongInt;
    procedure DeleteRow(Index: LongInt);
    procedure Clear;
    function ColumnCount: LongInt;
    { Logical units. }
    function ColumnWidth(Column: LongInt): LongInt;
    function SelectedCount: LongInt;
    { The middle of row Index (as shown now) and of the header, in this
      control's pixels (details). }
    function RowMiddle(Index: LongInt): LongInt;
    function HeaderMiddle: LongInt;
    { Item Index's cell as shown now, and its icon (icon views). }
    function ItemBounds(Index: LongInt): TRectangle;
    function IconBounds(Index: LongInt): TRectangle;
    { Where item Index's name is as shown now (what an edit box renaming
      it covers). }
    function CaptionBounds(Index: LongInt): TRectangle;
    { The item at (X, Y) of this control's pixels, or -1. }
    function ItemAt(X, Y: LongInt): LongInt;
    property Items[Row: LongInt]: TListItem read GetItem;
    property Cells[Row, Column: LongInt]: string read GetCell write SetCell;
    property RowCount: LongInt read GetRowCount;
    property ViewMode: TListViewMode read FViewMode write SetViewMode;
    { -1 if the items are not sorted by a column. }
    property SortColumn: LongInt read FSortColumn;
    property SortAscending: Boolean read FSortAscending;
    { Whether sorting by the column (a header click) compares numbers. }
    property ColumnNumeric[Column: LongInt]: Boolean read GetColumnNumeric write SetColumnNumeric;
    { The item shown as where a drop would go (-1: none). }
    property DropTarget: LongInt read FDropTarget write SetDropTarget;
    property IconsInDetails: Boolean read FIconsInDetails write SetIconsInDetails;
  end;

implementation

uses
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Icons,
  Controls.ListViewPainting,
  Controls.Painting;

const
  EdgeGrip = 3;

constructor TListViewBase.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FCaptions := TStringList.Create;
  FItems := TList.Create;
  FItemIndex := -1;
  FAnchor := -1;
  FSortColumn := -1;
  FSortAscending := True;
  FDropTarget := -1;
  FEditIndex := -1;
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Visible := False;
end;

destructor TListViewBase.Destroy;
begin
  Clear;
  FItems.Free;
  FCaptions.Free;
  inherited Destroy;
end;

procedure TListViewBase.ItemChanged(Item: TListItem; SelectionChanged: Boolean);
begin
  Invalidate;
end;

{ --- Columns and rows -------------------------------------------------------- }

procedure TListViewBase.AddColumn(const Caption: string; Width: LongInt);
begin
  FCaptions.Add(Caption);
  SetLength(FWidths, FCaptions.Count);
  SetLength(FNumericColumns, FCaptions.Count);
  FWidths[FCaptions.Count - 1] := Width;
  FNumericColumns[FCaptions.Count - 1] := False;
  Invalidate;
end;

function TListViewBase.ColumnCount: LongInt;
begin
  Result := FCaptions.Count;
end;

function TListViewBase.ColumnWidth(Column: LongInt): LongInt;
begin
  Result := FWidths[Column];
end;

function TListViewBase.GetColumnNumeric(Column: LongInt): Boolean;
begin
  Result := (Column >= 0) and (Column < ColumnCount) and FNumericColumns[Column];
end;

procedure TListViewBase.SetColumnNumeric(Column: LongInt; Value: Boolean);
begin
  if (Column >= 0) and (Column < ColumnCount) then
    FNumericColumns[Column] := Value;
end;

function TListViewBase.AddRow(const Texts: array of string): LongInt;
var
  Item: TListItem;
  Index: LongInt;
begin
  Item := TListItem.Create(Self);
  for Index := 0 to High(Texts) do
    Item.Cells[Index] := Texts[Index];
  Result := FItems.Add(Item);
  UpdateScrollBar;
  Invalidate;
end;

procedure TListViewBase.DeleteRow(Index: LongInt);
var
  WasSelected: Boolean;
begin
  if (Index < 0) or (Index >= FItems.Count) then
    Exit;
  WasSelected := TListItem(FItems[Index]).Selected;
  TListItem(FItems[Index]).Free;
  FItems.Delete(Index);
  if FDropTarget = Index then
    FDropTarget := -1
  else if FDropTarget > Index then
    Dec(FDropTarget);
  if FItemIndex > Index then
    Dec(FItemIndex)
  else if FItemIndex >= FItems.Count then
    FItemIndex := FItems.Count - 1;
  if FAnchor >= FItems.Count then
    FAnchor := FItems.Count - 1;
  SetFirstLine(FFirstLine);
  UpdateScrollBar;
  Invalidate;
  if WasSelected then
    Changed;
end;

procedure TListViewBase.Clear;
var
  Index: LongInt;
begin
  for Index := 0 to FItems.Count - 1 do
    TListItem(FItems[Index]).Free;
  FItems.Clear;
  FItemIndex := -1;
  FAnchor := -1;
  FDropTarget := -1;
  FFirstLine := 0;
  UpdateScrollBar;
  Invalidate;
end;

function TListViewBase.GetRowCount: LongInt;
begin
  Result := FItems.Count;
end;

function TListViewBase.GetItem(Row: LongInt): TListItem;
begin
  if (Row < 0) or (Row >= FItems.Count) then
    Exit(nil);
  Result := TListItem(FItems[Row]);
end;

function TListViewBase.GetCell(Row, Column: LongInt): string;
begin
  if (Row < 0) or (Row >= FItems.Count) then
    Exit('');
  Result := TListItem(FItems[Row]).Cells[Column];
end;

procedure TListViewBase.SetCell(Row, Column: LongInt; const Value: string);
begin
  if (Row >= 0) and (Row < FItems.Count) then
    TListItem(FItems[Row]).Cells[Column] := Value;
end;

function TListViewBase.GetSelected(Row: LongInt): Boolean;
begin
  Result := (Row >= 0) and (Row < FItems.Count) and TListItem(FItems[Row]).Selected;
end;

function TListViewBase.SelectedCount: LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to FItems.Count - 1 do
    if TListItem(FItems[Index]).Selected then
      Inc(Result);
end;

{ --- Geometry ---------------------------------------------------------------- }

function TListViewBase.HeaderHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(6);
end;

function TListViewBase.RowHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(2);
  if FViewMode in [ViewList, ViewSmallIcons] then
    if Result < Scaled(SmallIconSize + 2) then
      Result := Scaled(SmallIconSize + 2);
  if Result < 1 then
    Result := 1;
end;

function TListViewBase.ShowsHeader: Boolean;
begin
  Result := FViewMode = ViewDetails;
end;

function TListViewBase.ColumnLeft(Column: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := BevelWidth;
  for Index := 0 to Column - 1 do
    Result := Result + Scaled(FWidths[Index]);
end;

{ The column whose right edge is at X (within a grip), or -1. }
function TListViewBase.ColumnEdgeAt(X: LongInt): LongInt;
var
  Column: LongInt;
begin
  for Column := 0 to ColumnCount - 1 do
    if Abs(X - ColumnLeft(Column + 1)) <= Scaled(EdgeGrip) then
      Exit(Column);
  Result := -1;
end;

function TListViewBase.ColumnAt(X: LongInt): LongInt;
var
  Column: LongInt;
begin
  for Column := 0 to ColumnCount - 1 do
    if (X >= ColumnLeft(Column)) and (X < ColumnLeft(Column + 1)) then
      Exit(Column);
  Result := -1;
end;

function TListViewBase.PixelWidths: TPixelWidths;
var
  Column: LongInt;
begin
  Result := nil;
  SetLength(Result, ColumnCount);
  for Column := 0 to ColumnCount - 1 do
    Result[Column] := Scaled(FWidths[Column]);
end;

{ Inside the bevel, below the header, beside (or above) the scroll bar. }
function TListViewBase.ItemArea(WithScrollBar: Boolean): TRectangle;
begin
  Result := MakeRectangle(BevelWidth, BevelWidth, RectangleWidth(PixelBounds) - 2 * BevelWidth,
    RectangleHeight(PixelBounds) - 2 * BevelWidth);
  if ShowsHeader then
    Result.Top := Result.Top + HeaderHeight;
  if WithScrollBar and (FViewMode = ViewList) then
    Result.Bottom := Result.Bottom - Scaled(Theme.ScrollBarWidth)
  else if WithScrollBar then
    Result.Right := Result.Right - Scaled(Theme.ScrollBarWidth);
end;

function TListViewBase.MakeGrid(WithScrollBar: Boolean): TListViewGrid;
var
  Index: LongInt;
  Width: LongInt;
begin
  Result.Area := ItemArea(WithScrollBar);
  Result.ItemCount := FItems.Count;
  Result.FirstLine := FFirstLine;
  Result.ColumnMajor := FViewMode = ViewList;
  case FViewMode of
    ViewDetails:
      begin
        { One row per line: a cell as wide as the area. }
        Result.CellWidth := RectangleWidth(Result.Area);
        Result.CellHeight := RowHeight;
      end;
    ViewList, ViewSmallIcons:
      begin
        { Every cell as wide as the widest name needs. }
        Result.CellWidth := Scaled(SmallIconSize * 4);
        for Index := 0 to FItems.Count - 1 do
        begin
          Width := SmallIconCellWidthFor(TListItem(FItems[Index]).Caption);
          if Width > Result.CellWidth then
            Result.CellWidth := Width;
        end;
        Result.CellHeight := RowHeight;
      end;
    ViewLargeIcons:
      begin
        Result.CellWidth := LargeIconCellWidth;
        Result.CellHeight := LargeIconCellHeight;
      end;
  end;
  if Result.CellWidth < 1 then
    Result.CellWidth := 1;
  if Result.CellHeight < 1 then
    Result.CellHeight := 1;
end;

function TListViewBase.Grid: TListViewGrid;
begin
  Result := MakeGrid(FScrollBar.Visible);
end;

function TListViewBase.NeedsScrollBar: Boolean;
var
  Whole: TListViewGrid;
begin
  Whole := MakeGrid(False);
  Result := LineCount(Whole) > VisibleLineCount(Whole);
end;

function TListViewBase.RowMiddle(Index: LongInt): LongInt;
var
  Cell: TRectangle;
begin
  Cell := ItemCell(Grid, Index);
  Result := Cell.Top + RectangleHeight(Cell) div 2;
end;

function TListViewBase.HeaderMiddle: LongInt;
begin
  Result := BevelWidth + HeaderHeight div 2;
end;

function TListViewBase.ItemBounds(Index: LongInt): TRectangle;
begin
  Result := ItemCell(Grid, Index);
end;

function TListViewBase.IconBounds(Index: LongInt): TRectangle;
begin
  case FViewMode of
    ViewList, ViewSmallIcons: Result := SmallIconBox(ItemBounds(Index));
    ViewLargeIcons: Result := LargeIconBox(ItemBounds(Index));
  else
    Result := MakeRectangle(0, 0, 0, 0);
  end;
end;

function TListViewBase.CaptionBounds(Index: LongInt): TRectangle;
var
  Widths: TPixelWidths;
  FirstWidth: LongInt;
begin
  case FViewMode of
    ViewList, ViewSmallIcons: Result := SmallIconCaptionBox(ItemBounds(Index));
    ViewLargeIcons: Result := LargeIconCaptionBox(ItemBounds(Index));
  else
    begin
      Widths := PixelWidths;
      FirstWidth := RectangleWidth(ItemBounds(Index));
      if Length(Widths) > 0 then
        FirstWidth := Widths[0];
      Result := DetailsCaptionBox(ItemBounds(Index), FirstWidth, FIconsInDetails);
    end;
  end;
end;

function TListViewBase.ItemAt(X, Y: LongInt): LongInt;
begin
  Result := ItemAtPoint(Grid, X, Y);
end;

procedure TListViewBase.SetDropTarget(Value: LongInt);
begin
  if (Value < -1) or (Value >= FItems.Count) then
    Value := -1;
  if Value = FDropTarget then
    Exit;
  FDropTarget := Value;
  Invalidate;
end;

procedure TListViewBase.SetIconsInDetails(Value: Boolean);
begin
  if Value = FIconsInDetails then
    Exit;
  FIconsInDetails := Value;
  Invalidate;
end;

{ --- Scrolling --------------------------------------------------------------- }

procedure TListViewBase.Layout;
var
  Thickness: LongInt;
  Area: TRectangle;
begin
  Thickness := Scaled(Theme.ScrollBarWidth);
  Area := ItemArea(False);
  if FViewMode = ViewList then
  begin
    FScrollBar.Kind := ScrollHorizontal;
    FScrollBar.AssignBounds(Unscaled(Area.Left), Unscaled(Area.Bottom - Thickness), Unscaled(RectangleWidth(Area)),
      Unscaled(Thickness));
  end
  else
  begin
    FScrollBar.Kind := ScrollVertical;
    FScrollBar.AssignBounds(Unscaled(Area.Right - Thickness), Unscaled(Area.Top), Unscaled(Thickness),
      Unscaled(RectangleHeight(Area)));
  end;
  UpdateScrollBar;
  inherited Layout;
end;

procedure TListViewBase.UpdateScrollBar;
var
  Needed: Boolean;
  Shown: TListViewGrid;
begin
  Needed := NeedsScrollBar;
  if FScrollBar.Visible <> Needed then
    FScrollBar.Visible := Needed;
  Shown := Grid;
  FScrollBar.SetRange(0, LineCount(Shown), VisibleLineCount(Shown));
  FScrollBar.Position := FFirstLine;
end;

procedure TListViewBase.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and (TControl(Message.Parameter1) = FScrollBar) then
  begin
    if (Message.Parameter2 = NotifyChanged) and (FScrollBar.Position <> FFirstLine) then
    begin
      FFirstLine := FScrollBar.Position;
      Invalidate;
    end;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TListViewBase.SetFirstLine(Value: LongInt);
var
  Shown: TListViewGrid;
begin
  Shown := Grid;
  if Value > LineCount(Shown) - VisibleLineCount(Shown) then
    Value := LineCount(Shown) - VisibleLineCount(Shown);
  if Value < 0 then
    Value := 0;
  if Value = FFirstLine then
    Exit;
  FFirstLine := Value;
  FScrollBar.Position := Value;
  Invalidate;
end;

procedure TListViewBase.EnsureVisible(Index: LongInt);
var
  Shown: TListViewGrid;
  Line: LongInt;
begin
  Shown := Grid;
  Line := LineOfItem(Shown, Index);
  if Line < FFirstLine then
    SetFirstLine(Line)
  else if Line >= FFirstLine + VisibleLineCount(Shown) then
    SetFirstLine(Line - VisibleLineCount(Shown) + 1);
end;

procedure TListViewBase.SetViewMode(Value: TListViewMode);
begin
  if Value = FViewMode then
    Exit;
  FViewMode := Value;
  FFirstLine := 0;
  { The scroll bar changes side and the cells their size. }
  Layout;
  if FItemIndex >= 0 then
    EnsureVisible(FItemIndex);
  Invalidate;
end;

procedure TListViewBase.Wheel(Steps: LongInt);
begin
  SetFirstLine(FFirstLine - Steps * 3);
end;

{ --- Painting ---------------------------------------------------------------- }

procedure TListViewBase.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Shown: TListViewGrid;
  Widths: TPixelWidths;
  Index: LongInt;
  Cell: TRectangle;
  Item: TListItem;
  Highlighted: Boolean;
  FocusFrame: Boolean;
  VisiblePart: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
  Inner := Canvas;
  NarrowCanvasClip(Inner, InflateRectangle(Box, -BevelWidth));
  Widths := PixelWidths;
  if ShowsHeader then
    PaintListHeader(Inner, MakeRectangle(BevelWidth, BevelWidth, RectangleWidth(Box) - 2 * BevelWidth, HeaderHeight), FCaptions, Widths,
      FSortColumn, FSortAscending);
  Shown := Grid;
  NarrowCanvasClip(Inner, Shown.Area);
  for Index := 0 to FItems.Count - 1 do
  begin
    Cell := ItemCell(Shown, Index);
    if not IntersectRectangles(Cell, Shown.Area, VisiblePart) then
      Continue;
    Item := TListItem(FItems[Index]);
    Highlighted := Item.Selected or (Index = FDropTarget);
    FocusFrame := (Index = FItemIndex) and Focused;
    case FViewMode of
      ViewDetails: PaintDetailsRow(Inner, Item, Cell, Widths, Highlighted, FocusFrame, FIconsInDetails);
      ViewList, ViewSmallIcons: PaintSmallIconItem(Inner, Item, Cell, Highlighted, FocusFrame);
      ViewLargeIcons: PaintLargeIconItem(Inner, Item, Cell, Highlighted, FocusFrame, Index <> FEditIndex);
    end;
  end;
end;

end.
