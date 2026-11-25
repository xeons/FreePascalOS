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
  CallQueueSignal, a timer, or the kernel: SIGCHLD when a child ends,
  SIGPIPE from the C library, Ctrl-C and hang-ups as SIGINT and SIGHUP
  for a program that takes them) is then:

    * by default: ended (with the status of a process killed by that
      signal: 128 plus the signal, and the signal for waitpid), stopped
      (SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU), continued (SIGCONT) or left
      alone (SIGCHLD, SIGURG, SIGWINCH);
    * ignored: dropped;
    * handled: kept waiting for the process, and one of its threads that
      does not block it (or waits for it in sigtimedwait) is alerted
      (its wait, if it waits, ends with ErrorInterrupted). At the
      thread's next return to user mode the kernel writes a
      TAbiSignalRecord (the signal, why it came, the thread's mask, the
      registers) on its stack - or on its alternate signal stack
      (Processes.AlternateSignalStacks) - adds the handler's mask to the
      thread's mask, and continues the thread in the process's signal
      dispatcher, as the exception dispatcher is entered. The dispatcher
      calls the handler and ends with CallReturnFromSignal, which puts
      the registers and the mask back.

  A signal that does not queue waits as one instance with the
  information of its first sending; real-time signals and timers' queue
  (Processes.SignalQueue). Of the signals a thread may take, the lowest
  goes first. SIGKILL ends and SIGSTOP stops whatever the disposition.
  Masks are per thread, dispositions per process. A system call cut
  short by a signal fails with ErrorInterrupted, or is made again after
  a handler set up with SignalFlagRestart (Processes.SystemCallRestart).
}
unit Processes.Signals;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Kernel.Arch.TrapFrame,
  Processes.PosixState,
  Processes.Process,
  Processes.Thread;

{ Sends Signal from the kernel (SenderProcessId: whose doing it was, 0
  for nobody). Requires the registry lock. }
procedure PostSignalFromKernelLocked(Process: PProcess; Signal: LongInt; SenderProcessId: QWord);
{ Sends Information^.Signal with that information. ErrorNone, or
  ErrorWouldBlock for a real-time signal the queue has no room for.
  Requires the registry lock. }
function PostSignalWithInformationLocked(Process: PProcess; const Information: TAbiSignalInformation): LongInt;
{ A timer's expiry, at any level up to DispatchLevel and without the
  registry lock: queues Entry (embedded in the timer) unless it waits
  already, in which case the expiry adds to its overrun; Missed earlier
  expiries nobody saw add to it too. A signal whose action is to stop or
  continue the process is dropped here. }
procedure PostTimerSignal(Process: PProcess; Entry: PQueuedSignal; Missed: QWord; AtThreadReturn: Boolean);

{ For an end request (Processes.EndRequests): if Process takes the
  signal that stands for Reason (SIGTERM, SIGHUP, SIGINT) - handles or
  ignores it - the request becomes that signal and True is returned.
  Requires the registry lock. }
function EndRequestTakenAsSignalLocked(Process: PProcess; Reason: LongWord; SenderProcessId: QWord): Boolean;
{ The signal an end request for Reason stands for. }
function SignalOfEndReason(Reason: LongWord): LongInt;

function SignalBit(Signal: LongInt): QWord;
{ Takes the lowest signal of Allowed that waits for Thread (sent to it,
  or to its process), with its information; 0 if none. }
function TakeSignal(Process: PProcess; Thread: PThread; Allowed: QWord;
  out Information: TAbiSignalInformation): LongInt;
{ The signals waiting for Thread (its own and its process's). }
function SignalsWaitingFor(Process: PProcess; Thread: PThread): QWord;

{ At a return to user mode: looks at the process's processor-time
  timers, then continues the thread in the signal dispatcher if a
  signal it does not block waits for it. }
procedure DeliverPendingSignals(Frame: PTrapFrame);

{ The child of fork starts with the parent's dispositions and the
  calling thread's mask; exec keeps ignored signals and the mask and
  makes handled ones default (and forgets the thread's alternate
  stack). }
procedure InheritSignalState(Parent, Child: PProcess);
procedure ResetSignalHandlersForExec(Process: PProcess);
{ The process has ended: frees what of its signal queue is left. }
procedure DiscardQueuedSignals(Process: PProcess);

function PerformSetSignalDispatcher(Address: QWord): Int64;
function PerformSendSignal(Target: Int64; Signal: QWord): Int64;
{ CallQueueSignal (sigqueue). }
function PerformQueueSignal(Target: Int64; Signal: QWord; Value: Int64): Int64;
function PerformSetSignalMask(How, MaskAddress, OldMaskAddress: QWord): Int64;
function PerformSetSignalDisposition(Signal, Disposition, HandlerMask, Flags: QWord): Int64;
function PerformReturnFromSignal(Frame: PTrapFrame; RecordAddress: QWord): LongInt;
function PerformSuspendForSignal(MaskAddress: QWord): Int64;
function PerformPendingSignals: Int64;

implementation

uses
  Runtime.Memory,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Threads,
  Kernel.Scheduler,
  Processes.Security,
  Processes.Termination,
  Processes.Stopping,
  Processes.ThreadControl,
  Processes.UserAccess,
  Processes.SignalQueue,
  Processes.AlternateSignalStacks,
  Processes.SystemCallRestart,
  Processes.PosixTimers,
  Processes.Arch.UserContext;

const
  { Neither blocked nor handled: SIGKILL and SIGSTOP. }
  UnblockableSignals = (QWord(1) shl (SignalKill - 1)) or (QWord(1) shl (SignalStop - 1));
  { How long a sigsuspend waits between looks (it is woken by the alert
    a signal brings). }
  SuspendSliceMilliseconds = 60000;
  { The most an overrun counts (DELAYTIMER_MAX). }
  HighestOverrun = High(LongInt);

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

function IsRealTime(Signal: LongInt): Boolean;
begin
  Result := Signal >= FirstRealTimeSignal;
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

function IsHandled(Process: PProcess; Signal: LongInt): Boolean;
begin
  Result := (Process^.Posix.Dispositions[Signal] = SignalDispositionHandle) and
    (Process^.Posix.SignalDispatcher <> 0);
end;

{ Ends the process as killed by Signal. Requires the registry lock. }
procedure TerminateBySignalLocked(Process: PProcess; Signal: LongInt);
begin
  if Process^.TerminationRequested then
    Exit;
  Process^.Posix.EndSignal := Signal;
  RequestProcessTerminationLocked(Process, 128 + Signal);
end;

function KernelInformation(Signal: LongInt; SenderProcessId: QWord): TAbiSignalInformation;
begin
  ZeroMemory(@Result, SizeOf(Result));
  Result.Signal := LongWord(Signal);
  Result.SenderProcessId := Int64(SenderProcessId);
  if SenderProcessId = 0 then
    Result.Code := SignalFromKernel
  else
    Result.Code := SignalFromProcess;
end;

{ --- Waking a thread to take a signal ------------------------------------ }

type
  TTargetSearch = record
    Signal: LongInt;
    Chosen: PThread;
  end;
  PTargetSearch = ^TTargetSearch;

{ The thread may take Signal: it does not block it, or waits for it. }
function ThreadTakes(Thread: PThread; Signal: LongInt): Boolean;
begin
  Result := Thread^.IsUserThread and
    (((Thread^.Posix.SignalMask and SignalBit(Signal)) = 0) or
     ((Thread^.Posix.WaitedSignals and SignalBit(Signal)) <> 0));
end;

procedure ConsiderThread(Thread: PThread; Context: Pointer);
var
  Search: PTargetSearch;
begin
  Search := PTargetSearch(Context);
  if not ThreadTakes(Thread, Search^.Signal) then
    Exit;
  { One that waits for it in sigtimedwait is the best. }
  if (Search^.Chosen = nil) or ((Thread^.Posix.WaitedSignals and SignalBit(Search^.Signal)) <> 0) then
    Search^.Chosen := Thread;
end;

{ Alerts one thread that takes Signal, so it takes it soon; none if the
  sending thread is one of the process's and takes it itself (raise) at
  the end of this system call. From a timer's deferred call
  (FromSystemCall False) the thread that was interrupted may be about to
  wait, so it is alerted like any other. }
procedure WakeTakerOf(Process: PProcess; Signal: LongInt; FromSystemCall: Boolean);
var
  Search: TTargetSearch;
  Current: PThread;
begin
  Current := CurrentThreadObject;
  if FromSystemCall and (Current <> nil) and (Current^.Process = Process) and
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

procedure ConsiderUnblocking(Thread: PThread; Context: Pointer);
var
  Search: PTargetSearch;
begin
  Search := PTargetSearch(Context);
  if (Search^.Chosen = nil) and Thread^.IsUserThread and
     ((Thread^.Posix.SignalMask and SignalBit(Search^.Signal)) = 0) then
    Search^.Chosen := Thread;
end;

{ True if a thread of Process does not block Signal. }
function SomeThreadUnblocks(Process: PProcess; Signal: LongInt): Boolean;
var
  Search: TTargetSearch;
begin
  Search.Signal := Signal;
  Search.Chosen := nil;
  VisitProcessThreads(Process, @ConsiderUnblocking, @Search);
  Result := Search.Chosen <> nil;
end;

{ --- Leaving signals pending ---------------------------------------------- }

{ Leaves a signal waiting for the process: a real-time one queued
  (Entry, from the heap), another as one instance. ErrorWouldBlock if
  the queue is full (Entry is then freed). }
function MakePending(Process: PProcess; const Information: TAbiSignalInformation): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Signal: LongInt;
  Entry: PQueuedSignal;
  Queued: Boolean;
begin
  Signal := LongInt(Information.Signal);
  Entry := nil;
  if IsRealTime(Signal) then
  begin
    Entry := AllocateQueuedSignal(Information);
    if Entry = nil then
      Exit(ErrorWouldBlock);
  end;
  Queued := True;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  if Entry <> nil then
    Queued := AppendQueuedSignalLocked(Process, Entry)
  else if Process^.Posix.PendingInformation[Signal].Signal = 0 then
    Process^.Posix.PendingInformation[Signal] := Information;
  if Queued then
    Process^.Posix.PendingSignals := Process^.Posix.PendingSignals or SignalBit(Signal);
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  if not Queued then
  begin
    FreeQueuedSignals(Entry);
    Exit(ErrorWouldBlock);
  end;
  WakeTakerOf(Process, Signal, True);
  Result := ErrorNone;
end;

function PostSignalWithInformationLocked(Process: PProcess; const Information: TAbiSignalInformation): LongInt;
var
  Signal: LongInt;
begin
  Result := ErrorNone;
  Signal := LongInt(Information.Signal);
  if (Signal < 1) or (Signal > HighestSignal) or not Process^.IsUserProcess or Process^.HasExited then
    Exit;
  if Signal = SignalKill then
  begin
    TerminateBySignalLocked(Process, Signal);
    Exit;
  end;
  if IsDiscarded(Process, Signal) then
    Exit;
  if IsHandled(Process, Signal) then
    Result := MakePending(Process, Information)
  else if DefaultActionOf(Signal) = ActionTerminate then
  begin
    { Blocked by every thread, it waits (for a sigtimedwait, or to end
      the process once a thread unblocks it, DeliverPendingSignals). }
    if SomeThreadUnblocks(Process, Signal) then
      TerminateBySignalLocked(Process, Signal)
    else
      Result := MakePending(Process, Information);
  end;
  { Stopping and continuing take the registry lock themselves; from here
    (SIGCHLD, end requests) they do not come. }
end;

procedure PostSignalFromKernelLocked(Process: PProcess; Signal: LongInt; SenderProcessId: QWord);
begin
  PostSignalWithInformationLocked(Process, KernelInformation(Signal, SenderProcessId));
end;

procedure PostTimerSignal(Process: PProcess; Entry: PQueuedSignal; Missed: QWord; AtThreadReturn: Boolean);
var
  PreviousLevel: TPriorityLevel;
  Signal: LongInt;
  Overrun: QWord;
  Appended: Boolean;
begin
  Signal := LongInt(Entry^.Information.Signal);
  if (Signal < 1) or (Signal > HighestSignal) or Process^.HasExited or Process^.TerminationRequested or
     IsDiscarded(Process, Signal) then
    Exit;
  if not IsHandled(Process, Signal) and (DefaultActionOf(Signal) <> ActionTerminate) then
    Exit;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Appended := not Entry^.IsQueued;
  Overrun := QWord(Entry^.Information.Overrun) + Missed;
  if not Appended then
    Inc(Overrun);
  if Overrun > HighestOverrun then
    Overrun := HighestOverrun;
  Entry^.Information.Overrun := LongWord(Overrun);
  if Appended then
  begin
    AppendQueuedSignalLocked(Process, Entry);
    Process^.Posix.PendingSignals := Process^.Posix.PendingSignals or SignalBit(Signal);
  end;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  { A signal whose default action ends the process ends it when a
    thread takes it (DeliverPendingSignals). }
  if Appended then
    WakeTakerOf(Process, Signal, AtThreadReturn);
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

{ --- Taking signals -------------------------------------------------------- }

function SignalsWaitingFor(Process: PProcess; Thread: PThread): QWord;
begin
  Result := Thread^.Posix.PendingSignals or Process^.Posix.PendingSignals;
end;

{ The lowest signal set in Ready (not 0). }
function LowestSignalOf(Ready: QWord): LongInt;
begin
  Result := 1;
  while (Ready and SignalBit(Result)) = 0 do
    Inc(Result);
end;

{ Takes Signal from the process's pending signals; the signal lock held.
  A heap entry taken is returned in Spent, for freeing after the lock. }
procedure TakeProcessSignalLocked(Process: PProcess; Signal: LongInt; out Information: TAbiSignalInformation;
  out Spent: PQueuedSignal);
var
  Entry: PQueuedSignal;
begin
  Spent := nil;
  Entry := TakeQueuedSignalLocked(Process, Signal);
  if Entry <> nil then
  begin
    Information := Entry^.Information;
    if Entry^.Timer <> nil then
    begin
      Entry^.DeliveredOverrun := Entry^.Information.Overrun;
      Entry^.Information.Overrun := 0;
    end
    else
      Spent := Entry;
    { A signal that does not queue: the instance waiting as a bit is
      merged into this one. }
    if not SignalIsQueuedLocked(Process, Signal) then
    begin
      Process^.Posix.PendingSignals := Process^.Posix.PendingSignals and not SignalBit(Signal);
      ZeroMemory(@Process^.Posix.PendingInformation[Signal], SizeOf(TAbiSignalInformation));
    end;
  end
  else
  begin
    Information := Process^.Posix.PendingInformation[Signal];
    Process^.Posix.PendingSignals := Process^.Posix.PendingSignals and not SignalBit(Signal);
    ZeroMemory(@Process^.Posix.PendingInformation[Signal], SizeOf(TAbiSignalInformation));
  end;
  Information.Signal := LongWord(Signal);
end;

function TakeSignal(Process: PProcess; Thread: PThread; Allowed: QWord;
  out Information: TAbiSignalInformation): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Ready: QWord;
  Spent: PQueuedSignal;
begin
  Result := 0;
  Spent := nil;
  ZeroMemory(@Information, SizeOf(Information));
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Ready := SignalsWaitingFor(Process, Thread) and Allowed;
  if Ready <> 0 then
  begin
    Result := LowestSignalOf(Ready);
    if (Thread^.Posix.PendingSignals and SignalBit(Result)) <> 0 then
    begin
      Thread^.Posix.PendingSignals := Thread^.Posix.PendingSignals and not SignalBit(Result);
      Information := KernelInformation(Result, 0);
    end
    else
      TakeProcessSignalLocked(Process, Result, Information, Spent);
  end;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  FreeQueuedSignals(Spent);
end;

{ Where the record goes: on the alternate stack if the signal runs
  there, else below the red zone; 16-byte aligned. }
function SignalRecordAddress(Frame: PTrapFrame; Process: PProcess; Thread: PThread; Signal: LongInt): QWord;
var
  Top: QWord;
begin
  if not AlternateStackTopForSignal(Process, Thread, Signal, TrapFrameStackPointer(Frame), Top) then
    Top := TrapFrameStackPointer(Frame) - UserStackRedZoneSize;
  Result := (Top - SizeOf(TAbiSignalRecord)) and not QWord(15);
end;

{ Writes the record for Signal on the user stack and points Frame at
  the dispatcher. False if the record does not fit (the stack is gone). }
function EnterSignalDispatcher(Frame: PTrapFrame; Process: PProcess; Thread: PThread;
  const Information: TAbiSignalInformation): Boolean;
var
  SignalRecord: TAbiSignalRecord;
  Signal: LongInt;
  RecordAddress: QWord;
  ReturnSlot: QWord;
  NoReturnAddress: QWord;
  PreviousLevel: TPriorityLevel;
begin
  Signal := LongInt(Information.Signal);
  { A call the signal cut short is made again after the handler, or
    fails with ErrorInterrupted. }
  SettleInterruptedCallForHandler(Frame, (Process^.Posix.HandlerFlags[Signal] and SignalFlagRestart) <> 0);
  ZeroMemory(@SignalRecord, SizeOf(SignalRecord));
  SignalRecord.Signal := LongWord(Signal);
  SignalRecord.Code := Information.Code;
  SignalRecord.SenderProcessId := Information.SenderProcessId;
  SignalRecord.SenderUserId := Information.SenderUserId;
  SignalRecord.Value := Information.Value;
  SignalRecord.TimerId := Information.TimerId;
  SignalRecord.Overrun := Information.Overrun;
  CaptureUserContext(Frame, SignalRecord.Context);
  RecordAddress := SignalRecordAddress(Frame, Process, Thread, Signal);

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

  ReturnSlot := RecordAddress - SizeOf(QWord);
  NoReturnAddress := 0;
  Result := (CopyToUser(RecordAddress, @SignalRecord, SizeOf(SignalRecord)) = ErrorNone) and
    (CopyToUser(ReturnSlot, @NoReturnAddress, SizeOf(NoReturnAddress)) = ErrorNone);
  if Result then
    EnterExceptionDispatcher(Frame, Process^.Posix.SignalDispatcher, RecordAddress, ReturnSlot)
  else
    Thread^.Posix.SignalMask := SignalRecord.PreviousMask;
end;

procedure TerminateBySignal(Process: PProcess; Signal: LongInt);
begin
  LockProcessRegistry;
  TerminateBySignalLocked(Process, Signal);
  UnlockProcessRegistry;
end;

procedure DeliverPendingSignals(Frame: PTrapFrame);
var
  Process: PProcess;
  Thread: PThread;
  Signal: LongInt;
  Information: TAbiSignalInformation;
  WereEnabled: Boolean;
begin
  Process := CurrentProcess;
  if (Process = nil) or not Process^.IsUserProcess then
    Exit;
  Thread := CurrentThreadObject;
  if Thread^.Posix.AlertedForSignal then
    GiveUpSignalAlert(Process, Thread);
  if Process^.Posix.ArmedProcessorTimers > 0 then
  begin
    WereEnabled := SaveAndDisableInterrupts;
    EnableInterrupts;
    CheckProcessorTimers(Process, Thread);
    DisableInterrupts;
    RestoreInterrupts(WereEnabled);
  end;
  if (SignalsWaitingFor(Process, Thread) and not Thread^.Posix.SignalMask) = 0 then
    Exit;
  if Process^.TerminationRequested then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  EnableInterrupts;
  Signal := TakeSignal(Process, Thread, not Thread^.Posix.SignalMask, Information);
  if Signal <> 0 then
  begin
    { One that waited while blocked and is not handled (any more) takes
      its default action now. }
    if not IsHandled(Process, Signal) then
    begin
      if (Process^.Posix.Dispositions[Signal] = SignalDispositionDefault) and
         (DefaultActionOf(Signal) = ActionTerminate) then
        TerminateBySignal(Process, Signal);
    end
    else if not EnterSignalDispatcher(Frame, Process, Thread, Information) then
      TerminateBySignal(Process, Signal);
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
  Thread: PThread;
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
  { The alternate stack was memory of the old program. }
  Thread := CurrentThreadObject;
  Thread^.Posix.AlternateStack.Base := 0;
  Thread^.Posix.AlternateStack.Size := 0;
end;

procedure DiscardQueuedSignals(Process: PProcess);
var
  PreviousLevel: TPriorityLevel;
  Spent: PQueuedSignal;
begin
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Spent := RemoveAllQueuedSignalsLocked(Process);
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  FreeQueuedSignals(Spent);
end;

function PerformSetSignalDispatcher(Address: QWord): Int64;
begin
  if Address >= UserSpaceLimit then
    Exit(Failure(ErrorInvalidArgument));
  CurrentProcess^.Posix.SignalDispatcher := Address;
  Result := 0;
end;

{ --- kill and sigqueue ------------------------------------------------------ }

{ What to do with each process a kill reaches. }
type
  TSignalRequest = record
    Caller: PProcess;
    Information: TAbiSignalInformation;
    Target: Int64;
    Count: Integer;
    Denied: Integer;
    Full: Integer;
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

procedure PostRequested(Process: PProcess; Request: PSignalRequest);
begin
  if PostSignalWithInformationLocked(Process, Request^.Information) <> ErrorNone then
    Inc(Request^.Full);
end;

procedure SignalVisitedProcess(Process: PProcess; Context: Pointer);
var
  Request: PSignalRequest;
  Signal: LongInt;
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
  Signal := LongInt(Request^.Information.Signal);
  if Signal = 0 then
    Exit;
  { Each process the walk reaches is handled by its own dispositions:
    SIGSTOP always stops, SIGCONT continues (and is delivered), and the
    other stopping signals stop only where their action is the default
    one, are delivered where they are handled and do nothing where they
    are ignored. }
  if Signal = SignalStop then
    StopProcessLocked(Process)
  else if Signal = SignalContinue then
  begin
    ContinueProcessLocked(Process);
    PostRequested(Process, Request);
  end
  else if DefaultActionOf(Signal) = ActionStop then
  begin
    if Process^.Posix.Dispositions[Signal] = SignalDispositionDefault then
      StopProcessLocked(Process)
    else if Process^.Posix.Dispositions[Signal] = SignalDispositionHandle then
      PostRequested(Process, Request);
  end
  else
    PostRequested(Process, Request);
end;

function SendRequest(var Request: TSignalRequest): Int64;
begin
  Request.Count := 0;
  Request.Denied := 0;
  Request.Full := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@SignalVisitedProcess, @Request);
  UnlockProcessRegistry;
  if Request.Count = 0 then
  begin
    if Request.Denied > 0 then
      Exit(Failure(ErrorNotPermitted));
    Exit(Failure(ErrorNoSuchProcess));
  end;
  if Request.Full = Request.Count then
    Exit(Failure(ErrorWouldBlock));
  Result := 0;
end;

function NewRequest(Target: Int64; Signal: QWord; Code: LongWord; Value: Int64): TSignalRequest;
begin
  ZeroMemory(@Result, SizeOf(Result));
  Result.Caller := CurrentProcess;
  Result.Target := Target;
  Result.Information.Signal := LongWord(Signal);
  Result.Information.Code := Code;
  Result.Information.SenderProcessId := Int64(Result.Caller^.ProcessId);
  Result.Information.SenderUserId := Result.Caller^.Credentials.RealUserId;
  Result.Information.Value := Value;
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
  Request := NewRequest(Target, Signal, SignalFromProcess, 0);
  Result := SendRequest(Request);
end;

function PerformQueueSignal(Target: Int64; Signal: QWord; Value: Int64): Int64;
var
  Request: TSignalRequest;
begin
  if Signal > HighestSignal then
    Exit(Failure(ErrorInvalidArgument));
  { sigqueue reaches one process. }
  if Target <= 0 then
    Exit(Failure(ErrorNoSuchProcess));
  Request := NewRequest(Target, Signal, SignalFromQueue, Value);
  Result := SendRequest(Request);
end;

{ --- Masks and dispositions ------------------------------------------------ }

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
const
  KnownFlags = SignalFlagResetHandler or SignalFlagRestart or SignalFlagOnStack;
var
  Process: PProcess;
  PreviousLevel: TPriorityLevel;
  Spent: PQueuedSignal;
begin
  if (Signal < 1) or (Signal > HighestSignal) or (Signal = SignalKill) or (Signal = SignalStop) or
     (Disposition > SignalDispositionHandle) then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  Spent := nil;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Process^.Posix.Dispositions[Signal] := Byte(Disposition);
  Process^.Posix.HandlerMasks[Signal] := HandlerMask and not UnblockableSignals;
  Process^.Posix.HandlerFlags[Signal] := Byte(Flags and KnownFlags);
  { Ignoring a signal drops what of it waits. }
  if Disposition = SignalDispositionIgnore then
  begin
    Process^.Posix.PendingSignals := Process^.Posix.PendingSignals and not SignalBit(Signal);
    Spent := RemoveSignalFromQueueLocked(Process, LongInt(Signal));
    ZeroMemory(@Process^.Posix.PendingInformation[Signal], SizeOf(TAbiSignalInformation));
  end;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  FreeQueuedSignals(Spent);
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
  Result := (SignalsWaitingFor(Process, Thread) and not Thread^.Posix.SignalMask) <> 0;
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
  Result := Int64(SignalsWaitingFor(CurrentProcess, CurrentThreadObject) and not QWord($8000000000000000));
end;

end.
