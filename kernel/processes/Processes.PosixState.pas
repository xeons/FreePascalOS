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
  What a process and a thread keep for the POSIX calls of the C library
  (the POSIX block, 180-199, and signals and timers, 240-249): signal
  dispositions and masks (Processes.Signals), queued signals
  (Processes.SignalQueue), the alternate signal stack, POSIX timers
  (Processes.PosixTimers), the children fork made and their changes
  (Processes.ChildWaits). Types only, so Processes.Process and
  Processes.Thread can hold them.
}
unit Processes.PosixState;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Kernel.SpinLock,
  Kernel.Events;

const
  PosixHighestSignal = 64;

type
  { A signal waiting with its own information: a real-time signal (one
    entry per sending), or a POSIX timer's (embedded in the timer, so a
    timer's signal never needs memory; its expiries while it waits add
    to the timer's overrun). }
  PQueuedSignal = ^TQueuedSignal;
  TQueuedSignal = record
    Next: PQueuedSignal;
    { A timer's: its Overrun counts the expiries while it waits. }
    Information: TAbiSignalInformation;
    { A timer's: the overrun its last signal taken stood for. }
    DeliveredOverrun: LongWord;
    { The PPosixTimer it is part of; nil for one from the kernel heap. }
    Timer: Pointer;
    IsQueued: Boolean;
  end;

  { A thread's alternate signal stack; Size 0 for none. }
  TAlternateSignalStack = record
    Base: QWord;
    Size: QWord;
  end;

  TProcessPosixState = record
    { Guards the signal fields of the process and of its threads, the
      signal queue and the state of the process's timers. }
    SignalLock: TSpinLock;
    { Where a thread continues to take a handled signal; 0 for none. }
    SignalDispatcher: QWord;
    { SignalDisposition* per signal, the mask its handler runs with and
      SignalFlag*. }
    Dispositions: array[1..PosixHighestSignal] of Byte;
    HandlerFlags: array[1..PosixHighestSignal] of Byte;
    HandlerMasks: array[1..PosixHighestSignal] of QWord;
    { Signals sent to the process that no thread has taken yet. }
    PendingSignals: QWord;
    { Who sent the pending ones that do not queue, and why (the first
      sending wins: another one while it waits is merged into it). }
    PendingInformation: array[1..PosixHighestSignal] of TAbiSignalInformation;
    { The signals waiting with information, in the order sent
      (Processes.SignalQueue), and how many came from the kernel heap. }
    QueueHead: PQueuedSignal;
    QueueTail: PQueuedSignal;
    QueuedCount: LongInt;
    { The POSIX and interval timers (a PPosixTimerTable; nil until the
      first), how many processor-time timers are armed, and the clock
      tick they were last looked at in (Processes.PosixTimers). }
    Timers: Pointer;
    ArmedProcessorTimers: LongInt;
    ProcessorTimersCheckedTick: QWord;
    { The signal that ended the process (0: it exited or was ended
      otherwise), for its parent's waitpid. }
    EndSignal: LongInt;
    { The children fork made, each referenced until waited for (or until
      this process ends): a kernel array of PProcess. Guarded by the
      process's Lock. }
    Children: PPointer;
    ChildCount: LongInt;
    ChildCapacity: LongInt;
    { Signaled whenever a child ends or stops (manual reset: a waiter
      resets it before it looks). }
    ChildChangedEvent: TEvent;
    { The stop was reported to the parent's waitpid (WaitUntraced). }
    StopReportedToParent: Boolean;
  end;

  TThreadPosixState = record
    { The signals the thread blocks (bit N - 1 for signal N). }
    SignalMask: QWord;
    { Signals sent to the thread itself. }
    PendingSignals: QWord;
    { sigsuspend: the mask to give back once a signal is taken. }
    SavedSignalMask: QWord;
    HasSavedSignalMask: Boolean;
    { It was alerted to take a signal (another thread may take it first):
      the alert is given up at its next return to user mode. }
    AlertedForSignal: Boolean;
    { sigtimedwait: the signals it waits for (blocked, yet a sending
      alerts it). }
    WaitedSignals: QWord;
    { sigaltstack. }
    AlternateStack: TAlternateSignalStack;
    { A system call a signal cut short that may be made again
      (SA_RESTART): its number plus one (0: none) and first argument
      (Processes.SystemCallRestart). }
    InterruptedCall: QWord;
    InterruptedArgument: QWord;
    { The clock tick its processor-time timers were last looked at in. }
    ProcessorTimersCheckedTick: QWord;
  end;

implementation

end.
