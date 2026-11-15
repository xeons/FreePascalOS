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
  0. if a process watches for shutdowns (CallWatchShutdown: the service
     manager), signals its event and waits for it to end (up to
     ShutdownCoordinatorSeconds), so it can stop the services in the
     reverse of the order they started in;
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
{ CallWatchShutdown: root only; an event handle, or minus an error. }
function PerformWatchShutdown: Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Atomic,
  Kernel.Mutex,
  Kernel.Events,
  Objects.Manager,
  Objects.Events,
  Processes.Handles,
  Processes.UserProcess,
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
  { The process watching for shutdowns and the event it waits on, each
    with a reference of ours; nil for none. Under CoordinatorLock, made
    when first needed. }
  Coordinator: PProcess;
  CoordinatorEvent: PEventObject;
  CoordinatorLock: TMutex;
  CoordinatorLockReady: PtrUInt;

procedure EnsureCoordinatorLock;
begin
  { Only system calls and the shutdown thread get here, all after
    startup; the first one sets the lock up. }
  if AtomicCompareExchange(CoordinatorLockReady, 1, 0) = 0 then
  begin
    InitializeMutex(CoordinatorLock);
    CoordinatorLockReady := 2;
  end;
  while CoordinatorLockReady <> 2 do
    SleepMilliseconds(1);
end;

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

{ The service manager stops the services in order; everything after
  that is ours. A watcher that is gone, or never came, costs nothing. }
procedure LetCoordinatorFinish;
var
  Watcher: PProcess;
  Event: PEventObject;
  ExitCode: LongInt;
begin
  EnsureCoordinatorLock;
  AcquireMutex(CoordinatorLock);
  Watcher := Coordinator;
  Event := CoordinatorEvent;
  Coordinator := nil;
  CoordinatorEvent := nil;
  ReleaseMutex(CoordinatorLock);
  if Watcher = nil then
    Exit;
  SignalEvent(Event^.Event);
  if not Watcher^.HasExited then
  begin
    Report('waiting for the services to stop');
    if WaitForProcessExit(Watcher, ShutdownCoordinatorSeconds * 1000, ExitCode) <> ErrorNone then
      Report('the services did not stop in time');
  end;
  DereferenceObject(Event);
  DereferenceObject(Watcher);
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
  LetCoordinatorFinish;
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

function PerformWatchShutdown: Int64;
var
  Process: PProcess;
  Event: PEventObject;
  Handle: Int64;
begin
  Process := CurrentProcess;
  if Process^.Credentials.EffectiveUserId <> RootUserId then
    Exit(-Int64(ErrorNotPermitted));
  EnsureCoordinatorLock;
  AcquireMutex(CoordinatorLock);
  if (Coordinator <> nil) and not Coordinator^.HasExited then
  begin
    ReleaseMutex(CoordinatorLock);
    Exit(-Int64(ErrorBusy));
  end;
  Event := CreateEventObject(True, Started <> 0);
  if Event = nil then
  begin
    ReleaseMutex(CoordinatorLock);
    Exit(-Int64(ErrorOutOfMemory));
  end;
  AcquireMutex(Process^.Lock);
  Handle := InsertHandle(Process^.Handles, HandleKindEvent, Event, 0);
  ReleaseMutex(Process^.Lock);
  if Handle < 0 then
  begin
    ReleaseMutex(CoordinatorLock);
    DereferenceObject(Event);
    Exit(-Int64(ErrorTooManyHandles));
  end;
  { A watcher that ended is replaced. }
  if Coordinator <> nil then
  begin
    DereferenceObject(Coordinator);
    DereferenceObject(CoordinatorEvent);
  end;
  ReferenceObject(Process);
  Coordinator := Process;
  { The creation reference stays ours; the handle has its own. }
  CoordinatorEvent := Event;
  ReleaseMutex(CoordinatorLock);
  Result := Handle;
end;

end.
