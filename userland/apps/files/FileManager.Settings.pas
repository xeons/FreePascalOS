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

    [Options]                         the Options dialog
    OpenInNewWindow = false           folders open in a new window
    SingleClick = false               one click opens
    ShowHidden = false                names starting with a dot
    ShowExtensions = true             "notes.txt" rather than "notes"
    ShowCheckBoxes = false            item check boxes
    ShowPreviewPane, ShowDetailsPane  at start (one at most)
    ShowRecent, ShowFavorites = true  on the Home page
    Compact = false                   less space between items
    ProgressDelay = 500               milliseconds an operation runs
                                      before its progress dialog shows
    PlacesWidth = 200, PanesWidth = 280   the panes (logical units)
    [Window] Left, Top, Width, Height     logical units
    [Views/KEY]                       a folder's view (KEY: a page's
                                      name or a hash of the path):
      View, Sort, Ascending, GroupBy, Columns = ["name", ...]
    [Defaults] EXTENSION = FOLDER     the program chosen to open a type

  Lists (FileManager.UserLists): Pinned, Favorites, Recent,
  SearchHistory. Values not set (or out of range) are the defaults.
}
unit FileManager.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Controls.ItemViewLayout,
  FileManager.ItemColumns,
  FileManager.Grouping;

type
  TFileManagerOptions = record
    OpenInNewWindow: Boolean;
    SingleClick: Boolean;
    ShowHidden: Boolean;
    ShowExtensions: Boolean;
    ShowCheckBoxes: Boolean;
    ShowPreviewPane: Boolean;
    ShowDetailsPane: Boolean;
    ShowRecent: Boolean;
    ShowFavorites: Boolean;
    Compact: Boolean;
    ProgressDelay: LongInt;
    PlacesWidth: LongInt;
    PanesWidth: LongInt;
    WindowLeft: LongInt;
    WindowTop: LongInt;
    WindowWidth: LongInt;
    WindowHeight: LongInt;
  end;

  TFolderViewSettings = record
    Mode: TItemViewMode;
    SortColumn: TColumnKind;
    SortAscending: Boolean;
    GroupBy: TGroupBy;
    Columns: array of TColumnKind;
  end;

const
  ViewModeKeys: array[TItemViewMode] of string = ('extra-large', 'large', 'medium', 'small', 'list', 'details',
    'tiles', 'content');
  ViewModeCaptions: array[TItemViewMode] of string = ('E&xtra large icons', '&Large icons', 'M&edium icons',
    'Sm&all icons', '&List', '&Details', '&Tiles', 'C&ontent');

function RememberedOptions: TFileManagerOptions;
procedure RememberOptions(const Options: TFileManagerOptions);
procedure RememberWindow(Left, Top, Width, Height, PlacesWidth, PanesWidth: LongInt);
{ The view of a folder or page (KEY), else the defaults for it. }
function RememberedView(const Key: string; const Defaults: TFolderViewSettings): TFolderViewSettings;
procedure RememberView(const Key: string; const View: TFolderViewSettings);
{ Forgets every folder's own view ("Reset views"). }
procedure ForgetViews;
{ The key a folder's view is kept under. }
function ViewKeyOfPath(const Path: string): string;
function ViewModeNamed(const Name: string; Default: TItemViewMode): TItemViewMode;
{ The program (folder name) chosen for an extension ('' if none). }
function ChosenProgramFor(const Extension: string): string;
procedure RememberChosenProgram(const Extension, FolderName: string);
function DefaultViewSettings(Mode: TItemViewMode): TFolderViewSettings;

implementation

uses
  SysUtils,
  Configuration.Settings,
  Configuration.Locations;

const
  OptionsPrefix = 'Files/Options/';
  WindowPrefix = 'Files/Window/';
  ViewsSection = 'Files/Views';
  DefaultsPrefix = 'Files/Defaults/';

function ViewModeNamed(const Name: string; Default: TItemViewMode): TItemViewMode;
var
  Mode: TItemViewMode;
begin
  for Mode := Low(TItemViewMode) to High(TItemViewMode) do
    if ViewModeKeys[Mode] = Name then
      Exit(Mode);
  Result := Default;
end;

function DefaultViewSettings(Mode: TItemViewMode): TFolderViewSettings;
var
  Column: TColumnKind;
begin
  Result := Default(TFolderViewSettings);
  Result.Mode := Mode;
  Result.SortColumn := ColumnName;
  Result.SortAscending := True;
  Result.GroupBy := GroupNone;
  for Column := Low(TColumnKind) to High(TColumnKind) do
    if Column in DefaultColumns then
    begin
      SetLength(Result.Columns, Length(Result.Columns) + 1);
      Result.Columns[High(Result.Columns)] := Column;
    end;
end;

function RememberedOptions: TFileManagerOptions;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Result.OpenInNewWindow := Store.ReadBoolean(OptionsPrefix + 'OpenInNewWindow', False);
    Result.SingleClick := Store.ReadBoolean(OptionsPrefix + 'SingleClick', False);
    Result.ShowHidden := Store.ReadBoolean(OptionsPrefix + 'ShowHidden', Store.ReadBoolean('Files/ShowHidden', False));
    Result.ShowExtensions := Store.ReadBoolean(OptionsPrefix + 'ShowExtensions', True);
    Result.ShowCheckBoxes := Store.ReadBoolean(OptionsPrefix + 'ShowCheckBoxes', False);
    Result.ShowPreviewPane := Store.ReadBoolean(OptionsPrefix + 'ShowPreviewPane', False);
    Result.ShowDetailsPane := Store.ReadBoolean(OptionsPrefix + 'ShowDetailsPane', False);
    Result.ShowRecent := Store.ReadBoolean(OptionsPrefix + 'ShowRecent', True);
    Result.ShowFavorites := Store.ReadBoolean(OptionsPrefix + 'ShowFavorites', True);
    Result.Compact := Store.ReadBoolean(OptionsPrefix + 'Compact', False);
    { (The test sets the delay under its older name, Files/ProgressDelay.) }
    Result.ProgressDelay := Store.ReadIntegerWithin(OptionsPrefix + 'ProgressDelay',
      Store.ReadIntegerWithin('Files/ProgressDelay', 500, 0, 60000), 0, 60000);
    Result.PlacesWidth := Store.ReadIntegerWithin(OptionsPrefix + 'PlacesWidth', 200, 60, 1000);
    Result.PanesWidth := Store.ReadIntegerWithin(OptionsPrefix + 'PanesWidth', 280, 120, 1200);
    Result.WindowLeft := Store.ReadIntegerWithin(WindowPrefix + 'Left', 60, -4000, 8000);
    Result.WindowTop := Store.ReadIntegerWithin(WindowPrefix + 'Top', 40, -4000, 8000);
    Result.WindowWidth := Store.ReadIntegerWithin(WindowPrefix + 'Width', 980, 420, 8000);
    Result.WindowHeight := Store.ReadIntegerWithin(WindowPrefix + 'Height', 620, 300, 8000);
  finally
    Store.Free;
  end;
end;

procedure RememberOptions(const Options: TFileManagerOptions);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteBoolean(OptionsPrefix + 'OpenInNewWindow', Options.OpenInNewWindow);
    Store.WriteBoolean(OptionsPrefix + 'SingleClick', Options.SingleClick);
    Store.WriteBoolean(OptionsPrefix + 'ShowHidden', Options.ShowHidden);
    Store.WriteBoolean(OptionsPrefix + 'ShowExtensions', Options.ShowExtensions);
    Store.WriteBoolean(OptionsPrefix + 'ShowCheckBoxes', Options.ShowCheckBoxes);
    Store.WriteBoolean(OptionsPrefix + 'ShowPreviewPane', Options.ShowPreviewPane);
    Store.WriteBoolean(OptionsPrefix + 'ShowDetailsPane', Options.ShowDetailsPane);
    Store.WriteBoolean(OptionsPrefix + 'ShowRecent', Options.ShowRecent);
    Store.WriteBoolean(OptionsPrefix + 'ShowFavorites', Options.ShowFavorites);
    Store.WriteBoolean(OptionsPrefix + 'Compact', Options.Compact);
  finally
    Store.Free;
  end;
end;

procedure RememberWindow(Left, Top, Width, Height, PlacesWidth, PanesWidth: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteInteger(WindowPrefix + 'Left', Left);
    Store.WriteInteger(WindowPrefix + 'Top', Top);
    Store.WriteInteger(WindowPrefix + 'Width', Width);
    Store.WriteInteger(WindowPrefix + 'Height', Height);
    Store.WriteInteger(OptionsPrefix + 'PlacesWidth', PlacesWidth);
    Store.WriteInteger(OptionsPrefix + 'PanesWidth', PanesWidth);
  finally
    Store.Free;
  end;
end;

function ViewKeyOfPath(const Path: string): string;
var
  Hash: QWord;
  Index: LongInt;
begin
  Hash := QWord($CBF29CE484222325);
  for Index := 1 to Length(Path) do
  begin
    Hash := Hash xor Ord(Path[Index]);
    {$push}{$overflowchecks off}{$rangechecks off}
    Hash := Hash * QWord($100000001B3);
    {$pop}
  end;
  Result := 'f' + IntToHex(Hash, 16);
end;

function RememberedView(const Key: string; const Defaults: TFolderViewSettings): TFolderViewSettings;
var
  Store: TSettings;
  Prefix: string;
  Names: TStringArray;
  Name: string;
  Column: TColumnKind;
  Empty: TStringArray;
begin
  Result := Defaults;
  Store := OpenSettings;
  try
    Prefix := ViewsSection + '/' + Key + '/';
    Result.Mode := ViewModeNamed(Store.ReadString(Prefix + 'View', ''), Defaults.Mode);
    if ColumnNamed(Store.ReadString(Prefix + 'Sort', ''), Column) then
      Result.SortColumn := Column;
    Result.SortAscending := Store.ReadBoolean(Prefix + 'Ascending', Defaults.SortAscending);
    Result.GroupBy := GroupByNamed(Store.ReadString(Prefix + 'GroupBy', GroupByKeys[Defaults.GroupBy]));
    Empty := nil;
    Names := Store.ReadList(Prefix + 'Columns', Empty);
    if Length(Names) > 0 then
    begin
      Result.Columns := nil;
      SetLength(Result.Columns, 1);
      Result.Columns[0] := ColumnName;
      for Name in Names do
        if ColumnNamed(Name, Column) and (Column <> ColumnName) then
        begin
          SetLength(Result.Columns, Length(Result.Columns) + 1);
          Result.Columns[High(Result.Columns)] := Column;
        end;
    end;
  finally
    Store.Free;
  end;
end;

procedure RememberView(const Key: string; const View: TFolderViewSettings);
var
  Store: TSettings;
  Prefix: string;
  Names: TStringArray;
  Index: LongInt;
begin
  Store := OpenSettings;
  try
    Prefix := ViewsSection + '/' + Key + '/';
    Store.WriteString(Prefix + 'View', ViewModeKeys[View.Mode]);
    Store.WriteString(Prefix + 'Sort', ColumnKeys[View.SortColumn]);
    Store.WriteBoolean(Prefix + 'Ascending', View.SortAscending);
    Store.WriteString(Prefix + 'GroupBy', GroupByKeys[View.GroupBy]);
    Names := nil;
    SetLength(Names, Length(View.Columns));
    for Index := 0 to High(View.Columns) do
      Names[Index] := ColumnKeys[View.Columns[Index]];
    Store.WriteList(Prefix + 'Columns', Names);
  finally
    Store.Free;
  end;
end;

procedure ForgetViews;
var
  Store: TSettings;
  Section: string;
  Key: string;
begin
  Store := OpenSettings;
  try
    for Section in Store.ListSections(ViewsSection) do
      for Key in Store.ListKeys(ViewsSection + '/' + Section) do
        Store.Delete(ViewsSection + '/' + Section + '/' + Key);
  finally
    Store.Free;
  end;
end;

function ChosenProgramFor(const Extension: string): string;
var
  Store: TSettings;
begin
  if Extension = '' then
    Exit('');
  Store := OpenSettings;
  try
    Result := Store.ReadString(DefaultsPrefix + LowerCase(Extension), '');
  finally
    Store.Free;
  end;
end;

procedure RememberChosenProgram(const Extension, FolderName: string);
var
  Store: TSettings;
begin
  if Extension = '' then
    Exit;
  Store := OpenSettings;
  try
    Store.WriteString(DefaultsPrefix + LowerCase(Extension), FolderName);
  finally
    Store.Free;
  end;
end;

end.
