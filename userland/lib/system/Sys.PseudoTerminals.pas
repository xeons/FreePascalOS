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
  Pseudo-terminals: a terminal for programs (/dev/ptsN, a console to
  them) that this program shows, as a terminal window does.

  CreatePseudoTerminal gives the master side as two handles - read
  OutputHandle for what programs write (wait on it until there is
  some), write InputHandle to type (wait on it until there is room) -
  and the terminal itself (TerminalHandle). StartOnTerminal starts a
  program with the terminal as its standard handles, in a new group
  that is the terminal's foreground group, with the terminal as its
  controlling terminal; the creator then usually closes its
  TerminalHandle, so that reading OutputHandle gives end of file once
  the programs are gone. Closing both master handles hangs the terminal
  up, which ends the programs it controls.
}
unit Sys.PseudoTerminals;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

{ A new pseudo-terminal of Rows by Columns; returns 0 or an error code
  (ErrorBusy when every one is taken). }
function CreatePseudoTerminal(Rows, Columns: LongInt; out Terminal: TAbiPseudoTerminal): LongInt;
{ Starts Path with Arguments (nil terminated) on the terminal behind
  TerminalHandle; returns a process handle or a negative error. }
function StartOnTerminal(Path: PChar; Arguments: PPChar; TerminalHandle: Int64): Int64;
{ "/dev/ptsN" for Number, in Buffer (at least 16 bytes). }
function PseudoTerminalPath(Number: Int64): string;

implementation

uses
  SysUtils,
  Sys.Kernel,
  Sys.Errors,
  Sys.Processes;

function CreatePseudoTerminal(Rows, Columns: LongInt; out Terminal: TAbiPseudoTerminal): LongInt;
begin
  Terminal.OutputHandle := NoHandle;
  Terminal.InputHandle := NoHandle;
  Terminal.TerminalHandle := NoHandle;
  Terminal.Number := -1;
  Result := ErrorCodeOf(KernelCreatePseudoTerminal(@Terminal, (QWord(Rows) shl 16) or QWord(Columns)));
end;

function StartOnTerminal(Path: PChar; Arguments: PPChar; TerminalHandle: Int64): Int64;
var
  Options: TProcessOptions;
begin
  DefaultProcessOptions(Options);
  Options.InputHandle := TerminalHandle;
  Options.OutputHandle := TerminalHandle;
  Options.ErrorHandle := TerminalHandle;
  Options.GroupId := GroupNewInForeground;
  Result := StartProgram(Path, Arguments, Options);
end;

function PseudoTerminalPath(Number: Int64): string;
begin
  Result := '/dev/pts' + IntToStr(QWord(Number));
end;

end.
