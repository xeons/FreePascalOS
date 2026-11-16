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
  announced once (OnChange, NotifyChanged). Typing the first letters of
  a name goes to it (Controls.TypeAhead).

  A right click selects the item under the pointer first (unless it is
  selected already: a menu for all the selected items), or clears the
  selection on empty space; the context menu itself is the program's
  (OnContextMenu, when the button is let go). Shift+F10 and the menu key
  ask for it at the focused item.

  EditItem puts an edit box over an item's name to rename it in place
  (Controls.ListEditing); OnEdited hears the new name and may refuse it.

  With DragEnabled, moving the pointer a few units with the button held
  on an item starts a drag (OnStartDrag gives what is dragged, usually
  the selected items); pressing on one of several selected items keeps
  them selected until the button is let go without a drag, so they can
  be dragged together. Where a drop would go is shown with DropTarget,
  which the program sets as the drag passes over (OnDragOver).
}
unit Controls.ListView;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Controls.Base,
  Controls.DragData,
  Controls.ListItems,
  Controls.ListSorting,
  Controls.ListEditing,
  Controls.TypeAhead,
  Controls.ListViewBase;

type
  TListView = class;
  TColumnEvent = procedure(Sender: TListView; Column: LongInt) of object;
  { Compares two items by Column, for SortByColumn; negative if First
    goes before Second (ascending). }
  TListColumnCompareEvent = function(Sender: TListView; First, Second: TListItem; Column: LongInt): LongInt of object;
  { An item renamed in place to NewCaption; Accept (True to start with)
    False keeps the old name. }
  TListItemEditedEvent = procedure(Sender: TListView; Index: LongInt; const NewCaption: string;
    var Accept: Boolean) of object;
  { A drag starts: Data is what is dragged (nil: no drag). }
  TListStartDragEvent = procedure(Sender: TListView; var Data: TDragData) of object;
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
    FTypeAhead: TTypeAhead;
    FEditor: TCaptionEditor;
    FOnEdited: TListItemEditedEvent;
    FDragEnabled: Boolean;
    FOnStartDrag: TListStartDragEvent;
    { The item a left press was on (-1: none, or no press), where, and
      whether a drag has started from it. }
    FPressIndex: LongInt;
    FPressX: LongInt;
    FPressY: LongInt;
    FDragStarted: Boolean;
    { A press on one of several selected items: it alone is selected
      when the button is let go, unless a drag started. }
    FSelectOnRelease: LongInt;
    function CaptionOf(Index: LongInt): string;
    function FindByTyping(Character: LongWord): Boolean;
    procedure EditorFinished(Sender: TCaptionEditor; Accepted: Boolean);
    procedure PlaceEditor;
    procedure StartDragFromPress;
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
    procedure Layout; override;
    { A rename in place is over (whether the name changed or not). }
    procedure EditingEnded; virtual;
    procedure Wheel(Steps: LongInt); override;
  public
    constructor Create(AParent: TControl); override;
    function KeyboardContextPoint: TPoint; override;
    { Puts an edit box over item Index's name to rename it (the name
      without its extension selected if SelectWithoutExtension). }
    procedure EditItem(Index: LongInt; SelectWithoutExtension: Boolean = True);
    { Ends a rename in progress, taking the name typed if Accept. }
    procedure EndEditing(Accept: Boolean);
    function IsEditing: Boolean;
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
    property OnEdited: TListItemEditedEvent read FOnEdited write FOnEdited;
    property DragEnabled: Boolean read FDragEnabled write FDragEnabled;
    property OnStartDrag: TListStartDragEvent read FOnStartDrag write FOnStartDrag;
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
  { Logical units the pointer moves with the button held before a drag
    starts (less is a shaky click). }
  DragThreshold = 4;

constructor TListView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FResizing := -1;
  FLastClickIndex := -1;
  FEditIndex := -1;
  FPressIndex := -1;
  FSelectOnRelease := -1;
  ResetTypeAhead(FTypeAhead);
end;

{ --- Renaming in place ---------------------------------------------------------- }

function TListView.IsEditing: Boolean;
begin
  Result := (FEditor <> nil) and FEditor.Editing;
end;

{ Puts the edit box over the name being edited (its logical bounds;
  the layout places it in pixels: setting the bounds the ordinary way
  would lay the list out again, which places the box again...). }
procedure TListView.PlaceEditor;
var
  Box: TRectangle;
begin
  if not IsEditing then
    Exit;
  Box := CaptionBounds(FEditIndex);
  { A little taller than the text, for the edit box's bevel. }
  FEditor.AssignBounds(Unscaled(Box.Left) - 2, Unscaled(Box.Top + RectangleHeight(Box) div 2) - 11,
    Unscaled(RectangleWidth(Box)) + 4, 22);
end;

procedure TListView.EditItem(Index: LongInt; SelectWithoutExtension: Boolean);
begin
  if (Index < 0) or (Index >= FItems.Count) then
    Exit;
  EndEditing(True);
  if FEditor = nil then
  begin
    FEditor := TCaptionEditor.Create(Self);
    FEditor.OnFinished := @EditorFinished;
  end;
  EnsureVisible(Index);
  FEditIndex := Index;
  FEditor.StartEditing(TListItem(FItems[Index]).Caption, SelectWithoutExtension);
  PlaceEditor;
  FEditor.UpdatePixelBounds;
  Invalidate;
end;

procedure TListView.EndEditing(Accept: Boolean);
begin
  if IsEditing then
    FEditor.StopEditing(Accept);
end;

procedure TListView.EditorFinished(Sender: TCaptionEditor; Accepted: Boolean);
var
  Index: LongInt;
  Accept: Boolean;
  HadFocus: Boolean;
begin
  Index := FEditIndex;
  FEditIndex := -1;
  { Enter or Escape leave the focus in the (hidden) box: back to the
    list. A click elsewhere has moved it already. }
  HadFocus := Sender.Focused;
  if HadFocus then
    SetFocus;
  Invalidate;
  if Accepted and (Index >= 0) and (Index < FItems.Count) and (Sender.Text <> TListItem(FItems[Index]).Caption) then
  begin
    Accept := Sender.Text <> '';
    if Assigned(FOnEdited) then
      FOnEdited(Self, Index, Sender.Text, Accept);
    if Accept and (Index < FItems.Count) then
      TListItem(FItems[Index]).Cells[0] := Sender.Text;
  end;
  EditingEnded;
end;

procedure TListView.EditingEnded;
begin
end;

procedure TListView.Layout;
begin
  PlaceEditor;
  inherited Layout;
end;

procedure TListView.Wheel(Steps: LongInt);
begin
  { The box would stay where the name was. }
  EndEditing(True);
  inherited Wheel(Steps);
end;

{ --- Typing names ------------------------------------------------------------ }

function TListView.CaptionOf(Index: LongInt): string;
begin
  Result := TListItem(FItems[Index]).Caption;
end;

function TListView.FindByTyping(Character: LongWord): Boolean;
var
  Found: LongInt;
begin
  Found := TypeAheadFind(FTypeAhead, Character, UptimeMilliseconds, FItemIndex, FItems.Count, @CaptionOf);
  Result := Found >= 0;
  if Result then
    SetItemIndex(Found);
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
  EndEditing(True);
  if ShowsHeader and (Y < 2 + HeaderHeight) then
  begin
    if Button = ButtonLeft then
      ClickHeader(X);
    Exit;
  end;
  Index := ItemAtPoint(Grid, X, Y);
  Modifiers := HeldModifiers;
  if Button = ButtonRight then
  begin
    { The context menu is for what is under the pointer: the selection
      if the item is in it, else that item alone (or nothing). }
    if Index < 0 then
    begin
      if FMultiSelect then
        ClearSelection;
    end
    else if not Selected[Index] then
      SetItemIndex(Index)
    else
    begin
      FItemIndex := Index;
      Invalidate;
    end;
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
  FPressIndex := Index;
  FPressX := X;
  FPressY := Y;
  FDragStarted := False;
  FSelectOnRelease := -1;
  if (Index >= 0) and FMultiSelect and Selected[Index] and (SelectedCount > 1) and
     ((Modifiers and (ModifierShift or ModifierControl)) = 0) then
  begin
    { Keep the others for a drag; decided when the button is let go. }
    FSelectOnRelease := Index;
    FItemIndex := Index;
    FAnchor := Index;
    Invalidate;
  end
  else
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

procedure TListView.StartDragFromPress;
var
  Data: TDragData;
begin
  FDragStarted := True;
  FSelectOnRelease := -1;
  { A drag is no click: the next press does not make a double click. }
  FLastClickIndex := -1;
  Data := nil;
  if Assigned(FOnStartDrag) then
    FOnStartDrag(Self, Data);
  if Data <> nil then
    BeginDrag(Data);
end;

procedure TListView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Width: LongInt;
begin
  if (FResizing < 0) and FDragEnabled and (FPressIndex >= 0) and not FDragStarted and
     ((Buttons and (LongWord(1) shl ButtonLeft)) <> 0) and
     ((Abs(X - FPressX) > Scaled(DragThreshold)) or (Abs(Y - FPressY) > Scaled(DragThreshold))) then
  begin
    StartDragFromPress;
    Exit;
  end;
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
  if (Button = ButtonLeft) and (FSelectOnRelease >= 0) and not FDragStarted then
    SetItemIndex(FSelectOnRelease);
  if Button = ButtonLeft then
  begin
    FSelectOnRelease := -1;
    FPressIndex := -1;
    FDragStarted := False;
  end;
end;

function TListView.KeyboardContextPoint: TPoint;
var
  Cell: TRectangle;
begin
  if FItemIndex < 0 then
    Exit(inherited KeyboardContextPoint);
  EnsureVisible(FItemIndex);
  Cell := CaptionBounds(FItemIndex);
  Result := MakePoint(Cell.Left + Scaled(8), Cell.Top + RectangleHeight(Cell) div 2);
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
  { A character typed (not a command key): a name starting with it. A
    space starts no name (Ctrl+Space toggles, above). }
  if (Character >= SpaceCharacter) and ((Modifiers and (ModifierControl or ModifierAlt)) = 0) and
     not ((Character = SpaceCharacter) and (FTypeAhead.Typed = '')) then
  begin
    FindByTyping(Character);
    Exit;
  end;
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
