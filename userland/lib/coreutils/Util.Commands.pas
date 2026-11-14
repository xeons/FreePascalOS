{
  Running a command given on the command line, as env, nice, nohup,
  stdbuf, chroot and timeout do, with the usual exit statuses:

    127  the command was not found
    126  it was found but could not be started
    otherwise the command's own exit status

  Also the signal names used by kill and timeout. Every signal that ends
  a program becomes a termination with exit status 128 + its number,
  which is what a shell reports for a program killed by that signal.
}
unit Util.Commands;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Processes;

const
  StatusCommandNotFound = 127;
  StatusCommandNotRunnable = 126;
  SignalTerminate = 15;
  SignalKill = 9;

{ Starts Arguments[0] (looked up in PATH) with Options. Returns the
  process handle, or reports the problem and returns -1 with Status set
  to 126 or 127. }
function StartCommand(Arguments: PPChar; const Options: TProcessOptions; out Status: LongInt): Int64;
{ Starts the command, waits for it, and ends this program with its
  status. }
procedure RunCommandAndExit(Arguments: PPChar; const Options: TProcessOptions);

{ Parses "TERM", "SIGTERM" or "15"; returns -1 if unknown. }
function ParseSignal(Text: PChar): Integer;
{ "TERM" for 15; nil if the number has no name. }
function SignalName(Number: Integer): PChar;
const
  HighestSignal = 31;

implementation

uses
  Runtime.Text,
  Sys.Errors,
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

end.
