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
  What the calculator's buttons and keys do: an action each, its
  button's caption and hint, the character that types it, and carrying
  it out on the engine (Calculator.Engine).

    0-9 (A-F in hexadecimal)  digits      . or ,   point
    + - * / ^                 operators   ( )      parentheses
    % ! =                     percent, factorial, equals
    @ sqrt   q square   r reciprocal   p pi   s sin   o cos   t tan
    l log   n ln   & and   | or   x xor (not in hexadecimal)   ~ not
    < lsh   > rsh   m mod

  Enter (the numpad's too), Escape, Delete, Backspace and F9 (negate)
  are keys rather than characters; the window maps those.

  Plain logic: the host checks it (make apps-test).
}
unit Calculator.Actions;

{$mode objfpc}
{$H+}

interface

uses
  Calculator.Engine;

type
  TCalculatorAction = (ActionNone,
    ActionDigit0, ActionDigit1, ActionDigit2, ActionDigit3, ActionDigit4, ActionDigit5, ActionDigit6,
    ActionDigit7, ActionDigit8, ActionDigit9, ActionDigitA, ActionDigitB, ActionDigitC, ActionDigitD,
    ActionDigitE, ActionDigitF,
    ActionPoint, ActionAdd, ActionSubtract, ActionMultiply, ActionDivide, ActionPower, ActionRoot, ActionModulo,
    ActionAnd, ActionOr, ActionXor, ActionShiftLeft, ActionShiftRight, ActionNot,
    ActionOpen, ActionClose, ActionEquals, ActionPercent, ActionNegate,
    ActionSquareRoot, ActionSquare, ActionCube, ActionCubeRoot, ActionReciprocal, ActionFactorial,
    ActionSine, ActionCosine, ActionTangent, ActionArcSine, ActionArcCosine, ActionArcTangent,
    ActionSinh, ActionCosh, ActionTanh, ActionNaturalLog, ActionCommonLog, ActionExponential, ActionTenPower,
    ActionAbsolute, ActionPi, ActionEuler,
    ActionBackspace, ActionClearEntry, ActionClear,
    ActionMemoryClear, ActionMemoryRecall, ActionMemoryStore, ActionMemoryAdd, ActionMemorySubtract);

const
  ActionCaptions: array[TCalculatorAction] of string = ('',
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
    '.', '+', #$E2#$88#$92, #$C3#$97, #$C3#$B7, 'x^y', 'y' + #$E2#$88#$9A + 'x', 'Mod',
    'And', 'Or', 'Xor', 'Lsh', 'Rsh', 'Not',
    '(', ')', '=', '%', '+/' + #$E2#$88#$92,
    #$E2#$88#$9A + 'x', 'x' + #$C2#$B2, 'x' + #$C2#$B3, #$E2#$88#$9B + 'x', '1/x', 'n!',
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan',
    'sinh', 'cosh', 'tanh', 'ln', 'log', 'e^x', '10^x',
    '|x|', #$CF#$80, 'e',
    #$E2#$8C#$AB, 'CE', 'C',
    'MC', 'MR', 'MS', 'M+', 'M' + #$E2#$88#$92);

  ActionHints: array[TCalculatorAction] of string = ('',
    '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
    'Decimal point', 'Add', 'Subtract', 'Multiply', 'Divide', 'Power (^)', 'Root of degree y', 'Modulo (m)',
    'Bitwise and (&)', 'Bitwise or (|)', 'Bitwise exclusive or', 'Shift left (<)', 'Shift right (>)',
    'Bitwise not (~)',
    'Open parenthesis', 'Close parenthesis', 'Equals (Enter)', 'Percent', 'Change sign (F9)',
    'Square root (@)', 'Square (q)', 'Cube', 'Cube root', 'Reciprocal (r)', 'Factorial (!)',
    'Sine (s)', 'Cosine (o)', 'Tangent (t)', 'Arcsine', 'Arccosine', 'Arctangent',
    'Hyperbolic sine', 'Hyperbolic cosine', 'Hyperbolic tangent', 'Natural logarithm (n)',
    'Logarithm, base 10 (l)', 'e to the power', 'Ten to the power',
    'Absolute value', 'Pi (p)', 'Euler''s number',
    'Backspace', 'Clear entry (Delete)', 'Clear (Escape)',
    'Memory clear', 'Memory recall', 'Memory store', 'Memory add', 'Memory subtract');

{ The action a typed character stands for (in Mode and Base), or
  ActionNone. }
function ActionForCharacter(Character: LongWord; Mode: TCalculatorMode; Base: LongInt): TCalculatorAction;
{ Whether Action means anything in Mode (a disabled button if not). }
function ActionAvailable(Action: TCalculatorAction; Mode: TCalculatorMode; Base: LongInt): Boolean;
procedure PerformAction(Engine: TCalculatorEngine; Action: TCalculatorAction);
{ Performs the action of each character of Keys in turn ("12*(3+4)="). }
procedure TypeKeys(Engine: TCalculatorEngine; const Keys: string);

implementation

uses
  Calculator.MathFunctions;

function DigitAction(Digit: LongInt): TCalculatorAction;
begin
  Result := TCalculatorAction(Ord(ActionDigit0) + Digit);
end;

function ActionForCharacter(Character: LongWord; Mode: TCalculatorMode; Base: LongInt): TCalculatorAction;
var
  Hexadecimal: Boolean;
begin
  Hexadecimal := (Mode = ModeProgrammer) and (Base = 16);
  if (Character >= Ord('0')) and (Character <= Ord('9')) then
    Exit(DigitAction(LongInt(Character) - Ord('0')));
  if Hexadecimal then
  begin
    if (Character >= Ord('a')) and (Character <= Ord('f')) then
      Exit(DigitAction(LongInt(Character) - Ord('a') + 10));
    if (Character >= Ord('A')) and (Character <= Ord('F')) then
      Exit(DigitAction(LongInt(Character) - Ord('A') + 10));
  end;
  case Character of
    Ord('.'), Ord(','): Result := ActionPoint;
    Ord('+'): Result := ActionAdd;
    Ord('-'): Result := ActionSubtract;
    Ord('*'): Result := ActionMultiply;
    Ord('/'): Result := ActionDivide;
    Ord('^'): Result := ActionPower;
    Ord('('): Result := ActionOpen;
    Ord(')'): Result := ActionClose;
    Ord('='): Result := ActionEquals;
    Ord('%'): Result := ActionPercent;
    Ord('!'): Result := ActionFactorial;
    Ord('@'): Result := ActionSquareRoot;
    Ord('q'): Result := ActionSquare;
    Ord('r'): Result := ActionReciprocal;
    Ord('p'): Result := ActionPi;
    Ord('s'): Result := ActionSine;
    Ord('o'): Result := ActionCosine;
    Ord('t'): Result := ActionTangent;
    Ord('l'): Result := ActionCommonLog;
    Ord('n'): Result := ActionNaturalLog;
    Ord('m'): Result := ActionModulo;
    Ord('&'): Result := ActionAnd;
    Ord('|'): Result := ActionOr;
    Ord('x'): Result := ActionXor;
    Ord('~'): Result := ActionNot;
    Ord('<'): Result := ActionShiftLeft;
    Ord('>'): Result := ActionShiftRight;
  else
    Result := ActionNone;
  end;
  if not ActionAvailable(Result, Mode, Base) then
    Result := ActionNone;
end;

function ActionAvailable(Action: TCalculatorAction; Mode: TCalculatorMode; Base: LongInt): Boolean;
begin
  case Action of
    ActionNone: Result := False;
    ActionDigit0..ActionDigitF:
      if Mode = ModeProgrammer then
        Result := Ord(Action) - Ord(ActionDigit0) < Base
      else
        Result := Ord(Action) - Ord(ActionDigit0) < 10;
    ActionAnd, ActionOr, ActionXor, ActionShiftLeft, ActionShiftRight, ActionNot:
      Result := Mode = ModeProgrammer;
    ActionPoint, ActionPercent, ActionPi, ActionEuler, ActionCubeRoot, ActionRoot, ActionSine..ActionTenPower:
      Result := Mode <> ModeProgrammer;
    ActionPower, ActionModulo, ActionFactorial, ActionOpen, ActionClose, ActionCube, ActionAbsolute:
      Result := Mode <> ModeStandard;
  else
    Result := True;
  end;
  { Standard keeps a few of the scientific ones off the keyboard too. }
  if (Mode = ModeStandard) and (Action in [ActionPi, ActionEuler, ActionCubeRoot, ActionRoot,
     ActionSine..ActionTenPower]) then
    Result := False;
  { Parentheses work from the keyboard in every mode. }
  if Action in [ActionOpen, ActionClose] then
    Result := True;
end;

procedure PerformAction(Engine: TCalculatorEngine; Action: TCalculatorAction);
begin
  case Action of
    ActionDigit0..ActionDigitF: Engine.TypeDigit(Ord(Action) - Ord(ActionDigit0));
    ActionPoint: Engine.TypePoint;
    ActionAdd: Engine.ApplyOperator(OperatorAdd);
    ActionSubtract: Engine.ApplyOperator(OperatorSubtract);
    ActionMultiply: Engine.ApplyOperator(OperatorMultiply);
    ActionDivide: Engine.ApplyOperator(OperatorDivide);
    ActionPower: Engine.ApplyOperator(OperatorPower);
    ActionRoot: Engine.ApplyOperator(OperatorRoot);
    ActionModulo: Engine.ApplyOperator(OperatorModulo);
    ActionAnd: Engine.ApplyOperator(OperatorAnd);
    ActionOr: Engine.ApplyOperator(OperatorOr);
    ActionXor: Engine.ApplyOperator(OperatorXor);
    ActionShiftLeft: Engine.ApplyOperator(OperatorShiftLeft);
    ActionShiftRight: Engine.ApplyOperator(OperatorShiftRight);
    ActionNot: Engine.BitwiseNot;
    ActionOpen: Engine.OpenParenthesis;
    ActionClose: Engine.CloseParenthesis;
    ActionEquals: Engine.ComputeResult;
    ActionPercent: Engine.Percent;
    ActionNegate: Engine.Negate;
    ActionSquareRoot: Engine.ApplyFunction(FunctionSquareRoot);
    ActionSquare: Engine.ApplyFunction(FunctionSquare);
    ActionCube: Engine.ApplyFunction(FunctionCube);
    ActionCubeRoot: Engine.ApplyFunction(FunctionCubeRoot);
    ActionReciprocal: Engine.ApplyFunction(FunctionReciprocal);
    ActionFactorial: Engine.ApplyFunction(FunctionFactorial);
    ActionSine: Engine.ApplyFunction(FunctionSine);
    ActionCosine: Engine.ApplyFunction(FunctionCosine);
    ActionTangent: Engine.ApplyFunction(FunctionTangent);
    ActionArcSine: Engine.ApplyFunction(FunctionArcSine);
    ActionArcCosine: Engine.ApplyFunction(FunctionArcCosine);
    ActionArcTangent: Engine.ApplyFunction(FunctionArcTangent);
    ActionSinh: Engine.ApplyFunction(FunctionHyperbolicSine);
    ActionCosh: Engine.ApplyFunction(FunctionHyperbolicCosine);
    ActionTanh: Engine.ApplyFunction(FunctionHyperbolicTangent);
    ActionNaturalLog: Engine.ApplyFunction(FunctionNaturalLog);
    ActionCommonLog: Engine.ApplyFunction(FunctionCommonLog);
    ActionExponential: Engine.ApplyFunction(FunctionExponential);
    ActionTenPower: Engine.ApplyFunction(FunctionTenPower);
    ActionAbsolute: Engine.ApplyFunction(FunctionAbsolute);
    ActionPi: Engine.InsertPi;
    ActionEuler: Engine.InsertEuler;
    ActionBackspace: Engine.Backspace;
    ActionClearEntry: Engine.ClearEntry;
    ActionClear: Engine.ClearAll;
    ActionMemoryClear: Engine.MemoryClear;
    ActionMemoryRecall: Engine.MemoryRecall;
    ActionMemoryStore: Engine.MemoryStore;
    ActionMemoryAdd: Engine.MemoryAdd;
    ActionMemorySubtract: Engine.MemorySubtract;
  end;
end;

procedure TypeKeys(Engine: TCalculatorEngine; const Keys: string);
var
  Index: LongInt;
begin
  for Index := 1 to Length(Keys) do
    PerformAction(Engine, ActionForCharacter(Ord(Keys[Index]), Engine.Mode, Engine.Base));
end;

end.
