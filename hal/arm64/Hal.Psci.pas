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
  The ARM Power State Coordination Interface: the firmware service that
  starts and stops processors and powers the machine off or resets it.
  On the Raspberry Pi 4 it is the ARM Trusted Firmware inside the UEFI
  firmware, called with SMC; under QEMU it is QEMU itself, called with
  HVC (or SMC with an emulated EL3). The FADT's ARM boot flags say which,
  or after a native boot the device tree's psci node ("method").
}
unit Hal.Psci;

{$mode objfpc}

interface

{ Reads the FADT. False if the firmware does not offer PSCI. }
function InitializePsci: Boolean;
function PsciIsAvailable: Boolean;
function PsciUsesHypervisorCall: Boolean;
{ Major and minor version (e.g. $00010001 for 1.1), 0 if unknown. }
function PsciVersion: LongWord;

{ Starts the processor with affinity ProcessorId at physical address
  EntryPoint with Context in X0. True if the firmware accepted. }
function PsciStartProcessor(ProcessorId: QWord; EntryPoint, Context: QWord): Boolean;
{ Suspends this processor in PowerState (a standby state: it returns
  when an interrupt is pending, as WFI does). True if the firmware took
  it; False if it refused (the processor did not sleep). }
function PsciSuspendProcessor(PowerState: LongWord): Boolean;
{ Whether the firmware offers CPU_SUSPEND (PSCI 1.0 PSCI_FEATURES; taken
  as offered by a 0.2 firmware), and whether its power states use the
  extended format (the state type in bit 30 rather than bit 16). }
function PsciOffersProcessorSuspend(out ExtendedStateFormat: Boolean): Boolean;
{ Whether the firmware offers SYSTEM_SUSPEND (suspend to RAM; PSCI 1.0
  PSCI_FEATURES). }
function PsciOffersSystemSuspend: Boolean;
{ Suspends the machine to RAM; every other processor must be off
  (PsciTurnOffThisProcessor). Waking, the boot processor starts at the
  physical address EntryPoint with its MMU off and Context in X0, as
  PsciStartProcessor's processors do. Returns only if the firmware
  refused. }
procedure PsciSuspendSystem(EntryPoint, Context: QWord);
{ CPU_OFF: this processor stops until started again
  (PsciStartProcessor). Returns only if the firmware refused. }
procedure PsciTurnOffThisProcessor;
{ Never return when they work. }
procedure PsciPowerOff;
procedure PsciReset;

implementation

uses
  Firmware.Acpi,
  Firmware.DeviceTreeMachine,
  Kernel.Arch.Cpu,
  Hal.FirmwareTables;

const
  FunctionVersion = $84000000;
  FunctionCpuOn = $C4000003;
  FunctionCpuSuspend = $C4000001;
  FunctionFeatures = $8400000A;
  FeatureExtendedStateFormat = 2;
  VersionOnePointZero = $00010000;
  FunctionSystemOff = $84000008;
  FunctionSystemSuspend = $C400000E;
  FunctionCpuOff = $84000002;
  FunctionSystemReset = $84000009;
  ResultSuccess = 0;
  ResultAlreadyOn = QWord(-4);

  { The FADT's ARM boot architecture flags (offset 129). }
  ArmBootFlagsOffset = 129;
  ArmBootPsciCompliant = 1;
  ArmBootPsciUseHypervisorCall = 2;
  MinimumFadtLength = 131;

var
  Available: Boolean = False;
  UseHypervisorCall: Boolean = False;
  { PSCI 0.1 (a device tree's "arm,psci") names its own. }
  CpuOnFunction: QWord = FunctionCpuOn;

function CallPsci(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;
begin
  if UseHypervisorCall then
    Result := CallFirmwareHypervisor(FunctionId, Argument1, Argument2, Argument3)
  else
    Result := CallFirmwareSecure(FunctionId, Argument1, Argument2, Argument3);
end;

function InitializePsci: Boolean;
var
  Fadt: PAcpiTableHeader;
  Flags: Word;
  Description: TDeviceTreePsci;
begin
  Available := False;
  Fadt := FindFirmwareTable('FACP', 0);
  if (Fadt <> nil) and (Fadt^.Length >= MinimumFadtLength) then
  begin
    Flags := PWord(PByte(Fadt) + ArmBootFlagsOffset)^;
    Available := (Flags and ArmBootPsciCompliant) <> 0;
    UseHypervisorCall := (Flags and ArmBootPsciUseHypervisorCall) <> 0;
  end
  else if FirmwareDeviceTreeIsPresent and DescribeDeviceTreePsci(Description) then
  begin
    Available := True;
    UseHypervisorCall := Description.UseHypervisorCall;
    CpuOnFunction := Description.CpuOnFunction;
  end;
  Result := Available;
end;

function PsciIsAvailable: Boolean;
begin
  Result := Available;
end;

function PsciUsesHypervisorCall: Boolean;
begin
  Result := UseHypervisorCall;
end;

function PsciVersion: LongWord;
begin
  if not Available then
    Exit(0);
  Result := LongWord(CallPsci(FunctionVersion, 0, 0, 0));
end;

function PsciStartProcessor(ProcessorId: QWord; EntryPoint, Context: QWord): Boolean;
var
  Status: QWord;
begin
  if not Available then
    Exit(False);
  Status := CallPsci(CpuOnFunction, ProcessorId, EntryPoint, Context);
  Result := (Status = ResultSuccess) or (Status = ResultAlreadyOn);
end;

function PsciSuspendProcessor(PowerState: LongWord): Boolean;
begin
  if not Available then
    Exit(False);
  { A standby state needs no entry point: the call returns. }
  Result := CallPsci(FunctionCpuSuspend, PowerState, 0, 0) = ResultSuccess;
end;

function PsciOffersProcessorSuspend(out ExtendedStateFormat: Boolean): Boolean;
var
  Features: QWord;
begin
  ExtendedStateFormat := False;
  if not Available or (CpuOnFunction <> FunctionCpuOn) then
    Exit(False);
  if PsciVersion < VersionOnePointZero then
    Exit(PsciVersion <> 0);
  Features := CallPsci(FunctionFeatures, FunctionCpuSuspend, 0, 0);
  { Negative: not supported. }
  if Int64(Features) < 0 then
    Exit(False);
  ExtendedStateFormat := (Features and FeatureExtendedStateFormat) <> 0;
  Result := True;
end;

function PsciOffersSystemSuspend: Boolean;
begin
  if not Available or (CpuOnFunction <> FunctionCpuOn) or (PsciVersion < VersionOnePointZero) then
    Exit(False);
  Result := Int64(CallPsci(FunctionFeatures, FunctionSystemSuspend, 0, 0)) >= 0;
end;

procedure PsciSuspendSystem(EntryPoint, Context: QWord);
begin
  if Available then
    CallPsci(FunctionSystemSuspend, EntryPoint, Context, 0);
end;

procedure PsciTurnOffThisProcessor;
begin
  if Available then
    CallPsci(FunctionCpuOff, 0, 0, 0);
end;

procedure PsciPowerOff;
begin
  if Available then
    CallPsci(FunctionSystemOff, 0, 0, 0);
end;

procedure PsciReset;
begin
  if Available then
    CallPsci(FunctionSystemReset, 0, 0, 0);
end;

end.
