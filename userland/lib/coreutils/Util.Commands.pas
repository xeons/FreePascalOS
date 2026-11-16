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
  Running a command given on the command line, as env, nice, nohup,
  stdbuf, chroot and timeout do, with the usual exit statuses:

    127  the command was not found
    126  it was found but could not be started
    otherwise the command's own exit status

  Also the signal names used by kill, pkill and timeout. The system has
  no signals; each becomes what it stands for:

    TERM, HUP, INT     a request to end (Sys.Notifications) with the
                       reason asked, hang-up or interrupt: a program
                       that takes it decides itself (it may tidy up
                       first); any other is ended with exit status 128
                       + the signal's number, as before
    KILL and the rest  of the signals that end a program: ended at once
                       with 128 + the number, which is what a shell
                       reports for a program killed by that signal
    STOP, TSTP, TTIN,  stop a program, CONT continues it (job control)
    TTOU
    CHLD, URG, WINCH   ignored as on Unix (signal 0 too: they only check
                       that the process exists)
}
unit Util.Commands;

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Sys.Processes;

const
  StatusCommandNotFound = 127;
  StatusCommandNotRunnable = 126;
  SignalHangUp = 1;
  SignalInterrupt = 2;
  SignalTerminate = 15;
  SignalKill = 9;
  SignalContinue = 18;
  SignalStop = 19;
  SignalTerminalStop = 20;

{ Starts Arguments[0] (looked up in PATH) with Options. Returns the
  process handle, or reports the problem and returns -1 with Status set
  to 126 or 127. }
function StartCommand(Arguments: PPChar; const Options: TProcessOptions; out Status: LongInt): Int64; overload;
function StartCommand(const Arguments: array of string; const Options: TProcessOptions;
  out Status: LongInt): Int64; overload;
{ Starts the command, waits for it, and ends this program with its
  status. }
procedure RunCommandAndExit(Arguments: PPChar; const Options: TProcessOptions); overload;
procedure RunCommandAndExit(const Arguments: array of string; const Options: TProcessOptions); overload;

type
  { A nil terminated list of PChar for the system calls (arguments, an
    environment); it points into strings the caller keeps alive. }
  TTextVector = array of PChar;

function TextVector(const Items: array of string): TTextVector;

{ Finds Name in PATH (or takes it as a path if it contains '/'); False
  if it is not there. }
function FindProgramPath(const Name: string; out Path: string): Boolean;

{ Parses "TERM", "SIGTERM" or "15"; returns -1 if unknown. }
function ParseSignal(Text: PChar): Integer; overload;
function ParseSignal(const Text: string): Integer; overload;
{ "TERM" for 15; nil if the number has no name. }
function SignalName(Number: Integer): PChar;
{ The same as a string; '' if the number has no name. }
function SignalNameText(Number: Integer): string;

type
  TSignalAction = (SignalActionNone, SignalActionAskToEnd, SignalActionEnd, SignalActionStop,
    SignalActionContinue);

function ActionOfSignal(Number: Integer): TSignalAction;
{ Delivers a signal as described above. Target is a process id, or the
  negated id of a process group (ending a whole group at once is not
  supported; asking it is).
  Returns 0 or an error code. }
function SendSignal(Target: Int64; Number: Integer): LongInt;
const
  HighestSignal = 31;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Notifications,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages;

const
  ProgramPathCapacity = 1024;
  SignalNames: array[1..HighestSignal] of PChar = (
    'HUP', 'INT', 'QUIT', 'ILL', 'TRAP', 'ABRT', 'BUS', 'FPE', 'KILL', 'USR1', 'SEGV', 'USR2',
    'PIPE', 'ALRM', 'TERM', 'STKFLT', 'CHLD', 'CONT', 'STOP', 'TSTP', 'TTIN', 'TTOU', 'URG',
    'XCPU', 'XFSZ', 'VTALRM', 'PROF', 'WINCH', 'POLL', 'PWR', 'SYS');

function StartCommand(Arguments: PPChar; const Options: TProcessOptions; out Status: LongInt): Int64;
var
  ProgramPath: array[0..ProgramPathCapacity - 1] of Char;
begin
  Status := 0;
  if not FindProgram(Arguments[0], @ProgramPath[0], ProgramPathCapacity) then
  begin
    ReportError(2, '''%s''', [ArgumentText(Arguments[0])]);
    Status := StatusCommandNotFound;
    Exit(-1);
  end;
  FlushStandardStreams;
  Result := StartProgram(@ProgramPath[0], Arguments, Options);
  if Result < 0 then
  begin
    ReportError(ErrorCodeOf(Result), '''%s''', [ArgumentText(Arguments[0])]);
    Status := StatusCommandNotRunnable;
    Result := -1;
  end;
end;

procedure RunCommandAndExit(Arguments: PPChar; const Options: TProcessOptions);
var
  Handle: Int64;
  Status: LongInt;
begin
  Handle := StartCommand(Arguments, Options, Status);
  if Handle < 0 then
    Halt(Status);
  Status := WaitForProgram(Handle);
  if Status < 0 then
    Halt(StatusCommandNotRunnable);
  Halt(Status);
end;

function ParseSignal(Text: PChar): Integer;
var
  Number: Int64;
  Index: Integer;
begin
  if ParseInteger(Text, Number) then
  begin
    if (Number >= 0) and (Number <= HighestSignal) then
      Exit(Integer(Number));
    Exit(-1);
  end;
  if TextStartsWith(Text, 'SIG') or TextStartsWith(Text, 'sig') then
    Text := Text + 3;
  for Index := 1 to HighestSignal do
  begin
    if CompareTextIgnoringCase(Text, SignalNames[Index]) = 0 then
      Exit(Index);
  end;
  Result := -1;
end;

function SignalName(Number: Integer): PChar;
begin
  if (Number < 1) or (Number > HighestSignal) then
    Exit(nil);
  Result := SignalNames[Number];
end;

function ActionOfSignal(Number: Integer): TSignalAction;
begin
  case Number of
    0, 17, 23, 28: Result := SignalActionNone;
    SignalHangUp, SignalInterrupt, SignalTerminate: Result := SignalActionAskToEnd;
    SignalContinue: Result := SignalActionContinue;
    SignalStop, SignalTerminalStop, 21, 22: Result := SignalActionStop;
  else
    Result := SignalActionEnd;
  end;
end;

function EndReasonOfSignal(Number: Integer): LongWord;
begin
  case Number of
    SignalHangUp: Result := EndReasonHangUp;
    SignalInterrupt: Result := EndReasonInterrupt;
  else
    Result := EndReasonAsked;
  end;
end;

function AskToEnd(Target: Int64; Number: Integer): LongInt;
var
  Asked: Int64;
begin
  if Target > 0 then
    Exit(AskProcessToEnd(QWord(Target), EndReasonOfSignal(Number)));
  Asked := AskGroupToEnd(QWord(-Target), EndReasonOfSignal(Number));
  if Asked < 0 then
    Result := ErrorCodeOf(Asked)
  else
    Result := ErrorNone;
end;

function SendSignal(Target: Int64; Number: Integer): LongInt;
begin
  case ActionOfSignal(Number) of
    SignalActionAskToEnd: Result := AskToEnd(Target, Number);
    SignalActionStop: Result := StopPrograms(Target);
    SignalActionContinue: Result := ContinuePrograms(Target);
    SignalActionEnd:
      if Target > 0 then
        Result := TerminateProgram(QWord(Target), 128 + Number)
      else
        Result := ErrorUnsupported;
  else
    { Nothing happens, but the target must exist: continuing a running
      program changes nothing. }
    Result := ContinuePrograms(Target);
  end;
end;

function TextVector(const Items: array of string): TTextVector;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Items) + 1);
  for Index := 0 to High(Items) do
    Result[Index] := PChar(Items[Index]);
  Result[Length(Items)] := nil;
end;

function StartCommand(const Arguments: array of string; const Options: TProcessOptions;
  out Status: LongInt): Int64;
var
  Vector: TTextVector;
begin
  Vector := TextVector(Arguments);
  Result := StartCommand(PPChar(@Vector[0]), Options, Status);
end;

procedure RunCommandAndExit(const Arguments: array of string; const Options: TProcessOptions);
var
  Vector: TTextVector;
begin
  Vector := TextVector(Arguments);
  RunCommandAndExit(PPChar(@Vector[0]), Options);
end;

function ParseSignal(const Text: string): Integer;
begin
  Result := ParseSignal(PChar(Text));
end;

function SignalNameText(Number: Integer): string;
begin
  Result := SignalName(Number);
end;

function FindProgramPath(const Name: string; out Path: string): Boolean;
var
  Buffer: array[0..ProgramPathCapacity - 1] of Char;
begin
  Result := FindProgram(PChar(Name), @Buffer[0], ProgramPathCapacity);
  if Result then
    Path := PChar(@Buffer[0])
  else
    Path := '';
end;

end.
