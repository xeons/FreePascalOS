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
                           were idle (busy under 10 %) must average under
                           LIMIT (5); exits 1 if not, 2 if no processor
                           was idle
}
program PowerStat;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
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

function InterruptRate(const First, Second: TSample; Index: Integer): Double;
var
  Seconds: Double;
begin
  Seconds := ElapsedSeconds(First, Second);
  if Seconds <= 0 then
    Exit(0);
  Result := (Second.Power.Processors[Index].ClockInterrupts - First.Power.Processors[Index].ClockInterrupts) / Seconds;
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

function CheckIdle(Seconds: LongInt; Limit: Double): LongInt;
var
  First: TSample;
  Second: TSample;
  Index: Integer;
  Idle: Integer;
  Total: Double;
  Average: Double;
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
  for Index := 0 to Integer(Second.Power.ProcessorCount) - 1 do
  begin
    if Second.Power.Processors[Index].Online = 0 then
      Continue;
    WriteLn(Format('powerstat: processor %d: busy %d %%, %.1f clock interrupts per second',
      [Index, BusyPercent(First, Second, Index), InterruptRate(First, Second, Index)]));
    if BusyPercent(First, Second, Index) < IdleBusyPercent then
    begin
      Inc(Idle);
      Total := Total + InterruptRate(First, Second, Index);
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
    WriteLn(Format('powerstat: FAIL: %.1f clock interrupts per second per idle processor (limit %.1f)',
      [Average, Limit]));
    Exit(1);
  end;
  WriteLn(Format('powerstat: idle processors take %.1f clock interrupts per second (under %.1f)', [Average, Limit]));
  Result := 0;
end;

var
  First: TSample;
  Second: TSample;
begin
  if (ParamCount >= 1) and (ParamStr(1) = '--check-idle') then
    Halt(CheckIdle(StrToIntDef(ParamStr(2), 3), StrToFloatDef(ParamStr(3), 5)));
  if (ParamCount >= 1) and ((ParamStr(1) = '--help') or (ParamStr(1) = '-h')) then
  begin
    WriteLn('usage: powerstat [--check-idle [SECONDS [LIMIT]]]');
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
  ShowThermalZones;
  ShowBatteries;
end.
