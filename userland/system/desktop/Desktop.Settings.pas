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
  The desktop's settings (the user's over the system's, group Desktop):

    Wallpaper = "/home/user/sky.bmp"   the image behind the icons (-w)
    ClockFormat = "24-hour"            the taskbar clock: "24-hour"
                                       (14:05) or "12-hour" (2:05 PM)

  Both are taken at once when they change while the desktop runs (the
  taskbar and the desktop windows subscribe to them), as is a new time
  zone (group Time, the system's).
}
unit Desktop.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Desktop.Clock;

const
  DesktopSettingsGroup = 'Desktop';
  TimeSettingsGroup = 'Time';
  WallpaperSetting = 'Desktop/Wallpaper';
  ClockFormatSetting = 'Desktop/ClockFormat';

function RememberedWallpaper: string;
procedure RememberWallpaper(const Path: string);
function RememberedClockFormat: TClockFormat;

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  TwelveHourName = '12-hour';

function RememberedWallpaper: string;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Result := Store.ReadString(WallpaperSetting, '');
  Store.Free;
end;

procedure RememberWallpaper(const Path: string);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteString(WallpaperSetting, Path);
  { Freeing the settings flushes them. }
  Store.Free;
end;

function RememberedClockFormat: TClockFormat;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  if Store.ReadString(ClockFormatSetting, '') = TwelveHourName then
    Result := ClockTwelveHours
  else
    Result := ClockTwentyFourHours;
  Store.Free;
end;

end.
