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
  The calculator's arithmetic on doubles, each operation telling what
  went wrong rather than giving NaN or an infinity: division by zero,
  an argument outside the function's domain (the square root of a
  negative number, the tangent of 90 degrees), or a result too large.

  Sums keep no noise: a sum far smaller than its terms (0.3 - 0.1 - 0.2)
  is zero, not a few units in the last place. Angles are in degrees,
  radians or gradians; whole quarter turns give exact sines and cosines
  (the sine of 180 degrees, or of pi radians, is 0, not 1.2e-16).

  Plain logic: the host checks it (make apps-test).
}
unit Calculator.MathFunctions;

{$mode objfpc}
{$H+}

interface

type
  TAngleUnit = (AngleDegrees, AngleRadians, AngleGradians);

  TCalculationError = (CalculationOk, CalculationSyntax, CalculationDivideByZero, CalculationDomain,
    CalculationOverflow);

  TUnaryFunction = (FunctionSquareRoot, FunctionCubeRoot, FunctionSquare, FunctionCube, FunctionReciprocal,
    FunctionNegate, FunctionFactorial, FunctionSine, FunctionCosine, FunctionTangent, FunctionArcSine,
    FunctionArcCosine, FunctionArcTangent, FunctionHyperbolicSine, FunctionHyperbolicCosine,
    FunctionHyperbolicTangent, FunctionNaturalLog, FunctionCommonLog, FunctionExponential, FunctionTenPower,
    FunctionAbsolute);

  TBinaryOperator = (OperatorAdd, OperatorSubtract, OperatorMultiply, OperatorDivide, OperatorPower,
    OperatorRoot, OperatorModulo, OperatorAnd, OperatorOr, OperatorXor, OperatorShiftLeft, OperatorShiftRight);

const
  { The names functions have in expressions. }
  UnaryFunctionNames: array[TUnaryFunction] of string = ('sqrt', 'cbrt', 'sqr', 'cube', 'recip', 'negate', 'fact',
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sinh', 'cosh', 'tanh', 'ln', 'log', 'exp', 'tenpow', 'abs');

  CalculationErrorTexts: array[TCalculationError] of string = ('', 'Invalid input', 'Cannot divide by zero',
    'Invalid input', 'Overflow');

{ Each sets Error (left as it is when all goes well). }
function ApplyUnary(Operation: TUnaryFunction; Value: Double; Angles: TAngleUnit;
  var Error: TCalculationError): Double;
function ApplyBinary(Operation: TBinaryOperator; Left, Right: Double; var Error: TCalculationError): Double;
{ The same on integers of a word of Bits bits (bit operators,
  division towards zero; powers and roots of integers). }
function ApplyIntegerUnary(Operation: TUnaryFunction; Value: Int64; Bits: LongInt;
  var Error: TCalculationError): Int64;
function ApplyIntegerBinary(Operation: TBinaryOperator; Left, Right: Int64; Bits: LongInt;
  var Error: TCalculationError): Int64;
{ Error becomes CalculationOverflow (or Domain for NaN) if Value is not a
  finite number, and Value is returned. }
function CheckedResult(Value: Double; var Error: TCalculationError): Double;

implementation

uses
  Math,
  Calculator.Numbers;

{$R-}
{$Q-}

const
  { A sum smaller than this share of its larger term is rounding noise. }
  CancellationShare = 8e-16;
  LargestFactorial = 170;
  { How near a whole number of quarter turns an angle must be to count
    as one (in quarter turns). }
  QuarterTurnTolerance = 1e-12;

function CheckedResult(Value: Double; var Error: TCalculationError): Double;
begin
  Result := Value;
  if Error <> CalculationOk then
    Exit;
  if IsNan(Value) then
    Error := CalculationDomain
  else if IsInfinite(Value) or (Abs(Value) > MaxDouble) then
    Error := CalculationOverflow;
end;

function GuardedSum(Left, Right: Double): Double;
var
  Larger: Double;
begin
  Result := Left + Right;
  Larger := Max(Abs(Left), Abs(Right));
  if (Result <> 0) and (Abs(Result) < Larger * CancellationShare) then
    Result := 0;
end;

{ --- Angles --------------------------------------------------------------------------- }

function QuarterTurnsOf(Value: Double; Angles: TAngleUnit): Double;
begin
  case Angles of
    AngleDegrees: Result := Value / 90;
    AngleGradians: Result := Value / 100;
  else
    Result := Value / (Pi / 2);
  end;
end;

function ToRadians(Value: Double; Angles: TAngleUnit): Double;
begin
  case Angles of
    AngleDegrees: Result := DegToRad(Value);
    AngleGradians: Result := GradToRad(Value);
  else
    Result := Value;
  end;
end;

function FromRadians(Value: Double; Angles: TAngleUnit): Double;
begin
  case Angles of
    AngleDegrees: Result := RadToDeg(Value);
    AngleGradians: Result := RadToGrad(Value);
  else
    Result := Value;
  end;
end;

{ The whole number of quarter turns Value is (0 to 3), or -1 if it is
  not one. }
function WholeQuarterTurns(Value: Double; Angles: TAngleUnit): LongInt;
var
  Turns: Double;
  Nearest: Double;
begin
  Turns := QuarterTurnsOf(Value, Angles);
  if Abs(Turns) > 1e15 then
    Exit(-1);
  Nearest := Round(Turns);
  if Abs(Turns - Nearest) > QuarterTurnTolerance * Max(1, Abs(Nearest)) then
    Exit(-1);
  Result := LongInt(Trunc(Nearest - 4 * Floor(Nearest / 4)));
end;

function Sine(Value: Double; Angles: TAngleUnit): Double;
const
  Exact: array[0..3] of Double = (0, 1, 0, -1);
var
  Quarter: LongInt;
begin
  Quarter := WholeQuarterTurns(Value, Angles);
  if Quarter >= 0 then
    Exit(Exact[Quarter]);
  Result := Sin(ToRadians(Value, Angles));
end;

function Cosine(Value: Double; Angles: TAngleUnit): Double;
const
  Exact: array[0..3] of Double = (1, 0, -1, 0);
var
  Quarter: LongInt;
begin
  Quarter := WholeQuarterTurns(Value, Angles);
  if Quarter >= 0 then
    Exit(Exact[Quarter]);
  Result := Cos(ToRadians(Value, Angles));
end;

function Tangent(Value: Double; Angles: TAngleUnit; var Error: TCalculationError): Double;
var
  Quarter: LongInt;
begin
  Quarter := WholeQuarterTurns(Value, Angles);
  if Quarter in [1, 3] then
  begin
    Error := CalculationDomain;
    Exit(0);
  end;
  if Quarter >= 0 then
    Exit(0);
  { 45 degrees and its likes are exactly 1. }
  Quarter := WholeQuarterTurns(Value * 2, Angles);
  if Quarter in [1, 3] then
  begin
    if Quarter = 1 then
      Exit(1);
    Exit(-1);
  end;
  Result := Tan(ToRadians(Value, Angles));
end;

function Factorial(Value: Double; var Error: TCalculationError): Double;
var
  Count: LongInt;
  Index: LongInt;
begin
  Result := 1;
  if (Value < 0) or (Frac(Value) <> 0) then
  begin
    Error := CalculationDomain;
    Exit;
  end;
  if Value > LargestFactorial then
  begin
    Error := CalculationOverflow;
    Exit;
  end;
  Count := Trunc(Value);
  for Index := 2 to Count do
    Result := Result * Index;
end;

{ --- Doubles ---------------------------------------------------------------------------- }

function ApplyUnary(Operation: TUnaryFunction; Value: Double; Angles: TAngleUnit;
  var Error: TCalculationError): Double;
begin
  Result := 0;
  case Operation of
    FunctionSquareRoot:
      if Value < 0 then
        Error := CalculationDomain
      else
        Result := Sqrt(Value);
    FunctionCubeRoot:
      if Value < 0 then
        Result := -Power(-Value, 1 / 3)
      else
        Result := Power(Value, 1 / 3);
    FunctionSquare: Result := Value * Value;
    FunctionCube: Result := Value * Value * Value;
    FunctionReciprocal:
      if Value = 0 then
        Error := CalculationDivideByZero
      else
        Result := 1 / Value;
    FunctionNegate: Result := -Value;
    FunctionFactorial: Result := Factorial(Value, Error);
    FunctionSine: Result := Sine(Value, Angles);
    FunctionCosine: Result := Cosine(Value, Angles);
    FunctionTangent: Result := Tangent(Value, Angles, Error);
    FunctionArcSine, FunctionArcCosine:
      if Abs(Value) > 1 then
        Error := CalculationDomain
      else if Operation = FunctionArcSine then
        Result := FromRadians(ArcSin(Value), Angles)
      else
        Result := FromRadians(ArcCos(Value), Angles);
    FunctionArcTangent: Result := FromRadians(ArcTan(Value), Angles);
    FunctionHyperbolicSine: Result := SinH(Value);
    FunctionHyperbolicCosine: Result := CosH(Value);
    FunctionHyperbolicTangent: Result := TanH(Value);
    FunctionNaturalLog, FunctionCommonLog:
      if Value <= 0 then
        Error := CalculationDomain
      else if Operation = FunctionNaturalLog then
        Result := Ln(Value)
      else
        Result := Log10(Value);
    FunctionExponential: Result := Exp(Value);
    FunctionTenPower: Result := Power(10, Value);
    FunctionAbsolute: Result := Abs(Value);
  end;
  Result := CheckedResult(Result, Error);
end;

function RaisePower(Base, Exponent: Double; var Error: TCalculationError): Double;
begin
  Result := 0;
  if (Base = 0) and (Exponent < 0) then
  begin
    Error := CalculationDivideByZero;
    Exit;
  end;
  if (Base < 0) and (Frac(Exponent) <> 0) then
  begin
    Error := CalculationDomain;
    Exit;
  end;
  Result := Power(Base, Exponent);
end;

{ The Degree-th root of Value (an odd root of a negative number is
  negative). }
function RootOf(Value, Degree: Double; var Error: TCalculationError): Double;
var
  OddWhole: Boolean;
begin
  Result := 0;
  if Degree = 0 then
  begin
    Error := CalculationDivideByZero;
    Exit;
  end;
  OddWhole := (Frac(Degree) = 0) and (Abs(Degree) < 1e15) and Odd(Trunc(Degree));
  if Value < 0 then
  begin
    if not OddWhole then
    begin
      Error := CalculationDomain;
      Exit;
    end;
    Exit(-Power(-Value, 1 / Degree));
  end;
  Result := Power(Value, 1 / Degree);
end;

function ApplyBinary(Operation: TBinaryOperator; Left, Right: Double; var Error: TCalculationError): Double;
begin
  Result := 0;
  case Operation of
    OperatorAdd: Result := GuardedSum(Left, Right);
    OperatorSubtract: Result := GuardedSum(Left, -Right);
    OperatorMultiply: Result := Left * Right;
    OperatorDivide:
      if Right = 0 then
        Error := CalculationDivideByZero
      else
        Result := Left / Right;
    OperatorPower: Result := RaisePower(Left, Right, Error);
    OperatorRoot: Result := RootOf(Left, Right, Error);
    OperatorModulo:
      if Right = 0 then
        Error := CalculationDivideByZero
      else
        Result := Left - Right * Floor(Left / Right);
  else
    { The bit operators work on integers only. }
    Error := CalculationSyntax;
  end;
  Result := CheckedResult(Result, Error);
end;

{ --- Integers ----------------------------------------------------------------------------- }

function IntegerPower(Base, Exponent: Int64; Bits: LongInt; var Error: TCalculationError): Int64;
begin
  if Exponent < 0 then
  begin
    if Base = 0 then
      Error := CalculationDivideByZero
    else if Abs(Base) = 1 then
    begin
      if Odd(Exponent) then
        Exit(Base);
      Exit(1);
    end;
    Exit(0);
  end;
  Result := 1;
  while Exponent > 0 do
  begin
    if Odd(Exponent) then
      Result := WrapToWord(Result * Base, Bits);
    Base := WrapToWord(Base * Base, Bits);
    Exponent := Exponent shr 1;
  end;
end;

function IntegerSquareRoot(Value: Int64; var Error: TCalculationError): Int64;
begin
  if Value < 0 then
  begin
    Error := CalculationDomain;
    Exit(0);
  end;
  Result := Trunc(Sqrt(Double(Value)));
  while (Result > 0) and (Result * Result > Value) do
    Dec(Result);
  while (Result + 1) * (Result + 1) <= Value do
    Inc(Result);
end;

function ApplyIntegerUnary(Operation: TUnaryFunction; Value: Int64; Bits: LongInt;
  var Error: TCalculationError): Int64;
var
  Index: Int64;
begin
  Result := 0;
  case Operation of
    FunctionNegate: Result := -Value;
    FunctionSquare: Result := Value * Value;
    FunctionCube: Result := Value * Value * Value;
    FunctionSquareRoot: Result := IntegerSquareRoot(Value, Error);
    FunctionAbsolute: Result := Abs(Value);
    FunctionReciprocal:
      if Value = 0 then
        Error := CalculationDivideByZero
      else
        Result := 1 div Value;
    FunctionFactorial:
      if Value < 0 then
        Error := CalculationDomain
      else
      begin
        Result := 1;
        Index := 2;
        while Index <= Value do
        begin
          Result := WrapToWord(Result * Index, Bits);
          Inc(Index);
        end;
      end;
  else
    Error := CalculationSyntax;
  end;
  Result := WrapToWord(Result, Bits);
end;

function ApplyIntegerBinary(Operation: TBinaryOperator; Left, Right: Int64; Bits: LongInt;
  var Error: TCalculationError): Int64;
var
  Shift: LongInt;
begin
  Result := 0;
  case Operation of
    OperatorAdd: Result := Left + Right;
    OperatorSubtract: Result := Left - Right;
    OperatorMultiply: Result := Left * Right;
    OperatorDivide, OperatorModulo:
      if Right = 0 then
        Error := CalculationDivideByZero
      else if Operation = OperatorDivide then
        Result := Left div Right
      else
        Result := Left mod Right;
    OperatorPower: Result := IntegerPower(Left, Right, Bits, Error);
    OperatorAnd: Result := Left and Right;
    OperatorOr: Result := Left or Right;
    OperatorXor: Result := Left xor Right;
    OperatorShiftLeft, OperatorShiftRight:
      begin
        if (Right < 0) or (Right >= Bits) then
          Shift := Bits
        else
          Shift := LongInt(Right);
        if Shift >= 64 then
          Result := 0
        else if Operation = OperatorShiftLeft then
          Result := Int64(QWord(Left) shl Shift)
        else
          { Arithmetic: the sign is kept. }
          Result := SarInt64(Left, Shift);
      end;
  else
    Error := CalculationSyntax;
  end;
  Result := WrapToWord(Result, Bits);
end;

end.
