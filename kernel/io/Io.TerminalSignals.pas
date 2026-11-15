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
  Where the terminals' signal keys and hang-ups wait for a thread.

  Ctrl-C and Ctrl-Z on a terminal end or stop the terminal's foreground
  process group, and a pseudo-terminal whose master side was closed
  ends the processes it controls. That needs locks an interrupt handler
  (the keyboard's, for the console) cannot take, and the process layer,
  which the I/O layer does not know. So a terminal only notes what
  happened (Io.LineDiscipline keeps the flags) and calls
  RaiseTerminalSignal, from any priority level; a deferred call wakes
  one thread (Processes.TerminalSignals), which looks at every terminal
  registered here and acts for each.

  Terminals are kept as untyped pointers (their line disciplines) and
  are never removed: pseudo-terminals are a pool whose pairs are reused.
}
unit Io.TerminalSignals;

{$mode objfpc}

interface

const
  MaximumSignalTerminals = 32;

procedure InitializeTerminalSignals;

{ Adds a terminal (a PLineDiscipline) to the ones the thread looks at.
  Callers are serialized (the console at start, then the pseudo-terminal
  pool under its lock). }
procedure RegisterSignalTerminal(Terminal: Pointer);
function SignalTerminalCount: LongInt;
function SignalTerminalAt(Index: LongInt): Pointer;

{ Something happened on a terminal: wakes the thread. Any level. }
procedure RaiseTerminalSignal;
{ For the thread: waits until RaiseTerminalSignal is called (or was,
  since the last wait). }
procedure WaitForTerminalSignals;

implementation

uses
  Kernel.Events,
  Kernel.DeferredCalls,
  Kernel.Panic;

var
  Terminals: array[0..MaximumSignalTerminals - 1] of Pointer;
  TerminalCount: LongInt;
  SignalRaised: TEvent;
  WakeHandler: TDeferredCall;

procedure WakeSignalThread(Context: Pointer);
begin
  SignalEvent(SignalRaised);
end;

procedure InitializeTerminalSignals;
begin
  InitializeEvent(SignalRaised, EventKindSynchronization, False);
  InitializeDeferredCall(WakeHandler, @WakeSignalThread, nil);
end;

procedure RegisterSignalTerminal(Terminal: Pointer);
begin
  if TerminalCount = MaximumSignalTerminals then
    KernelPanic('too many terminals');
  { The slot is filled before the count includes it, so the thread
    never looks at an empty one. }
  Terminals[TerminalCount] := Terminal;
  Inc(TerminalCount);
end;

function SignalTerminalCount: LongInt;
begin
  Result := TerminalCount;
end;

function SignalTerminalAt(Index: LongInt): Pointer;
begin
  Result := Terminals[Index];
end;

procedure RaiseTerminalSignal;
begin
  QueueDeferredCall(WakeHandler);
end;

procedure WaitForTerminalSignals;
begin
  WaitForEvent(SignalRaised);
end;

end.
