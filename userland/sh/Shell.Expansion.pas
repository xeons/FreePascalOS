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

(*
  Word expansion: turning the raw text of a word into the arguments a
  command receives.

  In order, as a POSIX shell does it:

    1. tilde expansion        ~ at the start becomes $HOME
    2. parameter expansion    $NAME ${NAME} $? $$ $# $0..$9 $@ $*
                              ${#NAME} ${NAME:-word} ${NAME:=word}
                              ${NAME:+word} ${NAME:?word} (also
                              without ':', for unset only)
                              ${NAME#pattern} ${NAME##pattern}
                              ${NAME%pattern} ${NAME%%pattern}
    3. command substitution   $( command )  (its output, trailing
                              line ends removed)
    4. arithmetic expansion   $(( expression ))
    5. field splitting        unquoted results of 2-4 split at blanks
    6. pattern expansion      unquoted * ? [ match file names
    7. quote removal          '...' "..." and \ are removed

  Single quotes keep everything literal; double quotes allow 2-4 but
  prevent 5 and 6; a backslash quotes the next character.
*)
unit Shell.Expansion;

{$mode objfpc}
{$pointermath on}

interface

type
  TFieldList = record
    Items: PPChar;     { nil terminated }
    Count: Integer;
    Capacity: Integer;
  end;

procedure BeginFieldList(out Fields: TFieldList);
procedure AddField(var Fields: TFieldList; Text: PChar);
procedure FreeFieldList(var Fields: TFieldList);

{ Expands words into fields (with splitting and patterns). }
procedure ExpandWords(Words: PPChar; Count: Integer; var Fields: TFieldList);
{ Expands one word into a single string, without splitting or patterns
  (assignments and redirection targets). }
function ExpandToText(Word: PChar): PChar;
{ Expands a word into a pattern for MatchPattern: quoted characters are
  escaped, so only unquoted * ? [ match. }
function ExpandToPattern(Word: PChar): PChar;
{ Expands a here-document body like text in double quotes. }
function ExpandHereDocument(Body: PChar): PChar;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Shell.Variables,
  Shell.Functions,
  Shell.Arithmetic,
  Shell.Patterns;

type
  { The state of the word being expanded. }
  TExpander = record
    Fields: ^TFieldList;
    Splitting: Boolean;       { False for ExpandToText }
    { Current field: literal text and the same text as a pattern, in
      which quoted pattern characters are escaped. }
    Text: TTextBuilder;
    Pattern: TTextBuilder;
    HasPattern: Boolean;
    { A field exists even if empty (e.g. after ""). }
    FieldStarted: Boolean;
    { Expanding a pattern: unquoted expansion results stay patterns. }
    PatternContext: Boolean;
  end;

procedure BeginFieldList(out Fields: TFieldList);
begin
  Fields.Capacity := 8;
  Fields.Items := PPChar(AllocateZeroedMemory(QWord(Fields.Capacity + 1) * SizeOf(PChar)));
  Fields.Count := 0;
end;

procedure AddField(var Fields: TFieldList; Text: PChar);
begin
  if Fields.Count = Fields.Capacity then
  begin
    Fields.Capacity := Fields.Capacity * 2;
    Fields.Items := PPChar(ReallocateMemory(Fields.Items, QWord(Fields.Capacity + 1) * SizeOf(PChar)));
  end;
  Fields.Items[Fields.Count] := DuplicateText(Text);
  Inc(Fields.Count);
  Fields.Items[Fields.Count] := nil;
end;

procedure FreeFieldList(var Fields: TFieldList);
var
  Index: Integer;
begin
  Index := 0;
  while Index < Fields.Count do
  begin
    FreeMemory(Fields.Items[Index]);
    Inc(Index);
  end;
  FreeMemory(Fields.Items);
  Fields.Items := nil;
  Fields.Count := 0;
  Fields.Capacity := 0;
end;

{ --- Building fields ------------------------------------------------- }

procedure AddPatternMatch(Path: PChar; Context: Pointer);
begin
  AddField(TFieldList(Context^), Path);
end;

procedure FinishField(var Expander: TExpander);
begin
  if Expander.FieldStarted then
  begin
    if Expander.HasPattern and Expander.Splitting and
       (ExpandPattern(Expander.Pattern.Text, @AddPatternMatch, Expander.Fields) > 0) then
      { The matches replace the word. }
    else
      AddField(Expander.Fields^, Expander.Text.Text);
  end;
  DiscardText(Expander.Text);
  DiscardText(Expander.Pattern);
  BeginText(Expander.Text);
  BeginText(Expander.Pattern);
  Expander.HasPattern := False;
  Expander.FieldStarted := False;
end;

{ Appends a character that came from quoted text (or is literal). }
procedure AddQuoted(var Expander: TExpander; Character: Char);
begin
  AppendCharacter(Expander.Text, Character);
  if Character in ['*', '?', '[', '\'] then
    AppendCharacter(Expander.Pattern, '\');
  AppendCharacter(Expander.Pattern, Character);
  Expander.FieldStarted := True;
end;

{ Appends an unquoted character of the word itself. }
procedure AddUnquoted(var Expander: TExpander; Character: Char);
begin
  AppendCharacter(Expander.Text, Character);
  AppendCharacter(Expander.Pattern, Character);
  if Character in ['*', '?', '['] then
    Expander.HasPattern := True;
  Expander.FieldStarted := True;
end;

{ Appends the result of an expansion. Unquoted results are split at
  blanks and may contain patterns. }
procedure AddExpansionResult(var Expander: TExpander; Value: PChar; Quoted: Boolean);
var
  Index: Integer;
begin
  if Value = nil then
    Exit;
  Index := 0;
  while Value[Index] <> #0 do
  begin
    if Quoted or (not Expander.Splitting and not Expander.PatternContext) then
      AddQuoted(Expander, Value[Index])
    else if not Expander.Splitting then
      AddUnquoted(Expander, Value[Index])
    else if IsSpace(Value[Index]) then
      FinishField(Expander)
    else
      AddUnquoted(Expander, Value[Index]);
    Inc(Index);
  end;
end;

{ --- Command substitution -------------------------------------------- }

{ Runs Command in a new shell and returns its output (heap string). }
function RunCommandSubstitution(Command: PChar): PChar;
var
  ReadHandle: Int64;
  WriteHandle: Int64;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Process: Int64;
  Builder: TTextBuilder;
  Buffer: array[0..1023] of Char;
  BytesRead: Int64;
  Script: TTextBuilder;
begin
  BeginText(Builder);
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
    Exit(FinishText(Builder));
  { The child is a new shell; it gets this shell's variables, positional
    parameters and functions first, as a subshell would have them. }
  BeginText(Script);
  AppendVariableState(Script);
  AppendFunctionDefinitions(Script);
  AppendText(Script, Command);
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := Script.Text;
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteHandle;
  Process := StartProgram('/bin/sh', @Arguments[0], Options);
  DiscardText(Script);
  CloseFile(WriteHandle);
  if Process >= 0 then
  begin
    repeat
      BytesRead := ReadFile(ReadHandle, @Buffer[0], SizeOf(Buffer));
      if BytesRead > 0 then
        AppendBytes(Builder, @Buffer[0], BytesRead);
    until BytesRead <= 0;
    LastStatus := WaitForProgram(Process);
  end
  else
    LastStatus := 127;
  CloseFile(ReadHandle);

  while (Builder.Length > 0) and (Builder.Text[Builder.Length - 1] = #10) do
  begin
    Dec(Builder.Length);
    Builder.Text[Builder.Length] := #0;
  end;
  Result := FinishText(Builder);
end;

{ Finds the end of $( ... ) or $(( ... )) starting at the '(' after
  '$'. Returns the index of the matching ')'. }
function FindClosingParenthesis(Word: PChar; Start: PtrInt): PtrInt;
var
  Depth: Integer;
  Position: PtrInt;
  Quote: Char;
begin
  Depth := 0;
  Position := Start;
  while Word[Position] <> #0 do
  begin
    case Word[Position] of
      '\':
        if Word[Position + 1] <> #0 then
          Inc(Position);
      '''', '"':
        begin
          Quote := Word[Position];
          Inc(Position);
          while (Word[Position] <> #0) and (Word[Position] <> Quote) do
          begin
            if (Quote = '"') and (Word[Position] = '\') and (Word[Position + 1] <> #0) then
              Inc(Position);
            Inc(Position);
          end;
          if Word[Position] = #0 then
            Exit(-1);
        end;
      '(':
        Inc(Depth);
      ')':
        begin
          Dec(Depth);
          if Depth = 0 then
            Exit(Position);
        end;
    end;
    Inc(Position);
  end;
  Result := -1;
end;

function CopyRange(Text: PChar; Start, Finish: PtrInt): PChar;
var
  Length: PtrInt;
begin
  Length := Finish - Start;
  if Length < 0 then
    Length := 0;
  Result := PChar(AllocateMemory(Length + 1));
  CopyMemory(Result, Text + Start, Length);
  Result[Length] := #0;
end;

{ --- Parameters ------------------------------------------------------ }

{ Value may point into Buffer, so Buffer must outlive its use. }
function SpecialParameter(Name: Char; out Value: PChar; var Buffer: TNumberText): Boolean;
begin
  Result := True;
  case Name of
    '?': Value := FormatSignedDecimal(LastStatus, Buffer);
    '$': Value := FormatSignedDecimal(CurrentProcessId, Buffer);
    '!':
      if LastBackgroundProcessId > 0 then
        Value := FormatSignedDecimal(LastBackgroundProcessId, Buffer)
      else
        Value := '';
    '#': Value := FormatSignedDecimal(PositionalCount, Buffer);
    '0': Value := ScriptName;
    '1'..'9': Value := PositionalParameter(Ord(Name) - Ord('0'));
  else
    begin
      Value := nil;
      Result := False;
    end;
  end;
end;

{ Expands $@ or $*. Inside double quotes "$@" gives one field per
  parameter; everything else joins them with spaces. }
procedure ExpandAllParameters(var Expander: TExpander; AsSeparateFields: Boolean; Quoted: Boolean);
var
  Index: Integer;
begin
  for Index := 1 to PositionalCount do
  begin
    if Index > 1 then
    begin
      if AsSeparateFields and Quoted and Expander.Splitting then
      begin
        FinishField(Expander);
        Expander.FieldStarted := True;
      end
      else
        AddExpansionResult(Expander, ' ', Quoted);
    end;
    AddExpansionResult(Expander, PositionalParameter(Index), Quoted);
  end;
end;

{ --- ${...} ---------------------------------------------------------- }

function ExpandWordFlat(Word: PChar; AsPattern: Boolean): PChar; forward;

{ Finds the brace that closes the dollar-brace before Word[Start]; -1 if none.
  Nested ${...}, quotes and backslashes are skipped. }
function FindClosingBrace(Word: PChar; Start: PtrInt): PtrInt;
var
  Position: PtrInt;
  Depth: Integer;
  Quote: Char;
begin
  Depth := 1;
  Position := Start;
  while Word[Position] <> #0 do
  begin
    case Word[Position] of
      '\':
        if Word[Position + 1] <> #0 then
          Inc(Position);
      '''', '"':
        begin
          Quote := Word[Position];
          Inc(Position);
          while (Word[Position] <> #0) and (Word[Position] <> Quote) do
          begin
            if (Quote = '"') and (Word[Position] = '\') and (Word[Position + 1] <> #0) then
              Inc(Position);
            Inc(Position);
          end;
          if Word[Position] = #0 then
            Exit(-1);
        end;
      '$':
        if Word[Position + 1] = '{' then
        begin
          Inc(Depth);
          Inc(Position);
        end;
      '}':
        begin
          Dec(Depth);
          if Depth = 0 then
            Exit(Position);
        end;
    end;
    Inc(Position);
  end;
  Result := -1;
end;

{ The value of a parameter name inside braces (variable, positional or
  special); nil when unset. }
function ParameterValue(Name: PChar; var Buffer: TNumberText): PChar;
var
  Number: Int64;
begin
  if (Name[0] <> #0) and (Name[1] = #0) and SpecialParameter(Name[0], Result, Buffer) then
    Exit;
  if IsDigit(Name[0]) and ParseInteger(Name, Number) then
    Exit(PositionalParameter(Integer(Number)));
  Result := LookupVariable(Name);
end;

{ Removes the shortest or longest prefix or suffix matching Pattern. }
function RemovePattern(Value, Pattern: PChar; FromEnd, Longest: Boolean): PChar;
var
  Length: PtrInt;
  Cut: PtrInt;
  Part: PChar;
  Found: PtrInt;
begin
  Length := PtrInt(TextLength(Value));
  Found := -1;
  if not FromEnd then
  begin
    { Prefixes of length Cut. }
    if Longest then
      Cut := Length
    else
      Cut := 0;
    while (Cut >= 0) and (Cut <= Length) do
    begin
      Part := CopyRange(Value, 0, Cut);
      if MatchPattern(Pattern, Part) then
        Found := Cut;
      FreeMemory(Part);
      if Found >= 0 then
        Break;
      if Longest then
        Dec(Cut)
      else
        Inc(Cut);
    end;
    if Found < 0 then
      Exit(DuplicateText(Value));
    Exit(CopyRange(Value, Found, Length));
  end;
  { Suffixes starting at Cut. }
  if Longest then
    Cut := 0
  else
    Cut := Length;
  while (Cut >= 0) and (Cut <= Length) do
  begin
    if MatchPattern(Pattern, Value + Cut) then
    begin
      Found := Cut;
      Break;
    end;
    if Longest then
      Inc(Cut)
    else
      Dec(Cut);
  end;
  if Found < 0 then
    Exit(DuplicateText(Value));
  Result := CopyRange(Value, 0, Found);
end;

procedure ExpandBraced(var Expander: TExpander; Word: PChar; var Position: PtrInt; Quoted: Boolean);
var
  Finish: PtrInt;
  Inner: PChar;
  NameEnd: PtrInt;
  Name: PChar;
  Operation: array[0..2] of Char;
  Argument: PChar;
  Value: PChar;
  Buffer: TNumberText;
  IsUnset: Boolean;
  IsEmpty: Boolean;
  UseColon: Boolean;
  Expanded: PChar;
  Pattern: PChar;
  Result: PChar;
  Message: PChar;
begin
  Finish := FindClosingBrace(Word, Position + 1);
  if Finish < 0 then
  begin
    AddQuoted(Expander, '$');
    Exit;
  end;
  Inner := CopyRange(Word, Position + 1, Finish);
  Position := Finish + 1;

  { ${#NAME}: the length. }
  if (Inner[0] = '#') and (Inner[1] <> #0) then
  begin
    Value := ParameterValue(Inner + 1, Buffer);
    if Value = nil then
      Value := '';
    AddExpansionResult(Expander, FormatDecimal(TextLength(Value), Buffer), Quoted);
    FreeMemory(Inner);
    Exit;
  end;

  { The name: letters, digits and _, or one special character. }
  NameEnd := 0;
  if IsLetter(Inner[0]) or (Inner[0] = '_') then
    while IsAlphanumeric(Inner[NameEnd]) or (Inner[NameEnd] = '_') do
      Inc(NameEnd)
  else if IsDigit(Inner[0]) then
    while IsDigit(Inner[NameEnd]) do
      Inc(NameEnd)
  else if Inner[0] in ['?', '$', '#', '@', '*', '!', '-'] then
    NameEnd := 1;
  if NameEnd = 0 then
  begin
    WriteText(StandardError, 'sh: ${');
    WriteText(StandardError, Inner);
    WriteLine(StandardError, '}: bad substitution');
    ExpansionFailed := True;
    FreeMemory(Inner);
    Exit;
  end;
  Name := CopyRange(Inner, 0, NameEnd);

  { The operation after the name, and its word. }
  Operation[0] := #0;
  Operation[1] := #0;
  Operation[2] := #0;
  Argument := Inner + NameEnd;
  UseColon := Argument^ = ':';
  if UseColon then
    Inc(Argument);
  if Argument^ in ['-', '=', '+', '?'] then
  begin
    Operation[0] := Argument^;
    Inc(Argument);
  end
  else if (Argument^ in ['#', '%']) and not UseColon then
  begin
    Operation[0] := Argument^;
    Inc(Argument);
    if Argument^ = Operation[0] then
    begin
      Operation[1] := Argument^;
      Inc(Argument);
    end;
  end
  else if Argument^ <> #0 then
  begin
    WriteText(StandardError, 'sh: ${');
    WriteText(StandardError, Inner);
    WriteLine(StandardError, '}: bad substitution');
    ExpansionFailed := True;
    FreeMemory(Name);
    FreeMemory(Inner);
    Exit;
  end;

  Value := ParameterValue(Name, Buffer);
  IsUnset := Value = nil;
  IsEmpty := IsUnset or (Value^ = #0);

  case Operation[0] of
    #0:
      AddExpansionResult(Expander, Value, Quoted);
    '-':
      if (UseColon and IsEmpty) or (not UseColon and IsUnset) then
      begin
        Expanded := ExpandWordFlat(Argument, False);
        AddExpansionResult(Expander, Expanded, Quoted);
        FreeMemory(Expanded);
      end
      else
        AddExpansionResult(Expander, Value, Quoted);
    '=':
      if (UseColon and IsEmpty) or (not UseColon and IsUnset) then
      begin
        Expanded := ExpandWordFlat(Argument, False);
        AssignVariable(Name, Expanded);
        AddExpansionResult(Expander, Expanded, Quoted);
        FreeMemory(Expanded);
      end
      else
        AddExpansionResult(Expander, Value, Quoted);
    '+':
      if not ((UseColon and IsEmpty) or (not UseColon and IsUnset)) then
      begin
        Expanded := ExpandWordFlat(Argument, False);
        AddExpansionResult(Expander, Expanded, Quoted);
        FreeMemory(Expanded);
      end;
    '?':
      if (UseColon and IsEmpty) or (not UseColon and IsUnset) then
      begin
        if Argument^ <> #0 then
          Message := ExpandWordFlat(Argument, False)
        else
          Message := DuplicateText('parameter null or not set');
        WriteText(StandardError, 'sh: ');
        WriteText(StandardError, Name);
        WriteText(StandardError, ': ');
        WriteLine(StandardError, Message);
        FreeMemory(Message);
        ExpansionFailed := True;
      end
      else
        AddExpansionResult(Expander, Value, Quoted);
    '#', '%':
      begin
        if Value = nil then
          Value := '';
        Pattern := ExpandWordFlat(Argument, True);
        Result := RemovePattern(Value, Pattern, Operation[0] = '%', Operation[1] <> #0);
        AddExpansionResult(Expander, Result, Quoted);
        FreeMemory(Result);
        FreeMemory(Pattern);
      end;
  end;
  FreeMemory(Name);
  FreeMemory(Inner);
end;

{ Expands the "$..." at Word[Position]; Position ends after it. }
procedure ExpandDollar(var Expander: TExpander; Word: PChar; var Position: PtrInt; Quoted: Boolean);
var
  Start: PtrInt;
  Finish: PtrInt;
  Name: PChar;
  Value: PChar;
  Buffer: TNumberText;
  Inner: PChar;
  Output: PChar;
  Number: Int64;
  NumberText: TNumberText;
begin
  Inc(Position); { the '$' }

  if Word[Position] = '(' then
  begin
    Finish := FindClosingParenthesis(Word, Position);
    if Finish < 0 then
    begin
      AddQuoted(Expander, '$');
      Exit;
    end;
    if (Word[Position + 1] = '(') and (Finish > Position + 1) and (Word[Finish - 1] = ')') then
    begin
      Inner := CopyRange(Word, Position + 2, Finish - 1);
      { $1, ${...} and $( ) inside the expression are expanded first. }
      Output := ExpandToText(Inner);
      if not EvaluateArithmetic(Output, Number) then
        Number := 0;
      FreeMemory(Output);
      FreeMemory(Inner);
      AddExpansionResult(Expander, FormatSignedDecimal(Number, NumberText), Quoted);
    end
    else
    begin
      Inner := CopyRange(Word, Position + 1, Finish);
      Output := RunCommandSubstitution(Inner);
      FreeMemory(Inner);
      AddExpansionResult(Expander, Output, Quoted);
      FreeMemory(Output);
    end;
    Position := Finish + 1;
    Exit;
  end;

  if Word[Position] = '{' then
  begin
    ExpandBraced(Expander, Word, Position, Quoted);
    Exit;
  end;

  if (Word[Position] = '@') or (Word[Position] = '*') then
  begin
    ExpandAllParameters(Expander, Word[Position] = '@', Quoted);
    Inc(Position);
    Exit;
  end;

  if SpecialParameter(Word[Position], Value, Buffer) then
  begin
    AddExpansionResult(Expander, Value, Quoted);
    Inc(Position);
    Exit;
  end;

  Start := Position;
  while IsAlphanumeric(Word[Position]) or (Word[Position] = '_') do
    Inc(Position);
  if Position = Start then
  begin
    { A lone '$' is literal. }
    AddQuoted(Expander, '$');
    Exit;
  end;
  Name := CopyRange(Word, Start, Position);
  AddExpansionResult(Expander, LookupVariable(Name), Quoted);
  FreeMemory(Name);
end;

{ --- The word -------------------------------------------------------- }

procedure ExpandWordInto(var Expander: TExpander; Word: PChar);
var
  Position: PtrInt;
  Home: PChar;
begin
  Position := 0;

  if (Word[0] = '~') and ((Word[1] = '/') or (Word[1] = #0)) then
  begin
    Home := LookupVariable('HOME');
    if Home = nil then
      Home := '/';
    AddExpansionResult(Expander, Home, True);
    Position := 1;
  end;

  while Word[Position] <> #0 do
  begin
    case Word[Position] of
      '''':
        begin
          Inc(Position);
          Expander.FieldStarted := True;
          while (Word[Position] <> '''') and (Word[Position] <> #0) do
          begin
            AddQuoted(Expander, Word[Position]);
            Inc(Position);
          end;
          if Word[Position] = '''' then
            Inc(Position);
        end;
      '"':
        begin
          Inc(Position);
          Expander.FieldStarted := True;
          while (Word[Position] <> '"') and (Word[Position] <> #0) do
          begin
            if (Word[Position] = '\') and (Word[Position + 1] in ['$', '`', '"', '\', #10]) then
            begin
              AddQuoted(Expander, Word[Position + 1]);
              Inc(Position, 2);
            end
            else if Word[Position] = '$' then
              ExpandDollar(Expander, Word, Position, True)
            else
            begin
              AddQuoted(Expander, Word[Position]);
              Inc(Position);
            end;
          end;
          if Word[Position] = '"' then
            Inc(Position);
        end;
      '\':
        begin
          if Word[Position + 1] <> #0 then
            Inc(Position);
          AddQuoted(Expander, Word[Position]);
          Inc(Position);
        end;
      '$':
        ExpandDollar(Expander, Word, Position, False);
    else
      begin
        AddUnquoted(Expander, Word[Position]);
        Inc(Position);
      end;
    end;
  end;
end;

procedure ExpandWords(Words: PPChar; Count: Integer; var Fields: TFieldList);
var
  Expander: TExpander;
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
  begin
    Expander.Fields := @Fields;
    Expander.Splitting := True;
    Expander.PatternContext := False;
    BeginText(Expander.Text);
    BeginText(Expander.Pattern);
    Expander.HasPattern := False;
    Expander.FieldStarted := False;
    ExpandWordInto(Expander, Words[Index]);
    FinishField(Expander);
    DiscardText(Expander.Text);
    DiscardText(Expander.Pattern);
  end;
end;

function ExpandWordFlat(Word: PChar; AsPattern: Boolean): PChar;
var
  Expander: TExpander;
begin
  Expander.Fields := nil;
  Expander.Splitting := False;
  Expander.PatternContext := AsPattern;
  BeginText(Expander.Text);
  BeginText(Expander.Pattern);
  Expander.HasPattern := False;
  Expander.FieldStarted := False;
  ExpandWordInto(Expander, Word);
  if AsPattern then
  begin
    Result := FinishText(Expander.Pattern);
    DiscardText(Expander.Text);
  end
  else
  begin
    Result := FinishText(Expander.Text);
    DiscardText(Expander.Pattern);
  end;
end;

function ExpandToText(Word: PChar): PChar;
begin
  Result := ExpandWordFlat(Word, False);
end;

function ExpandToPattern(Word: PChar): PChar;
begin
  Result := ExpandWordFlat(Word, True);
end;

function ExpandHereDocument(Body: PChar): PChar;
var
  Expander: TExpander;
  Position: PtrInt;
begin
  Expander.Fields := nil;
  Expander.Splitting := False;
  Expander.PatternContext := False;
  BeginText(Expander.Text);
  BeginText(Expander.Pattern);
  Expander.HasPattern := False;
  Expander.FieldStarted := False;
  Position := 0;
  while Body[Position] <> #0 do
  begin
    if (Body[Position] = '\') and (Body[Position + 1] in ['$', '`', '\']) then
    begin
      AddQuoted(Expander, Body[Position + 1]);
      Inc(Position, 2);
    end
    else if (Body[Position] = '\') and (Body[Position + 1] = #10) then
      Inc(Position, 2)
    else if Body[Position] = '$' then
      ExpandDollar(Expander, Body, Position, True)
    else
    begin
      AddQuoted(Expander, Body[Position]);
      Inc(Position);
    end;
  end;
  Result := FinishText(Expander.Text);
  DiscardText(Expander.Pattern);
end;

end.
