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
  Suspend to RAM: the machine sleeps with memory kept, and wakes where
  it was.

  A thread of its own, on the boot processor (the one the firmware
  wakes), with a large stack (it runs AML):
  1. \_PTS(3) and the S3 types (Io.AcpiSleep); the volumes are synced,
     in case the machine does not come back;
  2. every power handler suspends, last stage first (Io.PowerManagement):
     block I/O and the audio framework stop taking work, the drivers
     quiet their hardware;
  3. every other processor freezes (Kernel.ProcessorPower), and the boot
     processor saves its state and writes the sleep registers;
  4. waking, the processors are set up and run again, the wall clock is
     read again, and every power handler resumes, first stage first:
     PCI configuration and MSI-X tables, ACPI (\_WAK), USB, drivers,
     frameworks.

  Programs go on where they were; the time asleep does not count in the
  uptime.
}
unit Processes.Suspend;

{$mode objfpc}

interface

{ Suspends to RAM and returns after waking: 0, or an error code (the
  firmware has no S3, a suspend or shutdown is under way). }
function SuspendToRam: LongInt;
{ CallSuspend: root only. }
function PerformSuspend: Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.Events,
  Kernel.Scheduler,
  Kernel.Threads,
  Kernel.ProcessorPower,
  FileSystem.Files,
  Io.PowerManagement,
  Io.AcpiSleep,
  Processes.Process,
  Processes.Thread,
  Processes.Shutdown,
  Debug.Output;

const
  SuspendStackSize = 256 * 1024;
  SuspendThreadPriority = 20;
  BootProcessorMask = 1;

var
  Busy: PtrUInt;
  Finished: TEvent;
  Outcome: LongInt;

procedure Report(Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('power');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

procedure RunSuspend(Context: Pointer);
var
  Slept: Boolean;
begin
  { Where the firmware will wake the machine. }
  SetThreadAffinity(CurrentThread, BootProcessorMask);
  Outcome := ErrorUnsupported;
  if PrepareSuspendToRam then
  begin
    Report('suspending to RAM');
    SyncAllVolumes;
    SuspendPowerHandlers;
    if FreezeOtherProcessors then
    begin
      Slept := SleepAndWake(@EnterSuspendToRam);
      EnableInterrupts;
      if Slept then
      begin
        ResynchronizeWallClock;
        Report('woke from suspend to RAM');
        Outcome := ErrorNone;
      end
      else
        Report('the machine did not go to sleep');
    end
    else
    begin
      Report('a processor did not freeze; not suspending');
      WakeOtherProcessors;
    end;
    ResumePowerHandlers;
    if Outcome = ErrorNone then
      Report('resumed');
  end;
  SignalEvent(Finished);
end;

function SuspendToRam: LongInt;
begin
  if ShutdownIsInProgress or (AtomicCompareExchange(Busy, 1, 0) <> 0) then
    Exit(ErrorBusy);
  InitializeEvent(Finished, EventKindNotification, False);
  if CreateSystemThread(@RunSuspend, nil, SuspendThreadPriority, 'Suspend', False, SuspendStackSize) = nil then
    Result := ErrorOutOfMemory
  else
  begin
    WaitForEvent(Finished);
    Result := Outcome;
  end;
  AtomicExchange(Busy, 0);
end;

function PerformSuspend: Int64;
var
  Status: LongInt;
begin
  if CurrentProcess^.Credentials.EffectiveUserId <> RootUserId then
    Exit(-Int64(ErrorNotPermitted));
  Status := SuspendToRam;
  if Status <> ErrorNone then
    Exit(-Int64(Status));
  Result := 0;
end;

end.
