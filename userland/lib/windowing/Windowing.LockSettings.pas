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
  When the screen locks by itself: a user's settings (the group
  ScreenLock), over the system's, over the defaults.

  AfterMinutes: the screen locks after this many minutes without input
  (0, the default: never). OnResume: it is locked before the computer
  suspends, so it is locked when it wakes (the default: yes). The
  session manager reads them (as root, in the user's home); the Control
  Panel writes them.
}
unit Windowing.LockSettings;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Settings;

const
  LockAfterMinutesSetting = 'ScreenLock/AfterMinutes';
  LockOnResumeSetting = 'ScreenLock/OnResume';
  { The longest wait that can be chosen: a day. }
  MaximumLockAfterMinutes = 24 * 60;

type
  TLockSettings = record
    { 0: never. }
    AfterMinutes: LongWord;
    OnResume: Boolean;
  end;

{ The defaults: never by itself, but on resume. }
function DefaultLockSettings: TLockSettings;
{ The settings Store holds (one missing or out of range: the default). }
function RememberedLockSettings(Store: TSettings): TLockSettings;
{ Keeps Settings in one of Store's scopes (flushed by the caller). }
procedure RememberLockSettings(Store: TSettings; const Settings: TLockSettings;
  Scope: TSettingsScopeKind = ScopeUser);

implementation

function DefaultLockSettings: TLockSettings;
begin
  Result.AfterMinutes := 0;
  Result.OnResume := True;
end;

function RememberedLockSettings(Store: TSettings): TLockSettings;
var
  Minutes: Int64;
begin
  Result := DefaultLockSettings;
  Minutes := Store.ReadInteger(LockAfterMinutesSetting, 0);
  if (Minutes >= 0) and (Minutes <= MaximumLockAfterMinutes) then
    Result.AfterMinutes := Minutes;
  Result.OnResume := Store.ReadBoolean(LockOnResumeSetting, True);
end;

procedure RememberLockSettings(Store: TSettings; const Settings: TLockSettings; Scope: TSettingsScopeKind);
begin
  Store.WriteInteger(LockAfterMinutesSetting, Settings.AfterMinutes, Scope);
  Store.WriteBoolean(LockOnResumeSetting, Settings.OnResume, Scope);
end;

end.
