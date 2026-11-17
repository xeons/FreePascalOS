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
  Evaluating what the calculator was given as text: what the keys built
  up ("12*(3+4)"), or what was pasted.

    expression  numbers (1.5, 2e+10), pi (or π) and e, parentheses
                (those still open at the end are closed), functions
                applied to a parenthesised argument (sqrt(2),
                sin(30): Calculator.MathFunctions' names), postfix !
                (factorial), unary minus and plus
    operators   ^ (also yroot, the left side's root of that degree;
                both right to left), * / mod (also × ÷), + - (also −),
                and in the programmer mode lsh rsh, and, xor, or
                (in that order, loosest last); not(x)

  Two orders: by precedence (the scientific and programmer modes) and
  strictly left to right (the standard mode, where 2 + 3 x 4 is 20, as
  a pocket calculator does it). Integer evaluation (the programmer
  mode) works on Int64s wrapped to the word size, numbers in decimal.

  Plain logic: the host checks it (make apps-test).
}
unit Calculator.Expressions;

{$mode objfpc}
{$H+}

interface

uses
  Calculator.MathFunctions;

type
  TEvaluationOrder = (OrderPrecedence, OrderLeftToRight);

  TEvaluationSettings = record
    Order: TEvaluationOrder;
    Angles: TAngleUnit;
    { Int64s of WordBits bits rather than doubles. }
    Integers: Boolean;
    WordBits: LongInt;
  end;

  TCalculatorValue = record
    Real: Double;
    Whole: Int64;
  end;

function DefaultEvaluationSettings: TEvaluationSettings;
{ False (and Error says why) if Text cannot be evaluated. }
function EvaluateExpression(const Text: string; const Settings: TEvaluationSettings;
  out Value: TCalculatorValue; out Error: TCalculationError): Boolean;
{ The same, for doubles. }
function EvaluateToReal(const Text: string; const Settings: TEvaluationSettings; out Value: Double;
  out Error: TCalculationError): Boolean;

implementation

uses
  SysUtils,
  Math,
  Calculator.Numbers;

type
  TTokenKind = (TokenEnd, TokenNumber, TokenName, TokenSymbol);

  TToken = record
    Kind: TTokenKind;
    Text: string;
  end;

  TParser = record
    Text: string;
    Position: LongInt;
    Current: TToken;
    Settings: TEvaluationSettings;
    Error: TCalculationError;
  end;

const
  PrecedenceOr = 1;
  PrecedenceXor = 2;
  PrecedenceAnd = 3;
  PrecedenceShift = 4;
  PrecedenceAdditive = 5;
  PrecedenceMultiplicative = 6;
  PrecedenceUnary = 7;
  PrecedencePower = 8;
  NoPrecedence = 0;
  MultiplySign = #$C3#$97;
  DivideSign = #$C3#$B7;
  MinusSign = #$E2#$88#$92;
  PiSign = #$CF#$80;

function DefaultEvaluationSettings: TEvaluationSettings;
begin
  Result.Order := OrderPrecedence;
  Result.Angles := AngleDegrees;
  Result.Integers := False;
  Result.WordBits := 64;
end;

function MakeValue(Real: Double; Whole: Int64): TCalculatorValue;
begin
  Result.Real := Real;
  Result.Whole := Whole;
end;

{ --- Tokens ------------------------------------------------------------------------------ }

function StartsWithAt(const Text, Part: string; Position: LongInt): Boolean;
begin
  Result := Copy(Text, Position, Length(Part)) = Part;
end;

procedure ReadNumberToken(var Parser: TParser);
var
  Start: LongInt;
begin
  Start := Parser.Position;
  while (Parser.Position <= Length(Parser.Text)) and (Parser.Text[Parser.Position] in ['0'..'9', '.']) do
    Inc(Parser.Position);
  { An exponent: e or E, a sign or digit, digits ("2e" alone is 2 times e
    no more than "2pi" is; it is refused). }
  if (Parser.Position < Length(Parser.Text)) and (Parser.Text[Parser.Position] in ['e', 'E']) and
     ((Parser.Text[Parser.Position + 1] in ['0'..'9']) or ((Parser.Text[Parser.Position + 1] in ['+', '-']) and
     (Parser.Position + 1 < Length(Parser.Text)) and (Parser.Text[Parser.Position + 2] in ['0'..'9']))) then
  begin
    Inc(Parser.Position, 2);
    while (Parser.Position <= Length(Parser.Text)) and (Parser.Text[Parser.Position] in ['0'..'9']) do
      Inc(Parser.Position);
  end;
  Parser.Current.Kind := TokenNumber;
  Parser.Current.Text := Copy(Parser.Text, Start, Parser.Position - Start);
end;

procedure ReadSymbol(var Parser: TParser; const Symbol: string; Length: LongInt);
begin
  Parser.Current.Kind := TokenSymbol;
  Parser.Current.Text := Symbol;
  Inc(Parser.Position, Length);
end;

procedure NextToken(var Parser: TParser);
var
  Start: LongInt;
begin
  while (Parser.Position <= Length(Parser.Text)) and (Parser.Text[Parser.Position] in [' ', #9]) do
    Inc(Parser.Position);
  if Parser.Position > Length(Parser.Text) then
  begin
    Parser.Current.Kind := TokenEnd;
    Parser.Current.Text := '';
    Exit;
  end;
  if Parser.Text[Parser.Position] in ['0'..'9', '.'] then
    ReadNumberToken(Parser)
  else if Parser.Text[Parser.Position] in ['a'..'z', 'A'..'Z'] then
  begin
    Start := Parser.Position;
    while (Parser.Position <= Length(Parser.Text)) and (Parser.Text[Parser.Position] in ['a'..'z', 'A'..'Z']) do
      Inc(Parser.Position);
    Parser.Current.Kind := TokenName;
    Parser.Current.Text := LowerCase(Copy(Parser.Text, Start, Parser.Position - Start));
  end
  else if StartsWithAt(Parser.Text, MultiplySign, Parser.Position) then
    ReadSymbol(Parser, '*', Length(MultiplySign))
  else if StartsWithAt(Parser.Text, DivideSign, Parser.Position) then
    ReadSymbol(Parser, '/', Length(DivideSign))
  else if StartsWithAt(Parser.Text, MinusSign, Parser.Position) then
    ReadSymbol(Parser, '-', Length(MinusSign))
  else if StartsWithAt(Parser.Text, PiSign, Parser.Position) then
  begin
    Parser.Current.Kind := TokenName;
    Parser.Current.Text := 'pi';
    Inc(Parser.Position, Length(PiSign));
  end
  else
    ReadSymbol(Parser, Parser.Text[Parser.Position], 1);
end;

{ --- Operators ---------------------------------------------------------------------------- }

{ The binary operator Token is, and its precedence (NoPrecedence: none). }
function BinaryOperatorOf(const Token: TToken; const Settings: TEvaluationSettings;
  out Operation: TBinaryOperator): LongInt;
begin
  Result := NoPrecedence;
  Operation := OperatorAdd;
  if Token.Kind = TokenSymbol then
    case Token.Text of
      '+': Result := PrecedenceAdditive;
      '-':
        begin
          Operation := OperatorSubtract;
          Result := PrecedenceAdditive;
        end;
      '*':
        begin
          Operation := OperatorMultiply;
          Result := PrecedenceMultiplicative;
        end;
      '/':
        begin
          Operation := OperatorDivide;
          Result := PrecedenceMultiplicative;
        end;
      '^':
        begin
          Operation := OperatorPower;
          Result := PrecedencePower;
        end;
    end
  else if Token.Kind = TokenName then
    case Token.Text of
      'mod':
        begin
          Operation := OperatorModulo;
          Result := PrecedenceMultiplicative;
        end;
      'yroot':
        begin
          Operation := OperatorRoot;
          Result := PrecedencePower;
        end;
      'and':
        begin
          Operation := OperatorAnd;
          Result := PrecedenceAnd;
        end;
      'or':
        begin
          Operation := OperatorOr;
          Result := PrecedenceOr;
        end;
      'xor':
        begin
          Operation := OperatorXor;
          Result := PrecedenceXor;
        end;
      'lsh':
        begin
          Operation := OperatorShiftLeft;
          Result := PrecedenceShift;
        end;
      'rsh':
        begin
          Operation := OperatorShiftRight;
          Result := PrecedenceShift;
        end;
    end;
  if (Result <> NoPrecedence) and (Settings.Order = OrderLeftToRight) then
    Result := PrecedenceAdditive;
end;

function IsRightToLeft(Operation: TBinaryOperator; const Settings: TEvaluationSettings): Boolean;
begin
  Result := (Settings.Order = OrderPrecedence) and (Operation in [OperatorPower, OperatorRoot]);
end;

function FindFunction(const Name: string; out Operation: TUnaryFunction): Boolean;
var
  Candidate: TUnaryFunction;
begin
  Operation := FunctionNegate;
  for Candidate := Low(TUnaryFunction) to High(TUnaryFunction) do
    if UnaryFunctionNames[Candidate] = Name then
    begin
      Operation := Candidate;
      Exit(True);
    end;
  Result := False;
end;

function Fail(var Parser: TParser; Error: TCalculationError): TCalculatorValue;
begin
  if Parser.Error = CalculationOk then
    Parser.Error := Error;
  Result := MakeValue(0, 0);
end;

function Binary(var Parser: TParser; Operation: TBinaryOperator; const Left, Right: TCalculatorValue): TCalculatorValue;
begin
  if Parser.Settings.Integers then
    Result := MakeValue(0, ApplyIntegerBinary(Operation, Left.Whole, Right.Whole, Parser.Settings.WordBits,
      Parser.Error))
  else
    Result := MakeValue(ApplyBinary(Operation, Left.Real, Right.Real, Parser.Error), 0);
end;

function Unary(var Parser: TParser; Operation: TUnaryFunction; const Argument: TCalculatorValue): TCalculatorValue;
begin
  if Parser.Settings.Integers then
    Result := MakeValue(0, ApplyIntegerUnary(Operation, Argument.Whole, Parser.Settings.WordBits, Parser.Error))
  else
    Result := MakeValue(ApplyUnary(Operation, Argument.Real, Parser.Settings.Angles, Parser.Error), 0);
end;

{ --- Parsing ------------------------------------------------------------------------------- }

function ParseExpression(var Parser: TParser; MinimumPrecedence: LongInt): TCalculatorValue; forward;

function NumberValue(var Parser: TParser): TCalculatorValue;
var
  Real: Double;
  Whole: Int64;
begin
  if Parser.Settings.Integers then
  begin
    if not ParseInBase(Parser.Current.Text, 10, Parser.Settings.WordBits, Whole) then
      Exit(Fail(Parser, CalculationSyntax));
    Result := MakeValue(0, Whole);
  end
  else
  begin
    if not ParseCalculatorNumber(Parser.Current.Text, Real) then
      Exit(Fail(Parser, CalculationSyntax));
    Result := MakeValue(Real, 0);
  end;
  NextToken(Parser);
end;

{ An expression in parentheses; one not closed by the end of the text
  is closed there. }
function ParenthesisedValue(var Parser: TParser): TCalculatorValue;
begin
  if (Parser.Current.Kind <> TokenSymbol) or (Parser.Current.Text <> '(') then
    Exit(Fail(Parser, CalculationSyntax));
  NextToken(Parser);
  Result := ParseExpression(Parser, PrecedenceOr);
  if (Parser.Current.Kind = TokenSymbol) and (Parser.Current.Text = ')') then
    NextToken(Parser)
  else if Parser.Current.Kind <> TokenEnd then
    Result := Fail(Parser, CalculationSyntax);
end;

function NamedValue(var Parser: TParser): TCalculatorValue;
var
  Name: string;
  Operation: TUnaryFunction;
  Argument: TCalculatorValue;
begin
  Name := Parser.Current.Text;
  NextToken(Parser);
  if (Name = 'pi') or (Name = 'e') then
  begin
    if Parser.Settings.Integers then
      Exit(Fail(Parser, CalculationSyntax));
    if Name = 'pi' then
      Exit(MakeValue(Pi, 0));
    Exit(MakeValue(Exp(1), 0));
  end;
  if Name = 'not' then
  begin
    if not Parser.Settings.Integers then
      Exit(Fail(Parser, CalculationSyntax));
    Argument := ParenthesisedValue(Parser);
    Exit(MakeValue(0, WrapToWord(not Argument.Whole, Parser.Settings.WordBits)));
  end;
  if not FindFunction(Name, Operation) then
    Exit(Fail(Parser, CalculationSyntax));
  Argument := ParenthesisedValue(Parser);
  if Parser.Error <> CalculationOk then
    Exit(Argument);
  Result := Unary(Parser, Operation, Argument);
end;

function ParsePrimary(var Parser: TParser): TCalculatorValue;
begin
  case Parser.Current.Kind of
    TokenNumber: Result := NumberValue(Parser);
    TokenName: Result := NamedValue(Parser);
    TokenSymbol:
      if Parser.Current.Text = '(' then
        Result := ParenthesisedValue(Parser)
      else
        Result := Fail(Parser, CalculationSyntax);
  else
    Result := Fail(Parser, CalculationSyntax);
  end;
  { Postfix factorials. }
  while (Parser.Error = CalculationOk) and (Parser.Current.Kind = TokenSymbol) and (Parser.Current.Text = '!') do
  begin
    NextToken(Parser);
    Result := Unary(Parser, FunctionFactorial, Result);
  end;
end;

{ A sign binds more loosely than a power: -2^2 is -4. }
function ParseUnary(var Parser: TParser): TCalculatorValue;
var
  Negative: Boolean;
begin
  Negative := False;
  while (Parser.Current.Kind = TokenSymbol) and ((Parser.Current.Text = '-') or (Parser.Current.Text = '+')) do
  begin
    if Parser.Current.Text = '-' then
      Negative := not Negative;
    NextToken(Parser);
  end;
  if not Negative then
    Exit(ParsePrimary(Parser));
  if Parser.Settings.Order = OrderPrecedence then
    Result := ParseExpression(Parser, PrecedencePower)
  else
    Result := ParsePrimary(Parser);
  if Parser.Error = CalculationOk then
    Result := Unary(Parser, FunctionNegate, Result);
end;

function ParseExpression(var Parser: TParser; MinimumPrecedence: LongInt): TCalculatorValue;
var
  Operation: TBinaryOperator;
  Precedence: LongInt;
  NextMinimum: LongInt;
  Right: TCalculatorValue;
begin
  Result := ParseUnary(Parser);
  while Parser.Error = CalculationOk do
  begin
    Precedence := BinaryOperatorOf(Parser.Current, Parser.Settings, Operation);
    if (Precedence = NoPrecedence) or (Precedence < MinimumPrecedence) then
      Break;
    NextToken(Parser);
    if IsRightToLeft(Operation, Parser.Settings) then
      NextMinimum := Precedence
    else
      NextMinimum := Precedence + 1;
    Right := ParseExpression(Parser, NextMinimum);
    if Parser.Error <> CalculationOk then
      Break;
    Result := Binary(Parser, Operation, Result, Right);
  end;
end;

function EvaluateExpression(const Text: string; const Settings: TEvaluationSettings;
  out Value: TCalculatorValue; out Error: TCalculationError): Boolean;
var
  Parser: TParser;
begin
  Parser.Text := Text;
  Parser.Position := 1;
  Parser.Settings := Settings;
  Parser.Error := CalculationOk;
  NextToken(Parser);
  Value := ParseExpression(Parser, PrecedenceOr);
  if (Parser.Error = CalculationOk) and (Parser.Current.Kind <> TokenEnd) then
    Parser.Error := CalculationSyntax;
  Error := Parser.Error;
  Result := Error = CalculationOk;
  if not Result then
    Value := MakeValue(0, 0);
end;

function EvaluateToReal(const Text: string; const Settings: TEvaluationSettings; out Value: Double;
  out Error: TCalculationError): Boolean;
var
  Both: TCalculatorValue;
begin
  Result := EvaluateExpression(Text, Settings, Both, Error);
  Value := Both.Real;
end;

end.
