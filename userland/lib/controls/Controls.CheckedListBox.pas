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
  Checked list boxes: a list box with a check box before each item.

  Everything a list box does, and: Space toggles the item with the
  focus (the choice), a click on an item's box toggles it. With
  AllowMixed an item goes round three states, unchecked, checked and
  mixed (some of what it stands for checked); a program may set any
  state. A toggled item is announced (OnItemCheck, NotifyItemChecked);
  setting a state from the program is not.

  Each item's state is kept with it in Items.Objects (so it follows the
  item when items are inserted, deleted or sorted): a program keeps its
  own data elsewhere.
}
unit Controls.CheckedListBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.ListBox,
  Controls.CheckMarks;

type
  TItemCheckEvent = procedure(Sender: TControl; Index: LongInt; Checked: Boolean) of object;

  TCheckedListBox = class(TListBox)
  private
    FAllowMixed: Boolean;
    FOnItemCheck: TItemCheckEvent;
    function GetState(Index: LongInt): TCheckState;
    procedure SetState(Index: LongInt; Value: TCheckState);
    function GetChecked(Index: LongInt): Boolean;
    procedure SetChecked(Index: LongInt; Value: Boolean);
    function MarkBounds(const Row: TRectangle): TRectangle;
  protected
    procedure PaintItem(var Canvas: TCanvas; Index: LongInt; const Row: TRectangle); override;
    function ItemIndent: LongInt; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    { Tells OnItemCheck and the parent. }
    procedure ItemChecked(Index: LongInt); virtual;
  public
    function ItemHeight: LongInt; override;
    function PreferredSize: TSize; override;
    { As Space or a click does: the next state, announced. }
    procedure ToggleItem(Index: LongInt);
    procedure CheckAll;
    procedure UncheckAll;
    { How many items are checked (mixed ones not). }
    function CheckedCount: LongInt;
    property State[Index: LongInt]: TCheckState read GetState write SetState;
    { Checked: the state is CheckChecked; setting it checks or unchecks. }
    property Checked[Index: LongInt]: Boolean read GetChecked write SetChecked;
    property AllowMixed: Boolean read FAllowMixed write FAllowMixed;
    property OnItemCheck: TItemCheckEvent read FOnItemCheck write FOnItemCheck;
  end;

const
  NotifyItemChecked = 4;

implementation

uses
  Abi.SystemCalls,
  Windowing.Connection,
  Controls.Keys,
  Controls.LayoutRules,
  Controls.Text,
  Windowing.Theme;

const
  { Logical units: the rows shown when it sizes itself, at most. }
  PreferredVisibleRows = 8;
  CheckedListRoom = 8;

{ The widest item after its check box, the scroll bar beside them, and
  up to PreferredVisibleRows rows. }
function TCheckedListBox.PreferredSize: TSize;
var
  Index: LongInt;
  Widest: LongInt;
  Rows: LongInt;
begin
  Widest := 0;
  for Index := 0 to Items.Count - 1 do
    if TextWidth(ControlFace, Items[Index]) > Widest then
      Widest := TextWidth(ControlFace, Items[Index]);
  Rows := Items.Count;
  if Rows > PreferredVisibleRows then
    Rows := PreferredVisibleRows;
  if Rows < 1 then
    Rows := 1;
  Result := MakeSize(PixelsToLogicalCeiling(ItemIndent + Widest) + Theme.ScrollBarWidth + CheckedListRoom,
    PixelsToLogicalCeiling(Rows * ItemHeight + 4));
end;

function TCheckedListBox.ItemHeight: LongInt;
var
  MarkHeight: LongInt;
begin
  Result := inherited ItemHeight;
  MarkHeight := CheckMarkSize + Scaled(3);
  if Result < MarkHeight then
    Result := MarkHeight;
end;

function TCheckedListBox.ItemIndent: LongInt;
begin
  Result := CheckMarkSize + Scaled(6);
end;

function TCheckedListBox.GetState(Index: LongInt): TCheckState;
var
  Stored: PtrInt;
begin
  if (Index < 0) or (Index >= Items.Count) then
    Exit(CheckUnchecked);
  Stored := PtrInt(Items.Objects[Index]);
  if (Stored < Ord(Low(TCheckState))) or (Stored > Ord(High(TCheckState))) then
    Exit(CheckUnchecked);
  Result := TCheckState(Stored);
end;

procedure TCheckedListBox.SetState(Index: LongInt; Value: TCheckState);
begin
  if (Index < 0) or (Index >= Items.Count) or (GetState(Index) = Value) then
    Exit;
  Items.Objects[Index] := TObject(PtrInt(Ord(Value)));
  Invalidate;
end;

function TCheckedListBox.GetChecked(Index: LongInt): Boolean;
begin
  Result := GetState(Index) = CheckChecked;
end;

procedure TCheckedListBox.SetChecked(Index: LongInt; Value: Boolean);
begin
  if Value then
    SetState(Index, CheckChecked)
  else
    SetState(Index, CheckUnchecked);
end;

procedure TCheckedListBox.ItemChecked(Index: LongInt);
begin
  if Assigned(FOnItemCheck) then
    FOnItemCheck(Self, Index, GetChecked(Index));
  Notify(NotifyItemChecked);
end;

procedure TCheckedListBox.ToggleItem(Index: LongInt);
var
  Next: TCheckState;
begin
  if (Index < 0) or (Index >= Items.Count) then
    Exit;
  case GetState(Index) of
    CheckUnchecked: Next := CheckChecked;
    CheckChecked:
      if FAllowMixed then
        Next := CheckMixed
      else
        Next := CheckUnchecked;
  else
    Next := CheckUnchecked;
  end;
  SetState(Index, Next);
  ItemChecked(Index);
end;

procedure TCheckedListBox.CheckAll;
var
  Index: LongInt;
begin
  for Index := 0 to Items.Count - 1 do
    SetState(Index, CheckChecked);
end;

procedure TCheckedListBox.UncheckAll;
var
  Index: LongInt;
begin
  for Index := 0 to Items.Count - 1 do
    SetState(Index, CheckUnchecked);
end;

function TCheckedListBox.CheckedCount: LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to Items.Count - 1 do
    if GetChecked(Index) then
      Inc(Result);
end;

{ The box at the start of Row, centred down it. }
function TCheckedListBox.MarkBounds(const Row: TRectangle): TRectangle;
var
  Size: LongInt;
begin
  Size := CheckMarkSize;
  Result := MakeRectangle(Row.Left + Scaled(2), Row.Top + (RectangleHeight(Row) - Size) div 2, Size, Size);
end;

procedure TCheckedListBox.PaintItem(var Canvas: TCanvas; Index: LongInt; const Row: TRectangle);
begin
  inherited PaintItem(Canvas, Index, Row);
  DrawCheckMark(Canvas, MarkBounds(Row), GetState(Index), Enabled);
end;

procedure TCheckedListBox.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  Index := ItemAt(Y);
  inherited PointerDown(X, Y, Button);
  { The box (and the space either side of it) toggles. }
  if (Button = ButtonLeft) and (Index >= 0) and (X < 2 + ItemIndent) then
    ToggleItem(Index);
end;

function TCheckedListBox.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if (Code = KeySpace) and (ItemIndex >= 0) then
  begin
    ToggleItem(ItemIndex);
    Exit(True);
  end;
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

end.
