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

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.RegularExpressions;

var
  Position: Integer;

procedure SyntaxError;
begin
  Report('syntax error', []);
  Halt(2);
end;

function Token(Offset: Integer): PChar;
begin
  if Position + Offset < ArgumentTotal then
    Result := Argument(Position + Offset)
  else
    Result := nil;
end;

function TokenIs(Text: PChar): Boolean;
begin
  Result := (Token(0) <> nil) and TextIsEqual(Token(0), Text);
end;

function IsNumber(Text: PChar; out Value: Int64): Boolean;
begin
  Result := (Text <> nil) and (Text^ <> #0) and ParseInteger(Text, Value);
end;

function MakeNumber(Value: Int64): PChar;
var
  NumberText: TNumberText;
begin
  Result := DuplicateText(FormatSignedDecimal(Value, NumberText));
end;

function IsNullOrZero(Text: PChar): Boolean;
var
  Value: Int64;
begin
  Result := (Text^ = #0) or (IsNumber(Text, Value) and (Value = 0));
end;

function RequireNumber(Text: PChar): Int64;
begin
  if not IsNumber(Text, Result) then
  begin
    Report('non-integer argument', []);
    Halt(2);
  end;
end;

{ --- Pattern matching for ':' ---------------------------------------- }

{ Anchored BRE match: the first group's text if the pattern has a group,
  otherwise the length of the match. }
function MatchPattern(Text, Pattern: PChar): PChar;
var
  Expression: TExpression;
  Match: TMatch;
  ErrorMessage: PChar;
  Length: PtrInt;
begin
  if not CompileExpression(Pattern, SyntaxBasic, Expression, ErrorMessage) then
  begin
    Report('%s', [ArgumentText(ErrorMessage)]);
    Halt(2);
  end;
  if not MatchExpressionAtStart(Expression, Text, Match) then
  begin
    if Expression.GroupCount > 0 then
      Result := DuplicateText('')
    else
      Result := MakeNumber(0);
  end
  else if Expression.GroupCount > 0 then
  begin
    if Match.Starts[1] < 0 then
      Exit(DuplicateText(''));
    Length := Match.Ends[1] - Match.Starts[1];
    Result := PChar(AllocateMemory(Length + 1));
    CopyMemory(Result, Text + Match.Starts[1], Length);
    Result[Length] := #0;
  end
  else
    Result := MakeNumber(Match.Ends[0]);
  FreeExpression(Expression);
end;

{ --- Grammar --------------------------------------------------------- }

function ParseOr: PChar; forward;

function ParsePrimary: PChar;
var
  Text: PChar;
  Start: Int64;
  Count: Int64;
  Length: Int64;
  Index: PtrInt;
  Characters: PChar;
  Found: Int64;
begin
  if Token(0) = nil then
    SyntaxError;
  if TokenIs('(') then
  begin
    Inc(Position);
    Result := ParseOr;
    if not TokenIs(')') then
      SyntaxError;
    Inc(Position);
    Exit;
  end;
  if TokenIs('length') and (Token(1) <> nil) then
  begin
    Result := MakeNumber(TextLength(Token(1)));
    Inc(Position, 2);
    Exit;
  end;
  if TokenIs('substr') and (Token(3) <> nil) then
  begin
    Text := Token(1);
    Length := TextLength(Text);
    Start := RequireNumber(Token(2));
    Count := RequireNumber(Token(3));
    Inc(Position, 4);
    if (Start < 1) or (Start > Length) or (Count < 1) then
      Exit(DuplicateText(''));
    if Start - 1 + Count > Length then
      Count := Length - Start + 1;
    Result := PChar(AllocateMemory(Count + 1));
    CopyMemory(Result, Text + Start - 1, Count);
    Result[Count] := #0;
    Exit;
  end;
  if TokenIs('index') and (Token(2) <> nil) then
  begin
    Text := Token(1);
    Characters := Token(2);
    Found := 0;
    Index := 0;
    while Text[Index] <> #0 do
    begin
      if FindCharacter(Characters, Text[Index]) >= 0 then
      begin
        Found := Index + 1;
        Break;
      end;
      Inc(Index);
    end;
    Inc(Position, 3);
    Exit(MakeNumber(Found));
  end;
  if TokenIs('+') and (Token(1) <> nil) then
    Inc(Position);
  Result := DuplicateText(Token(0));
  Inc(Position);
end;

function ParseMatch: PChar;
var
  Right: PChar;
  Matched: PChar;
begin
  Result := ParsePrimary;
  while TokenIs(':') do
  begin
    Inc(Position);
    Right := ParsePrimary;
    Matched := MatchPattern(Result, Right);
    FreeMemory(Result);
    FreeMemory(Right);
    Result := Matched;
  end;
end;

function ParseProduct: PChar;
var
  Operation: PChar;
  Left: Int64;
  Right: Int64;
  RightText: PChar;
begin
  Result := ParseMatch;
  while TokenIs('*') or TokenIs('/') or TokenIs('%') do
  begin
    Operation := Token(0);
    Inc(Position);
    RightText := ParseMatch;
    Left := RequireNumber(Result);
    Right := RequireNumber(RightText);
    FreeMemory(Result);
    FreeMemory(RightText);
    if (Operation[0] <> '*') and (Right = 0) then
    begin
      Report('division by zero', []);
      Halt(2);
    end;
    case Operation[0] of
      '*': Result := MakeNumber(Left * Right);
      '/': Result := MakeNumber(Left div Right);
    else
      Result := MakeNumber(Left mod Right);
    end;
  end;
end;

function ParseSum: PChar;
var
  IsAddition: Boolean;
  Left: Int64;
  Right: Int64;
  RightText: PChar;
begin
  Result := ParseProduct;
  while TokenIs('+') or TokenIs('-') do
  begin
    IsAddition := TokenIs('+');
    Inc(Position);
    RightText := ParseProduct;
    Left := RequireNumber(Result);
    Right := RequireNumber(RightText);
    FreeMemory(Result);
    FreeMemory(RightText);
    if IsAddition then
      Result := MakeNumber(Left + Right)
    else
      Result := MakeNumber(Left - Right);
  end;
end;

function ParseComparison: PChar;
var
  Operation: PChar;
  RightText: PChar;
  Left: Int64;
  Right: Int64;
  Order: Integer;
  Outcome: Boolean;
begin
  Result := ParseSum;
  while TokenIs('<') or TokenIs('<=') or TokenIs('=') or TokenIs('==') or
        TokenIs('!=') or TokenIs('>=') or TokenIs('>') do
  begin
    Operation := Token(0);
    Inc(Position);
    RightText := ParseSum;
    { Numbers compare as numbers, anything else as text. }
    if IsNumber(Result, Left) and IsNumber(RightText, Right) then
    begin
      if Left < Right then
        Order := -1
      else if Left > Right then
        Order := 1
      else
        Order := 0;
    end
    else
      Order := CompareText(Result, RightText);
    if TextIsEqual(Operation, '<') then
      Outcome := Order < 0
    else if TextIsEqual(Operation, '<=') then
      Outcome := Order <= 0
    else if TextIsEqual(Operation, '=') or TextIsEqual(Operation, '==') then
      Outcome := Order = 0
    else if TextIsEqual(Operation, '!=') then
      Outcome := Order <> 0
    else if TextIsEqual(Operation, '>=') then
      Outcome := Order >= 0
    else
      Outcome := Order > 0;
    FreeMemory(Result);
    FreeMemory(RightText);
    Result := MakeNumber(Ord(Outcome));
  end;
end;

function ParseAnd: PChar;
var
  Right: PChar;
begin
  Result := ParseComparison;
  while TokenIs('&') do
  begin
    Inc(Position);
    Right := ParseComparison;
    if IsNullOrZero(Result) or IsNullOrZero(Right) then
    begin
      FreeMemory(Result);
      Result := MakeNumber(0);
    end;
    FreeMemory(Right);
  end;
end;

function ParseOr: PChar;
var
  Right: PChar;
begin
  Result := ParseAnd;
  while TokenIs('|') do
  begin
    Inc(Position);
    Right := ParseAnd;
    if IsNullOrZero(Result) then
    begin
      FreeMemory(Result);
      if IsNullOrZero(Right) then
      begin
        Result := MakeNumber(0);
        FreeMemory(Right);
      end
      else
        Result := Right;
    end
    else
      FreeMemory(Right);
  end;
end;

var
  Outcome: PChar;
begin
  if ArgumentTotal < 2 then
  begin
    Report('missing operand', []);
    Halt(2);
  end;
  if (ArgumentTotal = 2) and TextIsEqual(Argument(1), '--help') then
  begin
    PrintLine('Usage: expr EXPRESSION');
    Halt(0);
  end;
  Position := 1;
  if TokenIs('--') then
    Inc(Position);
  Outcome := ParseOr;
  if Position < ArgumentTotal then
    SyntaxError;
  PrintLine(Outcome);
  if IsNullOrZero(Outcome) then
    Halt(1);
  Halt(0);
end.
