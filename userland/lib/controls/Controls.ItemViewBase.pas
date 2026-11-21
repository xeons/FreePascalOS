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
  The parts of an item view (Controls.ItemView) that hold and show its
  items: the items (Controls.ItemViewItems), the columns and their
  header (details), the groups, the view they are shown in, their
  places (Controls.ItemViewLayout, worked out again only when something
  that moves them changes), scrolling (down, or across in the list and
  in details wider than the view), and painting (Controls.
  ItemViewPainting). Choosing items, the pointer and the keys are
  TItemView's.

  Items are added between BeginUpdate and EndUpdate to lay them out
  once. SortItems orders them by the program's comparison within their
  groups (groups in their own order), which is also how they are shown.
  With no items, EmptyText is shown in the middle.
}
unit Controls.ItemViewBase;

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
  Controls.ItemViewItems,
  Controls.ItemViewLayout,
  Controls.ItemViewPainting;

type
  { Negative if First goes before Second. }
  TItemCompare = function(First, Second: TItemViewItem): LongInt of object;

  TItemViewBase = class(TItemViewOwner)
  private
    FUpdating: LongInt;
    function GetItem(Index: LongInt): TItemViewItem;
    function GetCount: LongInt;
    function GetColumn(Index: LongInt): TItemColumn;
    function GetGroup(Index: LongInt): TItemGroup;
    procedure SetMode(Value: TItemViewMode);
    procedure SetCompact(Value: Boolean);
    procedure SetShowCheckBoxes(Value: Boolean);
    procedure SetDropTarget(Value: LongInt);
    procedure SetEmptyText(const Value: string);
    procedure ScrollBarChanged;
  protected
    FItems: TList;
    FColumns: TItemColumns;
    FGroups: TItemGroups;
    FTileColumns: array of LongInt;
    FMode: TItemViewMode;
    FCompact: Boolean;
    FShowCheckBoxes: Boolean;
    FLayout: TItemLayout;
    FLayoutDirty: Boolean;
    FScrollX: LongInt;
    FScrollY: LongInt;
    FVerticalBar: TScrollBar;
    FHorizontalBar: TScrollBar;
    FItemIndex: LongInt;
    FAnchor: LongInt;
    FHotIndex: LongInt;
    FHotGroup: LongInt;
    FDropTarget: LongInt;
    FEditIndex: LongInt;
    FSortColumn: LongInt;
    FSortAscending: Boolean;
    FEmptyText: string;
    { The rubber band being dragged (content pixels), if any. }
    FBanding: Boolean;
    FBandRectangle: TRectangle;
    procedure ItemChanged(Item: TItemViewItem; SelectionChanged: Boolean); override;
    procedure Paint(var Canvas: TCanvas); override;
    procedure Layout; override;
    procedure Wheel(Steps: LongInt); override;
    { The area items are shown in (control pixels): inside the bevel,
      below the header, beside the scroll bars. }
    function ItemArea: TRectangle;
    function HeaderBox: TRectangle;
    function ShowsHeader: Boolean;
    function HeaderHeight: LongInt;
    function CellWidth: LongInt;
    function CellHeight: LongInt;
    function DetailsWidth: LongInt;
    function PaintColumns: TItemPaintColumns;
    procedure EnsureLayout;
    procedure InvalidateLayout;
    procedure UpdateScrollBars;
    procedure SetScroll(X, Y: LongInt);
    { Content pixels to control pixels and back. }
    function ToControl(const Box: TRectangle): TRectangle;
    function ContentX(X: LongInt): LongInt;
    function ContentY(Y: LongInt): LongInt;
    function GroupItemCount(Group: LongInt): LongInt;
    { The visible column whose header holds X (an index into Columns),
      and the one whose right edge is within a grip of X; -1 if none. }
    function HeaderColumnAt(X: LongInt): LongInt;
    function HeaderEdgeAt(X: LongInt): LongInt;
    function FirstColumnPixelWidth: LongInt;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    procedure BeginUpdate;
    procedure EndUpdate;
    function AddItem(const Caption: string): TItemViewItem;
    procedure DeleteItem(Index: LongInt);
    procedure Clear;
    function IndexOfItem(Item: TItemViewItem): LongInt;
    { Columns: Width in logical units; the first is the name. }
    function AddColumn(const Caption: string; Width: LongInt; Alignment: LongInt = 0; Shown: Boolean = True;
      ColumnTag: PtrInt = 0): LongInt;
    procedure ClearColumns;
    function ColumnCount: LongInt;
    procedure SetColumnVisible(Index: LongInt; Value: Boolean);
    procedure SetColumnWidth(Index: LongInt; Width: LongInt);
    { The columns tiles and content show under (beside) the name. }
    procedure SetTileColumns(const Columns: array of LongInt);
    { Groups: items name them by index (Item.Group); none: no grouping. }
    procedure SetGroups(const Captions: array of string);
    procedure ClearGroups;
    function GroupCount: LongInt;
    procedure SetGroupCollapsed(Index: LongInt; Value: Boolean);
    { Orders the items: by group, then by Compare (stable). }
    procedure SortItems(Compare: TItemCompare);
    { Shows the arrow on a column's header (-1: none). }
    procedure ShowSortArrow(Column: LongInt; Ascending: Boolean);
    procedure EnsureVisible(Index: LongInt);
    { Geometry as shown now, in this control's pixels (for tests and
      for the editor and menus). }
    function ItemBounds(Index: LongInt): TRectangle;
    function NameBounds(Index: LongInt): TRectangle;
    function IconBounds(Index: LongInt): TRectangle;
    function CheckBoxBounds(Index: LongInt): TRectangle;
    function GroupBounds(Index: LongInt): TRectangle;
    function ColumnHeaderBounds(Index: LongInt): TRectangle;
    { The item at (X, Y) of this control's pixels, or -1; the same for a
      group's header. }
    function ItemAt(X, Y: LongInt): LongInt;
    function GroupAt(X, Y: LongInt): LongInt;
    function SelectedCount: LongInt;
    function IsItemShown(Index: LongInt): Boolean;
    property Items[Index: LongInt]: TItemViewItem read GetItem; default;
    property Count: LongInt read GetCount;
    property Columns[Index: LongInt]: TItemColumn read GetColumn;
    property Groups[Index: LongInt]: TItemGroup read GetGroup;
    property Mode: TItemViewMode read FMode write SetMode;
    { Less space between the rows of details and the list. }
    property Compact: Boolean read FCompact write SetCompact;
    property ShowCheckBoxes: Boolean read FShowCheckBoxes write SetShowCheckBoxes;
    property DropTarget: LongInt read FDropTarget write SetDropTarget;
    property SortColumn: LongInt read FSortColumn;
    property SortAscending: Boolean read FSortAscending;
    property EmptyText: string read FEmptyText write SetEmptyText;
  end;

const
  { How a column's text is aligned (TItemColumn.Alignment). }
  ColumnAlignLeft = 0;
  ColumnAlignCenter = 1;
  ColumnAlignRight = 2;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.Icons,
  Controls.ListViewPainting,
  Controls.Painting;

const
  EdgeGrip = 3;
  ContentMargin = 6;
  MinimumColumnWidth = 24;
  MostSmallCellWidth = 360;
  LeastSmallCellWidth = 120;

constructor TItemViewBase.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FItems := TList.Create;
  FItemIndex := -1;
  FAnchor := -1;
  FHotIndex := -1;
  FHotGroup := -1;
  FDropTarget := -1;
  FEditIndex := -1;
  FSortColumn := -1;
  FSortAscending := True;
  FMode := ItemViewDetails;
  FLayoutDirty := True;
  FVerticalBar := TScrollBar.Create(Self);
  FVerticalBar.Kind := ScrollVertical;
  FVerticalBar.Visible := False;
  FHorizontalBar := TScrollBar.Create(Self);
  FHorizontalBar.Kind := ScrollHorizontal;
  FHorizontalBar.Visible := False;
end;

destructor TItemViewBase.Destroy;
begin
  Clear;
  FItems.Free;
  inherited Destroy;
end;

procedure TItemViewBase.ItemChanged(Item: TItemViewItem; SelectionChanged: Boolean);
begin
  Invalidate;
end;

{ --- Items, columns, groups ------------------------------------------------------------- }

procedure TItemViewBase.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure TItemViewBase.EndUpdate;
begin
  Dec(FUpdating);
  if FUpdating = 0 then
    InvalidateLayout;
end;

procedure TItemViewBase.InvalidateLayout;
begin
  FLayoutDirty := True;
  if FUpdating = 0 then
  begin
    EnsureLayout;
    Invalidate;
  end;
end;

function TItemViewBase.AddItem(const Caption: string): TItemViewItem;
begin
  Result := TItemViewItem.Create(Self);
  Result.Cells[0] := Caption;
  FItems.Add(Result);
  InvalidateLayout;
end;

procedure TItemViewBase.DeleteItem(Index: LongInt);
begin
  if (Index < 0) or (Index >= FItems.Count) then
    Exit;
  TItemViewItem(FItems[Index]).Free;
  FItems.Delete(Index);
  if FItemIndex >= FItems.Count then
    FItemIndex := FItems.Count - 1;
  if FAnchor >= FItems.Count then
    FAnchor := FItems.Count - 1;
  FHotIndex := -1;
  FDropTarget := -1;
  InvalidateLayout;
  Changed;
end;

procedure TItemViewBase.Clear;
var
  Index: LongInt;
begin
  for Index := 0 to FItems.Count - 1 do
    TItemViewItem(FItems[Index]).Free;
  FItems.Clear;
  FItemIndex := -1;
  FAnchor := -1;
  FHotIndex := -1;
  FDropTarget := -1;
  FScrollX := 0;
  FScrollY := 0;
  InvalidateLayout;
end;

function TItemViewBase.IndexOfItem(Item: TItemViewItem): LongInt;
begin
  Result := FItems.IndexOf(Item);
end;

function TItemViewBase.GetItem(Index: LongInt): TItemViewItem;
begin
  if (Index < 0) or (Index >= FItems.Count) then
    Exit(nil);
  Result := TItemViewItem(FItems[Index]);
end;

function TItemViewBase.GetCount: LongInt;
begin
  Result := FItems.Count;
end;

function TItemViewBase.AddColumn(const Caption: string; Width: LongInt; Alignment: LongInt; Shown: Boolean;
  ColumnTag: PtrInt): LongInt;
begin
  SetLength(FColumns, Length(FColumns) + 1);
  Result := High(FColumns);
  FColumns[Result].Caption := Caption;
  FColumns[Result].Width := Width;
  FColumns[Result].Alignment := THorizontalAlignment(Alignment);
  FColumns[Result].Visible := Shown or (Result = 0);
  FColumns[Result].Tag := ColumnTag;
  InvalidateLayout;
end;

procedure TItemViewBase.ClearColumns;
begin
  FColumns := nil;
  InvalidateLayout;
end;

function TItemViewBase.ColumnCount: LongInt;
begin
  Result := Length(FColumns);
end;

function TItemViewBase.GetColumn(Index: LongInt): TItemColumn;
begin
  Result := FColumns[Index];
end;

procedure TItemViewBase.SetColumnVisible(Index: LongInt; Value: Boolean);
begin
  if (Index <= 0) or (Index > High(FColumns)) then
    Exit;
  FColumns[Index].Visible := Value;
  InvalidateLayout;
end;

procedure TItemViewBase.SetColumnWidth(Index: LongInt; Width: LongInt);
begin
  if (Index < 0) or (Index > High(FColumns)) then
    Exit;
  if Width < MinimumColumnWidth then
    Width := MinimumColumnWidth;
  FColumns[Index].Width := Width;
  InvalidateLayout;
end;

procedure TItemViewBase.SetTileColumns(const Columns: array of LongInt);
var
  Index: LongInt;
begin
  SetLength(FTileColumns, Length(Columns));
  for Index := 0 to High(Columns) do
    FTileColumns[Index] := Columns[Index];
  Invalidate;
end;

procedure TItemViewBase.SetGroups(const Captions: array of string);
var
  Index: LongInt;
begin
  SetLength(FGroups, Length(Captions));
  for Index := 0 to High(Captions) do
  begin
    FGroups[Index].Caption := Captions[Index];
    FGroups[Index].Collapsed := False;
  end;
  InvalidateLayout;
end;

procedure TItemViewBase.ClearGroups;
var
  Index: LongInt;
begin
  FGroups := nil;
  for Index := 0 to FItems.Count - 1 do
    TItemViewItem(FItems[Index]).Group := -1;
  InvalidateLayout;
end;

function TItemViewBase.GroupCount: LongInt;
begin
  Result := Length(FGroups);
end;

function TItemViewBase.GetGroup(Index: LongInt): TItemGroup;
begin
  Result := FGroups[Index];
end;

procedure TItemViewBase.SetGroupCollapsed(Index: LongInt; Value: Boolean);
begin
  if (Index < 0) or (Index > High(FGroups)) then
    Exit;
  FGroups[Index].Collapsed := Value;
  InvalidateLayout;
end;

function TItemViewBase.GroupItemCount(Group: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to FItems.Count - 1 do
    if TItemViewItem(FItems[Index]).Group = Group then
      Inc(Result);
end;

procedure TItemViewBase.SortItems(Compare: TItemCompare);
var
  Index: LongInt;
  Other: LongInt;
  Moving: TItemViewItem;
  FocusedItem: TItemViewItem;
  AnchorItem: TItemViewItem;
  function GoesBefore(First, Second: TItemViewItem): Boolean;
  var
    Order: LongInt;
  begin
    if First.Group <> Second.Group then
      Exit(First.Group < Second.Group);
    Order := 0;
    if Assigned(Compare) then
      Order := Compare(First, Second);
    Result := Order < 0;
  end;
begin
  FocusedItem := GetItem(FItemIndex);
  AnchorItem := GetItem(FAnchor);
  { Insertion sort: stable, and fast on lists nearly in order already. }
  for Index := 1 to FItems.Count - 1 do
  begin
    Moving := TItemViewItem(FItems[Index]);
    Other := Index - 1;
    while (Other >= 0) and GoesBefore(Moving, TItemViewItem(FItems[Other])) do
    begin
      FItems[Other + 1] := FItems[Other];
      Dec(Other);
    end;
    FItems[Other + 1] := Moving;
  end;
  FItemIndex := FItems.IndexOf(FocusedItem);
  FAnchor := FItems.IndexOf(AnchorItem);
  FHotIndex := -1;
  InvalidateLayout;
end;

procedure TItemViewBase.ShowSortArrow(Column: LongInt; Ascending: Boolean);
begin
  FSortColumn := Column;
  FSortAscending := Ascending;
  Invalidate;
end;

function TItemViewBase.SelectedCount: LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to FItems.Count - 1 do
    if TItemViewItem(FItems[Index]).Selected then
      Inc(Result);
end;

procedure TItemViewBase.SetMode(Value: TItemViewMode);
begin
  if Value = FMode then
    Exit;
  FMode := Value;
  FScrollX := 0;
  FScrollY := 0;
  InvalidateLayout;
  if FItemIndex >= 0 then
    EnsureVisible(FItemIndex);
end;

procedure TItemViewBase.SetCompact(Value: Boolean);
begin
  if Value = FCompact then
    Exit;
  FCompact := Value;
  InvalidateLayout;
end;

procedure TItemViewBase.SetShowCheckBoxes(Value: Boolean);
begin
  if Value = FShowCheckBoxes then
    Exit;
  FShowCheckBoxes := Value;
  InvalidateLayout;
end;

procedure TItemViewBase.SetDropTarget(Value: LongInt);
begin
  if (Value < -1) or (Value >= FItems.Count) then
    Value := -1;
  if Value = FDropTarget then
    Exit;
  FDropTarget := Value;
  Invalidate;
end;

procedure TItemViewBase.SetEmptyText(const Value: string);
begin
  FEmptyText := Value;
  Invalidate;
end;

{ --- Geometry ----------------------------------------------------------------------------- }

function TItemViewBase.ShowsHeader: Boolean;
begin
  Result := FMode = ItemViewDetails;
end;

function TItemViewBase.HeaderHeight: LongInt;
begin
  Result := TextHeight(ControlFace) + Scaled(8);
end;

function TItemViewBase.HeaderBox: TRectangle;
begin
  Result := MakeRectangle(BevelWidth, BevelWidth, RectangleWidth(PixelBounds) - 2 * BevelWidth, HeaderHeight);
end;

function TItemViewBase.ItemArea: TRectangle;
begin
  Result := MakeRectangle(BevelWidth, BevelWidth, RectangleWidth(PixelBounds) - 2 * BevelWidth,
    RectangleHeight(PixelBounds) - 2 * BevelWidth);
  if ShowsHeader then
    Result.Top := Result.Top + HeaderHeight;
  if FVerticalBar.Visible then
    Result.Right := Result.Right - Scaled(Theme.ScrollBarWidth);
  if FHorizontalBar.Visible then
    Result.Bottom := Result.Bottom - Scaled(Theme.ScrollBarWidth);
  if Result.Right < Result.Left then
    Result.Right := Result.Left;
  if Result.Bottom < Result.Top then
    Result.Bottom := Result.Top;
end;

function TItemViewBase.DetailsWidth: LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to High(FColumns) do
    if FColumns[Index].Visible then
      Result := Result + Scaled(FColumns[Index].Width);
end;

function TItemViewBase.FirstColumnPixelWidth: LongInt;
begin
  if Length(FColumns) = 0 then
    Result := Scaled(200)
  else
    Result := Scaled(FColumns[0].Width);
end;

function TItemViewBase.CellWidth: LongInt;
var
  Index: LongInt;
  Width: LongInt;
begin
  case FMode of
    ItemViewDetails: Result := DetailsWidth;
    ItemViewContent: Result := RectangleWidth(ItemArea);
    ItemViewSmallIcons, ItemViewList:
      begin
        Result := Scaled(LeastSmallCellWidth);
        for Index := 0 to FItems.Count - 1 do
        begin
          Width := SmallCellWidthFor(TItemViewItem(FItems[Index]).Caption);
          if Width > Result then
            Result := Width;
        end;
        if Result > Scaled(MostSmallCellWidth) then
          Result := Scaled(MostSmallCellWidth);
      end;
  else
    Result := IconCellWidth(FMode);
  end;
end;

function TItemViewBase.CellHeight: LongInt;
begin
  case FMode of
    ItemViewDetails, ItemViewList, ItemViewSmallIcons: Result := RowHeight(FMode, FCompact);
  else
    Result := IconCellHeight(FMode);
  end;
end;

function TItemViewBase.PaintColumns: TItemPaintColumns;
var
  Index: LongInt;
  Position: LongInt;
begin
  Result := Default(TItemPaintColumns);
  for Index := 0 to High(FColumns) do
    if FColumns[Index].Visible then
    begin
      Position := Length(Result.Indexes);
      SetLength(Result.Indexes, Position + 1);
      SetLength(Result.Widths, Position + 1);
      SetLength(Result.Captions, Position + 1);
      SetLength(Result.Alignments, Position + 1);
      Result.Indexes[Position] := Index;
      Result.Widths[Position] := Scaled(FColumns[Index].Width);
      Result.Captions[Position] := FColumns[Index].Caption;
      Result.Alignments[Position] := Ord(FColumns[Index].Alignment);
    end;
end;

procedure TItemViewBase.EnsureLayout;
var
  Input: TItemLayoutInput;
  Index: LongInt;
  Area: TRectangle;
  Pass: LongInt;
  NeedVertical: Boolean;
  NeedHorizontal: Boolean;
begin
  if not FLayoutDirty or (FUpdating > 0) then
    Exit;
  FLayoutDirty := False;
  { Twice: a scroll bar appearing narrows the area. }
  for Pass := 1 to 2 do
  begin
    Area := ItemArea;
    Input := Default(TItemLayoutInput);
    Input.Mode := FMode;
    Input.AreaWidth := RectangleWidth(Area);
    Input.AreaHeight := RectangleHeight(Area);
    SetLength(Input.ItemGroups, FItems.Count);
    for Index := 0 to FItems.Count - 1 do
      Input.ItemGroups[Index] := TItemViewItem(FItems[Index]).Group;
    SetLength(Input.GroupCollapsed, Length(FGroups));
    for Index := 0 to High(FGroups) do
      Input.GroupCollapsed[Index] := FGroups[Index].Collapsed;
    Input.CellWidth := CellWidth;
    Input.CellHeight := CellHeight;
    Input.GroupHeaderHeight := GroupHeaderHeight;
    if FMode = ItemViewDetails then
      Input.Margin := 0
    else
      Input.Margin := Scaled(ContentMargin);
    FLayout := LayOutItems(Input);
    NeedVertical := not FLayout.Across and (FLayout.ContentHeight > RectangleHeight(Area));
    NeedHorizontal := FLayout.ContentWidth > RectangleWidth(Area);
    if (NeedVertical = FVerticalBar.Visible) and (NeedHorizontal = FHorizontalBar.Visible) then
      Break;
    FVerticalBar.Visible := NeedVertical;
    FHorizontalBar.Visible := NeedHorizontal;
  end;
  UpdateScrollBars;
end;

procedure TItemViewBase.UpdateScrollBars;
var
  Area: TRectangle;
  Thickness: LongInt;
  Outer: TRectangle;
begin
  Area := ItemArea;
  Thickness := Scaled(Theme.ScrollBarWidth);
  Outer := MakeRectangle(BevelWidth, BevelWidth, RectangleWidth(PixelBounds) - 2 * BevelWidth,
    RectangleHeight(PixelBounds) - 2 * BevelWidth);
  if FVerticalBar.Visible then
  begin
    FVerticalBar.AssignBounds(Unscaled(Area.Right), Unscaled(Area.Top), Unscaled(Thickness),
      Unscaled(RectangleHeight(Area)));
    FVerticalBar.SetRange(0, FLayout.ContentHeight, RectangleHeight(Area));
    FVerticalBar.Step := CellHeight;
  end;
  if FHorizontalBar.Visible then
  begin
    FHorizontalBar.AssignBounds(Unscaled(Outer.Left), Unscaled(Area.Bottom), Unscaled(RectangleWidth(Area)),
      Unscaled(Thickness));
    FHorizontalBar.SetRange(0, FLayout.ContentWidth, RectangleWidth(Area));
    FHorizontalBar.Step := CellWidth div 2;
  end;
  SetScroll(FScrollX, FScrollY);
end;

procedure TItemViewBase.SetScroll(X, Y: LongInt);
var
  Area: TRectangle;
begin
  Area := ItemArea;
  if X > FLayout.ContentWidth - RectangleWidth(Area) then
    X := FLayout.ContentWidth - RectangleWidth(Area);
  if X < 0 then
    X := 0;
  if FLayout.Across or (Y > FLayout.ContentHeight - RectangleHeight(Area)) then
    Y := FLayout.ContentHeight - RectangleHeight(Area);
  if Y < 0 then
    Y := 0;
  if (X = FScrollX) and (Y = FScrollY) then
  begin
    FHorizontalBar.Position := X;
    FVerticalBar.Position := Y;
    Exit;
  end;
  FScrollX := X;
  FScrollY := Y;
  FHorizontalBar.Position := X;
  FVerticalBar.Position := Y;
  Invalidate;
end;

procedure TItemViewBase.ScrollBarChanged;
begin
  if (FVerticalBar.Position <> FScrollY) or (FHorizontalBar.Position <> FScrollX) then
  begin
    FScrollY := FVerticalBar.Position;
    FScrollX := FHorizontalBar.Position;
    Invalidate;
  end;
end;

procedure TItemViewBase.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and ((TControl(Message.Parameter1) = FVerticalBar) or
     (TControl(Message.Parameter1) = FHorizontalBar)) then
  begin
    if Message.Parameter2 = NotifyChanged then
      ScrollBarChanged;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

procedure TItemViewBase.Layout;
begin
  FLayoutDirty := True;
  EnsureLayout;
  inherited Layout;
end;

procedure TItemViewBase.Wheel(Steps: LongInt);
begin
  EnsureLayout;
  if FLayout.Across then
    SetScroll(FScrollX - Steps * CellWidth, FScrollY)
  else
    SetScroll(FScrollX, FScrollY - Steps * 3 * RowHeight(ItemViewDetails, False));
end;

function TItemViewBase.ToControl(const Box: TRectangle): TRectangle;
var
  Area: TRectangle;
begin
  Area := ItemArea;
  Result := OffsetRectangle(Box, Area.Left - FScrollX, Area.Top - FScrollY);
end;

function TItemViewBase.ContentX(X: LongInt): LongInt;
begin
  Result := X - ItemArea.Left + FScrollX;
end;

function TItemViewBase.ContentY(Y: LongInt): LongInt;
begin
  Result := Y - ItemArea.Top + FScrollY;
end;

function TItemViewBase.IsItemShown(Index: LongInt): Boolean;
begin
  EnsureLayout;
  Result := (Index >= 0) and (Index <= High(FLayout.ItemShown)) and FLayout.ItemShown[Index];
end;

function TItemViewBase.ItemBounds(Index: LongInt): TRectangle;
begin
  EnsureLayout;
  if not IsItemShown(Index) then
    Exit(MakeRectangle(0, 0, 0, 0));
  Result := ToControl(FLayout.ItemRects[Index]);
end;

function TItemViewBase.NameBounds(Index: LongInt): TRectangle;
begin
  Result := ItemNameBox(FMode, ItemBounds(Index), FirstColumnPixelWidth, FShowCheckBoxes);
end;

function TItemViewBase.IconBounds(Index: LongInt): TRectangle;
begin
  Result := ItemIconBox(FMode, ItemBounds(Index), FirstColumnPixelWidth, FShowCheckBoxes);
end;

function TItemViewBase.CheckBoxBounds(Index: LongInt): TRectangle;
begin
  Result := ItemCheckBox(FMode, ItemBounds(Index));
end;

function TItemViewBase.GroupBounds(Index: LongInt): TRectangle;
begin
  EnsureLayout;
  if (Index < 0) or (Index > High(FLayout.GroupShown)) or not FLayout.GroupShown[Index] then
    Exit(MakeRectangle(0, 0, 0, 0));
  Result := ToControl(FLayout.GroupRects[Index]);
end;

function TItemViewBase.ColumnHeaderBounds(Index: LongInt): TRectangle;
var
  Left: LongInt;
  Column: LongInt;
  Box: TRectangle;
begin
  Box := HeaderBox;
  Left := Box.Left - FScrollX;
  for Column := 0 to High(FColumns) do
  begin
    if not FColumns[Column].Visible then
      Continue;
    if Column = Index then
      Exit(MakeRectangle(Left, Box.Top, Scaled(FColumns[Column].Width), RectangleHeight(Box)));
    Left := Left + Scaled(FColumns[Column].Width);
  end;
  Result := MakeRectangle(0, 0, 0, 0);
end;

function TItemViewBase.HeaderColumnAt(X: LongInt): LongInt;
var
  Column: LongInt;
  Box: TRectangle;
begin
  for Column := 0 to High(FColumns) do
  begin
    if not FColumns[Column].Visible then
      Continue;
    Box := ColumnHeaderBounds(Column);
    if (X >= Box.Left) and (X < Box.Right) then
      Exit(Column);
  end;
  Result := -1;
end;

function TItemViewBase.HeaderEdgeAt(X: LongInt): LongInt;
var
  Column: LongInt;
begin
  for Column := 0 to High(FColumns) do
    if FColumns[Column].Visible and (Abs(X - ColumnHeaderBounds(Column).Right) <= Scaled(EdgeGrip)) then
      Exit(Column);
  Result := -1;
end;

function TItemViewBase.ItemAt(X, Y: LongInt): LongInt;
begin
  EnsureLayout;
  if not RectangleContainsPoint(ItemArea, X, Y) then
    Exit(-1);
  Result := ItemAtContentPoint(FLayout, ContentX(X), ContentY(Y));
end;

function TItemViewBase.GroupAt(X, Y: LongInt): LongInt;
begin
  EnsureLayout;
  if not RectangleContainsPoint(ItemArea, X, Y) or FLayout.Across then
    Exit(-1);
  Result := GroupAtContentPoint(FLayout, ContentX(X), ContentY(Y));
end;

procedure TItemViewBase.EnsureVisible(Index: LongInt);
var
  Box: TRectangle;
  Area: TRectangle;
  X: LongInt;
  Y: LongInt;
begin
  if not IsItemShown(Index) then
    Exit;
  Box := FLayout.ItemRects[Index];
  Area := ItemArea;
  X := FScrollX;
  Y := FScrollY;
  if FLayout.Across or (FMode <> ItemViewDetails) then
  begin
    if Box.Left < X then
      X := Box.Left
    else if Box.Right > X + RectangleWidth(Area) then
      X := Box.Right - RectangleWidth(Area);
  end;
  if Box.Top < Y then
    Y := Box.Top
  else if Box.Bottom > Y + RectangleHeight(Area) then
    Y := Box.Bottom - RectangleHeight(Area);
  SetScroll(X, Y);
end;

{ --- Painting ----------------------------------------------------------------------------- }

procedure TItemViewBase.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TCanvas;
  Area: TRectangle;
  Index: LongInt;
  Cell: TRectangle;
  VisiblePart: TRectangle;
  State: TItemPaintState;
  Item: TItemViewItem;
  PaintedColumns: TItemPaintColumns;
  Captions: TStringList;
  HeaderWidths: array of LongInt;
  SortPosition: LongInt;
  Position: LongInt;
  Band: TRectangle;
begin
  EnsureLayout;
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
  Inner := Canvas;
  NarrowCanvasClip(Inner, InflateRectangle(Box, -BevelWidth));
  PaintedColumns := PaintColumns;
  if ShowsHeader then
  begin
    Captions := TStringList.Create;
    try
      HeaderWidths := nil;
      SetLength(HeaderWidths, Length(PaintedColumns.Captions));
      SortPosition := -1;
      for Position := 0 to High(PaintedColumns.Captions) do
      begin
        Captions.Add(PaintedColumns.Captions[Position]);
        HeaderWidths[Position] := PaintedColumns.Widths[Position];
        if PaintedColumns.Indexes[Position] = FSortColumn then
          SortPosition := Position;
      end;
      Band := HeaderBox;
      Band.Left := Band.Left - FScrollX;
      PaintListHeader(Inner, Band, Captions, HeaderWidths, SortPosition, FSortAscending);
    finally
      Captions.Free;
    end;
  end;
  Area := ItemArea;
  NarrowCanvasClip(Inner, Area);
  if FItems.Count = 0 then
  begin
    DrawTextInBox(Inner, ControlFace, FEmptyText, MakeRectangle(Area.Left, Area.Top + Scaled(24),
      RectangleWidth(Area), TextHeight(ControlFace)), AlignTextCenter, MixColors(Theme.Field, Theme.FieldText, 150));
    Exit;
  end;
  if not FLayout.Across then
    for Index := 0 to High(FGroups) do
      if FLayout.GroupShown[Index] then
      begin
        Cell := ToControl(FLayout.GroupRects[Index]);
        if IntersectRectangles(Cell, Area, VisiblePart) then
          PaintGroupHeader(Inner, Cell, FGroups[Index].Caption, GroupItemCount(Index), FGroups[Index].Collapsed,
            Index = FHotGroup);
      end;
  for Index := 0 to FItems.Count - 1 do
  begin
    if not FLayout.ItemShown[Index] then
      Continue;
    Cell := ToControl(FLayout.ItemRects[Index]);
    if not IntersectRectangles(Cell, Area, VisiblePart) then
      Continue;
    Item := TItemViewItem(FItems[Index]);
    State := Default(TItemPaintState);
    State.Selected := Item.Selected;
    State.Hot := Index = FHotIndex;
    State.Focused := (Index = FItemIndex) and Focused;
    State.DropTarget := Index = FDropTarget;
    State.CheckBox := FShowCheckBoxes;
    State.NameHidden := Index = FEditIndex;
    PaintItem(Inner, Item, FMode, Cell, State, PaintedColumns, FTileColumns);
  end;
  if FBanding then
  begin
    Band := ToControl(FBandRectangle);
    FillRectangle(Inner, Band, WithAlpha(Theme.Selection, 60));
    DrawRectangleOutline(Inner, Band, Theme.Selection);
  end;
end;

end.
