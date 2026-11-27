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
  Which group an item goes in when a folder is grouped ("Group by"):

    name      0-9, A - H, I - P, Q - Z, Other (by the first character)
    date      Today, Yesterday, Earlier this week, Last week, Earlier
              this month, Last month, Earlier this year, A long time ago
    type      its type ("Folder", "PNG file", ...), in name order
    size      Folders, Empty, Tiny (under 16 KB), Small (to 1 MB),
              Medium (to 128 MB), Large (to 1 GB), Huge (to 4 GB),
              Gigantic
    month     "November 2026" (the gallery), the newest first

  GroupOrder places a caption among the others: the fixed sets keep
  their own order, types and months are sorted. Times are Unix seconds,
  "today" worked out for the local time zone given. Plain logic, checked
  on the host (make files-test).
}
unit FileManager.Grouping;

{$mode objfpc}
{$H+}

interface

type
  TGroupBy = (GroupNone, GroupByName, GroupByDate, GroupByType, GroupBySize, GroupByMonth);

const
  GroupByKeys: array[TGroupBy] of string = ('none', 'name', 'date', 'type', 'size', 'month');
  GroupByCaptions: array[TGroupBy] of string = ('(None)', 'Name', 'Date modified', 'Type', 'Size', 'Month');

{ The caption of the group an item goes in. }
function GroupCaption(GroupBy: TGroupBy; const Name, TypeText: string; IsFolder: Boolean; Size: QWord;
  ModificationTime, NowTime: Int64; LocalOffset: LongInt): string;
{ A number to order groups by (smaller first); for types the caption
  itself decides (0 for all), for months the newest first. }
function GroupOrder(GroupBy: TGroupBy; const Caption: string; ModificationTime: Int64): Int64;
function GroupByNamed(const Key: string): TGroupBy;

implementation

uses
  SysUtils,
  FileManager.CivilDates;

const
  KiB = QWord(1024);
  MiB = KiB * 1024;
  GiB = MiB * 1024;
  DateCaptions: array[0..7] of string = ('Today', 'Yesterday', 'Earlier this week', 'Last week',
    'Earlier this month', 'Last month', 'Earlier this year', 'A long time ago');
  SizeCaptions: array[0..7] of string = ('Folders', 'Empty', 'Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Gigantic');
  NameCaptions: array[0..4] of string = ('0-9', 'A - H', 'I - P', 'Q - Z', 'Other');

function NameGroup(const Name: string): string;
var
  First: Char;
begin
  if Name = '' then
    Exit('Other');
  First := UpCase(Name[1]);
  case First of
    '0'..'9': Result := '0-9';
    'A'..'H': Result := 'A - H';
    'I'..'P': Result := 'I - P';
    'Q'..'Z': Result := 'Q - Z';
  else
    Result := 'Other';
  end;
end;

function DateGroup(ModificationTime, NowTime: Int64; LocalOffset: LongInt): string;
var
  Today: Int64;
  Day: Int64;
  WeekStart: Int64;
  TodayDate: TCivilDate;
  Date: TCivilDate;
  MonthStart: Int64;
  LastMonthStart: Int64;
begin
  Today := LocalDayOf(NowTime, LocalOffset);
  Day := LocalDayOf(ModificationTime, LocalOffset);
  WeekStart := Today - WeekdayOfDays(Today);
  TodayDate := CivilFromDays(Today);
  Date := CivilFromDays(Day);
  MonthStart := DaysFromCivil(TodayDate.Year, TodayDate.Month, 1);
  if TodayDate.Month = 1 then
    LastMonthStart := DaysFromCivil(TodayDate.Year - 1, 12, 1)
  else
    LastMonthStart := DaysFromCivil(TodayDate.Year, TodayDate.Month - 1, 1);
  if Day >= Today then
    Result := DateCaptions[0]
  else if Day = Today - 1 then
    Result := DateCaptions[1]
  else if Day >= WeekStart then
    Result := DateCaptions[2]
  else if Day >= WeekStart - 7 then
    Result := DateCaptions[3]
  else if Day >= MonthStart then
    Result := DateCaptions[4]
  else if Day >= LastMonthStart then
    Result := DateCaptions[5]
  else if Date.Year = TodayDate.Year then
    Result := DateCaptions[6]
  else
    Result := DateCaptions[7];
end;

function SizeGroup(IsFolder: Boolean; Size: QWord): string;
begin
  if IsFolder then
    Result := SizeCaptions[0]
  else if Size = 0 then
    Result := SizeCaptions[1]
  else if Size < 16 * KiB then
    Result := SizeCaptions[2]
  else if Size < MiB then
    Result := SizeCaptions[3]
  else if Size < 128 * MiB then
    Result := SizeCaptions[4]
  else if Size < GiB then
    Result := SizeCaptions[5]
  else if Size < 4 * GiB then
    Result := SizeCaptions[6]
  else
    Result := SizeCaptions[7];
end;

function MonthGroup(ModificationTime: Int64; LocalOffset: LongInt): string;
var
  Date: TCivilDate;
begin
  Date := LocalDateOf(ModificationTime, LocalOffset);
  Result := MonthNames[Date.Month] + ' ' + IntToStr(Date.Year);
end;

function GroupCaption(GroupBy: TGroupBy; const Name, TypeText: string; IsFolder: Boolean; Size: QWord;
  ModificationTime, NowTime: Int64; LocalOffset: LongInt): string;
begin
  case GroupBy of
    GroupByName: Result := NameGroup(Name);
    GroupByDate: Result := DateGroup(ModificationTime, NowTime, LocalOffset);
    GroupByType: Result := TypeText;
    GroupBySize: Result := SizeGroup(IsFolder, Size);
    GroupByMonth: Result := MonthGroup(ModificationTime, LocalOffset);
  else
    Result := '';
  end;
end;

function IndexIn(const Captions: array of string; const Caption: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Captions) do
    if Captions[Index] = Caption then
      Exit(Index);
  Result := Length(Captions);
end;

function GroupOrder(GroupBy: TGroupBy; const Caption: string; ModificationTime: Int64): Int64;
begin
  case GroupBy of
    GroupByName: Result := IndexIn(NameCaptions, Caption);
    GroupByDate: Result := IndexIn(DateCaptions, Caption);
    GroupBySize: Result := IndexIn(SizeCaptions, Caption);
    { Newest month first: by the time, turned round. }
    GroupByMonth: Result := -ModificationTime;
  else
    Result := 0;
  end;
end;

function GroupByNamed(const Key: string): TGroupBy;
var
  Each: TGroupBy;
begin
  for Each := Low(TGroupBy) to High(TGroupBy) do
    if GroupByKeys[Each] = Key then
      Exit(Each);
  Result := GroupNone;
end;

end.
