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
  A tab of the window: where it is, its own Back and Forward history,
  and what was selected when it was left, so switching back to it shows
  it as it was. The window's controls are shared: switching tabs shows
  the tab's location in them again.

  The history holds locations as keys (LocationKey): a search is a
  place in the history like a folder.
}
unit FileManager.Tabs;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  FileManager.History,
  FileManager.Locations;

type
  TBrowserTab = class
  public
    Location: TLocation;
    History: TNavigationHistory;
    SelectedPaths: TStringList;
    constructor Create(const ALocation: TLocation);
    destructor Destroy; override;
    { A copy (Duplicate): the same place and history. }
    function Clone: TBrowserTab;
  end;

function LocationKey(const Location: TLocation): string;
function LocationFromKey(const Key: string): TLocation;

implementation

uses
  SysUtils;

const
  Separator = #1;

function LocationKey(const Location: TLocation): string;
begin
  Result := IntToStr(Ord(Location.Kind)) + Separator + Location.Path + Separator + Location.InnerPath + Separator +
    Location.Query;
end;

function LocationFromKey(const Key: string): TLocation;
var
  Parts: TStringArray;
  Kind: LongInt;
begin
  Result := Default(TLocation);
  Parts := Key.Split([Separator]);
  if (Length(Parts) < 1) or not TryStrToInt(Parts[0], Kind) or (Kind < Ord(Low(TLocationKind))) or
     (Kind > Ord(High(TLocationKind))) then
    Exit(PageLocation(LocationHome));
  Result.Kind := TLocationKind(Kind);
  if Length(Parts) > 1 then
    Result.Path := Parts[1];
  if Length(Parts) > 2 then
    Result.InnerPath := Parts[2];
  if Length(Parts) > 3 then
    Result.Query := Parts[3];
end;

constructor TBrowserTab.Create(const ALocation: TLocation);
begin
  inherited Create;
  Location := ALocation;
  History := TNavigationHistory.Create;
  SelectedPaths := TStringList.Create;
end;

destructor TBrowserTab.Destroy;
begin
  History.Free;
  SelectedPaths.Free;
  inherited Destroy;
end;

function TBrowserTab.Clone: TBrowserTab;
var
  Keys: TStringList;
  Index: LongInt;
  Back: LongInt;
begin
  Result := TBrowserTab.Create(Location);
  { The history again, in order, ending where this one is. }
  Keys := TStringList.Create;
  try
    Back := 0;
    while History.CanGoBack do
    begin
      History.GoBack;
      Inc(Back);
    end;
    Keys.Add(History.Current);
    while History.CanGoForward do
      Keys.Add(History.GoForward);
    for Index := 0 to Keys.Count - 1 do
      if Keys[Index] <> '' then
        Result.History.Visit(Keys[Index]);
    for Index := Keys.Count - 1 downto Back + 1 do
      Result.History.GoBack;
    { And this one back where it was. }
    while History.CanGoBack do
      History.GoBack;
    for Index := 1 to Back do
      History.GoForward;
  finally
    Keys.Free;
  end;
end;

end.
