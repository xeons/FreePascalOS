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
  Which theme is in use: the system's setting Appearance/Theme (a
  theme's key, Windowing.Theme), the same for every user and for the
  display server, so frames and controls always match. Missing or
  naming no theme: the default (Sunrise).

  It is the machine's look, so anyone may change it: the Control Panel
  asks the system settings service (SystemRequestSetTheme), root may
  also write it with "settings set -s Appearance/Theme classic". The
  display server follows it (Server.LiveSettings) and so does every
  window program: Windowing.Connection applies it when the program
  connects, Windowing.Windows follows it and tells every window
  (ThemeChanged), which repaints.
}
unit Windowing.ThemeSettings;

{$mode objfpc}
{$H+}

interface

const
  AppearanceGroup = 'Appearance';
  ThemeSetting = 'Appearance/Theme';
  { The key of ThemeSetting within its group (what a change names). }
  ThemeSettingKey = 'Theme';

{ The theme's key the system's settings name ('' when none). }
function SystemThemeKey: string;
{ Puts the theme the system's settings name in Theme; True if that
  changed which theme Theme is. }
function ApplySystemTheme: Boolean;

implementation

uses
  Configuration.Settings,
  Configuration.Locations,
  Windowing.Theme;

function SystemThemeKey: string;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  try
    Result := Store.ReadString(ThemeSetting, '');
  finally
    Store.Free;
  end;
end;

function ApplySystemTheme: Boolean;
var
  Before: string;
begin
  Before := Theme.Key;
  LoadThemeByKey(SystemThemeKey);
  Result := Theme.Key <> Before;
end;

end.
