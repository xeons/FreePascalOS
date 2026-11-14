{
  Arithmetic expansion: $(( expression )).

  Integers only. Operators, from lowest to highest precedence:

    ||   &&   == !=   < <= > >=   + -   * / %   unary - + !   ( )

  A name (or $name) stands for the value of that variable; it counts as
  0 if unset or not a number.
}
unit Shell.Arithmetic;

{$mode objfpc}
{$pointermath on}

interface

{ Evaluates Text; False on a syntax error or division by zero. }
function EvaluateArithmetic(Text: PChar; out Value: Int64): Boolean;

implementation

uses
  Runtime.Text,
  Sys.Text,
  Shell.Variables;

type
  TEvaluator = record
    Text: PChar;
    Position: PtrUInt;
    Failed: Boolean;
  end;

procedure SkipBlanks(var Evaluator: TEvaluator);
begin
  while IsSpace(Evaluator.Text[Evaluator.Position]) do
    Inc(Evaluator.Position);
end;

{ Consumes Symbol if it comes next. }
function Accept(var Evaluator: TEvaluator; Symbol: PChar): Boolean;
var
  Length: PtrUInt;
begin
  SkipBlanks(Evaluator);
  Length := TextLength(Symbol);
  Result := TextStartsWith(Evaluator.Text + Evaluator.Position, Symbol);
  { Do not take "<" from "<=", or "=" alone. }
  if Result and (Length = 1) and (Symbol[0] in ['<', '>', '!']) and
     (Evaluator.Text[Evaluator.Position + 1] = '=') then
    Result := False;
  if Result and (Length = 1) and (Symbol[0] in ['|', '&']) and
     (Evaluator.Text[Evaluator.Position + 1] = Symbol[0]) then
    Result := False;
  if Result then
    Inc(Evaluator.Position, Length);
end;

function ParseOr(var Evaluator: TEvaluator): Int64; forward;

function ParsePrimary(var Evaluator: TEvaluator): Int64;
var
  Start: PtrUInt;
  Name: array[0..127] of Char;
  Length: PtrUInt;
  VariableValue: PChar;
begin
  Result := 0;
  SkipBlanks(Evaluator);
  if Accept(Evaluator, '(') then
  begin
    Result := ParseOr(Evaluator);
    if not Accept(Evaluator, ')') then
      Evaluator.Failed := True;
    Exit;
  end;
  if Accept(Evaluator, '-') then
    Exit(-ParsePrimary(Evaluator));
  if Accept(Evaluator, '+') then
    Exit(ParsePrimary(Evaluator));
  if Accept(Evaluator, '!') then
    Exit(Ord(ParsePrimary(Evaluator) = 0));

  if Evaluator.Text[Evaluator.Position] = '$' then
    Inc(Evaluator.Position);
  Start := Evaluator.Position;
  if IsDigit(Evaluator.Text[Start]) then
  begin
    while IsDigit(Evaluator.Text[Evaluator.Position]) do
    begin
      Result := Result * 10 + Ord(Evaluator.Text[Evaluator.Position]) - Ord('0');
      Inc(Evaluator.Position);
    end;
    Exit;
  end;
  while IsAlphanumeric(Evaluator.Text[Evaluator.Position]) or (Evaluator.Text[Evaluator.Position] = '_') do
    Inc(Evaluator.Position);
  Length := Evaluator.Position - Start;
  if (Length = 0) or (Length >= SizeOf(Name)) then
  begin
    Evaluator.Failed := True;
    Exit;
  end;
  CopyText(@Name[0], Evaluator.Text + Start, Length + 1);
  VariableValue := LookupVariable(@Name[0]);
  if (VariableValue = nil) or not ParseInteger(VariableValue, Result) then
    Result := 0;
end;

function ParseProduct(var Evaluator: TEvaluator): Int64;
var
  Right: Int64;
begin
  Result := ParsePrimary(Evaluator);
  while not Evaluator.Failed do
  begin
    if Accept(Evaluator, '*') then
      Result := Result * ParsePrimary(Evaluator)
    else if Accept(Evaluator, '/') or Accept(Evaluator, '%') then
    begin
      Right := ParsePrimary(Evaluator);
      if Right = 0 then
      begin
        Evaluator.Failed := True;
        Exit;
      end;
      if Evaluator.Text[Evaluator.Position - 1] = '/' then
        Result := Result div Right
      else
        Result := Result mod Right;
    end
    else
      Break;
  end;
end;

function ParseSum(var Evaluator: TEvaluator): Int64;
begin
  Result := ParseProduct(Evaluator);
  while not Evaluator.Failed do
  begin
    if Accept(Evaluator, '+') then
      Result := Result + ParseProduct(Evaluator)
    else if Accept(Evaluator, '-') then
      Result := Result - ParseProduct(Evaluator)
    else
      Break;
  end;
end;

function ParseComparison(var Evaluator: TEvaluator): Int64;
begin
  Result := ParseSum(Evaluator);
  while not Evaluator.Failed do
  begin
    if Accept(Evaluator, '<=') then
      Result := Ord(Result <= ParseSum(Evaluator))
    else if Accept(Evaluator, '>=') then
      Result := Ord(Result >= ParseSum(Evaluator))
    else if Accept(Evaluator, '<') then
      Result := Ord(Result < ParseSum(Evaluator))
    else if Accept(Evaluator, '>') then
      Result := Ord(Result > ParseSum(Evaluator))
    else
      Break;
  end;
end;

function ParseEquality(var Evaluator: TEvaluator): Int64;
begin
  Result := ParseComparison(Evaluator);
  while not Evaluator.Failed do
  begin
    if Accept(Evaluator, '==') then
      Result := Ord(Result = ParseComparison(Evaluator))
    else if Accept(Evaluator, '!=') then
      Result := Ord(Result <> ParseComparison(Evaluator))
    else
      Break;
  end;
end;

function ParseAnd(var Evaluator: TEvaluator): Int64;
var
  Right: Int64;
begin
  Result := ParseEquality(Evaluator);
  while not Evaluator.Failed and Accept(Evaluator, '&&') do
  begin
    Right := ParseEquality(Evaluator);
    Result := Ord((Result <> 0) and (Right <> 0));
  end;
end;

function ParseOr(var Evaluator: TEvaluator): Int64;
var
  Right: Int64;
begin
  Result := ParseAnd(Evaluator);
  while not Evaluator.Failed and Accept(Evaluator, '||') do
  begin
    Right := ParseAnd(Evaluator);
    Result := Ord((Result <> 0) or (Right <> 0));
  end;
end;

function EvaluateArithmetic(Text: PChar; out Value: Int64): Boolean;
var
  Evaluator: TEvaluator;
begin
  Evaluator.Text := Text;
  Evaluator.Position := 0;
  Evaluator.Failed := False;
  Value := ParseOr(Evaluator);
  SkipBlanks(Evaluator);
  Result := not Evaluator.Failed and (Evaluator.Text[Evaluator.Position] = #0);
end;

end.
