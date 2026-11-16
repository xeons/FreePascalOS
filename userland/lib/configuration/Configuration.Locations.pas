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
  Where settings live, and opening them.

    /etc/settings/GROUP.settings     the system's: read by everyone,
                                     written by root (0644, folder 0755)
    $HOME/.settings/GROUP.settings   a user's: theirs alone (0600,
                                     folder 0700)

  OpenSettings is what a program usually wants: the settings of the user
  it runs as (HOME says where they live) over the system's. A program
  without a home (HOME unset or empty) gets the system's alone. Root's
  home is "/", so its settings are in /.settings.
}
unit Configuration.Locations;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Settings;

const
  SystemSettingsFolder = '/etc/settings';
  UserSettingsFolderName = '.settings';
  UserSettingsFileMode = $180;     { rw------- }
  UserSettingsFolderMode = $1C0;   { rwx------ }
  SystemSettingsFileMode = $1A4;   { rw-r--r-- }
  SystemSettingsFolderMode = $1ED; { rwxr-xr-x }

{ The folder of the settings of the user whose home is Home. }
function UserSettingsFolder(const Home: string): string;
{ The home of the user this program runs as ('' if it has none). }
function CurrentHome: string;

{ The current user's settings over the system's. }
function OpenSettings: TSettings;
{ The system's settings alone. }
function OpenSystemSettings: TSettings;
{ The settings of the user whose home is Home over the system's: for
  root acting for a user (the session manager reading what a user chose). }
function OpenSettingsOfHome(const Home: string): TSettings;

implementation

uses
  SysUtils,
  Sys.Environment,
  Configuration.Scopes,
  Configuration.FileStorage;

function UserSettingsFolder(const Home: string): string;
begin
  if (Home <> '') and (Home[Length(Home)] = '/') then
    Result := Home + UserSettingsFolderName
  else
    Result := Home + '/' + UserSettingsFolderName;
end;

function CurrentHome: string;
var
  Home: PChar;
begin
  Home := GetVariable('HOME');
  if Home = nil then
    Result := ''
  else
    Result := string(Home);
end;

function SystemScope: TSettingsScope;
begin
  Result := TSettingsScope.Create(TFileSettingsStorage.Create(SystemSettingsFolder, SystemSettingsFileMode,
    SystemSettingsFolderMode), True);
end;

function UserScope(const Home: string): TSettingsScope;
begin
  Result := nil;
  if Home <> '' then
    Result := TSettingsScope.Create(TFileSettingsStorage.Create(UserSettingsFolder(Home), UserSettingsFileMode,
      UserSettingsFolderMode), True);
end;

function OpenSettings: TSettings;
begin
  Result := OpenSettingsOfHome(CurrentHome);
end;

function OpenSystemSettings: TSettings;
begin
  Result := TSettings.Create(nil, SystemScope);
end;

function OpenSettingsOfHome(const Home: string): TSettings;
begin
  Result := TSettings.Create(UserScope(Home), SystemScope);
end;

end.
