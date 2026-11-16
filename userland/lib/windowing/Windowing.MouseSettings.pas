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
  The mouse's settings: asking the display server for them, changing
  them there, and keeping them in the settings (libconfiguration).

  How the pointer moves is a matter of taste, so the mouse's settings
  are the user's: the group Mouse of their settings (Speed,
  Acceleration, LeftHanded), over the system's (what the login window
  has, and what users start from), over the server's defaults. The
  display server only applies them: the session manager gives it a
  user's settings when they log in and the system's when they log off,
  and a program that changes them for the user (mousesettings
  --remember, a control panel) keeps them in the user's settings.

  The calls that talk to the server wait for its answer (other events
  are kept, Windowing.Connection); the program must be connected.
}
unit Windowing.MouseSettings;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Settings;

const
  MouseSpeedSetting = 'Mouse/Speed';
  MouseAccelerationSetting = 'Mouse/Acceleration';
  MouseLeftHandedSetting = 'Mouse/LeftHanded';

type
  TMouseSettings = record
    { MinimumMouseSpeed to MaximumMouseSpeed (NormalMouseSpeed: as far
      as the mouse moves). }
    Speed: LongWord;
    { 0 to MaximumMouseAcceleration. }
    Acceleration: LongWord;
    LeftHanded: Boolean;
  end;

{ What the server has now; False if it did not answer. }
function AskMouseSettings(out Settings: TMouseSettings): Boolean;
{ Gives the server new settings; Applied is what it has then. }
function ChangeMouseSettings(const Settings: TMouseSettings; out Applied: TMouseSettings): Boolean;

{ The settings Store holds (each one that is missing, or out of its
  range, is the server's default). }
function RememberedMouseSettings(Store: TSettings): TMouseSettings;
{ Keeps Settings in one of Store's scopes (flushed by the caller). }
procedure RememberMouseSettings(Store: TSettings; const Settings: TMouseSettings;
  Scope: TSettingsScopeKind = ScopeUser);
{ The server's defaults. }
function DefaultMouseSettings: TMouseSettings;

implementation

uses
  Windowing.Protocol,
  Windowing.Connection;

const
  ReplyTimeout = 5000;

function SettingsFromEvent(const Event: TWindowMessage): TMouseSettings;
begin
  Result.Speed := Event.Code;
  Result.Acceleration := LongWord(Event.Value);
  Result.LeftHanded := (Event.Flags and MouseLeftHanded) <> 0;
end;

function AskMouseSettings(out Settings: TMouseSettings): Boolean;
var
  Request: TWindowMessage;
  Reply: TWindowMessage;
begin
  Settings := DefaultMouseSettings;
  Request := NewMessage(RequestGetMouseSettings, 0);
  SendRequest(Request, -1);
  Result := WaitForEvent(EventMouseSettings, ReplyTimeout, Reply);
  if Result then
    Settings := SettingsFromEvent(Reply);
end;

function ChangeMouseSettings(const Settings: TMouseSettings; out Applied: TMouseSettings): Boolean;
var
  Request: TWindowMessage;
  Reply: TWindowMessage;
begin
  Applied := Settings;
  Request := NewMessage(RequestSetMouseSettings, 0);
  Request.Code := Settings.Speed;
  Request.Value := LongInt(Settings.Acceleration);
  if Settings.LeftHanded then
    Request.Flags := MouseLeftHanded;
  SendRequest(Request, -1);
  Result := WaitForEvent(EventMouseSettings, ReplyTimeout, Reply);
  if Result then
    Applied := SettingsFromEvent(Reply);
end;

function DefaultMouseSettings: TMouseSettings;
begin
  Result.Speed := NormalMouseSpeed;
  Result.Acceleration := 0;
  Result.LeftHanded := False;
end;

function RememberedMouseSettings(Store: TSettings): TMouseSettings;
var
  Speed: Int64;
  Acceleration: Int64;
begin
  Result := DefaultMouseSettings;
  Speed := Store.ReadInteger(MouseSpeedSetting, NormalMouseSpeed);
  if (Speed >= MinimumMouseSpeed) and (Speed <= MaximumMouseSpeed) then
    Result.Speed := Speed;
  Acceleration := Store.ReadInteger(MouseAccelerationSetting, 0);
  if (Acceleration >= 0) and (Acceleration <= MaximumMouseAcceleration) then
    Result.Acceleration := Acceleration;
  Result.LeftHanded := Store.ReadBoolean(MouseLeftHandedSetting, False);
end;

procedure RememberMouseSettings(Store: TSettings; const Settings: TMouseSettings; Scope: TSettingsScopeKind);
begin
  Store.WriteInteger(MouseSpeedSetting, Settings.Speed, Scope);
  Store.WriteInteger(MouseAccelerationSetting, Settings.Acceleration, Scope);
  Store.WriteBoolean(MouseLeftHandedSetting, Settings.LeftHanded, Scope);
end;

end.
