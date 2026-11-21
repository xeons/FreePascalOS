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
  Abi.SystemCalls;

type
  TThermalZoneArray = array of TAbiThermalZone;
  TBatteryArray = array of TAbiBattery;

function GetProcessorPower(out Information: TAbiProcessorPower): LongInt;
function ListThermalZones: TThermalZoneArray;
function ListBatteries: TBatteryArray;

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

implementation

uses
  SysUtils,
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

end.
