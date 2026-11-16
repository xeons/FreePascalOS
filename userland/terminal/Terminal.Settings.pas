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

  Values out of their range are taken as not set.
}
unit Terminal.Settings;

{$mode objfpc}
{$H+}

interface

type
  TTerminalSettings = record
    Rows: LongInt;
    Columns: LongInt;
    FontPointTenths: LongWord;
  end;

function RememberedTerminalSettings: TTerminalSettings;
procedure RememberGridSize(Rows, Columns: LongInt);

implementation

uses
  Configuration.Settings,
  Configuration.Locations,
  Terminal.View;

const
  RowsSetting = 'Terminal/Rows';
  ColumnsSetting = 'Terminal/Columns';
  FontSizeSetting = 'Terminal/FontSize';
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
  Store.Free;
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
