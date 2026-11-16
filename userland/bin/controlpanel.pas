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
  controlpanel - the system's settings, in a window

  controlpanel [PAGE]

  A list of pages on the left and the page chosen on the right, with OK,
  Cancel and Apply:

    display    each display's resolution and scale (kept only when
               "Keep these settings?" is answered in time)
    mouse      the pointer's speed and acceleration, left-handed buttons
    keyboard   the layout, the key repeat's delay and rate
    sound      each output's volume and mute, the default output
    datetime   the time zone, the date and time ("date" works too)
    users      adding and removing users, passwords, full names, groups

  PAGE opens that page first. The display, mouse and keyboard settings
  go to the display server; the mouse's and keyboard's are kept in the
  user's settings, the display's in the system's. The time zone, the
  clock, the volumes and the accounts are changed by the system settings
  service, which asks for an administrator's password where it must
  (ControlPanel.Administrator). Units in userland/controlpanel.

  Prints what happens, a line each:

    page NAME              a page is shown
    place NAME X Y         where a control is on the screen (pixels)
    applied WHAT           a page's changes were made (display, mouse,
                           keyboard, volume, default output, time-zone,
                           clock)
    keep-asked SECONDS     "Keep these settings?" appeared
    keep-countdown N       ...and N seconds are left
    kept / reverted        the display's settings were kept, or went back
    password-asked TITLE   a password is asked for
    dialog TITLE           a user dialog appeared
    user-added NAME, user-removed NAME, password-changed NAME,
    user-changed NAME      an account was changed
    refused CODE ERROR     the system settings service refused a request
    scale P                the window's scale is now P percent
    closed / cancelled     the window was closed (OK or its close
                           button), or Cancel was pressed
}
program ControlPanel;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Windowing.Windows,
  ControlPanel.Report,
  ControlPanel.MainWindow;

var
  Window: TControlPanelWindow;
begin
  Window := TControlPanelWindow.Create;
  Window.Show;
  if ParamCount >= 1 then
  begin
    if not Window.ShowPageNamed(LowerCase(ParamStr(1))) then
    begin
      Say('unknown page ' + ParamStr(1));
      Window.ShowPage(0);
    end;
  end
  else
    Window.ShowPage(0);
  RunMessageLoop;
end.
