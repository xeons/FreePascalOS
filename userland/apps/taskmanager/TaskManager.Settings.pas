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
  What the task manager remembers from one run to the next, in the
  user's settings (libconfiguration), group TaskManager:

    Width = 600, Height = 440      the window's client size (logical units)
    Tab = 0 | 1 | 2                Programs, Processes, Performance
    SortColumn = 3                 the Processes list's sort column
    SortAscending = true|false
    UpdateMilliseconds = 1000      how often it looks; 0 for paused

  The tab, the sort and the update speed are written as soon as they
  are chosen, the size when the window closes. Values not set are the
  defaults below.
}
unit TaskManager.Settings;

{$mode objfpc}
{$H+}

interface

const
  { Small enough for a 1280x800 display at 150% (its taskbar left out). }
  DefaultWidth = 600;
  DefaultHeight = 440;
  { The speeds offered (View > Update Speed). }
  HighUpdateMilliseconds = 500;
  NormalUpdateMilliseconds = 1000;
  LowUpdateMilliseconds = 4000;
  PausedUpdateMilliseconds = 0;

type
  TTaskManagerSettings = record
    Width: LongInt;
    Height: LongInt;
    TabIndex: LongInt;
    SortColumn: LongInt;
    SortAscending: Boolean;
    UpdateMilliseconds: LongWord;
  end;

function RememberedSettings: TTaskManagerSettings;
procedure RememberSize(Width, Height: LongInt);
procedure RememberTab(TabIndex: LongInt);
procedure RememberSort(Column: LongInt; Ascending: Boolean);
procedure RememberUpdateSpeed(Milliseconds: LongWord);

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  WidthSetting = 'TaskManager/Width';
  HeightSetting = 'TaskManager/Height';
  TabSetting = 'TaskManager/Tab';
  SortColumnSetting = 'TaskManager/SortColumn';
  SortAscendingSetting = 'TaskManager/SortAscending';
  UpdateSetting = 'TaskManager/UpdateMilliseconds';
  SmallestWidth = 300;
  SmallestHeight = 240;
  LargestSize = 4000;
  LastTab = 2;
  LastColumn = 7;
  { The CPU column, busiest first: what a task manager is opened for. }
  DefaultSortColumn = 3;

{ An update speed read back is one of those offered. }
function OfferedSpeed(Milliseconds: Int64): LongWord;
begin
  case Milliseconds of
    HighUpdateMilliseconds, LowUpdateMilliseconds, PausedUpdateMilliseconds: Result := LongWord(Milliseconds);
  else
    Result := NormalUpdateMilliseconds;
  end;
end;

function RememberedSettings: TTaskManagerSettings;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Result.Width := Store.ReadIntegerWithin(WidthSetting, DefaultWidth, SmallestWidth, LargestSize);
  Result.Height := Store.ReadIntegerWithin(HeightSetting, DefaultHeight, SmallestHeight, LargestSize);
  Result.TabIndex := Store.ReadIntegerWithin(TabSetting, 1, 0, LastTab);
  Result.SortColumn := Store.ReadIntegerWithin(SortColumnSetting, DefaultSortColumn, 0, LastColumn);
  Result.SortAscending := Store.ReadBoolean(SortAscendingSetting, False);
  Result.UpdateMilliseconds := OfferedSpeed(Store.ReadInteger(UpdateSetting, NormalUpdateMilliseconds));
  Store.Free;
end;

{ Freeing the settings flushes them. }
procedure RememberSize(Width, Height: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(WidthSetting, Width);
  Store.WriteInteger(HeightSetting, Height);
  Store.Free;
end;

procedure RememberTab(TabIndex: LongInt);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(TabSetting, TabIndex);
  Store.Free;
end;

procedure RememberSort(Column: LongInt; Ascending: Boolean);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(SortColumnSetting, Column);
  Store.WriteBoolean(SortAscendingSetting, Ascending);
  Store.Free;
end;

procedure RememberUpdateSpeed(Milliseconds: LongWord);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  Store.WriteInteger(UpdateSetting, Milliseconds);
  Store.Free;
end;

end.
