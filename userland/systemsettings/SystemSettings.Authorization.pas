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
  Who may ask the system settings service for what (the rules are
  Sys.SystemSettings'): the caller is who the kernel says connected
  (CallGetChannelPeer), and the request's Authorization is the password
  they offer. A wrong password costs a pause before the answer, so
  passwords cannot be tried quickly over the port.
}
unit SystemSettings.Authorization;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.SystemSettings;

{ ErrorNone if the caller may make Request; ErrorAccessDenied for a
  wrong (or missing) password. }
function AuthorizeRequest(const Peer: TAbiChannelPeer; const Request: TSystemSettingsRequest): LongInt;
{ True if Password proves the caller an administrator: root's password,
  or the caller's own when they are in "wheel". }
function IsAdministratorPassword(UserId: LongWord; Password: PChar): Boolean;

implementation

uses
  Sys.Kernel,
  Util.Accounts,
  Util.Passwords,
  SystemSettings.Report;

const
  WrongPasswordPauseMilliseconds = 1500;
  RootName = 'root';

function InAdministratorsGroup(UserId: LongWord): Boolean;
var
  Groups: array[0..MaximumSupplementaryGroups] of LongWord;
  Count: Integer;
  Index: Integer;
  Administrators: LongWord;
begin
  Result := False;
  if not FindGroupId(AdministratorsGroupName, Administrators) or (GroupNameOf(Administrators) = nil) then
    Exit;
  Count := GroupsOfUser(UserId, @Groups[0], Length(Groups));
  for Index := 0 to Count - 1 do
    if Groups[Index] = Administrators then
      Exit(True);
end;

function IsOwnPassword(UserId: LongWord; Password: PChar): Boolean;
var
  Name: PChar;
begin
  Name := UserNameOf(UserId);
  Result := (Name <> nil) and (CheckPassword(Name, Password) = PasswordAccepted);
end;

function IsAdministratorPassword(UserId: LongWord; Password: PChar): Boolean;
begin
  Result := (CheckPassword(RootName, Password) = PasswordAccepted) or
    (InAdministratorsGroup(UserId) and IsOwnPassword(UserId, Password));
end;

function AboutTheCaller(const Peer: TAbiChannelPeer; const Request: TSystemSettingsRequest): Boolean;
var
  Name: PChar;
begin
  Name := UserNameOf(Peer.UserId);
  Result := (Name <> nil) and (string(Name) = string(PChar(@Request.UserName[0])));
end;

function AuthorizeRequest(const Peer: TAbiChannelPeer; const Request: TSystemSettingsRequest): LongInt;
var
  Password: PChar;
  Accepted: Boolean;
begin
  if Peer.UserId = RootId then
    Exit(ErrorNone);
  case Request.Code of
    SystemRequestSetVolume, SystemRequestSetDefaultOutput:
      Exit(ErrorNone);
  end;
  Password := @Request.Authorization[0];
  { One's own password and full name, with one's own password. }
  if (Request.Code in [SystemRequestSetPassword, SystemRequestSetFullName]) and AboutTheCaller(Peer, Request) then
    Accepted := IsOwnPassword(Peer.UserId, Password) or IsAdministratorPassword(Peer.UserId, Password)
  else
    Accepted := IsAdministratorPassword(Peer.UserId, Password);
  if Accepted then
    Exit(ErrorNone);
  KernelSleep(WrongPasswordPauseMilliseconds);
  Result := ErrorAccessDenied;
end;

end.
