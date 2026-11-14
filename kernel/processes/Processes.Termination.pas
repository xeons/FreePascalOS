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

  Ctrl-C on the console ends the console's foreground process group with
  exit code 130 (128 + SIGINT), sparing processes that ignore it (an
  interactive shell). A system thread does this, woken by the console. If
  it ended nobody, the reader gets Ctrl-C as an ordinary character.
}
unit Processes.Termination;

{$mode objfpc}

interface

procedure InitializeProcessTermination;

{ Starts the thread that handles Ctrl-C (needs a running scheduler). }
procedure StartConsoleInterruptHandler;

{ Returns ErrorNone, ErrorNoSuchProcess or ErrorNotPermitted. }
function TerminateProcessById(ProcessId: QWord; ExitCode: LongInt): LongInt;

{ Ends every process of group GroupId that does not ignore interrupts;
  returns how many. }
function InterruptProcessGroup(GroupId: QWord; ExitCode: LongInt): Integer;

{ Ends the current process if termination was requested. Called before
  returning from a system call (PassiveLevel, interrupts enabled). }
procedure EndProcessIfTerminationRequested;

implementation

uses
  Abi.SystemCalls,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Processes.Process,
  Processes.Thread,
  Processes.UserProcess,
  Io.Console;

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
  if (Process <> nil) and Process^.IsUserProcess and Process^.TerminationRequested then
  begin
    { Ending the process may block; interrupts must be on for that. }
    EnableInterrupts;
    ExitCurrentProcess(Process^.TerminationCode);
  end;
end;

const
  InterruptExitCode = 130;
  InterruptThreadPriority = 20;

procedure RequestTerminationLocked(Process: PProcess; ExitCode: LongInt);
begin
  if not Process^.TerminationRequested then
  begin
    Process^.TerminationCode := ExitCode;
    Process^.TerminationRequested := True;
  end;
  AlertProcessThreads(Process);
end;

type
  TGroupInterrupt = record
    GroupId: QWord;
    ExitCode: LongInt;
    Count: Integer;
  end;
  PGroupInterrupt = ^TGroupInterrupt;

procedure InterruptIfInGroup(Process: PProcess; Context: Pointer);
var
  Request: PGroupInterrupt;
begin
  Request := PGroupInterrupt(Context);
  if (Process^.GroupId = Request^.GroupId) and Process^.IsUserProcess and
     not Process^.IgnoresInterrupt then
  begin
    RequestTerminationLocked(Process, Request^.ExitCode);
    Inc(Request^.Count);
  end;
end;

function InterruptProcessGroup(GroupId: QWord; ExitCode: LongInt): Integer;
var
  Request: TGroupInterrupt;
begin
  Request.GroupId := GroupId;
  Request.ExitCode := ExitCode;
  Request.Count := 0;
  if GroupId <> 0 then
  begin
    LockProcessRegistry;
    VisitRunningProcessesLocked(@InterruptIfInGroup, @Request);
    UnlockProcessRegistry;
  end;
  Result := Request.Count;
end;

procedure HandleConsoleInterrupts(Context: Pointer);
begin
  repeat
    WaitForInterruptKey;
    if InterruptProcessGroup(ConsoleForegroundGroup, InterruptExitCode) > 0 then
      FinishInterrupt
    else
      PassInterruptToReader;
  until False;
end;

procedure InitializeProcessTermination;
begin
  SetUserModeReturnHook(@CheckTerminationOnReturn);
end;

procedure StartConsoleInterruptHandler;
begin
  CreateSystemThread(@HandleConsoleInterrupts, nil, InterruptThreadPriority, 'console-interrupt', False);
end;

function TerminateProcessById(ProcessId: QWord; ExitCode: LongInt): LongInt;
var
  Process: PProcess;
begin
  LockProcessRegistry;
  Process := FindRunningProcessLocked(ProcessId);
  if Process = nil then
    Result := ErrorNoSuchProcess
  else if not Process^.IsUserProcess then
    Result := ErrorNotPermitted
  else
  begin
    RequestTerminationLocked(Process, ExitCode);
    Result := ErrorNone;
  end;
  UnlockProcessRegistry;
end;

end.
