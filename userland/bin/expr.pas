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
  expr - evaluate expressions

  expr EXPRESSION

  Each token is a separate argument. Operators, lowest precedence first:
    |  &  < <= = == != >= >  + -  * / %  : (match a pattern at the start)
  plus "length STRING", "substr STRING POS LENGTH", "index STRING CHARS"
  and parentheses. Prints the result; exits 0 if it is neither empty nor
  0, 1 if it is, 2 for an invalid expression.

  The ':' operator matches a basic regular expression at the start of
  the text (see Util.RegularExpressions); \( \) marks the part to return.
}
program expr;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Util.RegularExpressions;

type
  { A recursive descent evaluator over the tokens (one per argument);
    every value is a string, numbers in decimal. }
  TExpressionEvaluator = class
  private
    FTokens: TStringArray;
    FPosition: Integer;
    function HasToken(Offset: Integer): Boolean;
    function TokenAt(Offset: Integer): string;
    function TokenIs(const Text: string): Boolean;
    function ParsePrimary: string;
    function ParseMatch: string;
    function ParseProduct: string;
    function ParseSum: string;
    function ParseComparison: string;
    function ParseAnd: string;
    function ParseOr: string;
  public
    constructor Create(const Tokens: TStringArray);
    { The value of the whole expression; a syntax error ends the program. }
    function Evaluate: string;
  end;

procedure SyntaxError;
begin
  Report('syntax error');
  Halt(2);
end;

function IsNumber(const Text: string; out Value: Int64): Boolean;
begin
  Result := (Text <> '') and ParseDecimal(Text, Value);
end;

function IsNullOrZero(const Text: string): Boolean;
var
  Value: Int64;
begin
  Result := (Text = '') or (IsNumber(Text, Value) and (Value = 0));
end;

function RequireNumber(const Text: string): Int64;
begin
  if not IsNumber(Text, Result) then
  begin
    Report('non-integer argument');
    Halt(2);
  end;
end;

{ --- Pattern matching for ':' ---------------------------------------- }

{ Anchored BRE match: the first group's text if the pattern has a group,
  otherwise the length of the match. }
function MatchPattern(const Text, Pattern: string): string;
var
  Expression: TExpression;
  Match: TMatch;
  ErrorMessage: string;
begin
  if not CompileExpression(Pattern, SyntaxBasic, Expression, ErrorMessage) then
  begin
    Report(ErrorMessage);
    Halt(2);
  end;
  if not MatchExpressionAtStart(Expression, Text, Match) then
  begin
    if Expression.GroupCount > 0 then
      Result := ''
    else
      Result := '0';
  end
  else if Expression.GroupCount > 0 then
    Result := MatchedText(Text, Match, 1)
  else
    Result := IntToStr(Match.Ends[0]);
  FreeExpression(Expression);
end;

{ --- Grammar --------------------------------------------------------- }

constructor TExpressionEvaluator.Create(const Tokens: TStringArray);
begin
  inherited Create;
  FTokens := Tokens;
  FPosition := 0;
end;

function TExpressionEvaluator.HasToken(Offset: Integer): Boolean;
begin
  Result := FPosition + Offset < Length(FTokens);
end;

function TExpressionEvaluator.TokenAt(Offset: Integer): string;
begin
  if HasToken(Offset) then
    Result := FTokens[FPosition + Offset]
  else
    Result := '';
end;

function TExpressionEvaluator.TokenIs(const Text: string): Boolean;
begin
  Result := HasToken(0) and (FTokens[FPosition] = Text);
end;

function TExpressionEvaluator.Evaluate: string;
begin
  if TokenIs('--') then
    Inc(FPosition);
  Result := ParseOr;
  if HasToken(0) then
    SyntaxError;
end;

function TExpressionEvaluator.ParsePrimary: string;
var
  Text: string;
  Start: Int64;
  Count: Int64;
  Index: Integer;
  Found: Integer;
begin
  if not HasToken(0) then
    SyntaxError;
  if TokenIs('(') then
  begin
    Inc(FPosition);
    Result := ParseOr;
    if not TokenIs(')') then
      SyntaxError;
    Inc(FPosition);
    Exit;
  end;
  if TokenIs('length') and HasToken(1) then
  begin
    Result := IntToStr(Length(TokenAt(1)));
    Inc(FPosition, 2);
    Exit;
  end;
  if TokenIs('substr') and HasToken(3) then
  begin
    Text := TokenAt(1);
    Start := RequireNumber(TokenAt(2));
    Count := RequireNumber(TokenAt(3));
    Inc(FPosition, 4);
    if (Start < 1) or (Start > Length(Text)) or (Count < 1) then
      Exit('');
    Exit(Copy(Text, Start, Count));
  end;
  if TokenIs('index') and HasToken(2) then
  begin
    Text := TokenAt(1);
    Found := 0;
    for Index := 1 to Length(Text) do
      if Pos(Text[Index], TokenAt(2)) > 0 then
      begin
        Found := Index;
        Break;
      end;
    Inc(FPosition, 3);
    Exit(IntToStr(Found));
  end;
  if TokenIs('+') and HasToken(1) then
    Inc(FPosition);
  Result := TokenAt(0);
  Inc(FPosition);
end;

function TExpressionEvaluator.ParseMatch: string;
begin
  Result := ParsePrimary;
  while TokenIs(':') do
  begin
    Inc(FPosition);
    Result := MatchPattern(Result, ParsePrimary);
  end;
end;

function TExpressionEvaluator.ParseProduct: string;
var
  Operation: string;
  Left: Int64;
  Right: Int64;
  RightText: string;
begin
  Result := ParseMatch;
  while TokenIs('*') or TokenIs('/') or TokenIs('%') do
  begin
    Operation := TokenAt(0);
    Inc(FPosition);
    RightText := ParseMatch;
    Left := RequireNumber(Result);
    Right := RequireNumber(RightText);
    if (Operation <> '*') and (Right = 0) then
    begin
      Report('division by zero');
      Halt(2);
    end;
    if Operation = '*' then
      Result := IntToStr(Left * Right)
    else if Operation = '/' then
      Result := IntToStr(Left div Right)
    else
      Result := IntToStr(Left mod Right);
  end;
end;

function TExpressionEvaluator.ParseSum: string;
var
  IsAddition: Boolean;
  Left: Int64;
  Right: Int64;
  RightText: string;
begin
  Result := ParseProduct;
  while TokenIs('+') or TokenIs('-') do
  begin
    IsAddition := TokenIs('+');
    Inc(FPosition);
    RightText := ParseProduct;
    Left := RequireNumber(Result);
    Right := RequireNumber(RightText);
    if IsAddition then
      Result := IntToStr(Left + Right)
    else
      Result := IntToStr(Left - Right);
  end;
end;

{ Numbers compare as numbers, anything else as text. }
function CompareValues(const Left, Right: string): Integer;
var
  LeftNumber: Int64;
  RightNumber: Int64;
begin
  if IsNumber(Left, LeftNumber) and IsNumber(Right, RightNumber) then
  begin
    if LeftNumber < RightNumber then
      Result := -1
    else if LeftNumber > RightNumber then
      Result := 1
    else
      Result := 0;
  end
  else
    Result := CompareStr(Left, Right);
end;

function TExpressionEvaluator.ParseComparison: string;
var
  Operation: string;
  Order: Integer;
  Outcome: Boolean;
begin
  Result := ParseSum;
  while TokenIs('<') or TokenIs('<=') or TokenIs('=') or TokenIs('==') or
        TokenIs('!=') or TokenIs('>=') or TokenIs('>') do
  begin
    Operation := TokenAt(0);
    Inc(FPosition);
    Order := CompareValues(Result, ParseSum);
    if Operation = '<' then
      Outcome := Order < 0
    else if Operation = '<=' then
      Outcome := Order <= 0
    else if (Operation = '=') or (Operation = '==') then
      Outcome := Order = 0
    else if Operation = '!=' then
      Outcome := Order <> 0
    else if Operation = '>=' then
      Outcome := Order >= 0
    else
      Outcome := Order > 0;
    Result := IntToStr(Ord(Outcome));
  end;
end;

function TExpressionEvaluator.ParseAnd: string;
var
  Right: string;
begin
  Result := ParseComparison;
  while TokenIs('&') do
  begin
    Inc(FPosition);
    Right := ParseComparison;
    if IsNullOrZero(Result) or IsNullOrZero(Right) then
      Result := '0';
  end;
end;

function TExpressionEvaluator.ParseOr: string;
var
  Right: string;
begin
  Result := ParseAnd;
  while TokenIs('|') do
  begin
    Inc(FPosition);
    Right := ParseAnd;
    if IsNullOrZero(Result) then
    begin
      if IsNullOrZero(Right) then
        Result := '0'
      else
        Result := Right;
    end;
  end;
end;

var
  Arguments: TStringArray;
  Evaluator: TExpressionEvaluator;
  Outcome: string;
begin
  Arguments := ProgramArguments;
  if Length(Arguments) = 0 then
  begin
    Report('missing operand');
    Halt(2);
  end;
  if (Length(Arguments) = 1) and (Arguments[0] = '--help') then
  begin
    PrintStringLine('Usage: expr EXPRESSION');
    Halt(0);
  end;
  Evaluator := TExpressionEvaluator.Create(Arguments);
  Outcome := Evaluator.Evaluate;
  Evaluator.Free;
  PrintStringLine(Outcome);
  if IsNullOrZero(Outcome) then
    Halt(1);
  Halt(0);
end.
