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
  threadnametest - thread names

  Names its main thread "namer" (Sys.Threads.SetThreadName), starts a
  TThread that names itself "worker-tthread" (NameThreadForDebugging)
  and a plain thread that the main thread names "worker-plain" by its
  id, checks that ListThreads shows the three names, then runs
  "ps -L -p PID -o comm=" on itself, whose lines (sorted) must be the
  same names. Prints "threadnametest: names listed" and ps's lines;
  exits with 1 if a name is missing.
}
program threadnametest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Sys.Streams,
  Sys.Threads,
  Sys.Locks,
  Sys.Processes;

type
  TNamedWorker = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Gate: TLock;
  NamedCount: LongInt = 0;

procedure WaitAtGate;
begin
  AcquireLock(Gate);
  ReleaseLock(Gate);
end;

procedure TNamedWorker.Execute;
begin
  NameThreadForDebugging('worker-tthread');
  AtomicAdd32(NamedCount, 1);
  WaitAtGate;
end;

function PlainWorker(Argument: Pointer): LongInt;
begin
  WaitAtGate;
  Result := 0;
end;

function HasThreadNamed(const Threads: TThreadDetailsList; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Threads) do
    if Threads[Index].Name = Name then
      Exit(True);
  Result := False;
end;

function RunPs: LongInt;
var
  Arguments: array[0..3] of PChar;
  Command: string;
begin
  Command := Format('ps -L -p %d -o comm= | sort', [CurrentProcessId]);
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := PChar(Command);
  Arguments[3] := nil;
  Result := RunProgram('/bin/sh', @Arguments[0]);
end;

var
  Worker: TNamedWorker;
  PlainHandle: Int64;
  ThreadExitCode: LongInt;
  Threads: TThreadDetailsList;
  Passed: Boolean;
begin
  InitializeLock(Gate);
  AcquireLock(Gate);
  Passed := SetThreadName('namer') = 0;

  Worker := TNamedWorker.Create(False);
  PlainHandle := CreateThread(@PlainWorker, nil);
  Passed := Passed and (PlainHandle >= 0) and (SetThreadName('worker-plain', GetThreadId(PlainHandle)) = 0);
  while NamedCount < 1 do
    YieldThread;

  Passed := Passed and (ListThreads(0, Threads) = 0) and HasThreadNamed(Threads, 'namer') and
    HasThreadNamed(Threads, 'worker-tthread') and HasThreadNamed(Threads, 'worker-plain');
  if Passed then
    PrintStringLine('threadnametest: names listed')
  else
    PrintStringLine('threadnametest: FAIL: the names are not all listed');
  FlushStandardStreams;
  RunPs;

  ReleaseLock(Gate);
  Worker.WaitFor;
  Worker.Free;
  if PlainHandle >= 0 then
  begin
    WaitForThread(PlainHandle, -1, ThreadExitCode);
    CloseThreadHandle(PlainHandle);
  end;
  if not Passed then
    Halt(1);
end.
