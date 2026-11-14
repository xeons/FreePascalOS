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
  xargs - build and run command lines from standard input

  xargs [OPTION]... [COMMAND [INITIAL-ARGUMENTS]]

  Reads items from standard input, separated by blanks and line ends
  (which quotes and backslashes protect), and runs COMMAND (default echo)
  with the initial arguments followed by as many items as fit.

  Exit status: 0 on success, 123 if a command exited with 1-125,
  124 if one exited with 255, 125 if one was killed, 126 if COMMAND
  cannot be run, 127 if it is not found, 1 for other errors.
}
program xargs;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Commands,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: xargs [OPTION]... COMMAND [INITIAL-ARGS]...'#10 +
    'Run COMMAND with arguments INITIAL-ARGS and more arguments read from input.'#10#10 +
    '  -0, --null                   items are separated by a null, not whitespace;'#10 +
    '                                 disables quote and backslash processing'#10 +
    '  -d, --delimiter=CHARACTER    items in input stream are separated by CHARACTER,'#10 +
    '                                 not by whitespace'#10 +
    '  -I R                         replace R in INITIAL-ARGS with names read'#10 +
    '                                 from standard input, split at newlines'#10 +
    '  -L, --max-lines=MAX-LINES    use at most MAX-LINES non-blank input lines per'#10 +
    '                                 command line'#10 +
    '  -n, --max-args=MAX-ARGS      use at most MAX-ARGS arguments per command line'#10 +
    '  -P, --max-procs=MAX-PROCS    accepted; commands always run one at a time'#10 +
    '  -r, --no-run-if-empty        if there are no arguments, then do not run COMMAND'#10 +
    '  -s, --max-chars=MAX-CHARS    limit length of command line to MAX-CHARS'#10 +
    '  -t, --verbose                print commands before executing them'#10;

  OptionNull = 1;
  OptionDelimiter = 2;
  OptionReplace = 3;
  OptionMaximumLines = 4;
  OptionMaximumArguments = 5;
  OptionMaximumProcesses = 6;
  OptionNoRunIfEmpty = 7;
  OptionMaximumCharacters = 8;
  OptionVerbose = 9;

  StatusCommandFailed = 123;
  StatusCommandReturned255 = 124;
  StatusCommandKilled = 125;
  StatusUsage = 1;

  DefaultMaximumCharacters = 128 * 1024;

type
  TSplitMode = (SplitBlanks, SplitCharacter);

var
  SplitMode: TSplitMode;
  Delimiter: Char;
  Replacement: PChar;
  MaximumLines: Int64;
  MaximumArguments: Int64;
  MaximumCharacters: Int64;
  NoRunIfEmpty: Boolean;
  Verbose: Boolean;

  CommandWords: PPChar;
  CommandWordCount: Integer;
  ExitStatus: LongInt;
  InputEnded: Boolean;

{ --- Reading items --------------------------------------------------- }

{ Reads the next item. EndsLine tells whether a line end followed it
  (for -L); a line ending in a blank continues on the next line. }
function ReadItem(out Item: PChar; out EndsLine: Boolean): Boolean;
var
  Builder: TTextBuilder;
  Character: Char;
  Quote: Char;
  HaveItem: Boolean;
begin
  Item := nil;
  EndsLine := False;
  if InputEnded then
    Exit(False);
  BeginText(Builder);
  HaveItem := False;
  if SplitMode = SplitCharacter then
  begin
    while ReadCharacter(StandardInput, Character) do
    begin
      if Character = Delimiter then
      begin
        Item := FinishText(Builder);
        EndsLine := True;
        Exit(True);
      end;
      AppendCharacter(Builder, Character);
      HaveItem := True;
    end;
    InputEnded := True;
    if HaveItem then
    begin
      Item := FinishText(Builder);
      EndsLine := True;
      Exit(True);
    end;
    DiscardText(Builder);
    Exit(False);
  end;

  Quote := #0;
  while ReadCharacter(StandardInput, Character) do
  begin
    if Quote <> #0 then
    begin
      if Character = Quote then
        Quote := #0
      else if Character = #10 then
        Fail(1, 'unmatched quote; by default quotes are special to xargs unless you use the -0 option', [])
      else
        AppendCharacter(Builder, Character);
      Continue;
    end;
    case Character of
      ' ', #9, #10:
        begin
          if Character = #10 then
            EndsLine := True;
          if HaveItem then
          begin
            if Character <> #10 then
            begin
              { A blank followed by a line end does not end the line. }
              EndsLine := False;
            end;
            Item := FinishText(Builder);
            Exit(True);
          end;
          EndsLine := False;
        end;
      '''', '"':
        begin
          Quote := Character;
          HaveItem := True;
        end;
      '\':
        begin
          if ReadCharacter(StandardInput, Character) then
            AppendCharacter(Builder, Character);
          HaveItem := True;
        end;
    else
      AppendCharacter(Builder, Character);
      HaveItem := True;
    end;
  end;
  InputEnded := True;
  if Quote <> #0 then
    Fail(1, 'unmatched quote; by default quotes are special to xargs unless you use the -0 option', []);
  if HaveItem then
  begin
    Item := FinishText(Builder);
    EndsLine := True;
    Exit(True);
  end;
  DiscardText(Builder);
  Result := False;
end;

{ For -I: the next whole line, leading blanks removed. }
function ReadReplacementLine(out Item: PChar): Boolean;
var
  Line: PChar;
  HadLineEnd: Boolean;
  Start: PChar;
begin
  repeat
    if SplitMode = SplitCharacter then
    begin
      Result := ReadItem(Item, HadLineEnd);
      Exit;
    end;
    if not ReadLine(StandardInput, Line, HadLineEnd) then
      Exit(False);
    Start := Line;
    while (Start^ = ' ') or (Start^ = #9) do
      Inc(Start);
    if Start^ <> #0 then
    begin
      Item := DuplicateText(Start);
      FreeMemory(Line);
      Exit(True);
    end;
    FreeMemory(Line);
  until False;
end;

{ --- Running --------------------------------------------------------- }

procedure RunWith(Items: PPChar; ItemCount: Integer);
var
  Arguments: PPChar;
  Index: Integer;
  Options: TProcessOptions;
  Handle: Int64;
  Status: LongInt;
begin
  Arguments := PPChar(AllocateZeroedMemory(QWord(CommandWordCount + ItemCount + 1) * SizeOf(PChar)));
  for Index := 0 to CommandWordCount - 1 do
    Arguments[Index] := CommandWords[Index];
  for Index := 0 to ItemCount - 1 do
    Arguments[CommandWordCount + Index] := Items[Index];
  if Verbose then
  begin
    for Index := 0 to CommandWordCount + ItemCount - 1 do
    begin
      if Index > 0 then
        WriteCharacter(StandardError, ' ');
      WriteText(StandardError, Arguments[Index]);
    end;
    WriteCharacter(StandardError, #10);
    FlushStream(StandardError);
  end;
  DefaultProcessOptions(Options);
  FlushStandardStreams;
  Handle := StartCommand(Arguments, Options, Status);
  FreeMemory(Arguments);
  if Handle < 0 then
    Halt(Status);
  Status := WaitForProgram(Handle);
  if Status = 0 then
    Exit;
  if Status = 255 then
  begin
    Report('%s: exited with status 255; aborting', [ArgumentText(CommandWords[0])]);
    Halt(StatusCommandReturned255);
  end;
  if (Status < 0) or (Status > 128) then
  begin
    Report('%s: terminated by a signal', [ArgumentText(CommandWords[0])]);
    Halt(StatusCommandKilled);
  end;
  ExitStatus := StatusCommandFailed;
end;

{ Replaces every occurrence of Replacement in Word with Item. }
function ReplaceIn(Word, Item: PChar): PChar;
var
  Builder: TTextBuilder;
  Position: PChar;
  ReplacementLength: PtrUInt;
begin
  ReplacementLength := TextLength(Replacement);
  BeginText(Builder);
  Position := Word;
  while Position^ <> #0 do
  begin
    if (ReplacementLength > 0) and TextStartsWith(Position, Replacement) then
    begin
      AppendText(Builder, Item);
      Inc(Position, ReplacementLength);
    end
    else
    begin
      AppendCharacter(Builder, Position^);
      Inc(Position);
    end;
  end;
  Result := FinishText(Builder);
end;

procedure RunReplacing;
var
  Item: PChar;
  Arguments: PPChar;
  Index: Integer;
  SavedWords: PPChar;
begin
  while ReadReplacementLine(Item) do
  begin
    Arguments := PPChar(AllocateZeroedMemory(QWord(CommandWordCount + 1) * SizeOf(PChar)));
    for Index := 0 to CommandWordCount - 1 do
      Arguments[Index] := ReplaceIn(CommandWords[Index], Item);
    SavedWords := CommandWords;
    CommandWords := Arguments;
    RunWith(nil, 0);
    CommandWords := SavedWords;
    for Index := 0 to CommandWordCount - 1 do
      FreeMemory(Arguments[Index]);
    FreeMemory(Arguments);
    FreeMemory(Item);
  end;
end;

procedure RunCollecting;
var
  Items: TLineList;
  Item: PChar;
  EndsLine: Boolean;
  Length: Int64;
  BaseLength: Int64;
  Lines: Int64;
  Index: Integer;
  RanOnce: Boolean;
begin
  BaseLength := 0;
  for Index := 0 to CommandWordCount - 1 do
    BaseLength := BaseLength + Int64(TextLength(CommandWords[Index])) + 1;
  if BaseLength > MaximumCharacters then
    Fail(1, 'argument list too long', []);
  BeginLineList(Items);
  RanOnce := False;
  Length := BaseLength;
  Lines := 0;
  while ReadItem(Item, EndsLine) do
  begin
    if (Items.Count > 0) and (Length + Int64(TextLength(Item)) + 1 > MaximumCharacters) then
    begin
      RunWith(Items.Items, Items.Count);
      RanOnce := True;
      FreeLineList(Items);
      BeginLineList(Items);
      Length := BaseLength;
      Lines := 0;
    end;
    if BaseLength + Int64(TextLength(Item)) + 1 > MaximumCharacters then
      Fail(1, 'argument line too long', []);
    AddLine(Items, Item);
    Length := Length + Int64(TextLength(Item)) + 1;
    if EndsLine then
      Inc(Lines);
    if ((MaximumArguments > 0) and (Items.Count >= MaximumArguments)) or
       ((MaximumLines > 0) and (Lines >= MaximumLines)) then
    begin
      RunWith(Items.Items, Items.Count);
      RanOnce := True;
      FreeLineList(Items);
      BeginLineList(Items);
      Length := BaseLength;
      Lines := 0;
    end;
  end;
  if (Items.Count > 0) or (not RanOnce and not NoRunIfEmpty) then
    RunWith(Items.Items, Items.Count);
  FreeLineList(Items);
end;

function ParseCount(Value: PChar; Option: PChar): Int64;
begin
  if not ParseInteger(Value, Result) or (Result < 1) then
  begin
    Report('invalid number "%s" for -%s option', [ArgumentText(Value), ArgumentText(Option)]);
    Halt(StatusUsage);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Processes: Int64;
begin
  SplitMode := SplitBlanks;
  MaximumCharacters := DefaultMaximumCharacters;
  ExitStatus := 0;
  BeginOptions(Parser, [
    OptionDefinition('0', 'null', False, OptionNull),
    OptionDefinition('d', 'delimiter', True, OptionDelimiter),
    OptionDefinition('I', nil, True, OptionReplace),
    OptionDefinition('L', 'max-lines', True, OptionMaximumLines),
    OptionDefinition('n', 'max-args', True, OptionMaximumArguments),
    OptionDefinition('P', 'max-procs', True, OptionMaximumProcesses),
    OptionDefinition('r', 'no-run-if-empty', False, OptionNoRunIfEmpty),
    OptionDefinition('s', 'max-chars', True, OptionMaximumCharacters),
    OptionDefinition('t', 'verbose', False, OptionVerbose)], Usage);
  { Options end at the command name. }
  Parser.StopAtFirstOperand := True;
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionNull:
        begin
          SplitMode := SplitCharacter;
          Delimiter := #0;
        end;
      OptionDelimiter:
        begin
          SplitMode := SplitCharacter;
          if TextIsEqual(Value, '\n') then
            Delimiter := #10
          else if TextIsEqual(Value, '\t') then
            Delimiter := #9
          else if TextIsEqual(Value, '\0') then
            Delimiter := #0
          else if (Value[0] <> #0) and (Value[1] = #0) then
            Delimiter := Value[0]
          else
          begin
            Report('invalid input delimiter specification %s: the delimiter must be a single character',
              [ArgumentText(Value)]);
            Halt(StatusUsage);
          end;
        end;
      OptionReplace:
        begin
          Replacement := Value;
          MaximumLines := 1;
        end;
      OptionMaximumLines: MaximumLines := ParseCount(Value, 'L');
      OptionMaximumArguments: MaximumArguments := ParseCount(Value, 'n');
      OptionMaximumProcesses:
        if not ParseInteger(Value, Processes) or (Processes < 0) then
        begin
          Report('invalid number "%s" for -P option', [ArgumentText(Value)]);
          Halt(StatusUsage);
        end;
      OptionNoRunIfEmpty: NoRunIfEmpty := True;
      OptionMaximumCharacters: MaximumCharacters := ParseCount(Value, 's');
      OptionVerbose: Verbose := True;
    end;

  if Parser.OperandCount = 0 then
  begin
    CommandWordCount := 1;
    CommandWords := PPChar(AllocateZeroedMemory(2 * SizeOf(PChar)));
    CommandWords[0] := 'echo';
  end
  else
  begin
    CommandWordCount := Parser.OperandCount;
    CommandWords := PPChar(AllocateZeroedMemory(QWord(CommandWordCount + 1) * SizeOf(PChar)));
    for Index := 0 to CommandWordCount - 1 do
      CommandWords[Index] := Parser.Operands[Index];
  end;

  if Replacement <> nil then
    RunReplacing
  else
    RunCollecting;
  Halt(ExitStatus);
end.
