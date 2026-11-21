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
  System calls for power: the processors' idle states, clock interrupts
  and clock rate (CallGetProcessorPower), the thermal zones
  (CallListThermalZones) and the batteries (CallListBatteries). Anyone
  may read them; nothing here runs AML (the batteries are the last
  reading Io.AcpiPower took).
}
unit Processes.PowerCalls;

{$mode objfpc}

interface

function PerformGetProcessorPower(InformationAddress: QWord): Int64;
function PerformListThermalZones(BufferAddress, Capacity: QWord): Int64;
function PerformListBatteries(BufferAddress, Capacity: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Runtime.Memory,
  Hal.Platform,
  Kernel.Clock,
  Kernel.Processors,
  Kernel.ProcessorTime,
  Kernel.IdleStateDefinitions,
  Kernel.IdleStates,
  Firmware.AcpiBatteries,
  Io.AcpiPower,
  Power.Performance,
  Power.ThermalZones,
  Processes.UserAccess;

procedure FillIdleStates(var Information: TAbiProcessorPower);
var
  Index: Integer;
  State: TIdleState;
begin
  Information.IdleStateCount := 0;
  Index := 0;
  while (Index < AbiIdleStateCapacity) and GetIdleState(Index, State) do
  begin
    CopyText(@Information.IdleStates[Index].Name[0], @State.Name[0], AbiIdleStateNameCapacity);
    Information.IdleStates[Index].ExitLatencyNanoseconds := State.ExitLatencyNanoseconds;
    Inc(Information.IdleStateCount);
    Inc(Index);
  end;
end;

procedure FillProcessors(var Information: TAbiProcessorPower);
var
  Index: LongWord;
  Entry: Integer;
  Processor: PProcessor;
  Usage: ^TAbiProcessorPowerUsage;
begin
  Information.ProcessorCount := 0;
  Index := 0;
  while (Index < ProcessorTotal) and (Index < AbiMaximumProcessors) do
  begin
    Processor := ProcessorByIndex(Index);
    Usage := @Information.Processors[Index];
    if (Processor <> nil) and Processor^.IsOnline then
    begin
      Usage^.Online := 1;
      Usage^.ClockInterrupts := Processor^.ClockInterruptCount;
      for Entry := 0 to AbiIdleStateCapacity - 1 do
        if Entry < MaximumIdleStates then
          Usage^.IdleStateEntries[Entry] := Processor^.IdleStateEntries[Entry];
      GetProcessorTimes(Index, Usage^.BusyNanoseconds, Usage^.IdleNanoseconds);
    end;
    Inc(Information.ProcessorCount);
    Inc(Index);
  end;
end;

function PerformGetProcessorPower(InformationAddress: QWord): Int64;
var
  Information: TAbiProcessorPower;
  Report: TProcessorClockReport;
begin
  ZeroMemory(@Information, SizeOf(Information));
  Information.UptimeNanoseconds := ClockNanoseconds;
  FillIdleStates(Information);
  FillProcessors(Information);
  GetProcessorClockReport(Report);
  Information.ClockHertz := Report.ClockHertz;
  Information.MinimumClockHertz := Report.MinimumClockHertz;
  Information.MaximumClockHertz := Report.MaximumClockHertz;
  Information.PerformanceLimitPercent := PerformanceLimitPercent;
  if ClockIsTickless then
    Information.Flags := Information.Flags or ProcessorPowerTickless;
  if Report.Scaling then
    Information.Flags := Information.Flags or ProcessorPowerClockScaling;
  if Information.PerformanceLimitPercent < 100 then
    Information.Flags := Information.Flags or ProcessorPowerThrottled;
  if Report.FanControlled then
    Information.Flags := Information.Flags or ProcessorPowerFanControlled;
  if Report.FanRunning then
    Information.Flags := Information.Flags or ProcessorPowerFanRunning;
  CopyText(@Information.ClockSource[0], HalClockSourceName, SizeOf(Information.ClockSource));
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

function PerformListThermalZones(BufferAddress, Capacity: QWord): Int64;
var
  Index: Integer;
  Zone: TThermalZone;
  Record_: TAbiThermalZone;
  Error: LongInt;
begin
  Index := 0;
  while GetThermalZone(Index, Zone) do
  begin
    if QWord(Index) < Capacity then
    begin
      ZeroMemory(@Record_, SizeOf(Record_));
      CopyText(@Record_.Name[0], @Zone.Name[0], AbiThermalZoneNameCapacity);
      Record_.Kind := Zone.Kind;
      Record_.TemperatureMilliCelsius := Zone.TemperatureMilliCelsius;
      Record_.PassiveMilliCelsius := Zone.PassiveMilliCelsius;
      Record_.CriticalMilliCelsius := Zone.CriticalMilliCelsius;
      Record_.LimitPercent := Zone.LimitPercent;
      Record_.PollMilliseconds := Zone.PollMilliseconds;
      Error := CopyToUser(BufferAddress + QWord(Index) * SizeOf(Record_), @Record_, SizeOf(Record_));
      if Error <> 0 then
        Exit(-Int64(Error));
    end;
    Inc(Index);
  end;
  Result := Index;
end;

function Known(Value: LongWord): LongWord;
begin
  if Value = AcpiBatteryUnknown then
    Result := BatteryValueUnknown
  else
    Result := Value;
end;

procedure DescribeBattery(constref Battery: TAcpiBattery; out Record_: TAbiBattery);
begin
  ZeroMemory(@Record_, SizeOf(Record_));
  CopyText(@Record_.Name[0], @Battery.Path[0], AbiBatteryTextCapacity);
  CopyText(@Record_.Model[0], @Battery.Model[0], AbiBatteryTextCapacity);
  CopyText(@Record_.Serial[0], @Battery.Serial[0], AbiBatteryTextCapacity);
  CopyText(@Record_.Technology[0], @Battery.BatteryType[0], AbiBatteryTextCapacity);
  Record_.Present := Ord(Battery.Present);
  Record_.PowerUnit := Battery.PowerUnit;
  Record_.DesignCapacity := BatteryValueUnknown;
  Record_.FullChargeCapacity := BatteryValueUnknown;
  Record_.RemainingCapacity := BatteryValueUnknown;
  Record_.PresentRate := BatteryValueUnknown;
  Record_.PresentVoltage := BatteryValueUnknown;
  Record_.DesignVoltage := BatteryValueUnknown;
  Record_.Percent := BatteryValueUnknown;
  if Battery.HasInformation then
  begin
    Record_.DesignCapacity := Known(Battery.DesignCapacity);
    Record_.FullChargeCapacity := Known(Battery.LastFullCapacity);
    Record_.DesignVoltage := Known(Battery.DesignVoltage);
  end;
  if Battery.HasStatus then
  begin
    Record_.State := Battery.State;
    Record_.RemainingCapacity := Known(Battery.RemainingCapacity);
    Record_.PresentRate := Known(Battery.PresentRate);
    Record_.PresentVoltage := Known(Battery.PresentVoltage);
  end;
  if (Record_.RemainingCapacity <> BatteryValueUnknown) and (Record_.FullChargeCapacity <> BatteryValueUnknown) and
     (Record_.FullChargeCapacity > 0) then
  begin
    Record_.Percent := LongWord(QWord(Record_.RemainingCapacity) * 100 div Record_.FullChargeCapacity);
    if Record_.Percent > 100 then
      Record_.Percent := 100;
  end;
end;

function PerformListBatteries(BufferAddress, Capacity: QWord): Int64;
var
  Index: Integer;
  Battery: TAcpiBattery;
  Record_: TAbiBattery;
  Error: LongInt;
begin
  Index := 0;
  while GetAcpiBattery(Index, Battery) do
  begin
    if QWord(Index) < Capacity then
    begin
      DescribeBattery(Battery, Record_);
      Error := CopyToUser(BufferAddress + QWord(Index) * SizeOf(Record_), @Record_, SizeOf(Record_));
      if Error <> 0 then
        Exit(-Int64(Error));
    end;
    Inc(Index);
  end;
  Result := Index;
end;

end.
