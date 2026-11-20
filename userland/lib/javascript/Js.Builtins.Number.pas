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
  Number and Boolean: the constructors, Number's constants and tests,
  and the prototypes.

  toFixed, toExponential and toPrecision round exactly: the double is
  taken as the exact rational it is (mantissa times a power of two) and
  scaled and rounded with big integers, so (1.005).toFixed(2) is
  "1.00", as in every engine.
}
unit Js.Builtins.Number;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.BigIntegers,
  Js.Conversions,
  Js.Operations,
  Js.Interpreter;

procedure InstallNumber(R: TJsInterpreterRealm);
{ Value (not negative) rounded half up to Fraction decimals, exactly. }
function FormatFixed(Heap: TJsHeap; Value: Double; Fraction: Integer): string;
{ The Count significant digits of Value (positive), and its decimal
  exponent. }
procedure PrecisionDigits(Heap: TJsHeap; Value: Double; Count: Integer; out Digits: string; out Exponent: Integer);

var
  { Number.prototype.toLocaleString with locales and options (set by
    Js.Builtins.Intl). }
  JsNumberLocaleHook: function(R: TJsRealm; Value: TJsValue; Locales, Options: TJsValue): TJsValue = nil;

implementation

function ThisNumber(R: TJsRealm; Value: TJsValue; out Number: Double): Boolean;
begin
  Number := 0;
  if JsIsNumber(Value) then
    Number := JsNumberValue(Value)
  else if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocNumber) then
    Number := JsNumberValue(TJsPrimitiveObject(JsAsObject(Value)).PrimitiveValue)
  else
  begin
    R.ThrowTypeError('Number.prototype method called on incompatible receiver');
    Exit(False);
  end;
  Result := True;
end;

{ Exact rounding }

procedure DecomposeDouble(Value: Double; out Mantissa: QWord; out Exponent: Integer);
var
  Bits: QWord;
  ExponentField: Integer;
begin
  Bits := DoubleBits(Value) and QWord($7FFFFFFFFFFFFFFF);
  ExponentField := Integer(Bits shr 52);
  Mantissa := Bits and QWord($000FFFFFFFFFFFFF);
  if ExponentField = 0 then
    Exponent := -1074
  else
  begin
    Mantissa := Mantissa or QWord($0010000000000000);
    Exponent := ExponentField - 1075;
  end;
end;

{ The digits of round-half-up(|Value| * 10^Scale). }
function ScaledRound(Heap: TJsHeap; Value: Double; Scale: Integer): string;
var
  Mantissa: QWord;
  Exponent: Integer;
  Numerator, Denominator, Quotient, Remainder, Two, Doubled: TJsBigInt;
begin
  DecomposeDouble(Value, Mantissa, Exponent);
  Numerator := BigIntFromInt64(Heap, Int64(Mantissa));
  Denominator := BigIntFromInt64(Heap, 1);
  Two := BigIntFromInt64(Heap, 2);
  if Exponent >= 0 then
    Numerator := BigIntShiftLeft(Heap, Numerator, Exponent)
  else
    Denominator := BigIntShiftLeft(Heap, Denominator, -Exponent);
  if Scale >= 0 then
    Numerator := BigIntMultiply(Heap, Numerator, BigIntPower(Heap, BigIntFromInt64(Heap, 10), Scale))
  else
    Denominator := BigIntMultiply(Heap, Denominator, BigIntPower(Heap, BigIntFromInt64(Heap, 10), -Scale));
  Quotient := BigIntDivide(Heap, Numerator, Denominator);
  Remainder := BigIntRemainder(Heap, Numerator, Denominator);
  Doubled := BigIntMultiply(Heap, Remainder, Two);
  if BigIntCompare(Doubled, Denominator) >= 0 then
    Quotient := BigIntAdd(Heap, Quotient, BigIntFromInt64(Heap, 1));
  Result := BigIntToText(Quotient, 10);
end;

function DecimalExponent(Value: Double): Integer;
begin
  Result := Floor(Log10(Value));
end;

function FormatFixed(Heap: TJsHeap; Value: Double; Fraction: Integer): string;
var
  Digits: string;
  Negative: Boolean;
begin
  Negative := Value < 0;
  Digits := ScaledRound(Heap, Abs(Value), Fraction);
  if Fraction > 0 then
  begin
    while Length(Digits) <= Fraction do
      Digits := '0' + Digits;
    Insert('.', Digits, Length(Digits) - Fraction + 1);
  end;
  if Negative then
    Digits := '-' + Digits;
  Result := Digits;
end;

{ Digits (exactly Count of them) and decimal exponent for Value. }
procedure PrecisionDigits(Heap: TJsHeap; Value: Double; Count: Integer; out Digits: string; out Exponent: Integer);
begin
  Exponent := DecimalExponent(Value);
  Digits := ScaledRound(Heap, Value, Count - 1 - Exponent);
  if Length(Digits) > Count then
  begin
    Inc(Exponent);
    Digits := ScaledRound(Heap, Value, Count - 1 - Exponent);
  end
  else if Length(Digits) < Count then
  begin
    Dec(Exponent);
    Digits := ScaledRound(Heap, Value, Count - 1 - Exponent);
  end;
end;

function ExponentText(Exponent: Integer): string;
begin
  if Exponent >= 0 then
    Result := 'e+' + IntToStr(Exponent)
  else
    Result := 'e-' + IntToStr(-Exponent);
end;

{ The constructor and statics }

function NumberConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Wrapper: TJsPrimitiveObject;
  Prototype: TJsObject;
begin
  Value := JsInteger(0);
  if ArgCount > 0 then
  begin
    Value := ToNumeric(R, Args^[0]);
    if Value = JsException then
      Exit(JsException);
    if JsIsBigInt(Value) then
      Value := JsNumber(BigIntToDouble(TJsBigInt(JsAsCell(Value))));
  end;
  if NewTarget = JsUndefined then
    Exit(Value);
  Prototype := PrototypeFromConstructor(R, NewTarget, inNumberPrototype);
  if Prototype = nil then
    Exit(JsException);
  Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, Prototype, ocNumber));
  Wrapper.PrimitiveValue := Value;
  Result := JsObjectValue(Wrapper);
end;

{ isFinite (0), isInteger (1), isNaN (2), isSafeInteger (3) }
function NumberTest(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Number: Double;
begin
  Value := Arg(Args, ArgCount, 0);
  if not JsIsNumber(Value) then
    Exit(JsFalse);
  Number := JsNumberValue(Value);
  case Callee.Magic of
    0: Result := JsBoolean(IsFiniteDouble(Number));
    1: Result := JsBoolean(IsFiniteDouble(Number) and (Int(Number) = Number));
    2: Result := JsBoolean(IsNaNDouble(Number));
  else
    Result := JsBoolean(IsFiniteDouble(Number) and (Int(Number) = Number) and (Abs(Number) <= 9007199254740991.0));
  end;
end;

{ The prototype }

function NumberToStringMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number, RadixValue: Double;
  Radix: Integer;
begin
  if not ThisNumber(R, This, Number) then
    Exit(JsException);
  Radix := 10;
  if Arg(Args, ArgCount, 0) <> JsUndefined then
  begin
    if not ToIntegerOrInfinity(R, Args^[0], RadixValue) then
      Exit(JsException);
    if (RadixValue < 2) or (RadixValue > 36) then
      Exit(R.ThrowRangeError('toString() radix must be between 2 and 36'));
    Radix := Trunc(RadixValue);
  end;
  if Radix = 10 then
    Result := JsStringValue(NumberToJsString(R, Number))
  else
    Result := R.NewString(NumberToRadixString(Number, Radix));
end;

function NumberToLocaleString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number: Double;
begin
  if not ThisNumber(R, This, Number) then
    Exit(JsException);
  if Assigned(JsNumberLocaleHook) then
    Exit(JsNumberLocaleHook(R, JsNumber(Number), Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1)));
  Result := JsStringValue(NumberToJsString(R, Number));
end;

function NumberValueOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number: Double;
begin
  if not ThisNumber(R, This, Number) then
    Exit(JsException);
  Result := JsNumber(Number);
end;

function NumberToFixed(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number, Fraction: Double;
begin
  if not ThisNumber(R, This, Number) then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Fraction) then
    Exit(JsException);
  if (Fraction < 0) or (Fraction > 100) then
    Exit(R.ThrowRangeError('toFixed() digits argument must be between 0 and 100'));
  if not IsFiniteDouble(Number) or IsNaNDouble(Number) or (Abs(Number) >= 1e21) then
    Exit(JsStringValue(NumberToJsString(R, Number)));
  if Number = 0 then
    Number := 0;
  Result := R.NewString(FormatFixed(R.Heap, Number, Trunc(Fraction)));
end;

function NumberToExponential(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number, Fraction: Double;
  Digits, Text: string;
  Exponent: Integer;
  Negative: Boolean;
begin
  if not ThisNumber(R, This, Number) then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Fraction) then
    Exit(JsException);
  if not IsFiniteDouble(Number) or IsNaNDouble(Number) then
    Exit(JsStringValue(NumberToJsString(R, Number)));
  if (Fraction < 0) or (Fraction > 100) then
    Exit(R.ThrowRangeError('toExponential() argument must be between 0 and 100'));
  Negative := Number < 0;
  Number := Abs(Number);
  if Number = 0 then
  begin
    Digits := StringOfChar('0', Trunc(Fraction) + 1);
    Exponent := 0;
  end
  else if Arg(Args, ArgCount, 0) = JsUndefined then
  begin
    ShortestDigits(Number, Digits, Exponent);
    Dec(Exponent);
  end
  else
    PrecisionDigits(R.Heap, Number, Trunc(Fraction) + 1, Digits, Exponent);
  Text := Digits[1];
  if Length(Digits) > 1 then
    Text := Text + '.' + Copy(Digits, 2, MaxInt);
  Text := Text + ExponentText(Exponent);
  if Negative then
    Text := '-' + Text;
  Result := R.NewString(Text);
end;

function NumberToPrecision(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Number, Precision: Double;
  Digits, Text: string;
  Exponent, Count: Integer;
  Negative: Boolean;
begin
  if not ThisNumber(R, This, Number) then
    Exit(JsException);
  if Arg(Args, ArgCount, 0) = JsUndefined then
    Exit(JsStringValue(NumberToJsString(R, Number)));
  if not ToIntegerOrInfinity(R, Args^[0], Precision) then
    Exit(JsException);
  if not IsFiniteDouble(Number) or IsNaNDouble(Number) then
    Exit(JsStringValue(NumberToJsString(R, Number)));
  if (Precision < 1) or (Precision > 100) then
    Exit(R.ThrowRangeError('toPrecision() argument must be between 1 and 100'));
  Count := Trunc(Precision);
  Negative := Number < 0;
  Number := Abs(Number);
  if Number = 0 then
  begin
    Digits := StringOfChar('0', Count);
    Exponent := 0;
  end
  else
    PrecisionDigits(R.Heap, Number, Count, Digits, Exponent);
  if (Exponent < -6) or (Exponent >= Count) then
  begin
    Text := Digits[1];
    if Count > 1 then
      Text := Text + '.' + Copy(Digits, 2, MaxInt);
    Text := Text + ExponentText(Exponent);
  end
  else if Exponent = Count - 1 then
    Text := Digits
  else if Exponent >= 0 then
    Text := Copy(Digits, 1, Exponent + 1) + '.' + Copy(Digits, Exponent + 2, MaxInt)
  else
    Text := '0.' + StringOfChar('0', -(Exponent + 1)) + Digits;
  if Negative then
    Text := '-' + Text;
  Result := R.NewString(Text);
end;

{ Boolean }

function BooleanConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Wrapper: TJsPrimitiveObject;
  Prototype: TJsObject;
begin
  Value := JsBoolean(ToBoolean(Arg(Args, ArgCount, 0)));
  if NewTarget = JsUndefined then
    Exit(Value);
  Prototype := PrototypeFromConstructor(R, NewTarget, inBooleanPrototype);
  if Prototype = nil then
    Exit(JsException);
  Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, Prototype, ocBoolean));
  Wrapper.PrimitiveValue := Value;
  Result := JsObjectValue(Wrapper);
end;

function ThisBoolean(R: TJsRealm; Value: TJsValue; out Outcome: TJsValue): Boolean;
begin
  Outcome := JsFalse;
  if JsIsBoolean(Value) then
    Outcome := Value
  else if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocBoolean) then
    Outcome := TJsPrimitiveObject(JsAsObject(Value)).PrimitiveValue
  else
  begin
    R.ThrowTypeError('Boolean.prototype method called on incompatible receiver');
    Exit(False);
  end;
  Result := True;
end;

function BooleanToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  if not ThisBoolean(R, This, Value) then
    Exit(JsException);
  if Callee.Magic = 1 then
    Exit(Value);
  if Value = JsTrue then
    Result := R.Atom(anTrue)
  else
    Result := R.Atom(anFalse);
end;

procedure InstallNumber(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
begin
  Prototype := R.Intrinsics[inNumberPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Number', @NumberConstructor, 1, Prototype);
  DefineValue(R, Constructor_, 'EPSILON', JsDouble(2.220446049250313e-16), 0);
  DefineValue(R, Constructor_, 'MAX_SAFE_INTEGER', JsDouble(9007199254740991.0), 0);
  DefineValue(R, Constructor_, 'MIN_SAFE_INTEGER', JsDouble(-9007199254740991.0), 0);
  DefineValue(R, Constructor_, 'MAX_VALUE', JsDouble(MaxDouble), 0);
  DefineValue(R, Constructor_, 'MIN_VALUE', JsDouble(BitsDouble(1)), 0);
  DefineValue(R, Constructor_, 'NaN', JsNaN, 0);
  DefineValue(R, Constructor_, 'POSITIVE_INFINITY', JsDouble(Infinity), 0);
  DefineValue(R, Constructor_, 'NEGATIVE_INFINITY', JsDouble(NegInfinity), 0);
  DefineMethod(R, Constructor_, 'isFinite', @NumberTest, 1, 0);
  DefineMethod(R, Constructor_, 'isInteger', @NumberTest, 1, 1);
  DefineMethod(R, Constructor_, 'isNaN', @NumberTest, 1, 2);
  DefineMethod(R, Constructor_, 'isSafeInteger', @NumberTest, 1, 3);
  Constructor_.DefineData(R, R.Intern('parseFloat'), R.GlobalObject.GetValue(R, R.Intern('parseFloat')),
    PropertyHidden);
  Constructor_.DefineData(R, R.Intern('parseInt'), R.GlobalObject.GetValue(R, R.Intern('parseInt')),
    PropertyHidden);
  DefineMethod(R, Prototype, 'toString', @NumberToStringMethod, 1);
  DefineMethod(R, Prototype, 'toLocaleString', @NumberToLocaleString, 0);
  DefineMethod(R, Prototype, 'valueOf', @NumberValueOf, 0);
  DefineMethod(R, Prototype, 'toFixed', @NumberToFixed, 1);
  DefineMethod(R, Prototype, 'toExponential', @NumberToExponential, 1);
  DefineMethod(R, Prototype, 'toPrecision', @NumberToPrecision, 1);

  Prototype := R.Intrinsics[inBooleanPrototype];
  DefineConstructor(R, R.GlobalObject, 'Boolean', @BooleanConstructor, 1, Prototype);
  DefineMethod(R, Prototype, 'toString', @BooleanToString, 0, 0);
  DefineMethod(R, Prototype, 'valueOf', @BooleanToString, 0, 1);
end;

end.
