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

  S5, soft off, ends here. S3, suspend to RAM, is entered in parts, as
  the rest of the kernel brings the machine down and back
  (Processes.Suspend): PrepareSuspendToRam reads the types and runs
  \_PTS(3); EnterSuspendToRam, with every other processor frozen and
  interrupts off, sets the firmware waking vector and writes the
  registers; FinishResumeFromRam, once the processors run again, puts
  the machine back in ACPI mode and runs \_WAK(3). S1, S2 and S4 are not
  entered.

  Without ACPI's fixed hardware (hardware-reduced ACPI, a device tree:
  AArch64) suspend to RAM goes through the HAL instead where it offers
  it (PSCI SYSTEM_SUSPEND): the same three steps without the AML.

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

{ S3. Prepare (AML) before freezing the processors; Enter is a
  Kernel.ProcessorPower sleep routine; Finish after waking. }
function PrepareSuspendToRam: Boolean;
procedure EnterSuspendToRam(WakeVector: QWord);
procedure FinishResumeFromRam;

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
  Io.Watchdog,
  Debug.Output;

const
  SuspendToRam = 3;
  SoftOff = 5;
  WaitForPowerOffMilliseconds = 3000;

var
  { S3's types, read before the processors are frozen. }
  SuspendTypeA: Byte;
  SuspendTypeB: Byte;
  { The HAL suspends (PSCI) rather than ACPI. }
  SuspendThroughHal: Boolean = False;

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
  { Without ACPI's fixed hardware (hardware-reduced ACPI, as on AArch64)
    the firmware powers off (PSCI). }
  if not AcpiNamespaceIsLoaded or not AcpiHardware.Present then
  begin
    HalPowerOff;
    Exit;
  end;
  LockAmlInterpreter;
  if not SleepTypeOf(State, TypeA, TypeB) then
  begin
    UnlockAmlInterpreter;
    Report('the firmware has no S5');
    HalPowerOff;
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

{ --- S3 ---------------------------------------------------------------------- }

function PrepareSuspendToRam: Boolean;
begin
  Result := False;
  SuspendThroughHal := False;
  if not AcpiNamespaceIsLoaded or not AcpiHardware.Present then
  begin
    SuspendThroughHal := HalOffersSuspendToRam;
    if not SuspendThroughHal then
      Report('the firmware offers no suspend to RAM');
    Exit(SuspendThroughHal);
  end;
  LockAmlInterpreter;
  if SleepTypeOf(SuspendToRam, SuspendTypeA, SuspendTypeB) then
  begin
    PrepareToSleep(SuspendToRam);
    Result := True;
  end
  else
    Report('the firmware has no S3');
  UnlockAmlInterpreter;
end;

procedure EnterSuspendToRam(WakeVector: QWord);
begin
  if SuspendThroughHal then
  begin
    { Returns only if the firmware refused. }
    HalEnterSuspendToRam(WakeVector);
    Exit;
  end;
  if not SetFirmwareWakingVector(LongWord(WakeVector)) then
    Exit;
  { The wake status cleared; the power button stays a wake source. }
  ClearPm1Status(Pm1StatusBits);
  WriteSleepControl(SuspendTypeA, SuspendTypeB);
  { The machine sleeps within a moment; waking comes back through the
    waking vector, not here. }
  while True do
    HaltProcessor;
end;

procedure FinishResumeFromRam;
var
  Argument: TAmlValue;
  Ignored: TAmlValue;
begin
  if SuspendThroughHal then
    Exit;
  EnableAcpiMode;
  ClearPm1Status(Pm1StatusBits);
  LockAmlInterpreter;
  Argument := MakeInteger(SuspendToRam);
  if EvaluatePath(nil, '\_WAK', @Argument, 1, Ignored) then
    ReleaseValue(Ignored);
  UnlockAmlInterpreter;
end;

procedure ResetMachine;
begin
  if AcpiHardware.CanReset then
  begin
    ResetThroughAcpi;
    Report('reset through the reset register did not work');
  end;
  HalResetMachine;
  { The firmware did not reset it (or there is none to ask). }
  ResetThroughWatchdog;
end;

end.
