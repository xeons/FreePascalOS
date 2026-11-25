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
  The browser's profile: the folder in the user's settings folder
  (~/.settings/browser) where it keeps the history, the bookmarks, the
  session, the search engines, saved passwords and local storage.
}
unit Browser.Profile;

{$mode objfpc}
{$H+}

interface

{ ~/.settings/browser (made if missing); /tmp/browser without a home. }
function BrowserProfileFolder: string;
{ A file of the profile. }
function ProfileFile(const Name: string): string;

implementation

uses
  SysUtils,
  Configuration.Locations;

function BrowserProfileFolder: string;
var
  Home: string;
begin
  Home := CurrentHome;
  if Home = '' then
    Result := '/tmp/browser'
  else
    Result := UserSettingsFolder(Home) + '/browser';
  ForceDirectories(Result);
end;

function ProfileFile(const Name: string): string;
begin
  Result := BrowserProfileFolder + '/' + Name;
end;

end.
