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
  Carrying out a request to the system settings service, once the
  caller has been found to be allowed it (SystemSettings.Authorization):
  the clock and the zone through the kernel, the sound through the
  outputs (Audio.Outputs), the accounts through Util.AccountChanges, the
  same routines useradd, userdel and usermod use, and the network's
  settings into the file the network service applies
  (SystemSettings.Network). What is to last is kept in the system's
  settings (SystemSettings.Remembered).
}
unit SystemSettings.Requests;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.SystemSettings;

{ Does what Request asks; ErrorNone or why not. }
function CarryOutRequest(const Peer: TAbiChannelPeer; const Request: TSystemSettingsRequest): LongInt;

implementation

uses
  SysUtils,
  Sys.LocalTime,
  Sys.TimeZones,
  Audio.Outputs,
  Util.Accounts,
  Util.AccountChanges,
  SystemSettings.Remembered,
  SystemSettings.Network,
  SystemSettings.Report;

function TextOf(const Field: array of Char): string;
begin
  Result := string(PChar(@Field[0]));
end;

function SetTimeZone(const Request: TSystemSettingsRequest): LongInt;
var
  Name: string;
begin
  Name := TextOf(Request.Text);
  Result := SetSystemTimeZone(PChar(Name));
  if Result = ErrorNone then
    Result := RememberTimeZone(Name);
  if Result = ErrorNone then
    Say('time zone set to ' + Name);
end;

function SetClock(const Request: TSystemSettingsRequest): LongInt;
begin
  Result := SetSystemClock(Request.Time);
  if Result = ErrorNone then
    Say(Format('clock set to %d', [Request.Time]));
end;

function SetVolume(const Request: TSystemSettingsRequest): LongInt;
var
  Muted: Boolean;
begin
  if Request.Volume > 100 then
    Exit(ErrorInvalidArgument);
  Muted := (Request.Flags and SystemFlagMuted) <> 0;
  Result := SetAudioOutputVolume(Integer(Request.Output), Request.Volume);
  if Result = ErrorNone then
    Result := SetAudioOutputMuted(Integer(Request.Output), Muted);
  if Result = ErrorNone then
    Result := RememberOutput(Integer(Request.Output), Request.Volume, Muted);
  if Result = ErrorNone then
    Say(Format('sound output %d volume %d%s kept', [Request.Output, Request.Volume,
      BoolToStr(Muted, ', muted', '')]));
end;

function SetDefaultOutput(const Request: TSystemSettingsRequest): LongInt;
begin
  Result := SetDefaultAudioOutput(Integer(Request.Output));
  if Result = ErrorNone then
    Result := RememberDefaultOutput(Integer(Request.Output));
  if Result = ErrorNone then
    Say(Format('default sound output %d kept', [Request.Output]));
end;

function AddAccount(const Request: TSystemSettingsRequest): LongInt;
var
  Name: string;
begin
  Name := TextOf(Request.UserName);
  Result := AddUser(Name, TextOf(Request.FullName), TextOf(Request.Password),
    (Request.Flags and SystemFlagAdministrator) <> 0);
  if Result = ErrorNone then
    Say('user ' + Name + ' added');
end;

function RemoveAccount(const Peer: TAbiChannelPeer; const Request: TSystemSettingsRequest): LongInt;
var
  Name: string;
  Caller: PChar;
begin
  Name := TextOf(Request.UserName);
  { The caller's own account stays while they are using it. }
  Caller := UserNameOf(Peer.UserId);
  if (Caller <> nil) and (string(Caller) = Name) then
    Exit(ErrorBusy);
  Result := RemoveUser(Name, (Request.Flags and SystemFlagRemoveHome) <> 0);
  if Result = ErrorNone then
    Say('user ' + Name + ' removed' + BoolToStr((Request.Flags and SystemFlagRemoveHome) <> 0, ' with their home', ''));
end;

function SetPassword(const Request: TSystemSettingsRequest): LongInt;
var
  Name: string;
begin
  Name := TextOf(Request.UserName);
  Result := ChangePassword(Name, TextOf(Request.Password));
  if Result = ErrorNone then
    Say('password of ' + Name + ' changed');
end;

function SetFullName(const Request: TSystemSettingsRequest): LongInt;
var
  Name: string;
begin
  Name := TextOf(Request.UserName);
  Result := ChangeFullName(Name, TextOf(Request.FullName));
  if Result = ErrorNone then
    Say('full name of ' + Name + ' changed');
end;

function SetGroups(const Request: TSystemSettingsRequest): LongInt;
var
  Name: string;
begin
  Name := TextOf(Request.UserName);
  Result := ChangeGroups(Name, SplitGroupList(TextOf(Request.Text)));
  if Result = ErrorNone then
    Say('groups of ' + Name + ': ' + TextOf(Request.Text));
end;

function CarryOutRequest(const Peer: TAbiChannelPeer; const Request: TSystemSettingsRequest): LongInt;
begin
  case Request.Code of
    SystemRequestCheckAdministrator: Result := ErrorNone;
    SystemRequestSetTimeZone: Result := SetTimeZone(Request);
    SystemRequestSetClock: Result := SetClock(Request);
    SystemRequestSetVolume: Result := SetVolume(Request);
    SystemRequestSetDefaultOutput: Result := SetDefaultOutput(Request);
    SystemRequestAddUser: Result := AddAccount(Request);
    SystemRequestRemoveUser: Result := RemoveAccount(Peer, Request);
    SystemRequestSetPassword: Result := SetPassword(Request);
    SystemRequestSetFullName: Result := SetFullName(Request);
    SystemRequestSetGroups: Result := SetGroups(Request);
    SystemRequestSetNetworkInterface: Result := SetNetworkInterface(Request);
    SystemRequestSetDnsServers: Result := SetDnsServers(Request);
  else
    Result := ErrorInvalidArgument;
  end;
end;

end.
