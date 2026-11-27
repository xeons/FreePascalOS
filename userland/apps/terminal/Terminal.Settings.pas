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
  What the terminal remembers, in the user's settings (libconfiguration),
  group Terminal:

    Rows = 25, Columns = 80    the size of the last window when it closed,
                               which the next one starts at
    FontSize = 110             the text's size in tenths of a point (set
                               with the settings tool: settings set
                               Terminal/FontSize 140)
    TextColor = "#d0d0d0"      the text's colour and the background's,
    BackgroundColor = "#101010"  as #RRGGBB

  Values out of their range are taken as not set. The font's size and
  the colours are taken at once when they change while a terminal runs
  (Terminal.Window).
}
unit Terminal.Settings;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Configuration.Changes;

const
  TerminalSettingsGroup = 'Terminal';

type
  TTerminalSettings = record
    Rows: LongInt;
    Columns: LongInt;
    FontPointTenths: LongWord;
    TextColor: TColor;
    BackgroundColor: TColor;
  end;

function RememberedTerminalSettings: TTerminalSettings;
procedure RememberGridSize(Rows, Columns: LongInt);
{ True if Changes touch how the text looks (not the window's size). }
function AppearanceChanged(const Changes: TSettingChanges): Boolean;

implementation

uses
  SysUtils,
  Configuration.Settings,
  Configuration.Locations,
  Terminal.Cells,
  Terminal.View;

const
  RowsSetting = 'Terminal/Rows';
  ColumnsSetting = 'Terminal/Columns';
  FontSizeSetting = 'Terminal/FontSize';
  TextColorSetting = 'Terminal/TextColor';
  BackgroundColorSetting = 'Terminal/BackgroundColor';
  DefaultRows = 25;
  DefaultColumns = 80;
  FewestRows = 2;
  MostRows = 200;
  FewestColumns = 10;
  MostColumns = 400;
  SmallestPointTenths = 60;
  LargestPointTenths = 400;

function WithinOrDefault(Value, Lowest, Highest, Default: Int64): Int64;
begin
  if (Value < Lowest) or (Value > Highest) then
    Result := Default
  else
    Result := Value;
end;

{ "#RRGGBB" as an opaque colour; Default if it is not one. }
function ColorOrDefault(const Text: string; Default: TColor): TColor;
var
  Value: LongInt;
begin
  if (Length(Text) <> 7) or (Text[1] <> '#') or not TryStrToInt('$' + Copy(Text, 2, 6), Value) then
    Exit(Default);
  Result := TColor($FF000000 or LongWord(Value));
end;

function RememberedTerminalSettings: TTerminalSettings;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Result.Rows := WithinOrDefault(Store.ReadInteger(RowsSetting, DefaultRows), FewestRows, MostRows, DefaultRows);
  Result.Columns := WithinOrDefault(Store.ReadInteger(ColumnsSetting, DefaultColumns), FewestColumns, MostColumns,
    DefaultColumns);
  Result.FontPointTenths := WithinOrDefault(Store.ReadInteger(FontSizeSetting, DefaultTerminalPointTenths),
    SmallestPointTenths, LargestPointTenths, DefaultTerminalPointTenths);
  Result.TextColor := ColorOrDefault(Store.ReadString(TextColorSetting, ''), StandardTextColor);
  Result.BackgroundColor := ColorOrDefault(Store.ReadString(BackgroundColorSetting, ''), StandardBackgroundColor);
  Store.Free;
end;

function AppearanceChanged(const Changes: TSettingChanges): Boolean;
begin
  Result := ChangesInclude(Changes, FontSizeSetting) or ChangesInclude(Changes, TextColorSetting) or
    ChangesInclude(Changes, BackgroundColorSetting);
end;

procedure RememberGridSize(Rows, Columns: LongInt);
var
  Store: TSettings;
begin
  if (Rows < FewestRows) or (Rows > MostRows) or (Columns < FewestColumns) or (Columns > MostColumns) then
    Exit;
  Store := OpenSettings;
  Store.WriteInteger(RowsSetting, Rows);
  Store.WriteInteger(ColumnsSetting, Columns);
  { Freeing the settings flushes them. }
  Store.Free;
end;

end.
