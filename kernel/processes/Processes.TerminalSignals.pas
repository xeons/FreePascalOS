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
  The thread that acts on the terminals' signals (Io.TerminalSignals),
  for the console and every pseudo-terminal alike:

    * Ctrl-C ends the terminal's foreground group with status 130,
      sparing processes that ignore it (Processes.Termination); if that
      ended nobody (an interactive shell waiting at its prompt is the
      foreground), the reader gets Ctrl-C as a character instead;
    * Ctrl-Z stops the foreground group (Processes.Stopping); with
      nobody to stop it does nothing;
    * a hang-up (a pseudo-terminal's master closed) ends every process
      whose controlling terminal it is with status 129, as SIGHUP would.
}
unit Processes.TerminalSignals;

{$mode objfpc}

interface

{ Starts the thread (needs a running scheduler). }
procedure StartTerminalSignalHandler;

implementation

uses
  Io.LineDiscipline,
  Io.TerminalSignals,
  Processes.Thread,
  Processes.Termination,
  Processes.Stopping;

const
  InterruptExitCode = 130;
  HangUpExitCode = 129;
  SignalThreadPriority = 20;

procedure ActOnSignal(var Terminal: TLineDiscipline; Signal: TTerminalSignal);
begin
  case Signal of
    TerminalSignalInterrupt:
      if InterruptProcessGroup(Terminal.ForegroundGroup, InterruptExitCode) > 0 then
        FinishTerminalInterrupt(Terminal)
      else
        PassInterruptToTerminalReader(Terminal);
    TerminalSignalSuspend:
      if SuspendProcessGroup(Terminal.ForegroundGroup) > 0 then
        FinishTerminalSuspend(Terminal);
    TerminalSignalHangUp:
      TerminateProcessesOfTerminal(@Terminal, HangUpExitCode);
  end;
end;

procedure HandleTerminalSignals(Context: Pointer);
var
  Index: LongInt;
  Terminal: PLineDiscipline;
  Signal: TTerminalSignal;
begin
  repeat
    WaitForTerminalSignals;
    Index := 0;
    while Index < SignalTerminalCount do
    begin
      Terminal := PLineDiscipline(SignalTerminalAt(Index));
      while TakeTerminalSignal(Terminal^, Signal) do
        ActOnSignal(Terminal^, Signal);
      Inc(Index);
    end;
  until False;
end;

procedure StartTerminalSignalHandler;
begin
  CreateSystemThread(@HandleTerminalSignals, nil, SignalThreadPriority, 'terminal-signals', False);
end;

end.
