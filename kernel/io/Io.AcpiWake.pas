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
  What may wake the machine from suspend to RAM.

  The wake sources are the devices with an ACPI _PRW
  (Firmware.AcpiWakeDevices: buttons, the lid, USB controllers, network
  cards, ...) and the battery backed clock's alarm. By default the
  buttons, the lid and USB controllers wake the machine; network cards
  and the rest do not (waking on the network needs the card set up for
  it, and a busy network would wake the machine over and over).
  CallSetWakeSource changes that, CallSetWakeAlarm sets the alarm (a
  time, once: it is cancelled after the next wake).

  Going to sleep, in three steps:
  - ArmWakeSources (with the interpreter's lock, before \_PTS): each
    enabled device that can wake from the state gets its power
    resources on and _DSW (or _PSW), and its PCI function, where it is
    one, PME enabled (power management capability, PME_Status cleared);
    the alarm is written to the clock;
  - ApplyWakeEnables (interrupts off, right before the sleep types are
    written): every GPE off and cleared but the wake sources', and the
    fixed power button and, with an alarm, the clock's event (RTC_EN)
    enabled;
  - after waking, NoteWakeReason, before the status is cleared, notes
    what woke the machine: the fixed power button, the clock's event
    (or the alarm's own flag), a wake source's GPE; DisarmWakeSources
    then undoes the first step. The runtime GPEs come back with the
    rest of ACPI's enables (Io.AcpiEvents).
  Without ACPI's fixed hardware (AArch64, PSCI SYSTEM_SUSPEND) only the
  alarm is armed, on the PL031 where there is one.
}
unit Io.AcpiWake;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

{ After the namespace is loaded, with the interpreter's lock (or with no
  namespace: the alarm alone). }
procedure InitializeAcpiWake;
function WakeSourceCount: Integer;
function GetWakeSource(Index: Integer; out Source: TAbiWakeSource): Boolean;
function SetWakeSourceEnabled(Index: Integer; Enabled: Boolean): Boolean;
{ The alarm Seconds from now (0: none); an error number or 0. }
function SetWakeAlarm(Seconds: QWord): LongInt;
{ Interpreter's lock held when UsesAcpi. }
procedure ArmWakeSources(TargetState: Byte; UsesAcpi: Boolean);
procedure ApplyWakeEnables;
procedure NoteWakeReason(UsesAcpi: Boolean);
procedure DisarmWakeSources(TargetState: Byte; UsesAcpi: Boolean);
procedure WriteWakeSources;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Runtime.Time,
  Hal.RealTimeClock,
  Kernel.Clock,
  Firmware.AcpiWakeDevices,
  Io.AcpiHardware,
  Io.Pci,
  Debug.Output;

const
  MaximumWakeDevices = 16;
  NoGpe = High(LongWord);
  PciCapabilityPowerManagement = $01;
  PowerControlOffset = 4;
  PowerControlPmeEnable = $0100;
  PowerControlPmeStatus = $8000;

var
  Devices: array[0..MaximumWakeDevices - 1] of TAcpiWakeDevice;
  DeviceEnabled: array[0..MaximumWakeDevices - 1] of Boolean;
  DeviceArmed: array[0..MaximumWakeDevices - 1] of Boolean;
  DeviceWoke: array[0..MaximumWakeDevices - 1] of Boolean;
  DeviceTotal: Integer = 0;
  AlarmEnabled: Boolean = True;
  AlarmTime: TUnixTime = 0;
  AlarmArmed: Boolean = False;
  AlarmWoke: Boolean = False;
  PowerButtonWoke: Boolean = False;

function KindOf(constref Device: TAcpiWakeDevice): LongWord;
var
  Pci: PPciDevice;
begin
  Result := Device.Kind;
  if (Result <> AcpiWakeOther) or not Device.IsPciFunction then
    Exit;
  Pci := FindPciFunction(Device.PciSegment, Device.PciBus, Device.PciDevice, Device.PciFunction);
  if Pci <> nil then
    Result := WakeKindOfPciClass(Pci^.ClassCode, Pci^.Subclass);
end;

function EnabledByDefault(Kind: LongWord): Boolean;
begin
  Result := Kind in [AcpiWakePowerButton, AcpiWakeSleepButton, AcpiWakeLid, AcpiWakeUsb];
end;

procedure InitializeAcpiWake;
var
  Index: Integer;
begin
  DeviceTotal := ListAcpiWakeDevices(Devices);
  for Index := 0 to DeviceTotal - 1 do
  begin
    Devices[Index].Kind := KindOf(Devices[Index]);
    DeviceEnabled[Index] := EnabledByDefault(Devices[Index].Kind);
  end;
end;

function WakeSourceCount: Integer;
begin
  Result := DeviceTotal + 1;
end;

function AlarmSecondsLeft: LongWord;
var
  Now: TUnixTime;
begin
  Result := 0;
  if AlarmTime = 0 then
    Exit;
  Now := CurrentWallClockTime;
  if AlarmTime > Now then
    Result := LongWord(AlarmTime - Now);
end;

function GetWakeSource(Index: Integer; out Source: TAbiWakeSource): Boolean;
begin
  ZeroMemory(@Source, SizeOf(Source));
  Result := (Index >= 0) and (Index < WakeSourceCount);
  if not Result then
    Exit;
  if Index = DeviceTotal then
  begin
    CopyText(@Source.Name[0], 'alarm', AbiWakeSourceNameCapacity);
    Source.Kind := WakeSourceAlarm;
    Source.Enabled := Ord(AlarmEnabled);
    Source.GpeNumber := NoGpe;
    Source.DeepestSleepState := 3;
    Source.WokeLast := Ord(AlarmWoke);
    Source.AlarmSeconds := AlarmSecondsLeft;
    Exit;
  end;
  CopyText(@Source.Name[0], @Devices[Index].Path[0], AbiWakeSourceNameCapacity);
  Source.Kind := Devices[Index].Kind;
  Source.Enabled := Ord(DeviceEnabled[Index]);
  Source.GpeNumber := Devices[Index].GpeNumber;
  Source.DeepestSleepState := Devices[Index].DeepestSleepState;
  Source.WokeLast := Ord(DeviceWoke[Index] or ((Devices[Index].Kind = AcpiWakePowerButton) and PowerButtonWoke));
end;

function SetWakeSourceEnabled(Index: Integer; Enabled: Boolean): Boolean;
begin
  Result := (Index >= 0) and (Index < WakeSourceCount);
  if not Result then
    Exit;
  if Index = DeviceTotal then
    AlarmEnabled := Enabled
  else
    DeviceEnabled[Index] := Enabled;
end;

function SetWakeAlarm(Seconds: QWord): LongInt;
const
  LongestAlarmSeconds = 366 * 86400;
begin
  if Seconds = 0 then
  begin
    AlarmTime := 0;
    Exit(ErrorNone);
  end;
  if Seconds > LongestAlarmSeconds then
    Exit(ErrorInvalidArgument);
  { Tried now (and turned off again): whether the clock has an alarm
    that reaches this far. }
  if not SetRealTimeClockAlarm(ReadRealTimeClock + TUnixTime(Seconds)) then
  begin
    if not SetRealTimeClockAlarm(0) then
      Exit(ErrorUnsupported);
    Exit(ErrorInvalidArgument);
  end;
  SetRealTimeClockAlarm(0);
  AlarmTime := CurrentWallClockTime + TUnixTime(Seconds);
  Result := ErrorNone;
end;

{ --- PCI power management events -------------------------------------------- }

procedure SetPowerManagementEvent(constref Device: TAcpiWakeDevice; Enable: Boolean);
var
  Pci: PPciDevice;
  Capability: Word;
  Control: Word;
begin
  if not Device.IsPciFunction then
    Exit;
  Pci := FindPciFunction(Device.PciSegment, Device.PciBus, Device.PciDevice, Device.PciFunction);
  if Pci = nil then
    Exit;
  Capability := FindPciCapability(Pci, PciCapabilityPowerManagement);
  if Capability = 0 then
    Exit;
  Control := PciRead16(Pci, Capability + PowerControlOffset);
  { Writing PME_Status back as 1 clears it. }
  Control := Control or PowerControlPmeStatus;
  if Enable then
    Control := Control or PowerControlPmeEnable
  else
    Control := Control and not PowerControlPmeEnable;
  PciWrite16(Pci, Capability + PowerControlOffset, Control);
end;

{ --- Sleeping and waking -------------------------------------------------------- }

procedure ArmWakeSources(TargetState: Byte; UsesAcpi: Boolean);
var
  Index: Integer;
begin
  AlarmArmed := False;
  if AlarmEnabled and (AlarmTime <> 0) then
  begin
    AlarmArmed := SetRealTimeClockAlarm(ReadRealTimeClock + (AlarmTime - CurrentWallClockTime));
    if not AlarmArmed then
      DebugWriteLine('[acpi] the wake alarm is past or out of reach: not set');
  end;
  if not UsesAcpi then
    Exit;
  for Index := 0 to DeviceTotal - 1 do
  begin
    DeviceArmed[Index] := DeviceEnabled[Index] and (Devices[Index].DeepestSleepState >= TargetState) and
      not Devices[Index].GpeOfBlockDevice and (Devices[Index].GpeNumber < AcpiHardware.GpeCount);
    if not DeviceArmed[Index] then
      Continue;
    ArmAcpiWakeDevice(Devices[Index], True, TargetState);
    SetPowerManagementEvent(Devices[Index], True);
  end;
end;

procedure ApplyWakeEnables;
var
  Number: LongWord;
  Index: Integer;
  Enables: Word;
begin
  if AcpiHardware.GpeCount > 0 then
    for Number := 0 to AcpiHardware.GpeCount - 1 do
    begin
      EnableGpe(Number, False);
      ClearGpe(Number);
    end;
  for Index := 0 to DeviceTotal - 1 do
    if DeviceArmed[Index] then
      EnableGpe(Devices[Index].GpeNumber, True);
  Enables := 0;
  if AcpiHardware.FixedPowerButton then
    Enables := Enables or Pm1PowerButton;
  if AlarmArmed then
    Enables := Enables or Pm1RealTimeClock;
  WritePm1Enable(Enables);
end;

procedure NoteWakeReason(UsesAcpi: Boolean);
var
  Status: Word;
  Index: Integer;
begin
  AlarmWoke := False;
  PowerButtonWoke := False;
  for Index := 0 to DeviceTotal - 1 do
    DeviceWoke[Index] := False;
  if UsesAcpi then
  begin
    Status := ReadPm1Status;
    PowerButtonWoke := (Status and Pm1PowerButton) <> 0;
    AlarmWoke := AlarmArmed and ((Status and Pm1RealTimeClock) <> 0);
    for Index := 0 to DeviceTotal - 1 do
      DeviceWoke[Index] := DeviceArmed[Index] and GpeIsSet(Devices[Index].GpeNumber);
  end;
  if AlarmArmed and RealTimeClockAlarmFired then
    AlarmWoke := True;
end;

procedure WriteWakeReason;
var
  Index: Integer;
  Any: Boolean;
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('woken by');
  Any := False;
  if AlarmWoke then
  begin
    DebugWrite(' the alarm');
    Any := True;
  end;
  if PowerButtonWoke then
  begin
    DebugWrite(' the power button');
    Any := True;
  end;
  for Index := 0 to DeviceTotal - 1 do
    if DeviceWoke[Index] then
    begin
      DebugWrite(' ');
      DebugWrite(@Devices[Index].Path[0]);
      Any := True;
    end;
  if not Any then
    DebugWrite(' something not told (the firmware, or a wake request)');
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure DisarmWakeSources(TargetState: Byte; UsesAcpi: Boolean);
var
  Index: Integer;
begin
  if AlarmArmed then
  begin
    SetRealTimeClockAlarm(0);
    { Once: the alarm that woke the machine is done. }
    AlarmTime := 0;
  end;
  if UsesAcpi then
    for Index := 0 to DeviceTotal - 1 do
    begin
      if not DeviceArmed[Index] then
        Continue;
      ArmAcpiWakeDevice(Devices[Index], False, TargetState);
      SetPowerManagementEvent(Devices[Index], False);
      DeviceArmed[Index] := False;
    end;
  WriteWakeReason;
  AlarmArmed := False;
end;

function KindName(Kind: LongWord): PChar;
begin
  case Kind of
    AcpiWakePowerButton: Result := 'power button';
    AcpiWakeSleepButton: Result := 'sleep button';
    AcpiWakeLid: Result := 'lid';
    AcpiWakeUsb: Result := 'USB';
    AcpiWakeNetwork: Result := 'network';
  else
    Result := 'device';
  end;
end;

procedure WriteWakeSources;
var
  Index: Integer;
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('wake sources: ');
  for Index := 0 to DeviceTotal - 1 do
  begin
    DebugWrite(@Devices[Index].Path[0]);
    DebugWrite(' (');
    DebugWrite(KindName(Devices[Index].Kind));
    DebugWrite(', GPE ');
    DebugWriteDecimal(Devices[Index].GpeNumber);
    DebugWrite(', S');
    DebugWriteDecimal(Devices[Index].DeepestSleepState);
    if not DeviceEnabled[Index] then
      DebugWrite(', off');
    DebugWrite('), ');
  end;
  DebugWriteLine('the alarm');
  DebugEndMessage;
end;

end.
