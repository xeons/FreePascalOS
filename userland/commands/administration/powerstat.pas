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
  powerstat: the processors' power, the thermal zones and the batteries.

    powerstat              the clock, the idle states, each processor's
                           clock interrupts per second and busy share
                           over one second, the clock rate, the thermal
                           zones and the batteries
    powerstat --check-idle [SECONDS [LIMIT]]
                           for the tests: over SECONDS (3), the clock
                           interrupts per second of the processors that
                           were idle (busy under 10 %) that no timer or
                           thread's wake-up was due for (the tick, early
                           or longest-wait interrupts) must average under
                           LIMIT (5): with the periodic tick it is 100.
                           Interrupts for due work are shown, not
                           counted (a test machine has pollers: netlog,
                           services). Exits 1 if not, 2 if no processor
                           was idle
    powerstat --wake INDEX on|off
                           lets wake source INDEX (as listed) wake the
                           machine from suspend to RAM, or not (root)
    powerstat --check-wake for the tests: the wake sources are listed with
                           the alarm last, a source past the end is
                           refused, and the alarm can be turned off and
                           on again; exits 1 if not

    powerstat --clock      the kernel's clock and timers only: which
                           counter the clock reads, where the counter's
                           and the local timer's rates came from, the
                           HPET and what wakes processors in deep idle
                           states

  The default listing also shows the clock and timers, the cooling
  devices (fans), the performance states and what may wake the machine
  (and what did last).
    powerstat --check-busy [SECONDS [LIMIT]]
                           for the tests: the dynamic tick. Pins itself
                           to the last processor, spins there in a
                           thread of its own for SECONDS (3) one-second
                           stretches and checks that the processor,
                           busy all the while, took under LIMIT (5)
                           ticks in the quietest of them (100 with the
                           periodic tick; work pinned to the processor
                           now and then brings the tick back for a
                           while, as it should). Exits 1 if not, 2 if
                           there is only one processor
}
program PowerStat;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Threads,
  Sys.Power;

const
  IdleBusyPercent = 10;

type
  TSample = record
    Power: TAbiProcessorPower;
  end;

function TakeSample(out Sample: TSample): Boolean;
begin
  Result := GetProcessorPower(Sample.Power) = 0;
end;

function ElapsedSeconds(const First, Second: TSample): Double;
begin
  Result := (Second.Power.UptimeNanoseconds - First.Power.UptimeNanoseconds) / 1e9;
end;

function BusyPercent(const First, Second: TSample; Index: Integer): LongWord;
var
  Busy: QWord;
  Idle: QWord;
begin
  Busy := Second.Power.Processors[Index].BusyNanoseconds - First.Power.Processors[Index].BusyNanoseconds;
  Idle := Second.Power.Processors[Index].IdleNanoseconds - First.Power.Processors[Index].IdleNanoseconds;
  if Busy + Idle = 0 then
    Result := 0
  else
    Result := Busy * 100 div (Busy + Idle);
end;

function PerSecond(const First, Second: TSample; Earlier, Later: QWord): Double;
var
  Seconds: Double;
begin
  Seconds := ElapsedSeconds(First, Second);
  if Seconds <= 0 then
    Exit(0);
  Result := (Later - Earlier) / Seconds;
end;

{ Clock interrupts that found neither a timer nor a wake-up due. }
function UnexplainedRate(const First, Second: TSample; Index: Integer): Double;
var
  All: QWord;
  ForWork: QWord;
begin
  All := Second.Power.Processors[Index].ClockInterrupts - First.Power.Processors[Index].ClockInterrupts;
  ForWork := (Second.Power.Processors[Index].TimerInterrupts - First.Power.Processors[Index].TimerInterrupts) +
    (Second.Power.Processors[Index].WakeUpInterrupts - First.Power.Processors[Index].WakeUpInterrupts);
  if ForWork > All then
    ForWork := All;
  Result := PerSecond(First, Second, 0, All - ForWork);
end;

function InterruptRate(const First, Second: TSample; Index: Integer): Double;
begin
  Result := PerSecond(First, Second, First.Power.Processors[Index].ClockInterrupts,
    Second.Power.Processors[Index].ClockInterrupts);
end;

{ "ticks 0.0, timers 1.0, wake-ups 0.3" per second. }
function CauseText(const First, Second: TSample; Index: Integer): string;
begin
  Result := Format('ticks %.1f, timers %.1f, wake-ups %.1f',
    [PerSecond(First, Second, First.Power.Processors[Index].TickInterrupts, Second.Power.Processors[Index].TickInterrupts),
     PerSecond(First, Second, First.Power.Processors[Index].TimerInterrupts, Second.Power.Processors[Index].TimerInterrupts),
     PerSecond(First, Second, First.Power.Processors[Index].WakeUpInterrupts,
       Second.Power.Processors[Index].WakeUpInterrupts)]);
end;

procedure ShowProcessors(const First, Second: TSample);
var
  Index: Integer;
  State: Integer;
  Line: string;
begin
  WriteLn('Clock: ', PChar(@Second.Power.ClockSource[0]), BoolToStr((Second.Power.Flags and ProcessorPowerTickless) <> 0,
    ', tickless idle', ', periodic tick'));
  Line := 'Idle states:';
  for State := 0 to Integer(Second.Power.IdleStateCount) - 1 do
  begin
    Line := Line + ' ' + PChar(@Second.Power.IdleStates[State].Name[0]);
    if State > 0 then
      Line := Line + Format(' (%d us)', [Second.Power.IdleStates[State].ExitLatencyNanoseconds div 1000]);
    if State < Integer(Second.Power.IdleStateCount) - 1 then
      Line := Line + ',';
  end;
  WriteLn(Line);
  if ProcessorClockText(Second.Power) <> '' then
    WriteLn('Clock rate: ', ProcessorClockText(Second.Power));
  if (Second.Power.Flags and ProcessorPowerFanControlled) <> 0 then
    WriteLn('Fan: ', BoolToStr((Second.Power.Flags and ProcessorPowerFanRunning) <> 0, 'running', 'stopped'));
  WriteLn('CPU  busy  interrupts/s  idle state entries');
  for Index := 0 to Integer(Second.Power.ProcessorCount) - 1 do
  begin
    if Second.Power.Processors[Index].Online = 0 then
      Continue;
    Line := Format('%3d  %3d%%  %12.1f ', [Index, BusyPercent(First, Second, Index), InterruptRate(First, Second, Index)]);
    for State := 0 to Integer(Second.Power.IdleStateCount) - 1 do
      Line := Line + ' ' + IntToStr(Second.Power.Processors[Index].IdleStateEntries[State]);
    WriteLn(Line);
  end;
end;

procedure ShowClockInformation;
var
  Information: TAbiClockInformation;
  Line: string;
begin
  if GetClockInformation(Information) <> 0 then
    Exit;
  for Line in ClockInformationLines(Information) do
    WriteLn(Line);
end;

procedure ShowThermalZones;
var
  Zones: TThermalZoneArray;
  Index: Integer;
begin
  Zones := ListThermalZones;
  if Length(Zones) = 0 then
  begin
    WriteLn('Thermal zones: none');
    Exit;
  end;
  WriteLn('Thermal zones:');
  for Index := 0 to High(Zones) do
    WriteLn(Format('  %-20s %8s  passive %8s  critical %8s  limit %d %%',
      [PChar(@Zones[Index].Name[0]), MilliCelsiusText(Zones[Index].TemperatureMilliCelsius),
       MilliCelsiusText(Zones[Index].PassiveMilliCelsius), MilliCelsiusText(Zones[Index].CriticalMilliCelsius),
       Zones[Index].LimitPercent]));
end;

function CapacityText(Value, PowerUnit: LongWord): string;
begin
  if Value = BatteryValueUnknown then
    Exit('?');
  if PowerUnit = BatteryUnitPower then
    Result := Format('%d mWh', [Value])
  else
    Result := Format('%d mAh', [Value]);
end;

procedure ShowBatteries;
var
  Batteries: TBatteryArray;
  Index: Integer;
begin
  Batteries := ListBatteries;
  if Length(Batteries) = 0 then
  begin
    WriteLn('Batteries: none');
    Exit;
  end;
  WriteLn('Batteries:');
  for Index := 0 to High(Batteries) do
    with Batteries[Index] do
      WriteLn(Format('  %-20s %-20s %s, %s of %s', [PChar(@Name[0]), PChar(@Model[0]),
        BatteryStateText(Batteries[Index]), CapacityText(RemainingCapacity, PowerUnit),
        CapacityText(FullChargeCapacity, PowerUnit)]));
end;

procedure ShowCoolingDevices;
var
  Devices: TCoolingDeviceArray;
  Index: Integer;
  Line: string;
begin
  Devices := ListCoolingDevices;
  if Length(Devices) = 0 then
    Exit;
  WriteLn('Cooling devices:');
  for Index := 0 to High(Devices) do
  begin
    Line := Format('  %-28s %s', [PChar(@Devices[Index].Name[0]),
      BoolToStr(Devices[Index].Running <> 0, Format('running at %d %%', [Devices[Index].SpeedPercent]), 'stopped')]);
    if Devices[Index].ThermalZone <> High(LongWord) then
      Line := Line + Format(' (zone %d, active trip point %d)', [Devices[Index].ThermalZone, Devices[Index].ActiveLevel]);
    WriteLn(Line);
  end;
end;

procedure ShowPerformanceStates;
var
  States: TPerformanceStateArray;
  Index: Integer;
  Line: string;
begin
  States := ListPerformanceStates;
  if Length(States) = 0 then
    Exit;
  Line := 'Performance states:';
  for Index := 0 to High(States) do
  begin
    Line := Line + Format(' %d MHz', [States[Index].FrequencyMegahertz]);
    if (States[Index].Flags and PerformanceStateCurrent) <> 0 then
      Line := Line + ' (now)';
    if (States[Index].Flags and PerformanceStateNotAllowed) <> 0 then
      Line := Line + ' (not allowed)';
  end;
  WriteLn(Line);
end;

procedure ShowWakeSources;
var
  Sources: TWakeSourceArray;
  Index: Integer;
  Line: string;
begin
  Sources := ListWakeSources;
  if Length(Sources) = 0 then
    Exit;
  WriteLn('Wake sources:');
  for Index := 0 to High(Sources) do
  begin
    Line := Format('  %2d %-28s %-12s %s', [Index, PChar(@Sources[Index].Name[0]),
      WakeSourceKindText(Sources[Index].Kind), BoolToStr(Sources[Index].Enabled <> 0, 'on', 'off')]);
    if Sources[Index].GpeNumber <> High(LongWord) then
      Line := Line + Format(', GPE %d, S%d', [Sources[Index].GpeNumber, Sources[Index].DeepestSleepState]);
    if Sources[Index].AlarmSeconds <> 0 then
      Line := Line + Format(', in %d s', [Sources[Index].AlarmSeconds]);
    if Sources[Index].WokeLast <> 0 then
      Line := Line + ', woke the machine last';
    WriteLn(Line);
  end;
end;

function SetWake(const IndexText, State: string): LongInt;
var
  Status: Int64;
begin
  if (State <> 'on') and (State <> 'off') then
  begin
    WriteLn(StdErr, 'powerstat: --wake takes on or off');
    Exit(2);
  end;
  Status := KernelSetWakeSource(StrToIntDef(IndexText, -1), State = 'on');
  if Status < 0 then
  begin
    WriteLn(StdErr, 'powerstat: cannot change wake source ', IndexText, ' (error ', -Status, ')');
    Exit(1);
  end;
  Result := 0;
end;

function CheckWake: LongInt;
var
  Sources: TWakeSourceArray;
  Alarm: Integer;
begin
  Result := 1;
  Sources := ListWakeSources;
  if Length(Sources) = 0 then
  begin
    WriteLn('powerstat: FAIL: no wake sources (not even the alarm)');
    Exit;
  end;
  Alarm := High(Sources);
  if Sources[Alarm].Kind <> WakeSourceAlarm then
  begin
    WriteLn('powerstat: FAIL: the alarm is not the last wake source');
    Exit;
  end;
  if KernelSetWakeSource(Length(Sources), True) <> -ErrorInvalidArgument then
  begin
    WriteLn('powerstat: FAIL: a wake source past the end was not refused');
    Exit;
  end;
  if (KernelSetWakeSource(Alarm, False) <> 0) or (ListWakeSources[Alarm].Enabled <> 0) or
     (KernelSetWakeSource(Alarm, True) <> 0) or (ListWakeSources[Alarm].Enabled = 0) then
  begin
    WriteLn('powerstat: FAIL: the alarm could not be turned off and on');
    Exit;
  end;
  WriteLn(Format('powerstat: %d wake sources, the alarm last; turned off and on', [Length(Sources)]));
  Result := 0;
end;

function CheckIdle(Seconds: LongInt; Limit: Double): LongInt;
var
  First: TSample;
  Second: TSample;
  Index: Integer;
  Idle: Integer;
  Total: Double;
  Average: Double;
  Causes: string;
begin
  if not TakeSample(First) then
  begin
    WriteLn('powerstat: FAIL: no power information');
    Exit(1);
  end;
  Sleep(Seconds * 1000);
  TakeSample(Second);
  Idle := 0;
  Total := 0;
  Causes := '';
  for Index := 0 to Integer(Second.Power.ProcessorCount) - 1 do
  begin
    if Second.Power.Processors[Index].Online = 0 then
      Continue;
    WriteLn(Format('powerstat: processor %d: busy %d %%, %.1f clock interrupts per second (%s)',
      [Index, BusyPercent(First, Second, Index), InterruptRate(First, Second, Index),
       CauseText(First, Second, Index)]));
    if BusyPercent(First, Second, Index) < IdleBusyPercent then
    begin
      Inc(Idle);
      Total := Total + UnexplainedRate(First, Second, Index);
      Causes := Causes + Format('; %d: %.1f (%s)', [Index, InterruptRate(First, Second, Index),
        CauseText(First, Second, Index)]);
    end;
  end;
  if (Second.Power.Flags and ProcessorPowerTickless) = 0 then
    WriteLn('powerstat: FAIL: the clock is not tickless');
  if Idle = 0 then
  begin
    WriteLn('powerstat: FAIL: no processor was idle');
    Exit(2);
  end;
  Average := Total / Idle;
  if Average >= Limit then
  begin
    WriteLn(Format('powerstat: FAIL: %.1f clock interrupts per second per idle processor with nothing due (limit %.1f)%s',
      [Average, Limit, Causes]));
    Exit(1);
  end;
  WriteLn(Format('powerstat: idle processors take %.1f clock interrupts per second with nothing due (under %.1f)',
    [Average, Limit]));
  Result := 0;
end;

var
  StopSpinning: LongInt = 0;

function Spin(Argument: Pointer): LongInt;
begin
  while InterlockedCompareExchange(StopSpinning, 0, 0) = 0 do
    ;
  Result := 0;
end;

function CheckBusy(Seconds: LongInt; Limit: Double): LongInt;
var
  First: TSample;
  Second: TSample;
  Last: Integer;
  Index: Integer;
  Spinner: Int64;
  ExitCode: LongInt;
  Ticks: Double;
  Rate: Double;
  Stretch: LongInt;
  Busy: LongWord;
begin
  if not TakeSample(First) then
  begin
    WriteLn('powerstat: FAIL: no power information');
    Exit(1);
  end;
  Last := -1;
  for Index := 0 to Integer(First.Power.ProcessorCount) - 1 do
    if First.Power.Processors[Index].Online <> 0 then
      Last := Index;
  if Last < 1 then
  begin
    WriteLn('powerstat: one processor: no dynamic tick to check');
    Exit(2);
  end;
  if KernelSetAffinity(0, QWord(1) shl Last) < 0 then
  begin
    WriteLn('powerstat: FAIL: could not keep to the last processor');
    Exit(1);
  end;
  Spinner := CreateThread(@Spin, nil);
  if Spinner < 0 then
  begin
    WriteLn('powerstat: FAIL: could not start the spinning thread');
    Exit(1);
  end;
  { Let the tick settle, then watch one-second stretches, keeping the
    quietest (this thread sleeps through each). }
  Sleep(500);
  Ticks := 1e9;
  Busy := 100;
  for Stretch := 1 to Seconds do
  begin
    TakeSample(First);
    Sleep(1000);
    TakeSample(Second);
    WriteLn(Format('powerstat: processor %d: busy %d %%, %.1f clock interrupts per second (%s)',
      [Last, BusyPercent(First, Second, Last), InterruptRate(First, Second, Last), CauseText(First, Second, Last)]));
    if BusyPercent(First, Second, Last) < Busy then
      Busy := BusyPercent(First, Second, Last);
    Rate := PerSecond(First, Second, First.Power.Processors[Last].TickInterrupts,
      Second.Power.Processors[Last].TickInterrupts);
    if Rate < Ticks then
      Ticks := Rate;
  end;
  InterlockedExchange(StopSpinning, 1);
  WaitForThread(Spinner, -1, ExitCode);
  CloseThreadHandle(Spinner);
  if Busy < 90 then
  begin
    WriteLn('powerstat: FAIL: the spinning thread did not keep its processor busy');
    Exit(1);
  end;
  if Ticks >= Limit then
  begin
    WriteLn(Format('powerstat: FAIL: a processor running one thread took %.1f ticks per second (limit %.1f)',
      [Ticks, Limit]));
    Exit(1);
  end;
  WriteLn(Format('powerstat: a busy processor running one thread takes %.1f ticks per second (under %.1f)',
    [Ticks, Limit]));
  Result := 0;
end;

var
  First: TSample;
  Second: TSample;
begin
  if (ParamCount >= 1) and (ParamStr(1) = '--check-idle') then
    Halt(CheckIdle(StrToIntDef(ParamStr(2), 3), StrToFloatDef(ParamStr(3), 5)));
  if (ParamCount >= 1) and (ParamStr(1) = '--check-wake') then
    Halt(CheckWake);
  if (ParamCount = 3) and (ParamStr(1) = '--wake') then
    Halt(SetWake(ParamStr(2), ParamStr(3)));
  if (ParamCount >= 1) and (ParamStr(1) = '--check-busy') then
    Halt(CheckBusy(StrToIntDef(ParamStr(2), 3), StrToFloatDef(ParamStr(3), 5)));
  if (ParamCount >= 1) and (ParamStr(1) = '--clock') then
  begin
    ShowClockInformation;
    Halt(0);
  end;
  if (ParamCount >= 1) and ((ParamStr(1) = '--help') or (ParamStr(1) = '-h')) then
  begin
    WriteLn('usage: powerstat [--clock | --check-idle [SECONDS [LIMIT]] | --wake INDEX on|off | --check-wake | --check-busy [SECONDS [LIMIT]]]');
    Halt(0);
  end;
  if not TakeSample(First) then
  begin
    WriteLn(StdErr, 'powerstat: no power information');
    Halt(1);
  end;
  Sleep(1000);
  TakeSample(Second);
  ShowProcessors(First, Second);
  ShowClockInformation;
  ShowPerformanceStates;
  ShowThermalZones;
  ShowCoolingDevices;
  ShowBatteries;
  ShowWakeSources;
end.
