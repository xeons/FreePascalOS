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
  Shutting the system down: powering off, rebooting or halting.

  Asked for by the power button (Io.AcpiEvents), a program
  (CallShutdown, root only) or the kernel debug shell; the first request
  wins. A thread of its own then:
  1. asks every user process to end, and waits for them (a few seconds
     at most);
  2. writes everything cached out (SyncAllVolumes);
  3. writes the closing summaries (disks, keyboards);
  4. powers off through ACPI's S5 (Io.AcpiSleep), resets the machine,
     or halts the processors.
  If powering off fails, it says it is safe to turn the machine off and
  halts.
}
unit Processes.Shutdown;

{$mode objfpc}

interface

type
  TShutdownAction = (PowerActionOff, PowerActionReboot, PowerActionHalt);

{ Starts shutting down; False if a shutdown is already under way (or the
  thread could not be made). }
function RequestShutdown(Action: TShutdownAction): Boolean;
function ShutdownIsInProgress: Boolean;
{ CallShutdown: root only. }
function PerformShutdown(Action: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Atomic,
  Processes.Process,
  Kernel.Arch.Cpu,
  Kernel.Scheduler,
  Hal.Platform,
  FileSystem.Files,
  Drivers.DiskStatistics,
  Io.Startup,
  Io.AcpiSleep,
  Processes.Thread,
  Processes.Termination,
  Debug.Output;

const
  { The exit status processes get (128 + SIGTERM's number). }
  ShutdownExitCode = 143;
  WaitForProcessesMilliseconds = 5000;
  PollMilliseconds = 50;
  ShutdownStackSize = 256 * 1024;
  ShutdownThreadPriority = 20;

var
  Started: PtrUInt;
  RequestedAction: TShutdownAction;

procedure Report(Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('power');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

procedure EndUserProcesses;
var
  Waited: QWord;
begin
  Waited := 0;
  while (TerminateAllUserProcesses(ShutdownExitCode) > 0) and (Waited < WaitForProcessesMilliseconds) do
  begin
    SleepMilliseconds(PollMilliseconds);
    Inc(Waited, PollMilliseconds);
  end;
  if Waited >= WaitForProcessesMilliseconds then
    Report('some processes did not end in time');
end;

procedure HaltForever;
begin
  HalHaltOtherProcessors;
  DisableInterrupts;
  while True do
    HaltProcessor;
end;

procedure RunShutdown(Context: Pointer);
begin
  case RequestedAction of
    PowerActionOff: Report('powering off');
    PowerActionReboot: Report('rebooting');
  else
    Report('halting');
  end;
  EndUserProcesses;
  SyncAllVolumes;
  WriteDiskStatistics;
  WriteKeyboardSummary;
  case RequestedAction of
    PowerActionOff:
      EnterSleepState(5);
    PowerActionReboot:
      ResetMachine;
  end;
  Report('it is now safe to turn the machine off');
  HaltForever;
end;

function RequestShutdown(Action: TShutdownAction): Boolean;
begin
  Result := AtomicCompareExchange(Started, 1, 0) = 0;
  if not Result then
    Exit;
  RequestedAction := Action;
  Result := CreateSystemThread(@RunShutdown, nil, ShutdownThreadPriority, 'Shutdown', False,
    ShutdownStackSize) <> nil;
end;

function ShutdownIsInProgress: Boolean;
begin
  Result := Started <> 0;
end;

function PerformShutdown(Action: QWord): Int64;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  if Process^.Credentials.EffectiveUserId <> RootUserId then
    Exit(-Int64(ErrorNotPermitted));
  case Action of
    ShutdownPowerOff: RequestShutdown(PowerActionOff);
    ShutdownReboot: RequestShutdown(PowerActionReboot);
    ShutdownHalt: RequestShutdown(PowerActionHalt);
  else
    Exit(-Int64(ErrorInvalidArgument));
  end;
  Result := 0;
end;

end.
