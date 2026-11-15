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
  Edit commands: cut, copy, paste and select all, shared by the controls
  that edit text, so they answer the same keys and show the same menu.

  The keys are the usual pairs: Ctrl+X or Shift+Delete cuts, Ctrl+C or
  Ctrl+Insert copies, Ctrl+V or Shift+Insert pastes, Ctrl+A selects
  everything. A right click shows the same commands in a context menu;
  those that cannot be done now (nothing selected, nothing to paste, a
  read-only box) are greyed.
}
unit Controls.EditCommands;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base;

type
  TEditCommand = (EditCommandCut, EditCommandCopy, EditCommandPaste, EditCommandSelectAll);
  TEditCommands = set of TEditCommand;
  TEditCommandEvent = procedure(Command: TEditCommand) of object;

{ The command a key with Modifiers stands for; False if none. }
function EditCommandOfKey(Code, Modifiers: LongWord; out Command: TEditCommand): Boolean;
{ The commands that can be done in a control with a selection or not,
  read-only or not, given what the clipboard holds. }
function AvailableEditCommands(HasSelection, ReadOnly: Boolean): TEditCommands;
{ The context menu at (X, Y) of Control (its own pixels); the command
  chosen goes to Handler. Only those in Enabled can be chosen. }
procedure ShowEditMenu(Control: TControl; X, Y: LongInt; Enabled: TEditCommands; Handler: TEditCommandEvent);

implementation

uses
  Abi.SystemCalls,
  Windowing.Connection,
  Controls.Keys,
  Controls.Window,
  Controls.Menus,
  Controls.Clipboard;

type
  { Hands the chosen menu item to the control that opened the menu. }
  TEditMenuChooser = class
  public
    Handler: TEditCommandEvent;
    procedure ItemChosen(Item: TMenuItem);
  end;

var
  { One menu serves every edit control: only one menu is open at once. }
  EditMenu: TMenuItem;
  Chooser: TEditMenuChooser;

function EditCommandOfKey(Code, Modifiers: LongWord; out Command: TEditCommand): Boolean;
var
  Held: LongWord;
begin
  Result := True;
  Held := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  if Held = ModifierControl then
    case Code of
      KeyX: Command := EditCommandCut;
      KeyC, KeyInsert: Command := EditCommandCopy;
      KeyV: Command := EditCommandPaste;
      KeyA: Command := EditCommandSelectAll;
    else
      Result := False;
    end
  else if Held = ModifierShift then
    case Code of
      KeyDelete: Command := EditCommandCut;
      KeyInsert: Command := EditCommandPaste;
    else
      Result := False;
    end
  else
    Result := False;
end;

function AvailableEditCommands(HasSelection, ReadOnly: Boolean): TEditCommands;
begin
  Result := [EditCommandSelectAll];
  if HasSelection then
    Include(Result, EditCommandCopy);
  if HasSelection and not ReadOnly then
    Include(Result, EditCommandCut);
  if ClipboardHasText and not ReadOnly then
    Include(Result, EditCommandPaste);
end;

procedure TEditMenuChooser.ItemChosen(Item: TMenuItem);
begin
  if Assigned(Handler) then
    Handler(TEditCommand(Item.Tag));
end;

procedure AddCommandItem(Command: TEditCommand; const Text, ShortcutText: string);
var
  Item: TMenuItem;
begin
  Item := EditMenu.Add(Text, nil, ShortcutText);
  Item.Tag := Ord(Command);
end;

procedure BuildEditMenu;
begin
  EditMenu := TMenuItem.Create('');
  AddCommandItem(EditCommandCut, 'Cut', 'Ctrl+X');
  AddCommandItem(EditCommandCopy, 'Copy', 'Ctrl+C');
  AddCommandItem(EditCommandPaste, 'Paste', 'Ctrl+V');
  EditMenu.AddSeparator;
  AddCommandItem(EditCommandSelectAll, 'Select All', 'Ctrl+A');
  Chooser := TEditMenuChooser.Create;
end;

procedure ShowEditMenu(Control: TControl; X, Y: LongInt; Enabled: TEditCommands; Handler: TEditCommandEvent);
var
  Window: TControlWindow;
  Index: LongInt;
  Item: TMenuItem;
begin
  if (Control.Host = nil) or not (Control.Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Control.Host.OwnerWindow);
  if EditMenu = nil then
    BuildEditMenu;
  for Index := 0 to EditMenu.Count - 1 do
  begin
    Item := EditMenu[Index];
    if not Item.IsSeparator then
      Item.Enabled := TEditCommand(Item.Tag) in Enabled;
  end;
  Chooser.Handler := Handler;
  ShowPopupMenu(Window, EditMenu, Window.ScreenLeft + Unscaled(Control.PixelBounds.Left + X),
    Window.ScreenTop + Unscaled(Control.PixelBounds.Top + Y), @Chooser.ItemChosen);
end;

finalization
  EditMenu.Free;
  Chooser.Free;
end.
