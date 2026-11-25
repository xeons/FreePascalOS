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
  (the POSIX block, 180-199): signal dispositions and masks
  (Processes.Signals), the children fork made and their changes
  (Processes.ChildWaits). Types only, so Processes.Process and
  Processes.Thread can hold them.
}
unit Processes.PosixState;

{$mode objfpc}

interface

uses
  Kernel.SpinLock,
  Kernel.Events;

const
  PosixHighestSignal = 64;

type
  TProcessPosixState = record
    { Guards the signal fields of the process and of its threads. }
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
    { Who sent the pending ones (the last sender wins). }
    PendingSenders: array[1..PosixHighestSignal] of QWord;
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
  end;

implementation

end.
