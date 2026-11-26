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
  Waiting for signals: sigtimedwait and sigwaitinfo (CallWaitForSignal).

  The thread names a set of signals it blocks and takes one of them
  that waits, without a handler: the lowest first, a real-time one with
  the information of its oldest sending. While it waits, the set is its
  WaitedSignals, so a signal of the set that is sent to the process
  alerts this thread (Processes.Signals prefers it) although it blocks
  the signal. A signal outside the set that the thread does not block
  ends the wait with ErrorInterrupted, and its handler runs as the call
  returns; so does a stop or an end of the process. The timeout is in
  nanoseconds, waited for in whole milliseconds (rounded up).
}
unit Processes.SignalWaits;

{$mode objfpc}

interface

function PerformWaitForSignal(MaskAddress, InformationAddress: QWord; TimeoutNanoseconds: Int64): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.Clock,
  Kernel.Scheduler,
  Processes.Process,
  Processes.Thread,
  Processes.Signals,
  Processes.ThreadControl,
  Processes.UserAccess;

const
  { Neither waited for nor blocked: SIGKILL and SIGSTOP. }
  UnblockableSignals = (QWord(1) shl (SignalKill - 1)) or (QWord(1) shl (SignalStop - 1));
  { The longest single sleep (an alert ends it sooner). }
  SliceMilliseconds = 60000;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ A signal the thread would take with its handler waits. }
function DeliverableSignalWaits(Process: PProcess; Thread: PThread): Boolean;
begin
  Result := (SignalsWaitingFor(Process, Thread) and not Thread^.Posix.SignalMask) <> 0;
end;

{ Something other than a signal of the set asks the wait to end. }
function MustStopWaiting(Process: PProcess): Boolean;
begin
  Result := Process^.TerminationRequested or Process^.StopRequested or CurrentThreadIsAsked;
end;

{ Milliseconds to sleep until Deadline (a ClockNanoseconds time). }
function SleepFor(Deadline: QWord): QWord;
var
  Now: QWord;
begin
  Now := ClockNanoseconds;
  if Deadline <= Now then
    Exit(0);
  Result := (Deadline - Now + NanosecondsPerMillisecond - 1) div NanosecondsPerMillisecond;
  if Result > SliceMilliseconds then
    Result := SliceMilliseconds;
end;

{ Waits for a signal of Mask until Deadline (NeverDue: none); returns
  the signal or minus an error. }
function WaitForSignalOf(Process: PProcess; Thread: PThread; Mask: QWord; Deadline: QWord;
  out Information: TAbiSignalInformation): Int64;
var
  Milliseconds: QWord;
begin
  { An alert a signal taken earlier left must not end this wait. }
  if not DeliverableSignalWaits(Process, Thread) and not MustStopWaiting(Process) then
    ClearCurrentThreadAlert;
  Thread^.Posix.WaitedSignals := Mask;
  repeat
    Result := TakeSignal(Process, Thread, Mask, Information);
    if Result <> 0 then
      Break;
    if DeliverableSignalWaits(Process, Thread) or MustStopWaiting(Process) then
    begin
      Result := Failure(ErrorInterrupted);
      Break;
    end;
    if Deadline = NeverDue then
      Milliseconds := SliceMilliseconds
    else
      Milliseconds := SleepFor(Deadline);
    if Milliseconds = 0 then
    begin
      Result := Failure(ErrorWouldBlock);
      Break;
    end;
    if not SleepAlertable(Milliseconds) then
    begin
      { Alerted for a signal of the set another thread took first: wait
        on. Anything else is seen at the top. }
      if Thread^.Posix.AlertedForSignal and not MustStopWaiting(Process) and
         not DeliverableSignalWaits(Process, Thread) and
         ((SignalsWaitingFor(Process, Thread) and Mask) = 0) then
      begin
        Thread^.Posix.AlertedForSignal := False;
        ClearCurrentThreadAlert;
      end;
    end;
  until False;
  Thread^.Posix.WaitedSignals := 0;
end;

function PerformWaitForSignal(MaskAddress, InformationAddress: QWord; TimeoutNanoseconds: Int64): Int64;
var
  Process: PProcess;
  Thread: PThread;
  Mask: QWord;
  Deadline: QWord;
  Information: TAbiSignalInformation;
  Error: LongInt;
begin
  Error := CopyFromUser(@Mask, MaskAddress, SizeOf(Mask));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Mask := Mask and not UnblockableSignals;
  if TimeoutNanoseconds < 0 then
    Deadline := NeverDue
  else
    Deadline := ClockNanoseconds + QWord(TimeoutNanoseconds);
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  Result := WaitForSignalOf(Process, Thread, Mask, Deadline, Information);
  if (Result > 0) and (InformationAddress <> 0) then
  begin
    Error := CopyToUser(InformationAddress, @Information, SizeOf(Information));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
end;

end.
