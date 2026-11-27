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
  pgrep, pkill - look up or end processes by name

  pgrep [-flnoxc] [-d DELIMITER] [-u USER] PATTERN
  pkill [-SIGNAL] [-flnox] [-u USER] PATTERN

  PATTERN is an extended regular expression matched against process
  names (or the whole name with -x). The program itself is never
  matched. Called as pkill it ends the matching processes instead of
  printing them; the system has no signals, so -SIGNAL picks what
  happens as with kill: TERM (the default), HUP and INT ask the program
  to end (it may tidy up first, or end with 128 + the signal number),
  the others end it at once.
}
program pgrep;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Errors,
  Sys.Kernel,
  Sys.Processes,
  Util.Accounts,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Sys.Streams,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage = 'Usage: pgrep [OPTION]... PATTERN'#10 +
    '       pkill [-SIGNAL] [OPTION]... PATTERN'#10 +
    'List (pgrep) or end (pkill) the processes whose names match PATTERN.'#10#10 +
    '  -c, --count             count matching processes (pgrep)'#10 +
    '  -d, --delimiter=TEXT    separate process IDs with TEXT (pgrep, default newline)'#10 +
    '  -l, --list-name         list the process name as well as the ID (pgrep)'#10 +
    '  -n, --newest            select only the newest matching process'#10 +
    '  -o, --oldest            select only the oldest matching process'#10 +
    '  -u, --euid=USER         match only processes of USER'#10 +
    '  -x, --exact             match the whole process name'#10;

  OptionCount = 1;
  OptionDelimiter = 2;
  OptionListName = 3;
  OptionNewest = 4;
  OptionOldest = 5;
  OptionUser = 6;
  OptionExact = 7;
  OptionFull = 8;
  DefaultSignal = 15;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  IsKill: Boolean;
  CountOnly: Boolean;
  Delimiter: string;
  ListName: Boolean;
  Newest: Boolean;
  Oldest: Boolean;
  Exact: Boolean;
  HaveUser: Boolean;
  UserId: LongWord;
  Signal: Integer;
  Pattern: TExpression;
  PatternError: string;
  PatternText: string;
  Matches: array of TAbiProcessInformation;
  MatchCount: Integer;
  Information: TAbiProcessInformation;
  ListIndex: QWord;
  Own: QWord;
  Index: Integer;
  Chosen: Integer;
  First: Integer;
  ExitStatus: LongInt;
  Error: LongInt;
  SignalName: string;
  Line: string;

function Selected(const Information: TAbiProcessInformation): Boolean;
var
  Name: string;
  Match: TMatch;
begin
  if Information.ProcessId = Own then
    Exit(False);
  if HaveUser and (Information.EffectiveUserId <> UserId) then
    Exit(False);
  Name := PChar(@Information.Name[0]);
  if not SearchExpression(Pattern, Name, Match) then
    Exit(False);
  if Exact and ((Match.Starts[0] <> 0) or (Match.Ends[0] <> Length(Name))) then
    Exit(False);
  Result := True;
end;

begin
  IsKill := BaseName(string(Argument(0))) = 'pkill';
  Delimiter := #10;
  Signal := DefaultSignal;
  First := 1;
  { pkill -9 NAME, pkill -KILL NAME }
  if IsKill and (ArgumentTotal > 2) then
  begin
    SignalName := Argument(1);
    if (Length(SignalName) >= 2) and (SignalName[1] = '-') and (SignalName[2] <> '-') then
    begin
      Delete(SignalName, 1, 1);
      if ParseSignal(SignalName) > 0 then
      begin
        Signal := ParseSignal(SignalName);
        First := 2;
      end;
    end;
  end;

  { The signal argument of pkill, if any, is left out. }
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'count', False, OptionCount),
    CommandOption('d', 'delimiter', True, OptionDelimiter),
    CommandOption('f', 'full', False, OptionFull),
    CommandOption('l', 'list-name', False, OptionListName),
    CommandOption('n', 'newest', False, OptionNewest),
    CommandOption('o', 'oldest', False, OptionOldest),
    CommandOption('u', 'euid', True, OptionUser),
    CommandOption('x', 'exact', False, OptionExact)], Usage, Copy(ProgramArguments, First - 1, MaxInt));
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionCount: CountOnly := True;
      OptionDelimiter: Delimiter := Value;
      OptionListName: ListName := True;
      OptionNewest: Newest := True;
      OptionOldest: Oldest := True;
      OptionExact: Exact := True;
      OptionUser:
        begin
          if not FindUserId(Value, UserId) then
            Fail(2, 'invalid user name: ' + Value);
          HaveUser := True;
        end;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('no matching criteria specified');
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint('only one pattern can be provided');
  PatternText := CommandLine.Operands[0];
  if not CompileExpression(PatternText, SyntaxExtended, Pattern, PatternError) then
    Fail(2, Format('invalid pattern ''%s'': %s', [PatternText, PatternError]));

  Own := QWord(CurrentProcessId);
  MatchCount := 0;
  ListIndex := 0;
  while KernelListProcesses(ListIndex, Information) >= 0 do
  begin
    Inc(ListIndex);
    if Selected(Information) then
    begin
      SetLength(Matches, MatchCount + 1);
      Matches[MatchCount] := Information;
      Inc(MatchCount);
    end;
  end;

  { -n and -o pick by start time, then by process ID. }
  if (Newest or Oldest) and (MatchCount > 1) then
  begin
    Chosen := 0;
    for Index := 1 to MatchCount - 1 do
      if (Newest and ((Matches[Index].StartTime > Matches[Chosen].StartTime) or
          ((Matches[Index].StartTime = Matches[Chosen].StartTime) and
           (Matches[Index].ProcessId > Matches[Chosen].ProcessId)))) or
         (Oldest and ((Matches[Index].StartTime < Matches[Chosen].StartTime) or
          ((Matches[Index].StartTime = Matches[Chosen].StartTime) and
           (Matches[Index].ProcessId < Matches[Chosen].ProcessId)))) then
        Chosen := Index;
    Matches[0] := Matches[Chosen];
    MatchCount := 1;
  end;

  if MatchCount = 0 then
  begin
    if CountOnly then
      PrintStringLine('0');
    Halt(1);
  end;
  ExitStatus := 0;
  if IsKill then
  begin
    for Index := 0 to MatchCount - 1 do
    begin
      Error := SendSignal(Int64(Matches[Index].ProcessId), Signal);
      if Error <> ErrorNone then
      begin
        ReportError(Error, Format('killing pid %u failed', [Matches[Index].ProcessId]));
        ExitStatus := 1;
      end;
    end;
    Halt(ExitStatus);
  end;

  if CountOnly then
  begin
    PrintStringLine(IntToStr(MatchCount));
    Halt(0);
  end;
  Line := '';
  for Index := 0 to MatchCount - 1 do
  begin
    if Index > 0 then
      Line := Line + Delimiter;
    Line := Line + IntToStr(Matches[Index].ProcessId);
    if ListName then
      Line := Line + ' ' + string(PChar(@Matches[Index].Name[0]));
  end;
  PrintStringLine(Line);
end.
