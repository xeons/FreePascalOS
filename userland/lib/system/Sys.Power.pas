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
  Power as the kernel reports it: the processors' idle states, clock
  interrupts and clock rate (TAbiProcessorPower), the thermal zones and
  the batteries; with the words to show them (power, sysinfo).
}
unit Sys.Power;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls;

type
  TThermalZoneArray = array of TAbiThermalZone;
  TBatteryArray = array of TAbiBattery;
  TWakeSourceArray = array of TAbiWakeSource;
  TCoolingDeviceArray = array of TAbiCoolingDevice;
  TPerformanceStateArray = array of TAbiPerformanceState;

function GetProcessorPower(out Information: TAbiProcessorPower): LongInt;
function ListThermalZones: TThermalZoneArray;
function ListBatteries: TBatteryArray;
function ListWakeSources: TWakeSourceArray;
function ListCoolingDevices: TCoolingDeviceArray;
function ListPerformanceStates: TPerformanceStateArray;
{ "USB", "power button", "alarm", ... }
function WakeSourceKindText(Kind: LongWord): string;

{ "47.5 C", or "-" for ThermalTripNone. }
function MilliCelsiusText(Value: LongInt): string;
{ "2400 MHz", or "-" for 0. }
function HertzText(Hertz: QWord): string;
{ "73 % (discharging)", "charging", "no battery". }
function BatteryStateText(constref Battery: TAbiBattery): string;
{ The processors' clock: "1500 MHz (1500-2400 MHz, scaled)", or '' where
  the machine does not tell it. }
function ProcessorClockText(constref Information: TAbiProcessorPower): string;
{ The hottest zone's temperature, ThermalTripNone without one. }
function HottestTemperature(const Zones: TThermalZoneArray): LongInt;

{ The kernel's clock and timers (CallGetClockInformation): 0 or an
  error number. }
function GetClockInformation(out Information: TAbiClockInformation): LongInt;
{ Them in a few lines: the clock and its counter, the local timer, the
  HPET, the broadcast timer of deep idle states, the watchdog. }
function ClockInformationLines(constref Information: TAbiClockInformation): TStringArray;

implementation

uses
  Sys.Kernel;

const
  MaximumListed = 16;

function GetProcessorPower(out Information: TAbiProcessorPower): LongInt;
var
  Status: Int64;
begin
  FillChar(Information, SizeOf(Information), 0);
  Status := KernelGetProcessorPower(Information);
  if Status < 0 then
    Result := LongInt(-Status)
  else
    Result := 0;
end;

function ListThermalZones: TThermalZoneArray;
var
  Buffer: array[0..MaximumListed - 1] of TAbiThermalZone;
  Count: Int64;
  Index: Integer;
begin
  Result := nil;
  Count := KernelListThermalZones(@Buffer[0], MaximumListed);
  if Count <= 0 then
    Exit;
  if Count > MaximumListed then
    Count := MaximumListed;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Buffer[Index];
end;

function ListBatteries: TBatteryArray;
var
  Buffer: array[0..MaximumListed - 1] of TAbiBattery;
  Count: Int64;
  Index: Integer;
begin
  Result := nil;
  Count := KernelListBatteries(@Buffer[0], MaximumListed);
  if Count <= 0 then
    Exit;
  if Count > MaximumListed then
    Count := MaximumListed;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Buffer[Index];
end;

function ListWakeSources: TWakeSourceArray;
var
  Buffer: array[0..MaximumListed - 1] of TAbiWakeSource;
  Count: Int64;
  Index: Integer;
begin
  Result := nil;
  Count := KernelListWakeSources(@Buffer[0], MaximumListed);
  if Count <= 0 then
    Exit;
  if Count > MaximumListed then
    Count := MaximumListed;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Buffer[Index];
end;

function ListCoolingDevices: TCoolingDeviceArray;
var
  Buffer: array[0..MaximumListed - 1] of TAbiCoolingDevice;
  Count: Int64;
  Index: Integer;
begin
  Result := nil;
  Count := KernelListCoolingDevices(@Buffer[0], MaximumListed);
  if Count <= 0 then
    Exit;
  if Count > MaximumListed then
    Count := MaximumListed;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Buffer[Index];
end;

function ListPerformanceStates: TPerformanceStateArray;
var
  Buffer: array[0..MaximumListed - 1] of TAbiPerformanceState;
  Count: Int64;
  Index: Integer;
begin
  Result := nil;
  Count := KernelListPerformanceStates(@Buffer[0], MaximumListed);
  if Count <= 0 then
    Exit;
  if Count > MaximumListed then
    Count := MaximumListed;
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
    Result[Index] := Buffer[Index];
end;

function WakeSourceKindText(Kind: LongWord): string;
begin
  case Kind of
    WakeSourcePowerButton: Result := 'power button';
    WakeSourceSleepButton: Result := 'sleep button';
    WakeSourceLid: Result := 'lid';
    WakeSourceUsb: Result := 'USB';
    WakeSourceNetwork: Result := 'network';
    WakeSourceAlarm: Result := 'alarm';
  else
    Result := 'device';
  end;
end;

function MilliCelsiusText(Value: LongInt): string;
var
  Magnitude: LongInt;
begin
  if Value = ThermalTripNone then
    Exit('-');
  Magnitude := Abs(Value);
  Result := Format('%d.%d C', [Magnitude div 1000, (Magnitude mod 1000) div 100]);
  if Value < 0 then
    Result := '-' + Result;
end;

function HertzText(Hertz: QWord): string;
begin
  if Hertz = 0 then
    Result := '-'
  else
    Result := Format('%d MHz', [Hertz div 1000000]);
end;

function BatteryStateText(constref Battery: TAbiBattery): string;
begin
  if Battery.Present = 0 then
    Exit('no battery');
  if Battery.Percent <> BatteryValueUnknown then
    Result := Format('%d %%', [Battery.Percent])
  else
    Result := '';
  if (Battery.State and BatteryCharging) <> 0 then
    Result := Trim(Result + ' charging')
  else if (Battery.State and BatteryDischarging) <> 0 then
    Result := Trim(Result + ' discharging');
  if (Battery.State and BatteryCritical) <> 0 then
    Result := Trim(Result + ' critical');
  if Result = '' then
    Result := 'present';
end;

function ProcessorClockText(constref Information: TAbiProcessorPower): string;
begin
  Result := '';
  if Information.ClockHertz = 0 then
    Exit;
  Result := HertzText(Information.ClockHertz);
  if Information.MaximumClockHertz <> 0 then
    Result := Result + Format(' (%d-%d MHz', [Information.MinimumClockHertz div 1000000,
      Information.MaximumClockHertz div 1000000]);
  if (Information.Flags and ProcessorPowerClockScaling) <> 0 then
    Result := Result + ', scaled';
  if Information.MaximumClockHertz <> 0 then
    Result := Result + ')';
  if (Information.Flags and ProcessorPowerThrottled) <> 0 then
    Result := Result + Format(', limited to %d %%', [Information.PerformanceLimitPercent]);
end;

function HottestTemperature(const Zones: TThermalZoneArray): LongInt;
var
  Index: Integer;
begin
  Result := ThermalTripNone;
  for Index := 0 to High(Zones) do
    if (Zones[Index].TemperatureMilliCelsius <> ThermalTripNone) and
       ((Result = ThermalTripNone) or (Zones[Index].TemperatureMilliCelsius > Result)) then
      Result := Zones[Index].TemperatureMilliCelsius;
end;

function GetClockInformation(out Information: TAbiClockInformation): LongInt;
var
  Status: Int64;
begin
  FillChar(Information, SizeOf(Information), 0);
  Status := KernelGetClockInformation(Information);
  if Status < 0 then
    Result := LongInt(-Status)
  else
    Result := 0;
end;

{ "2899.999 MHz" }
function PreciseHertzText(Hertz: QWord): string;
begin
  Result := Format('%d.%.3d MHz', [Hertz div 1000000, (Hertz mod 1000000) div 1000]);
end;

function FlagText(Flags, Flag: LongWord; const Text: string): string;
begin
  if (Flags and Flag) <> 0 then
    Result := Text
  else
    Result := '';
end;

function ClockInformationLines(constref Information: TAbiClockInformation): TStringArray;
var
  Lines: TStringArray;

  procedure Add(const Line: string);
  begin
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := Line;
  end;

var
  Flags: LongWord;
  Line: string;
begin
  Lines := nil;
  Flags := Information.Flags;
  Line := 'Clock source: ' + PChar(@Information.ClockSource[0]) +
    FlagText(Flags, ClockInformationClockForced, ' (chosen by the clocksource option)') +
    FlagText(Flags, ClockInformationClockFellBack, ' (the watchdog moved it from the time stamp counter)');
  if (Flags and ClockInformationClockPageCounter) <> 0 then
    Line := Line + ', programs read the clock page'
  else
    Line := Line + ', programs make the system call';
  Add(Line);
  Line := 'Counter: ' + PreciseHertzText(Information.CounterHertz) + ', rate: ' +
    PChar(@Information.CounterCalibration[0]);
  if Information.CounterMeasuredHertz <> 0 then
    Line := Line + ' (measured ' + PreciseHertzText(Information.CounterMeasuredHertz) + ')';
  Line := Line + FlagText(Flags, ClockInformationCounterInvariant, ', invariant');
  Add(Line);
  Add('Local timer: ' + PreciseHertzText(Information.LocalTimerHertz) + ', rate: ' +
    PChar(@Information.LocalTimerCalibration[0]));
  if (Flags and ClockInformationHpetPresent) <> 0 then
  begin
    Add(Format('HPET: %s (period %d fs), %d-bit counter, %d comparators%s%s at 0x%x',
      [PreciseHertzText((QWord(1000000000000000) + Information.HpetPeriodFemtoseconds div 2) div
        Information.HpetPeriodFemtoseconds), Information.HpetPeriodFemtoseconds, Information.HpetCounterBits,
       Information.HpetComparators,
       FlagText(Flags, ClockInformationHpetLegacyCapable, ', legacy replacement capable'),
       FlagText(Flags, ClockInformationHpetLegacyInUse, ' (in use)'), Information.HpetBaseAddress]));
    if Information.HpetEventComparator >= 0 then
      Add(Format('HPET event timer: comparator %d, %s, %d interrupts',
        [Information.HpetEventComparator, PChar(@Information.HpetRoute[0]), Information.HpetInterrupts]));
  end
  else
    Add('HPET: none');
  Add(Format('Broadcast timer: %s, %d wake-ups', [PChar(@Information.BroadcastTimer[0]), Information.BroadcastWakes]));
  if (Flags and ClockInformationClockWatched) <> 0 then
    Add(Format('Watchdog: %d checks, %d failed, largest drift %d us',
      [Information.WatchdogChecks, Information.WatchdogFailures,
       Information.WatchdogLargestDriftNanoseconds div 1000]))
  else if Information.WatchdogChecks > 0 then
    Add(Format('Watchdog: stopped after %d checks, %d failed', [Information.WatchdogChecks,
      Information.WatchdogFailures]));
  Result := Lines;
end;

end.
