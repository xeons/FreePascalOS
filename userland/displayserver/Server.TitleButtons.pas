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
  How the title buttons look: hot while the pointer is over one, pressed
  while the button that was pressed on it is held and the pointer is
  over it (moving off it lets it up: letting go there does nothing).

  One button at most is hot or pressed. Server.Input says which as the
  pointer moves; Server.Frames draws it so; a change damages the buttons
  concerned.
}
unit Server.TitleButtons;

{$mode objfpc}

interface

uses
  Server.Windows,
  Server.Frames;

{ The button under the pointer (Window nil or Button not a title button:
  none), drawn pressed if Pressed. }
procedure TrackTitleButton(Window: PServerWindow; Button: THitArea; Pressed: Boolean);
{ How Window's Button looks now. }
function TitleButtonIsHot(Window: PServerWindow; Button: THitArea): Boolean;
function TitleButtonIsPressed(Window: PServerWindow; Button: THitArea): Boolean;
{ The window is going: no button of it is hot. }
procedure ForgetWindowInTitleButtons(Window: PServerWindow);

implementation

uses
  Server.Composer;

var
  HotWindow: PServerWindow;
  HotButton: THitArea;
  HotPressed: Boolean;

function IsTitleButton(Button: THitArea): Boolean;
begin
  Result := Button in [HitClose, HitMaximize, HitMinimize];
end;

procedure DamageHotButton;
begin
  if (HotWindow <> nil) and HotWindow^.Visible then
    AddDamage(TitleButtonRectangle(HotWindow, HotButton));
end;

procedure TrackTitleButton(Window: PServerWindow; Button: THitArea; Pressed: Boolean);
begin
  if (Window = nil) or not IsTitleButton(Button) then
  begin
    Window := nil;
    Button := HitNothing;
    Pressed := False;
  end;
  if (Window = HotWindow) and (Button = HotButton) and (Pressed = HotPressed) then
    Exit;
  DamageHotButton;
  HotWindow := Window;
  HotButton := Button;
  HotPressed := Pressed;
  DamageHotButton;
end;

function TitleButtonIsHot(Window: PServerWindow; Button: THitArea): Boolean;
begin
  Result := (Window = HotWindow) and (Button = HotButton) and not HotPressed;
end;

function TitleButtonIsPressed(Window: PServerWindow; Button: THitArea): Boolean;
begin
  Result := (Window = HotWindow) and (Button = HotButton) and HotPressed;
end;

procedure ForgetWindowInTitleButtons(Window: PServerWindow);
begin
  if HotWindow = Window then
  begin
    HotWindow := nil;
    HotButton := HitNothing;
    HotPressed := False;
  end;
end;

end.
