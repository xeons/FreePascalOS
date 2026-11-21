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
  The processor's own protection of the kernel on x86-64, turned on
  where the processor has it (CPUID leaf 7):

    * SMEP (supervisor mode execution prevention): the kernel never runs
      code from a user page, so a jump through a pointer a program
      planted faults instead of running the program's code with the
      kernel's privileges.
    * UMIP (user mode instruction prevention): SGDT, SIDT, SLDT, SMSW
      and STR fault in user mode, so programs cannot read where the
      kernel's descriptor tables are.

  SMAP, the third, is turned on with the user copy routines that open
  its window (Kernel.Arch.UserCopy). The other processors copy the boot
  processor's CR4 when they start and wake (Kernel.Arch.ProcessorStartup),
  which is why this runs before they start.
}
unit Kernel.Arch.ProcessorProtection;

{$mode objfpc}

interface

{ Turns the protections on (boot processor, once). }
procedure EnableProcessorProtection;
{ The same on a processor that started later: there CR4 already came
  from the boot processor, so nothing is left to do. }
procedure EnableProcessorProtectionOnThisProcessor;

function SupervisorExecutionProtectionIsOn: Boolean;
function UserInstructionProtectionIsOn: Boolean;

implementation

uses
  Kernel.Arch.Cpu,
  Debug.Output;

const
  ControlRegister4Umip = QWord(1) shl 11;
  ControlRegister4Smep = QWord(1) shl 20;
  { CPUID leaf 7, subleaf 0: EBX bit 7 (SMEP), ECX bit 2 (UMIP). }
  CpuidSmepBit = LongWord(1) shl 7;
  CpuidUmipBit = LongWord(1) shl 2;

var
  SmepIsOn: Boolean = False;
  UmipIsOn: Boolean = False;

procedure WriteProtectionSummary;
begin
  DebugBeginMessage;
  DebugWriteTag('cpu');
  if SmepIsOn then
    DebugWrite('SMEP on (the kernel never runs user code)')
  else
    DebugWrite('no SMEP');
  if UmipIsOn then
    DebugWriteLine(', UMIP on (descriptor table addresses hidden from programs)')
  else
    DebugWriteLine(', no UMIP');
  DebugEndMessage;
end;

procedure EnableProcessorProtection;
var
  Registers: TCpuidResult;
  ControlBits: QWord;
begin
  ExecuteCpuid(0, 0, Registers);
  if Registers.Eax >= 7 then
  begin
    ExecuteCpuid(7, 0, Registers);
    SmepIsOn := (Registers.Ebx and CpuidSmepBit) <> 0;
    UmipIsOn := (Registers.Ecx and CpuidUmipBit) <> 0;
  end;
  ControlBits := 0;
  if SmepIsOn then
    ControlBits := ControlBits or ControlRegister4Smep;
  if UmipIsOn then
    ControlBits := ControlBits or ControlRegister4Umip;
  if ControlBits <> 0 then
    WriteControlRegister4(ReadControlRegister4 or ControlBits);
  WriteProtectionSummary;
end;

procedure EnableProcessorProtectionOnThisProcessor;
begin
end;

function SupervisorExecutionProtectionIsOn: Boolean;
begin
  Result := SmepIsOn;
end;

function UserInstructionProtectionIsOn: Boolean;
begin
  Result := UmipIsOn;
end;

end.
