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
  How busy the busiest processor was since the last look, for the clock
  governors (Power.BoardClocks, Power.PerformanceStates).
}
unit Power.ProcessorLoad;

{$mode objfpc}

interface

uses
  Kernel.Processors;

type
  TProcessorLoadSample = record
    Busy: array[0..MaximumProcessors - 1] of QWord;
    Idle: array[0..MaximumProcessors - 1] of QWord;
  end;

procedure StartLoadSample(out Sample: TProcessorLoadSample);
{ The busiest processor's busy share since the last call, in percent. }
function BusiestProcessorPercent(var Sample: TProcessorLoadSample): LongWord;

implementation

uses
  Runtime.Memory,
  Kernel.ProcessorTime;

procedure StartLoadSample(out Sample: TProcessorLoadSample);
begin
  ZeroMemory(@Sample, SizeOf(Sample));
  BusiestProcessorPercent(Sample);
end;

function BusiestProcessorPercent(var Sample: TProcessorLoadSample): LongWord;
var
  Index: LongWord;
  Busy: QWord;
  Idle: QWord;
  DeltaBusy: QWord;
  DeltaIdle: QWord;
  Share: LongWord;
begin
  Result := 0;
  Index := 0;
  while (Index < ProcessorTotal) and (Index < MaximumProcessors) do
  begin
    GetProcessorTimes(Index, Busy, Idle);
    DeltaBusy := Busy - Sample.Busy[Index];
    DeltaIdle := Idle - Sample.Idle[Index];
    Sample.Busy[Index] := Busy;
    Sample.Idle[Index] := Idle;
    if DeltaBusy + DeltaIdle > 0 then
    begin
      Share := LongWord(DeltaBusy * 100 div (DeltaBusy + DeltaIdle));
      if Share > Result then
        Result := Share;
    end;
    Inc(Index);
  end;
end;

end.
