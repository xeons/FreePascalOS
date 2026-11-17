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
  HVC (or SMC with an emulated EL3). The FADT's ARM boot flags say which.
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
{ Never return when they work. }
procedure PsciPowerOff;
procedure PsciReset;

implementation

uses
  Firmware.Acpi,
  Kernel.Arch.Cpu,
  Hal.FirmwareTables;

const
  FunctionVersion = $84000000;
  FunctionCpuOn = $C4000003;
  FunctionSystemOff = $84000008;
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
begin
  Available := False;
  Fadt := FindFirmwareTable('FACP', 0);
  if (Fadt <> nil) and (Fadt^.Length >= MinimumFadtLength) then
  begin
    Flags := PWord(PByte(Fadt) + ArmBootFlagsOffset)^;
    Available := (Flags and ArmBootPsciCompliant) <> 0;
    UseHypervisorCall := (Flags and ArmBootPsciUseHypervisorCall) <> 0;
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
  Status := CallPsci(FunctionCpuOn, ProcessorId, EntryPoint, Context);
  Result := (Status = ResultSuccess) or (Status = ResultAlreadyOn);
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
