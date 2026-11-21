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
  Slowing a processor down when it is too hot, on x86-64: on-demand
  clock modulation (IA32_CLOCK_MODULATION, MSR 19Ah), which stops the
  processor's clock for part of the time, in eighths (CPUID 1 EDX bit
  22, "ACPI": thermal monitor and software controlled clock). It works
  on every processor that has it, whatever its performance states,
  which is why passive cooling uses it (Power.ThermalZones). Each
  processor has its own register: the caller runs on the processor to
  change.
}
unit Hal.ProcessorThrottle;

{$mode objfpc}

interface

{ Whether the processors can be slowed down this way. }
function ProcessorThrottleIsAvailable: Boolean;
{ Lets the executing processor run Percent of the time (100: full
  speed), rounded down to eighths (at least one). }
procedure SetThisProcessorThrottle(Percent: LongWord);

implementation

uses
  Kernel.Arch.Cpu;

const
  ClockModulationRegister = $19A;
  ClockModulationEnable = $10;
  FeatureClockModulation = LongWord(1) shl 22;
  { Reading the register under a hypervisor that does not offer it would
    fault; the feature bit says it is there. }

function ProcessorThrottleIsAvailable: Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(1, 0, Registers);
  Result := (Registers.Edx and FeatureClockModulation) <> 0;
end;

procedure SetThisProcessorThrottle(Percent: LongWord);
var
  Eighths: LongWord;
begin
  if not ProcessorThrottleIsAvailable then
    Exit;
  if Percent >= 100 then
  begin
    WriteModelSpecificRegister(ClockModulationRegister, 0);
    Exit;
  end;
  Eighths := Percent * 8 div 100;
  if Eighths < 1 then
    Eighths := 1;
  { Bits 3:1 hold the duty cycle in eighths, bit 4 enables it. }
  WriteModelSpecificRegister(ClockModulationRegister, ClockModulationEnable or (Eighths shl 1));
end;

end.
