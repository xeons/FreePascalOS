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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Kernel,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Accounts,
  Util.Commands,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage: PChar = 'Usage: pgrep [OPTION]... PATTERN'#10 +
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
  MaximumMatches = 256;
  DefaultSignal = 15;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  IsKill: Boolean;
  CountOnly: Boolean;
  Delimiter: PChar;
  ListName: Boolean;
  Newest: Boolean;
  Oldest: Boolean;
  Exact: Boolean;
  HaveUser: Boolean;
  UserId: LongWord;
  Signal: Integer;
  Pattern: TExpression;
  PatternError: PChar;
  PatternText: PChar;
  Matches: array[0..MaximumMatches - 1] of TAbiProcessInformation;
  MatchCount: Integer;
  Information: TAbiProcessInformation;
  ListIndex: QWord;
  Own: QWord;
  Index: Integer;
  Chosen: Integer;
  First: Integer;
  ExitStatus: LongInt;
  Error: LongInt;

function Selected(const Information: TAbiProcessInformation): Boolean;
var
  Match: TMatch;
begin
  if Information.ProcessId = Own then
    Exit(False);
  if HaveUser and (Information.EffectiveUserId <> UserId) then
    Exit(False);
  if not SearchExpression(Pattern, @Information.Name[0], Match) then
    Exit(False);
  if Exact and ((Match.Starts[0] <> 0) or (Match.Ends[0] <> PtrInt(TextLength(@Information.Name[0])))) then
    Exit(False);
  Result := True;
end;

begin
  IsKill := TextIsEqual(BaseName(Argument(0)), 'pkill');
  Delimiter := #10;
  Signal := DefaultSignal;
  First := 1;
  { pkill -9 NAME, pkill -KILL NAME }
  if IsKill and (ArgumentTotal > 2) and (Argument(1)[0] = '-') and (Argument(1)[1] <> '-') and
     (ParseSignal(Argument(1) + 1) > 0) then
  begin
    Signal := ParseSignal(Argument(1) + 1);
    First := 2;
  end;

  BeginOptions(Parser, [
    OptionDefinition('c', 'count', False, OptionCount),
    OptionDefinition('d', 'delimiter', True, OptionDelimiter),
    OptionDefinition('f', 'full', False, OptionFull),
    OptionDefinition('l', 'list-name', False, OptionListName),
    OptionDefinition('n', 'newest', False, OptionNewest),
    OptionDefinition('o', 'oldest', False, OptionOldest),
    OptionDefinition('u', 'euid', True, OptionUser),
    OptionDefinition('x', 'exact', False, OptionExact)], Usage);
  Parser.ArgumentIndex := First;
  while NextOption(Parser, Code, Value) do
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
            Fail(2, 'invalid user name: %s', [ArgumentText(Value)]);
          HaveUser := True;
        end;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('no matching criteria specified', []);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('only one pattern can be provided', []);
  PatternText := Parser.Operands[0];
  if not CompileExpression(PatternText, SyntaxExtended, Pattern, PatternError) then
    Fail(2, 'invalid pattern ''%s'': %s', [ArgumentText(PatternText), ArgumentText(PatternError)]);

  Own := QWord(CurrentProcessId);
  MatchCount := 0;
  ListIndex := 0;
  while (KernelListProcesses(ListIndex, Information) >= 0) and (MatchCount < MaximumMatches) do
  begin
    Inc(ListIndex);
    if Selected(Information) then
    begin
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
      PrintLine('0');
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
        ReportError(Error, 'killing pid %u failed', [ArgumentUnsigned(Matches[Index].ProcessId)]);
        ExitStatus := 1;
      end;
    end;
    Halt(ExitStatus);
  end;

  if CountOnly then
  begin
    WriteFormatted(StandardOutput, '%d'#10, [ArgumentNumber(MatchCount)]);
    Halt(0);
  end;
  for Index := 0 to MatchCount - 1 do
  begin
    if Index > 0 then
      WriteText(StandardOutput, Delimiter);
    WriteUnsigned(StandardOutput, Matches[Index].ProcessId);
    if ListName then
    begin
      WriteCharacter(StandardOutput, ' ');
      WriteText(StandardOutput, @Matches[Index].Name[0]);
    end;
  end;
  WriteCharacter(StandardOutput, #10);
end.
