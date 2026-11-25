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
  Host test of what the kernel reads from ACPI about power (make
  acpi-power-test), over a table make-table.py assembles:
    - Firmware.AcpiThermal: both thermal zones found, the first's
      temperature (40 C), trip points and poll period, the second's
      nonsense _TMP refused and its missing trip points;
    - Firmware.AcpiBatteries: three battery slots, one empty; _BIF and
      _BIX read (units, capacities, voltage, texts), _BST (state, rate,
      remaining, voltage; an unknown figure kept as unknown);
    - Firmware.AcpiProcessorIdle: the processor's _CST gives its two
      MWAIT states (hints, types, latencies), not the halt or the port
      state.
  The QEMU machines' DSDTs (tools/AmlTest) have none of these: the
  same calls find nothing there. Prints every failed check and exits
  with 1 if there was one.
}
program AcpiPowerTest;

{$mode objfpc}
{$pointermath on}

uses
  Firmware.AmlHost,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiThermal,
  Firmware.AcpiBatteries,
  Firmware.AcpiProcessorIdle,
  AcpiPowerDeviceTests;

var
  Failures: Integer;

function HostAllocate(ByteCount: PtrUInt): Pointer;
begin
  Result := AllocMem(ByteCount);
end;

procedure HostFree(Block: Pointer);
begin
  FreeMem(Block);
end;

function HostRead(Space: Byte; Address: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  Value := 0;
  Result := (Space = AmlSpaceEmbeddedController) and ReadControllerSpace(Address, Width, Value);
end;

function HostWrite(Space: Byte; Address: QWord; Width: Byte; Value: QWord): Boolean;
begin
  Result := (Space = AmlSpaceEmbeddedController) and WriteControllerSpace(Address, Width, Value);
end;

procedure HostSleep(Milliseconds: QWord);
begin
end;

procedure HostStall(Microseconds: QWord);
begin
end;

function HostTimer: QWord;
begin
  Result := 0;
end;

procedure HostLog(Text: PChar);
begin
  WriteLn('log: ', Text);
end;

procedure SetUpHost;
begin
  AmlHost.Allocate := @HostAllocate;
  AmlHost.Free := @HostFree;
  AmlHost.ReadSpace := @HostRead;
  AmlHost.WriteSpace := @HostWrite;
  AmlHost.Sleep := @HostSleep;
  AmlHost.Stall := @HostStall;
  AmlHost.Timer := @HostTimer;
  AmlHost.Log := @HostLog;
end;

function ReadTable(FileName: string): PByte;
var
  TableFile: File;
  Size: Int64;
begin
  Assign(TableFile, FileName);
  Reset(TableFile, 1);
  Size := FileSize(TableFile);
  Result := GetMem(Size);
  BlockRead(TableFile, Result^, Size);
  Close(TableFile);
end;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAILED: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: Int64; const What: string);
begin
  if Actual <> Expected then
  begin
    WriteLn('FAILED: ', What, ': ', Actual, ' instead of ', Expected);
    Inc(Failures);
  end;
end;

procedure CheckText(Actual: PChar; const Expected, What: string);
begin
  if string(Actual) <> Expected then
  begin
    WriteLn('FAILED: ', What, ': "', Actual, '" instead of "', Expected, '"');
    Inc(Failures);
  end;
end;

{ The namespace lists children newest first: look them up by path. }
procedure SortZones(var Zones: array of TAcpiThermalZone; Count: Integer);
var
  Swap: TAcpiThermalZone;
  Index: Integer;
  Other: Integer;
begin
  for Index := 0 to Count - 2 do
    for Other := Index + 1 to Count - 1 do
      if string(PChar(@Zones[Index].Path[0])) > string(PChar(@Zones[Other].Path[0])) then
      begin
        Swap := Zones[Index];
        Zones[Index] := Zones[Other];
        Zones[Other] := Swap;
      end;
end;

function FindBattery(const Nodes: array of PAmlNode; Count: Integer; const Path: string): PAmlNode;
var
  Index: Integer;
  Battery: TAcpiBattery;
begin
  Result := nil;
  for Index := 0 to Count - 1 do
  begin
    ReadAcpiBattery(Nodes[Index], Battery);
    if string(PChar(@Battery.Path[0])) = Path then
      Exit(Nodes[Index]);
  end;
  WriteLn('FAILED: no battery ', Path);
  Inc(Failures);
end;

procedure CheckThermalZones;
var
  Zones: array[0..7] of TAcpiThermalZone;
  Count: Integer;
  DeciKelvin: LongInt;
begin
  Count := ListAcpiThermalZones(Zones);
  CheckNumber(Count, 3, 'thermal zones');
  if Count < 2 then
    Exit;
  SortZones(Zones, Count);
  CheckText(@Zones[0].Path[0], '\_TZ_.TZ00', 'first zone path');
  Check(ReadAcpiZoneTemperature(Zones[0].Node, DeciKelvin), 'first zone read');
  CheckNumber(DeciKelvin, 3132, 'first zone _TMP');
  CheckNumber(DeciKelvinToMilliCelsius(DeciKelvin), 40050, 'first zone in thousandths of a degree');
  CheckNumber(DeciKelvinToMilliCelsius(Zones[0].PassiveDeciKelvin), 80050, 'passive trip point');
  CheckNumber(Zones[0].CriticalDeciKelvin, 3732, 'critical trip point');
  CheckNumber(Zones[0].HotDeciKelvin, 3682, 'hot trip point');
  CheckNumber(Zones[0].PollDeciseconds, 50, 'poll period');
  CheckText(@Zones[1].Path[0], '\_TZ_.TZ01', 'second zone path');
  Check(not ReadAcpiZoneTemperature(Zones[1].Node, DeciKelvin), 'nonsense _TMP refused');
  CheckNumber(Zones[1].PassiveDeciKelvin, AcpiNoTemperature, 'second zone has no passive point');
  CheckNumber(Zones[1].CriticalDeciKelvin, AcpiNoTemperature, 'second zone has no critical point');
  CheckNumber(Zones[1].PollDeciseconds, 0, 'second zone poll period');
end;

procedure CheckBatteries;
var
  Nodes: array[0..7] of PAmlNode;
  Count: Integer;
  Battery: TAcpiBattery;
begin
  Count := ListAcpiBatteries(Nodes);
  CheckNumber(Count, 3, 'battery slots');
  if Count < 3 then
    Exit;
  ReadAcpiBattery(FindBattery(Nodes, Count, '\_SB_.BAT0'), Battery);
  CheckText(@Battery.Path[0], '\_SB_.BAT0', 'first battery path');
  Check(Battery.Present and Battery.HasInformation and Battery.HasStatus, 'first battery read whole');
  CheckNumber(Battery.PowerUnit, 0, 'first battery unit (mWh)');
  CheckNumber(Battery.DesignCapacity, 5000, 'design capacity');
  CheckNumber(Battery.LastFullCapacity, 4000, 'last full charge');
  CheckNumber(Battery.DesignVoltage, 11100, 'design voltage');
  CheckText(@Battery.Model[0], 'TestCell 4000', '_BIF model');
  CheckText(@Battery.Serial[0], 'SN0042', '_BIF serial number');
  CheckText(@Battery.BatteryType[0], 'LION', '_BIF type');
  CheckText(@Battery.Maker[0], 'FPOS Power', '_BIF maker');
  CheckNumber(Battery.State, 1, '_BST state (discharging)');
  CheckNumber(Battery.PresentRate, 1500, '_BST rate');
  CheckNumber(Battery.RemainingCapacity, 2500, '_BST remaining');
  CheckNumber(Battery.PresentVoltage, 11400, '_BST voltage');

  ReadAcpiBattery(FindBattery(Nodes, Count, '\_SB_.BAT1'), Battery);
  Check(Battery.Present and Battery.HasInformation, 'second battery read');
  CheckNumber(Battery.PowerUnit, 1, '_BIX unit (mAh)');
  CheckNumber(Battery.DesignCapacity, 3000, '_BIX design capacity');
  CheckNumber(Battery.LastFullCapacity, 2900, '_BIX last full charge');
  CheckNumber(Battery.DesignVoltage, 7400, '_BIX design voltage');
  CheckText(@Battery.Model[0], 'Second 3000', '_BIX model');
  CheckText(@Battery.Serial[0], 'SN0007', '_BIX serial number');
  CheckText(@Battery.BatteryType[0], 'LiP', '_BIX type');
  CheckNumber(Battery.State, 2, 'second battery charging');
  CheckNumber(Battery.RemainingCapacity, AcpiBatteryUnknown, 'unknown remaining capacity kept');

  ReadAcpiBattery(FindBattery(Nodes, Count, '\_SB_.BAT2'), Battery);
  Check(not Battery.Present, 'empty slot');
  Check(not Battery.HasInformation and not Battery.HasStatus, 'empty slot not read');
end;

procedure CheckIdleStates;
var
  States: array[0..MaximumAcpiIdleStates - 1] of TAcpiIdleState;
  Count: Integer;
begin
  Count := ReadAcpiIdleStates(States);
  CheckNumber(Count, 3, '_CST MWAIT and port states');
  if Count < 3 then
    Exit;
  CheckNumber(States[0].CStateType, 2, 'first state type');
  CheckNumber(States[0].MonitorWaitHint, $10, 'first state hint');
  CheckNumber(States[0].LatencyMicroseconds, 20, 'first state latency');
  CheckNumber(States[0].PowerMilliwatts, 500, 'first state power');
  CheckNumber(States[1].CStateType, 3, 'second state type');
  CheckNumber(States[1].MonitorWaitHint, $20, 'second state hint');
  CheckNumber(States[1].LatencyMicroseconds, 100, 'second state latency');
  CheckNumber(States[2].Entry, AcpiIdleEntryPortRead, 'third state read from a port');
  CheckNumber(States[2].Port, $414, 'its port');
  CheckNumber(States[2].CStateType, 3, 'its type');
end;

var
  Table: PByte;

begin
  SetUpHost;
  if ParamCount < 1 then
  begin
    WriteLn('usage: AcpiPowerTest <table.aml>');
    Halt(2);
  end;
  Check(InitializeNamespace, 'namespace made');
  Table := ReadTable(ParamStr(1));
  Check(LoadAmlTable(Table), 'table loaded');
  CheckThermalZones;
  CheckBatteries;
  CheckIdleStates;
  RunDeviceTests;
  Failures := Failures + DeviceFailures;
  if Failures > 0 then
  begin
    WriteLn('ACPI POWER TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('ACPI POWER TEST PASSED');
end.
