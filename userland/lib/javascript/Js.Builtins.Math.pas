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
  Math: the constants and functions. Math.random is xorshift128+,
  seeded from the clock when the realm is made.
}
unit Js.Builtins.Math;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.ArrayBuffers,
  Js.Bytecode,
  Js.Interpreter;

procedure InstallMath(R: TJsInterpreterRealm);

implementation

var
  RandomState0: QWord = QWord($9E3779B97F4A7C15);
  RandomState1: QWord = QWord($BF58476D1CE4E5B9);

function NextRandom: Double;
var
  S0, S1: QWord;
begin
  S1 := RandomState0;
  S0 := RandomState1;
  RandomState0 := S0;
  S1 := S1 xor (S1 shl 23);
  RandomState1 := S1 xor S0 xor (S1 shr 17) xor (S0 shr 26);
  Result := ((RandomState1 + S0) shr 11) * (1.0 / 9007199254740992.0);
end;

const
  FnAbs = 0; FnAcos = 1; FnAcosh = 2; FnAsin = 3; FnAsinh = 4; FnAtan = 5; FnAtanh = 6; FnCbrt = 7;
  FnCeil = 8; FnCos = 9; FnCosh = 10; FnExp = 11; FnExpm1 = 12; FnFloor = 13; FnFround = 14; FnLog = 15;
  FnLog1p = 16; FnLog10 = 17; FnLog2 = 18; FnRound = 19; FnSign = 20; FnSin = 21; FnSinh = 22; FnSqrt = 23;
  FnTan = 24; FnTanh = 25; FnTrunc = 26; FnClz32 = 27; FnF16round = 28;

function RoundHalfUp(X: Double): Double;
var
  Lower: Double;
begin
  if IsNaNDouble(X) or not IsFiniteDouble(X) or (X = 0) then
    Exit(X);
  if (X > -0.5) and (X < 0) then
    Exit(-0.0);
  if Abs(X) >= 4503599627370496.0 then
    Exit(X);
  Lower := FloorDouble(X);
  if X - Lower >= 0.5 then
    Result := Lower + 1
  else
    Result := Lower;
  if (Result = 0) and (X < 0) then
    Result := -0.0;
end;

function MathUnary(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  X: Double;
  Unsigned: LongWord;
  Count: Integer;
begin
  if (Callee.Magic in [FnAbs, FnFloor, FnCeil, FnTrunc, FnRound, FnSign]) and (ArgCount > 0) and
    JsIsInteger(Args^[0]) then
  begin
    case Callee.Magic of
      FnAbs:
        if JsAsInteger(Args^[0]) >= 0 then
          Exit(Args^[0])
        else
          Exit(JsNumber(-Double(JsAsInteger(Args^[0]))));
      FnSign:
        if JsAsInteger(Args^[0]) > 0 then
          Exit(JsInteger(1))
        else if JsAsInteger(Args^[0]) < 0 then
          Exit(JsInteger(-1))
        else
          Exit(JsInteger(0));
    else
      Exit(Args^[0]);
    end;
  end;
  if not ToDouble(R, Arg(Args, ArgCount, 0), X) then
    Exit(JsException);
  case Callee.Magic of
    FnAbs: Result := JsNumber(Abs(X));
    FnAcos:
      if (X < -1) or (X > 1) or IsNaNDouble(X) then
        Result := JsNaN
      else
        Result := JsNumber(ArcCos(X));
    FnAcosh:
      if (X < 1) or IsNaNDouble(X) then
        Result := JsNaN
      else
        Result := JsNumber(ArcCosh(X));
    FnAsin:
      if (X < -1) or (X > 1) or IsNaNDouble(X) then
        Result := JsNaN
      else
        Result := JsNumber(ArcSin(X));
    FnAsinh:
      if X = 0 then
        Result := JsDouble(X)
      else
        Result := JsNumber(ArcSinh(X));
    FnAtan: Result := JsNumber(ArcTan(X));
    FnAtanh:
      if (X < -1) or (X > 1) or IsNaNDouble(X) then
        Result := JsNaN
      else if X = 1 then
        Result := JsDouble(Infinity)
      else if X = -1 then
        Result := JsDouble(NegInfinity)
      else
        Result := JsNumber(ArcTanh(X));
    FnCbrt:
      if (X = 0) or IsNaNDouble(X) or not IsFiniteDouble(X) then
        Result := JsDouble(X)
      else if X < 0 then
        Result := JsNumber(-Power(-X, Double(1) / 3))
      else
        Result := JsNumber(Power(X, Double(1) / 3));
    FnCeil:
      if IsNaNDouble(X) or not IsFiniteDouble(X) or (X = 0) then
        Result := JsDouble(X)
      else if (X < 0) and (X > -1) then
        Result := JsDouble(-0.0)
      else
        Result := JsNumber(CeilDouble(X));
    FnCos: Result := JsNumber(Cos(X));
    FnCosh: Result := JsNumber(Cosh(X));
    FnExp:
      if IsNaNDouble(X) then
        Result := JsNaN
      else if X = NegInfinity then
        Result := JsInteger(0)
      else
        Result := JsNumber(Exp(X));
    FnExpm1:
      if X = 0 then
        Result := JsDouble(X)
      else if Abs(X) < 1e-5 then
        Result := JsNumber(X + X * X / 2 + X * X * X / 6)
      else
        Result := JsNumber(Exp(X) - 1);
    FnFloor:
      if IsNaNDouble(X) or not IsFiniteDouble(X) or (X = 0) then
        Result := JsDouble(X)
      else
        Result := JsNumber(FloorDouble(X));
    FnFround: Result := JsDouble(Single(X));
    FnF16round: Result := JsNumber(HalfToDouble(DoubleToHalf(X)));
    FnLog:
      if IsNaNDouble(X) or (X < 0) then
        Result := JsNaN
      else if X = 0 then
        Result := JsDouble(NegInfinity)
      else
        Result := JsNumber(Ln(X));
    FnLog1p:
      if IsNaNDouble(X) or (X < -1) then
        Result := JsNaN
      else if X = -1 then
        Result := JsDouble(NegInfinity)
      else if X = 0 then
        Result := JsDouble(X)
      else if Abs(X) < 1e-5 then
        Result := JsNumber(X - X * X / 2 + X * X * X / 3)
      else
        Result := JsNumber(Ln(1 + X));
    FnLog10:
      if IsNaNDouble(X) or (X < 0) then
        Result := JsNaN
      else if X = 0 then
        Result := JsDouble(NegInfinity)
      else
        Result := JsNumber(Log10(X));
    FnLog2:
      if IsNaNDouble(X) or (X < 0) then
        Result := JsNaN
      else if X = 0 then
        Result := JsDouble(NegInfinity)
      else
        Result := JsNumber(Log2(X));
    FnRound: Result := JsNumber(RoundHalfUp(X));
    FnSign:
      if IsNaNDouble(X) or (X = 0) then
        Result := JsDouble(X)
      else if X > 0 then
        Result := JsInteger(1)
      else
        Result := JsInteger(-1);
    FnSin:
      if X = 0 then
        Result := JsDouble(X)
      else
        Result := JsNumber(Sin(X));
    FnSinh:
      if X = 0 then
        Result := JsDouble(X)
      else
        Result := JsNumber(Sinh(X));
    FnSqrt:
      if IsNaNDouble(X) or (X < 0) then
        Result := JsNaN
      else
        Result := JsDouble(Sqrt(X));
    FnTan:
      if X = 0 then
        Result := JsDouble(X)
      else
        Result := JsNumber(Tan(X));
    FnTanh:
      if X = 0 then
        Result := JsDouble(X)
      else if X > 20 then
        Result := JsInteger(1)
      else if X < -20 then
        Result := JsInteger(-1)
      else
        Result := JsNumber(Tanh(X));
    FnTrunc:
      if IsNaNDouble(X) or not IsFiniteDouble(X) or (X = 0) then
        Result := JsDouble(X)
      else if (X < 0) and (X > -1) then
        Result := JsDouble(-0.0)
      else
        Result := JsNumber(Int(X));
    FnClz32:
      begin
        Unsigned := DoubleToUint32(X);
        Count := 0;
        if Unsigned = 0 then
          Exit(JsInteger(32));
        while (Unsigned and $80000000) = 0 do
        begin
          Inc(Count);
          Unsigned := Unsigned shl 1;
        end;
        Result := JsInteger(Count);
      end;
  else
    Result := JsNaN;
  end;
end;

{ max (0), min (1) }
function MathMax(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Best, X: Double;
  Index: Integer;
  SawNaN: Boolean;
begin
  if Callee.Magic = 0 then
    Best := NegInfinity
  else
    Best := Infinity;
  SawNaN := False;
  for Index := 0 to ArgCount - 1 do
  begin
    if not ToDouble(R, Args^[Index], X) then
      Exit(JsException);
    if IsNaNDouble(X) then
      SawNaN := True
    else if Callee.Magic = 0 then
    begin
      if (X > Best) or ((X = 0) and (Best = 0) and (DoubleBits(Best) <> 0)) then
        Best := X;
    end
    else if (X < Best) or ((X = 0) and (Best = 0) and (DoubleBits(X) <> 0)) then
      Best := X;
  end;
  if SawNaN then
    Exit(JsNaN);
  Result := JsNumber(Best);
end;

function MathPow(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := Arithmetic(R, opExponent, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1));
end;

function MathAtan2(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Y, X: Double;
begin
  if not ToDouble(R, Arg(Args, ArgCount, 0), Y) or not ToDouble(R, Arg(Args, ArgCount, 1), X) then
    Exit(JsException);
  Result := JsNumber(ArcTan2(Y, X));
end;

function MathHypot(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Sum, X, Largest: Double;
  Index: Integer;
  Values: array of Double;
  SawInfinity, SawNaN: Boolean;
begin
  Values := nil;
  SetLength(Values, ArgCount);
  SawInfinity := False;
  SawNaN := False;
  Largest := 0;
  for Index := 0 to ArgCount - 1 do
  begin
    if not ToDouble(R, Args^[Index], X) then
      Exit(JsException);
    Values[Index] := Abs(X);
    if not IsFiniteDouble(X) and not IsNaNDouble(X) then
      SawInfinity := True;
    if IsNaNDouble(X) then
      SawNaN := True;
    if Values[Index] > Largest then
      Largest := Values[Index];
  end;
  if SawInfinity then
    Exit(JsDouble(Infinity));
  if SawNaN then
    Exit(JsNaN);
  if Largest = 0 then
    Exit(JsInteger(0));
  Sum := 0;
  for Index := 0 to ArgCount - 1 do
    Sum := Sum + Sqr(Values[Index] / Largest);
  Result := JsNumber(Sqrt(Sum) * Largest);
end;

function MathImul(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  A, B: LongInt;
begin
  if not ToInt32(R, Arg(Args, ArgCount, 0), A) or not ToInt32(R, Arg(Args, ArgCount, 1), B) then
    Exit(JsException);
  Result := JsInteger(LongInt(LongWord(A) * LongWord(B)));
end;

function MathRandom(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsDouble(NextRandom);
end;

procedure InstallMath(R: TJsInterpreterRealm);
var
  MathObject: TJsObject;

  procedure Unary(const Name: string; Code: Integer);
  begin
    DefineMethod(R, MathObject, Name, @MathUnary, 1, Code);
  end;

begin
  RandomState0 := RandomState0 xor QWord(Trunc(Now * 86400000.0));
  NextRandom;
  MathObject := R.NewPlainObject;
  DefineValue(R, R.GlobalObject, 'Math', JsObjectValue(MathObject));
  DefineValue(R, MathObject, 'E', JsDouble(2.718281828459045), 0);
  DefineValue(R, MathObject, 'LN10', JsDouble(2.302585092994046), 0);
  DefineValue(R, MathObject, 'LN2', JsDouble(0.6931471805599453), 0);
  DefineValue(R, MathObject, 'LOG10E', JsDouble(0.4342944819032518), 0);
  DefineValue(R, MathObject, 'LOG2E', JsDouble(1.4426950408889634), 0);
  DefineValue(R, MathObject, 'PI', JsDouble(3.141592653589793), 0);
  DefineValue(R, MathObject, 'SQRT1_2', JsDouble(0.7071067811865476), 0);
  DefineValue(R, MathObject, 'SQRT2', JsDouble(1.4142135623730951), 0);
  MathObject.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Math'), PropertyConfigurable);
  Unary('abs', FnAbs);
  Unary('acos', FnAcos);
  Unary('acosh', FnAcosh);
  Unary('asin', FnAsin);
  Unary('asinh', FnAsinh);
  Unary('atan', FnAtan);
  Unary('atanh', FnAtanh);
  Unary('cbrt', FnCbrt);
  Unary('ceil', FnCeil);
  Unary('cos', FnCos);
  Unary('cosh', FnCosh);
  Unary('exp', FnExp);
  Unary('expm1', FnExpm1);
  Unary('floor', FnFloor);
  Unary('fround', FnFround);
  Unary('f16round', FnF16round);
  Unary('log', FnLog);
  Unary('log1p', FnLog1p);
  Unary('log10', FnLog10);
  Unary('log2', FnLog2);
  Unary('round', FnRound);
  Unary('sign', FnSign);
  Unary('sin', FnSin);
  Unary('sinh', FnSinh);
  Unary('sqrt', FnSqrt);
  Unary('tan', FnTan);
  Unary('tanh', FnTanh);
  Unary('trunc', FnTrunc);
  Unary('clz32', FnClz32);
  DefineMethod(R, MathObject, 'max', @MathMax, 2, 0);
  DefineMethod(R, MathObject, 'min', @MathMax, 2, 1);
  DefineMethod(R, MathObject, 'pow', @MathPow, 2);
  DefineMethod(R, MathObject, 'atan2', @MathAtan2, 2);
  DefineMethod(R, MathObject, 'hypot', @MathHypot, 2);
  DefineMethod(R, MathObject, 'imul', @MathImul, 2);
  DefineMethod(R, MathObject, 'random', @MathRandom, 0);
end;

end.
