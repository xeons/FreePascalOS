{
  sed - stream editor for filtering and transforming text

  sed [-nEsuz] [-i[SUFFIX]] [-e SCRIPT]... [-f FILE]... [SCRIPT] [FILE]...

  The script is a list of commands, each with up to two addresses:
    N  a line number      $  the last line      /RE/  lines matching RE
    \cREc  RE with another delimiter      ADDR1,+N  ADDR1 and N more lines
    FIRST~STEP  every STEP-th line from FIRST      ADDR!  lines NOT matching

  Commands:
    {  }        group commands
    s/RE/REPLACEMENT/FLAGS   substitute (flags g, N, p, I, w FILE)
    y/SOURCE/DEST/  transliterate characters
    p P         print the pattern space (P: up to the first line end)
    d D         delete the pattern space (D: up to the first line end)
    n N         next line (N: append it)
    g G h H x   copy, append or exchange with the hold space
    a i c TEXT  append, insert, change
    =           print the line number      l  print unambiguously
    r FILE      append FILE's contents     w FILE  write the pattern space
    b t T LABEL branch always / if a substitution was made / if not
    : LABEL     a label        q Q [CODE]  quit (Q: without printing)
    # comment

  Regular expressions are basic (extended with -E or -r); an empty RE
  repeats the last one used. In replacements, & is the match, \1-\9 the
  groups and \n a line end.
}
program sed;

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
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.RegularExpressions;

const
  Usage: PChar = 'Usage: sed [OPTION]... {script-only-if-no-other-script} [input-file]...'#10#10 +
    '  -n, --quiet, --silent'#10 +
    '                 suppress automatic printing of pattern space'#10 +
    '  -e script, --expression=script'#10 +
    '                 add the script to the commands to be executed'#10 +
    '  -f script-file, --file=script-file'#10 +
    '                 add the contents of script-file to the commands to be executed'#10 +
    '  -i[SUFFIX], --in-place[=SUFFIX]'#10 +
    '                 edit files in place (makes backup if SUFFIX supplied)'#10 +
    '  -E, -r, --regexp-extended'#10 +
    '                 use extended regular expressions in the script'#10 +
    '  -s, --separate'#10 +
    '                 consider files as separate rather than as a single'#10 +
    '                 continuous long stream.'#10 +
    '  -z, --null-data'#10 +
    '                 separate lines by NUL characters'#10;

  OptionQuiet = 1;
  OptionExpression = 2;
  OptionScriptFile = 3;
  OptionExtended = 4;
  OptionSeparate = 5;
  OptionNullData = 6;
  OptionUnbuffered = 7;
  OptionPosix = 8;

  MaximumCommands = 1024;
  MaximumWriteFiles = 32;
  LineWrapWidth = 70;

type
  TAddressKind = (AddressNone, AddressLine, AddressLast, AddressRegex, AddressStep, AddressRelative);

  TAddress = record
    Kind: TAddressKind;
    Line: Int64;
    Step: Int64;
    Expression: ^TExpression;  { nil = the last regex used }
  end;

  TWriteFile = record
    Path: PChar;
    Handle: Int64;
    Stream: POutputStream;
  end;

  PCommand = ^TCommand;
  TCommand = record
    First: TAddress;
    Second: TAddress;
    Negate: Boolean;
    Name: Char;
    Text: PChar;              { a i c text, label, file name }
    Expression: ^TExpression; { s: nil = last regex }
    Replacement: PChar;
    Global: Boolean;
    Occurrence: Int64;
    PrintAfter: Boolean;
    WriteFile: Integer;       { index, -1 = none }
    ExitCode: LongInt;
    Translation: array[Char] of Char;
    { For '{': the index after the matching '}'. For b t T: the target. }
    JumpTarget: Integer;
    { Range state. }
    InRange: Boolean;
    RangeEnd: Int64;
  end;

  { Output queued until the end of the cycle (a, r). }
  TQueuedOutput = record
    IsFile: Boolean;
    Text: PChar;
  end;

var
  Syntax: TExpressionSyntax;
  Quiet: Boolean;
  Separate: Boolean;
  InPlace: Boolean;
  InPlaceSuffix: PChar;
  LineEnd: Char;

  Script: TTextBuilder;
  Commands: array[0..MaximumCommands - 1] of TCommand;
  CommandCount: Integer;
  WriteFiles: array[0..MaximumWriteFiles - 1] of TWriteFile;
  WriteFileCount: Integer;
  LastExpression: ^TExpression;

  PatternSpace: TTextBuilder;
  HoldSpace: TTextBuilder;
  Queue: array[0..255] of TQueuedOutput;
  QueueCount: Integer;
  Output: POutputStream;
  LineNumber: Int64;
  Substituted: Boolean;
  Quitting: Boolean;
  QuitCode: LongInt;

  { Input: the files in turn, one line read ahead to recognize "$". }
  InputFiles: PPChar;
  InputFileCount: Integer;
  InputIndex: Integer;
  CurrentInput: PInputStream;
  LookAhead: PChar;
  HaveLookAhead: Boolean;
  ExitStatus: LongInt;

{ --- Parsing --------------------------------------------------------- }

var
  Position: PtrInt;

procedure ScriptError(Message: PChar);
begin
  Fail(1, '-e expression #1, char %d: %s', [ArgumentNumber(Position), ArgumentText(Message)]);
end;

function Current: Char;
begin
  Result := Script.Text[Position];
end;

procedure SkipBlanks;
begin
  while (Current = ' ') or (Current = #9) do
    Inc(Position);
end;

procedure SkipBlanksAndSeparators;
begin
  while Current in [' ', #9, #10, ';'] do
    Inc(Position);
end;

{ Reads text up to Delimiter (not escaped by '\'), turning "\n" into a
  line end and "\Delimiter" into the delimiter; other escapes are kept
  for the regex or replacement parser. }
function ReadDelimited(Delimiter: Char; KeepOtherEscapes: Boolean): PChar;
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  while Current <> Delimiter do
  begin
    if Current = #0 then
      ScriptError('unterminated `s'' command');
    if (Current = '\') and (Script.Text[Position + 1] <> #0) then
    begin
      Inc(Position);
      if Current = Delimiter then
        AppendCharacter(Builder, Delimiter)
      else if (Current = 'n') then
        AppendCharacter(Builder, #10)
      else
      begin
        AppendCharacter(Builder, '\');
        AppendCharacter(Builder, Current);
      end;
      Inc(Position);
      Continue;
    end;
    AppendCharacter(Builder, Current);
    Inc(Position);
  end;
  Inc(Position);
  Result := FinishText(Builder);
end;

function CompileRegex(Text: PChar; IgnoreCase: Boolean): Pointer;
var
  Expression: ^TExpression;
  ErrorMessage: PChar;
begin
  if Text^ = #0 then
    Exit(nil); { the last regex }
  Expression := AllocateZeroedMemory(SizeOf(TExpression));
  if not CompileExpression(Text, Syntax, Expression^, ErrorMessage) then
    ScriptError(ErrorMessage);
  Expression^.IgnoreCase := IgnoreCase;
  Result := Expression;
end;

function ParseNumber: Int64;
begin
  Result := 0;
  while IsDigit(Current) do
  begin
    Result := Result * 10 + Ord(Current) - Ord('0');
    Inc(Position);
  end;
end;

function ParseAddress(out Address: TAddress; IsSecond: Boolean): Boolean;
var
  Delimiter: Char;
  Text: PChar;
begin
  Address.Kind := AddressNone;
  Address.Expression := nil;
  Result := True;
  if IsDigit(Current) then
  begin
    Address.Kind := AddressLine;
    Address.Line := ParseNumber;
    if Current = '~' then
    begin
      Inc(Position);
      Address.Kind := AddressStep;
      Address.Step := ParseNumber;
    end;
  end
  else if IsSecond and (Current = '+') and IsDigit(Script.Text[Position + 1]) then
  begin
    Inc(Position);
    Address.Kind := AddressRelative;
    Address.Line := ParseNumber;
  end
  else if Current = '$' then
  begin
    Address.Kind := AddressLast;
    Inc(Position);
  end
  else if (Current = '/') or (Current = '\') then
  begin
    if Current = '\' then
      Inc(Position);
    Delimiter := Current;
    Inc(Position);
    Text := ReadDelimited(Delimiter, False);
    Address.Kind := AddressRegex;
    if Current = 'I' then
    begin
      Inc(Position);
      Address.Expression := CompileRegex(Text, True);
    end
    else
      Address.Expression := CompileRegex(Text, False);
    FreeMemory(Text);
  end
  else
    Result := False;
end;

{ Text for a, i and c: "a text" or "a\" followed by lines; a line
  ending in a backslash continues. }
function ParseText: PChar;
var
  Builder: TTextBuilder;
begin
  SkipBlanks;
  if Current = '\' then
  begin
    Inc(Position);
    SkipBlanks;
    if Current = #10 then
      Inc(Position);
  end;
  BeginText(Builder);
  while (Current <> #0) and (Current <> #10) do
  begin
    if Current = '\' then
    begin
      Inc(Position);
      if Current = #0 then
        Break;
      AppendCharacter(Builder, Current);
      Inc(Position);
      Continue;
    end;
    AppendCharacter(Builder, Current);
    Inc(Position);
  end;
  Result := FinishText(Builder);
end;

{ A label or file name: the rest of the line (labels also end at ';'). }
function ParseWord(StopAtSemicolon: Boolean): PChar;
var
  Start: PtrInt;
  Finish: PtrInt;
begin
  SkipBlanks;
  Start := Position;
  while (Current <> #0) and (Current <> #10) and not (StopAtSemicolon and (Current = ';')) do
    Inc(Position);
  Finish := Position;
  while (Finish > Start) and (Script.Text[Finish - 1] in [' ', #9]) do
    Dec(Finish);
  Result := PChar(AllocateMemory(Finish - Start + 1));
  CopyMemory(Result, Script.Text + Start, Finish - Start);
  Result[Finish - Start] := #0;
end;

function OpenWriteFile(Path: PChar): Integer;
var
  Index: Integer;
begin
  for Index := 0 to WriteFileCount - 1 do
    if TextIsEqual(WriteFiles[Index].Path, Path) then
      Exit(Index);
  if WriteFileCount = MaximumWriteFiles then
    ScriptError('too many output files');
  WriteFiles[WriteFileCount].Path := Path;
  if TextIsEqual(Path, '/dev/stdout') then
  begin
    WriteFiles[WriteFileCount].Handle := -1;
    WriteFiles[WriteFileCount].Stream := StandardOutput;
  end
  else
  begin
    WriteFiles[WriteFileCount].Handle := OpenFile(Path, OpenWrite or OpenCreate or OpenTruncate);
    if WriteFiles[WriteFileCount].Handle < 0 then
      FailWithError(4, ErrorCodeOf(WriteFiles[WriteFileCount].Handle), 'couldn''t open file %s',
        [ArgumentText(Path)]);
    WriteFiles[WriteFileCount].Stream := CreateOutputStream(WriteFiles[WriteFileCount].Handle);
  end;
  Result := WriteFileCount;
  Inc(WriteFileCount);
end;

procedure ParseSubstitution(Command: PCommand);
var
  Delimiter: Char;
  RegexText: PChar;
  IgnoreCase: Boolean;
begin
  Delimiter := Current;
  if (Delimiter = #0) or (Delimiter = #10) or (Delimiter = '\') then
    ScriptError('unterminated `s'' command');
  Inc(Position);
  RegexText := ReadDelimited(Delimiter, False);
  Command^.Replacement := ReadDelimited(Delimiter, True);
  Command^.Global := False;
  Command^.Occurrence := 1;
  Command^.WriteFile := -1;
  IgnoreCase := False;
  repeat
    case Current of
      'g': begin Command^.Global := True; Inc(Position); end;
      'p': begin Command^.PrintAfter := True; Inc(Position); end;
      'i', 'I': begin IgnoreCase := True; Inc(Position); end;
      '0'..'9': Command^.Occurrence := ParseNumber;
      'w':
        begin
          Inc(Position);
          Command^.WriteFile := OpenWriteFile(ParseWord(False));
          Break;
        end;
    else
      Break;
    end;
  until False;
  if Command^.Occurrence < 1 then
    ScriptError('number option to `s'' command may not be zero');
  Command^.Expression := CompileRegex(RegexText, IgnoreCase);
  FreeMemory(RegexText);
end;

procedure ParseTransliteration(Command: PCommand);
var
  Delimiter: Char;
  Source: PChar;
  Destination: PChar;
  Character: Char;
  Index: PtrUInt;
begin
  Delimiter := Current;
  Inc(Position);
  Source := ReadDelimited(Delimiter, True);
  Destination := ReadDelimited(Delimiter, True);
  if TextLength(Source) <> TextLength(Destination) then
    ScriptError('strings for `y'' command are different lengths');
  for Character := #0 to #255 do
    Command^.Translation[Character] := Character;
  Index := 0;
  while Source[Index] <> #0 do
  begin
    Command^.Translation[Source[Index]] := Destination[Index];
    Inc(Index);
  end;
  FreeMemory(Source);
  FreeMemory(Destination);
end;

procedure ParseScript;
var
  Command: PCommand;
  OpenBlocks: array[0..63] of Integer;
  OpenBlockCount: Integer;
  Index: Integer;
  Target: Integer;
begin
  Position := 0;
  CommandCount := 0;
  OpenBlockCount := 0;
  repeat
    SkipBlanksAndSeparators;
    if Current = #0 then
      Break;
    if Current = '#' then
    begin
      while (Current <> #0) and (Current <> #10) do
        Inc(Position);
      Continue;
    end;
    if CommandCount = MaximumCommands then
      ScriptError('too many commands');
    Command := @Commands[CommandCount];
    ZeroMemory(Command, SizeOf(TCommand));
    Command^.WriteFile := -1;
    Command^.JumpTarget := -1;
    if ParseAddress(Command^.First, False) then
    begin
      SkipBlanks;
      if Current = ',' then
      begin
        Inc(Position);
        SkipBlanks;
        if not ParseAddress(Command^.Second, True) then
          ScriptError('unexpected `,''');
      end;
    end;
    SkipBlanks;
    while Current = '!' do
    begin
      Command^.Negate := True;
      Inc(Position);
      SkipBlanks;
    end;
    Command^.Name := Current;
    if Current = #0 then
      ScriptError('missing command');
    Inc(Position);
    case Command^.Name of
      '{':
        begin
          OpenBlocks[OpenBlockCount] := CommandCount;
          Inc(OpenBlockCount);
        end;
      '}':
        begin
          if OpenBlockCount = 0 then
            ScriptError('unexpected `}''');
          Dec(OpenBlockCount);
          Commands[OpenBlocks[OpenBlockCount]].JumpTarget := CommandCount + 1;
        end;
      's': ParseSubstitution(Command);
      'y': ParseTransliteration(Command);
      'a', 'i', 'c': Command^.Text := ParseText;
      ':':
        begin
          Command^.Text := ParseWord(True);
          if Command^.Text^ = #0 then
            ScriptError('":" lacks a label');
        end;
      'b', 't', 'T': Command^.Text := ParseWord(True);
      'r': Command^.Text := ParseWord(False);
      'w': Command^.WriteFile := OpenWriteFile(ParseWord(False));
      'q', 'Q':
        begin
          SkipBlanks;
          Command^.ExitCode := LongInt(ParseNumber);
        end;
      'p', 'P', 'd', 'D', 'n', 'N', 'g', 'G', 'h', 'H', 'x', '=', 'l', 'z':
        ;
    else
      Fail(1, '-e expression #1, char %d: unknown command: `%c''', [ArgumentNumber(Position),
        ArgumentCharacter(Command^.Name)]);
    end;
    Inc(CommandCount);
  until False;
  if OpenBlockCount > 0 then
    ScriptError('unmatched `{''');

  { Resolve branch targets; an empty label means the end of the script. }
  for Index := 0 to CommandCount - 1 do
    if Commands[Index].Name in ['b', 't', 'T'] then
    begin
      if Commands[Index].Text^ = #0 then
        Commands[Index].JumpTarget := CommandCount
      else
      begin
        Commands[Index].JumpTarget := -1;
        for Target := 0 to CommandCount - 1 do
          if (Commands[Target].Name = ':') and TextIsEqual(Commands[Target].Text, Commands[Index].Text) then
            Commands[Index].JumpTarget := Target;
        if Commands[Index].JumpTarget < 0 then
          Fail(1, '-e expression #1, char 0: can''t find label for jump to `%s''',
            [ArgumentText(Commands[Index].Text)]);
      end;
    end;
end;

{ --- Input ----------------------------------------------------------- }

{ Opens the next input file; False when there are none left. }
function OpenNextInput: Boolean;
var
  Path: PChar;
begin
  Result := False;
  while InputIndex < InputFileCount do
  begin
    Path := InputFiles[InputIndex];
    Inc(InputIndex);
    if TextIsEqual(Path, '-') then
      CurrentInput := StandardInput
    else
    begin
      if IsDirectory(Path) then
      begin
        Report('couldn''t edit %s: not a regular file', [ArgumentText(Path)]);
        ExitStatus := 2;
        Continue;
      end;
      CurrentInput := OpenInput(Path);
      if CurrentInput = nil then
      begin
        ExitStatus := 2;
        Continue;
      end;
    end;
    Exit(True);
  end;
end;

{ Reads the next raw line from the input files (in order). }
function ReadRawLine(out Line: PChar): Boolean;
var
  HadLineEnd: Boolean;
  Builder: TTextBuilder;
  Character: Char;
begin
  repeat
    if CurrentInput = nil then
      if not OpenNextInput then
        Exit(False);
    if LineEnd = #10 then
    begin
      if ReadLine(CurrentInput, Line, HadLineEnd) then
        Exit(True);
    end
    else
    begin
      BeginText(Builder);
      Result := False;
      while ReadCharacter(CurrentInput, Character) do
      begin
        Result := True;
        if Character = LineEnd then
          Break;
        AppendCharacter(Builder, Character);
      end;
      if Result then
      begin
        Line := FinishText(Builder);
        Exit(True);
      end;
      DiscardText(Builder);
    end;
    CloseInput(CurrentInput);
    CurrentInput := nil;
    { With -s or -i each file is its own stream. }
    if Separate then
      Exit(False);
  until False;
end;

function NextLine(out Line: PChar): Boolean;
begin
  if not HaveLookAhead then
    HaveLookAhead := ReadRawLine(LookAhead);
  Result := HaveLookAhead;
  Line := LookAhead;
  if Result then
    HaveLookAhead := ReadRawLine(LookAhead);
  if Result then
    Inc(LineNumber);
end;

function IsLastLine: Boolean;
begin
  if not HaveLookAhead then
    HaveLookAhead := ReadRawLine(LookAhead);
  Result := not HaveLookAhead;
end;

{ --- Output ---------------------------------------------------------- }

procedure WritePatternSpace(Stream: POutputStream; UpToLineEnd: Boolean);
var
  Length: PtrUInt;
  Newline: PtrInt;
begin
  Length := PatternSpace.Length;
  if UpToLineEnd then
  begin
    Newline := FindCharacter(PatternSpace.Text, #10);
    if Newline >= 0 then
      Length := PtrUInt(Newline);
  end;
  WriteBytes(Stream, PatternSpace.Text, Length);
  WriteCharacter(Stream, LineEnd);
end;

procedure WriteUnambiguous;
const
  Escapes: array[7..13] of Char = ('a', 'b', 't', 'n', 'v', 'f', 'r');
var
  Index: PtrUInt;
  Column: Integer;
  Piece: array[0..7] of Char;
  Character: Byte;
  PieceText: PChar;

  procedure Emit(Text: PChar);
  begin
    if Column + Integer(TextLength(Text)) > LineWrapWidth - 1 then
    begin
      WriteText(Output, '\'#10);
      Column := 0;
    end;
    WriteText(Output, Text);
    Column := Column + Integer(TextLength(Text));
  end;

begin
  Column := 0;
  for Index := 0 to PatternSpace.Length - 1 do
  begin
    Character := Byte(PatternSpace.Text[Index]);
    if Character = Ord('\') then
      PieceText := '\\'
    else if (Character >= 7) and (Character <= 13) then
    begin
      Piece[0] := '\';
      Piece[1] := Escapes[Character];
      Piece[2] := #0;
      PieceText := @Piece[0];
    end
    else if (Character < 32) or (Character >= 127) then
    begin
      Piece[0] := '\';
      Piece[1] := Char(Ord('0') + (Character shr 6));
      Piece[2] := Char(Ord('0') + ((Character shr 3) and 7));
      Piece[3] := Char(Ord('0') + (Character and 7));
      Piece[4] := #0;
      PieceText := @Piece[0];
    end
    else
    begin
      Piece[0] := Char(Character);
      Piece[1] := #0;
      PieceText := @Piece[0];
    end;
    Emit(PieceText);
  end;
  WriteText(Output, '$'#10);
end;

procedure QueueOutput(Text: PChar; IsFile: Boolean);
begin
  if QueueCount < Length(Queue) then
  begin
    Queue[QueueCount].Text := Text;
    Queue[QueueCount].IsFile := IsFile;
    Inc(QueueCount);
  end;
end;

procedure FlushQueue;
var
  Index: Integer;
  Stream: PInputStream;
  Buffer: array[0..4095] of Char;
  Count: QWord;
begin
  for Index := 0 to QueueCount - 1 do
  begin
    if not Queue[Index].IsFile then
    begin
      WriteText(Output, Queue[Index].Text);
      WriteCharacter(Output, #10);
    end
    else if PathExists(Queue[Index].Text) then
    begin
      { A missing file is silently ignored, as in GNU sed. }
      Stream := OpenInput(Queue[Index].Text);
      if Stream = nil then
        Continue;
      repeat
        Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
        WriteBytes(Output, @Buffer[0], Count);
      until Count = 0;
      CloseInput(Stream);
    end;
  end;
  QueueCount := 0;
end;

{ --- Matching addresses ---------------------------------------------- }

function RegexFor(Expression: Pointer): Pointer;
begin
  if Expression = nil then
  begin
    if LastExpression = nil then
      Fail(1, 'no previous regular expression', []);
    Exit(LastExpression);
  end;
  LastExpression := Expression;
  Result := Expression;
end;

function AddressMatches(const Address: TAddress): Boolean;
var
  Match: TMatch;
begin
  case Address.Kind of
    AddressLine: Result := LineNumber = Address.Line;
    AddressLast: Result := IsLastLine;
    AddressStep:
      if Address.Step <= 0 then
        Result := LineNumber = Address.Line
      else
        Result := (LineNumber >= Address.Line) and ((LineNumber - Address.Line) mod Address.Step = 0);
    AddressRegex: Result := SearchExpression(TExpression(RegexFor(Address.Expression)^), PatternSpace.Text, Match);
  else
    Result := True;
  end;
end;

function CommandSelects(Command: PCommand): Boolean;
begin
  if Command^.First.Kind = AddressNone then
    Result := True
  else if Command^.Second.Kind = AddressNone then
    Result := AddressMatches(Command^.First)
  else if Command^.InRange then
  begin
    { The range ends at the second address (inclusive). }
    Result := True;
    case Command^.Second.Kind of
      AddressLine, AddressRelative:
        if LineNumber >= Command^.RangeEnd then
          Command^.InRange := False;
    else
      if AddressMatches(Command^.Second) then
        Command^.InRange := False;
    end;
  end
  else if AddressMatches(Command^.First) then
  begin
    Result := True;
    Command^.InRange := True;
    case Command^.Second.Kind of
      AddressLine:
        begin
          Command^.RangeEnd := Command^.Second.Line;
          if Command^.RangeEnd <= LineNumber then
            Command^.InRange := False;
        end;
      AddressRelative:
        begin
          Command^.RangeEnd := LineNumber + Command^.Second.Line;
          if Command^.Second.Line = 0 then
            Command^.InRange := False;
        end;
      AddressLast:
        if IsLastLine then
          Command^.InRange := False;
    end;
  end
  else
    Result := False;
  if Command^.Negate then
    Result := not Result;
end;

{ --- Substitution ---------------------------------------------------- }

procedure AppendReplacement(var Builder: TTextBuilder; Replacement: PChar; Subject: PChar; const Match: TMatch);
var
  Index: PtrUInt;
  Group: Integer;
begin
  Index := 0;
  while Replacement[Index] <> #0 do
  begin
    if Replacement[Index] = '&' then
      AppendBytes(Builder, Subject + Match.Starts[0], QWord(Match.Ends[0] - Match.Starts[0]))
    else if (Replacement[Index] = '\') and (Replacement[Index + 1] <> #0) then
    begin
      Inc(Index);
      if IsDigit(Replacement[Index]) then
      begin
        Group := Ord(Replacement[Index]) - Ord('0');
        if (Group < MaximumGroups) and (Match.Starts[Group] >= 0) then
          AppendBytes(Builder, Subject + Match.Starts[Group], QWord(Match.Ends[Group] - Match.Starts[Group]));
      end
      else if Replacement[Index] = 't' then
        AppendCharacter(Builder, #9)
      else
        AppendCharacter(Builder, Replacement[Index]);
    end
    else
      AppendCharacter(Builder, Replacement[Index]);
    Inc(Index);
  end;
end;

function Substitute(Command: PCommand): Boolean;
var
  Expression: ^TExpression;
  Builder: TTextBuilder;
  Subject: PChar;
  From: PtrInt;
  Copied: PtrInt;
  Match: TMatch;
  Count: Int64;
  SubjectLength: PtrInt;
begin
  Result := False;
  Expression := RegexFor(Command^.Expression);
  Subject := DuplicateText(PatternSpace.Text);
  SubjectLength := PtrInt(TextLength(Subject));
  BeginText(Builder);
  From := 0;
  Copied := 0;
  Count := 0;
  while (From <= SubjectLength) and SearchExpressionFrom(Expression^, Subject, From, Match) do
  begin
    Inc(Count);
    if Count >= Command^.Occurrence then
    begin
      AppendBytes(Builder, Subject + Copied, QWord(Match.Starts[0] - Copied));
      AppendReplacement(Builder, Command^.Replacement, Subject, Match);
      Copied := Match.Ends[0];
      Result := True;
      if not Command^.Global then
        Break;
    end;
    { An empty match must still move on. }
    if Match.Ends[0] = Match.Starts[0] then
    begin
      if (Count >= Command^.Occurrence) and (Match.Ends[0] < SubjectLength) then
      begin
        AppendCharacter(Builder, Subject[Match.Ends[0]]);
        Copied := Match.Ends[0] + 1;
      end;
      From := Match.Ends[0] + 1;
    end
    else
      From := Match.Ends[0];
  end;
  if Result then
  begin
    if Copied < SubjectLength then
      AppendText(Builder, Subject + Copied);
    PatternSpace.Length := 0;
    PatternSpace.Text[0] := #0;
    AppendText(PatternSpace, Builder.Text);
  end;
  DiscardText(Builder);
  FreeMemory(Subject);
end;

{ --- Executing ------------------------------------------------------- }

procedure SetPatternSpace(Text: PChar);
begin
  PatternSpace.Length := 0;
  PatternSpace.Text[0] := #0;
  AppendText(PatternSpace, Text);
end;

procedure EndCycleOutput;
begin
  if not Quiet then
    WritePatternSpace(Output, False);
  FlushQueue;
end;

{ Runs the script on the pattern space. Returns False when the input
  ended inside the cycle (n or N at the last line). }
procedure RunCycle(out StartNextWithoutReading: Boolean);
var
  Counter: Integer;
  Command: PCommand;
  Line: PChar;
  Newline: PtrInt;
  Swap: TTextBuilder;
  Index: PtrUInt;
begin
  StartNextWithoutReading := False;
  Substituted := False;
  Counter := 0;
  while Counter < CommandCount do
  begin
    Command := @Commands[Counter];
    Inc(Counter);
    if Command^.Name in [':', '}'] then
      Continue;
    if not CommandSelects(Command) then
    begin
      if Command^.Name = '{' then
        Counter := Command^.JumpTarget;
      Continue;
    end;
    case Command^.Name of
      '{': ;
      '=':
        begin
          WriteDecimal(Output, LineNumber);
          WriteCharacter(Output, #10);
        end;
      'a': QueueOutput(Command^.Text, False);
      'i':
        begin
          WriteText(Output, Command^.Text);
          WriteCharacter(Output, #10);
        end;
      'c':
        begin
          { In a range, the text replaces the whole range. }
          if not Command^.InRange or Command^.Negate then
          begin
            WriteText(Output, Command^.Text);
            WriteCharacter(Output, #10);
          end;
          FlushQueue;
          Exit;
        end;
      'd':
        begin
          FlushQueue;
          Exit;
        end;
      'D':
        begin
          Newline := FindCharacter(PatternSpace.Text, #10);
          if Newline < 0 then
          begin
            FlushQueue;
            Exit;
          end;
          Line := DuplicateText(PatternSpace.Text + Newline + 1);
          SetPatternSpace(Line);
          FreeMemory(Line);
          FlushQueue;
          StartNextWithoutReading := True;
          Exit;
        end;
      'p': WritePatternSpace(Output, False);
      'P': WritePatternSpace(Output, True);
      'l': WriteUnambiguous;
      'n':
        begin
          if Quitting or IsLastLine then
          begin
            { GNU sed prints the pattern space and stops. }
            EndCycleOutput;
            Quitting := True;
            Exit;
          end;
          EndCycleOutput;
          NextLine(Line);
          SetPatternSpace(Line);
          FreeMemory(Line);
        end;
      'N':
        begin
          if IsLastLine then
          begin
            EndCycleOutput;
            Quitting := True;
            Exit;
          end;
          NextLine(Line);
          AppendCharacter(PatternSpace, #10);
          AppendText(PatternSpace, Line);
          FreeMemory(Line);
        end;
      'g': SetPatternSpace(HoldSpace.Text);
      'G':
        begin
          AppendCharacter(PatternSpace, #10);
          AppendText(PatternSpace, HoldSpace.Text);
        end;
      'h':
        begin
          HoldSpace.Length := 0;
          HoldSpace.Text[0] := #0;
          AppendText(HoldSpace, PatternSpace.Text);
        end;
      'H':
        begin
          AppendCharacter(HoldSpace, #10);
          AppendText(HoldSpace, PatternSpace.Text);
        end;
      'x':
        begin
          Swap := PatternSpace;
          PatternSpace := HoldSpace;
          HoldSpace := Swap;
        end;
      'z': SetPatternSpace('');
      's':
        if Substitute(Command) then
        begin
          Substituted := True;
          if Command^.PrintAfter then
            WritePatternSpace(Output, False);
          if Command^.WriteFile >= 0 then
            WritePatternSpace(WriteFiles[Command^.WriteFile].Stream, False);
        end;
      'y':
        for Index := 0 to PatternSpace.Length - 1 do
          PatternSpace.Text[Index] := Command^.Translation[PatternSpace.Text[Index]];
      'r': QueueOutput(Command^.Text, True);
      'w': WritePatternSpace(WriteFiles[Command^.WriteFile].Stream, False);
      'b': Counter := Command^.JumpTarget;
      't':
        if Substituted then
        begin
          Substituted := False;
          Counter := Command^.JumpTarget;
        end;
      'T':
        if not Substituted then
          Counter := Command^.JumpTarget
        else
          Substituted := False;
      'q':
        begin
          EndCycleOutput;
          Quitting := True;
          QuitCode := Command^.ExitCode;
          Exit;
        end;
      'Q':
        begin
          Quitting := True;
          QuitCode := Command^.ExitCode;
          Exit;
        end;
    end;
  end;
  EndCycleOutput;
end;

{ Processes the input files currently set up as one stream. }
procedure ProcessStream;
var
  Line: PChar;
  StartWithoutReading: Boolean;
begin
  StartWithoutReading := False;
  while not Quitting do
  begin
    if not StartWithoutReading then
    begin
      if not NextLine(Line) then
        Break;
      SetPatternSpace(Line);
      FreeMemory(Line);
    end;
    RunCycle(StartWithoutReading);
  end;
end;

procedure ResetStreamState;
var
  Index: Integer;
begin
  LineNumber := 0;
  HaveLookAhead := False;
  CurrentInput := nil;
  for Index := 0 to CommandCount - 1 do
    Commands[Index].InRange := False;
end;

{ -i: each file is edited separately, through a temporary file that then
  replaces it. }
procedure EditInPlace(Path: PChar);
var
  TemporaryPath: TTextBuilder;
  Backup: TTextBuilder;
  Handle: Int64;
  Error: LongInt;
begin
  if IsDirectory(Path) or not PathExists(Path) then
  begin
    if not PathExists(Path) then
      Report('can''t read %s: No such file or directory', [ArgumentText(Path)])
    else
      Report('couldn''t edit %s: not a regular file', [ArgumentText(Path)]);
    ExitStatus := 2;
    Exit;
  end;
  BeginText(TemporaryPath);
  AppendText(TemporaryPath, Path);
  AppendText(TemporaryPath, '.sedtmp');
  Handle := OpenFile(TemporaryPath.Text, OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    FailWithError(4, ErrorCodeOf(Handle), 'couldn''t open temporary file %s', [ArgumentText(TemporaryPath.Text)]);
  Output := CreateOutputStream(Handle);
  InputFiles := @Path;
  InputFileCount := 1;
  InputIndex := 0;
  ResetStreamState;
  ProcessStream;
  DestroyOutputStream(Output);
  CloseFile(Handle);
  Output := StandardOutput;

  if (InPlaceSuffix <> nil) and (InPlaceSuffix^ <> #0) then
  begin
    BeginText(Backup);
    AppendText(Backup, Path);
    AppendText(Backup, InPlaceSuffix);
    if PathExists(Backup.Text) then
      RemovePath(Backup.Text);
    RenamePath(Path, Backup.Text);
    DiscardText(Backup);
  end
  else
    RemovePath(Path);
  Error := RenamePath(TemporaryPath.Text, Path);
  if Error <> ErrorNone then
    ReportError(Error, 'cannot rename %s', [ArgumentText(TemporaryPath.Text)]);
  DiscardText(TemporaryPath);
end;

{ "-i" and "-iSUFFIX" share a letter with no separate value; they are
  taken out before the option parser sees them. }
procedure TakeInPlaceOptions;
var
  Index: Integer;
  Text: PChar;
begin
  for Index := 1 to ArgumentTotal - 1 do
  begin
    Text := ArgumentValues[Index];
    if TextIsEqual(Text, '--') then
      Break;
    if TextStartsWith(Text, '--in-place') then
    begin
      InPlace := True;
      if Text[10] = '=' then
        InPlaceSuffix := Text + 11;
      ArgumentValues[Index] := '--in-place-taken';
    end
    else if (Text[0] = '-') and (Text[1] = 'i') then
    begin
      InPlace := True;
      if Text[2] <> #0 then
        InPlaceSuffix := Text + 2;
      ArgumentValues[Index] := '--in-place-taken';
    end;
  end;
end;

procedure AddScriptText(Text: PChar);
begin
  if Script.Length > 0 then
    AppendCharacter(Script, #10);
  AppendText(Script, Text);
end;

procedure AddScriptFile(Path: PChar);
var
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
begin
  Stream := OpenInput(Path);
  if Stream = nil then
    Halt(1);
  while ReadLine(Stream, Line, HadLineEnd) do
  begin
    AddScriptText(Line);
    FreeMemory(Line);
  end;
  CloseInput(Stream);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  HaveScript: Boolean;
  FirstFile: Integer;
  Index: Integer;
  Standard: PChar;
begin
  Syntax := SyntaxBasic;
  LineEnd := #10;
  ExitStatus := 0;
  BeginText(Script);
  HaveScript := False;
  TakeInPlaceOptions;
  BeginOptions(Parser, [
    OptionDefinition('n', 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'silent', False, OptionQuiet),
    OptionDefinition('e', 'expression', True, OptionExpression),
    OptionDefinition('f', 'file', True, OptionScriptFile),
    OptionDefinition('E', 'regexp-extended', False, OptionExtended),
    OptionDefinition('r', nil, False, OptionExtended),
    OptionDefinition('s', 'separate', False, OptionSeparate),
    OptionDefinition('z', 'null-data', False, OptionNullData),
    OptionDefinition('u', 'unbuffered', False, OptionUnbuffered),
    OptionDefinition(#0, 'posix', False, OptionPosix),
    OptionDefinition(#0, 'in-place-taken', False, 0)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionQuiet: Quiet := True;
      OptionExpression:
        begin
          AddScriptText(Value);
          HaveScript := True;
        end;
      OptionScriptFile:
        begin
          AddScriptFile(Value);
          HaveScript := True;
        end;
      OptionExtended: Syntax := SyntaxExtended;
      OptionSeparate: Separate := True;
      OptionNullData: LineEnd := #0;
    end;
  FirstFile := 0;
  if not HaveScript then
  begin
    if Parser.OperandCount = 0 then
      FailWithUsageHint('no script specified', []);
    AddScriptText(Parser.Operands[0]);
    FirstFile := 1;
  end;
  ParseScript;

  BeginText(PatternSpace);
  BeginText(HoldSpace);
  Output := StandardOutput;
  QueueCount := 0;
  if InPlace then
  begin
    Separate := True;
    if FirstFile >= Parser.OperandCount then
      Fail(1, 'no input files', []);
    for Index := FirstFile to Parser.OperandCount - 1 do
    begin
      EditInPlace(Parser.Operands[Index]);
      if Quitting then
        Break;
    end;
  end
  else
  begin
    if FirstFile >= Parser.OperandCount then
    begin
      Standard := '-';
      InputFiles := @Standard;
      InputFileCount := 1;
    end
    else
    begin
      InputFiles := Parser.Operands + FirstFile;
      InputFileCount := Parser.OperandCount - FirstFile;
    end;
    InputIndex := 0;
    if Separate then
      while (InputIndex < InputFileCount) and not Quitting do
      begin
        ResetStreamState;
        ProcessStream;
      end
    else
    begin
      ResetStreamState;
      ProcessStream;
    end;
  end;
  for Index := 0 to WriteFileCount - 1 do
    if WriteFiles[Index].Handle >= 0 then
    begin
      DestroyOutputStream(WriteFiles[Index].Stream);
      CloseFile(WriteFiles[Index].Handle);
    end;
  if Quitting and (QuitCode <> 0) then
    Halt(QuitCode);
  Halt(ExitStatus);
end.
