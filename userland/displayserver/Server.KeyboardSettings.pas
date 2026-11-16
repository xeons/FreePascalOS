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
  The keyboards' layout and key repeat, for whoever sits at the screen.

  Keys become characters in the kernel, which keeps the layout and the
  repeat for every keyboard and lets only root change them (Sys.Keyboard).
  The server runs as root and changes them for any program
  (RequestSetKeyboardSettings), as it does the mouse's settings: the
  session manager gives it each user's when they log in and the system's
  when they log off (Windowing.KeyboardSettings), and the server starts
  with the system's (Server.RememberedSettings). The characters in the
  key events the server passes on are typed with the new layout from
  the next key on.
}
unit Server.KeyboardSettings;

{$mode objfpc}

interface

uses
  Sys.Keyboard;

{ Gives the kernel new settings. A layout the kernel does not have
  leaves the layout as it is (the repeat is still taken). }
procedure ChangeKeyboardSettings(const Settings: TKeyboardSettings);
{ What the kernel has now. }
function CurrentKeyboardSettings: TKeyboardSettings;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text;

function CurrentKeyboardSettings: TKeyboardSettings;
begin
  GetKeyboardSettings(Result);
end;

procedure ChangeKeyboardSettings(const Settings: TKeyboardSettings);
var
  KeptLayout: TKeyboardSettings;
begin
  if SetKeyboardSettings(Settings) = ErrorNotFound then
  begin
    KeptLayout := CurrentKeyboardSettings;
    KeptLayout.RepeatDelay := Settings.RepeatDelay;
    KeptLayout.RepeatRate := Settings.RepeatRate;
    SetKeyboardSettings(KeptLayout);
  end;
end;

end.
