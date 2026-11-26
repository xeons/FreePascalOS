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
  System calls a signal cut short, made again (SA_RESTART).

  A signal alerts a thread that waits in a system call; the wait ends
  and the call fails with ErrorInterrupted. If the call is one that may
  be made again, the end of the call notes it (NoteInterruptedCall).
  Then, as the thread goes back to user mode:

    * a handler set up with SignalFlagRestart is entered with the frame
      rewound to the system call instruction (the number, and on AArch64
      the first argument, given back): when the handler returns, the
      call is made again, from the start;
    * a handler without the flag sees ErrorInterrupted;
    * if no handler runs at all (another thread took the signal, or it
      was blocked again), the call is made again at once.

  The calls POSIX never restarts fail with ErrorInterrupted whatever the
  flag: the waits for signals (sigsuspend, sigtimedwait), sleeps,
  CallWaitForHandles and CallWaitForSocket (poll, select), the address
  waits (futexes, whose callers look again anyway) and anything else not
  listed in IsRestartableCall. A restarted call starts over, so a call
  with a timeout of its own would wait it out again in full: the calls
  listed have none (a socket's receive timeout aside).
}
unit Processes.SystemCallRestart;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

{ True for the calls a signal may cut short and SA_RESTART make again. }
function IsRestartableCall(Number: QWord): Boolean;

{ At the end of a call: notes it for restarting if it failed with
  ErrorInterrupted because a signal alerted the thread, and may be made
  again. }
procedure NoteInterruptedCall(Number, Argument0: QWord; CallResult: Int64; AlertedForSignal: Boolean);
{ Before a handler is entered: with Restart (SignalFlagRestart) the noted
  call is made again once the handler returns. The note is spent either
  way. }
procedure SettleInterruptedCallForHandler(Frame: PTrapFrame; Restart: Boolean);
{ At the very end of the call, signals delivered: a note still there
  means no handler ran, so the call is made again. }
procedure RestartInterruptedCallIfNoted(Frame: PTrapFrame);

implementation

uses
  Abi.SystemCalls,
  Kernel.Arch.SystemCallEntry,
  Processes.Thread;

function IsRestartableCall(Number: QWord): Boolean;
begin
  case Number of
    CallRead, CallWrite, CallOpen, CallControlHandle, CallWaitForProcess, CallWaitForThread,
    CallSendMessage, CallReceiveMessage, CallAcceptSocket, CallSendSocket, CallReceiveSocket,
    CallWaitForChild:
      Result := True;
  else
    Result := False;
  end;
end;

procedure NoteInterruptedCall(Number, Argument0: QWord; CallResult: Int64; AlertedForSignal: Boolean);
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  Thread^.Posix.InterruptedCall := 0;
  if (CallResult <> -Int64(ErrorInterrupted)) or not AlertedForSignal or not IsRestartableCall(Number) then
    Exit;
  Thread^.Posix.InterruptedCall := Number + 1;
  Thread^.Posix.InterruptedArgument := Argument0;
end;

procedure SettleInterruptedCallForHandler(Frame: PTrapFrame; Restart: Boolean);
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  if Thread^.Posix.InterruptedCall = 0 then
    Exit;
  if Restart then
    RewindSystemCall(Frame, Thread^.Posix.InterruptedCall - 1, Thread^.Posix.InterruptedArgument);
  Thread^.Posix.InterruptedCall := 0;
end;

procedure RestartInterruptedCallIfNoted(Frame: PTrapFrame);
begin
  SettleInterruptedCallForHandler(Frame, True);
end;

end.
