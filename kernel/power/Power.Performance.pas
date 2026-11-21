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
  How fast the processors may run, and what is known about their clock.

  The thermal zones (Power.ThermalZones) ask for a limit in percent of
  full speed; the lowest asked for holds. A limiter carries it out: by
  default clock modulation on every processor (Hal.ProcessorThrottle,
  where the processor has it); on the Raspberry Pi the board's clock
  governor caps the ARM clock instead (Power.BoardClocks registers its
  own limiter). The governor also reports the clock rate and the fan
  here, for the power information call (CallGetProcessorPower).
}
unit Power.Performance;

{$mode objfpc}

interface

type
  { Carries out a limit (percent of full speed). Passive level, from a
    kernel thread. }
  TPerformanceLimiter = procedure(Percent: LongWord);

  TProcessorClockReport = record
    ClockHertz: QWord;
    MinimumClockHertz: QWord;
    MaximumClockHertz: QWord;
    { The governor changes the clock rate. }
    Scaling: Boolean;
    FanControlled: Boolean;
    FanRunning: Boolean;
  end;

procedure SetPerformanceLimiter(Limiter: TPerformanceLimiter);
{ The thermal policy's limit; the limiter is called when it changes. }
procedure SetThermalPerformanceLimit(Percent: LongWord);
function PerformanceLimitPercent: LongWord;

procedure ReportProcessorClock(constref Report: TProcessorClockReport);
procedure GetProcessorClockReport(out Report: TProcessorClockReport);

implementation

uses
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Hal.ProcessorThrottle,
  Power.EveryProcessor,
  Debug.Output;

var
  CurrentLimiter: TPerformanceLimiter = nil;
  LimitPercent: LongWord = 100;
  ReportLock: TSpinLock;
  ClockReport: TProcessorClockReport;

procedure ThrottleThisProcessor(Context: Pointer);
begin
  SetThisProcessorThrottle(PtrUInt(Context));
end;

{ The default limiter: clock modulation, processor by processor. }
procedure ModulateClocks(Percent: LongWord);
begin
  if ProcessorThrottleIsAvailable then
    RunOnEveryProcessor(@ThrottleThisProcessor, Pointer(PtrUInt(Percent)));
end;

procedure SetPerformanceLimiter(Limiter: TPerformanceLimiter);
begin
  CurrentLimiter := Limiter;
end;

procedure SetThermalPerformanceLimit(Percent: LongWord);
begin
  if Percent > 100 then
    Percent := 100;
  if Percent = LimitPercent then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('thermal');
  DebugWrite('processors limited to ');
  DebugWriteDecimal(Percent);
  DebugWriteLine(' % of full speed');
  DebugEndMessage;
  LimitPercent := Percent;
  if Assigned(CurrentLimiter) then
    CurrentLimiter(Percent)
  else
    ModulateClocks(Percent);
end;

function PerformanceLimitPercent: LongWord;
begin
  Result := LimitPercent;
end;

procedure ReportProcessorClock(constref Report: TProcessorClockReport);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(ReportLock);
  ClockReport := Report;
  ReleaseSpinLock(ReportLock, PreviousLevel);
end;

procedure GetProcessorClockReport(out Report: TProcessorClockReport);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(ReportLock);
  Report := ClockReport;
  ReleaseSpinLock(ReportLock, PreviousLevel);
end;

end.
