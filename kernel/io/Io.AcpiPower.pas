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
  What the ACPI namespace says about power: thermal zones, batteries and
  the processors' idle states.

  Once the namespace is loaded a thread ("AcpiPower", with the large
  stack AML needs) reads:
  - the thermal zones (Firmware.AcpiThermal), each registered with the
    thermal policy (Power.ThermalZones) with its passive and critical
    trip points; their _TMP is read by the policy's thread, which has a
    large stack too, under the interpreter's lock;
  - the first processor's _CST (Firmware.AcpiProcessorIdle): MWAIT
    states replace the CPUID ones where the processor may use them
    (Kernel.Arch.IdleStates, Kernel.IdleStates);
  - the batteries (Firmware.AcpiBatteries), then again every 10
    seconds, kept for the system call that lists them
    (CallListBatteries) so that no AML runs on a caller's small stack.
  Machines without these (QEMU's) simply have none; everything here
  copes with their absence.
}
unit Io.AcpiPower;

{$mode objfpc}

interface

uses
  Firmware.AcpiBatteries;

const
  MaximumAcpiBatteries = 4;

{ After the namespace is loaded: starts the thread. }
procedure StartAcpiPower;
function AcpiBatteryCount: Integer;
{ The last reading of battery Index; False past the last. }
function GetAcpiBattery(Index: Integer; out Battery: TAcpiBattery): Boolean;
procedure WriteAcpiPowerSummary;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Scheduler,
  Kernel.IdleStateDefinitions,
  Kernel.IdleStates,
  Kernel.Arch.IdleStates,
  Firmware.AmlNamespace,
  Firmware.AcpiThermal,
  Firmware.AcpiProcessorIdle,
  Io.AcpiNamespace,
  Processes.Thread,
  Power.ThermalZones,
  Debug.Output;

const
  AcpiPowerStackSize = 256 * 1024;
  AcpiPowerPriority = 18;
  BatteryPollMilliseconds = 10000;
  MaximumZones = 8;
  DecisecondsToMilliseconds = 100;

var
  BatteryLock: TSpinLock;
  BatteryNodes: array[0..MaximumAcpiBatteries - 1] of PAmlNode;
  Batteries: array[0..MaximumAcpiBatteries - 1] of TAcpiBattery;
  BatteryTotal: Integer = 0;
  ThermalZoneTotal: Integer = 0;
  FirmwareIdleStateTotal: Integer = 0;

function ReadAcpiZone(Zone: PThermalZone; out MilliCelsius: LongInt): Boolean;
var
  DeciKelvin: LongInt;
begin
  LockAmlInterpreter;
  Result := ReadAcpiZoneTemperature(PAmlNode(Zone^.Context), DeciKelvin);
  UnlockAmlInterpreter;
  if Result then
    MilliCelsius := DeciKelvinToMilliCelsius(DeciKelvin)
  else
    MilliCelsius := NoTripPoint;
end;

function TripMilliCelsius(DeciKelvin: LongInt): LongInt;
begin
  if DeciKelvin = AcpiNoTemperature then
    Result := NoTripPoint
  else
    Result := DeciKelvinToMilliCelsius(DeciKelvin);
end;

procedure RegisterZones;
var
  Found: array[0..MaximumZones - 1] of TAcpiThermalZone;
  Count: Integer;
  Index: Integer;
  Zone: TThermalZone;
begin
  LockAmlInterpreter;
  Count := ListAcpiThermalZones(Found);
  UnlockAmlInterpreter;
  for Index := 0 to Count - 1 do
  begin
    ZeroMemory(@Zone, SizeOf(Zone));
    CopyText(@Zone.Name[0], @Found[Index].Path[0], ThermalZoneNameCapacity);
    Zone.Kind := ThermalZoneAcpi;
    Zone.Read := @ReadAcpiZone;
    Zone.Context := Found[Index].Node;
    Zone.PassiveMilliCelsius := TripMilliCelsius(Found[Index].PassiveDeciKelvin);
    Zone.CriticalMilliCelsius := TripMilliCelsius(Found[Index].CriticalDeciKelvin);
    Zone.PollMilliseconds := Found[Index].PollDeciseconds * DecisecondsToMilliseconds;
    if RegisterThermalZone(Zone) then
      Inc(ThermalZoneTotal);
  end;
end;

procedure TakeFirmwareIdleStates;
var
  Listed: array[0..MaximumAcpiIdleStates - 1] of TAcpiIdleState;
  States: array[0..MaximumAcpiIdleStates - 1] of TIdleState;
  Count: Integer;
  Index: Integer;
begin
  LockAmlInterpreter;
  Count := ReadAcpiIdleStates(Listed);
  UnlockAmlInterpreter;
  FirmwareIdleStateTotal := 0;
  for Index := 0 to Count - 1 do
    if ArchIdleStateFromFirmware(Listed[Index].CStateType, Listed[Index].MonitorWaitHint,
       Listed[Index].LatencyMicroseconds, States[FirmwareIdleStateTotal]) then
      Inc(FirmwareIdleStateTotal);
  if FirmwareIdleStateTotal > 0 then
  begin
    SetFirmwareIdleStates(States, FirmwareIdleStateTotal);
    WriteIdleStates;
  end;
end;

procedure ReadBatteries;
var
  Reading: TAcpiBattery;
  Index: Integer;
  PreviousLevel: TPriorityLevel;
begin
  for Index := 0 to BatteryTotal - 1 do
  begin
    LockAmlInterpreter;
    ReadAcpiBattery(BatteryNodes[Index], Reading);
    UnlockAmlInterpreter;
    PreviousLevel := AcquireSpinLock(BatteryLock);
    Batteries[Index] := Reading;
    ReleaseSpinLock(BatteryLock, PreviousLevel);
  end;
end;

procedure RunAcpiPower(Context: Pointer);
begin
  RegisterZones;
  TakeFirmwareIdleStates;
  LockAmlInterpreter;
  BatteryTotal := ListAcpiBatteries(BatteryNodes);
  UnlockAmlInterpreter;
  ReadBatteries;
  WriteAcpiPowerSummary;
  if BatteryTotal = 0 then
    Exit;
  while True do
  begin
    SleepMilliseconds(BatteryPollMilliseconds);
    ReadBatteries;
  end;
end;

procedure StartAcpiPower;
begin
  if not AcpiNamespaceIsLoaded then
    Exit;
  CreateSystemThread(@RunAcpiPower, nil, AcpiPowerPriority, 'AcpiPower', False, AcpiPowerStackSize);
end;

function AcpiBatteryCount: Integer;
begin
  Result := BatteryTotal;
end;

function GetAcpiBattery(Index: Integer; out Battery: TAcpiBattery): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(BatteryLock);
  Result := (Index >= 0) and (Index < BatteryTotal);
  if Result then
    Battery := Batteries[Index];
  ReleaseSpinLock(BatteryLock, PreviousLevel);
  if not Result then
    ZeroMemory(@Battery, SizeOf(Battery));
end;

procedure WriteBattery(constref Battery: TAcpiBattery);
begin
  DebugBeginMessage;
  DebugWriteTag('battery');
  DebugWrite(@Battery.Path[0]);
  if not Battery.Present then
    DebugWrite(': no battery in the slot')
  else
  begin
    if Battery.Model[0] <> #0 then
    begin
      DebugWrite(' ');
      DebugWrite(@Battery.Model[0]);
    end;
    if Battery.HasStatus and (Battery.RemainingCapacity <> AcpiBatteryUnknown) then
    begin
      DebugWrite(': ');
      DebugWriteDecimal(Battery.RemainingCapacity);
      DebugWrite(' of ');
      DebugWriteDecimal(Battery.LastFullCapacity);
      if Battery.PowerUnit = 0 then
        DebugWrite(' mWh')
      else
        DebugWrite(' mAh');
    end;
    if Battery.HasStatus then
    begin
      if (Battery.State and BatteryCharging) <> 0 then
        DebugWrite(', charging')
      else if (Battery.State and BatteryDischarging) <> 0 then
        DebugWrite(', discharging');
      if (Battery.State and BatteryCritical) <> 0 then
        DebugWrite(', critical');
    end;
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WriteAcpiPowerSummary;
var
  Index: Integer;
  Battery: TAcpiBattery;
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWriteDecimal(ThermalZoneTotal);
  DebugWrite(' thermal zones, ');
  DebugWriteDecimal(BatteryTotal);
  DebugWrite(' batteries, ');
  DebugWriteDecimal(FirmwareIdleStateTotal);
  DebugWriteLine(' idle states from _CST');
  DebugEndMessage;
  for Index := 0 to BatteryTotal - 1 do
    if GetAcpiBattery(Index, Battery) then
      WriteBattery(Battery);
end;

end.
