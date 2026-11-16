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
  kill - end processes

  kill [-s SIGNAL | -SIGNAL] PID...
  kill -l [NUMBER]...

  The system has no signals; each becomes what it stands for
  (Util.Commands.SendSignal). TERM (the default), HUP and INT ask the
  program to end, for the reason "asked", "hang-up" or "interrupt": a
  program that takes requests to end may tidy up first (save its work,
  ask its user) or refuse; any other program ends at once with status
  128 + the signal number, as before. KILL (kill -9) and the other
  signals that would end a program end it at once, whatever it takes.
  STOP, TSTP, TTIN and TTOU stop it and CONT continues it; the others
  (and signal 0) only check that the process exists. A negative PID
  names a process group: it can be asked to end, stopped and continued
  (write "kill -TERM -- -PGID").
}
program kill;

{$mode objfpc}{$H+}

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: kill [-s SIGNAL | -SIGNAL] PID...'#10 +
    '  or:  kill -l [SIGNAL]...'#10 +
    'Send signals to processes, or list signals. TERM (the default), HUP and INT'#10 +
    'ask a process to end and let it tidy up first; KILL (-9) ends it at once.'#10#10 +
    '  -s, --signal=SIGNAL, -SIGNAL'#10 +
    '                   specify the name or number of the signal to be sent'#10 +
    '  -l, --list       list signal names, or convert signal names to/from numbers'#10;

var
  Arguments: TStringArray;

procedure ListAllSignals;
var
  Index: Integer;
begin
  for Index := 1 to HighestSignal do
  begin
    PrintString(Format('%2d) SIG%-8s', [Index, SignalName(Index)]));
    if Index mod 5 = 0 then
      PrintString(#10);
  end;
  PrintString(#10);
end;

{ Names for numbers and numbers for names, from argument First on. }
procedure TranslateSignals(First: Integer);
var
  Index: Integer;
  Number: Int64;
begin
  for Index := First to High(Arguments) do
  begin
    if ParseDecimal(Arguments[Index], Number) then
    begin
      { Exit statuses above 128 name the signal that ended a program. }
      if Number > 128 then
        Number := Number - 128;
      if SignalName(Integer(Number)) = '' then
        Fail(1, Format('%s: invalid signal', [Arguments[Index]]));
      PrintStringLine(SignalName(Integer(Number)));
    end
    else
    begin
      Number := ParseSignal(Arguments[Index]);
      if Number < 0 then
        Fail(1, Format('%s: invalid signal', [Arguments[Index]]));
      PrintStringLine(IntToStr(Number));
    end;
  end;
end;

procedure ListSignals(First: Integer);
begin
  if First > High(Arguments) then
    ListAllSignals
  else
    TranslateSignals(First);
  Halt(0);
end;

var
  Signal: Integer;
  First: Integer;
  Index: Integer;
  Option: string;
  ProcessId: Int64;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Arguments := ProgramArguments;
  Signal := SignalTerminate;
  First := 0;
  if Length(Arguments) < 1 then
  begin
    Report('not enough arguments');
    Halt(1);
  end;
  Option := Arguments[0];
  if Option = '--help' then
  begin
    PrintString(Usage);
    Halt(0);
  end;
  if (Option = '-l') or (Option = '--list') or (Option = '-L') or (Option = '--table') then
    ListSignals(1);

  if (Option = '-s') or (Option = '--signal') or (Option = '-n') then
  begin
    if Length(Arguments) < 2 then
      Fail(1, 'option requires an argument -- ''s''');
    Signal := ParseSignal(Arguments[1]);
    First := 2;
  end
  else if StartsStr('--signal=', Option) then
  begin
    Signal := ParseSignal(Copy(Option, 10, MaxInt));
    First := 1;
  end
  else if (Length(Option) >= 2) and (Option[1] = '-') and (Option[2] <> '-') then
  begin
    Signal := ParseSignal(Copy(Option, 2, MaxInt));
    First := 1;
  end;
  if (First <= High(Arguments)) and (Arguments[First] = '--') then
    Inc(First);
  if Signal < 0 then
    Fail(1, 'invalid signal');
  if First > High(Arguments) then
    Fail(1, 'no process ID specified');

  ExitStatus := 0;
  for Index := First to High(Arguments) do
  begin
    if not ParseDecimal(Arguments[Index], ProcessId) or (ProcessId = 0) then
    begin
      Report(Format('failed to parse argument: ''%s''', [Arguments[Index]]));
      ExitStatus := 1;
      Continue;
    end;
    Error := SendSignal(ProcessId, Signal);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('(%d)', [ProcessId]));
      ExitStatus := 1;
    end;
  end;
  Halt(ExitStatus);
end.
