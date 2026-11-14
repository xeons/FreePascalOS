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
  grep, egrep, fgrep - print lines that match patterns

  grep [OPTION]... PATTERNS [FILE]...
  grep [OPTION]... -e PATTERN... [FILE]...
  grep [OPTION]... -f FILE... [FILE]...

  PATTERNS are basic regular expressions (-G, the default), extended ones
  (-E, or started as egrep) or fixed strings (-F, or started as fgrep);
  several patterns can be given with -e, -f, or separated by line ends.
  With no FILE, reads standard input (or the current directory with -r).
  Exit status: 0 if a line was selected, 1 if none, 2 on an error.
}
program grep;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage: PChar = 'Usage: grep [OPTION]... PATTERNS [FILE]...'#10 +
    'Search for PATTERNS in each FILE.'#10 +
    'Example: grep -i ''hello world'' menu.h main.c'#10 +
    'PATTERNS can contain multiple patterns separated by newlines.'#10#10 +
    'Pattern selection and interpretation:'#10 +
    '  -E, --extended-regexp     PATTERNS are extended regular expressions'#10 +
    '  -F, --fixed-strings       PATTERNS are strings'#10 +
    '  -G, --basic-regexp        PATTERNS are basic regular expressions'#10 +
    '  -e, --regexp=PATTERNS     use PATTERNS for matching'#10 +
    '  -f, --file=FILE           take PATTERNS from FILE'#10 +
    '  -i, --ignore-case         ignore case distinctions in patterns and data'#10 +
    '  -w, --word-regexp         match only whole words'#10 +
    '  -x, --line-regexp         match only whole lines'#10#10 +
    'Miscellaneous:'#10 +
    '  -s, --no-messages         suppress error messages'#10 +
    '  -v, --invert-match        select non-matching lines'#10#10 +
    'Output control:'#10 +
    '  -n, --line-number         print line number with output lines'#10 +
    '  -H, --with-filename       print file name with output lines'#10 +
    '  -h, --no-filename         suppress the file name prefix on output'#10 +
    '  -o, --only-matching       show only nonempty parts of lines that match'#10 +
    '  -q, --quiet, --silent     suppress all normal output'#10 +
    '  -r, --recursive           read all files under each directory, recursively'#10 +
    '  -R, --dereference-recursive  likewise'#10 +
    '  -L, --files-without-match  print only names of FILEs with no selected lines'#10 +
    '  -l, --files-with-matches  print only names of FILEs with selected lines'#10 +
    '  -c, --count               print only a count of selected lines per FILE'#10 +
    '      --color[=WHEN]        accepted; output is never colored'#10;

  OptionExtended = 1;
  OptionFixed = 2;
  OptionBasic = 3;
  OptionPattern = 4;
  OptionPatternFile = 5;
  OptionIgnoreCase = 6;
  OptionWord = 7;
  OptionLine = 8;
  OptionNoMessages = 9;
  OptionInvert = 10;
  OptionLineNumber = 11;
  OptionWithFileName = 12;
  OptionNoFileName = 13;
  OptionOnlyMatching = 14;
  OptionQuiet = 15;
  OptionRecursive = 16;
  OptionFilesWithout = 17;
  OptionFilesWith = 18;
  OptionCount = 19;
  OptionColor = 20;

  StatusSelected = 0;
  StatusNothingSelected = 1;
  StatusTrouble = 2;

type
  TPatternKind = (PatternBasic, PatternExtended, PatternFixed);

  TPattern = record
    Text: PChar;
    Expression: TExpression;
  end;
  PPattern = ^TPattern;

var
  Kind: TPatternKind;
  IgnoreCase: Boolean;
  WholeWords: Boolean;
  WholeLines: Boolean;
  NoMessages: Boolean;
  Invert: Boolean;
  ShowLineNumbers: Boolean;
  ShowFileNames: Boolean;
  OnlyMatching: Boolean;
  Quiet: Boolean;
  Recursive: Boolean;
  ListFilesWithout: Boolean;
  ListFilesWith: Boolean;
  CountOnly: Boolean;

  PatternTexts: TLineList;
  Patterns: PPattern;
  PatternCount: Integer;
  AnySelected: Boolean;
  HadTrouble: Boolean;
  { With -r and no FILE, names are shown without a leading "./". }
  ImplicitCurrentDirectory: Boolean;

{ --- Patterns -------------------------------------------------------- }

{ Adds every line of Text as a pattern. }
procedure AddPatternLines(Text: PChar);
var
  Start: PChar;
  Position: PChar;
  Line: PChar;
begin
  Start := Text;
  Position := Text;
  repeat
    if (Position^ = #10) or (Position^ = #0) then
    begin
      Line := PChar(AllocateMemory(Position - Start + 1));
      CopyMemory(Line, Start, Position - Start);
      Line[Position - Start] := #0;
      AddLine(PatternTexts, Line);
      if Position^ = #0 then
        Break;
      Start := Position + 1;
    end;
    Inc(Position);
  until False;
end;

procedure AddPatternFile(Path: PChar);
var
  Stream: PInputStream;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Halt(StatusTrouble);
  ReadAllLines(Stream, PatternTexts);
  CloseInput(Stream);
end;

{ For -x the pattern is anchored at both ends; a group keeps
  alternatives together. }
function AnchoredPattern(Text: PChar): PChar;
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  if Kind = PatternExtended then
    AppendText(Builder, '^(')
  else
    AppendText(Builder, '^\(');
  AppendText(Builder, Text);
  if Kind = PatternExtended then
    AppendText(Builder, ')$')
  else
    AppendText(Builder, '\)$');
  Result := FinishText(Builder);
end;

procedure CompilePatterns;
var
  Index: Integer;
  Source: PChar;
  ErrorMessage: PChar;
  Syntax: TExpressionSyntax;
begin
  PatternCount := PatternTexts.Count;
  Patterns := PPattern(AllocateZeroedMemory(QWord(PatternCount + 1) * SizeOf(TPattern)));
  if Kind = PatternExtended then
    Syntax := SyntaxExtended
  else
    Syntax := SyntaxBasic;
  for Index := 0 to PatternCount - 1 do
  begin
    Patterns[Index].Text := PatternTexts.Items[Index];
    if Kind = PatternFixed then
      Continue;
    if WholeLines then
      Source := AnchoredPattern(PatternTexts.Items[Index])
    else
      Source := PatternTexts.Items[Index];
    if not CompileExpression(Source, Syntax, Patterns[Index].Expression, ErrorMessage) then
    begin
      Report('%s', [ArgumentText(ErrorMessage)]);
      Halt(StatusTrouble);
    end;
    Patterns[Index].Expression.IgnoreCase := IgnoreCase;
  end;
end;

{ --- Matching -------------------------------------------------------- }

function IsWordCharacter(Character: Char): Boolean;
begin
  Result := IsAlphanumeric(Character) or (Character = '_');
end;

function IsWholeWord(Line: PChar; LineLength, Start, Finish: PtrInt): Boolean;
begin
  Result := ((Start = 0) or not IsWordCharacter(Line[Start - 1])) and
    ((Finish >= LineLength) or not IsWordCharacter(Line[Finish]));
end;

function SameText(First, Second: PChar; Count: PtrInt): Boolean;
var
  Index: PtrInt;
begin
  for Index := 0 to Count - 1 do
  begin
    if IgnoreCase then
    begin
      if ToLowerCase(First[Index]) <> ToLowerCase(Second[Index]) then
        Exit(False);
    end
    else if First[Index] <> Second[Index] then
      Exit(False);
  end;
  Result := True;
end;

{ Finds the first acceptable match of one pattern at or after From. }
function FindMatch(const Pattern: TPattern; Line: PChar; LineLength: PtrInt; From: PtrInt;
  out Start, Finish: PtrInt): Boolean;
var
  PatternLength: PtrInt;
  Position: PtrInt;
  Match: TMatch;
begin
  Start := -1;
  Finish := -1;
  if Kind = PatternFixed then
  begin
    PatternLength := PtrInt(TextLength(Pattern.Text));
    if WholeLines then
    begin
      Result := (From = 0) and (PatternLength = LineLength) and SameText(Line, Pattern.Text, LineLength);
      if Result then
      begin
        Start := 0;
        Finish := LineLength;
      end;
      Exit;
    end;
    Position := From;
    while Position + PatternLength <= LineLength do
    begin
      if SameText(Line + Position, Pattern.Text, PatternLength) and
         (not WholeWords or IsWholeWord(Line, LineLength, Position, Position + PatternLength)) then
      begin
        Start := Position;
        Finish := Position + PatternLength;
        Exit(True);
      end;
      Inc(Position);
    end;
    Exit(False);
  end;

  Position := From;
  while Position <= LineLength do
  begin
    if not SearchExpressionFrom(Pattern.Expression, Line, Position, Match) then
      Exit(False);
    if not WholeWords or IsWholeWord(Line, LineLength, Match.Starts[0], Match.Ends[0]) then
    begin
      Start := Match.Starts[0];
      Finish := Match.Ends[0];
      Exit(True);
    end;
    Position := Match.Starts[0] + 1;
  end;
  Result := False;
end;

{ The earliest match of any pattern at or after From. }
function FindAnyMatch(Line: PChar; LineLength: PtrInt; From: PtrInt; out Start, Finish: PtrInt): Boolean;
var
  Index: Integer;
  CandidateStart: PtrInt;
  CandidateFinish: PtrInt;
begin
  Result := False;
  Start := -1;
  Finish := -1;
  for Index := 0 to PatternCount - 1 do
    if FindMatch(Patterns[Index], Line, LineLength, From, CandidateStart, CandidateFinish) then
      if not Result or (CandidateStart < Start) or
         ((CandidateStart = Start) and (CandidateFinish > Finish)) then
      begin
        Start := CandidateStart;
        Finish := CandidateFinish;
        Result := True;
      end;
end;

{ --- Searching files ------------------------------------------------- }

procedure WritePrefix(Name: PChar; LineNumber: Int64);
begin
  if ShowFileNames then
  begin
    WriteText(StandardOutput, Name);
    WriteCharacter(StandardOutput, ':');
  end;
  if ShowLineNumbers then
  begin
    WriteDecimal(StandardOutput, LineNumber);
    WriteCharacter(StandardOutput, ':');
  end;
end;

{ Searches one stream; Name is how it is shown. }
procedure SearchStream(Stream: PInputStream; Name: PChar);
var
  Line: PChar;
  HadLineEnd: Boolean;
  LineNumber: Int64;
  Count: Int64;
  LineLength: PtrInt;
  Start: PtrInt;
  Finish: PtrInt;
  Selected: Boolean;
  From: PtrInt;
begin
  LineNumber := 0;
  Count := 0;
  while ReadLine(Stream, Line, HadLineEnd) do
  begin
    Inc(LineNumber);
    LineLength := PtrInt(TextLength(Line));
    Selected := FindAnyMatch(Line, LineLength, 0, Start, Finish) <> Invert;
    if Selected then
    begin
      Inc(Count);
      AnySelected := True;
      if Quiet then
        Halt(StatusSelected);
      if not CountOnly and not ListFilesWith and not ListFilesWithout then
      begin
        if OnlyMatching then
        begin
          if not Invert then
          begin
            From := 0;
            while FindAnyMatch(Line, LineLength, From, Start, Finish) do
            begin
              if Finish > Start then
              begin
                WritePrefix(Name, LineNumber);
                WriteBytes(StandardOutput, Line + Start, QWord(Finish - Start));
                WriteCharacter(StandardOutput, #10);
                From := Finish;
              end
              else
                From := Start + 1;
              if From > LineLength then
                Break;
            end;
          end;
        end
        else
        begin
          WritePrefix(Name, LineNumber);
          WriteLine(StandardOutput, Line);
        end;
      end;
      if ListFilesWith then
      begin
        FreeMemory(Line);
        Break;
      end;
    end;
    FreeMemory(Line);
  end;

  if CountOnly then
  begin
    if ShowFileNames then
    begin
      WriteText(StandardOutput, Name);
      WriteCharacter(StandardOutput, ':');
    end;
    WriteDecimal(StandardOutput, Count);
    WriteCharacter(StandardOutput, #10);
  end;
  if ListFilesWith and (Count > 0) then
    WriteLine(StandardOutput, Name);
  if ListFilesWithout and (Count = 0) then
    WriteLine(StandardOutput, Name);
end;

procedure SearchPath(Path: PChar);
var
  Information: TFileInformation;
  Error: LongInt;
  Handle: Int64;
  Stream: PInputStream;
  Names: TLineList;
  Index: Integer;
  Child: PChar;
begin
  if TextIsEqual(Path, '-') then
  begin
    SearchStream(StandardInput, '(standard input)');
    Exit;
  end;
  Error := GetFileInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    if not NoMessages then
      ReportError(Error, '%s', [ArgumentText(Path)]);
    HadTrouble := True;
    Exit;
  end;
  if Information.Kind = KindDirectory then
  begin
    if not Recursive then
    begin
      if not NoMessages then
        Report('%s: Is a directory', [ArgumentText(Path)]);
      HadTrouble := True;
      Exit;
    end;
    BeginLineList(Names);
    ListDirectory(Path, Names);
    for Index := 0 to Names.Count - 1 do
    begin
      if ImplicitCurrentDirectory and TextIsEqual(Path, '.') then
        Child := DuplicateText(Names.Items[Index])
      else
        Child := JoinPath(Path, Names.Items[Index]);
      { Symbolic links inside the tree are not followed. }
      if (GetLinkInformation(Child, Information) = ErrorNone) and (Information.Kind <> KindSymbolicLink) then
        SearchPath(Child);
      FreeMemory(Child);
    end;
    FreeLineList(Names);
    Exit;
  end;
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
  begin
    if not NoMessages then
      ReportError(ErrorCodeOf(Handle), '%s', [ArgumentText(Path)]);
    HadTrouble := True;
    Exit;
  end;
  Stream := CreateInputStream(Handle);
  SearchStream(Stream, Path);
  DestroyInputStream(Stream);
  CloseFile(Handle);
end;

{ --color takes an optional value, which the option parser does not
  know; such arguments are simply dropped. }
procedure DropColorOptions;
var
  Index: Integer;
begin
  for Index := 1 to ArgumentTotal - 1 do
  begin
    if TextIsEqual(ArgumentValues[Index], '--') then
      Break;
    if TextStartsWith(ArgumentValues[Index], '--color') or TextStartsWith(ArgumentValues[Index], '--colour') then
      ArgumentValues[Index] := '--color';
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ProgramBase: PChar;
  HavePatterns: Boolean;
  FirstOperand: Integer;
  Index: Integer;
  ForceFileNames: Integer; { -1 never, 0 automatic, 1 always }
begin
  ProgramBase := BaseName(Argument(0));
  Kind := PatternBasic;
  if TextIsEqual(ProgramBase, 'egrep') then
    Kind := PatternExtended
  else if TextIsEqual(ProgramBase, 'fgrep') then
    Kind := PatternFixed;
  ForceFileNames := 0;
  BeginLineList(PatternTexts);
  HavePatterns := False;
  DropColorOptions;
  BeginOptions(Parser, [
    OptionDefinition('E', 'extended-regexp', False, OptionExtended),
    OptionDefinition('F', 'fixed-strings', False, OptionFixed),
    OptionDefinition('G', 'basic-regexp', False, OptionBasic),
    OptionDefinition('e', 'regexp', True, OptionPattern),
    OptionDefinition('f', 'file', True, OptionPatternFile),
    OptionDefinition('i', 'ignore-case', False, OptionIgnoreCase),
    OptionDefinition('y', nil, False, OptionIgnoreCase),
    OptionDefinition('w', 'word-regexp', False, OptionWord),
    OptionDefinition('x', 'line-regexp', False, OptionLine),
    OptionDefinition('s', 'no-messages', False, OptionNoMessages),
    OptionDefinition('v', 'invert-match', False, OptionInvert),
    OptionDefinition('n', 'line-number', False, OptionLineNumber),
    OptionDefinition('H', 'with-filename', False, OptionWithFileName),
    OptionDefinition('h', 'no-filename', False, OptionNoFileName),
    OptionDefinition('o', 'only-matching', False, OptionOnlyMatching),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'silent', False, OptionQuiet),
    OptionDefinition('r', 'recursive', False, OptionRecursive),
    OptionDefinition('R', 'dereference-recursive', False, OptionRecursive),
    OptionDefinition('L', 'files-without-match', False, OptionFilesWithout),
    OptionDefinition('l', 'files-with-matches', False, OptionFilesWith),
    OptionDefinition('c', 'count', False, OptionCount),
    OptionDefinition(#0, 'color', False, OptionColor),
    OptionDefinition(#0, 'colour', False, OptionColor)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionExtended: Kind := PatternExtended;
      OptionFixed: Kind := PatternFixed;
      OptionBasic: Kind := PatternBasic;
      OptionPattern:
        begin
          AddPatternLines(Value);
          HavePatterns := True;
        end;
      OptionPatternFile:
        begin
          AddPatternFile(Value);
          HavePatterns := True;
        end;
      OptionIgnoreCase: IgnoreCase := True;
      OptionWord: WholeWords := True;
      OptionLine: WholeLines := True;
      OptionNoMessages: NoMessages := True;
      OptionInvert: Invert := True;
      OptionLineNumber: ShowLineNumbers := True;
      OptionWithFileName: ForceFileNames := 1;
      OptionNoFileName: ForceFileNames := -1;
      OptionOnlyMatching: OnlyMatching := True;
      OptionQuiet: Quiet := True;
      OptionRecursive: Recursive := True;
      OptionFilesWithout: ListFilesWithout := True;
      OptionFilesWith: ListFilesWith := True;
      OptionCount: CountOnly := True;
    end;

  FirstOperand := 0;
  if not HavePatterns then
  begin
    if Parser.OperandCount = 0 then
      FailWithUsageHint('no pattern given', []);
    AddPatternLines(Parser.Operands[0]);
    FirstOperand := 1;
  end;
  CompilePatterns;

  if FirstOperand >= Parser.OperandCount then
  begin
    if Recursive then
    begin
      Parser.Operands[Parser.OperandCount] := '.';
      ImplicitCurrentDirectory := True;
    end
    else
      Parser.Operands[Parser.OperandCount] := '-';
    Inc(Parser.OperandCount);
  end;
  case ForceFileNames of
    1: ShowFileNames := True;
    -1: ShowFileNames := False;
  else
    ShowFileNames := Recursive or (Parser.OperandCount - FirstOperand > 1);
  end;

  for Index := FirstOperand to Parser.OperandCount - 1 do
    SearchPath(Parser.Operands[Index]);

  if HadTrouble and not (Quiet and AnySelected) then
    Halt(StatusTrouble);
  if AnySelected then
    Halt(StatusSelected);
  Halt(StatusNothingSelected);
end.
