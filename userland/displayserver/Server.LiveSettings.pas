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
  The system's settings the server keeps to, followed while it runs
  (Configuration.Watcher): when they change - the settings tool, an
  administrator, another program - the server applies them at once.

    Display/N/Mode, Display/N/Scale   display N is given them again
                                      (Server.RememberedSettings); what
                                      it has already is left alone, so
                                      the server's own remembering
                                      changes nothing
    Mouse/..., Keyboard/...           each value the server still has
                                      from the system's settings takes
                                      the new one; a value someone set
                                      since (the session manager giving
                                      a user's own) is theirs and stays

  The watcher's handles join the main loop's wait when there is room
  (AddSettingsHandles), and the wait ends in time for a burst of
  changes to be delivered (SettingsWaitTime, DeliverSettingsChanges).
}
unit Server.LiveSettings;

{$mode objfpc}
{$H+}

interface

{ Starts following the system's settings (after they were applied). }
procedure StartFollowingSettings;
procedure StopFollowingSettings;

{ Puts the watcher's handles after Handles[Count - 1] while there is
  room for them, moving Count on. }
procedure AddSettingsHandles(var Handles: array of Int64; var Count: LongInt);
{ Handle (one AddSettingsHandles gave) was ready. }
procedure SettingsHandleReady(Handle: Int64);
{ How long the loop may wait (milliseconds, or InfiniteWait). }
function SettingsWaitTime: Int64;
{ Applies what changed, once a burst of changes is over. }
procedure DeliverSettingsChanges;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Keyboard,
  Sys.Streams,
  Configuration.Changes,
  Configuration.Watcher,
  Windowing.MouseSettings,
  Windowing.KeyboardSettings,
  Server.Screen,
  Server.MouseSettings,
  Server.KeyboardSettings,
  Server.RememberedSettings;

const
  DisplayGroup = 'Display';
  MouseGroup = 'Mouse';
  KeyboardGroup = 'Keyboard';
  OnOff: array[Boolean] of string = ('off', 'on');

type
  TSettingsFollower = class
  public
    procedure GroupChanged(const Group: string; const Changes: TSettingChanges);
  end;

var
  Watcher: TSettingsWatcher;
  Follower: TSettingsFollower;
  { The system's mouse and keyboard settings as last read. }
  SystemMouse: TMouseSettings;
  SystemKeyboard: TKeyboardSettings;

procedure Say(const Text: string);
begin
  WriteString(StandardOutput, 'displayserver: ' + Text + #10);
  FlushStream(StandardOutput);
end;

procedure FollowDisplays(const Changes: TSettingChanges);
var
  Index: LongInt;
begin
  for Index := 0 to ScreenCount - 1 do
    if ChangesInclude(Changes, DisplayGroup + '/' + IntToStr(Screens[Index].Number)) then
      ApplyScreenSettings(Watcher.Settings, @Screens[Index]);
end;

procedure FollowMouse;
var
  Latest: TMouseSettings;
  Speed: LongWord;
  Acceleration: LongWord;
  LeftHanded: Boolean;
begin
  Latest := RememberedMouseSettings(Watcher.Settings);
  Speed := MouseSpeed;
  Acceleration := MouseAcceleration;
  LeftHanded := LeftHandedButtons;
  if Speed = SystemMouse.Speed then
    Speed := Latest.Speed;
  if Acceleration = SystemMouse.Acceleration then
    Acceleration := Latest.Acceleration;
  if LeftHanded = SystemMouse.LeftHanded then
    LeftHanded := Latest.LeftHanded;
  SystemMouse := Latest;
  if (Speed = MouseSpeed) and (Acceleration = MouseAcceleration) and (LeftHanded = LeftHandedButtons) then
    Exit;
  Server.MouseSettings.ChangeMouseSettings(Speed, Acceleration, LeftHanded);
  Say(Format('the system''s mouse settings changed: speed %d, acceleration %d, left-handed %s',
    [MouseSpeed, MouseAcceleration, OnOff[LeftHandedButtons]]));
end;

procedure FollowKeyboard;
var
  Latest: TKeyboardSettings;
  Present: TKeyboardSettings;
  Wanted: TKeyboardSettings;
begin
  Latest := RememberedKeyboardSettings(Watcher.Settings);
  Present := CurrentKeyboardSettings;
  Wanted := Present;
  if Present.Layout = SystemKeyboard.Layout then
    Wanted.Layout := Latest.Layout;
  if Present.RepeatDelay = SystemKeyboard.RepeatDelay then
    Wanted.RepeatDelay := Latest.RepeatDelay;
  if Present.RepeatRate = SystemKeyboard.RepeatRate then
    Wanted.RepeatRate := Latest.RepeatRate;
  SystemKeyboard := Latest;
  if (Wanted.Layout = Present.Layout) and (Wanted.RepeatDelay = Present.RepeatDelay) and
     (Wanted.RepeatRate = Present.RepeatRate) then
    Exit;
  Server.KeyboardSettings.ChangeKeyboardSettings(Wanted);
  Present := CurrentKeyboardSettings;
  Say(Format('the system''s keyboard settings changed: layout %s, repeat delay %d, rate %d',
    [Present.Layout, Present.RepeatDelay, Present.RepeatRate]));
end;

procedure TSettingsFollower.GroupChanged(const Group: string; const Changes: TSettingChanges);
begin
  if Group = DisplayGroup then
    FollowDisplays(Changes)
  else if Group = MouseGroup then
    FollowMouse
  else if Group = KeyboardGroup then
    FollowKeyboard;
end;

procedure StartFollowingSettings;
begin
  if Watcher <> nil then
    Exit;
  Watcher := OpenSystemSettingsWatcher;
  Follower := TSettingsFollower.Create;
  Watcher.OnChanged := @Follower.GroupChanged;
  Watcher.Watch(DisplayGroup);
  Watcher.Watch(MouseGroup);
  Watcher.Watch(KeyboardGroup);
  SystemMouse := RememberedMouseSettings(Watcher.Settings);
  SystemKeyboard := RememberedKeyboardSettings(Watcher.Settings);
end;

procedure StopFollowingSettings;
begin
  FreeAndNil(Watcher);
  FreeAndNil(Follower);
end;

procedure AddSettingsHandles(var Handles: array of Int64; var Count: LongInt);
var
  Wanted: TWatcherHandles;
  Index: Integer;
begin
  if Watcher = nil then
    Exit;
  Wanted := Watcher.Handles(False);
  for Index := 0 to High(Wanted) do
    if Count < Length(Handles) then
    begin
      Handles[Count] := Wanted[Index];
      Inc(Count);
    end;
end;

procedure SettingsHandleReady(Handle: Int64);
begin
  if Watcher <> nil then
    Watcher.HandleReady(Handle);
end;

function SettingsWaitTime: Int64;
begin
  if Watcher = nil then
    Exit(InfiniteWait);
  Result := Watcher.WaitTime;
end;

procedure DeliverSettingsChanges;
begin
  if Watcher <> nil then
    Watcher.DeliverChanges;
end;

end.
