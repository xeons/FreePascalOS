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
  The ACPI power test's newer parts, over the same table:
  - Firmware.AcpiWakeDevices: four wake devices (USB by name, network,
    the power button, a lid on a GPE block device), _DSW and _PSW
    told, the power resource turned on;
  - Firmware.AcpiEmbeddedController against a controller played in
    memory (EmbeddedControllerPorts): bytes read and written, a 16-bit
    field, _REG, a query running _Q42, a dead controller timing out; AML
    reading a zone's temperature from it through the EmbeddedControl
    space;
  - Firmware.AcpiThermal's active trip points and Firmware.AcpiFans (a
    fan by _FSL, one by its power resource);
  - Firmware.AcpiProcessorControl: _OSC and _PDC told, _PSS/_PCT/_PPC,
    _MAT (local APIC and x2APIC entries).
}
unit AcpiPowerDeviceTests;

{$mode objfpc}
{$pointermath on}

interface

var
  DeviceFailures: Integer = 0;

{ The host's read and write of the EmbeddedControl space (the played
  controller); False for other spaces. }
function ReadControllerSpace(Address: QWord; Width: Byte; out Value: QWord): Boolean;
function WriteControllerSpace(Address: QWord; Width: Byte; Value: QWord): Boolean;
procedure RunDeviceTests;

implementation

uses
  SysUtils,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiDeviceWalk,
  Firmware.AcpiThermal,
  Firmware.AcpiFans,
  Firmware.AcpiWakeDevices,
  Firmware.AcpiEmbeddedController,
  Firmware.AcpiProcessorControl,
  Firmware.AcpiProcessorIdle;

type
  TControllerState = (StateIdle, StateReadAddress, StateWriteAddress, StateWriteValue);

var
  ControllerMemory: array[0..255] of Byte;
  ControllerOutput: Byte;
  ControllerOutputFull: Boolean;
  ControllerState: TControllerState;
  ControllerAddress: Byte;
  PendingQuery: Byte;
  ControllerDead: Boolean;
  Played: TAcpiEmbeddedController;
  PlayedReady: Boolean;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAILED: ', What);
    Inc(DeviceFailures);
  end;
end;

procedure CheckNumber(Actual, Expected: Int64; const What: string);
begin
  Check(Actual = Expected, What + ': ' + IntToStr(Actual) + ' instead of ' + IntToStr(Expected));
end;

{ --- The played controller --------------------------------------------------------- }

function PlayedReadPort(Port: Word): Byte;
begin
  if ControllerDead then
    Exit($FF);
  if Port = $66 then
  begin
    Result := 0;
    if ControllerOutputFull then
      Result := Result or EmbeddedControllerStatusOutputFull;
    if PendingQuery <> 0 then
      Result := Result or EmbeddedControllerStatusEvent;
  end
  else
  begin
    Result := ControllerOutput;
    ControllerOutputFull := False;
  end;
end;

procedure PlayedWritePort(Port: Word; Value: Byte);
begin
  if Port = $66 then
    case Value of
      EmbeddedControllerRead: ControllerState := StateReadAddress;
      EmbeddedControllerWrite: ControllerState := StateWriteAddress;
      EmbeddedControllerQuery:
        begin
          ControllerOutput := PendingQuery;
          ControllerOutputFull := True;
          PendingQuery := 0;
          ControllerState := StateIdle;
        end;
    end
  else
    case ControllerState of
      StateReadAddress:
        begin
          ControllerOutput := ControllerMemory[Value];
          ControllerOutputFull := True;
          ControllerState := StateIdle;
        end;
      StateWriteAddress:
        begin
          ControllerAddress := Value;
          ControllerState := StateWriteValue;
        end;
      StateWriteValue:
        begin
          ControllerMemory[ControllerAddress] := Value;
          ControllerState := StateIdle;
        end;
    end;
end;

procedure PlayedStall;
begin
end;

procedure PreparePlayedController;
begin
  if PlayedReady then
    Exit;
  FindAcpiEmbeddedController(Played);
  Played.Ports.ReadPort := @PlayedReadPort;
  Played.Ports.WritePort := @PlayedWritePort;
  Played.Ports.Stall := @PlayedStall;
  Played.WaitLimit := 1000;
  PlayedReady := True;
end;

function ReadControllerSpace(Address: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  PreparePlayedController;
  Result := ReadEmbeddedControllerSpace(Played, Address, Width, Value);
end;

function WriteControllerSpace(Address: QWord; Width: Byte; Value: QWord): Boolean;
begin
  PreparePlayedController;
  Result := WriteEmbeddedControllerSpace(Played, Address, Width, Value);
end;

{ --- Helpers ---------------------------------------------------------------------------- }

function NamedInteger(Path: PChar): Int64;
begin
  Result := Int64(EvaluateInteger(nil, Path, QWord(-1)));
end;

function FindWake(const Devices: array of TAcpiWakeDevice; Count: Integer; const Path: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if string(PChar(@Devices[Index].Path[0])) = Path then
      Exit(Index);
  WriteLn('FAILED: no wake device ', Path);
  Inc(DeviceFailures);
  Result := -1;
end;

{ --- Wake devices -------------------------------------------------------------------- }

procedure CheckWakeDevices;
var
  Devices: array[0..15] of TAcpiWakeDevice;
  Count: Integer;
  Usb: Integer;
  Network: Integer;
  Button: Integer;
  Lid: Integer;
begin
  Count := ListAcpiWakeDevices(Devices);
  CheckNumber(Count, 4, 'wake devices');
  Usb := FindWake(Devices, Count, '\_SB_.PCI0.XHC_');
  Network := FindWake(Devices, Count, '\_SB_.PCI0.GLAN');
  Button := FindWake(Devices, Count, '\_SB_.PWRB');
  Lid := FindWake(Devices, Count, '\_SB_.LID0');
  if (Usb < 0) or (Network < 0) or (Button < 0) or (Lid < 0) then
    Exit;
  CheckNumber(Devices[Usb].GpeNumber, $6D, 'USB controller''s GPE');
  CheckNumber(Devices[Usb].DeepestSleepState, 3, 'USB controller wakes from S3');
  CheckNumber(Devices[Usb].Kind, AcpiWakeUsb, 'USB controller found by name');
  CheckNumber(Devices[Usb].PowerResourceCount, 1, 'USB controller''s power resource');
  Check(Devices[Usb].IsPciFunction and (Devices[Usb].PciDevice = $14) and (Devices[Usb].PciFunction = 0),
    'USB controller''s PCI address');
  CheckNumber(Devices[Network].Kind, AcpiWakeNetwork, 'network card found by name');
  CheckNumber(Devices[Network].DeepestSleepState, 4, 'network card wakes from S4');
  CheckNumber(Devices[Button].Kind, AcpiWakePowerButton, 'power button by its id');
  CheckNumber(Devices[Button].GpeNumber, $1D, 'power button''s GPE');
  CheckNumber(Devices[Lid].Kind, AcpiWakeLid, 'lid by its id');
  Check(Devices[Lid].GpeOfBlockDevice, 'lid''s GPE is a block device''s');
  CheckNumber(Devices[Lid].GpeNumber, 2, 'lid''s GPE index');
  CheckNumber(WakeKindOfPciClass($0C, $03), AcpiWakeUsb, 'class 0C03 is USB');
  CheckNumber(WakeKindOfPciClass($02, $00), AcpiWakeNetwork, 'class 02 is network');

  Check(ArmAcpiWakeDevice(Devices[Usb], True, 3), 'USB controller armed');
  CheckNumber(NamedInteger('\_SB_.PCI0.XHC_.DSWA'), 1, '_DSW told to enable');
  CheckNumber(NamedInteger('\_SB_.PRW0.STAT'), 1, 'its power resource on');
  Check(ArmAcpiWakeDevice(Devices[Usb], False, 3), 'USB controller disarmed');
  CheckNumber(NamedInteger('\_SB_.PCI0.XHC_.DSWA'), 0, '_DSW told to disable');
  Check(ArmAcpiWakeDevice(Devices[Network], True, 3), 'network card armed');
  CheckNumber(NamedInteger('\_SB_.PCI0.GLAN.PSWA'), 1, '_PSW told to enable');
  Check(not ArmAcpiWakeDevice(Devices[Button], True, 3), 'the button has nothing to tell');
end;

{ --- The embedded controller ------------------------------------------------------------ }

procedure CheckEmbeddedController;
var
  Controller: TAcpiEmbeddedController;
  Value: Byte;
  Wide: QWord;
  Dead: TAcpiEmbeddedController;
begin
  Check(FindAcpiEmbeddedController(Controller), 'embedded controller found');
  CheckNumber(Controller.DataPort, $62, 'its data port');
  CheckNumber(Controller.CommandPort, $66, 'its command port');
  CheckNumber(Controller.GpeNumber, $17, 'its GPE');
  PreparePlayedController;
  ControllerMemory[$10] := 50;
  Check(ReadEmbeddedControllerByte(Played, $10, Value) and (Value = 50), 'a byte read');
  Check(WriteEmbeddedControllerByte(Played, $30, 77) and (ControllerMemory[$30] = 77), 'a byte written');
  ControllerMemory[$21] := $34;
  ControllerMemory[$22] := $12;
  Check(ReadEmbeddedControllerSpace(Played, $21, 16, Wide) and (Wide = $1234), 'two bytes, little endian');
  ConnectEmbeddedControllerRegion(Played, True);
  CheckNumber(NamedInteger('\_SB_.EC0_.ECAV'), 1, '_REG told the space is there');
  CheckNumber(NamedInteger('\_SB_.EC0_.FSPD'), $1234, 'AML reads a 16-bit field from it');
  CheckNumber(NamedInteger('\_TZ_.TZ02._TMP'), 3232, 'a zone reads its temperature from it');
  PendingQuery := $42;
  CheckNumber(QueryEmbeddedController(Played), $42, 'query number');
  CheckNumber(QueryEmbeddedController(Played), 0, 'no second query');
  Check(RunEmbeddedControllerQuery(Played, $42), '_Q42 run');
  CheckNumber(NamedInteger('\_SB_.EC0_.QHIT'), $42, '_Q42 did its work');
  Check(not RunEmbeddedControllerQuery(Played, $43), 'no _Q43');
  Dead := Played;
  Dead.Timeouts := 0;
  ControllerDead := True;
  Check(not ReadEmbeddedControllerByte(Dead, $10, Value), 'a dead controller''s read fails');
  Check(Dead.Timeouts > 0, 'and counts as a timeout');
  ControllerDead := False;
end;

{ --- Active cooling ----------------------------------------------------------------------- }

procedure CheckActiveCooling;
var
  Zones: array[0..7] of TAcpiThermalZone;
  Count: Integer;
  Index: Integer;
  Zone: Integer;
  Percent: LongWord;
begin
  Count := ListAcpiThermalZones(Zones);
  Zone := -1;
  for Index := 0 to Count - 1 do
    if string(PChar(@Zones[Index].Path[0])) = '\_TZ_.TZ02' then
      Zone := Index;
  Check(Zone >= 0, 'the cooled zone is found');
  if Zone < 0 then
    Exit;
  CheckNumber(Zones[Zone].ActiveCount, 2, 'active trip points');
  CheckNumber(Zones[Zone].ActiveDeciKelvin[0], 3332, '_AC0');
  CheckNumber(Zones[Zone].ActiveDeciKelvin[1], 3182, '_AC1');
  CheckNumber(Zones[Zone].ActiveDeviceCount[0], 1, '_AL0''s devices');
  CheckNumber(Zones[Zone].ActiveDeviceCount[1], 1, '_AL1''s devices');
  Check(Zones[Zone].ActiveDevices[0, 0] = LookupText(NamespaceRoot, '\_SB_.FAN0'), '_AL0 is FAN0');
  Check(Zones[Zone].ActiveDevices[1, 0] = LookupText(NamespaceRoot, '\_SB_.FAN1'), '_AL1 is FAN1');
  Check(SetAcpiCoolingDevice(Zones[Zone].ActiveDevices[0, 0], True), 'FAN0 on');
  CheckNumber(ControllerMemory[$20], 100, 'FAN0 at full speed through _FSL');
  Check(SetAcpiCoolingDevice(Zones[Zone].ActiveDevices[0, 0], False), 'FAN0 off');
  CheckNumber(ControllerMemory[$20], 0, 'FAN0 stopped');
  Check(SetAcpiCoolingDevice(Zones[Zone].ActiveDevices[1, 0], True), 'FAN1 on');
  CheckNumber(NamedInteger('\_SB_.PRF1.STAT'), 1, 'FAN1''s power resource on');
  Check(ReadAcpiCoolingSpeed(Zones[Zone].ActiveDevices[1, 0], Percent) and (Percent = 100), 'FAN1 runs');
  Check(SetAcpiCoolingDevice(Zones[Zone].ActiveDevices[1, 0], False), 'FAN1 off');
  Check(ReadAcpiCoolingSpeed(Zones[Zone].ActiveDevices[1, 0], Percent) and (Percent = 0), 'FAN1 stopped');
end;

{ --- Processors -------------------------------------------------------------------------- }

procedure CheckProcessorControl;
const
  Capabilities = $033B;
var
  Nodes: array[0..7] of PAmlNode;
  Count: Integer;
  First: PAmlNode;
  Second: PAmlNode;
  Performance: TAcpiPerformance;
  Value: TAmlValue;
  ApicId: LongWord;
  Enabled: Boolean;
begin
  Count := ListAcpiProcessors(Nodes);
  CheckNumber(Count, 2, 'processor objects');
  First := LookupText(NamespaceRoot, '\_PR_.CPU0');
  Second := LookupText(NamespaceRoot, '\_PR_.CPU1');
  Check((First <> nil) and (Second <> nil), 'both processors found');
  if (First = nil) or (Second = nil) then
    Exit;
  Check(IsAcpiProcessor(First) and IsAcpiProcessor(Second), 'they are processors');
  Check(TellProcessorCapabilities(First, Capabilities) = CapabilitiesByOsc, 'CPU0 told by _OSC');
  if EvaluatePath(nil, '\_PR_.CPU0.OSCB', nil, 0, Value) then
  begin
    Check((Value.Kind = AmlBuffer) and (PLongWord(ValueData(Value))[1] = Capabilities), '_OSC got the capabilities');
    ReleaseValue(Value);
  end;
  Check(TellProcessorCapabilities(Second, Capabilities) = CapabilitiesByPdc, 'CPU1 told by _PDC');
  if EvaluatePath(nil, '\_PR_.CPU1.PDCB', nil, 0, Value) then
  begin
    Check((Value.Kind = AmlBuffer) and (PLongWord(ValueData(Value))[0] = 1) and
      (PLongWord(ValueData(Value))[1] = 1) and (PLongWord(ValueData(Value))[2] = Capabilities),
      '_PDC got revision, count and capabilities');
    ReleaseValue(Value);
  end;
  Check(ReadAcpiPerformance(First, Performance), 'performance states read');
  CheckNumber(Performance.Count, 3, 'performance states');
  CheckNumber(Performance.States[0].FrequencyMegahertz, 2400, 'fastest state');
  CheckNumber(Performance.States[2].FrequencyMegahertz, 800, 'slowest state');
  CheckNumber(Performance.States[1].Control, $1200, 'a state''s control value');
  CheckNumber(Performance.States[1].PowerMilliwatts, 20000, 'a state''s power');
  CheckNumber(Performance.Control.Space, AcpiControlFixedHardware, 'control through fixed hardware');
  CheckNumber(Performance.Control.Address, $199, 'the control register');
  CheckNumber(Performance.FastestAllowed, 1, '_PPC');
  Check(not ReadAcpiPerformance(Second, Performance), 'CPU1 has no performance states');
  Check(AcpiProcessorIsPresent(First) and AcpiProcessorIsPresent(Second), 'both present');
  Check(ReadProcessorInterruptId(First, ApicId, Enabled) and Enabled, 'CPU0''s _MAT');
  CheckNumber(ApicId, 5, 'CPU0''s local APIC id');
  Check(ReadProcessorInterruptId(Second, ApicId, Enabled) and Enabled, 'CPU1''s _MAT');
  CheckNumber(ApicId, 300, 'CPU1''s x2APIC id');
end;

procedure RunDeviceTests;
begin
  CheckWakeDevices;
  CheckEmbeddedController;
  CheckActiveCooling;
  CheckProcessorControl;
end;

end.
