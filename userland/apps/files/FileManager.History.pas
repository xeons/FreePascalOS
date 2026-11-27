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
  Where the window has been: Back and Forward, as a browser has them.

  Visiting a folder puts it after the current one and forgets what was
  ahead; Back and Forward move along the list without changing it. A
  folder visited again right where it is (a refresh) is not added
  twice. The list keeps the last MostRemembered folders.

  Plain logic: the host checks it (make files-test).
}
unit FileManager.History;

{$mode objfpc}
{$H+}

interface

uses
  Classes;

type
  TNavigationHistory = class
  private
    FFolders: TStringList;
    { The current folder's place in the list (-1: none yet). }
    FCurrent: LongInt;
    function GetCurrent: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Visit(const Folder: string);
    function CanGoBack: Boolean;
    function CanGoForward: Boolean;
    { The folder before (after) the current one, which becomes current. }
    function GoBack: string;
    function GoForward: string;
    { Takes Folder (and everything below it) out of the list: it is gone
      (its volume was unplugged). }
    procedure Forget(const Folder: string);
    property Current: string read GetCurrent;
  end;

implementation

uses
  FileManager.Paths;

const
  MostRemembered = 100;

constructor TNavigationHistory.Create;
begin
  inherited Create;
  FFolders := TStringList.Create;
  FCurrent := -1;
end;

destructor TNavigationHistory.Destroy;
begin
  FFolders.Free;
  inherited Destroy;
end;

function TNavigationHistory.GetCurrent: string;
begin
  if FCurrent < 0 then
    Exit('');
  Result := FFolders[FCurrent];
end;

procedure TNavigationHistory.Visit(const Folder: string);
begin
  if (FCurrent >= 0) and (FFolders[FCurrent] = Folder) then
    Exit;
  while FFolders.Count > FCurrent + 1 do
    FFolders.Delete(FFolders.Count - 1);
  FFolders.Add(Folder);
  if FFolders.Count > MostRemembered then
    FFolders.Delete(0);
  FCurrent := FFolders.Count - 1;
end;

function TNavigationHistory.CanGoBack: Boolean;
begin
  Result := FCurrent > 0;
end;

function TNavigationHistory.CanGoForward: Boolean;
begin
  Result := (FCurrent >= 0) and (FCurrent < FFolders.Count - 1);
end;

function TNavigationHistory.GoBack: string;
begin
  if CanGoBack then
    Dec(FCurrent);
  Result := GetCurrent;
end;

function TNavigationHistory.GoForward: string;
begin
  if CanGoForward then
    Inc(FCurrent);
  Result := GetCurrent;
end;

procedure TNavigationHistory.Forget(const Folder: string);
var
  Index: LongInt;
begin
  Index := FFolders.Count - 1;
  while Index >= 0 do
  begin
    if IsSameOrInside(FFolders[Index], Folder) then
    begin
      FFolders.Delete(Index);
      if FCurrent >= Index then
        Dec(FCurrent);
    end;
    Dec(Index);
  end;
  { Two neighbours left equal by the removal would make Back do
    nothing once. }
  Index := FFolders.Count - 1;
  while Index > 0 do
  begin
    if FFolders[Index] = FFolders[Index - 1] then
    begin
      FFolders.Delete(Index);
      if FCurrent >= Index then
        Dec(FCurrent);
    end;
    Dec(Index);
  end;
  if (FCurrent < 0) and (FFolders.Count > 0) then
    FCurrent := 0;
end;

end.
