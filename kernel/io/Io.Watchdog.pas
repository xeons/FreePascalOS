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
  Hardware watchdogs: a timer in the hardware that resets the machine
  unless the kernel tells it, in time, that all is well. A board that
  nobody can reach gets back on its own after a hang or a panic.

  A driver registers its watchdog (RegisterWatchdog) with routines to
  arm it for a number of seconds, pet it (start the count again), stop
  it and, if it can, reset the machine at once. The first one registered
  is used. Drivers: Drivers.Bcm2835Watchdog (the Raspberry Pi's PM
  watchdog), Drivers.I6300EsbWatchdog (Intel 6300ESB; QEMU has one with
  -device i6300esb).

  The policy (StartWatchdogPolicy, once the drivers are in):

    watchdog=SECONDS   arm it for that long (0: not at all); without the
                       option a watchdog whose driver says so (the Pi's)
                       is armed for its default (15 s, the most the Pi's
                       can count), others are left alone
    panicreset=SECONDS after a panic, reset the machine that long after
                       the message (0: never, and the watchdog is stopped
                       so the message stays on the screen); without the
                       option, an armed watchdog is simply no longer
                       petted and resets the machine when it runs out

  While armed it is petted by a kernel timer every third of its timeout,
  from a deferred call: a kernel that no longer runs its timers (stuck
  with interrupts off, or at a high level) gets reset. After a panic
  (interrupts are off) the reset comes either from the watchdog running
  out or, with panicreset, from the panic path itself: it waits, petting
  the watchdog, then resets through the HAL (PSCI SYSTEM_RESET on
  AArch64), and if that returns, through the watchdog at once.

  Io.AcpiSleep's ResetMachine uses ResetThroughWatchdog when the other
  ways did not reset the machine.
}
unit Io.Watchdog;

{$mode objfpc}

interface

type
  TWatchdogRoutines = record
    { Arms (or arms again) for Seconds (at most the device's maximum). }
    Start: procedure(Context: Pointer; Seconds: LongWord);
    { Starts the count again. At dispatch level; also after a panic. }
    Pet: procedure(Context: Pointer);
    Stop: procedure(Context: Pointer);
    { Resets the machine as soon as it can; nil if it cannot. }
    ResetNow: procedure(Context: Pointer);
  end;

  PWatchdogDevice = ^TWatchdogDevice;
  TWatchdogDevice = record
    Routines: TWatchdogRoutines;
    Context: Pointer;
    { "BCM2835 PM watchdog", ... }
    Name: PChar;
    MaximumSeconds: LongWord;
    { Armed without the watchdog option, for DefaultSeconds. }
    ArmByDefault: Boolean;
    DefaultSeconds: LongWord;
  end;

{ Called by drivers while the system starts. The device record is
  copied. }
procedure RegisterWatchdog(constref NewDevice: TWatchdogDevice);
function WatchdogIsPresent: Boolean;
function WatchdogName: PChar;

{ Reads the options, arms the watchdog if they (or its driver) say so,
  and sets the panic path's reset policy. }
procedure StartWatchdogPolicy;

{ Arms the watchdog for Seconds and pets it from then on; False without
  one. }
function ArmWatchdog(Seconds: LongWord): Boolean;
procedure DisarmWatchdog;
function WatchdogIsArmed: Boolean;
function WatchdogTimeoutSeconds: LongWord;
{ How often it has been petted since it was last armed. }
function WatchdogPetCount: QWord;

{ Resets the machine through the watchdog, if it can; returns if not. }
procedure ResetThroughWatchdog;

implementation

uses
  Kernel.Options,
  Kernel.Panic,
  Kernel.Timers,
  Kernel.DeferredCalls,
  Kernel.Arch.Cpu,
  Hal.Platform,
  Debug.Output;

const
  OptionWatchdog = 'watchdog';
  OptionPanicReset = 'panicreset';
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;
  { After the watchdog should have run out, the HAL is tried. }
  ExpiryMarginSeconds = 2;

var
  Device: TWatchdogDevice;
  Present: Boolean;
  Armed: Boolean;
  TimeoutSeconds: LongWord;
  PetIntervalMilliseconds: QWord;
  PetCount: QWord;
  PetTimer: TTimer;
  PetCall: TDeferredCall;
  { The panic policy, decided at start-up. }
  PanicResetSeconds: QWord;
  PanicResetWasAsked: Boolean;
  PanicDelaySeconds: QWord;
  PanicPetsWhileWaiting: Boolean;

procedure PetFromTimer(Context: Pointer); forward;

procedure RegisterWatchdog(constref NewDevice: TWatchdogDevice);
begin
  if Present then
    Exit;
  Device := NewDevice;
  Present := True;
  InitializeTimer(PetTimer);
  InitializeDeferredCall(PetCall, @PetFromTimer, nil);
end;

function WatchdogIsPresent: Boolean;
begin
  Result := Present;
end;

function WatchdogName: PChar;
begin
  if Present then
    Result := Device.Name
  else
    Result := 'none';
end;

procedure PetFromTimer(Context: Pointer);
begin
  if not Armed then
    Exit;
  Device.Routines.Pet(Device.Context);
  Inc(PetCount);
  SetTimer(PetTimer, PetIntervalMilliseconds, PetCall);
end;

function ArmWatchdog(Seconds: LongWord): Boolean;
begin
  Result := False;
  if not Present or (Seconds = 0) then
    Exit;
  if Seconds > Device.MaximumSeconds then
    Seconds := Device.MaximumSeconds;
  CancelTimer(PetTimer);
  TimeoutSeconds := Seconds;
  PetIntervalMilliseconds := QWord(Seconds) * 1000 div 3;
  if PetIntervalMilliseconds = 0 then
    PetIntervalMilliseconds := 300;
  PetCount := 0;
  Device.Routines.Start(Device.Context, Seconds);
  Armed := True;
  SetTimer(PetTimer, PetIntervalMilliseconds, PetCall);
  Result := True;
end;

procedure DisarmWatchdog;
begin
  if not Armed then
    Exit;
  Armed := False;
  CancelTimer(PetTimer);
  Device.Routines.Stop(Device.Context);
end;

function WatchdogIsArmed: Boolean;
begin
  Result := Armed;
end;

function WatchdogTimeoutSeconds: LongWord;
begin
  Result := TimeoutSeconds;
end;

function WatchdogPetCount: QWord;
begin
  Result := PetCount;
end;

procedure ResetThroughWatchdog;
begin
  if Present and Assigned(Device.Routines.ResetNow) then
    Device.Routines.ResetNow(Device.Context);
end;

{ --- After a panic -------------------------------------------------------------- }

procedure AnnouncePanicReset;
begin
  if PanicResetWasAsked then
    PanicDelaySeconds := PanicResetSeconds
  else if Armed then
    PanicDelaySeconds := TimeoutSeconds
  else
    PanicDelaySeconds := 0;
  PanicPetsWhileWaiting := PanicResetWasAsked and Armed;

  if PanicDelaySeconds > 0 then
  begin
    DebugWrite('The machine resets in ');
    DebugWriteDecimal(PanicDelaySeconds);
    if Armed and not PanicResetWasAsked then
      DebugWriteLine(' seconds (the watchdog).')
    else
      DebugWriteLine(' seconds.');
  end
  else if Armed then
  begin
    { panicreset=0: the message stays. }
    Device.Routines.Stop(Device.Context);
    Armed := False;
    DebugWriteLine('The watchdog is stopped; the machine stays halted.');
  end;
end;

procedure WaitSeconds(Seconds: QWord; PetMeanwhile: Boolean);
var
  Deadline: QWord;
  NextPet: QWord;
  Now: QWord;
begin
  Now := HalClockNanoseconds;
  Deadline := Now + Seconds * NanosecondsPerSecond;
  NextPet := Now;
  while Now < Deadline do
  begin
    if PetMeanwhile and (Now >= NextPet) then
    begin
      Device.Routines.Pet(Device.Context);
      NextPet := Now + PetIntervalMilliseconds * 1000 * 1000;
    end;
    CpuRelax;
    Now := HalClockNanoseconds;
  end;
end;

procedure PerformPanicReset;
begin
  if PanicDelaySeconds = 0 then
    Exit;
  if Armed and not PanicResetWasAsked then
    { The watchdog should do it; the HAL after a margin if it did not. }
    WaitSeconds(PanicDelaySeconds + ExpiryMarginSeconds, False)
  else
    WaitSeconds(PanicDelaySeconds, PanicPetsWhileWaiting);
  HalResetMachine;
  ResetThroughWatchdog;
end;

{ --- The policy ----------------------------------------------------------------- }

procedure WriteArmed;
begin
  DebugBeginMessage;
  DebugWriteTag('watchdog');
  DebugWrite(Device.Name);
  DebugWrite(' armed for ');
  DebugWriteDecimal(TimeoutSeconds);
  DebugWrite(' s, petted every ');
  DebugWriteDecimal(PetIntervalMilliseconds);
  DebugWrite(' ms');
  if PanicResetWasAsked then
  begin
    DebugWrite('; resets ');
    DebugWriteDecimal(PanicResetSeconds);
    DebugWriteLine(' s after a panic');
  end
  else
    DebugWriteLine('; resets the machine when it runs out after a panic');
  DebugEndMessage;
end;

procedure StartWatchdogPolicy;
var
  Seconds: QWord;
  WatchdogWasAsked: Boolean;
begin
  PanicResetWasAsked := GetKernelOptionNumber(OptionPanicReset, PanicResetSeconds);
  SetPanicResetRoutines(@AnnouncePanicReset, @PerformPanicReset);

  WatchdogWasAsked := GetKernelOptionNumber(OptionWatchdog, Seconds);
  if not Present then
  begin
    if WatchdogWasAsked and (Seconds > 0) then
    begin
      DebugWriteTag('watchdog');
      DebugWriteLine('the watchdog option is set, but this machine has no watchdog the kernel drives');
    end;
    Exit;
  end;
  if not WatchdogWasAsked then
  begin
    if not Device.ArmByDefault then
      Exit;
    Seconds := Device.DefaultSeconds;
  end;
  if Seconds = 0 then
  begin
    { The firmware may have left it running. }
    Device.Routines.Stop(Device.Context);
    Exit;
  end;
  if Seconds > $FFFFFFFF then
    Seconds := $FFFFFFFF;
  if ArmWatchdog(LongWord(Seconds)) then
    WriteArmed;
end;

end.
