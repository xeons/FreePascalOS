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
  The power summary in the kernel log (the kernel debug shell's
  "power"): each processor's clock interrupts, busy share and idle state
  entries, the board's clock, the thermal zones and the batteries.
}
unit Power.Summary;

{$mode objfpc}

interface

procedure WritePowerSummary;

implementation

uses
  Kernel.Clock,
  Kernel.Processors,
  Kernel.ProcessorTime,
  Kernel.IdleStates,
  Io.AcpiPower,
  Power.BoardClocks,
  Power.ThermalZones,
  Debug.Output;

procedure WriteProcessor(Index: LongWord);
var
  Processor: PProcessor;
  Busy: QWord;
  Idle: QWord;
  State: Integer;
begin
  Processor := ProcessorByIndex(Index);
  if (Processor = nil) or not Processor^.IsOnline then
    Exit;
  GetProcessorTimes(Index, Busy, Idle);
  DebugBeginMessage;
  DebugWriteTag('power');
  DebugWrite('processor ');
  DebugWriteDecimal(Index);
  DebugWrite(': ');
  DebugWriteDecimal(Processor^.ClockInterruptCount);
  DebugWrite(' clock interrupts (');
  DebugWriteDecimal(Processor^.TickInterruptCount);
  DebugWrite(' ticks, ');
  DebugWriteDecimal(Processor^.TimerInterruptCount);
  DebugWrite(' timers, ');
  DebugWriteDecimal(Processor^.WakeUpInterruptCount);
  DebugWrite(' wake-ups), busy ');
  if Busy + Idle > 0 then
    DebugWriteDecimal(Busy * 100 div (Busy + Idle))
  else
    DebugWrite('0');
  DebugWrite(' %, idle entries');
  for State := 0 to IdleStateCount - 1 do
  begin
    DebugWrite(' ');
    DebugWriteDecimal(Processor^.IdleStateEntries[State]);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WritePowerSummary;
var
  Index: LongWord;
begin
  WriteIdleStates;
  Index := 0;
  while Index < ProcessorTotal do
  begin
    WriteProcessor(Index);
    Inc(Index);
  end;
  WriteBoardPowerSummary;
  WriteThermalSummary;
  WriteAcpiPowerSummary;
end;

end.
