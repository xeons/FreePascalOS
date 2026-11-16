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
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Commands,
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

  UnmatchedQuoteMessage: PChar =
    'unmatched quote; by default quotes are special to xargs unless you use the -0 option';

type
  TSplitMode = (SplitBlanks, SplitCharacter);
  TStringArray = array of string;

var
  SplitMode: TSplitMode;
  Delimiter: Char;
  Replacing: Boolean;
  Replacement: string;
  MaximumLines: Int64;
  MaximumArguments: Int64;
  MaximumCharacters: Int64;
  NoRunIfEmpty: Boolean;
  Verbose: Boolean;

  CommandWords: TStringArray;
  ExitStatus: LongInt;
  InputEnded: Boolean;

{ --- Reading items --------------------------------------------------- }

{ Reads the next item separated by Delimiter (-0, -d). }
function ReadDelimitedItem(out Item: string): Boolean;
var
  Character: Char;
  HaveItem: Boolean;
begin
  Item := '';
  HaveItem := False;
  while ReadCharacter(StandardInput, Character) do
  begin
    if Character = Delimiter then
      Exit(True);
    Item := Item + Character;
    HaveItem := True;
  end;
  InputEnded := True;
  Result := HaveItem;
end;

{ Reads the next blank separated item, with quotes and backslashes.
  EndsLine tells whether a line end followed it. }
function ReadBlankSeparatedItem(out Item: string; out EndsLine: Boolean): Boolean;
var
  Character: Char;
  Quote: Char;
  HaveItem: Boolean;
begin
  Item := '';
  EndsLine := False;
  HaveItem := False;
  Quote := #0;
  while ReadCharacter(StandardInput, Character) do
  begin
    if Quote <> #0 then
    begin
      if Character = Quote then
        Quote := #0
      else if Character = #10 then
        Fail(1, UnmatchedQuoteMessage, [])
      else
        Item := Item + Character;
      Continue;
    end;
    case Character of
      ' ', #9, #10:
        begin
          if HaveItem then
          begin
            { A blank followed by a line end does not end the line. }
            EndsLine := Character = #10;
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
            Item := Item + Character;
          HaveItem := True;
        end;
    else
      Item := Item + Character;
      HaveItem := True;
    end;
  end;
  InputEnded := True;
  if Quote <> #0 then
    Fail(1, UnmatchedQuoteMessage, []);
  EndsLine := HaveItem;
  Result := HaveItem;
end;

{ Reads the next item. EndsLine tells whether a line end followed it
  (for -L); a line ending in a blank continues on the next line. }
function ReadItem(out Item: string; out EndsLine: Boolean): Boolean;
begin
  Item := '';
  EndsLine := False;
  if InputEnded then
    Exit(False);
  if SplitMode = SplitCharacter then
  begin
    Result := ReadDelimitedItem(Item);
    EndsLine := Result;
  end
  else
    Result := ReadBlankSeparatedItem(Item, EndsLine);
end;

{ For -I: the next whole line, leading blanks removed. }
function ReadReplacementLine(out Item: string): Boolean;
var
  Line: PChar;
  HadLineEnd: Boolean;
  Start: Integer;
begin
  if SplitMode = SplitCharacter then
    Exit(ReadItem(Item, HadLineEnd));
  repeat
    if not ReadLine(StandardInput, Line, HadLineEnd) then
      Exit(False);
    Item := Line;
    FreeMemory(Line);
    Start := 1;
    while (Start <= Length(Item)) and (Item[Start] in [' ', #9]) do
      Inc(Start);
    if Start <= Length(Item) then
    begin
      Delete(Item, 1, Start - 1);
      Exit(True);
    end;
  until False;
end;

{ --- Running --------------------------------------------------------- }

procedure WriteCommandLine(const Words: TStringArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Words) do
  begin
    if Index > 0 then
      WriteCharacter(StandardError, ' ');
    WriteText(StandardError, PChar(Words[Index]));
  end;
  WriteCharacter(StandardError, #10);
  FlushStream(StandardError);
end;

{ Runs Words (the command and its arguments) and waits for it. }
procedure Run(const Words: TStringArray);
var
  Arguments: array of PChar;
  Index: Integer;
  Options: TProcessOptions;
  Handle: Int64;
  Status: LongInt;
begin
  if Verbose then
    WriteCommandLine(Words);
  SetLength(Arguments, Length(Words) + 1);
  for Index := 0 to High(Words) do
    Arguments[Index] := PChar(Words[Index]);
  Arguments[High(Arguments)] := nil;
  DefaultProcessOptions(Options);
  FlushStandardStreams;
  Handle := StartCommand(@Arguments[0], Options, Status);
  if Handle < 0 then
    Halt(Status);
  Status := WaitForProgram(Handle);
  if Status = 0 then
    Exit;
  if Status = 255 then
  begin
    Report('%s: exited with status 255; aborting', [ArgumentText(PChar(Words[0]))]);
    Halt(StatusCommandReturned255);
  end;
  if (Status < 0) or (Status > 128) then
  begin
    Report('%s: terminated by a signal', [ArgumentText(PChar(Words[0]))]);
    Halt(StatusCommandKilled);
  end;
  ExitStatus := StatusCommandFailed;
end;

procedure RunWith(const Items: TStringArray);
begin
  Run(Concat(CommandWords, Items));
end;

{ Replaces every occurrence of Replacement in Word with Item. }
function ReplaceIn(const Word, Item: string): string;
begin
  if Replacement = '' then
    Exit(Word);
  Result := StringReplace(Word, Replacement, Item, [rfReplaceAll]);
end;

procedure RunReplacing;
var
  Item: string;
  Words: TStringArray;
  Index: Integer;
begin
  SetLength(Words, Length(CommandWords));
  while ReadReplacementLine(Item) do
  begin
    for Index := 0 to High(CommandWords) do
      Words[Index] := ReplaceIn(CommandWords[Index], Item);
    Run(Words);
  end;
end;

procedure RunCollecting;
var
  Items: TStringArray;
  Item: string;
  EndsLine: Boolean;
  LineLength: Int64;
  BaseLength: Int64;
  Lines: Int64;
  Index: Integer;
  RanOnce: Boolean;

  procedure RunCollected;
  begin
    RunWith(Items);
    RanOnce := True;
    Items := nil;
    LineLength := BaseLength;
    Lines := 0;
  end;

begin
  BaseLength := 0;
  for Index := 0 to High(CommandWords) do
    BaseLength := BaseLength + Length(CommandWords[Index]) + 1;
  if BaseLength > MaximumCharacters then
    Fail(1, 'argument list too long', []);
  Items := nil;
  RanOnce := False;
  LineLength := BaseLength;
  Lines := 0;
  while ReadItem(Item, EndsLine) do
  begin
    if (Length(Items) > 0) and (LineLength + Length(Item) + 1 > MaximumCharacters) then
      RunCollected;
    if BaseLength + Length(Item) + 1 > MaximumCharacters then
      Fail(1, 'argument line too long', []);
    Insert(Item, Items, Length(Items));
    LineLength := LineLength + Length(Item) + 1;
    if EndsLine then
      Inc(Lines);
    if ((MaximumArguments > 0) and (Length(Items) >= MaximumArguments)) or
       ((MaximumLines > 0) and (Lines >= MaximumLines)) then
      RunCollected;
  end;
  if (Length(Items) > 0) or (not RanOnce and not NoRunIfEmpty) then
    RunWith(Items);
end;

function ParseCount(Value: PChar; Option: PChar): Int64;
begin
  if not ParseInteger(Value, Result) or (Result < 1) then
  begin
    Report('invalid number "%s" for -%s option', [ArgumentText(Value), ArgumentText(Option)]);
    Halt(StatusUsage);
  end;
end;

procedure SetDelimiter(const Text: string);
begin
  SplitMode := SplitCharacter;
  if Text = '\n' then
    Delimiter := #10
  else if Text = '\t' then
    Delimiter := #9
  else if Text = '\0' then
    Delimiter := #0
  else if Length(Text) = 1 then
    Delimiter := Text[1]
  else
  begin
    Report('invalid input delimiter specification %s: the delimiter must be a single character',
      [ArgumentText(PChar(Text))]);
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
  Replacing := False;
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
      OptionDelimiter: SetDelimiter(Value);
      OptionReplace:
        begin
          Replacement := Value;
          Replacing := True;
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
    CommandWords := ['echo']
  else
  begin
    SetLength(CommandWords, Parser.OperandCount);
    for Index := 0 to Parser.OperandCount - 1 do
      CommandWords[Index] := Parser.Operands[Index];
  end;

  if Replacing then
    RunReplacing
  else
    RunCollecting;
  Halt(ExitStatus);
end.
