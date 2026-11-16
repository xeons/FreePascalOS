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

{$mode objfpc}{$H+}
{$pointermath on}

uses
  SysUtils,
  Classes,
  StrUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Output,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage = 'Usage: grep [OPTION]... PATTERNS [FILE]...'#10 +
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

  WordCharacters = ['A'..'Z', 'a'..'z', '0'..'9', '_'];

type
  TPatternKind = (PatternBasic, PatternExtended, PatternFixed);

  { The patterns, and how lines are matched against them. }
  TLineMatcher = class
  private
    FKind: TPatternKind;
    FIgnoreCase: Boolean;
    FWholeWords: Boolean;
    FWholeLines: Boolean;
    FTexts: TStringList;
    FExpressions: array of TExpression;
    function AnchoredPattern(const Text: string): string;
    function IsWholeWord(const Line: string; Start, Finish: PtrInt): Boolean;
    function SameTextAt(const Line: string; Position: PtrInt; const Pattern: string): Boolean;
    function FindFixed(const Pattern, Line: string; From: PtrInt; out Start, Finish: PtrInt): Boolean;
    function FindExpression(const Expression: TExpression; const Line: string; From: PtrInt;
      out Start, Finish: PtrInt): Boolean;
    function FindMatch(Index: Integer; const Line: string; From: PtrInt; out Start, Finish: PtrInt): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { Adds every line of Text as a pattern. }
    procedure AddPatternLines(const Text: string);
    procedure AddPatternFile(const Path: string);
    { Compiles the patterns; reports a bad one and ends the program. }
    procedure Compile;
    { The earliest match of any pattern at or after byte offset From
      (the longest of those starting there). }
    function FindAnyMatch(const Line: string; From: PtrInt; out Start, Finish: PtrInt): Boolean;
    property Kind: TPatternKind read FKind write FKind;
    property IgnoreCase: Boolean read FIgnoreCase write FIgnoreCase;
    property WholeWords: Boolean read FWholeWords write FWholeWords;
    property WholeLines: Boolean read FWholeLines write FWholeLines;
  end;

var
  Matcher: TLineMatcher;
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

  AnySelected: Boolean;
  HadTrouble: Boolean;
  { With -r and no FILE, names are shown without a leading "./". }
  ImplicitCurrentDirectory: Boolean;

{ --- Patterns -------------------------------------------------------- }

constructor TLineMatcher.Create;
begin
  inherited Create;
  FTexts := TStringList.Create;
end;

destructor TLineMatcher.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FExpressions) do
    if FExpressions[Index].Root <> nil then
      FreeExpression(FExpressions[Index]);
  FTexts.Free;
  inherited Destroy;
end;

procedure TLineMatcher.AddPatternLines(const Text: string);
var
  Start: Integer;
  Position: Integer;
begin
  Start := 1;
  for Position := 1 to Length(Text) do
    if Text[Position] = #10 then
    begin
      FTexts.Add(Copy(Text, Start, Position - Start));
      Start := Position + 1;
    end;
  FTexts.Add(Copy(Text, Start, MaxInt));
end;

procedure TLineMatcher.AddPatternFile(const Path: string);
var
  Stream: PInputStream;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Halt(StatusTrouble);
  ReadLinesInto(Stream, FTexts);
  CloseInput(Stream);
end;

{ For -x the pattern is anchored at both ends; a group keeps
  alternatives together. }
function TLineMatcher.AnchoredPattern(const Text: string): string;
begin
  if FKind = PatternExtended then
    Result := '^(' + Text + ')$'
  else
    Result := '^\(' + Text + '\)$';
end;

procedure TLineMatcher.Compile;
var
  Index: Integer;
  Source: string;
  ErrorMessage: string;
  Syntax: TExpressionSyntax;
begin
  SetLength(FExpressions, FTexts.Count);
  if FKind = PatternFixed then
    Exit;
  if FKind = PatternExtended then
    Syntax := SyntaxExtended
  else
    Syntax := SyntaxBasic;
  for Index := 0 to FTexts.Count - 1 do
  begin
    if FWholeLines then
      Source := AnchoredPattern(FTexts[Index])
    else
      Source := FTexts[Index];
    if not CompileExpression(Source, Syntax, FExpressions[Index], ErrorMessage) then
    begin
      Report(ErrorMessage);
      Halt(StatusTrouble);
    end;
    FExpressions[Index].IgnoreCase := FIgnoreCase;
  end;
end;

{ --- Matching -------------------------------------------------------- }

{ Start and Finish are byte offsets from 0, Finish just past the match. }
function TLineMatcher.IsWholeWord(const Line: string; Start, Finish: PtrInt): Boolean;
begin
  Result := ((Start = 0) or not (Line[Start] in WordCharacters)) and
    ((Finish >= Length(Line)) or not (Line[Finish + 1] in WordCharacters));
end;

{ True if Pattern is at byte offset Position of Line (which has room). }
function TLineMatcher.SameTextAt(const Line: string; Position: PtrInt; const Pattern: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Pattern) do
  begin
    if FIgnoreCase then
    begin
      if LowerCase(Line[Position + Index]) <> LowerCase(Pattern[Index]) then
        Exit(False);
    end
    else if Line[Position + Index] <> Pattern[Index] then
      Exit(False);
  end;
  Result := True;
end;

function TLineMatcher.FindFixed(const Pattern, Line: string; From: PtrInt; out Start, Finish: PtrInt): Boolean;
var
  Position: PtrInt;
begin
  if FWholeLines then
  begin
    Result := (From = 0) and (Length(Pattern) = Length(Line)) and SameTextAt(Line, 0, Pattern);
    if Result then
    begin
      Start := 0;
      Finish := Length(Line);
    end;
    Exit;
  end;
  Position := From;
  while Position + Length(Pattern) <= Length(Line) do
  begin
    if SameTextAt(Line, Position, Pattern) and
       (not FWholeWords or IsWholeWord(Line, Position, Position + Length(Pattern))) then
    begin
      Start := Position;
      Finish := Position + Length(Pattern);
      Exit(True);
    end;
    Inc(Position);
  end;
  Result := False;
end;

function TLineMatcher.FindExpression(const Expression: TExpression; const Line: string; From: PtrInt;
  out Start, Finish: PtrInt): Boolean;
var
  Position: PtrInt;
  Match: TMatch;
begin
  Position := From;
  while Position <= Length(Line) do
  begin
    if not SearchExpressionFrom(Expression, Line, Position, Match) then
      Exit(False);
    if not FWholeWords or IsWholeWord(Line, Match.Starts[0], Match.Ends[0]) then
    begin
      Start := Match.Starts[0];
      Finish := Match.Ends[0];
      Exit(True);
    end;
    Position := Match.Starts[0] + 1;
  end;
  Result := False;
end;

{ The first acceptable match of pattern Index at or after From. }
function TLineMatcher.FindMatch(Index: Integer; const Line: string; From: PtrInt;
  out Start, Finish: PtrInt): Boolean;
begin
  Start := -1;
  Finish := -1;
  if FKind = PatternFixed then
    Result := FindFixed(FTexts[Index], Line, From, Start, Finish)
  else
    Result := FindExpression(FExpressions[Index], Line, From, Start, Finish);
end;

function TLineMatcher.FindAnyMatch(const Line: string; From: PtrInt; out Start, Finish: PtrInt): Boolean;
var
  Index: Integer;
  CandidateStart: PtrInt;
  CandidateFinish: PtrInt;
begin
  Result := False;
  Start := -1;
  Finish := -1;
  for Index := 0 to FTexts.Count - 1 do
    if FindMatch(Index, Line, From, CandidateStart, CandidateFinish) then
      if not Result or (CandidateStart < Start) or
         ((CandidateStart = Start) and (CandidateFinish > Finish)) then
      begin
        Start := CandidateStart;
        Finish := CandidateFinish;
        Result := True;
      end;
end;

{ --- Searching files ------------------------------------------------- }

function LinePrefix(const Name: string; LineNumber: Int64): string;
begin
  Result := '';
  if ShowFileNames then
    Result := Name + ':';
  if ShowLineNumbers then
    Result := Result + IntToStr(LineNumber) + ':';
end;

{ -o: every nonempty match of Line on a line of its own. }
procedure PrintMatches(const Line, Name: string; LineNumber: Int64);
var
  From: PtrInt;
  Start: PtrInt;
  Finish: PtrInt;
begin
  From := 0;
  while Matcher.FindAnyMatch(Line, From, Start, Finish) do
  begin
    if Finish > Start then
    begin
      PrintStringLine(LinePrefix(Name, LineNumber) + Copy(Line, Start + 1, Finish - Start));
      From := Finish;
    end
    else
      From := Start + 1;
    if From > Length(Line) then
      Break;
  end;
end;

{ Searches one stream; Name is how it is shown. }
procedure SearchStream(Stream: PInputStream; const Name: string);
var
  Line: string;
  HadLineEnd: Boolean;
  LineNumber: Int64;
  Count: Int64;
  Start: PtrInt;
  Finish: PtrInt;
begin
  LineNumber := 0;
  Count := 0;
  while ReadTextLine(Stream, Line, HadLineEnd) do
  begin
    Inc(LineNumber);
    if Matcher.FindAnyMatch(Line, 0, Start, Finish) = Invert then
      Continue;
    Inc(Count);
    AnySelected := True;
    if Quiet then
      Halt(StatusSelected);
    if not CountOnly and not ListFilesWith and not ListFilesWithout then
    begin
      if not OnlyMatching then
        PrintStringLine(LinePrefix(Name, LineNumber) + Line)
      else if not Invert then
        PrintMatches(Line, Name, LineNumber);
    end;
    if ListFilesWith then
      Break;
  end;

  if CountOnly then
  begin
    if ShowFileNames then
      PrintString(Name + ':');
    PrintStringLine(IntToStr(Count));
  end;
  if ListFilesWith and (Count > 0) then
    PrintStringLine(Name);
  if ListFilesWithout and (Count = 0) then
    PrintStringLine(Name);
end;

procedure SearchPath(const Path: string); forward;

procedure SearchDirectory(const Path: string);
var
  Names: TStringList;
  Name: string;
  Child: string;
  Information: TFileInformation;
begin
  Names := TStringList.Create;
  try
    ListDirectory(Path, Names);
    for Name in Names do
    begin
      if ImplicitCurrentDirectory and (Path = '.') then
        Child := Name
      else
        Child := JoinPath(Path, Name);
      { Symbolic links inside the tree are not followed. }
      if (GetLinkInformation(PChar(Child), Information) = ErrorNone) and
         (Information.Kind <> KindSymbolicLink) then
        SearchPath(Child);
    end;
  finally
    Names.Free;
  end;
end;

procedure SearchPath(const Path: string);
var
  Information: TFileInformation;
  Error: LongInt;
  Handle: Int64;
  Stream: PInputStream;
begin
  if Path = '-' then
  begin
    SearchStream(StandardInput, '(standard input)');
    Exit;
  end;
  Error := GetFileInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    if not NoMessages then
      ReportError(Error, Path);
    HadTrouble := True;
    Exit;
  end;
  if Information.Kind = KindDirectory then
  begin
    if Recursive then
      SearchDirectory(Path)
    else
    begin
      if not NoMessages then
        Report(Path + ': Is a directory');
      HadTrouble := True;
    end;
    Exit;
  end;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
  begin
    if not NoMessages then
      ReportError(ErrorCodeOf(Handle), Path);
    HadTrouble := True;
    Exit;
  end;
  Stream := CreateInputStream(Handle);
  SearchStream(Stream, Path);
  DestroyInputStream(Stream);
  CloseFile(Handle);
end;

{ --color takes an optional value, which the option parser does not
  know; such arguments are made plain "--color" in the program's own
  argument list, which the parser reads. }
procedure DropColorOptions;
var
  Index: Integer;
  Arguments: PPChar;
begin
  Arguments := ArgumentValues;
  for Index := 1 to ArgumentTotal - 1 do
  begin
    if string(Arguments[Index]) = '--' then
      Break;
    if StartsStr('--color', Arguments[Index]) or StartsStr('--colour', Arguments[Index]) then
      Arguments[Index] := '--color';
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  ProgramBase: string;
  HavePatterns: Boolean;
  Paths: TStringArray;
  Path: string;
  ForceFileNames: Integer; { -1 never, 0 automatic, 1 always }
begin
  Matcher := TLineMatcher.Create;
  ProgramBase := BaseName(string(Argument(0)));
  if ProgramBase = 'egrep' then
    Matcher.Kind := PatternExtended
  else if ProgramBase = 'fgrep' then
    Matcher.Kind := PatternFixed;
  ForceFileNames := 0;
  HavePatterns := False;
  DropColorOptions;
  CommandLine := TCommandLine.Create([
    CommandOption('E', 'extended-regexp', False, OptionExtended),
    CommandOption('F', 'fixed-strings', False, OptionFixed),
    CommandOption('G', 'basic-regexp', False, OptionBasic),
    CommandOption('e', 'regexp', True, OptionPattern),
    CommandOption('f', 'file', True, OptionPatternFile),
    CommandOption('i', 'ignore-case', False, OptionIgnoreCase),
    CommandOption('y', '', False, OptionIgnoreCase),
    CommandOption('w', 'word-regexp', False, OptionWord),
    CommandOption('x', 'line-regexp', False, OptionLine),
    CommandOption('s', 'no-messages', False, OptionNoMessages),
    CommandOption('v', 'invert-match', False, OptionInvert),
    CommandOption('n', 'line-number', False, OptionLineNumber),
    CommandOption('H', 'with-filename', False, OptionWithFileName),
    CommandOption('h', 'no-filename', False, OptionNoFileName),
    CommandOption('o', 'only-matching', False, OptionOnlyMatching),
    CommandOption('q', 'quiet', False, OptionQuiet),
    CommandOption(#0, 'silent', False, OptionQuiet),
    CommandOption('r', 'recursive', False, OptionRecursive),
    CommandOption('R', 'dereference-recursive', False, OptionRecursive),
    CommandOption('L', 'files-without-match', False, OptionFilesWithout),
    CommandOption('l', 'files-with-matches', False, OptionFilesWith),
    CommandOption('c', 'count', False, OptionCount),
    CommandOption(#0, 'color', False, OptionColor),
    CommandOption(#0, 'colour', False, OptionColor)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionExtended: Matcher.Kind := PatternExtended;
      OptionFixed: Matcher.Kind := PatternFixed;
      OptionBasic: Matcher.Kind := PatternBasic;
      OptionPattern:
        begin
          Matcher.AddPatternLines(Value);
          HavePatterns := True;
        end;
      OptionPatternFile:
        begin
          Matcher.AddPatternFile(Value);
          HavePatterns := True;
        end;
      OptionIgnoreCase: Matcher.IgnoreCase := True;
      OptionWord: Matcher.WholeWords := True;
      OptionLine: Matcher.WholeLines := True;
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

  Paths := CommandLine.Operands;
  if not HavePatterns then
  begin
    if Length(Paths) = 0 then
      FailWithUsageHint('no pattern given');
    Matcher.AddPatternLines(Paths[0]);
    Paths := Copy(Paths, 1, MaxInt);
  end;
  Matcher.Compile;

  if Length(Paths) = 0 then
  begin
    if Recursive then
    begin
      Paths := ['.'];
      ImplicitCurrentDirectory := True;
    end
    else
      Paths := ['-'];
  end;
  case ForceFileNames of
    1: ShowFileNames := True;
    -1: ShowFileNames := False;
  else
    ShowFileNames := Recursive or (Length(Paths) > 1);
  end;

  for Path in Paths do
    SearchPath(Path);

  if HadTrouble and not (Quiet and AnySelected) then
    Halt(StatusTrouble);
  if AnySelected then
    Halt(StatusSelected);
  Halt(StatusNothingSelected);
end.
