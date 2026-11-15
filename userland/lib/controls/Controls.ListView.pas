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
  List views: items shown as rows of columns under a header (details),
  as names in columns (list), or as small or large icons.

  Each item (Controls.ListItems) is a row of texts, one per column, with
  an icon: the program's own picture or a stock one. In details the
  header shows the columns' captions; dragging the edge between two
  resizes the left one, and a click on one is announced (OnColumnClick)
  after sorting by it if SortOnHeaderClick (a second click on the same
  column turns the order round). The other views show the first column
  only. Holding the items and showing them is TListViewBase's
  (Controls.ListViewBase); this adds choosing them.

  ItemIndex is the item with the focus, the one the keys move from. With
  MultiSelect several items can be selected: Ctrl+click selects or
  deselects one more, Shift+click and Shift with the moving keys select
  the range from the anchor (the item last clicked without Shift), Ctrl
  with the moving keys moves the focus alone (Ctrl+Space then selects
  it), Ctrl+A selects all. Without it, the focused item is the one
  selected. A double click or Enter activates (OnActivate,
  NotifyActivated); every change of the selection or the focus is
  announced once (OnChange, NotifyChanged).
}
unit Controls.ListView;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.ListItems,
  Controls.ListSorting,
  Controls.ListViewBase;

type
  TListView = class;
  TColumnEvent = procedure(Sender: TListView; Column: LongInt) of object;
  { Compares two items by Column, for SortByColumn; negative if First
    goes before Second (ascending). }
  TListColumnCompareEvent = function(Sender: TListView; First, Second: TListItem; Column: LongInt): LongInt of object;
  TListViewMode = Controls.ListViewBase.TListViewMode;

const
  { The views, here too, so a program needs only this unit. }
  ViewDetails = Controls.ListViewBase.ViewDetails;
  ViewList = Controls.ListViewBase.ViewList;
  ViewSmallIcons = Controls.ListViewBase.ViewSmallIcons;
  ViewLargeIcons = Controls.ListViewBase.ViewLargeIcons;

type
  TListView = class(TListViewBase)
  private
    FMultiSelect: Boolean;
    FSortNumeric: Boolean;
    FSortOnHeaderClick: Boolean;
    FUpdatingSelection: LongInt;
    FSelectionChanged: Boolean;
    FResizing: LongInt;
    FResizeStartX: LongInt;
    FResizeStartWidth: LongInt;
    FLastClickTime: QWord;
    FLastClickIndex: LongInt;
    FOnColumnClick: TColumnEvent;
    FOnActivate: TControlEvent;
    FOnCompare: TListColumnCompareEvent;
    procedure SetSelected(Row: LongInt; Value: Boolean);
    procedure SetItemIndex(Value: LongInt);
    procedure SetMultiSelect(Value: Boolean);
    procedure Activate;
    procedure BeginSelectionChange;
    procedure EndSelectionChange;
    procedure SelectOnly(Index: LongInt);
    procedure SelectRange(First, Last: LongInt; KeepOthers: Boolean);
    procedure MoveFocus(Index: LongInt; Modifiers: LongWord);
    procedure ClickItem(Index: LongInt; Modifiers: LongWord);
    procedure ClickHeader(X: LongInt);
    function CompareForSort(First, Second: TListItem): LongInt;
    procedure ItemsReordered(FocusedItem: TListItem; AnchorItem: TListItem);
  protected
    procedure ItemChanged(Item: TListItem; SelectionChanged: Boolean); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    procedure SelectAll;
    procedure ClearSelection;
    { Sorts the items by Column's texts (as numbers if Numeric, or by
      OnCompare if set) and shows an arrow on its header. Rows added
      later are not sorted in. }
    procedure SortByColumn(Column: LongInt; Ascending: Boolean; Numeric: Boolean = False);
    { Sorts the items by any comparison (the header's arrow goes). }
    procedure SortWith(Compare: TListItemCompare);
    property ItemIndex: LongInt read FItemIndex write SetItemIndex;
    property Selected[Row: LongInt]: Boolean read GetSelected write SetSelected;
    property MultiSelect: Boolean read FMultiSelect write SetMultiSelect;
    property SortOnHeaderClick: Boolean read FSortOnHeaderClick write FSortOnHeaderClick;
    property OnColumnClick: TColumnEvent read FOnColumnClick write FOnColumnClick;
    property OnActivate: TControlEvent read FOnActivate write FOnActivate;
    property OnCompare: TListColumnCompareEvent read FOnCompare write FOnCompare;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.ListBox,
  Controls.ListViewLayout;

const
  MinimumColumnWidth = 16;
  SpaceCharacter = 32;

constructor TListView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FResizing := -1;
  FLastClickIndex := -1;
end;

{ --- Selection --------------------------------------------------------------- }

procedure TListView.ItemChanged(Item: TListItem; SelectionChanged: Boolean);
begin
  Invalidate;
  if not SelectionChanged then
    Exit;
  { Several changes made as one (a range selected) are announced once. }
  if FUpdatingSelection > 0 then
    FSelectionChanged := True
  else
    Changed;
end;

procedure TListView.BeginSelectionChange;
begin
  Inc(FUpdatingSelection);
end;

procedure TListView.EndSelectionChange;
begin
  Dec(FUpdatingSelection);
  if (FUpdatingSelection = 0) and FSelectionChanged then
  begin
    FSelectionChanged := False;
    Changed;
  end;
end;

procedure TListView.SetSelected(Row: LongInt; Value: Boolean);
begin
  if (Row < 0) or (Row >= FItems.Count) then
    Exit;
  if Value and not FMultiSelect then
  begin
    SetItemIndex(Row);
    Exit;
  end;
  TListItem(FItems[Row]).Selected := Value;
end;

procedure TListView.SelectRange(First, Last: LongInt; KeepOthers: Boolean);
var
  Index: LongInt;
  Swap: LongInt;
begin
  if First > Last then
  begin
    Swap := First;
    First := Last;
    Last := Swap;
  end;
  BeginSelectionChange;
  for Index := 0 to FItems.Count - 1 do
    if (Index >= First) and (Index <= Last) then
      TListItem(FItems[Index]).Selected := True
    else if not KeepOthers then
      TListItem(FItems[Index]).Selected := False;
  EndSelectionChange;
end;

procedure TListView.SelectOnly(Index: LongInt);
begin
  if Index < 0 then
    ClearSelection
  else
    SelectRange(Index, Index, False);
end;

procedure TListView.SelectAll;
begin
  if FItems.Count > 0 then
    SelectRange(0, FItems.Count - 1, True);
end;

procedure TListView.ClearSelection;
var
  Index: LongInt;
begin
  BeginSelectionChange;
  for Index := 0 to FItems.Count - 1 do
    TListItem(FItems[Index]).Selected := False;
  EndSelectionChange;
end;

procedure TListView.SetMultiSelect(Value: Boolean);
begin
  if Value = FMultiSelect then
    Exit;
  FMultiSelect := Value;
  { Down to one: the focused item. }
  if not Value then
    SelectOnly(FItemIndex);
end;

procedure TListView.SetItemIndex(Value: LongInt);
begin
  if Value >= FItems.Count then
    Value := FItems.Count - 1;
  if Value < -1 then
    Value := -1;
  if (Value = FItemIndex) and ((Value < 0) or (Selected[Value] and (SelectedCount = 1))) then
    Exit;
  BeginSelectionChange;
  { A new focus is a change even if the selection stays the same. }
  if Value <> FItemIndex then
    FSelectionChanged := True;
  FItemIndex := Value;
  FAnchor := Value;
  SelectOnly(Value);
  if Value >= 0 then
    EnsureVisible(Value);
  Invalidate;
  EndSelectionChange;
end;

{ The focus moved to Index by a key: Shift selects the range from the
  anchor, Ctrl leaves the selection as it is, neither selects Index. }
procedure TListView.MoveFocus(Index: LongInt; Modifiers: LongWord);
begin
  if Index < 0 then
    Exit;
  if FMultiSelect and ((Modifiers and ModifierShift) <> 0) and (FAnchor >= 0) then
  begin
    BeginSelectionChange;
    if Index <> FItemIndex then
      FSelectionChanged := True;
    FItemIndex := Index;
    SelectRange(FAnchor, Index, (Modifiers and ModifierControl) <> 0);
    EnsureVisible(Index);
    EndSelectionChange;
  end
  else if FMultiSelect and ((Modifiers and ModifierControl) <> 0) then
  begin
    FItemIndex := Index;
    EnsureVisible(Index);
    Invalidate;
  end
  else
    SetItemIndex(Index);
end;

{ --- Sorting ----------------------------------------------------------------- }

function TListView.CompareForSort(First, Second: TListItem): LongInt;
begin
  if Assigned(FOnCompare) then
    Result := FOnCompare(Self, First, Second, FSortColumn)
  else if FSortNumeric then
    Result := CompareCellNumbers(First, Second, FSortColumn)
  else
    Result := CompareCellTexts(First, Second, FSortColumn);
  if not FSortAscending then
    Result := -Result;
end;

{ After sorting: the focus and the anchor stay on their items. }
procedure TListView.ItemsReordered(FocusedItem: TListItem; AnchorItem: TListItem);
begin
  FItemIndex := FItems.IndexOf(FocusedItem);
  FAnchor := FItems.IndexOf(AnchorItem);
  if FItemIndex >= 0 then
    EnsureVisible(FItemIndex);
  Invalidate;
end;

procedure TListView.SortByColumn(Column: LongInt; Ascending: Boolean; Numeric: Boolean);
var
  FocusedItem: TListItem;
  AnchorItem: TListItem;
begin
  if (Column < 0) or (Column >= ColumnCount) then
    Exit;
  FSortColumn := Column;
  FSortAscending := Ascending;
  FSortNumeric := Numeric;
  FocusedItem := GetItem(FItemIndex);
  AnchorItem := GetItem(FAnchor);
  SortListItems(FItems, @CompareForSort);
  ItemsReordered(FocusedItem, AnchorItem);
end;

procedure TListView.SortWith(Compare: TListItemCompare);
var
  FocusedItem: TListItem;
  AnchorItem: TListItem;
begin
  FSortColumn := -1;
  FocusedItem := GetItem(FItemIndex);
  AnchorItem := GetItem(FAnchor);
  SortListItems(FItems, Compare);
  ItemsReordered(FocusedItem, AnchorItem);
end;

{ --- The pointer ------------------------------------------------------------- }

procedure TListView.ClickHeader(X: LongInt);
var
  Column: LongInt;
begin
  FResizing := ColumnEdgeAt(X);
  if FResizing >= 0 then
  begin
    FResizeStartX := X;
    FResizeStartWidth := FWidths[FResizing];
    Exit;
  end;
  Column := ColumnAt(X);
  if Column < 0 then
    Exit;
  if FSortOnHeaderClick then
  begin
    { The same column again turns the order round. }
    if Column = FSortColumn then
      SortByColumn(Column, not FSortAscending, FNumericColumns[Column])
    else
      SortByColumn(Column, True, FNumericColumns[Column]);
  end;
  if Assigned(FOnColumnClick) then
    FOnColumnClick(Self, Column);
end;

{ A click on item Index (-1: on no item) with Modifiers held. }
procedure TListView.ClickItem(Index: LongInt; Modifiers: LongWord);
var
  ControlHeld: Boolean;
  ShiftHeld: Boolean;
begin
  ControlHeld := FMultiSelect and ((Modifiers and ModifierControl) <> 0);
  ShiftHeld := FMultiSelect and ((Modifiers and ModifierShift) <> 0);
  if Index < 0 then
  begin
    { Empty space: nothing selected any more (unless adding). }
    if FMultiSelect and not ControlHeld and not ShiftHeld then
      ClearSelection;
    Exit;
  end;
  if ShiftHeld then
    MoveFocus(Index, Modifiers)
  else if ControlHeld then
  begin
    BeginSelectionChange;
    if Index <> FItemIndex then
      FSelectionChanged := True;
    FItemIndex := Index;
    FAnchor := Index;
    TListItem(FItems[Index]).Selected := not TListItem(FItems[Index]).Selected;
    Invalidate;
    EndSelectionChange;
  end
  else
    SetItemIndex(Index);
end;

procedure TListView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
  Modifiers: LongWord;
  Now: QWord;
begin
  if Button <> ButtonLeft then
    Exit;
  if ShowsHeader and (Y < 2 + HeaderHeight) then
  begin
    ClickHeader(X);
    Exit;
  end;
  Index := ItemAtPoint(Grid, X, Y);
  Modifiers := HeldModifiers;
  ClickItem(Index, Modifiers);
  if Index < 0 then
    Exit;
  Now := UptimeMilliseconds;
  if (Index = FLastClickIndex) and (Now - FLastClickTime <= DoubleClickMilliseconds) and
     ((Modifiers and (ModifierShift or ModifierControl)) = 0) then
  begin
    FLastClickIndex := -1;
    Activate;
    Exit;
  end;
  FLastClickIndex := Index;
  FLastClickTime := Now;
end;

procedure TListView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Width: LongInt;
begin
  if FResizing < 0 then
    Exit;
  Width := FResizeStartWidth + Unscaled(X - FResizeStartX);
  if Width < MinimumColumnWidth then
    Width := MinimumColumnWidth;
  FWidths[FResizing] := Width;
  Invalidate;
end;

procedure TListView.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FResizing := -1;
end;

procedure TListView.Activate;
begin
  if Assigned(FOnActivate) then
    FOnActivate(Self);
  Notify(NotifyActivated);
end;

{ --- Keys -------------------------------------------------------------------- }

function TListView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Shown: TListViewGrid;
  Page: LongInt;
  Target: LongInt;
  Start: LongInt;
begin
  Result := True;
  Shown := Grid;
  Page := ItemsPerLine(Shown) * VisibleLineCount(Shown);
  if FMultiSelect and (Code = KeyA) and
     ((Modifiers and (ModifierShift or ModifierControl or ModifierAlt)) = ModifierControl) then
  begin
    SelectAll;
    Exit;
  end;
  if FMultiSelect and (Character = SpaceCharacter) and ((Modifiers and ModifierControl) <> 0) and
     (FItemIndex >= 0) then
  begin
    TListItem(FItems[FItemIndex]).Selected := not TListItem(FItems[FItemIndex]).Selected;
    Exit;
  end;
  if IsEnterKey(Code) then
  begin
    if FItemIndex >= 0 then
      Activate
    else
      Result := False;
    Exit;
  end;
  if FItems.Count = 0 then
    Exit(False);
  { With nothing focused the first key lands on the first item. }
  Start := FItemIndex;
  if Start < 0 then
    Start := 0;
  case Code of
    KeyArrowUp: Target := ItemInDirection(Shown, Start, GridUp);
    KeyArrowDown: Target := ItemInDirection(Shown, Start, GridDown);
    KeyArrowLeft: Target := ItemInDirection(Shown, Start, GridLeft);
    KeyArrowRight: Target := ItemInDirection(Shown, Start, GridRight);
    KeyPageUp: Target := Start - Page;
    KeyPageDown: Target := Start + Page;
    KeyHome: Target := 0;
    KeyEnd: Target := FItems.Count - 1;
  else
    Exit(False);
  end;
  if FItemIndex < 0 then
    Target := 0;
  if Target < 0 then
    Target := 0;
  if Target >= FItems.Count then
    Target := FItems.Count - 1;
  MoveFocus(Target, Modifiers);
end;

end.
