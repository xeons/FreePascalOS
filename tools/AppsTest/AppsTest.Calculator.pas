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
  AppsTest: the calculator's numbers, arithmetic, expressions and keys.
}
unit AppsTest.Calculator;

{$mode objfpc}
{$H+}

interface

procedure TestCalculator;

implementation

uses
  SysUtils,
  AppsTest.Checks,
  Calculator.Numbers,
  Calculator.MathFunctions,
  Calculator.Expressions,
  Calculator.Engine,
  Calculator.Actions;

procedure TestFormatting;
var
  Value: Double;
begin
  CheckText('zero', FormatCalculatorNumber(0), '0');
  CheckText('a whole number', FormatCalculatorNumber(84), '84');
  CheckText('negative', FormatCalculatorNumber(-12.5), '-12.5');
  CheckText('0.1 + 0.2 shows 0.3', FormatCalculatorNumber(0.1 + 0.2), '0.3');
  CheckText('1 / 3', FormatCalculatorNumber(1 / 3), '0.333333333333333');
  CheckText('2 / 3 rounds the last digit', FormatCalculatorNumber(2 / 3), '0.666666666666667');
  CheckText('large numbers take an exponent', FormatCalculatorNumber(1.5e20), '1.5e+20');
  CheckText('fifteen digits stay plain', FormatCalculatorNumber(123456789012345), '123456789012345');
  CheckText('sixteen take an exponent', FormatCalculatorNumber(1234567890123456), '1.23456789012346e+15');
  CheckText('small numbers stay plain to 1e-9', FormatCalculatorNumber(0.000000001), '0.000000001');
  CheckText('smaller take an exponent', FormatCalculatorNumber(1.25e-12), '1.25e-12');
  Check('the text shown is read back', ParseCalculatorNumber('1.5e+20', Value) and (Value = 1.5e20));
  Check('typed text with a trailing point', ParseCalculatorNumber('3.', Value) and (Value = 3));
  Check('not a number', not ParseCalculatorNumber('12a', Value));
  Value := 0.3;
  Check('rounded to what is shown', RoundToShown(0.1 + 0.2) = Value);
end;

procedure TestIntegers;
var
  Whole: Int64;
begin
  CheckNumber('a byte wraps 200 to -56', WrapToWord(200, 8), -56);
  CheckNumber('a word keeps 65535 as -1', WrapToWord(65535, 16), -1);
  CheckText('hexadecimal', FormatInBase(255, 16, 64), 'FF');
  CheckText('a negative byte in hexadecimal', FormatInBase(-1, 16, 8), 'FF');
  CheckText('binary in groups of four', FormatInBase(37, 2, 8), '10 0101');
  CheckText('octal', FormatInBase(8, 8, 32), '10');
  CheckText('decimal is signed', FormatInBase(255, 10, 8), '-1');
  Check('hexadecimal read back', ParseInBase('ff', 16, 64, Whole) and (Whole = 255));
  Check('binary with spaces', ParseInBase('10 0101', 2, 64, Whole) and (Whole = 37));
  Check('a digit outside the base', not ParseInBase('19', 8, 64, Whole));
  Check('too large for 64 bits', not ParseInBase('1FFFFFFFFFFFFFFFF', 16, 64, Whole));
end;

procedure TestArithmetic;
var
  Error: TCalculationError;
  Value: Double;
begin
  Error := CalculationOk;
  Value := ApplyBinary(OperatorDivide, 1, 0, Error);
  Check('division by zero is an error', Error = CalculationDivideByZero);
  Error := CalculationOk;
  ApplyUnary(FunctionSquareRoot, -4, AngleDegrees, Error);
  Check('the square root of a negative number', Error = CalculationDomain);
  Error := CalculationOk;
  ApplyUnary(FunctionTangent, 90, AngleDegrees, Error);
  Check('the tangent of 90 degrees', Error = CalculationDomain);
  Error := CalculationOk;
  ApplyUnary(FunctionNaturalLog, 0, AngleDegrees, Error);
  Check('the logarithm of 0', Error = CalculationDomain);
  Error := CalculationOk;
  ApplyUnary(FunctionFactorial, 171, AngleDegrees, Error);
  Check('171! overflows', Error = CalculationOverflow);
  Error := CalculationOk;
  Check('the sine of 180 degrees is exactly 0', ApplyUnary(FunctionSine, 180, AngleDegrees, Error) = 0);
  Check('the cosine of 90 degrees is exactly 0', ApplyUnary(FunctionCosine, 90, AngleDegrees, Error) = 0);
  Check('the sine of pi radians is exactly 0', ApplyUnary(FunctionSine, Pi, AngleRadians, Error) = 0);
  Check('the tangent of 45 degrees is exactly 1', ApplyUnary(FunctionTangent, 45, AngleDegrees, Error) = 1);
  Check('the sine of 100 gradians is 1', ApplyUnary(FunctionSine, 100, AngleGradians, Error) = 1);
  CheckNear('the sine of 30 degrees', ApplyUnary(FunctionSine, 30, AngleDegrees, Error), 0.5, 1e-15);
  CheckNear('arcsine in degrees', ApplyUnary(FunctionArcSine, 1, AngleDegrees, Error), 90, 1e-12);
  Check('0.3 - 0.1 - 0.2 is exactly 0',
    ApplyBinary(OperatorSubtract, ApplyBinary(OperatorSubtract, 0.3, 0.1, Error), 0.2, Error) = 0);
  Check('5! is 120', ApplyUnary(FunctionFactorial, 5, AngleDegrees, Error) = 120);
  Check('the cube root of -27 is -3', Abs(ApplyBinary(OperatorRoot, -27, 3, Error) + 3) < 1e-12);
  Check('no error in all of those', Error = CalculationOk);
  Check('(unused)', Value = 0);
end;

function Evaluated(const Text: string; Order: TEvaluationOrder): string;
var
  Settings: TEvaluationSettings;
  Value: Double;
  Error: TCalculationError;
begin
  Settings := DefaultEvaluationSettings;
  Settings.Order := Order;
  if EvaluateToReal(Text, Settings, Value, Error) then
    Result := FormatCalculatorNumber(RoundToShown(Value))
  else
    Result := 'error: ' + CalculationErrorTexts[Error];
end;

function EvaluatedWhole(const Text: string; Bits: LongInt): string;
var
  Settings: TEvaluationSettings;
  Value: TCalculatorValue;
  Error: TCalculationError;
begin
  Settings := DefaultEvaluationSettings;
  Settings.Integers := True;
  Settings.WordBits := Bits;
  if EvaluateExpression(Text, Settings, Value, Error) then
    Result := IntToStr(Value.Whole)
  else
    Result := 'error: ' + CalculationErrorTexts[Error];
end;

procedure TestExpressions;
begin
  CheckText('precedence', Evaluated('2+3*4', OrderPrecedence), '14');
  CheckText('left to right (standard)', Evaluated('2+3*4', OrderLeftToRight), '20');
  CheckText('parentheses', Evaluated('12*(3+4)', OrderPrecedence), '84');
  CheckText('parentheses left to right', Evaluated('12*(3+4)', OrderLeftToRight), '84');
  CheckText('nested parentheses', Evaluated('((1+2)*(3+4))/7', OrderPrecedence), '3');
  CheckText('open parentheses close at the end', Evaluated('2*(3+4', OrderPrecedence), '14');
  CheckText('powers go right to left', Evaluated('2^3^2', OrderPrecedence), '512');
  CheckText('a sign binds more loosely than a power', Evaluated('-2^2', OrderPrecedence), '-4');
  CheckText('a negative exponent', Evaluated('2^-1', OrderPrecedence), '0.5');
  CheckText('functions', Evaluated('sqrt(16)+sin(30)', OrderPrecedence), '4.5');
  CheckText('pi and e', Evaluated('pi*e', OrderPrecedence), '8.53973422267357');
  CheckText('factorial', Evaluated('5!+1', OrderPrecedence), '121');
  CheckText('multiply and divide signs', Evaluated('6' + #$C3#$97 + '7' + #$C3#$B7 + '2', OrderPrecedence), '21');
  CheckText('exponents in numbers', Evaluated('1.5e+3*2', OrderPrecedence), '3000');
  CheckText('modulo', Evaluated('17 mod 5', OrderPrecedence), '2');
  CheckText('division by zero', Evaluated('1/(2-2)', OrderPrecedence), 'error: Cannot divide by zero');
  CheckText('a syntax error', Evaluated('2+*3', OrderPrecedence), 'error: Invalid input');
  CheckText('an unknown function', Evaluated('foo(2)', OrderPrecedence), 'error: Invalid input');
  CheckText('an unmatched close parenthesis', Evaluated('2)', OrderPrecedence), 'error: Invalid input');
  CheckText('0.1+0.2', Evaluated('0.1+0.2', OrderPrecedence), '0.3');
  CheckText('integers: bit operators by precedence', EvaluatedWhole('1 or 6 and 3', 64), '3');
  CheckText('integers: shifts', EvaluatedWhole('1 lsh 4 + 1', 64), '32');
  CheckText('integers: division towards zero', EvaluatedWhole('-7/2', 64), '-3');
  CheckText('integers: a byte wraps', EvaluatedWhole('127+1', 8), '-128');
  CheckText('integers: not', EvaluatedWhole('not(0)', 16), '-1');
  CheckText('integers: division by zero', EvaluatedWhole('1/0', 32), 'error: Cannot divide by zero');
end;

function Typed(const Keys: string; Mode: TCalculatorMode): string;
var
  Engine: TCalculatorEngine;
begin
  Engine := TCalculatorEngine.Create;
  try
    Engine.Mode := Mode;
    TypeKeys(Engine, Keys);
    Result := Engine.DisplayText;
  finally
    Engine.Free;
  end;
end;

procedure TestEngine;
var
  Engine: TCalculatorEngine;
begin
  CheckText('keys: 12*(3+4)= (standard)', Typed('12*(3+4)=', ModeStandard), '84');
  CheckText('keys: 12*(3+4)= (scientific)', Typed('12*(3+4)=', ModeScientific), '84');
  CheckText('keys: standard is left to right', Typed('2+3*4=', ModeStandard), '20');
  CheckText('keys: scientific by precedence', Typed('2+3*4=', ModeScientific), '14');
  CheckText('keys: a running total in standard', Typed('2+3*', ModeStandard), '5');
  CheckText('keys: equals again repeats', Typed('5+3==', ModeStandard), '11');
  CheckText('keys: an operator replaces the last', Typed('5+*2=', ModeStandard), '10');
  CheckText('keys: 5+= uses the value shown', Typed('5+=', ModeStandard), '10');
  CheckText('keys: percent of the number before +', Typed('50+10%=', ModeStandard), '55');
  CheckText('keys: percent after times', Typed('50*10%=', ModeStandard), '5');
  CheckText('keys: division by zero', Typed('7/0=', ModeStandard), 'Cannot divide by zero');
  CheckText('keys: a digit after an error starts again', Typed('7/0=3', ModeStandard), '3');
  CheckText('keys: the square root shows at once', Typed('9@', ModeStandard), '3');
  CheckText('keys: a function within an expression', Typed('1+9@=', ModeStandard), '4');
  CheckText('keys: the square root of a negative number', Typed('4-9=@', ModeStandard), 'Invalid input');
  CheckText('keys: the reciprocal of 0', Typed('0r', ModeStandard), 'Cannot divide by zero');
  CheckText('keys: the point', Typed('1.5*2=', ModeStandard), '3');
  CheckText('keys: one point only', Typed('1..5', ModeStandard), '1.5');
  CheckText('keys: leading zeros dropped', Typed('007', ModeStandard), '7');
  CheckText('keys: 0.1+0.2=', Typed('.1+.2=', ModeStandard), '0.3');
  CheckText('keys: factorial (scientific)', Typed('5!', ModeScientific), '120');
  CheckText('keys: sin 30 in degrees', Typed('30s', ModeScientific), '0.5');
  CheckText('keys: a number before ( multiplies', Typed('2(3)=', ModeScientific), '6');
  CheckText('keys: pi', Typed('p', ModeScientific), '3.14159265358979');
  CheckText('keys: power', Typed('2^10=', ModeScientific), '1024');
  CheckText('keys: digits are limited', Typed('12345678901234567890', ModeStandard), '1234567890123456');
  Engine := TCalculatorEngine.Create;
  try
    TypeKeys(Engine, '12*(3+4)=');
    CheckText('the expression shown after equals', Engine.ExpressionText, '12 ' + #$C3#$97 + ' (3 + 4) =');
    CheckNumber('the history has it', Engine.HistoryCount, 1);
    CheckText('the history''s result', Engine.History[0].Result, '84');
    TypeKeys(Engine, '123');
    Engine.Backspace;
    CheckText('backspace takes back a digit', Engine.DisplayText, '12');
    Engine.Negate;
    CheckText('negate while typing', Engine.DisplayText, '-12');
    Engine.MemoryStore;
    Engine.ClearAll;
    Engine.MemoryRecall;
    CheckText('memory store and recall', Engine.DisplayText, '-12');
    TypeKeys(Engine, '+2=');
    Engine.MemoryAdd;
    Engine.MemoryRecall;
    CheckText('memory add', Engine.DisplayText, '-22');
    Engine.ClearEntry;
    CheckText('clear entry', Engine.DisplayText, '0');
    Check('a pasted number', Engine.Paste('42.5'));
    CheckText('the pasted number is shown', Engine.DisplayText, '42.5');
    Check('a pasted expression', Engine.Paste('2*(3+4)'));
    CheckText('the pasted expression''s value', Engine.DisplayText, '14');
    Check('pasted words are refused', not Engine.Paste('hello'));
    Engine.RecallHistory(0);
    CheckText('a history entry recalled', Engine.DisplayText, '84');
    CheckText('copy gives the number shown', Engine.CopyText, '84');
    Engine.Mode := ModeProgrammer;
    Engine.Base := 16;
    TypeKeys(Engine, 'ff+1=');
    CheckText('programmer: hexadecimal', Engine.DisplayText, '100');
    Engine.Base := 2;
    CheckText('programmer: shown in binary', Engine.DisplayText, '1 0000 0000');
    Engine.WordBits := 8;
    CheckText('programmer: a byte keeps the low bits', Engine.DisplayText, '0');
    Engine.Base := 10;
    TypeKeys(Engine, '100+100=');
    CheckText('programmer: a byte wraps', Engine.DisplayText, '-56');
    TypeKeys(Engine, '6&3=');
    CheckText('programmer: and', Engine.DisplayText, '2');
    Engine.BitwiseNot;
    CheckText('programmer: not', Engine.DisplayText, '-3');
    TypeKeys(Engine, '7/2=');
    CheckText('programmer: integer division', Engine.DisplayText, '3');
  finally
    Engine.Free;
  end;
end;

procedure TestCalculator;
begin
  TestFormatting;
  TestIntegers;
  TestArithmetic;
  TestExpressions;
  TestEngine;
end;

end.
