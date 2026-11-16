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
  timeout - run a command with a time limit

  timeout [-k DURATION] [-s SIGNAL] [--preserve-status] DURATION COMMAND [ARG]...

  DURATION is a number with an optional suffix s, m, h or d (fractions
  allowed); 0 disables the limit. If the command is still running when
  the time is up it is sent the signal as kill would send it (TERM asks
  it to end: it may tidy up first; -k ends it outright later), and
  timeout exits with 124 (or, with --preserve-status, the command's
  status, 128 + the signal number for a program that took nothing).
}
program timeout;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Sys.Processes,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: timeout [OPTION] DURATION COMMAND [ARG]...'#10 +
    'Start COMMAND, and kill it if still running after DURATION.'#10#10 +
    '      --preserve-status'#10 +
    '                 exit with the same status as COMMAND, even when the'#10 +
    '                   command times out'#10 +
    '  -k, --kill-after=DURATION'#10 +
    '                 also send a KILL signal if COMMAND is still running'#10 +
    '                   this long after the initial signal was sent'#10 +
    '  -s, --signal=SIGNAL'#10 +
    '                 specify the signal to be sent on timeout'#10 +
    #10'If the command times out, and --preserve-status is not set, then exit'#10 +
    'with status 124.'#10;

  StatusTimedOut = 124;
  StatusTimeoutFailed = 125;

  Digits = ['0'..'9'];

{ "1.5m" into milliseconds. }
function ParseDuration(const Text: string; out Milliseconds: QWord): Boolean;
var
  Position: Integer;
  Whole: QWord;
  Fraction: QWord;
  Scale: QWord;
  Multiplier: QWord;
  Suffix: Char;
begin
  Milliseconds := 0;
  Whole := 0;
  Fraction := 0;
  Scale := 1;
  if (Text = '') or not ((Text[1] in Digits) or (Text[1] = '.')) then
    Exit(False);
  Position := 1;
  while (Position <= Length(Text)) and (Text[Position] in Digits) do
  begin
    Whole := Whole * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  if (Position <= Length(Text)) and (Text[Position] = '.') then
  begin
    Inc(Position);
    while (Position <= Length(Text)) and (Text[Position] in Digits) do
    begin
      if Scale < 1000 then
      begin
        Fraction := Fraction * 10 + QWord(Ord(Text[Position]) - Ord('0'));
        Scale := Scale * 10;
      end;
      Inc(Position);
    end;
  end;
  if Position <= Length(Text) then
    Suffix := Text[Position]
  else
    Suffix := #0;
  case Suffix of
    #0, 's': Multiplier := 1000;
    'm': Multiplier := 60 * 1000;
    'h': Multiplier := 60 * 60 * 1000;
    'd': Multiplier := 24 * 60 * 60 * 1000;
  else
    Exit(False);
  end;
  if Position < Length(Text) then
    Exit(False);
  Milliseconds := Whole * Multiplier + (Fraction * Multiplier) div Scale;
  Result := True;
end;

procedure FailUsage(const Message: string);
begin
  Report(Message);
  PrintErrorString(Format('Try ''%s --help'' for more information.'#10, [ProgramName]));
  Halt(StatusTimeoutFailed);
end;

var
  Arguments: TStringArray;
  First: Integer;
  Signal: Integer;
  PreserveStatus: Boolean;
  KillAfter: QWord;
  Limit: QWord;
  Options: TProcessOptions;
  Handle: Int64;
  ProcessId: Int64;
  Status: LongInt;
  Error: LongInt;
  Text: string;
begin
  Signal := SignalTerminate;
  PreserveStatus := False;
  KillAfter := 0;
  Arguments := ProgramArguments;
  First := 0;
  { Options end at the duration, so the command keeps its own options. }
  while (First < Length(Arguments)) and (Length(Arguments[First]) > 1) and (Arguments[First][1] = '-') do
  begin
    Text := Arguments[First];
    if Text = '--help' then
    begin
      PrintString(Usage);
      Halt(0);
    end
    else if Text = '--preserve-status' then
      PreserveStatus := True
    else if (Text = '--foreground') or (Text = '-v') or (Text = '--verbose') then
      { accepted; there are no process groups to leave }
    else if ((Text = '-s') or (Text = '--signal')) and (First + 1 < Length(Arguments)) then
    begin
      Inc(First);
      Signal := ParseSignal(Arguments[First]);
    end
    else if StartsStr('--signal=', Text) then
      Signal := ParseSignal(Copy(Text, 10, MaxInt))
    else if StartsStr('-s', Text) then
      Signal := ParseSignal(Copy(Text, 3, MaxInt))
    else if ((Text = '-k') or (Text = '--kill-after')) and (First + 1 < Length(Arguments)) then
    begin
      Inc(First);
      if not ParseDuration(Arguments[First], KillAfter) then
        FailUsage('invalid time interval');
    end
    else if StartsStr('--kill-after=', Text) then
    begin
      if not ParseDuration(Copy(Text, 14, MaxInt), KillAfter) then
        FailUsage('invalid time interval');
    end
    else if Text = '--' then
    begin
      Inc(First);
      Break;
    end
    else
      FailUsage('invalid option');
    Inc(First);
  end;
  if Signal < 0 then
    FailUsage('invalid signal');
  if First + 1 >= Length(Arguments) then
    FailUsage('missing operand');
  if not ParseDuration(Arguments[First], Limit) then
    FailUsage('invalid time interval');

  DefaultProcessOptions(Options);
  Handle := StartCommand(Copy(Arguments, First + 1, MaxInt), Options, Status);
  if Handle < 0 then
    Halt(Status);
  if Limit = 0 then
    Halt(WaitForProgram(Handle));

  Error := WaitForProgramWithTimeout(Handle, Limit, Status);
  if Error = 0 then
    Halt(Status);

  { Time is up. }
  ProcessId := ProcessIdOf(Handle);
  { TERM asks the command to end (it may tidy up first); KILL after
    KillAfter ends it whatever it takes. }
  SendSignal(ProcessId, Signal);
  if KillAfter > 0 then
  begin
    if WaitForProgramWithTimeout(Handle, KillAfter, Status) <> 0 then
    begin
      TerminateProgram(QWord(ProcessId), 128 + SignalKill);
      Status := WaitForProgram(Handle);
    end;
  end
  else
    Status := WaitForProgram(Handle);
  if PreserveStatus then
    Halt(Status);
  Halt(StatusTimedOut);
end.
