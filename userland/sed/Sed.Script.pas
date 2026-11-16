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
  A sed script: its commands, parsed from the script text, and the
  files its w commands and s///w flags write to.

  Parsing follows GNU sed: addresses (N, $, /RE/, \cREc, FIRST~STEP,
  ADDR1,+N), "!" to negate, blocks of commands in braces, and the
  commands listed in sed.pas. Errors end the program with GNU sed's
  messages, which give the position in the script as "char N".
}
unit Sed.Script;

{$mode objfpc}
{$H+}

interface

uses
  Sys.Streams,
  Util.RegularExpressions;

type
  PExpression = ^TExpression;

  TAddressKind = (AddressNone, AddressLine, AddressLast, AddressRegex, AddressStep, AddressRelative);

  TAddress = record
    Kind: TAddressKind;
    Line: Int64;
    Step: Int64;
    Expression: PExpression;  { nil = the last regex used }
  end;

  TWriteFile = record
    Path: string;
    { -1 for standard output, which is not closed. }
    Handle: Int64;
    Stream: POutputStream;
  end;

  PCommand = ^TCommand;
  TCommand = record
    First: TAddress;
    Second: TAddress;
    Negate: Boolean;
    Name: Char;
    Text: string;             { a i c text, label, file name }
    Expression: PExpression;  { s: nil = last regex }
    Replacement: string;
    Global: Boolean;
    Occurrence: Int64;
    PrintAfter: Boolean;
    WriteFile: Integer;       { index, -1 = none }
    ExitCode: LongInt;
    Translation: array[Char] of Char;
    { For a block's opening brace: the index after the closing one. For
      b t T: the target. }
    JumpTarget: Integer;
    { Range state. }
    InRange: Boolean;
    RangeEnd: Int64;
  end;

  TScript = class
  private
    FSyntax: TExpressionSyntax;
    FText: string;
    { The index into FText (from 0) of the character being parsed. }
    FPosition: Integer;
    procedure ScriptError(const Message: string);
    function CharacterAt(Index: Integer): Char;
    function Current: Char;
    procedure SkipBlanks;
    procedure SkipBlanksAndSeparators;
    procedure SkipComment;
    function ReadDelimited(Delimiter: Char): string;
    function CompileRegex(const Text: string; IgnoreCase: Boolean): PExpression;
    function ParseNumber: Int64;
    function ParseAddress(out Address: TAddress; IsSecond: Boolean): Boolean;
    function ParseText: string;
    function ParseWord(StopAtSemicolon: Boolean): string;
    function OpenWriteFile(const Path: string): Integer;
    procedure ParseSubstitution(var Command: TCommand);
    procedure ParseTransliteration(var Command: TCommand);
    procedure ParseAddresses(var Command: TCommand);
    procedure ParseArguments(var Command: TCommand);
    procedure ResolveBranchTargets;
  public
    Commands: array of TCommand;
    WriteFiles: array of TWriteFile;
    { Closes the write files. }
    destructor Destroy; override;
    { Adds a piece of script (-e, a line of -f, or the script operand);
      pieces are joined by line ends. }
    procedure AddText(const Text: string);
    procedure Parse(Syntax: TExpressionSyntax);
    procedure ResetRanges;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Util.Messages;

destructor TScript.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(WriteFiles) do
    if WriteFiles[Index].Handle >= 0 then
    begin
      DestroyOutputStream(WriteFiles[Index].Stream);
      CloseFile(WriteFiles[Index].Handle);
    end;
  inherited Destroy;
end;

procedure TScript.AddText(const Text: string);
begin
  if FText <> '' then
    FText := FText + #10;
  FText := FText + Text;
end;

procedure TScript.ResetRanges;
var
  Index: Integer;
begin
  for Index := 0 to High(Commands) do
    Commands[Index].InRange := False;
end;

procedure TScript.ScriptError(const Message: string);
begin
  Fail(1, '-e expression #1, char %d: %s', [ArgumentNumber(FPosition), ArgumentText(PChar(Message))]);
end;

{ #0 past the end of the script, like the end of a C string. }
function TScript.CharacterAt(Index: Integer): Char;
begin
  if (Index >= 0) and (Index < Length(FText)) then
    Result := FText[Index + 1]
  else
    Result := #0;
end;

function TScript.Current: Char;
begin
  Result := CharacterAt(FPosition);
end;

procedure TScript.SkipBlanks;
begin
  while Current in [' ', #9] do
    Inc(FPosition);
end;

procedure TScript.SkipBlanksAndSeparators;
begin
  while Current in [' ', #9, #10, ';'] do
    Inc(FPosition);
end;

procedure TScript.SkipComment;
begin
  while not (Current in [#0, #10]) do
    Inc(FPosition);
end;

{ Reads text up to Delimiter (not escaped by '\'), turning "\n" into a
  line end and "\Delimiter" into the delimiter; other escapes are kept
  for the regex or replacement parser. }
function TScript.ReadDelimited(Delimiter: Char): string;
begin
  Result := '';
  while Current <> Delimiter do
  begin
    if Current = #0 then
      ScriptError('unterminated `s'' command');
    if (Current = '\') and (CharacterAt(FPosition + 1) <> #0) then
    begin
      Inc(FPosition);
      if Current = Delimiter then
        Result := Result + Delimiter
      else if Current = 'n' then
        Result := Result + #10
      else
        Result := Result + '\' + Current;
      Inc(FPosition);
      Continue;
    end;
    Result := Result + Current;
    Inc(FPosition);
  end;
  Inc(FPosition);
end;

function TScript.CompileRegex(const Text: string; IgnoreCase: Boolean): PExpression;
var
  ErrorMessage: PChar;
begin
  if Text = '' then
    Exit(nil); { the last regex }
  New(Result);
  FillChar(Result^, SizeOf(TExpression), 0);
  if not CompileExpression(PChar(Text), FSyntax, Result^, ErrorMessage) then
    ScriptError(ErrorMessage);
  Result^.IgnoreCase := IgnoreCase;
end;

function TScript.ParseNumber: Int64;
begin
  Result := 0;
  while Current in ['0'..'9'] do
  begin
    Result := Result * 10 + Ord(Current) - Ord('0');
    Inc(FPosition);
  end;
end;

function TScript.ParseAddress(out Address: TAddress; IsSecond: Boolean): Boolean;
var
  Delimiter: Char;
  Text: string;
begin
  Address.Kind := AddressNone;
  Address.Expression := nil;
  Result := True;
  if Current in ['0'..'9'] then
  begin
    Address.Kind := AddressLine;
    Address.Line := ParseNumber;
    if Current = '~' then
    begin
      Inc(FPosition);
      Address.Kind := AddressStep;
      Address.Step := ParseNumber;
    end;
  end
  else if IsSecond and (Current = '+') and (CharacterAt(FPosition + 1) in ['0'..'9']) then
  begin
    Inc(FPosition);
    Address.Kind := AddressRelative;
    Address.Line := ParseNumber;
  end
  else if Current = '$' then
  begin
    Address.Kind := AddressLast;
    Inc(FPosition);
  end
  else if Current in ['/', '\'] then
  begin
    if Current = '\' then
      Inc(FPosition);
    Delimiter := Current;
    Inc(FPosition);
    Text := ReadDelimited(Delimiter);
    Address.Kind := AddressRegex;
    if Current = 'I' then
    begin
      Inc(FPosition);
      Address.Expression := CompileRegex(Text, True);
    end
    else
      Address.Expression := CompileRegex(Text, False);
  end
  else
    Result := False;
end;

{ Text for a, i and c: "a text" or "a\" followed by lines; a line
  ending in a backslash continues. }
function TScript.ParseText: string;
begin
  SkipBlanks;
  if Current = '\' then
  begin
    Inc(FPosition);
    SkipBlanks;
    if Current = #10 then
      Inc(FPosition);
  end;
  Result := '';
  while not (Current in [#0, #10]) do
  begin
    if Current = '\' then
    begin
      Inc(FPosition);
      if Current = #0 then
        Break;
    end;
    Result := Result + Current;
    Inc(FPosition);
  end;
end;

{ A label or file name: the rest of the line (labels also end at ';'),
  without the blanks after it. }
function TScript.ParseWord(StopAtSemicolon: Boolean): string;
var
  Start: Integer;
  Finish: Integer;
begin
  SkipBlanks;
  Start := FPosition;
  while not (Current in [#0, #10]) and not (StopAtSemicolon and (Current = ';')) do
    Inc(FPosition);
  Finish := FPosition;
  while (Finish > Start) and (CharacterAt(Finish - 1) in [' ', #9]) do
    Dec(Finish);
  Result := Copy(FText, Start + 1, Finish - Start);
end;

function TScript.OpenWriteFile(const Path: string): Integer;
var
  Index: Integer;
  WriteFile: TWriteFile;
begin
  for Index := 0 to High(WriteFiles) do
    if WriteFiles[Index].Path = Path then
      Exit(Index);
  WriteFile.Path := Path;
  if Path = '/dev/stdout' then
  begin
    WriteFile.Handle := -1;
    WriteFile.Stream := StandardOutput;
  end
  else
  begin
    WriteFile.Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
    if WriteFile.Handle < 0 then
      FailWithError(4, ErrorCodeOf(WriteFile.Handle), 'couldn''t open file %s', [ArgumentText(PChar(Path))]);
    WriteFile.Stream := CreateOutputStream(WriteFile.Handle);
  end;
  Result := Length(WriteFiles);
  Insert(WriteFile, WriteFiles, Result);
end;

procedure TScript.ParseSubstitution(var Command: TCommand);
var
  Delimiter: Char;
  RegexText: string;
  IgnoreCase: Boolean;
begin
  Delimiter := Current;
  if Delimiter in [#0, #10, '\'] then
    ScriptError('unterminated `s'' command');
  Inc(FPosition);
  RegexText := ReadDelimited(Delimiter);
  Command.Replacement := ReadDelimited(Delimiter);
  Command.Global := False;
  Command.Occurrence := 1;
  Command.WriteFile := -1;
  IgnoreCase := False;
  repeat
    case Current of
      'g':
        begin
          Command.Global := True;
          Inc(FPosition);
        end;
      'p':
        begin
          Command.PrintAfter := True;
          Inc(FPosition);
        end;
      'i', 'I':
        begin
          IgnoreCase := True;
          Inc(FPosition);
        end;
      '0'..'9': Command.Occurrence := ParseNumber;
      'w':
        begin
          Inc(FPosition);
          Command.WriteFile := OpenWriteFile(ParseWord(False));
          Break;
        end;
    else
      Break;
    end;
  until False;
  if Command.Occurrence < 1 then
    ScriptError('number option to `s'' command may not be zero');
  Command.Expression := CompileRegex(RegexText, IgnoreCase);
end;

procedure TScript.ParseTransliteration(var Command: TCommand);
var
  Delimiter: Char;
  Source: string;
  Destination: string;
  Character: Char;
  Index: Integer;
begin
  Delimiter := Current;
  Inc(FPosition);
  Source := ReadDelimited(Delimiter);
  Destination := ReadDelimited(Delimiter);
  if Length(Source) <> Length(Destination) then
    ScriptError('strings for `y'' command are different lengths');
  for Character := #0 to #255 do
    Command.Translation[Character] := Character;
  for Index := 1 to Length(Source) do
    Command.Translation[Source[Index]] := Destination[Index];
end;

procedure TScript.ParseAddresses(var Command: TCommand);
begin
  if ParseAddress(Command.First, False) then
  begin
    SkipBlanks;
    if Current = ',' then
    begin
      Inc(FPosition);
      SkipBlanks;
      if not ParseAddress(Command.Second, True) then
        ScriptError('unexpected `,''');
    end;
  end;
  SkipBlanks;
  while Current = '!' do
  begin
    Command.Negate := True;
    Inc(FPosition);
    SkipBlanks;
  end;
end;

{ Everything after the command letter. }
procedure TScript.ParseArguments(var Command: TCommand);
begin
  case Command.Name of
    's': ParseSubstitution(Command);
    'y': ParseTransliteration(Command);
    'a', 'i', 'c': Command.Text := ParseText;
    ':':
      begin
        Command.Text := ParseWord(True);
        if Command.Text = '' then
          ScriptError('":" lacks a label');
      end;
    'b', 't', 'T': Command.Text := ParseWord(True);
    'r': Command.Text := ParseWord(False);
    'w': Command.WriteFile := OpenWriteFile(ParseWord(False));
    'q', 'Q':
      begin
        SkipBlanks;
        Command.ExitCode := LongInt(ParseNumber);
      end;
    '{', '}', 'p', 'P', 'd', 'D', 'n', 'N', 'g', 'G', 'h', 'H', 'x', '=', 'l', 'z':
      ;
  else
    Fail(1, '-e expression #1, char %d: unknown command: `%c''', [ArgumentNumber(FPosition),
      ArgumentCharacter(Command.Name)]);
  end;
end;

procedure TScript.Parse(Syntax: TExpressionSyntax);
var
  { The blocks not closed yet (the indexes of their opening braces),
    innermost last. }
  OpenBlocks: array of Integer;
  CommandIndex: Integer;
  Command: TCommand;
begin
  FSyntax := Syntax;
  FPosition := 0;
  Commands := nil;
  OpenBlocks := nil;
  repeat
    SkipBlanksAndSeparators;
    if Current = #0 then
      Break;
    if Current = '#' then
    begin
      SkipComment;
      Continue;
    end;
    Command := Default(TCommand);
    Command.WriteFile := -1;
    Command.JumpTarget := -1;
    ParseAddresses(Command);
    Command.Name := Current;
    if Current = #0 then
      ScriptError('missing command');
    Inc(FPosition);
    CommandIndex := Length(Commands);
    if Command.Name = '{' then
      Insert(CommandIndex, OpenBlocks, Length(OpenBlocks))
    else if Command.Name = '}' then
    begin
      if Length(OpenBlocks) = 0 then
        ScriptError('unexpected `}''');
      Commands[OpenBlocks[High(OpenBlocks)]].JumpTarget := CommandIndex + 1;
      SetLength(OpenBlocks, Length(OpenBlocks) - 1);
    end;
    ParseArguments(Command);
    Insert(Command, Commands, CommandIndex);
  until False;
  if Length(OpenBlocks) > 0 then
    ScriptError('unmatched `{''');
  ResolveBranchTargets;
end;

{ An empty label means the end of the script. }
procedure TScript.ResolveBranchTargets;
var
  Index: Integer;
  Target: Integer;
begin
  for Index := 0 to High(Commands) do
    if Commands[Index].Name in ['b', 't', 'T'] then
    begin
      if Commands[Index].Text = '' then
        Commands[Index].JumpTarget := Length(Commands)
      else
      begin
        Commands[Index].JumpTarget := -1;
        for Target := 0 to High(Commands) do
          if (Commands[Target].Name = ':') and (Commands[Target].Text = Commands[Index].Text) then
            Commands[Index].JumpTarget := Target;
        if Commands[Index].JumpTarget < 0 then
          Fail(1, '-e expression #1, char 0: can''t find label for jump to `%s''',
            [ArgumentText(PChar(Commands[Index].Text))]);
      end;
    end;
end;

end.
