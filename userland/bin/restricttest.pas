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
  restricttest - checks the process restrictions (the sandbox of a
  browser's content process; ProcessLimitRestrictions)

  restricttest [--child]

  Unknown flags are refused; with RestrictNetwork a socket cannot be
  made, and a child started then (restricttest --child) has the flag
  too and cannot make one either; flags are never taken away. With
  every flag: a file cannot be written, created or removed, a file
  outside /lib and /etc cannot be read (one written just before) nor
  looked at, /lib/fonts can be listed and /dev/null opened, no program
  can be started, no port connected to, no other process ended. Prints
  a line per check and "restricttest: N checks, M failed"; the status
  is the number failed.
}
program RestrictTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Objects,
  Sys.Processes,
  Sys.Sockets,
  Sys.Restrictions;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const Name: string);
begin
  Inc(Checks);
  if Condition then
    WriteLn('ok   ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('FAIL ', Name);
  end;
end;

function SocketRefused: Boolean;
var
  Socket: Int64;
begin
  Socket := CreateSocket(AddressFamilyIPv4, SocketKindStream, 0);
  Result := Socket = -ErrorAccessDenied;
  if Socket >= 0 then
    CloseHandle(Socket);
end;

function OpenResult(const Path: string; Flags: LongWord): Int64;
begin
  Result := KernelOpen(PChar(Path), Flags);
  if Result >= 0 then
    CloseHandle(Result);
end;

function RunChild: LongInt;
var
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Handle: Int64;
begin
  Arguments[0] := PChar(ParamStr(0));
  Arguments[1] := '--child';
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Handle := StartProgram(PChar(ParamStr(0)), @Arguments[0], Options);
  if Handle < 0 then
    Exit(LongInt(Handle));
  Result := WaitForProgram(Handle);
end;

procedure CheckEverything;
const
  Scratch = '/tmp/restricttest.txt';
var
  Text: TextFile;
  Search: TSearchRec;
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Sleeper: Int64;
begin
  { Someone to fail to end (a process of our own, not one that matters). }
  Arguments[0] := '/bin/sleep';
  Arguments[1] := '5';
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Sleeper := StartProgram('/bin/sleep', @Arguments[0], Options);
  AssignFile(Text, Scratch);
  Rewrite(Text);
  WriteLn(Text, 'secret');
  CloseFile(Text);
  Check(RestrictThisProcess(RestrictionsAll) = ErrorNone, 'every restriction taken');
  Check(ThisProcessRestrictions = RestrictionsAll, 'every flag set');
  Check(OpenResult(Scratch, OpenRead) = -ErrorAccessDenied, 'a file under /tmp cannot be read');
  Check(OpenResult('/tmp/restricttest-new.txt', OpenWrite or OpenCreate) = -ErrorAccessDenied,
    'a file cannot be created');
  Check(OpenResult('/lib/libsystem.so', OpenRead or OpenWrite) = -ErrorAccessDenied, 'a library cannot be written');
  Check(not DeleteFile(Scratch), 'a file cannot be removed');
  Check(not FileExists(Scratch), 'a file outside /lib and /etc cannot be looked at');
  Check(FindFirst('/lib/fonts/*', faAnyFile, Search) = 0, '/lib/fonts can be listed');
  FindClose(Search);
  Check(OpenResult('/lib/libsystem.so', OpenRead) >= 0, 'a library can be read');
  Check(OpenResult('/dev/null', OpenRead) >= 0, '/dev/null can be opened');
  Check(OpenResult('/volumes', OpenRead) = -ErrorAccessDenied, 'other volumes cannot be reached');
  Arguments[0] := '/bin/true';
  Arguments[1] := nil;
  Check(StartProgram('/bin/true', @Arguments[0], Options) = -ErrorAccessDenied, 'no program can be started');
  Check(ConnectPort('display') = -ErrorAccessDenied, 'no port can be connected to');
  Check(CreatePort('restricttest') = -ErrorAccessDenied, 'no port can be made');
  Check((Sleeper >= 0) and (TerminateProgram(ProcessIdOf(Sleeper), 143) <> ErrorNone),
    'no other process can be ended');
end;

begin
  if ParamStr(1) = '--child' then
  begin
    if SocketRefused and (ThisProcessRestrictions = RestrictNetwork) then
      Halt(0);
    Halt(1);
  end;
  Check(ThisProcessRestrictions = 0, 'no restrictions at first');
  Check(RestrictThisProcess($100) = ErrorInvalidArgument, 'an unknown flag is refused');
  Check(not SocketRefused, 'a socket can be made before');
  Check(RestrictThisProcess(RestrictNetwork) = ErrorNone, 'the network taken away');
  Check(SocketRefused, 'no socket then');
  Check(RestrictThisProcess(0) = ErrorNone, 'adding nothing');
  Check(ThisProcessRestrictions = RestrictNetwork, 'nothing taken away');
  Check(RunChild = 0, 'a child inherits the restriction');
  CheckEverything;
  WriteLn('restricttest: ', Checks, ' checks, ', Failures, ' failed');
  Halt(Failures);
end.
