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
                              (Shell.Parameters)
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
{$H+}

interface

uses
  SysUtils,
  Classes,
  Shell.Text;

type
  { The state of the word being expanded. }
  TWordExpander = class
  private
    { Where finished fields go; nil when the word becomes one text. }
    FFields: TStrings;
    FSplitting: Boolean;
    { Expanding a pattern: unquoted expansion results stay patterns. }
    FPatternContext: Boolean;
    { The current field: literal text and the same text as a pattern, in
      which quoted pattern characters are escaped. }
    FText: TTextBuffer;
    FPattern: TTextBuffer;
    FHasPattern: Boolean;
    { A field exists even if empty (e.g. after ""). }
    FFieldStarted: Boolean;
    { "$@" expanded to nothing (no positional parameters): quotes holding
      only that make no field, as "$@" makes none. }
    FNoParametersInQuotes: Boolean;
    procedure ExpandSingleQuoted(const Word: string; var Position: Integer);
    procedure ExpandDoubleQuoted(const Word: string; var Position: Integer);
    procedure ExpandParenthesized(const Word: string; var Position: Integer; Quoted: Boolean);
    procedure ExpandAllParameters(AsSeparateFields, Quoted: Boolean);
  public
    constructor Create(Fields: TStrings; Splitting, PatternContext: Boolean);
    { Ends the current field: adds it (or the file names its pattern
      matches) to the fields. }
    procedure FinishField;
    { A character that came from quoted text (or is literal). }
    procedure AddQuoted(Character: Char);
    { An unquoted character of the word itself. }
    procedure AddUnquoted(Character: Char);
    { The result of an expansion. Unquoted results are split at blanks
      and may contain patterns. }
    procedure AddExpansionResult(const Value: string; Quoted: Boolean);
    { The "$..." at Word[Position]; Position ends after it. }
    procedure ExpandDollar(const Word: string; var Position: Integer; Quoted: Boolean);
    procedure ExpandWord(const Word: string);
    procedure ExpandHereDocumentBody(const Body: string);
    procedure MarkFieldStarted;
    function Text: string;
    function Pattern: string;
  end;

{ Expands words into fields (with splitting and patterns). }
procedure ExpandWords(const Words: TStringArray; Fields: TStrings);
{ Expands one word into a single string, without splitting or patterns
  (assignments and redirection targets). }
function ExpandToText(const Word: string): string;
{ Expands a word into a pattern for MatchPattern: quoted characters are
  escaped, so only unquoted * ? [ match. }
function ExpandToPattern(const Word: string): string;
{ Expands a here-document body like text in double quotes. }
function ExpandHereDocument(const Body: string): string;

{ Finds the parenthesis that closes the one at Word[Start], skipping
  quotes and backslashes; 0 if there is none. }
function FindClosingParenthesis(const Word: string; Start: Integer): Integer;

implementation

uses
  Sys.Text,
  Shell.Variables,
  Shell.Arithmetic,
  Shell.Patterns,
  Shell.Parameters,
  Shell.Substitution;

{ Skips the quoted text whose opening quote is at Word[Position]; then
  Position is at the closing quote. False if it is not closed. }
function SkipQuotedText(const Word: string; var Position: Integer): Boolean;
var
  Quote: Char;
begin
  Quote := Word[Position];
  Inc(Position);
  while not (CharAt(Word, Position) in [Quote, #0]) do
  begin
    if (Quote = '"') and (Word[Position] = '\') and (CharAt(Word, Position + 1) <> #0) then
      Inc(Position);
    Inc(Position);
  end;
  Result := CharAt(Word, Position) <> #0;
end;

function FindClosingParenthesis(const Word: string; Start: Integer): Integer;
var
  Depth: Integer;
  Position: Integer;
begin
  Depth := 0;
  Position := Start;
  while Position <= Length(Word) do
  begin
    case Word[Position] of
      '\':
        if Position < Length(Word) then
          Inc(Position);
      '''', '"':
        if not SkipQuotedText(Word, Position) then
          Exit(0);
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
  Result := 0;
end;

{ --- TWordExpander ----------------------------------------------------- }

constructor TWordExpander.Create(Fields: TStrings; Splitting, PatternContext: Boolean);
begin
  inherited Create;
  FFields := Fields;
  FSplitting := Splitting;
  FPatternContext := PatternContext;
  FText.Clear;
  FPattern.Clear;
end;

function TWordExpander.Text: string;
begin
  Result := FText.Value;
end;

function TWordExpander.Pattern: string;
begin
  Result := FPattern.Value;
end;

procedure TWordExpander.MarkFieldStarted;
begin
  FFieldStarted := True;
end;

procedure TWordExpander.FinishField;
begin
  if FFieldStarted then
  begin
    if FHasPattern and FSplitting and (ExpandPattern(FPattern.Value, FFields) > 0) then
      { The matches replace the word. }
    else
      FFields.Add(FText.Value);
  end;
  FText.Clear;
  FPattern.Clear;
  FHasPattern := False;
  FFieldStarted := False;
end;

procedure TWordExpander.AddQuoted(Character: Char);
begin
  FText.Append(Character);
  if Character in ['*', '?', '[', '\'] then
    FPattern.Append('\');
  FPattern.Append(Character);
  FFieldStarted := True;
end;

procedure TWordExpander.AddUnquoted(Character: Char);
begin
  FText.Append(Character);
  FPattern.Append(Character);
  if Character in ['*', '?', '['] then
    FHasPattern := True;
  FFieldStarted := True;
end;

procedure TWordExpander.AddExpansionResult(const Value: string; Quoted: Boolean);
var
  Index: Integer;
begin
  for Index := 1 to Length(Value) do
  begin
    if Quoted or (not FSplitting and not FPatternContext) then
      AddQuoted(Value[Index])
    else if not FSplitting then
      AddUnquoted(Value[Index])
    else if IsSpace(Value[Index]) then
      FinishField
    else
      AddUnquoted(Value[Index]);
  end;
end;

{ $@ or $*. Inside double quotes "$@" gives one field per parameter;
  everything else joins them with spaces. }
procedure TWordExpander.ExpandAllParameters(AsSeparateFields, Quoted: Boolean);
var
  Index: Integer;
begin
  if AsSeparateFields and Quoted and (PositionalCount = 0) then
    FNoParametersInQuotes := True;
  for Index := 1 to PositionalCount do
  begin
    if Index > 1 then
    begin
      if AsSeparateFields and Quoted and FSplitting then
      begin
        FinishField;
        FFieldStarted := True;
      end
      else
        AddExpansionResult(' ', Quoted);
    end;
    AddExpansionResult(PositionalParameter(Index), Quoted);
  end;
end;

{ $( command ) or $(( expression )); Position is at the '(' and ends
  after the closing parenthesis. }
procedure TWordExpander.ExpandParenthesized(const Word: string; var Position: Integer; Quoted: Boolean);
var
  Finish: Integer;
  Expression: string;
  Number: Int64;
begin
  Finish := FindClosingParenthesis(Word, Position);
  if Finish = 0 then
  begin
    AddQuoted('$');
    Exit;
  end;
  if (CharAt(Word, Position + 1) = '(') and (Finish > Position + 1) and (CharAt(Word, Finish - 1) = ')') then
  begin
    (* $1, ${...} and $( ) inside the expression are expanded first. *)
    Expression := ExpandToText(Copy(Word, Position + 2, Finish - 1 - (Position + 2)));
    if not EvaluateArithmetic(Expression, Number) then
      Number := 0;
    AddExpansionResult(IntToStr(Number), Quoted);
  end
  else
    AddExpansionResult(RunCommandSubstitution(Copy(Word, Position + 1, Finish - (Position + 1))), Quoted);
  Position := Finish + 1;
end;

procedure TWordExpander.ExpandDollar(const Word: string; var Position: Integer; Quoted: Boolean);
var
  Start: Integer;
  Value: string;
  IsSet: Boolean;
begin
  Inc(Position); { the '$' }

  case CharAt(Word, Position) of
    '(':
      begin
        ExpandParenthesized(Word, Position, Quoted);
        Exit;
      end;
    '{':
      begin
        ExpandBracedParameter(Self, Word, Position, Quoted);
        Exit;
      end;
    '@', '*':
      begin
        ExpandAllParameters(Word[Position] = '@', Quoted);
        Inc(Position);
        Exit;
      end;
  end;

  if SpecialParameter(CharAt(Word, Position), Value, IsSet) then
  begin
    AddExpansionResult(Value, Quoted);
    Inc(Position);
    Exit;
  end;

  Start := Position;
  while IsNameCharacter(CharAt(Word, Position)) do
    Inc(Position);
  if Position = Start then
  begin
    { A lone '$' is literal. }
    AddQuoted('$');
    Exit;
  end;
  AddExpansionResult(VariableValue(Copy(Word, Start, Position - Start)), Quoted);
end;

procedure TWordExpander.ExpandSingleQuoted(const Word: string; var Position: Integer);
begin
  Inc(Position);
  FFieldStarted := True;
  while not (CharAt(Word, Position) in ['''', #0]) do
  begin
    AddQuoted(Word[Position]);
    Inc(Position);
  end;
  if CharAt(Word, Position) = '''' then
    Inc(Position);
end;

procedure TWordExpander.ExpandDoubleQuoted(const Word: string; var Position: Integer);
var
  WasStarted: Boolean;
begin
  Inc(Position);
  WasStarted := FFieldStarted;
  FFieldStarted := True;
  FNoParametersInQuotes := False;
  while not (CharAt(Word, Position) in ['"', #0]) do
  begin
    if (Word[Position] = '\') and (CharAt(Word, Position + 1) in ['$', '`', '"', '\', #10]) then
    begin
      AddQuoted(Word[Position + 1]);
      Inc(Position, 2);
    end
    else if Word[Position] = '$' then
      ExpandDollar(Word, Position, True)
    else
    begin
      AddQuoted(Word[Position]);
      Inc(Position);
    end;
  end;
  if CharAt(Word, Position) = '"' then
    Inc(Position);
  if FNoParametersInQuotes and not WasStarted and (FText.Value = '') then
    FFieldStarted := False;
  FNoParametersInQuotes := False;
end;

procedure TWordExpander.ExpandWord(const Word: string);
var
  Position: Integer;
  Home: string;
begin
  Position := 1;

  if (CharAt(Word, 1) = '~') and (CharAt(Word, 2) in ['/', #0]) then
  begin
    if not FindVariable('HOME', Home) then
      Home := '/';
    AddExpansionResult(Home, True);
    Position := 2;
  end;

  while Position <= Length(Word) do
  begin
    case Word[Position] of
      '''':
        ExpandSingleQuoted(Word, Position);
      '"':
        ExpandDoubleQuoted(Word, Position);
      '\':
        begin
          if Position < Length(Word) then
            Inc(Position);
          AddQuoted(Word[Position]);
          Inc(Position);
        end;
      '$':
        ExpandDollar(Word, Position, False);
    else
      begin
        AddUnquoted(Word[Position]);
        Inc(Position);
      end;
    end;
  end;
end;

procedure TWordExpander.ExpandHereDocumentBody(const Body: string);
var
  Position: Integer;
begin
  Position := 1;
  while Position <= Length(Body) do
  begin
    if (Body[Position] = '\') and (CharAt(Body, Position + 1) in ['$', '`', '\']) then
    begin
      AddQuoted(Body[Position + 1]);
      Inc(Position, 2);
    end
    else if (Body[Position] = '\') and (CharAt(Body, Position + 1) = #10) then
      Inc(Position, 2)
    else if Body[Position] = '$' then
      ExpandDollar(Body, Position, True)
    else
    begin
      AddQuoted(Body[Position]);
      Inc(Position);
    end;
  end;
end;

{ --- Entry points ------------------------------------------------------ }

procedure ExpandWords(const Words: TStringArray; Fields: TStrings);
var
  Expander: TWordExpander;
  Index: Integer;
begin
  Expander := TWordExpander.Create(Fields, True, False);
  try
    for Index := 0 to High(Words) do
    begin
      Expander.ExpandWord(Words[Index]);
      Expander.FinishField;
    end;
  finally
    Expander.Free;
  end;
end;

function ExpandWordFlat(const Word: string; AsPattern: Boolean): string;
var
  Expander: TWordExpander;
begin
  Expander := TWordExpander.Create(nil, False, AsPattern);
  try
    Expander.ExpandWord(Word);
    if AsPattern then
      Result := Expander.Pattern
    else
      Result := Expander.Text;
  finally
    Expander.Free;
  end;
end;

function ExpandToText(const Word: string): string;
begin
  Result := ExpandWordFlat(Word, False);
end;

function ExpandToPattern(const Word: string): string;
begin
  Result := ExpandWordFlat(Word, True);
end;

function ExpandHereDocument(const Body: string): string;
var
  Expander: TWordExpander;
begin
  Expander := TWordExpander.Create(nil, False, False);
  try
    Expander.ExpandHereDocumentBody(Body);
    Result := Expander.Text;
  finally
    Expander.Free;
  end;
end;

end.
