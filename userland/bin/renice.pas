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
  renice - alter the priority of running processes

  renice [-n] PRIORITY [-p] PID...

  Sets the nice value (-20 .. 19) of each process. Users may change
  their own processes, and only root may lower a nice value.
}
program renice;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Kernel,
  Sys.Streams,
  Sys.Text,
  Util.Messages;

const
  Usage: PChar = 'Usage: renice [-n] PRIORITY [-p] PID...'#10 +
    'Alter the priority of running processes.'#10#10 +
    '  -n, --priority N   set the nice value to N'#10 +
    '  -p, --pid          interpret the following arguments as process IDs (the default)'#10;

var
  Index: Integer;
  Priority: Int64;
  Text: string;
  ProcessId: Int64;
  OldNice: LongInt;
  Error: Int64;
  ExitStatus: LongInt;
  HavePriority: Boolean;
begin
  ExitStatus := 0;
  HavePriority := False;
  Priority := 0;
  Index := 1;
  if (ArgumentTotal > 1) and (string(Argument(1)) = '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;
  while Index < ArgumentTotal do
  begin
    Text := Argument(Index);
    Inc(Index);
    if (Text = '-p') or (Text = '--pid') then
      Continue;
    if (Text = '-g') or (Text = '-u') then
      Fail(1, 'option ''%s'' is not supported', [ArgumentText(PChar(Text))]);
    if (Text = '-n') or (Text = '--priority') then
    begin
      if Index >= ArgumentTotal then
        Fail(1, 'option ''%s'' requires an argument', [ArgumentText(PChar(Text))]);
      Text := Argument(Index);
      Inc(Index);
      if not ParseInteger(PChar(Text), Priority) then
        Fail(1, 'invalid priority ''%s''', [ArgumentText(PChar(Text))]);
      HavePriority := True;
      Continue;
    end;
    if not HavePriority then
    begin
      if not ParseInteger(PChar(Text), Priority) then
        Fail(1, 'invalid priority ''%s''', [ArgumentText(PChar(Text))]);
      HavePriority := True;
      Continue;
    end;
    if not ParseInteger(PChar(Text), ProcessId) or (ProcessId <= 0) then
    begin
      Report('invalid process ID ''%s''', [ArgumentText(PChar(Text))]);
      ExitStatus := 1;
      Continue;
    end;
    Error := KernelGetPriority(QWord(ProcessId), OldNice);
    if Error >= 0 then
      Error := KernelSetPriority(QWord(ProcessId), LongInt(Priority));
    if Error < 0 then
    begin
      Report('failed to set priority for %d (process ID): %s', [ArgumentNumber(ProcessId),
        ArgumentText(ErrorMessage(ErrorCodeOf(Error)))]);
      ExitStatus := 1;
      Continue;
    end;
    if Priority < -20 then
      Priority := -20;
    if Priority > 19 then
      Priority := 19;
    WriteText(StandardOutput, PChar(Format('%d (process ID) old priority %d, new priority %d'#10,
      [ProcessId, OldNice, Priority])));
  end;
  if not HavePriority then
    FailWithUsageHint('missing priority', []);
  Halt(ExitStatus);
end.
