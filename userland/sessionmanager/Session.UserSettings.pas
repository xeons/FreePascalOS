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
  The user's settings that belong to the display server rather than to a
  program: the mouse's (Windowing.MouseSettings) and the keyboards'
  layout and repeat (Windowing.KeyboardSettings). The display server
  serves whoever sits at the screen, so the session manager, which knows
  who that is, hands it the user's settings when they log in (their own
  over the system's) and the system's when the session ends, so the
  login window and the next user start from those.

  The session manager runs as root and reads the user's settings in
  their home (Configuration.Locations.OpenSettingsOfHome); it never
  writes them.
}
unit Session.UserSettings;

{$mode objfpc}
{$H+}

interface

{ Gives the display server the settings of the user whose home is Home
  (Name for the log). }
procedure ApplyUserSettings(const Name, Home: string);
{ Gives the display server the system's settings. }
procedure ApplySystemSettings;

implementation

uses
  SysUtils,
  Configuration.Settings,
  Configuration.Locations,
  Windowing.MouseSettings,
  Windowing.KeyboardSettings,
  Sys.Keyboard,
  Session.Report;

const
  OnOff: array[Boolean] of string = ('off', 'on');

procedure ApplyMouseSettings(Store: TSettings; const Whose: string);
var
  Wanted: TMouseSettings;
  Applied: TMouseSettings;
begin
  Wanted := RememberedMouseSettings(Store);
  if not ChangeMouseSettings(Wanted, Applied) then
  begin
    Say('the display server did not take the mouse settings of ' + Whose);
    Exit;
  end;
  Say(Format('mouse settings of %s: speed %d, acceleration %d, left-handed %s',
    [Whose, Applied.Speed, Applied.Acceleration, OnOff[Applied.LeftHanded]]));
end;

procedure ApplyKeyboardSettings(Store: TSettings; const Whose: string);
var
  Wanted: TKeyboardSettings;
  Applied: TKeyboardSettings;
begin
  Wanted := RememberedKeyboardSettings(Store);
  if not ChangeKeyboardSettings(Wanted, Applied) then
  begin
    Say('the display server did not take the keyboard settings of ' + Whose);
    Exit;
  end;
  Say(Format('keyboard settings of %s: layout %s, repeat delay %d, rate %d',
    [Whose, PChar(@Applied.Layout[0]), Applied.RepeatDelay, Applied.RepeatRate]));
end;

procedure ApplyUserSettings(const Name, Home: string);
var
  Store: TSettings;
begin
  Store := OpenSettingsOfHome(Home);
  ApplyMouseSettings(Store, Name);
  ApplyKeyboardSettings(Store, Name);
  Store.Free;
end;

procedure ApplySystemSettings;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  ApplyMouseSettings(Store, 'the system');
  ApplyKeyboardSettings(Store, 'the system');
  Store.Free;
end;

end.
