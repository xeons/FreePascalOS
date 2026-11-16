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
  Ending another program.

  A program cannot be stopped at an arbitrary point in the kernel: it may
  hold locks. Instead, TerminateProcessById marks the process and alerts
  its threads. The process then ends itself at the next safe point:

    * when a system call is about to return to the program,
    * when an interrupt (the clock, at the latest) is about to return to
      the program, which catches programs that never make a call,
    * when an alertable wait (pipes, the console, sleeping, waiting for a
      process) is cut short by the alert; the system call then returns
      and the first rule applies.

  The exit code is the one given by the caller; by Unix convention 128
  plus a signal number (143 for "terminate").

  Asking a process to end, which lets it tidy up first if it wants to,
  is Processes.EndRequests; a process that does not take the request is
  ended here, with the request's status (143, 129 for a terminal's
  hang-up, 130 for Ctrl-C).

  The same safe points also let a thread wait while its process is
  stopped (StopCurrentThreadIfRequested), and act on being suspended or
  asked to end by another thread (Processes.ThreadControl).
}
unit Processes.Termination;

{$mode objfpc}

interface

uses
  Processes.Process;

procedure InitializeProcessTermination;

{ Returns ErrorNone, ErrorNoSuchProcess or ErrorNotPermitted. }
function TerminateProcessById(ProcessId: QWord; ExitCode: LongInt): LongInt;
{ Ends every user process (shutting down); returns how many were still
  running. }
function TerminateAllUserProcesses(ExitCode: LongInt): Integer;
{ How many user processes run. }
function CountUserProcesses: Integer;

{ Asks every process of session SessionId, except the caller and those
  it may not control, to end; returns how many were asked. }
function TerminateSession(SessionId: QWord; ExitCode: LongInt): Integer;

{ Marks Process for ending with ExitCode (unless it already is) and
  alerts its threads. Requires the registry lock. }
procedure RequestProcessTerminationLocked(Process: PProcess; ExitCode: LongInt);

{ Ends the current process if termination was requested. Called before
  returning from a system call (PassiveLevel, interrupts enabled). }
procedure EndProcessIfTerminationRequested;

implementation

uses
  Abi.SystemCalls,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Processes.Thread,
  Processes.UserProcess,
  Processes.Security,
  Processes.Stopping,
  Processes.ThreadControl,
  Processes.UserExceptions;

procedure EndProcessIfTerminationRequested;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  if (Process <> nil) and Process^.IsUserProcess and Process^.TerminationRequested then
    ExitCurrentProcess(Process^.TerminationCode);
end;

procedure CheckTerminationOnReturn(Frame: PTrapFrame);
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  if (Process <> nil) and Process^.IsUserProcess and Process^.StopRequested then
  begin
    { Waiting blocks; interrupts must be on for that. }
    EnableInterrupts;
    StopCurrentThreadIfRequested;
    DisableInterrupts;
  end;
  { A stack overflow's reserve is armed again once the stack is clear. }
  if (Process <> nil) and Process^.IsUserProcess and StackReserveIsOpen then
  begin
    EnableInterrupts;
    RearmStackReserveIfClear(Frame^.Rsp);
    DisableInterrupts;
  end;
  { A thread suspended or asked to end by another (Processes.ThreadControl). }
  if (Process <> nil) and Process^.IsUserProcess and CurrentThreadIsAsked then
  begin
    EnableInterrupts;
    HoldCurrentThreadIfAsked;
    DisableInterrupts;
  end;
  if (Process <> nil) and Process^.IsUserProcess and Process^.TerminationRequested then
  begin
    { Ending the process may block; interrupts must be on for that. }
    EnableInterrupts;
    ExitCurrentProcess(Process^.TerminationCode);
  end;
end;

procedure RequestProcessTerminationLocked(Process: PProcess; ExitCode: LongInt);
begin
  if not Process^.TerminationRequested then
  begin
    Process^.TerminationCode := ExitCode;
    Process^.TerminationRequested := True;
  end;
  AlertProcessThreads(Process);
end;

procedure InitializeProcessTermination;
begin
  SetUserModeReturnHook(@CheckTerminationOnReturn);
end;

function TerminateProcessById(ProcessId: QWord; ExitCode: LongInt): LongInt;
var
  Process: PProcess;
begin
  LockProcessRegistry;
  Process := FindRunningProcessLocked(ProcessId);
  if Process = nil then
    Result := ErrorNoSuchProcess
  else if not Process^.IsUserProcess or not MayControlProcess(CurrentProcess, Process) then
    Result := ErrorNotPermitted
  else
  begin
    RequestProcessTerminationLocked(Process, ExitCode);
    Result := ErrorNone;
  end;
  UnlockProcessRegistry;
end;

procedure TerminateIfUserProcess(Process: PProcess; Context: Pointer);
begin
  if not Process^.IsUserProcess then
    Exit;
  RequestProcessTerminationLocked(Process, PLongInt(Context)^);
end;

procedure CountUserProcess(Process: PProcess; Context: Pointer);
begin
  if Process^.IsUserProcess then
    Inc(PInteger(Context)^);
end;

type
  TSessionRequest = record
    SessionId: QWord;
    ExitCode: LongInt;
    Caller: PProcess;
    Count: Integer;
  end;
  PSessionRequest = ^TSessionRequest;

procedure TerminateIfInSession(Process: PProcess; Context: Pointer);
var
  Request: PSessionRequest;
begin
  Request := PSessionRequest(Context);
  if not Process^.IsUserProcess or (Process^.SessionId <> Request^.SessionId) or
     (Process = Request^.Caller) or Process^.HasExited then
    Exit;
  if not MayControlProcess(Request^.Caller, Process) then
    Exit;
  RequestProcessTerminationLocked(Process, Request^.ExitCode);
  Inc(Request^.Count);
end;

function TerminateSession(SessionId: QWord; ExitCode: LongInt): Integer;
var
  Request: TSessionRequest;
begin
  Request.SessionId := SessionId;
  Request.ExitCode := ExitCode;
  Request.Caller := CurrentProcess;
  Request.Count := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@TerminateIfInSession, @Request);
  UnlockProcessRegistry;
  Result := Request.Count;
end;

function TerminateAllUserProcesses(ExitCode: LongInt): Integer;
begin
  Result := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@CountUserProcess, @Result);
  VisitRunningProcessesLocked(@TerminateIfUserProcess, @ExitCode);
  UnlockProcessRegistry;
end;

function CountUserProcesses: Integer;
begin
  Result := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@CountUserProcess, @Result);
  UnlockProcessRegistry;
end;

end.
