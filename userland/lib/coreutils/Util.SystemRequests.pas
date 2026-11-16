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
  Asking the system settings service (Sys.SystemSettings) for a change
  from a command-line tool: root asks without a password; anyone else is
  asked for an administrator's password on the terminal first (root's,
  or their own if they are in "wheel"), which goes with the request.
}
unit Util.SystemRequests;

{$mode objfpc}

interface

uses
  Sys.SystemSettings;

{ Sends Request, with a password read from the terminal when the caller
  is not root and NeedsPassword says the request wants one; returns the
  service's answer (an Abi error code). }
function SendSystemRequest(var Request: TSystemSettingsRequest; NeedsPassword: Boolean): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Util.Accounts,
  Util.Passwords;

function SendSystemRequest(var Request: TSystemSettingsRequest; NeedsPassword: Boolean): LongInt;
var
  Password: PChar;
begin
  if NeedsPassword and (CurrentRealUserId <> RootId) then
  begin
    Password := ReadPassword('Administrator password: ');
    if Password <> nil then
    begin
      SetRequestText(@Request.Authorization[0], SystemPasswordCapacity, Password);
      ZeroMemory(Password, TextLength(Password));
      FreeMemory(Password);
    end;
  end;
  Result := AskSystemSettings(Request);
end;

end.
