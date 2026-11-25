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
  Stopping and continuing programs (job control).

  Like ending a program (Processes.Termination), stopping one cannot
  happen at an arbitrary point in the kernel. A stop request marks the
  process and alerts its threads; each user thread then waits at its next
  safe point (a system call or interrupt about to return to the program)
  until the process is continued or ended. When the last active thread
  has stopped, the process counts as stopped and a parent waiting with
  WaitForProcessChange hears about it once.

  A system call that was cut short by the alert (reading the console,
  sleeping, waiting for a child) is started again after the process is
  continued, so the program does not notice the stop. A timed wait then
  starts its timeout again.

  The console's Ctrl-Z stops its foreground process group; a program
  outside the foreground group that reads the console stops its own group
  (like SIGTTIN), and runs on once a shell makes it the foreground again.
}
unit Processes.Stopping;

{$mode objfpc}

interface

uses
  Processes.Process;

{ The safe point: if the current process was asked to stop, waits until
  it is continued or asked to end. }
procedure StopCurrentThreadIfRequested;

{ True if the current process has a stop request it has not yet acted on
  (and is not being ended). }
function CurrentStopIsPending: Boolean;

{ Target > 0 is a process id, Target < -1 a process group (its
  negation), 0 the caller's own group; -1 and the lowest Int64 (whose
  negation does not exist) are refused. Returns the number of processes
  stopped or continued, or a negative Abi error. }
function StopProcesses(Target: Int64): Int64;
function ContinueProcesses(Target: Int64): Int64;

{ Asks one process to stop, or lets it go on (kill's SIGSTOP and SIGCONT
  for each process it reaches). The process registry lock held. }
procedure StopProcessLocked(Process: PProcess);
procedure ContinueProcessLocked(Process: PProcess);

{ Stops the processes of a group that do not ignore Ctrl-Z; returns how
  many (used for the console's Ctrl-Z). }
function SuspendProcessGroup(GroupId: QWord): Integer;

{ Waits until Process exits or stops. Status is the exit code (0..255),
  or WaitStatusStopped for a stop not reported before. Returns ErrorNone,
  ErrorTimedOut or ErrorInterrupted. }
function WaitForProcessChange(Process: PProcess; TimeoutMilliseconds: QWord;
  out Status: LongInt): LongInt;

{ True if every active user thread of Process has stopped. }
function ProcessIsStopped(Process: PProcess): Boolean;

implementation

uses
  Abi.SystemCalls,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Events,
  Kernel.Scheduler,
  Processes.Thread,
  Processes.Security;

{ --- The stopped thread ----------------------------------------------- }

procedure StopCurrentThreadIfRequested;
var
  Process: PProcess;
  PreviousLevel: TPriorityLevel;
  BecameStopped: Boolean;
begin
  Process := CurrentProcess;
  if (Process = nil) or not Process^.IsUserProcess or not Process^.StopRequested then
    Exit;
  PreviousLevel := AcquireSpinLock(Process^.StopLock);
  while Process^.StopRequested and not Process^.TerminationRequested do
  begin
    Inc(Process^.StoppedThreads);
    BecameStopped := not Process^.IsStopped and
      (Process^.StoppedThreads >= Process^.ActiveUserThreads);
    if BecameStopped then
    begin
      Process^.IsStopped := True;
      Process^.StopReported := False;
    end;
    ReleaseSpinLock(Process^.StopLock, PreviousLevel);
    if BecameStopped then
      SignalEvent(Process^.StateChangedEvent);

    { The stop request alerted this thread; forget that, so the wait
      below blocks. A request to end the process sets its flag before it
      alerts, so it is either seen here or ends the wait. }
    ClearCurrentThreadAlert;
    if not Process^.TerminationRequested then
      WaitForEventWithOptions(Process^.ContinueEvent, InfiniteTimeout, True);

    PreviousLevel := AcquireSpinLock(Process^.StopLock);
    Dec(Process^.StoppedThreads);
  end;
  ReleaseSpinLock(Process^.StopLock, PreviousLevel);
end;

function CurrentStopIsPending: Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  Result := (Process <> nil) and Process^.IsUserProcess and Process^.StopRequested and
    not Process^.TerminationRequested;
end;

function ProcessIsStopped(Process: PProcess): Boolean;
begin
  Result := Process^.IsStopped;
end;

{ --- Requests ---------------------------------------------------------- }

procedure RequestStopLocked(Process: PProcess);
var
  PreviousLevel: TPriorityLevel;
begin
  if Process^.TerminationRequested or Process^.HasExited then
    Exit;
  PreviousLevel := AcquireSpinLock(Process^.StopLock);
  if not Process^.StopRequested then
  begin
    Process^.StopRequested := True;
    ResetEvent(Process^.ContinueEvent);
  end;
  ReleaseSpinLock(Process^.StopLock, PreviousLevel);
  AlertProcessThreads(Process);
end;

procedure RequestContinueLocked(Process: PProcess);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Process^.StopLock);
  Process^.StopRequested := False;
  Process^.IsStopped := False;
  SignalEvent(Process^.ContinueEvent);
  ReleaseSpinLock(Process^.StopLock, PreviousLevel);
end;

type
  TStopAction = (ActionStop, ActionContinue, ActionSuspendFromConsole);

  TGroupRequest = record
    GroupId: QWord;
    Action: TStopAction;
    Caller: PProcess;
    Count: Integer;
    Denied: Integer;
  end;
  PGroupRequest = ^TGroupRequest;

procedure ApplyAction(Process: PProcess; Action: TStopAction);
begin
  if Action = ActionContinue then
    RequestContinueLocked(Process)
  else
    RequestStopLocked(Process);
end;

procedure VisitGroupMember(Process: PProcess; Context: Pointer);
var
  Request: PGroupRequest;
begin
  Request := PGroupRequest(Context);
  if (Process^.GroupId <> Request^.GroupId) or not Process^.IsUserProcess then
    Exit;
  if (Request^.Action = ActionSuspendFromConsole) and Process^.IgnoresInterrupt then
    Exit;
  if (Request^.Caller <> nil) and not MayControlProcess(Request^.Caller, Process) then
  begin
    Inc(Request^.Denied);
    Exit;
  end;
  ApplyAction(Process, Request^.Action);
  Inc(Request^.Count);
end;

function ApplyToGroup(GroupId: QWord; Action: TStopAction; Caller: PProcess): TGroupRequest;
begin
  Result.GroupId := GroupId;
  Result.Action := Action;
  Result.Caller := Caller;
  Result.Count := 0;
  Result.Denied := 0;
  if GroupId = 0 then
    Exit;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@VisitGroupMember, @Result);
  UnlockProcessRegistry;
end;

function ApplyToTarget(Target: Int64; Action: TStopAction): Int64;
var
  Caller: PProcess;
  Process: PProcess;
  Request: TGroupRequest;
begin
  Caller := CurrentProcess;
  if (Target = -1) or (Target = Low(Int64)) then
    Exit(-ErrorInvalidArgument);
  if Target > 0 then
  begin
    LockProcessRegistry;
    Process := FindRunningProcessLocked(QWord(Target));
    if Process = nil then
      Result := -ErrorNoSuchProcess
    else if not Process^.IsUserProcess or not MayControlProcess(Caller, Process) then
      Result := -ErrorNotPermitted
    else
    begin
      ApplyAction(Process, Action);
      Result := 1;
    end;
    UnlockProcessRegistry;
    Exit;
  end;

  if Target = 0 then
    Request := ApplyToGroup(Caller^.GroupId, Action, Caller)
  else
    Request := ApplyToGroup(QWord(-Target), Action, Caller);
  if Request.Count > 0 then
    Result := Request.Count
  else if Request.Denied > 0 then
    Result := -ErrorNotPermitted
  else
    Result := -ErrorNoSuchProcess;
end;

procedure StopProcessLocked(Process: PProcess);
begin
  RequestStopLocked(Process);
end;

procedure ContinueProcessLocked(Process: PProcess);
begin
  RequestContinueLocked(Process);
end;

function StopProcesses(Target: Int64): Int64;
begin
  Result := ApplyToTarget(Target, ActionStop);
end;

function ContinueProcesses(Target: Int64): Int64;
begin
  Result := ApplyToTarget(Target, ActionContinue);
end;

function SuspendProcessGroup(GroupId: QWord): Integer;
begin
  Result := ApplyToGroup(GroupId, ActionSuspendFromConsole, nil).Count;
end;

{ --- Waiting for a change ---------------------------------------------- }

function TakeReportableChange(Process: PProcess; out Status: LongInt): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  Status := 0;
  if Process^.HasExited then
  begin
    { Exit codes are bytes, as on Unix. }
    Status := ReadExitCode(Process) and $FF;
    Exit(True);
  end;
  PreviousLevel := AcquireSpinLock(Process^.StopLock);
  Result := Process^.IsStopped and not Process^.StopReported;
  if Result then
  begin
    Process^.StopReported := True;
    Status := WaitStatusStopped;
  end;
  ReleaseSpinLock(Process^.StopLock, PreviousLevel);
end;

function WaitForProcessChange(Process: PProcess; TimeoutMilliseconds: QWord;
  out Status: LongInt): LongInt;
begin
  repeat
    if TakeReportableChange(Process, Status) then
      Exit(ErrorNone);
    { Check again after the reset: a change signaled in between is then
      seen, and one signaled later ends the wait. }
    ResetEvent(Process^.StateChangedEvent);
    if TakeReportableChange(Process, Status) then
      Exit(ErrorNone);
    case WaitForEventWithOptions(Process^.StateChangedEvent, TimeoutMilliseconds, True) of
      WaitSignaled: ;
      WaitTimedOut: Exit(ErrorTimedOut);
    else
      Exit(ErrorInterrupted);
    end;
  until False;
end;

end.
