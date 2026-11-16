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

  While a user is logged in (or the login window shows) it watches the
  settings it handed over (Configuration.Watcher, in the message loop):
  when the user changes them - their own programs, the settings tool -
  or the system's change under them, the display server is given them
  again at once ("user changed the mouse settings: speed 12, ...").
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
  Configuration.Changes,
  Configuration.Watcher,
  Windowing.SettingsChanges,
  Windowing.MouseSettings,
  Windowing.KeyboardSettings,
  Sys.Keyboard,
  Session.Report;

const
  OnOff: array[Boolean] of string = ('off', 'on');
  MouseGroup = 'Mouse';
  KeyboardGroup = 'Keyboard';

type
  { Applies the watched settings again when they change. }
  TSettingsFollower = class
  public
    Whose: string;
    procedure GroupChanged(const Group: string; const Changes: TSettingChanges);
  end;

var
  Follower: TSettingsFollower;
  Watching: TLoopSettingsWatcher;

procedure ApplyMouseSettings(Store: TSettings; const Whose: string; Changed: Boolean); forward;
procedure ApplyKeyboardSettings(Store: TSettings; const Whose: string; Changed: Boolean); forward;

procedure TSettingsFollower.GroupChanged(const Group: string; const Changes: TSettingChanges);
begin
  if Group = MouseGroup then
    ApplyMouseSettings(Watching.Watcher.Settings, Whose, True)
  else if Group = KeyboardGroup then
    ApplyKeyboardSettings(Watching.Watcher.Settings, Whose, True);
end;

{ "mouse settings of NAME", or "NAME changed the mouse settings" when
  they changed while in use. }
function SettingsOf(const What, Whose: string; Changed: Boolean): string;
begin
  if Changed then
    Result := Whose + ' changed the ' + What + ' settings'
  else
    Result := What + ' settings of ' + Whose;
end;

{ Watches the settings Watcher reads from now on (instead of any it
  watched before). }
procedure FollowSettings(Watcher: TSettingsWatcher; const Whose: string);
begin
  Watching.Free;
  if Follower = nil then
    Follower := TSettingsFollower.Create;
  Follower.Whose := Whose;
  Watcher.OnChanged := @Follower.GroupChanged;
  Watcher.Watch(MouseGroup);
  Watcher.Watch(KeyboardGroup);
  Watching := TLoopSettingsWatcher.Create(Watcher, True);
end;

procedure ApplyMouseSettings(Store: TSettings; const Whose: string; Changed: Boolean);
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
  Say(Format('%s: speed %d, acceleration %d, left-handed %s',
    [SettingsOf('mouse', Whose, Changed), Applied.Speed, Applied.Acceleration, OnOff[Applied.LeftHanded]]));
end;

procedure ApplyKeyboardSettings(Store: TSettings; const Whose: string; Changed: Boolean);
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
  Say(Format('%s: layout %s, repeat delay %d, rate %d',
    [SettingsOf('keyboard', Whose, Changed), Applied.Layout, Applied.RepeatDelay, Applied.RepeatRate]));
end;

procedure ApplyUserSettings(const Name, Home: string);
var
  Store: TSettings;
begin
  Store := OpenSettingsOfHome(Home);
  ApplyMouseSettings(Store, Name, False);
  ApplyKeyboardSettings(Store, Name, False);
  Store.Free;
  FollowSettings(OpenSettingsWatcherOfHome(Home), Name);
end;

procedure ApplySystemSettings;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  ApplyMouseSettings(Store, 'the system', False);
  ApplyKeyboardSettings(Store, 'the system', False);
  Store.Free;
  FollowSettings(OpenSystemSettingsWatcher, 'the system');
end;

finalization
  Watching.Free;
  Follower.Free;

end.
