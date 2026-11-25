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
  Item views: a file manager's view of items, in any of eight views
  (extra large, large, medium and small icons, a list, details with
  columns, tiles, content), optionally gathered in collapsible groups,
  with thumbnails, check boxes and a compact spacing. Holding and
  showing the items is TItemViewBase's (Controls.ItemViewBase); this
  adds choosing and handling them:

  * Selection: a click selects an item, Ctrl+click adds or removes one,
    Shift+click selects the range from the anchor; dragging from empty
    space draws a rubber band selecting what it touches (Ctrl keeps the
    rest); a check box toggles its item alone; Ctrl+A selects all.
    InvertSelection and SelectRange are there for menus. Every change is
    announced once (OnChange).
  * Opening: a double click (or a single one, SingleClickOpens) or
    Enter activates (OnActivate).
  * Keys: the arrows move by the layout in every view (Shift extends the
    selection, Ctrl moves the focus alone, Ctrl+Space toggles), Home,
    End, Page Up and Down; typing a name's first letters goes to it.
  * Groups: a click on a group's header collapses or opens it.
  * The header (details): a click on a column announces it
    (OnColumnClick; the program sorts and calls ShowSortArrow), dragging
    an edge resizes the column (OnColumnResized), a right click asks for
    the column chooser (OnHeaderContextMenu).
  * The wheel scrolls; Ctrl with the wheel asks for bigger or smaller
    icons (OnZoom, +1 bigger per notch).
  * EditItem renames in place (an edit box over the name); OnEdited
    hears the new name and may refuse it.
  * Dragging items (DragEnabled) starts a drag with what OnStartDrag
    gives; DropTarget shows where a drop would go.
  * A right click selects the item under the pointer first (keeping a
    selection it is in), or clears the selection on empty space; the
    menu itself is the program's (OnContextMenu).
}
unit Controls.ItemView;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Controls.Base,
  Controls.DragData,
  Controls.ListEditing,
  Controls.TypeAhead,
  Controls.ItemViewItems,
  Controls.ItemViewLayout,
  Controls.ItemViewBase;

type
  TItemView = class;
  TItemColumnEvent = procedure(Sender: TItemView; Column: LongInt) of object;
  TItemHeaderMenuEvent = procedure(Sender: TItemView; X, Y: LongInt) of object;
  TItemEditedEvent = procedure(Sender: TItemView; Index: LongInt; const NewCaption: string;
    var Accept: Boolean) of object;
  TItemStartDragEvent = procedure(Sender: TItemView; var Data: TDragData) of object;
  TItemZoomEvent = procedure(Sender: TItemView; Steps: LongInt) of object;

  TItemView = class(TItemViewBase)
  private
    FUpdatingSelection: LongInt;
    FSelectionChanged: Boolean;
    FSingleClickOpens: Boolean;
    FDragEnabled: Boolean;
    FTypeAhead: TTypeAhead;
    FEditor: TCaptionEditor;
    FLastClickTime: QWord;
    FLastClickIndex: LongInt;
    FPressIndex: LongInt;
    FPressX: LongInt;
    FPressY: LongInt;
    FPressContentX: LongInt;
    FPressContentY: LongInt;
    FDragStarted: Boolean;
    FSelectOnRelease: LongInt;
    FBandKeepsOthers: Boolean;
    FBandBase: array of Boolean;
    FResizingColumn: LongInt;
    FResizeStartX: LongInt;
    FResizeStartWidth: LongInt;
    FOnActivate: TControlEvent;
    FOnColumnClick: TItemColumnEvent;
    FOnColumnResized: TItemColumnEvent;
    FOnHeaderContextMenu: TItemHeaderMenuEvent;
    FOnEdited: TItemEditedEvent;
    FOnStartDrag: TItemStartDragEvent;
    FOnZoom: TItemZoomEvent;
    FOnGroupToggled: TControlEvent;
    function GetSelected(Index: LongInt): Boolean;
    procedure SetSelected(Index: LongInt; Value: Boolean);
    procedure SetItemIndex(Value: LongInt);
    procedure BeginSelectionChange;
    procedure EndSelectionChange;
    procedure MoveFocus(Index: LongInt; Modifiers: LongWord);
    procedure ClickItem(Index: LongInt; Modifiers: LongWord);
    procedure ToggleItem(Index: LongInt);
    procedure PressHeader(X, Y: LongInt; Button: LongWord);
    procedure UpdateBand(X, Y: LongInt);
    procedure StartDragFromPress;
    function CaptionOf(Index: LongInt): string;
    procedure EditorFinished(Sender: TCaptionEditor; Accepted: Boolean);
    procedure PlaceEditor;
    procedure Activate;
  protected
    procedure ItemChanged(Item: TItemViewItem; SelectionChanged: Boolean); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure PointerLeave; override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure Layout; override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
    { A rename in place is over. }
    procedure EditingEnded; virtual;
  public
    constructor Create(AParent: TControl); override;
    function KeyboardContextPoint: TPoint; override;
    procedure SelectAll;
    procedure ClearSelection;
    procedure InvertSelection;
    procedure SelectRange(First, Last: LongInt; KeepOthers: Boolean);
    { Puts an edit box over item Index's name to rename it. }
    procedure EditItem(Index: LongInt; SelectWithoutExtension: Boolean = True);
    procedure EndEditing(Accept: Boolean);
    function IsEditing: Boolean;
    property ItemIndex: LongInt read FItemIndex write SetItemIndex;
    property Selected[Index: LongInt]: Boolean read GetSelected write SetSelected;
    property SingleClickOpens: Boolean read FSingleClickOpens write FSingleClickOpens;
    property DragEnabled: Boolean read FDragEnabled write FDragEnabled;
    property OnActivate: TControlEvent read FOnActivate write FOnActivate;
    property OnColumnClick: TItemColumnEvent read FOnColumnClick write FOnColumnClick;
    property OnColumnResized: TItemColumnEvent read FOnColumnResized write FOnColumnResized;
    property OnHeaderContextMenu: TItemHeaderMenuEvent read FOnHeaderContextMenu write FOnHeaderContextMenu;
    property OnEdited: TItemEditedEvent read FOnEdited write FOnEdited;
    property OnStartDrag: TItemStartDragEvent read FOnStartDrag write FOnStartDrag;
    property OnZoom: TItemZoomEvent read FOnZoom write FOnZoom;
    property OnGroupToggled: TControlEvent read FOnGroupToggled write FOnGroupToggled;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Time,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.ListBox,
  Controls.Painting;

const
  SpaceCharacter = 32;
  DragThreshold = 4;

constructor TItemView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FLastClickIndex := -1;
  FPressIndex := -1;
  FSelectOnRelease := -1;
  FResizingColumn := -1;
  ResetTypeAhead(FTypeAhead);
end;

{ --- Selection ------------------------------------------------------------------------------ }

procedure TItemView.ItemChanged(Item: TItemViewItem; SelectionChanged: Boolean);
begin
  Invalidate;
  if not SelectionChanged then
    Exit;
  if FUpdatingSelection > 0 then
    FSelectionChanged := True
  else
    Changed;
end;

procedure TItemView.BeginSelectionChange;
begin
  Inc(FUpdatingSelection);
end;

procedure TItemView.EndSelectionChange;
begin
  Dec(FUpdatingSelection);
  if (FUpdatingSelection = 0) and FSelectionChanged then
  begin
    FSelectionChanged := False;
    Changed;
  end;
end;

function TItemView.GetSelected(Index: LongInt): Boolean;
begin
  Result := (Index >= 0) and (Index < Count) and Items[Index].Selected;
end;

procedure TItemView.SetSelected(Index: LongInt; Value: Boolean);
begin
  if (Index >= 0) and (Index < Count) then
    Items[Index].Selected := Value;
end;

procedure TItemView.SelectRange(First, Last: LongInt; KeepOthers: Boolean);
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
  for Index := 0 to Count - 1 do
    if (Index >= First) and (Index <= Last) and IsItemShown(Index) then
      Items[Index].Selected := True
    else if not KeepOthers then
      Items[Index].Selected := False;
  EndSelectionChange;
end;

procedure TItemView.SelectAll;
var
  Index: LongInt;
begin
  BeginSelectionChange;
  for Index := 0 to Count - 1 do
    if IsItemShown(Index) then
      Items[Index].Selected := True;
  EndSelectionChange;
end;

procedure TItemView.ClearSelection;
var
  Index: LongInt;
begin
  BeginSelectionChange;
  for Index := 0 to Count - 1 do
    Items[Index].Selected := False;
  EndSelectionChange;
end;

procedure TItemView.InvertSelection;
var
  Index: LongInt;
begin
  BeginSelectionChange;
  for Index := 0 to Count - 1 do
    if IsItemShown(Index) then
      Items[Index].Selected := not Items[Index].Selected;
  EndSelectionChange;
end;

procedure TItemView.SetItemIndex(Value: LongInt);
begin
  if Value >= Count then
    Value := Count - 1;
  if Value < -1 then
    Value := -1;
  BeginSelectionChange;
  if Value <> FItemIndex then
    FSelectionChanged := True;
  FItemIndex := Value;
  FAnchor := Value;
  if Value < 0 then
    ClearSelection
  else
    SelectRange(Value, Value, False);
  if Value >= 0 then
    EnsureVisible(Value);
  Invalidate;
  EndSelectionChange;
end;

procedure TItemView.MoveFocus(Index: LongInt; Modifiers: LongWord);
begin
  if Index < 0 then
    Exit;
  if ((Modifiers and ModifierShift) <> 0) and (FAnchor >= 0) then
  begin
    BeginSelectionChange;
    if Index <> FItemIndex then
      FSelectionChanged := True;
    FItemIndex := Index;
    SelectRange(FAnchor, Index, (Modifiers and ModifierControl) <> 0);
    EnsureVisible(Index);
    EndSelectionChange;
  end
  else if (Modifiers and ModifierControl) <> 0 then
  begin
    FItemIndex := Index;
    EnsureVisible(Index);
    Invalidate;
  end
  else
    SetItemIndex(Index);
end;

procedure TItemView.ToggleItem(Index: LongInt);
begin
  BeginSelectionChange;
  if Index <> FItemIndex then
    FSelectionChanged := True;
  FItemIndex := Index;
  FAnchor := Index;
  Items[Index].Selected := not Items[Index].Selected;
  Invalidate;
  EndSelectionChange;
end;

procedure TItemView.ClickItem(Index: LongInt; Modifiers: LongWord);
begin
  if Index < 0 then
    Exit;
  if (Modifiers and ModifierShift) <> 0 then
    MoveFocus(Index, Modifiers)
  else if (Modifiers and ModifierControl) <> 0 then
    ToggleItem(Index)
  else
    SetItemIndex(Index);
end;

procedure TItemView.Activate;
begin
  if Assigned(FOnActivate) then
    FOnActivate(Self);
  Notify(NotifyActivated);
end;

{ --- Renaming in place ---------------------------------------------------------------------- }

function TItemView.IsEditing: Boolean;
begin
  Result := (FEditor <> nil) and FEditor.Editing;
end;

procedure TItemView.PlaceEditor;
var
  Box: TRectangle;
begin
  if not IsEditing then
    Exit;
  Box := NameBounds(FEditIndex);
  FEditor.AssignBounds(Unscaled(Box.Left) - 2, Unscaled(Box.Top + RectangleHeight(Box) div 2) - 11,
    Unscaled(RectangleWidth(Box)) + 4, 22);
end;

procedure TItemView.EditItem(Index: LongInt; SelectWithoutExtension: Boolean);
begin
  if (Index < 0) or (Index >= Count) then
    Exit;
  EndEditing(True);
  if FEditor = nil then
  begin
    FEditor := TCaptionEditor.Create(Self);
    FEditor.OnFinished := @EditorFinished;
  end;
  EnsureVisible(Index);
  FEditIndex := Index;
  FEditor.StartEditing(Items[Index].Caption, SelectWithoutExtension);
  PlaceEditor;
  FEditor.UpdatePixelBounds;
  Invalidate;
end;

procedure TItemView.EndEditing(Accept: Boolean);
begin
  if IsEditing then
    FEditor.StopEditing(Accept);
end;

procedure TItemView.EditorFinished(Sender: TCaptionEditor; Accepted: Boolean);
var
  Index: LongInt;
  Accept: Boolean;
begin
  Index := FEditIndex;
  FEditIndex := -1;
  if Sender.Focused then
    SetFocus;
  Invalidate;
  if Accepted and (Index >= 0) and (Index < Count) and (Sender.Text <> Items[Index].Caption) then
  begin
    Accept := Sender.Text <> '';
    if Assigned(FOnEdited) then
      FOnEdited(Self, Index, Sender.Text, Accept);
    if Accept and (Index < Count) then
      Items[Index].Cells[0] := Sender.Text;
  end;
  EditingEnded;
end;

procedure TItemView.EditingEnded;
begin
end;

procedure TItemView.Layout;
begin
  inherited Layout;
  PlaceEditor;
end;

{ --- The pointer -------------------------------------------------------------------------- }

procedure TItemView.PressHeader(X, Y: LongInt; Button: LongWord);
var
  Column: LongInt;
begin
  if Button = ButtonRight then
  begin
    if Assigned(FOnHeaderContextMenu) then
      FOnHeaderContextMenu(Self, X, Y);
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
  FResizingColumn := HeaderEdgeAt(X);
  if FResizingColumn >= 0 then
  begin
    FResizeStartX := X;
    FResizeStartWidth := FColumns[FResizingColumn].Width;
    Exit;
  end;
  Column := HeaderColumnAt(X);
  if (Column >= 0) and Assigned(FOnColumnClick) then
    FOnColumnClick(Self, Column);
end;

procedure TItemView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
  Group: LongInt;
  Modifiers: LongWord;
  Now: QWord;
  Position: LongInt;
begin
  EndEditing(True);
  SetFocus;
  if ShowsHeader and (Y < HeaderBox.Bottom) and (Y >= HeaderBox.Top) then
  begin
    PressHeader(X, Y, Button);
    Exit;
  end;
  Modifiers := HeldModifiers;
  Group := GroupAt(X, Y);
  if (Group >= 0) and (Button = ButtonLeft) then
  begin
    SetGroupCollapsed(Group, not FGroups[Group].Collapsed);
    if Assigned(FOnGroupToggled) then
      FOnGroupToggled(Self);
    Exit;
  end;
  Index := ItemAt(X, Y);
  if Button = ButtonRight then
  begin
    if Index < 0 then
      ClearSelection
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
  FPressContentX := ContentX(X);
  FPressContentY := ContentY(Y);
  FDragStarted := False;
  FSelectOnRelease := -1;
  if Index < 0 then
  begin
    { Empty space: a rubber band may follow. }
    FBandKeepsOthers := (Modifiers and (ModifierControl or ModifierShift)) <> 0;
    if not FBandKeepsOthers then
      ClearSelection;
    SetLength(FBandBase, Count);
    for Position := 0 to Count - 1 do
      FBandBase[Position] := Items[Position].Selected;
    Exit;
  end;
  if FShowCheckBoxes and RectangleContainsPoint(CheckBoxBounds(Index), X, Y) then
  begin
    ToggleItem(Index);
    FPressIndex := -1;
    Exit;
  end;
  if Selected[Index] and (SelectedCount > 1) and ((Modifiers and (ModifierShift or ModifierControl)) = 0) then
  begin
    FSelectOnRelease := Index;
    FItemIndex := Index;
    FAnchor := Index;
    Invalidate;
  end
  else
    ClickItem(Index, Modifiers);
  if (Modifiers and (ModifierShift or ModifierControl)) <> 0 then
    Exit;
  Now := UptimeMilliseconds;
  if FSingleClickOpens then
  begin
    FLastClickIndex := Index;
    FLastClickTime := Now;
    Exit;
  end;
  if (Index = FLastClickIndex) and (Now - FLastClickTime <= DoubleClickMilliseconds) then
  begin
    FLastClickIndex := -1;
    FPressIndex := -1;
    Activate;
    Exit;
  end;
  FLastClickIndex := Index;
  FLastClickTime := Now;
end;

procedure TItemView.StartDragFromPress;
var
  Data: TDragData;
begin
  FDragStarted := True;
  FSelectOnRelease := -1;
  FLastClickIndex := -1;
  Data := nil;
  if Assigned(FOnStartDrag) then
    FOnStartDrag(Self, Data);
  if Data <> nil then
    BeginDrag(Data);
end;

procedure TItemView.UpdateBand(X, Y: LongInt);
var
  Left: LongInt;
  Top: LongInt;
  Right: LongInt;
  Bottom: LongInt;
  Index: LongInt;
  Common: TRectangle;
  Touched: Boolean;
begin
  Left := FPressContentX;
  Right := ContentX(X);
  if Right < Left then
  begin
    Left := Right;
    Right := FPressContentX;
  end;
  Top := FPressContentY;
  Bottom := ContentY(Y);
  if Bottom < Top then
  begin
    Top := Bottom;
    Bottom := FPressContentY;
  end;
  FBanding := True;
  FBandRectangle := MakeRectangle(Left, Top, Right - Left + 1, Bottom - Top + 1);
  BeginSelectionChange;
  for Index := 0 to Count - 1 do
  begin
    Touched := FLayout.ItemShown[Index] and IntersectRectangles(FLayout.ItemRects[Index], FBandRectangle, Common);
    if FBandKeepsOthers and (Index <= High(FBandBase)) then
      Items[Index].Selected := FBandBase[Index] <> Touched
    else
      Items[Index].Selected := Touched;
  end;
  EndSelectionChange;
  Invalidate;
end;

procedure TItemView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Hot: LongInt;
  HotGroup: LongInt;
  Width: LongInt;
  LeftHeld: Boolean;
begin
  LeftHeld := (Buttons and (LongWord(1) shl ButtonLeft)) <> 0;
  if FResizingColumn >= 0 then
  begin
    if not LeftHeld then
    begin
      FResizingColumn := -1;
      Exit;
    end;
    Width := FResizeStartWidth + Unscaled(X - FResizeStartX);
    SetColumnWidth(FResizingColumn, Width);
    Exit;
  end;
  if LeftHeld and (FPressIndex >= 0) and FDragEnabled and not FDragStarted and
     ((Abs(X - FPressX) > Scaled(DragThreshold)) or (Abs(Y - FPressY) > Scaled(DragThreshold))) then
  begin
    StartDragFromPress;
    Exit;
  end;
  if LeftHeld and (FPressIndex < 0) and (Length(FBandBase) = Count) and (Count > 0) and
     (FBanding or (Abs(X - FPressX) > Scaled(DragThreshold)) or (Abs(Y - FPressY) > Scaled(DragThreshold))) then
  begin
    UpdateBand(X, Y);
    Exit;
  end;
  if ShowsHeader and (Y < HeaderBox.Bottom) and (HeaderEdgeAt(X) >= 0) then
    PointerShape := PointerResizeHorizontal
  else
    PointerShape := PointerArrow;
  Hot := ItemAt(X, Y);
  HotGroup := GroupAt(X, Y);
  if (Hot <> FHotIndex) or (HotGroup <> FHotGroup) then
  begin
    FHotIndex := Hot;
    FHotGroup := HotGroup;
    Invalidate;
  end;
end;

procedure TItemView.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  if FResizingColumn >= 0 then
  begin
    if Assigned(FOnColumnResized) then
      FOnColumnResized(Self, FResizingColumn);
    FResizingColumn := -1;
    Exit;
  end;
  if (FSelectOnRelease >= 0) and not FDragStarted then
    SetItemIndex(FSelectOnRelease);
  if FSingleClickOpens and (FPressIndex >= 0) and not FDragStarted and (ItemAt(X, Y) = FPressIndex) and
     ((HeldModifiers and (ModifierShift or ModifierControl)) = 0) then
    Activate;
  FBanding := False;
  FBandBase := nil;
  FSelectOnRelease := -1;
  FPressIndex := -1;
  FDragStarted := False;
  Invalidate;
end;

procedure TItemView.PointerLeave;
begin
  if (FHotIndex >= 0) or (FHotGroup >= 0) then
  begin
    FHotIndex := -1;
    FHotGroup := -1;
    Invalidate;
  end;
end;

procedure TItemView.Wheel(Steps: LongInt);
begin
  EndEditing(True);
  if ((HeldModifiers and ModifierControl) <> 0) and Assigned(FOnZoom) then
  begin
    FOnZoom(Self, Steps);
    Exit;
  end;
  inherited Wheel(Steps);
end;

procedure TItemView.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
begin
  { A right click on the header is the column chooser's, not this. }
  if not FromKeyboard and ShowsHeader and (Y < HeaderBox.Bottom) then
    Exit;
  inherited ContextMenu(X, Y, FromKeyboard);
end;

function TItemView.KeyboardContextPoint: TPoint;
var
  Box: TRectangle;
begin
  if FItemIndex < 0 then
    Exit(inherited KeyboardContextPoint);
  EnsureVisible(FItemIndex);
  Box := NameBounds(FItemIndex);
  Result := MakePoint(Box.Left + Scaled(8), Box.Top + RectangleHeight(Box) div 2);
end;

{ --- Keys ------------------------------------------------------------------------------------ }

function TItemView.CaptionOf(Index: LongInt): string;
begin
  Result := Items[Index].Caption;
end;

function TItemView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Target: LongInt;
  Start: LongInt;
  Held: LongWord;
  Found: LongInt;
begin
  Result := True;
  EnsureLayout;
  Held := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  if (Code = KeyA) and (Held = ModifierControl) then
  begin
    SelectAll;
    Exit;
  end;
  if (Character = SpaceCharacter) and ((Modifiers and ModifierControl) <> 0) and (FItemIndex >= 0) then
  begin
    ToggleItem(FItemIndex);
    Exit;
  end;
  if IsEnterKey(Code) and ((Held and ModifierAlt) = 0) then
  begin
    if FItemIndex >= 0 then
      Activate
    else
      Result := False;
    Exit;
  end;
  if Count = 0 then
    Exit(False);
  if (Character >= SpaceCharacter) and ((Modifiers and (ModifierControl or ModifierAlt)) = 0) and
     not ((Character = SpaceCharacter) and (FTypeAhead.Typed = '')) then
  begin
    Found := TypeAheadFind(FTypeAhead, Character, UptimeMilliseconds, FItemIndex, Count, @CaptionOf);
    if Found >= 0 then
      SetItemIndex(Found);
    Exit;
  end;
  if (Held and ModifierAlt) <> 0 then
    Exit(False);
  Start := FItemIndex;
  case Code of
    KeyArrowUp: Target := ItemInDirection(FLayout, FMode, Start, ItemDirectionUp);
    KeyArrowDown: Target := ItemInDirection(FLayout, FMode, Start, ItemDirectionDown);
    KeyArrowLeft: Target := ItemInDirection(FLayout, FMode, Start, ItemDirectionLeft);
    KeyArrowRight: Target := ItemInDirection(FLayout, FMode, Start, ItemDirectionRight);
    KeyPageUp: Target := ItemAPageAway(FLayout, Start, -RectangleHeight(ItemArea));
    KeyPageDown: Target := ItemAPageAway(FLayout, Start, RectangleHeight(ItemArea));
    KeyHome: Target := FirstShownItem(FLayout);
    KeyEnd: Target := LastShownItem(FLayout);
  else
    Exit(False);
  end;
  if Start < 0 then
    Target := FirstShownItem(FLayout);
  MoveFocus(Target, Modifiers);
end;

end.
