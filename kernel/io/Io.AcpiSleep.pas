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
  ACPI sleep states, and resetting the machine.

  Entering a sleep state: its SLP_TYP values come from \_Sx in the
  namespace; \_PTS (prepare to sleep) is told the state; wake events are
  turned off and the wake status cleared; then the types and SLP_EN go
  into the PM1 control registers and the hardware does the rest.

  Only S5, soft off, is entered: the sleeping states S1 to S4 would need
  the machine brought back afterwards (the processors' state, and every
  device re-initialized after S3), which the kernel cannot do yet, so
  they are refused.

  Resetting tries the FADT's reset register, then the legacy ways.
}
unit Io.AcpiSleep;

{$mode objfpc}

interface

{ True if the namespace offers State. }
function SleepStateIsSupported(State: Integer): Boolean;
{ Enters State; returns only if that failed (or State is not one the
  kernel can enter: only S5). }
function EnterSleepState(State: Integer): Boolean;
procedure ResetMachine;

implementation

uses
  Runtime.Text,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  Hal.Platform,
  Firmware.AmlValues,
  Firmware.AmlInterpreter,
  Firmware.AcpiSleepStates,
  Io.AcpiHardware,
  Io.AcpiNamespace,
  Debug.Output;

const
  SoftOff = 5;
  WaitForPowerOffMilliseconds = 3000;

function SleepStateIsSupported(State: Integer): Boolean;
var
  TypeA: Byte;
  TypeB: Byte;
begin
  if not AcpiNamespaceIsLoaded then
    Exit(False);
  LockAmlInterpreter;
  Result := SleepTypeOf(State, TypeA, TypeB);
  UnlockAmlInterpreter;
end;

procedure Report(Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

{ Tells the firmware the state is coming (\_PTS). }
procedure PrepareToSleep(State: Integer);
var
  Argument: TAmlValue;
  Ignored: TAmlValue;
begin
  Argument := MakeInteger(State);
  if EvaluatePath(nil, '\_PTS', @Argument, 1, Ignored) then
    ReleaseValue(Ignored);
end;

function EnterSleepState(State: Integer): Boolean;
var
  TypeA: Byte;
  TypeB: Byte;
  Number: LongWord;
  Deadline: QWord;
begin
  Result := False;
  if State <> SoftOff then
  begin
    Report('only S5 (soft off) can be entered');
    Exit;
  end;
  if not AcpiNamespaceIsLoaded or not AcpiHardware.Present then
    Exit;
  LockAmlInterpreter;
  if not SleepTypeOf(State, TypeA, TypeB) then
  begin
    UnlockAmlInterpreter;
    Report('the firmware has no S5');
    Exit;
  end;
  PrepareToSleep(State);
  UnlockAmlInterpreter;
  { Nothing may wake it again. }
  WritePm1Enable(0);
  if AcpiHardware.GpeCount > 0 then
    for Number := 0 to AcpiHardware.GpeCount - 1 do
    begin
      EnableGpe(Number, False);
      ClearGpe(Number);
    end;
  ClearPm1Status(Pm1StatusBits);
  Report('entering S5 (soft off)');
  DisableInterrupts;
  WriteSleepControl(TypeA, TypeB);
  { Gone, normally. }
  EnableInterrupts;
  Deadline := ClockTickCount + MillisecondsToTicks(WaitForPowerOffMilliseconds);
  while ClockTickCount < Deadline do
    CpuRelax;
  Report('the machine did not turn off');
end;

procedure ResetMachine;
begin
  if AcpiHardware.CanReset then
  begin
    ResetThroughAcpi;
    Report('reset through the reset register did not work');
  end;
  HalResetMachine;
end;

end.
