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
  What hangtest says: "hangtest: ready PID MODE" once it is (about to
  be) stuck, so a test knows when to end it, and the helpers every way
  of getting stuck shares.
}
unit HangTest.Report;

{$mode objfpc}{$H+}

interface

{ Says the program is ready to be ended, stuck in Mode. }
procedure SayReady(const Mode: string);
{ Says something went wrong setting the hang up, and ends with 1. }
procedure GiveUp(const What: string; Error: Int64);
{ Spins for ever in user mode, never entering the kernel. }
procedure SpinForever;
{ Sleeps for ever (in steps, so each is an ordinary sleep). }
procedure SleepForever;
{ Starts a thread running Routine; gives up if it cannot. }
procedure StartThreadOrGiveUp(Routine: Pointer; Argument: Pointer);

implementation

uses
  SysUtils,
  Sys.Processes,
  Sys.Streams,
  Sys.Threads;

var
  ReadyMode: string;

procedure SayReady(const Mode: string);
begin
  ReadyMode := Mode;
  PrintString(Format('hangtest: ready %d %s'#10, [CurrentProcessId, Mode]));
  FlushStream(StandardOutput);
end;

procedure GiveUp(const What: string; Error: Int64);
begin
  PrintString(Format('hangtest: %s failed (%d)'#10, [What, Error]));
  FlushStream(StandardOutput);
  ExitProgram(1);
end;

{ The sum is written out, so the loop is not optimized away. }
var
  SpinSink: QWord;

procedure SpinForever;
var
  Sum: QWord;
  Round: LongInt;
begin
  Sum := 0;
  while True do
  begin
    for Round := 1 to 100000 do
      Sum := Sum * 31 + QWord(Round);
    SpinSink := Sum;
  end;
end;

procedure SleepForever;
begin
  while True do
    SleepMilliseconds(3600 * 1000);
end;

procedure StartThreadOrGiveUp(Routine: Pointer; Argument: Pointer);
var
  Handle: Int64;
begin
  Handle := CreateThread(TThreadRoutine(Routine), Argument);
  if Handle < 0 then
    GiveUp('starting a thread', Handle);
end;

end.
