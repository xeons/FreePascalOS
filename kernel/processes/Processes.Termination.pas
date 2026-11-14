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
}
unit Processes.Termination;

{$mode objfpc}

interface

procedure InitializeProcessTermination;

{ Returns ErrorNone, ErrorNoSuchProcess or ErrorNotPermitted. }
function TerminateProcessById(ProcessId: QWord; ExitCode: LongInt): LongInt;

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
  Processes.UserProcess;

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
  else if not Process^.IsUserProcess then
    Result := ErrorNotPermitted
  else
  begin
    if not Process^.TerminationRequested then
    begin
      Process^.TerminationCode := ExitCode;
      Process^.TerminationRequested := True;
    end;
    AlertProcessThreads(Process);
    Result := ErrorNone;
  end;
  UnlockProcessRegistry;
end;

end.
