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
  Combo boxes: a choice among items, shown in a field with a drop
  button; the items in a list that drops below it.

  A click on the field or the button opens the list (a pop-up); a click
  in it (or Enter) chooses and closes it, Escape or a click elsewhere
  closes it. With the list closed, the up and down arrows change the
  choice. A new choice is announced (OnChange, NotifyChanged).

  The text shown is always the chosen item's: when the items change
  (one renamed, inserted before it, or the list cleared), it follows,
  and so does an open list.
}
unit Controls.ComboBox;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Controls.Base,
  Controls.Popups,
  Controls.ListBox;

type
  TComboBox = class;

  { The dropped list: a click chooses. }
  TComboList = class(TListBox)
  private
    FCombo: TComboBox;
  protected
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  end;

  TComboBox = class(TControl)
  private
    FItems: TStringList;
    FItemIndex: LongInt;
    FPopup: TPopupWindow;
    FList: TComboList;
    procedure SetItemIndex(Value: LongInt);
    procedure ShowChosenItem;
    procedure ItemsChanged(Sender: TObject);
    procedure ListDismissed(Sender: TControl);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure DropDown;
    procedure CloseUp;
    { The list chose Index. }
    procedure Choose(Index: LongInt);
    function DroppedDown: Boolean;
    function PreferredSize: TSize; override;
    property Items: TStringList read FItems;
    property ItemIndex: LongInt read FItemIndex write SetItemIndex;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Window,
  Controls.Buttons,
  Controls.LayoutRules;

const
  MaximumDroppedItems = 8;

procedure TComboList.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  inherited PointerUp(X, Y, Button);
  if (Button = ButtonLeft) and (ItemAt(Y) >= 0) then
    FCombo.Choose(ItemAt(Y));
end;

function TComboList.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if IsEnterKey(Code) then
  begin
    FCombo.Choose(ItemIndex);
    Exit(True);
  end;
  if Code = KeyEscape then
  begin
    FCombo.CloseUp;
    Exit(True);
  end;
  Result := inherited KeyDown(Code, Character, Modifiers);
end;

constructor TComboBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FItems := TStringList.Create;
  FItems.OnChange := @ItemsChanged;
  FItemIndex := -1;
end;

destructor TComboBox.Destroy;
begin
  CloseUp;
  FItems.Free;
  inherited Destroy;
end;

{ The text shown is the chosen item's (or nothing, with none chosen). }
procedure TComboBox.ShowChosenItem;
begin
  if FItemIndex >= 0 then
    Text := FItems[FItemIndex]
  else
    Text := '';
  Invalidate;
end;

procedure TComboBox.ItemsChanged(Sender: TObject);
begin
  if FItemIndex >= FItems.Count then
    FItemIndex := FItems.Count - 1;
  ShowChosenItem;
  if FList <> nil then
  begin
    FList.Items.Assign(FItems);
    FList.ItemIndex := FItemIndex;
  end;
end;

procedure TComboBox.SetItemIndex(Value: LongInt);
begin
  if Value >= FItems.Count then
    Value := FItems.Count - 1;
  if Value < -1 then
    Value := -1;
  if Value = FItemIndex then
  begin
    { The same choice: nothing to announce, but its text may be new. }
    ShowChosenItem;
    Exit;
  end;
  FItemIndex := Value;
  ShowChosenItem;
  Changed;
end;

function TComboBox.DroppedDown: Boolean;
begin
  Result := FPopup <> nil;
end;

procedure TComboBox.DropDown;
var
  Window: TControlWindow;
  Rows: LongInt;
  Height: LongInt;
begin
  if (FPopup <> nil) or (FItems.Count = 0) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  Rows := FItems.Count;
  if Rows > MaximumDroppedItems then
    Rows := MaximumDroppedItems;
  Height := Unscaled(Rows * (TextHeight(ControlFace) + Scaled(2)) + 4) + 1;
  FPopup := TPopupWindow.CreatePopup(Window, Window.ScreenLeft + Unscaled(PixelBounds.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Bottom), Unscaled(RectangleWidth(PixelBounds)), Height);
  FPopup.OnDismiss := @ListDismissed;
  FList := TComboList.Create(FPopup.Root);
  FList.FCombo := Self;
  FList.Align := AlignClient;
  FList.Items.Assign(FItems);
  FList.ItemIndex := FItemIndex;
  FList.SetFocus;
  FPopup.Popup;
  Invalidate;
end;

procedure TComboBox.ListDismissed(Sender: TControl);
begin
  FPopup := nil;
  FList := nil;
  Invalidate;
end;

procedure TComboBox.CloseUp;
begin
  if FPopup <> nil then
    FPopup.Dismiss;
end;

procedure TComboBox.Choose(Index: LongInt);
begin
  CloseUp;
  ItemIndex := Index;
end;

procedure TComboBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Button: TRectangle;
  Field: TRectangle;
  Arrow: array[0..2] of TPoint;
  CentreX: LongInt;
  CentreY: LongInt;
  Size: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawBevel(Canvas, Box, SunkenThemeBevel);
  Button := MakeRectangle(Box.Right - 2 - Scaled(Theme.ScrollBarWidth), 2, Scaled(Theme.ScrollBarWidth),
    RectangleHeight(Box) - 4);
  DrawButtonFace(Canvas, Button, DroppedDown, False);
  CentreX := Button.Left + RectangleWidth(Button) div 2;
  CentreY := Button.Top + RectangleHeight(Button) div 2;
  Size := RectangleWidth(Button) div 4;
  Arrow[0] := MakePoint(CentreX - Size, CentreY - Size div 2);
  Arrow[1] := MakePoint(CentreX + Size, CentreY - Size div 2);
  Arrow[2] := MakePoint(CentreX, CentreY + Size div 2 + 1);
  FillPolygon(Canvas, Arrow, Theme.FaceText);
  Field := MakeRectangle(3, 3, Button.Left - 4, RectangleHeight(Box) - 6);
  if Focused and not DroppedDown then
  begin
    FillRectangle(Canvas, Field, Theme.Selection);
    DrawTextInBox(Canvas, ControlFace, Text, InflateRectangle(Field, -Scaled(2)), AlignTextLeft, Theme.SelectionText);
    DrawFocusFrame(Canvas, Field, Theme.SelectionText);
  end
  else
    DrawTextInBox(Canvas, ControlFace, Text, InflateRectangle(Field, -Scaled(2)), AlignTextLeft, Theme.FieldText);
end;

const
  { Logical units: room around the text in the field, above and below. }
  ComboFieldRoom = 12;
  ComboRoomDown = 8;
  MinimumComboHeight = 22;

{ The widest item, the drop button beside it; a line high. }
function TComboBox.PreferredSize: TSize;
var
  Index: LongInt;
  Widest: LongInt;
  Height: LongInt;
begin
  Widest := TextWidth(ControlFace, Text);
  for Index := 0 to FItems.Count - 1 do
    if TextWidth(ControlFace, FItems[Index]) > Widest then
      Widest := TextWidth(ControlFace, FItems[Index]);
  Height := PixelsToLogicalCeiling(TextHeight(ControlFace)) + ComboRoomDown;
  if Height < MinimumComboHeight then
    Height := MinimumComboHeight;
  Result := MakeSize(PixelsToLogicalCeiling(Widest) + Theme.ScrollBarWidth + ComboFieldRoom, Height);
end;

procedure TComboBox.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  if DroppedDown then
    CloseUp
  else
    DropDown;
end;

function TComboBox.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  if (Code = KeyArrowDown) and ((Modifiers and ModifierAlt) <> 0) then
    DropDown
  else if Code = KeyArrowUp then
    ItemIndex := FItemIndex - 1
  else if Code = KeyArrowDown then
    ItemIndex := FItemIndex + 1
  else
    Result := False;
end;

end.
