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
  Suggestion lists: completions dropped under a field while the user
  types in it (an address bar's paths), in a pop-up like a combo box's
  list (Controls.Popups).

  The pop-up does not take the typing away from the field: while it is
  open the window's keys come to its list, which keeps Up, Down, Page Up
  and Page Down (moving through the suggestions, none chosen at first),
  Enter (OnAccept with the suggestion chosen, -1 for none: the text as
  typed), Tab (OnComplete, when one is chosen) and Escape (closing it),
  and passes every other key on to the field (KeyTarget) and its
  parents, as if it had the focus. A click on a suggestion accepts it;
  a press anywhere else closes the list. Show again with new items
  updates an open list in place (its height follows them).
}
unit Controls.SuggestionList;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.Popups,
  Controls.ListBox;

type
  TSuggestionEvent = procedure(Index: LongInt) of object;
  TSuggestionDropDown = class;

  TSuggestionListBox = class(TListBox)
  private
    FDropDown: TSuggestionDropDown;
  protected
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  end;

  TSuggestionDropDown = class
  private
    FAnchor: TControl;
    FKeyTarget: TControl;
    FPopup: TPopupWindow;
    FList: TSuggestionListBox;
    FOnAccept: TSuggestionEvent;
    FOnComplete: TSuggestionEvent;
    FOnClosed: TControlEvent;
    procedure PopupDismissed(Sender: TControl);
    procedure PassKeyOn(Code, Character, Modifiers: LongWord);
    function PopupHeight(Count: LongInt): LongInt;
  public
    { Dropped under Anchor, as wide as it; keys not its own go to
      KeyTarget. }
    constructor Create(AAnchor, AKeyTarget: TControl);
    destructor Destroy; override;
    { Opens the list with Items, or shows them in the open one; closes
      it for none. }
    procedure Show(Items: TStrings);
    procedure Close;
    function IsOpen: Boolean;
    { The suggestion chosen in the list (-1: none, or closed). }
    function ChosenIndex: LongInt;
    function ChosenText: string;
    property OnAccept: TSuggestionEvent read FOnAccept write FOnAccept;
    property OnComplete: TSuggestionEvent read FOnComplete write FOnComplete;
    { The list closed, however it went (Sender: the anchor). }
    property OnClosed: TControlEvent read FOnClosed write FOnClosed;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Displays,
  Controls.Keys,
  Controls.Text,
  Controls.Window;

const
  MaximumSuggestionRows = 10;

procedure TSuggestionListBox.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  inherited PointerUp(X, Y, Button);
  Index := ItemAt(Y);
  if (Button = ButtonLeft) and (Index >= 0) and Assigned(FDropDown.FOnAccept) then
    FDropDown.FOnAccept(Index);
end;

function TSuggestionListBox.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  if (Code = KeyArrowUp) and (ItemIndex <= 0) then
    ItemIndex := -1
  else if (Code = KeyArrowDown) or (Code = KeyArrowUp) or (Code = KeyPageUp) or (Code = KeyPageDown) then
    Result := inherited KeyDown(Code, Character, Modifiers)
  else if IsEnterKey(Code) then
  begin
    if Assigned(FDropDown.FOnAccept) then
      FDropDown.FOnAccept(ItemIndex);
  end
  else if (Code = KeyTab) and (ItemIndex >= 0) and ((Modifiers and (ModifierShift or ModifierControl)) = 0) then
  begin
    if Assigned(FDropDown.FOnComplete) then
      FDropDown.FOnComplete(ItemIndex);
  end
  else if Code = KeyEscape then
    FDropDown.Close
  else
    FDropDown.PassKeyOn(Code, Character, Modifiers);
end;

constructor TSuggestionDropDown.Create(AAnchor, AKeyTarget: TControl);
begin
  inherited Create;
  FAnchor := AAnchor;
  FKeyTarget := AKeyTarget;
end;

destructor TSuggestionDropDown.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TSuggestionDropDown.PassKeyOn(Code, Character, Modifiers: LongWord);
var
  Control: TControl;
begin
  Control := FKeyTarget;
  while Control <> nil do
  begin
    if Control.HandleKeyDown(Code, Character, Modifiers) then
      Exit;
    Control := Control.Parent;
  end;
end;

function TSuggestionDropDown.IsOpen: Boolean;
begin
  Result := FPopup <> nil;
end;

function TSuggestionDropDown.ChosenIndex: LongInt;
begin
  Result := -1;
  if FList <> nil then
    Result := FList.ItemIndex;
end;

function TSuggestionDropDown.ChosenText: string;
begin
  Result := '';
  if (FList <> nil) and (FList.ItemIndex >= 0) and (FList.ItemIndex < FList.Items.Count) then
    Result := FList.Items[FList.ItemIndex];
end;

{ Logical units for Count rows (and the list's frame). }
function TSuggestionDropDown.PopupHeight(Count: LongInt): LongInt;
var
  RowHeight: LongInt;
begin
  if Count > MaximumSuggestionRows then
    Count := MaximumSuggestionRows;
  RowHeight := TextHeight(ControlFace) + Scaled(2);
  Result := Unscaled(Count * RowHeight + 4) + 1;
end;

procedure TSuggestionDropDown.Show(Items: TStrings);
var
  Window: TControlWindow;
  Left: LongInt;
  Top: LongInt;
  Width: LongInt;
  Height: LongInt;
begin
  if (Items = nil) or (Items.Count = 0) then
  begin
    Close;
    Exit;
  end;
  if (FAnchor.Host = nil) or not (FAnchor.Host.OwnerWindow is TControlWindow) then
    Exit;
  Height := PopupHeight(Items.Count);
  Width := Unscaled(RectangleWidth(FAnchor.PixelBounds));
  if FPopup <> nil then
  begin
    FList.Items.Assign(Items);
    FList.ItemIndex := -1;
    FPopup.SetClientSize(Width, Height);
    Exit;
  end;
  Window := TControlWindow(FAnchor.Host.OwnerWindow);
  Left := Window.ScreenLeft + Unscaled(FAnchor.PixelBounds.Left);
  Top := Window.ScreenTop + Unscaled(FAnchor.PixelBounds.Bottom);
  KeepOnDisplay(Left, Top, Width, Height);
  FPopup := TPopupWindow.CreatePopup(Window, Left, Top, Width, Height);
  FPopup.OnDismiss := @PopupDismissed;
  FList := TSuggestionListBox.Create(FPopup.Root);
  FList.FDropDown := Self;
  FList.Align := AlignClient;
  FList.Items.Assign(Items);
  FList.ItemIndex := -1;
  FList.SetFocus;
  FPopup.Popup;
end;

procedure TSuggestionDropDown.PopupDismissed(Sender: TControl);
begin
  FPopup := nil;
  FList := nil;
  if Assigned(FOnClosed) then
    FOnClosed(FAnchor);
end;

procedure TSuggestionDropDown.Close;
begin
  if FPopup <> nil then
    FPopup.Dismiss;
end;

end.
