(*
  Word expansion: turning the raw text of a word into the arguments a
  command receives.

  In order, as a POSIX shell does it:

    1. tilde expansion        ~ at the start becomes $HOME
    2. parameter expansion    $NAME ${NAME} $? $$ $# $0..$9 $@ $*
                              ${NAME:-default}
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

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Processes,
  Sys.Text,
  Shell.Variables,
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
    if Quoted or not Expander.Splitting then
      AddQuoted(Expander, Value[Index])
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
begin
  BeginText(Builder);
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
    Exit(FinishText(Builder));
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := Command;
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.OutputHandle := WriteHandle;
  Process := StartProgram('/bin/sh', @Arguments[0], Options);
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
  DefaultPosition: PtrInt;
  DefaultText: PChar;
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
      if not EvaluateArithmetic(Inner, Number) then
        Number := 0;
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
    Start := Position + 1;
    Finish := Start;
    while (Word[Finish] <> '}') and (Word[Finish] <> #0) do
      Inc(Finish);
    if Word[Finish] = #0 then
    begin
      AddQuoted(Expander, '$');
      Exit;
    end;
    Name := CopyRange(Word, Start, Finish);
    Position := Finish + 1;
    (* ${NAME:-default} *)
    DefaultText := nil;
    DefaultPosition := FindText(Name, ':-');
    if DefaultPosition > 0 then
    begin
      DefaultText := Name + DefaultPosition + 2;
      Name[DefaultPosition] := #0;
    end;
    if (Name[0] <> #0) and (Name[1] = #0) and SpecialParameter(Name[0], Value, Buffer) then
      { a special parameter in braces }
    else
      Value := LookupVariable(Name);
    if ((Value = nil) or (Value^ = #0)) and (DefaultText <> nil) then
    begin
      Output := ExpandToText(DefaultText);
      AddExpansionResult(Expander, Output, Quoted);
      FreeMemory(Output);
    end
    else
      AddExpansionResult(Expander, Value, Quoted);
    FreeMemory(Name);
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

function ExpandToText(Word: PChar): PChar;
var
  Expander: TExpander;
begin
  Expander.Fields := nil;
  Expander.Splitting := False;
  BeginText(Expander.Text);
  BeginText(Expander.Pattern);
  Expander.HasPattern := False;
  Expander.FieldStarted := False;
  ExpandWordInto(Expander, Word);
  Result := FinishText(Expander.Text);
  DiscardText(Expander.Pattern);
end;

end.
