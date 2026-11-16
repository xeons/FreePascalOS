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
  What the file manager remembers from one run to the next, in the
  user's settings (libconfiguration), group Files:

    View = "icons" | "details" | "list"     how folders are shown
    SortColumn = "name" | "size" | "type" | "modified" | "permissions" | "owner"
    SortAscending = true|false
    ShowHidden = true|false                 names starting with a dot
    PlacesWidth = 190                       the left pane (logical units)
    ProgressDelay = 500                     milliseconds an operation runs
                                            before its progress window shows
    [Window]
    Left, Top, Width, Height                logical units

  The view, the order and hidden files are written as soon as they are
  chosen; the window's place and size and the pane's width when the
  window closes. Values not set (or out of range) are the defaults.
}
unit FileManager.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Controls.ListView,
  FileManager.ItemOrder;

type
  TFileManagerSettings = record
    View: TListViewMode;
    SortColumn: TSortColumn;
    SortAscending: Boolean;
    ShowHidden: Boolean;
    PlacesWidth: LongInt;
    ProgressDelay: LongInt;
    WindowLeft: LongInt;
    WindowTop: LongInt;
    WindowWidth: LongInt;
    WindowHeight: LongInt;
  end;

function RememberedSettings: TFileManagerSettings;
procedure RememberView(View: TListViewMode);
procedure RememberOrder(Column: TSortColumn; Ascending: Boolean);
procedure RememberShowHidden(ShowHidden: Boolean);
procedure RememberWindow(Left, Top, Width, Height, PlacesWidth: LongInt);
function ViewName(View: TListViewMode): string;
function SortColumnName(Column: TSortColumn): string;

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  ViewSetting = 'Files/View';
  SortColumnSetting = 'Files/SortColumn';
  SortAscendingSetting = 'Files/SortAscending';
  ShowHiddenSetting = 'Files/ShowHidden';
  PlacesWidthSetting = 'Files/PlacesWidth';
  ProgressDelaySetting = 'Files/ProgressDelay';
  WindowLeftSetting = 'Files/Window/Left';
  WindowTopSetting = 'Files/Window/Top';
  WindowWidthSetting = 'Files/Window/Width';
  WindowHeightSetting = 'Files/Window/Height';
  SortColumnNames: array[TSortColumn] of string = ('name', 'size', 'type', 'modified', 'permissions', 'owner');

function ViewName(View: TListViewMode): string;
begin
  case View of
    ViewDetails: Result := 'details';
    ViewList: Result := 'list';
  else
    Result := 'icons';
  end;
end;

function SortColumnName(Column: TSortColumn): string;
begin
  Result := SortColumnNames[Column];
end;

function ViewNamed(const Name: string): TListViewMode;
begin
  if Name = 'details' then
    Result := ViewDetails
  else if Name = 'list' then
    Result := ViewList
  else
    Result := ViewLargeIcons;
end;

function SortColumnNamed(const Name: string): TSortColumn;
var
  Column: TSortColumn;
begin
  for Column := Low(TSortColumn) to High(TSortColumn) do
    if SortColumnNames[Column] = Name then
      Exit(Column);
  Result := SortByName;
end;

function RememberedSettings: TFileManagerSettings;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Result.View := ViewNamed(Store.ReadString(ViewSetting, 'icons'));
  Result.SortColumn := SortColumnNamed(Store.ReadString(SortColumnSetting, 'name'));
  Result.SortAscending := Store.ReadBoolean(SortAscendingSetting, True);
  Result.ShowHidden := Store.ReadBoolean(ShowHiddenSetting, False);
  Result.PlacesWidth := Store.ReadIntegerWithin(PlacesWidthSetting, 190, 60, 1000);
  Result.ProgressDelay := Store.ReadIntegerWithin(ProgressDelaySetting, 500, 0, 60000);
  Result.WindowLeft := Store.ReadIntegerWithin(WindowLeftSetting, 60, -4000, 8000);
  Result.WindowTop := Store.ReadIntegerWithin(WindowTopSetting, 40, -4000, 8000);
  Result.WindowWidth := Store.ReadIntegerWithin(WindowWidthSetting, 820, 320, 8000);
  Result.WindowHeight := Store.ReadIntegerWithin(WindowHeightSetting, 500, 240, 8000);
  Store.Free;
end;

{ Freeing the settings flushes them. }
procedure RememberView(View: TListViewMode);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteString(ViewSetting, ViewName(View));
  Store.Free;
end;

procedure RememberOrder(Column: TSortColumn; Ascending: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteString(SortColumnSetting, SortColumnNames[Column]);
  Store.WriteBoolean(SortAscendingSetting, Ascending);
  Store.Free;
end;

procedure RememberShowHidden(ShowHidden: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteBoolean(ShowHiddenSetting, ShowHidden);
  Store.Free;
end;

procedure RememberWindow(Left, Top, Width, Height, PlacesWidth: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(WindowLeftSetting, Left);
  Store.WriteInteger(WindowTopSetting, Top);
  Store.WriteInteger(WindowWidthSetting, Width);
  Store.WriteInteger(WindowHeightSetting, Height);
  Store.WriteInteger(PlacesWidthSetting, PlacesWidth);
  Store.Free;
end;

end.
