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
  Arithmetic expansion: $(( expression )).

  Integers only. Operators, from lowest to highest precedence:

    =  +=  -=  *=  /=  %=   (assignment to a variable, lowest)
    ||   &&   == !=   < <= > >=   + -   * / %   unary - + !   ( )

  A name (or $name) stands for the value of that variable; it counts as
  0 if unset or not a number.
}
unit Shell.Arithmetic;

{$mode objfpc}
{$H+}

interface

{ Evaluates Text; False on a syntax error or division by zero. }
function EvaluateArithmetic(const Text: string; out Value: Int64): Boolean;

implementation

uses
  SysUtils,
  Sys.Text,
  Shell.Text,
  Shell.Variables;

type
  { A recursive descent evaluator: one method per precedence level. }
  TArithmeticEvaluator = class
  private
    FText: string;
    FPosition: Integer;
    FFailed: Boolean;
    function Peek(Offset: Integer = 0): Char;
    procedure SkipBlanks;
    function Accept(const Symbol: string): Boolean;
    function ReadName: string;
    function ParsePrimary: Int64;
    function ParseProduct: Int64;
    function ParseSum: Int64;
    function ParseComparison: Int64;
    function ParseEquality: Int64;
    function ParseAnd: Int64;
    function ParseOr: Int64;
    function ParseAssignment: Int64;
  public
    constructor Create(const Text: string);
    function Evaluate(out Value: Int64): Boolean;
  end;

{ The variable's value as a number; 0 if unset or not a number. }
function NumericValue(const Name: string): Int64;
var
  Text: string;
begin
  if not FindVariable(Name, Text) or not TryParseInteger(Text, Result) then
    Result := 0;
end;

constructor TArithmeticEvaluator.Create(const Text: string);
begin
  inherited Create;
  FText := TextBeforeNull(Text);
  FPosition := 1;
end;

function TArithmeticEvaluator.Peek(Offset: Integer): Char;
begin
  Result := CharAt(FText, FPosition + Offset);
end;

procedure TArithmeticEvaluator.SkipBlanks;
begin
  while IsSpace(Peek) do
    Inc(FPosition);
end;

{ Consumes Symbol if it comes next. }
function TArithmeticEvaluator.Accept(const Symbol: string): Boolean;
begin
  SkipBlanks;
  Result := Copy(FText, FPosition, Length(Symbol)) = Symbol;
  { Do not take "<" from "<=", or "=" alone. }
  if Result and (Length(Symbol) = 1) and (Symbol[1] in ['<', '>', '!']) and (Peek(1) = '=') then
    Result := False;
  if Result and (Length(Symbol) = 1) and (Symbol[1] in ['|', '&']) and (Peek(1) = Symbol[1]) then
    Result := False;
  if Result then
    Inc(FPosition, Length(Symbol));
end;

{ Letters, digits and '_' from the current position (possibly none). }
function TArithmeticEvaluator.ReadName: string;
var
  Start: Integer;
begin
  Start := FPosition;
  while IsNameCharacter(Peek) do
    Inc(FPosition);
  Result := Copy(FText, Start, FPosition - Start);
end;

function TArithmeticEvaluator.ParsePrimary: Int64;
var
  Name: string;
begin
  Result := 0;
  SkipBlanks;
  if Accept('(') then
  begin
    Result := ParseOr;
    if not Accept(')') then
      FFailed := True;
    Exit;
  end;
  if Accept('-') then
    Exit(-ParsePrimary());
  if Accept('+') then
    Exit(ParsePrimary());
  if Accept('!') then
    Exit(Ord(ParsePrimary() = 0));

  if Peek = '$' then
    Inc(FPosition);
  if IsDigit(Peek) then
  begin
    while IsDigit(Peek) do
    begin
      Result := Result * 10 + Ord(Peek) - Ord('0');
      Inc(FPosition);
    end;
    Exit;
  end;
  Name := ReadName;
  if Name = '' then
  begin
    FFailed := True;
    Exit;
  end;
  Result := NumericValue(Name);
end;

function TArithmeticEvaluator.ParseProduct: Int64;
var
  Right: Int64;
begin
  Result := ParsePrimary;
  while not FFailed do
  begin
    if Accept('*') then
      Result := Result * ParsePrimary
    else if Accept('/') or Accept('%') then
    begin
      Right := ParsePrimary;
      if Right = 0 then
      begin
        FFailed := True;
        Exit;
      end;
      if CharAt(FText, FPosition - 1) = '/' then
        Result := Result div Right
      else
        Result := Result mod Right;
    end
    else
      Break;
  end;
end;

function TArithmeticEvaluator.ParseSum: Int64;
begin
  Result := ParseProduct;
  while not FFailed do
  begin
    if Accept('+') then
      Result := Result + ParseProduct
    else if Accept('-') then
      Result := Result - ParseProduct
    else
      Break;
  end;
end;

function TArithmeticEvaluator.ParseComparison: Int64;
begin
  Result := ParseSum;
  while not FFailed do
  begin
    if Accept('<=') then
      Result := Ord(Result <= ParseSum)
    else if Accept('>=') then
      Result := Ord(Result >= ParseSum)
    else if Accept('<') then
      Result := Ord(Result < ParseSum)
    else if Accept('>') then
      Result := Ord(Result > ParseSum)
    else
      Break;
  end;
end;

function TArithmeticEvaluator.ParseEquality: Int64;
begin
  Result := ParseComparison;
  while not FFailed do
  begin
    if Accept('==') then
      Result := Ord(Result = ParseComparison)
    else if Accept('!=') then
      Result := Ord(Result <> ParseComparison)
    else
      Break;
  end;
end;

function TArithmeticEvaluator.ParseAnd: Int64;
var
  Right: Int64;
begin
  Result := ParseEquality;
  while not FFailed and Accept('&&') do
  begin
    Right := ParseEquality;
    Result := Ord((Result <> 0) and (Right <> 0));
  end;
end;

function TArithmeticEvaluator.ParseOr: Int64;
var
  Right: Int64;
begin
  Result := ParseAnd;
  while not FFailed and Accept('||') do
  begin
    Right := ParseAnd;
    Result := Ord((Result <> 0) or (Right <> 0));
  end;
end;

{ NAME op= expression, or an ordinary expression. }
function TArithmeticEvaluator.ParseAssignment: Int64;
var
  Saved: Integer;
  Name: string;
  Operation: Char;
  Current: Int64;
  Right: Int64;
begin
  Saved := FPosition;
  SkipBlanks;
  Name := ReadName;
  if (Name <> '') and not IsDigit(Name[1]) then
  begin
    SkipBlanks;
    Operation := #0;
    if (Peek = '=') and (Peek(1) <> '=') then
    begin
      Operation := '=';
      Inc(FPosition);
    end
    else if (Peek in ['+', '-', '*', '/', '%']) and (Peek(1) = '=') then
    begin
      Operation := Peek;
      Inc(FPosition, 2);
    end;
    if Operation <> #0 then
    begin
      Right := ParseAssignment();
      if FFailed then
        Exit(0);
      Current := NumericValue(Name);
      case Operation of
        '=': Current := Right;
        '+': Current := Current + Right;
        '-': Current := Current - Right;
        '*': Current := Current * Right;
      else
        begin
          if Right = 0 then
          begin
            FFailed := True;
            Exit(0);
          end;
          if Operation = '/' then
            Current := Current div Right
          else
            Current := Current mod Right;
        end;
      end;
      AssignVariable(Name, IntToStr(Current));
      Exit(Current);
    end;
  end;
  FPosition := Saved;
  Result := ParseOr;
end;

function TArithmeticEvaluator.Evaluate(out Value: Int64): Boolean;
begin
  FPosition := 1;
  FFailed := False;
  Value := ParseAssignment;
  SkipBlanks;
  Result := not FFailed and (Peek = #0);
end;

function EvaluateArithmetic(const Text: string; out Value: Int64): Boolean;
var
  Evaluator: TArithmeticEvaluator;
begin
  Evaluator := TArithmeticEvaluator.Create(Text);
  try
    Result := Evaluator.Evaluate(Value);
  finally
    Evaluator.Free;
  end;
end;

end.
