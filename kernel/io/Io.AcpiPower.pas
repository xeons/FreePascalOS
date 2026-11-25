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
  What the ACPI namespace says about power: thermal zones and their
  fans, batteries, the processors' idle and performance states, what
  may wake the machine, and processors plugged in.

  Once the namespace is loaded a thread ("AcpiPower", with the large
  stack AML needs) reads:
  - every processor object is told what the kernel can do (_OSC, else
    _PDC: Firmware.AcpiProcessorControl), first;
  - the thermal zones (Firmware.AcpiThermal), each registered with the
    thermal policy (Power.ThermalZones) with its passive, critical and
    active trip points; their _TMP is read by the policy's thread, which
    has a large stack too, under the interpreter's lock, and so are the
    fans of the active trip points switched (Firmware.AcpiFans; each
    device once in Power.Cooling, running while any trip point that
    lists it is reached);
  - the first processor's _CST (Firmware.AcpiProcessorIdle): MWAIT and
    port states replace the CPUID ones where the processor may use them
    (Kernel.Arch.IdleStates, Kernel.IdleStates);
  - its _PSS, _PCT and _PPC: the performance states
    (Power.PerformanceStates), unless the processor has hardware
    P-states;
  - the wake devices (Io.AcpiWake);
  - the batteries (Firmware.AcpiBatteries), then again every 10
    seconds, kept for the system call that lists them
    (CallListBatteries) so that no AML runs on a caller's small stack.
  Then it waits for work the firmware's notifications bring (noted by
  the Notify handler, which may not run AML itself): a processor
  plugged in (Notify 0 or 1 on a processor object: _STA, _MAT, then
  Kernel.SecondaryProcessors.BringUpPluggedProcessor), its _PPC changed
  (0x80) or its _CST (0x81); thermal zones' notifications go to the
  thermal policy (0x80 read now, 0x81 trip points read again).
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
  Kernel.Events,
  Kernel.SecondaryProcessors,
  Firmware.AmlNamespace,
  Firmware.AcpiThermal,
  Firmware.AcpiFans,
  Firmware.AcpiProcessorIdle,
  Firmware.AcpiProcessorControl,
  Io.AcpiNamespace,
  Io.AcpiEvents,
  Io.AcpiWake,
  Processes.Thread,
  Power.Cooling,
  Power.ThermalZones,
  Power.PerformanceStates,
  Debug.Output;

const
  AcpiPowerStackSize = 256 * 1024;
  AcpiPowerPriority = 18;
  BatteryPollMilliseconds = 10000;
  MaximumZones = 8;
  DecisecondsToMilliseconds = 100;
  MaximumPendingProcessors = 8;
  NotifyBusCheck = 0;
  NotifyDeviceCheck = 1;
  NotifyPerformanceChanged = $80;
  NotifyIdleStatesChanged = $81;

var
  BatteryLock: TSpinLock;
  BatteryNodes: array[0..MaximumAcpiBatteries - 1] of PAmlNode;
  Batteries: array[0..MaximumAcpiBatteries - 1] of TAcpiBattery;
  BatteryTotal: Integer = 0;
  ThermalZoneTotal: Integer = 0;
  FirmwareIdleStateTotal: Integer = 0;
  AcpiZones: array[0..MaximumZones - 1] of TAcpiThermalZone;
  AcpiZoneTotal: Integer = 0;
  WorkArrived: TEvent;
  { Noted by the Notify handler for the thread. }
  PendingLock: TSpinLock;
  PendingProcessors: array[0..MaximumPendingProcessors - 1] of PAmlNode;
  PendingProcessorCount: Integer = 0;
  PerformanceChanged: Boolean = False;
  IdleStatesChanged: Boolean = False;
  FirstProcessor: PAmlNode = nil;

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

{ --- Fans ------------------------------------------------------------------------- }

{ Power.Cooling's routine for an ACPI cooling device (the thermal
  thread, large stack). }
function SetAcpiFanSpeed(Context: Pointer; Percent: LongWord): Boolean;
begin
  LockAmlInterpreter;
  Result := SetAcpiCoolingDevice(PAmlNode(Context), Percent > 0);
  UnlockAmlInterpreter;
end;

{ Interpreter's lock held. }
procedure RegisterZoneFans(constref Zone: TAcpiThermalZone);
var
  Level: Integer;
  Index: Integer;
  Device: PAmlNode;
  Path: array[0..63] of Char;
begin
  for Level := 0 to Zone.ActiveCount - 1 do
    for Index := 0 to Zone.ActiveDeviceCount[Level] - 1 do
    begin
      Device := Zone.ActiveDevices[Level, Index];
      if FindCoolingDevice(Device) >= 0 then
        Continue;
      NodePathText(Device, @Path[0], SizeOf(Path));
      RegisterCoolingDevice(@Path[0], CoolingAcpiFan, @SetAcpiFanSpeed, Device);
    end;
end;

{ Whether some ACPI zone wants Device running now: it is listed at the
  zone's active trip point in force or a cooler one. Zone and Level
  say the first that does. }
function DeviceWanted(Device: PAmlNode; out Zone, Level: LongWord): Boolean;
var
  ZoneIndex: Integer;
  Number: Integer;
  Entry: TThermalZone;
  Trip: Integer;
  Index: Integer;
begin
  Result := False;
  Zone := NoCoolingZone;
  Level := NoCoolingZone;
  for ZoneIndex := 0 to AcpiZoneTotal - 1 do
  begin
    Number := FindThermalZone(AcpiZones[ZoneIndex].Node);
    if not GetThermalZone(Number, Entry) or not Entry.ActiveDriven then
      Continue;
    Trip := Integer(Entry.ActiveLevel);
    while Trip < AcpiZones[ZoneIndex].ActiveCount do
    begin
      for Index := 0 to AcpiZones[ZoneIndex].ActiveDeviceCount[Trip] - 1 do
        if (AcpiZones[ZoneIndex].ActiveDevices[Trip, Index] = Device) and not Result then
        begin
          Zone := LongWord(Number);
          Level := LongWord(Trip);
          Result := True;
        end;
      Inc(Trip);
    end;
  end;
end;

{ Power.ThermalZones' active cooling routine: every ACPI fan set by
  what all the zones ask (a fan two zones list runs while either needs
  it). The zone's new level is already in the policy's table. }
procedure SetAcpiZoneActiveLevel(Zone: PThermalZone; Level: LongWord);
var
  Index: Integer;
  Device: TAbiCoolingDevice;
  ZoneNumber: LongWord;
  TripLevel: LongWord;
  Node: PAmlNode;
begin
  Index := 0;
  while GetCoolingDevice(Index, Device) do
  begin
    Node := PAmlNode(CoolingDeviceContext(Index));
    if (Device.Kind = CoolingAcpiFan) and (Node <> nil) then
    begin
      if DeviceWanted(Node, ZoneNumber, TripLevel) then
        SetCoolingDeviceSpeed(Index, 100, ZoneNumber, TripLevel)
      else
        SetCoolingDeviceSpeed(Index, 0, NoCoolingZone, NoCoolingZone);
    end;
    Inc(Index);
  end;
end;

{ Power.ThermalZones' trip point reader for an ACPI zone. }
procedure ReadAcpiZoneTrips(Zone: PThermalZone);
var
  Index: Integer;
  Level: Integer;
begin
  for Index := 0 to AcpiZoneTotal - 1 do
    if AcpiZones[Index].Node = PAmlNode(Zone^.Context) then
    begin
      LockAmlInterpreter;
      ReadAcpiZoneTripPoints(AcpiZones[Index]);
      RegisterZoneFans(AcpiZones[Index]);
      UnlockAmlInterpreter;
      Zone^.PassiveMilliCelsius := TripMilliCelsius(AcpiZones[Index].PassiveDeciKelvin);
      Zone^.CriticalMilliCelsius := TripMilliCelsius(AcpiZones[Index].CriticalDeciKelvin);
      Zone^.ActiveCount := AcpiZones[Index].ActiveCount;
      for Level := 0 to Zone^.ActiveCount - 1 do
        Zone^.ActiveMilliCelsius[Level] := TripMilliCelsius(AcpiZones[Index].ActiveDeciKelvin[Level]);
    end;
end;

procedure RegisterZones;
var
  Count: Integer;
  Index: Integer;
  Level: Integer;
  Zone: TThermalZone;
begin
  LockAmlInterpreter;
  Count := ListAcpiThermalZones(AcpiZones);
  for Index := 0 to Count - 1 do
    RegisterZoneFans(AcpiZones[Index]);
  UnlockAmlInterpreter;
  AcpiZoneTotal := Count;
  for Index := 0 to Count - 1 do
  begin
    ZeroMemory(@Zone, SizeOf(Zone));
    CopyText(@Zone.Name[0], @AcpiZones[Index].Path[0], ThermalZoneNameCapacity);
    Zone.Kind := ThermalZoneAcpi;
    Zone.Read := @ReadAcpiZone;
    Zone.Context := AcpiZones[Index].Node;
    Zone.PassiveMilliCelsius := TripMilliCelsius(AcpiZones[Index].PassiveDeciKelvin);
    Zone.CriticalMilliCelsius := TripMilliCelsius(AcpiZones[Index].CriticalDeciKelvin);
    Zone.PollMilliseconds := AcpiZones[Index].PollDeciseconds * DecisecondsToMilliseconds;
    Zone.ActiveCount := AcpiZones[Index].ActiveCount;
    for Level := 0 to Zone.ActiveCount - 1 do
      Zone.ActiveMilliCelsius[Level] := TripMilliCelsius(AcpiZones[Index].ActiveDeciKelvin[Level]);
    if Zone.ActiveCount > 0 then
      Zone.SetActive := @SetAcpiZoneActiveLevel;
    Zone.ReadTrips := @ReadAcpiZoneTrips;
    if RegisterThermalZone(Zone) then
      Inc(ThermalZoneTotal);
  end;
end;

function EntryParameter(constref State: TAcpiIdleState): LongWord;
begin
  if State.Entry = AcpiIdleEntryPortRead then
    Result := State.Port
  else
    Result := State.MonitorWaitHint;
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
    if ArchIdleStateFromFirmware(Listed[Index].CStateType, Listed[Index].Entry, EntryParameter(Listed[Index]),
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

{ --- Processors ---------------------------------------------------------------------- }

{ _OSC (or _PDC) on every processor object, before their _CST and _PSS
  are read. }
procedure TellProcessors;
var
  Nodes: array[0..MaximumAcpiProcessors - 1] of PAmlNode;
  Count: Integer;
  Index: Integer;
  Capabilities: LongWord;
  ByOsc: Integer;
  ByPdc: Integer;
begin
  Capabilities := ArchProcessorCapabilities;
  if Capabilities = 0 then
    Exit;
  ByOsc := 0;
  ByPdc := 0;
  LockAmlInterpreter;
  Count := ListAcpiProcessors(Nodes);
  for Index := 0 to Count - 1 do
    case TellProcessorCapabilities(Nodes[Index], Capabilities) of
      CapabilitiesByOsc: Inc(ByOsc);
      CapabilitiesByPdc: Inc(ByPdc);
    end;
  UnlockAmlInterpreter;
  if ByOsc + ByPdc = 0 then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('processor capabilities 0x');
  DebugWriteHex(Capabilities, 4);
  DebugWrite(' told by _OSC to ');
  DebugWriteDecimal(ByOsc);
  DebugWrite(', by _PDC to ');
  DebugWriteDecimal(ByPdc);
  DebugWriteLine(' processors');
  DebugEndMessage;
end;

procedure TakePerformanceStates;
var
  Performance: TAcpiPerformance;
  Found: Boolean;
begin
  LockAmlInterpreter;
  FirstProcessor := FirstAcpiProcessor;
  Found := ReadAcpiPerformance(FirstProcessor, Performance);
  UnlockAmlInterpreter;
  if Found then
    UseFirmwarePerformanceStates(Performance);
end;

{ The Notify handler (AML running: only notes the work). }
function NoteNotify(Node: Pointer; Value: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := False;
  if FindThermalZone(Node) >= 0 then
  begin
    NotifyThermalZone(Node, Value);
    Exit(True);
  end;
  if not IsAcpiProcessor(PAmlNode(Node)) then
    Exit;
  Result := True;
  PreviousLevel := AcquireSpinLock(PendingLock);
  case Value of
    NotifyBusCheck, NotifyDeviceCheck:
      if PendingProcessorCount < MaximumPendingProcessors then
      begin
        PendingProcessors[PendingProcessorCount] := PAmlNode(Node);
        Inc(PendingProcessorCount);
      end;
    NotifyPerformanceChanged:
      PerformanceChanged := True;
    NotifyIdleStatesChanged:
      IdleStatesChanged := True;
  else
    Result := False;
  end;
  ReleaseSpinLock(PendingLock, PreviousLevel);
  if Result then
    SignalEvent(WorkArrived);
end;

{ A processor object notified: plugged in if _STA says present and
  _MAT gives an enabled interrupt controller id. }
procedure CheckPluggedProcessor(Node: PAmlNode);
var
  ApicId: LongWord;
  Enabled: Boolean;
  Present: Boolean;
  Known: Boolean;
  Path: array[0..63] of Char;
begin
  LockAmlInterpreter;
  Present := AcpiProcessorIsPresent(Node);
  Known := ReadProcessorInterruptId(Node, ApicId, Enabled);
  NodePathText(Node, @Path[0], SizeOf(Path));
  if Present and Known and Enabled and (ArchProcessorCapabilities <> 0) then
    TellProcessorCapabilities(Node, ArchProcessorCapabilities);
  UnlockAmlInterpreter;
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('processor ');
  DebugWrite(@Path[0]);
  if not Present then
    DebugWriteLine(' checked: not present')
  else if not Known or not Enabled then
    DebugWriteLine(' present, but without an enabled interrupt controller entry (_MAT)')
  else
  begin
    DebugWrite(' present, APIC id ');
    DebugWriteDecimal(ApicId);
    DebugWriteLine('');
  end;
  DebugEndMessage;
  if Present and Known and Enabled then
    BringUpPluggedProcessor(ApicId);
end;

procedure DoPendingWork;
var
  PreviousLevel: TPriorityLevel;
  Node: PAmlNode;
  Performance: Boolean;
  Idle: Boolean;
begin
  repeat
    Node := nil;
    PreviousLevel := AcquireSpinLock(PendingLock);
    if PendingProcessorCount > 0 then
    begin
      Dec(PendingProcessorCount);
      Node := PendingProcessors[PendingProcessorCount];
    end;
    Performance := PerformanceChanged;
    Idle := IdleStatesChanged;
    PerformanceChanged := False;
    IdleStatesChanged := False;
    ReleaseSpinLock(PendingLock, PreviousLevel);
    if Node <> nil then
      CheckPluggedProcessor(Node);
    if Performance and (FirstProcessor <> nil) then
    begin
      LockAmlInterpreter;
      SetFirmwareFastestAllowed(ReadFastestAllowedState(FirstProcessor));
      UnlockAmlInterpreter;
    end;
    if Idle then
      TakeFirmwareIdleStates;
  until Node = nil;
end;

procedure RunAcpiPower(Context: Pointer);
begin
  TellProcessors;
  RegisterZones;
  TakeFirmwareIdleStates;
  TakePerformanceStates;
  LockAmlInterpreter;
  InitializeAcpiWake;
  BatteryTotal := ListAcpiBatteries(BatteryNodes);
  UnlockAmlInterpreter;
  WriteWakeSources;
  ReadBatteries;
  WriteAcpiPowerSummary;
  while True do
  begin
    WaitForEventWithOptions(WorkArrived, BatteryPollMilliseconds, False);
    DoPendingWork;
    if BatteryTotal > 0 then
      ReadBatteries;
  end;
end;

procedure StartAcpiPower;
begin
  if not AcpiNamespaceIsLoaded then
    Exit;
  InitializeEvent(WorkArrived, EventKindSynchronization, False);
  RegisterNotifyHandler(@NoteNotify);
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
