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
  POSIX signals, for the C library.

  Programs of the system's own runtime are told things through their
  notification queue and are never interrupted (see "Notifications and
  requests to end"). A C program instead says, per signal, what is to
  happen (CallSetSignalDisposition): the default action, nothing
  (ignore), or a call of its handler. A signal sent to it (CallSendSignal,
  or by the kernel: SIGCHLD when a child ends, SIGPIPE from the C
  library, Ctrl-C and hang-ups as SIGINT and SIGHUP for a program that
  takes them) is then:

    * by default: ended (with the status of a process killed by that
      signal: 128 plus the signal, and the signal for waitpid), stopped
      (SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU), continued (SIGCONT) or left
      alone (SIGCHLD, SIGURG, SIGWINCH);
    * ignored: dropped;
    * handled: kept waiting for the process, and one of its threads that
      does not block it is alerted (its wait, if it waits, ends with
      ErrorInterrupted). At the thread's next return to user mode the
      kernel writes a TAbiSignalRecord (the signal, the thread's mask,
      the registers) on its stack, adds the handler's mask to the
      thread's mask, and continues the thread in the process's signal
      dispatcher, as the exception dispatcher is entered. The dispatcher
      calls the handler and ends with CallReturnFromSignal, which puts
      the registers and the mask back.

  SIGKILL ends and SIGSTOP stops whatever the disposition. Masks are per
  thread, dispositions per process. A system call cut short by a signal
  fails with ErrorInterrupted (there is no SA_RESTART).
}
unit Processes.Signals;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame,
  Processes.Process;

{ Sends Signal from the kernel (SenderProcessId: whose doing it was, 0
  for nobody). Requires the registry lock. }
procedure PostSignalFromKernelLocked(Process: PProcess; Signal: LongInt; SenderProcessId: QWord);

{ For an end request (Processes.EndRequests): if Process takes the
  signal that stands for Reason (SIGTERM, SIGHUP, SIGINT) - handles or
  ignores it - the request becomes that signal and True is returned.
  Requires the registry lock. }
function EndRequestTakenAsSignalLocked(Process: PProcess; Reason: LongWord; SenderProcessId: QWord): Boolean;
{ The signal an end request for Reason stands for. }
function SignalOfEndReason(Reason: LongWord): LongInt;

{ At a return to user mode: continues the thread in the signal
  dispatcher if a signal it does not block waits for it. }
procedure DeliverPendingSignals(Frame: PTrapFrame);

{ The child of fork starts with the parent's dispositions and the
  calling thread's mask; exec keeps ignored signals and the mask and
  makes handled ones default. }
procedure InheritSignalState(Parent, Child: PProcess);
procedure ResetSignalHandlersForExec(Process: PProcess);

function PerformSetSignalDispatcher(Address: QWord): Int64;
function PerformSendSignal(Target: Int64; Signal: QWord): Int64;
function PerformSetSignalMask(How, MaskAddress, OldMaskAddress: QWord): Int64;
function PerformSetSignalDisposition(Signal, Disposition, HandlerMask, Flags: QWord): Int64;
function PerformReturnFromSignal(Frame: PTrapFrame; RecordAddress: QWord): LongInt;
function PerformSuspendForSignal(MaskAddress: QWord): Int64;
function PerformPendingSignals: Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Threads,
  Kernel.Scheduler,
  Processes.PosixState,
  Processes.Thread,
  Processes.Security,
  Processes.Termination,
  Processes.Stopping,
  Processes.ThreadControl,
  Processes.UserAccess,
  Processes.Arch.UserContext;

const
  { Neither blocked nor handled: SIGKILL and SIGSTOP. }
  UnblockableSignals = (QWord(1) shl (SignalKill - 1)) or (QWord(1) shl (SignalStop - 1));
  { How long a sigsuspend waits between looks (it is woken by the alert
    a signal brings). }
  SuspendSliceMilliseconds = 60000;

type
  TDefaultAction = (ActionTerminate, ActionIgnore, ActionStop, ActionContinue);

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function SignalBit(Signal: LongInt): QWord;
begin
  Result := QWord(1) shl (Signal - 1);
end;

function DefaultActionOf(Signal: LongInt): TDefaultAction;
begin
  case Signal of
    SignalChild, SignalUrgent, SignalWindowChanged: Result := ActionIgnore;
    SignalStop, SignalTerminalStop, SignalTerminalInput, SignalTerminalOutput: Result := ActionStop;
    SignalContinue: Result := ActionContinue;
  else
    Result := ActionTerminate;
  end;
end;

{ The signal is dropped when it arrives. }
function IsDiscarded(Process: PProcess; Signal: LongInt): Boolean;
begin
  case Process^.Posix.Dispositions[Signal] of
    SignalDispositionIgnore: Result := Signal <> SignalKill;
    SignalDispositionHandle: Result := False;
  else
    Result := DefaultActionOf(Signal) = ActionIgnore;
  end;
end;

{ Ends the process as killed by Signal. Requires the registry lock. }
procedure TerminateBySignalLocked(Process: PProcess; Signal: LongInt);
begin
  if Process^.TerminationRequested then
    Exit;
  Process^.Posix.EndSignal := Signal;
  RequestProcessTerminationLocked(Process, 128 + Signal);
end;

type
  TTargetSearch = record
    Signal: LongInt;
    Chosen: PThread;
  end;
  PTargetSearch = ^TTargetSearch;

procedure ConsiderThread(Thread: PThread; Context: Pointer);
var
  Search: PTargetSearch;
begin
  Search := PTargetSearch(Context);
  if (Search^.Chosen = nil) and Thread^.IsUserThread and
     ((Thread^.Posix.SignalMask and SignalBit(Search^.Signal)) = 0) then
    Search^.Chosen := Thread;
end;

{ Alerts one thread that does not block Signal, so it takes it soon;
  none if the sending thread is one of the process's and takes it itself
  (raise) at the end of this system call. }
procedure WakeTakerOf(Process: PProcess; Signal: LongInt);
var
  Search: TTargetSearch;
  Current: PThread;
begin
  Current := CurrentThreadObject;
  if (Current <> nil) and (Current^.Process = Process) and
     ((Current^.Posix.SignalMask and SignalBit(Signal)) = 0) then
    Exit;
  Search.Signal := Signal;
  Search.Chosen := nil;
  VisitProcessThreads(Process, @ConsiderThread, @Search);
  if Search.Chosen <> nil then
  begin
    Search.Chosen^.Posix.AlertedForSignal := True;
    AlertThread(@Search.Chosen^.ControlBlock);
  end;
end;

{ An alert brought for a signal is spent once the thread is back in user
  mode, whoever took the signal; later waits wait again (unless the
  process is being stopped or ended, or the thread asked to stop). }
procedure GiveUpSignalAlert(Process: PProcess; Thread: PThread);
begin
  if not Thread^.Posix.AlertedForSignal then
    Exit;
  Thread^.Posix.AlertedForSignal := False;
  if not Process^.StopRequested and not Process^.TerminationRequested and not CurrentThreadIsAsked then
    ClearCurrentThreadAlert;
end;

{ True if a thread of Process does not block Signal. }
function SomeThreadTakes(Process: PProcess; Signal: LongInt): Boolean;
var
  Search: TTargetSearch;
begin
  Search.Signal := Signal;
  Search.Chosen := nil;
  VisitProcessThreads(Process, @ConsiderThread, @Search);
  Result := Search.Chosen <> nil;
end;

{ Leaves a handled signal waiting for the process. }
procedure MakePending(Process: PProcess; Signal: LongInt; SenderProcessId: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Process^.Posix.PendingSignals := Process^.Posix.PendingSignals or SignalBit(Signal);
  Process^.Posix.PendingSenders[Signal] := SenderProcessId;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  WakeTakerOf(Process, Signal);
end;

procedure PostSignalFromKernelLocked(Process: PProcess; Signal: LongInt; SenderProcessId: QWord);
begin
  if (Signal < 1) or (Signal > HighestSignal) or not Process^.IsUserProcess or Process^.HasExited then
    Exit;
  if Signal = SignalKill then
  begin
    TerminateBySignalLocked(Process, Signal);
    Exit;
  end;
  if IsDiscarded(Process, Signal) then
    Exit;
  if (Process^.Posix.Dispositions[Signal] = SignalDispositionHandle) and (Process^.Posix.SignalDispatcher <> 0) then
    MakePending(Process, Signal, SenderProcessId)
  else if DefaultActionOf(Signal) = ActionTerminate then
  begin
    { Blocked by every thread, it waits (and ends the process once a
      thread unblocks it, DeliverPendingSignals). }
    if SomeThreadTakes(Process, Signal) then
      TerminateBySignalLocked(Process, Signal)
    else
      MakePending(Process, Signal, SenderProcessId);
  end;
  { Stopping and continuing take the registry lock themselves; from here
    (SIGCHLD, end requests) they do not come. }
end;

function SignalOfEndReason(Reason: LongWord): LongInt;
begin
  case Reason of
    EndReasonInterrupt: Result := SignalInterrupt;
    EndReasonHangUp: Result := SignalHangUp;
  else
    Result := SignalTerminate;
  end;
end;

function EndRequestTakenAsSignalLocked(Process: PProcess; Reason: LongWord; SenderProcessId: QWord): Boolean;
var
  Signal: LongInt;
begin
  Signal := SignalOfEndReason(Reason);
  Result := Process^.Posix.Dispositions[Signal] <> SignalDispositionDefault;
  if Result then
    PostSignalFromKernelLocked(Process, Signal, SenderProcessId);
end;

{ Takes the lowest signal waiting for the thread that it does not block;
  0 if there is none. }
function TakePendingSignal(Process: PProcess; Thread: PThread; out SenderProcessId: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Ready: QWord;
  Signal: LongInt;
begin
  Result := 0;
  SenderProcessId := 0;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Ready := (Thread^.Posix.PendingSignals or Process^.Posix.PendingSignals) and not Thread^.Posix.SignalMask;
  if Ready <> 0 then
  begin
    Signal := 1;
    while (Ready and SignalBit(Signal)) = 0 do
      Inc(Signal);
    if (Thread^.Posix.PendingSignals and SignalBit(Signal)) <> 0 then
      Thread^.Posix.PendingSignals := Thread^.Posix.PendingSignals and not SignalBit(Signal)
    else
    begin
      Process^.Posix.PendingSignals := Process^.Posix.PendingSignals and not SignalBit(Signal);
      SenderProcessId := Process^.Posix.PendingSenders[Signal];
    end;
    Result := Signal;
  end;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
end;

{ Writes the record for Signal on the user stack and points Frame at
  the dispatcher. False if the record does not fit (the stack is gone). }
function EnterSignalDispatcher(Frame: PTrapFrame; Process: PProcess; Thread: PThread; Signal: LongInt;
  SenderProcessId: QWord): Boolean;
var
  SignalRecord: TAbiSignalRecord;
  RecordAddress: QWord;
  ReturnSlot: QWord;
  NoReturnAddress: QWord;
  PreviousLevel: TPriorityLevel;
begin
  ZeroMemory(@SignalRecord, SizeOf(SignalRecord));
  SignalRecord.Signal := LongWord(Signal);
  if SenderProcessId = 0 then
    SignalRecord.Code := SignalFromKernel
  else
    SignalRecord.Code := SignalFromProcess;
  SignalRecord.SenderProcessId := Int64(SenderProcessId);
  CaptureUserContext(Frame, SignalRecord.Context);

  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  if Thread^.Posix.HasSavedSignalMask then
  begin
    SignalRecord.PreviousMask := Thread^.Posix.SavedSignalMask;
    Thread^.Posix.HasSavedSignalMask := False;
  end
  else
    SignalRecord.PreviousMask := Thread^.Posix.SignalMask;
  Thread^.Posix.SignalMask := (SignalRecord.PreviousMask or Process^.Posix.HandlerMasks[Signal]) and
    not UnblockableSignals;
  if (Process^.Posix.HandlerFlags[Signal] and SignalFlagResetHandler) <> 0 then
    Process^.Posix.Dispositions[Signal] := SignalDispositionDefault;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);

  RecordAddress := (TrapFrameStackPointer(Frame) - UserStackRedZoneSize - SizeOf(SignalRecord)) and not QWord(15);
  ReturnSlot := RecordAddress - SizeOf(QWord);
  NoReturnAddress := 0;
  Result := (CopyToUser(RecordAddress, @SignalRecord, SizeOf(SignalRecord)) = ErrorNone) and
    (CopyToUser(ReturnSlot, @NoReturnAddress, SizeOf(NoReturnAddress)) = ErrorNone);
  if Result then
    EnterExceptionDispatcher(Frame, Process^.Posix.SignalDispatcher, RecordAddress, ReturnSlot)
  else
    Thread^.Posix.SignalMask := SignalRecord.PreviousMask;
end;

procedure DeliverPendingSignals(Frame: PTrapFrame);
var
  Process: PProcess;
  Thread: PThread;
  Signal: LongInt;
  SenderProcessId: QWord;
  WereEnabled: Boolean;
begin
  Process := CurrentProcess;
  if (Process = nil) or not Process^.IsUserProcess then
    Exit;
  Thread := CurrentThreadObject;
  if Thread^.Posix.AlertedForSignal then
    GiveUpSignalAlert(Process, Thread);
  if ((Thread^.Posix.PendingSignals or Process^.Posix.PendingSignals) and not Thread^.Posix.SignalMask) = 0 then
    Exit;
  if Process^.TerminationRequested then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  EnableInterrupts;
  Signal := TakePendingSignal(Process, Thread, SenderProcessId);
  if Signal <> 0 then
  begin
    { One that waited while blocked and is not handled (any more) takes
      its default action now. }
    if (Process^.Posix.Dispositions[Signal] <> SignalDispositionHandle) or
       (Process^.Posix.SignalDispatcher = 0) then
    begin
      if (Process^.Posix.Dispositions[Signal] = SignalDispositionDefault) and
         (DefaultActionOf(Signal) = ActionTerminate) then
      begin
        LockProcessRegistry;
        TerminateBySignalLocked(Process, Signal);
        UnlockProcessRegistry;
      end;
    end
    else if not EnterSignalDispatcher(Frame, Process, Thread, Signal, SenderProcessId) then
    begin
      LockProcessRegistry;
      TerminateBySignalLocked(Process, Signal);
      UnlockProcessRegistry;
    end;
  end;
  DisableInterrupts;
  RestoreInterrupts(WereEnabled);
end;

procedure InheritSignalState(Parent, Child: PProcess);
var
  Signal: LongInt;
begin
  Child^.Posix.SignalDispatcher := Parent^.Posix.SignalDispatcher;
  for Signal := 1 to HighestSignal do
  begin
    Child^.Posix.Dispositions[Signal] := Parent^.Posix.Dispositions[Signal];
    Child^.Posix.HandlerFlags[Signal] := Parent^.Posix.HandlerFlags[Signal];
    Child^.Posix.HandlerMasks[Signal] := Parent^.Posix.HandlerMasks[Signal];
  end;
end;

procedure ResetSignalHandlersForExec(Process: PProcess);
var
  Signal: LongInt;
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Process^.Posix.SignalDispatcher := 0;
  for Signal := 1 to HighestSignal do
    if Process^.Posix.Dispositions[Signal] = SignalDispositionHandle then
    begin
      Process^.Posix.Dispositions[Signal] := SignalDispositionDefault;
      Process^.Posix.HandlerFlags[Signal] := 0;
      Process^.Posix.HandlerMasks[Signal] := 0;
    end;
  { Pending signals stay pending (POSIX): the new program gets them as
    its dispositions say. }
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
end;

function PerformSetSignalDispatcher(Address: QWord): Int64;
begin
  if Address >= UserSpaceLimit then
    Exit(Failure(ErrorInvalidArgument));
  CurrentProcess^.Posix.SignalDispatcher := Address;
  Result := 0;
end;

{ What to do with each process a kill reaches. }
type
  TSignalRequest = record
    Caller: PProcess;
    Signal: LongInt;
    Target: Int64;
    Count: Integer;
    Denied: Integer;
  end;
  PSignalRequest = ^TSignalRequest;

function TargetMatches(Process: PProcess; const Request: TSignalRequest): Boolean;
begin
  if Request.Target > 0 then
    Result := Process^.ProcessId = QWord(Request.Target)
  else if Request.Target = 0 then
    Result := Process^.GroupId = Request.Caller^.GroupId
  else if Request.Target = -1 then
    Result := (Process <> Request.Caller) and not Process^.NeverEndForMemory
  else
    Result := Process^.GroupId = QWord(-Request.Target);
end;

procedure SignalVisitedProcess(Process: PProcess; Context: Pointer);
var
  Request: PSignalRequest;
begin
  Request := PSignalRequest(Context);
  if not Process^.IsUserProcess or Process^.HasExited or not TargetMatches(Process, Request^) then
    Exit;
  if not MayControlProcess(Request^.Caller, Process) then
  begin
    Inc(Request^.Denied);
    Exit;
  end;
  Inc(Request^.Count);
  if Request^.Signal = 0 then
    Exit;
  { Each process the walk reaches is handled by its own dispositions:
    SIGSTOP always stops, SIGCONT continues (and is delivered), and the
    other stopping signals stop only where their action is the default
    one, are delivered where they are handled and do nothing where they
    are ignored. }
  if Request^.Signal = SignalStop then
    StopProcessLocked(Process)
  else if Request^.Signal = SignalContinue then
  begin
    ContinueProcessLocked(Process);
    PostSignalFromKernelLocked(Process, Request^.Signal, Request^.Caller^.ProcessId);
  end
  else if DefaultActionOf(Request^.Signal) = ActionStop then
  begin
    if Process^.Posix.Dispositions[Request^.Signal] = SignalDispositionDefault then
      StopProcessLocked(Process)
    else if Process^.Posix.Dispositions[Request^.Signal] = SignalDispositionHandle then
      PostSignalFromKernelLocked(Process, Request^.Signal, Request^.Caller^.ProcessId);
  end
  else
    PostSignalFromKernelLocked(Process, Request^.Signal, Request^.Caller^.ProcessId);
end;

function PerformSendSignal(Target: Int64; Signal: QWord): Int64;
var
  Request: TSignalRequest;
begin
  if Signal > HighestSignal then
    Exit(Failure(ErrorInvalidArgument));
  { No group has the negation of the lowest Int64 for its id. }
  if Target = Low(Int64) then
    Exit(Failure(ErrorNoSuchProcess));
  Request.Caller := CurrentProcess;
  Request.Signal := LongInt(Signal);
  Request.Target := Target;
  Request.Count := 0;
  Request.Denied := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@SignalVisitedProcess, @Request);
  UnlockProcessRegistry;
  if Request.Count = 0 then
  begin
    if Request.Denied > 0 then
      Exit(Failure(ErrorNotPermitted));
    Exit(Failure(ErrorNoSuchProcess));
  end;
  Result := 0;
end;

function PerformSetSignalMask(How, MaskAddress, OldMaskAddress: QWord): Int64;
var
  Process: PProcess;
  Thread: PThread;
  Mask: QWord;
  Previous: QWord;
  PreviousLevel: TPriorityLevel;
  Error: LongInt;
begin
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  Mask := 0;
  if MaskAddress <> 0 then
  begin
    Error := CopyFromUser(@Mask, MaskAddress, SizeOf(Mask));
    if Error <> ErrorNone then
      Exit(Failure(Error));
    if How > SignalSetMask then
      Exit(Failure(ErrorInvalidArgument));
  end;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Previous := Thread^.Posix.SignalMask;
  if MaskAddress <> 0 then
  begin
    case How of
      SignalBlock: Thread^.Posix.SignalMask := Previous or Mask;
      SignalUnblock: Thread^.Posix.SignalMask := Previous and not Mask;
    else
      Thread^.Posix.SignalMask := Mask;
    end;
    Thread^.Posix.SignalMask := Thread^.Posix.SignalMask and not UnblockableSignals;
  end;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  if OldMaskAddress <> 0 then
  begin
    Error := CopyToUser(OldMaskAddress, @Previous, SizeOf(Previous));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Result := 0;
end;

function PerformSetSignalDisposition(Signal, Disposition, HandlerMask, Flags: QWord): Int64;
var
  Process: PProcess;
  PreviousLevel: TPriorityLevel;
begin
  if (Signal < 1) or (Signal > HighestSignal) or (Signal = SignalKill) or (Signal = SignalStop) or
     (Disposition > SignalDispositionHandle) then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Process^.Posix.Dispositions[Signal] := Byte(Disposition);
  Process^.Posix.HandlerMasks[Signal] := HandlerMask and not UnblockableSignals;
  Process^.Posix.HandlerFlags[Signal] := Byte(Flags and SignalFlagResetHandler);
  { Ignoring a signal drops what of it waits. }
  if Disposition = SignalDispositionIgnore then
    Process^.Posix.PendingSignals := Process^.Posix.PendingSignals and not SignalBit(Signal);
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  Result := 0;
end;

function PerformReturnFromSignal(Frame: PTrapFrame; RecordAddress: QWord): LongInt;
var
  SignalRecord: TAbiSignalRecord;
  Process: PProcess;
  Thread: PThread;
  PreviousLevel: TPriorityLevel;
begin
  Result := CopyFromUser(@SignalRecord, RecordAddress, SizeOf(SignalRecord));
  if Result <> ErrorNone then
    Exit;
  Result := RestoreUserContext(Frame, SignalRecord.Context);
  if Result <> ErrorNone then
    Exit;
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Thread^.Posix.SignalMask := SignalRecord.PreviousMask and not UnblockableSignals;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
end;

function SignalIsReady(Process: PProcess; Thread: PThread): Boolean;
begin
  Result := ((Thread^.Posix.PendingSignals or Process^.Posix.PendingSignals) and
    not Thread^.Posix.SignalMask) <> 0;
end;

function PerformSuspendForSignal(MaskAddress: QWord): Int64;
var
  Process: PProcess;
  Thread: PThread;
  Mask: QWord;
  PreviousLevel: TPriorityLevel;
  Error: LongInt;
begin
  Error := CopyFromUser(@Mask, MaskAddress, SizeOf(Mask));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Thread^.Posix.SavedSignalMask := Thread^.Posix.SignalMask;
  Thread^.Posix.HasSavedSignalMask := True;
  Thread^.Posix.SignalMask := Mask and not UnblockableSignals;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  { An alert a signal taken earlier left must not end this wait. }
  if not SignalIsReady(Process, Thread) and not Process^.StopRequested and
     not Process^.TerminationRequested and not CurrentThreadIsAsked then
    ClearCurrentThreadAlert;
  while not SignalIsReady(Process, Thread) and not Process^.TerminationRequested do
    if not SleepAlertable(SuspendSliceMilliseconds) and not SignalIsReady(Process, Thread) then
      Break;
  { Taken now, the handler gives the saved mask back when it returns;
    otherwise it comes back here. }
  if not SignalIsReady(Process, Thread) then
  begin
    PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
    if Thread^.Posix.HasSavedSignalMask then
    begin
      Thread^.Posix.SignalMask := Thread^.Posix.SavedSignalMask;
      Thread^.Posix.HasSavedSignalMask := False;
    end;
    ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  end;
  Result := Failure(ErrorInterrupted);
end;

function PerformPendingSignals: Int64;
begin
  Result := Int64((CurrentThreadObject^.Posix.PendingSignals or CurrentProcess^.Posix.PendingSignals) and
    not QWord($8000000000000000));
end;

end.
