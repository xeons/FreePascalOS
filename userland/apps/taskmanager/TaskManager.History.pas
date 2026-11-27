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
  A history of one measure (how busy a processor was, how much memory
  was in use): the last HistoryLength samples, each in tenths of a
  percent, the newest last. A graph draws it; a new sample pushes the
  oldest out.
}
unit TaskManager.History;

{$mode objfpc}
{$H+}

interface

const
  { One minute at the normal speed. }
  HistoryLength = 60;

type
  TUsageHistory = record
    Samples: array[0..HistoryLength - 1] of LongWord;
    { Where the next sample goes, and how many there are so far. }
    Next: LongInt;
    Count: LongInt;
    { How many samples were ever added (the newest one's number plus
      one): a graph adds those it has not had yet. }
    Total: QWord;
  end;
  PUsageHistory = ^TUsageHistory;

procedure ClearHistory(out History: TUsageHistory);
procedure AddSample(var History: TUsageHistory; Tenths: LongWord);
{ Sample Age back from the newest (0: the newest); Age < History.Count. }
function SampleAt(const History: TUsageHistory; Age: LongInt): LongWord;
{ The newest sample, 0 if there is none. }
function NewestSample(const History: TUsageHistory): LongWord;

implementation

procedure ClearHistory(out History: TUsageHistory);
var
  Index: LongInt;
begin
  for Index := 0 to HistoryLength - 1 do
    History.Samples[Index] := 0;
  History.Next := 0;
  History.Count := 0;
  History.Total := 0;
end;

procedure AddSample(var History: TUsageHistory; Tenths: LongWord);
begin
  if Tenths > 1000 then
    Tenths := 1000;
  History.Samples[History.Next] := Tenths;
  History.Next := (History.Next + 1) mod HistoryLength;
  if History.Count < HistoryLength then
    Inc(History.Count);
  Inc(History.Total);
end;

function SampleAt(const History: TUsageHistory; Age: LongInt): LongWord;
begin
  Result := History.Samples[(History.Next - 1 - Age + 2 * HistoryLength) mod HistoryLength];
end;

function NewestSample(const History: TUsageHistory): LongWord;
begin
  if History.Count = 0 then
    Exit(0);
  Result := SampleAt(History, 0);
end;

end.
