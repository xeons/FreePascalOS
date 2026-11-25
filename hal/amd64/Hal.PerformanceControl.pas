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
  Choosing the processor's clock rate on x86-64.

  - Performance states through the performance control register
    (IA32_PERF_CTL, MSR 199h; Enhanced SpeedStep, CPUID 1 ECX bit 7):
    the value ACPI's _PSS gives a state is written on each processor.
  - Hardware P-states (HWP, CPUID 6 EAX bit 7): turned on once per
    processor (IA32_PM_ENABLE, 770h), they let the processor choose its
    clock itself between a lowest and a highest level the kernel asks
    for (IA32_HWP_REQUEST, 774h), from the range it says it has
    (IA32_HWP_CAPABILITIES, 771h). Its levels are roughly hundreds of
    MHz.
  Each processor has its own registers: the caller runs on the processor
  to change (Power.EveryProcessor). Nothing here is written unless CPUID
  says it is there (a hypervisor would fault the access).
}
unit Hal.PerformanceControl;

{$mode objfpc}

interface

type
  THardwarePStateCapabilities = record
    Highest: Byte;
    Guaranteed: Byte;
    MostEfficient: Byte;
    Lowest: Byte;
  end;

function PerformanceControlIsAvailable: Boolean;
procedure WriteThisProcessorPerformanceControl(Value: LongWord);
function HardwarePStatesAreAvailable: Boolean;
procedure EnableHardwarePStatesOnThisProcessor;
function ReadHardwarePStateCapabilities(out Capabilities: THardwarePStateCapabilities): Boolean;
{ The range the processor chooses in, and how much it should favour
  saving energy (0 performance - 255 energy). }
procedure RequestThisProcessorHardwarePStates(Lowest, Highest, EnergyPreference: Byte);
{ What one level of the hardware's scale is in megahertz (an estimate). }
function HardwarePStateLevelMegahertz: LongWord;

implementation

uses
  Kernel.Arch.Cpu;

const
  CpuidFeatures = 1;
  CpuidThermalPower = 6;
  FeatureSpeedStep = LongWord(1) shl 7;
  FeatureHardwarePStates = LongWord(1) shl 7;
  FeatureHardwareEnergyPreference = LongWord(1) shl 10;
  MsrPerformanceControl = $199;
  MsrPowerManagementEnable = $770;
  MsrHardwarePStateCapabilities = $771;
  MsrHardwarePStateRequest = $774;
  LevelMegahertz = 100;

function PerformanceControlIsAvailable: Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(CpuidFeatures, 0, Registers);
  Result := (Registers.Ecx and FeatureSpeedStep) <> 0;
end;

procedure WriteThisProcessorPerformanceControl(Value: LongWord);
begin
  if PerformanceControlIsAvailable then
    WriteModelSpecificRegister(MsrPerformanceControl,
      (ReadModelSpecificRegister(MsrPerformanceControl) and not QWord($FFFF)) or (Value and $FFFF));
end;

function HardwarePStatesAreAvailable: Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(0, 0, Registers);
  if Registers.Eax < CpuidThermalPower then
    Exit(False);
  ExecuteCpuid(CpuidThermalPower, 0, Registers);
  Result := (Registers.Eax and FeatureHardwarePStates) <> 0;
end;

procedure EnableHardwarePStatesOnThisProcessor;
begin
  if HardwarePStatesAreAvailable then
    WriteModelSpecificRegister(MsrPowerManagementEnable, 1);
end;

function ReadHardwarePStateCapabilities(out Capabilities: THardwarePStateCapabilities): Boolean;
var
  Value: QWord;
begin
  Capabilities.Highest := 0;
  Capabilities.Guaranteed := 0;
  Capabilities.MostEfficient := 0;
  Capabilities.Lowest := 0;
  Result := HardwarePStatesAreAvailable;
  if not Result then
    Exit;
  Value := ReadModelSpecificRegister(MsrHardwarePStateCapabilities);
  Capabilities.Highest := Byte(Value);
  Capabilities.Guaranteed := Byte(Value shr 8);
  Capabilities.MostEfficient := Byte(Value shr 16);
  Capabilities.Lowest := Byte(Value shr 24);
end;

procedure RequestThisProcessorHardwarePStates(Lowest, Highest, EnergyPreference: Byte);
var
  Registers: TCpuidResult;
  Request: QWord;
begin
  if not HardwarePStatesAreAvailable then
    Exit;
  ExecuteCpuid(CpuidThermalPower, 0, Registers);
  { Desired 0: the processor chooses itself within the range. }
  Request := QWord(Lowest) or (QWord(Highest) shl 8);
  if (Registers.Eax and FeatureHardwareEnergyPreference) <> 0 then
    Request := Request or (QWord(EnergyPreference) shl 24);
  WriteModelSpecificRegister(MsrHardwarePStateRequest, Request);
end;

function HardwarePStateLevelMegahertz: LongWord;
begin
  Result := LevelMegahertz;
end;

end.
