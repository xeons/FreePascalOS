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
  Changing a screen's mode (its resolution) while windows are open.

  The display device sets the mode (only modes from its list) and the
  screen gets a back buffer of the new size. The DPI follows the mode
  (the same physical width, other pixels), so the screen takes the
  display's own scale and DPI at the new mode, a scale chosen before
  being for the old one. Then everything is laid out again as for a new
  scale (Server.Scale): windows keep their places on the screen, are
  moved onto it if they would hang off it, a maximized one fills it
  again, and programs hear their windows' new scale (if it changed) and
  places. When the server gives the display back (it ends), the device
  sets the mode there was before.
}
unit Server.Modes;

{$mode objfpc}

interface

uses
  Server.Screen;

{ ErrorNone or an error code (the mode is not one the display has). }
function ChangeMode(Screen: PScreen; Width, Height: LongInt): LongInt;

implementation

uses
  Abi.SystemCalls,
  Server.Scale;

function ChangeMode(Screen: PScreen; Width, Height: LongInt): LongInt;
var
  Places: TWindowPlaces;
  Before: TScreenState;
begin
  if (Width = LongInt(Screen^.Device.Width)) and (Height = LongInt(Screen^.Device.Height)) then
    Exit(ErrorNone);
  RememberWindowPlaces(Places);
  Before := RememberScreenState(Screen);
  Result := SetScreenMode(Screen, Width, Height);
  if Result <> ErrorNone then
    Exit;
  Screen^.ScalePercent := Screen^.NativeScalePercent;
  Screen^.Dpi := Screen^.NativeDpi;
  FinishScreenChange(Screen, Before, Places, True);
end;

end.
