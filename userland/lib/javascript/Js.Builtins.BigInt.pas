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
  BigInt: the function (not a constructor), asIntN, asUintN and
  BigInt.prototype.
}
unit Js.Builtins.BigInt;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
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

procedure InstallBigInt(R: TJsInterpreterRealm);
{ ToBigInt; JsException when it throws. }
function ToBigIntValue(R: TJsRealm; Value: TJsValue): TJsValue;

implementation

function StringToBigInt(R: TJsRealm; Text: TJsString): TJsBigInt;
var
  Pascal: string;
  Negative: Boolean;
  Radix: Integer;
begin
  Pascal := Trim(StringToUtf8(R.Heap, Text));
  if Pascal = '' then
    Exit(BigIntFromInt64(R.Heap, 0));
  Negative := False;
  Radix := 10;
  if (Length(Pascal) > 2) and (Pascal[1] = '0') and (Pascal[2] in ['x', 'X', 'o', 'O', 'b', 'B']) then
  begin
    case Pascal[2] of
      'x', 'X': Radix := 16;
      'o', 'O': Radix := 8;
    else
      Radix := 2;
    end;
    Delete(Pascal, 1, 2);
  end
  else if Pascal[1] in ['+', '-'] then
  begin
    Negative := Pascal[1] = '-';
    Delete(Pascal, 1, 1);
  end;
  Result := BigIntFromText(R.Heap, Pascal, Radix, Negative);
end;

function ToBigIntValue(R: TJsRealm; Value: TJsValue): TJsValue;
var
  Big: TJsBigInt;
begin
  Value := ToPrimitive(R, Value, ptNumber);
  if Value = JsException then
    Exit(JsException);
  if JsIsBigInt(Value) then
    Exit(Value);
  case Value of
    JsTrue: Exit(JsCellValue(JsBigIntBase, BigIntFromInt64(R.Heap, 1)));
    JsFalse: Exit(JsCellValue(JsBigIntBase, BigIntFromInt64(R.Heap, 0)));
    JsUndefined, JsNull: Exit(R.ThrowTypeError('Cannot convert ' + ValueToPascal(R, Value) + ' to a BigInt'));
  end;
  if JsIsString(Value) then
  begin
    Big := StringToBigInt(R, JsAsString(Value));
    if Big = nil then
      Exit(R.ThrowError(ekSyntax, 'Cannot convert ' + ValueToPascal(R, Value) + ' to a BigInt'));
    Exit(JsCellValue(JsBigIntBase, Big));
  end;
  if JsIsNumber(Value) then
    Exit(R.ThrowTypeError('Cannot convert ' + ValueToPascal(R, Value) + ' to a BigInt'));
  Result := R.ThrowTypeError('Cannot convert ' + ValueToPascal(R, Value) + ' to a BigInt');
end;

function BigIntFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Big: TJsBigInt;
begin
  if NewTarget <> JsUndefined then
    Exit(R.ThrowTypeError('BigInt is not a constructor'));
  Value := ToPrimitive(R, Arg(Args, ArgCount, 0), ptNumber);
  if Value = JsException then
    Exit(JsException);
  if JsIsNumber(Value) then
  begin
    Big := BigIntFromDouble(R.Heap, JsNumberValue(Value));
    if Big = nil then
      Exit(R.ThrowRangeError('The number ' + ValueToPascal(R, Value) +
        ' cannot be converted to a BigInt because it is not an integer'));
    Exit(JsCellValue(JsBigIntBase, Big));
  end;
  Result := ToBigIntValue(R, Value);
end;

{ asIntN (0), asUintN (1) }
function BigIntAsN(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Bits: Double;
  Value: TJsValue;
begin
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Bits) then
    Exit(JsException);
  if (Bits < 0) or (Bits > 9007199254740991.0) then
    Exit(R.ThrowRangeError('Invalid value: not (convertible to) a safe integer'));
  Value := ToBigIntValue(R, Arg(Args, ArgCount, 1));
  if Value = JsException then
    Exit(JsException);
  if Bits > 1000000 then
    Exit(R.ThrowRangeError('Maximum BigInt size exceeded'));
  Result := JsCellValue(JsBigIntBase, BigIntAsIntN(R.Heap, TJsBigInt(JsAsCell(Value)), Trunc(Bits), Callee.Magic = 0));
end;

function ThisBigInt(R: TJsRealm; Value: TJsValue; out Big: TJsBigInt): Boolean;
begin
  Big := nil;
  if JsIsBigInt(Value) then
    Big := TJsBigInt(JsAsCell(Value))
  else if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocBigInt) then
    Big := TJsBigInt(JsAsCell(TJsPrimitiveObject(JsAsObject(Value)).PrimitiveValue))
  else
  begin
    R.ThrowTypeError('BigInt.prototype method called on incompatible receiver');
    Exit(False);
  end;
  Result := True;
end;

function BigIntToStringMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Big: TJsBigInt;
  Radix: Double;
begin
  if not ThisBigInt(R, This, Big) then
    Exit(JsException);
  Radix := 10;
  if (Callee.Magic = 0) and (Arg(Args, ArgCount, 0) <> JsUndefined) then
  begin
    if not ToIntegerOrInfinity(R, Args^[0], Radix) then
      Exit(JsException);
    if (Radix < 2) or (Radix > 36) then
      Exit(R.ThrowRangeError('toString() radix must be between 2 and 36'));
  end;
  Result := R.NewString(BigIntToText(Big, Trunc(Radix)));
end;

function BigIntValueOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Big: TJsBigInt;
begin
  if not ThisBigInt(R, This, Big) then
    Exit(JsException);
  Result := JsCellValue(JsBigIntBase, Big);
end;

procedure InstallBigInt(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
begin
  Prototype := R.Intrinsics[inBigIntPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'BigInt', @BigIntFunction, 1, Prototype);
  DefineMethod(R, Constructor_, 'asIntN', @BigIntAsN, 2, 0);
  DefineMethod(R, Constructor_, 'asUintN', @BigIntAsN, 2, 1);
  DefineMethod(R, Prototype, 'toString', @BigIntToStringMethod, 0, 0);
  DefineMethod(R, Prototype, 'toLocaleString', @BigIntToStringMethod, 0, 1);
  DefineMethod(R, Prototype, 'valueOf', @BigIntValueOf, 0);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('BigInt'), PropertyConfigurable);
end;

end.
