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
  What the WebAssembly natives share (Web.Script.NativeWasm and the
  units of its natives): their signature, their arguments, the JS API's
  value type names, and address values (memory64 and table64).

  Address values arrive checked by the platform script (JS API
  AddressValueToU64: [EnforceRange] unsigned long for "i32", a BigInt
  in 0 .. 2^64-1 for "i64", made by wasmToAddress); a result is a Number
  for an i32 memory or table and a BigInt for an i64 one
  (U64ToAddressValue).
}
unit Web.Script.WasmNativeArguments;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Wasm.Types,
  Web.Bindings.Context;

type
  TWasmNativeRoutine = function(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
    ArgCount: Integer): TJsValue;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
function ArgNumber(R: TJsRealm; Args: PJsValueArray; Count, Index: Integer): Double;
{ The argument when it is an object, else nil. }
function ArgPrototype(Args: PJsValueArray; Count, Index: Integer): TJsObject;
{ An address value (a Number or a BigInt) as a u64. }
function ArgAddress(Args: PJsValueArray; Count, Index: Integer): QWord;
{ A u64 as the address value of the address type. }
function AddressValue(R: TJsRealm; Value: QWord; AddressType: TWasmValueKind): TJsValue;
{ The JS API's AddressValueToU64 for "i64": ToBigInt, then a TypeError
  outside 0 .. 2^64-1; the BigInt, or JsException. }
function ToAddressBigInt(R: TJsRealm; Value: TJsValue): TJsValue;

{ Value type names: the JS API's ("i32" ... "externref", "anyfunc") and,
  as engines accept them, the other reference types' ("funcref",
  "anyref", "eqref", "i31ref", "structref", "arrayref", "nullref",
  "nullfuncref", "nullexternref", "exnref"). }
function ValueTypeFromName(const Name: string; out ValueType: TWasmValueType): Boolean;
function ValueTypeName(const ValueType: TWasmValueType): string;

implementation

uses
  Js.Conversions,
  Js.BigIntegers,
  Js.Builtins.BigInt;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function ArgNumber(R: TJsRealm; Args: PJsValueArray; Count, Index: Integer): Double;
begin
  if not ToDouble(R, Arg(Args, Count, Index), Result) then
    Result := 0;
end;

function ArgPrototype(Args: PJsValueArray; Count, Index: Integer): TJsObject;
begin
  if JsIsObject(Arg(Args, Count, Index)) then
    Result := JsAsObject(Arg(Args, Count, Index))
  else
    Result := nil;
end;

function ArgAddress(Args: PJsValueArray; Count, Index: Integer): QWord;
var
  Value: TJsValue;
  Number: Double;
begin
  Value := Arg(Args, Count, Index);
  if JsIsBigInt(Value) then
    Exit(QWord(BigIntToInt64(TJsBigInt(JsAsCell(Value)))));
  if not JsIsNumber(Value) then
    Exit(0);
  Number := JsNumberValue(Value);
  if not (Number >= 0) then
    Exit(0);
  if Number >= 18446744073709551615.0 then
    Exit(High(QWord));
  Result := QWord(Trunc(Number));
end;

function AddressValue(R: TJsRealm; Value: QWord; AddressType: TWasmValueKind): TJsValue;
var
  Digits: TJsDigits;
begin
  if AddressType <> vkI64 then
    Exit(JsNumber(Value));
  Digits := nil;
  SetLength(Digits, 2);
  Digits[0] := LongWord(Value);
  Digits[1] := LongWord(Value shr 32);
  Result := JsCellValue(JsBigIntBase, NewBigInt(R.Heap, False, Digits));
end;

function ToAddressBigInt(R: TJsRealm; Value: TJsValue): TJsValue;
var
  Big: TJsBigInt;
begin
  Result := ToBigIntValue(R, Value);
  if Result = JsException then
    Exit;
  Big := TJsBigInt(JsAsCell(Result));
  if (Big.Negative and not Big.IsZero) or (Length(Big.Digits) > 2) then
    Result := R.ThrowTypeError('WebAssembly: the address value is outside the range of a 64-bit address');
end;

type
  TNamedValueType = record
    Name: string;
    Kind: TWasmValueKind;
    HeapType: Int32;
  end;

const
  NamedValueTypes: array[0..16] of TNamedValueType = (
    (Name: 'i32'; Kind: vkI32; HeapType: 0),
    (Name: 'i64'; Kind: vkI64; HeapType: 0),
    (Name: 'f32'; Kind: vkF32; HeapType: 0),
    (Name: 'f64'; Kind: vkF64; HeapType: 0),
    (Name: 'v128'; Kind: vkV128; HeapType: 0),
    (Name: 'externref'; Kind: vkReference; HeapType: HeapTypeExtern),
    (Name: 'anyfunc'; Kind: vkReference; HeapType: HeapTypeFunc),
    (Name: 'funcref'; Kind: vkReference; HeapType: HeapTypeFunc),
    (Name: 'anyref'; Kind: vkReference; HeapType: HeapTypeAny),
    (Name: 'eqref'; Kind: vkReference; HeapType: HeapTypeEq),
    (Name: 'i31ref'; Kind: vkReference; HeapType: HeapTypeI31),
    (Name: 'structref'; Kind: vkReference; HeapType: HeapTypeStruct),
    (Name: 'arrayref'; Kind: vkReference; HeapType: HeapTypeArray),
    (Name: 'nullref'; Kind: vkReference; HeapType: HeapTypeNone),
    (Name: 'nullfuncref'; Kind: vkReference; HeapType: HeapTypeNoFunc),
    (Name: 'nullexternref'; Kind: vkReference; HeapType: HeapTypeNoExtern),
    (Name: 'exnref'; Kind: vkReference; HeapType: HeapTypeExn));

function ValueTypeFromName(const Name: string; out ValueType: TWasmValueType): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(NamedValueTypes) do
    if NamedValueTypes[Index].Name = Name then
    begin
      if NamedValueTypes[Index].Kind = vkReference then
        ValueType := MakeReferenceType(NamedValueTypes[Index].HeapType)
      else
        ValueType := MakeNumberType(NamedValueTypes[Index].Kind);
      Exit(True);
    end;
  ValueType := WasmI32Type;
  Result := False;
end;

function ValueTypeName(const ValueType: TWasmValueType): string;
begin
  if (ValueType.Kind = vkReference) and (ValueType.HeapType = HeapTypeFunc) and ValueType.Nullable then
    Result := 'anyfunc'
  else
    Result := ValueTypeToString(ValueType);
end;

end.
