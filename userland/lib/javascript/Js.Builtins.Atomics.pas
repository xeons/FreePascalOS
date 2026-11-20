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
  Atomics, for one agent: the read-modify-write operations on integer
  typed arrays are plain loads and stores (nothing else runs at the
  same time), wait cannot block (the agent is a main thread, as in a
  browser window: a TypeError), notify wakes nobody, and pause returns
  at once.
}
unit Js.Builtins.Atomics;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Interpreter;

procedure InstallAtomics(R: TJsInterpreterRealm);

implementation

uses
  Js.Values,
  Js.Symbols,
  Js.Shapes,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.BigIntegers,
  Js.ArrayBuffers;

const
  OperationAdd = 0;
  OperationAnd = 1;
  OperationExchange = 2;
  OperationOr = 3;
  OperationSub = 4;
  OperationXor = 5;
  OperationLoad = 6;
  OperationStore = 7;
  OperationCompareExchange = 8;

{ ValidateIntegerTypedArray, then the index (ValidateAtomicAccess). }
function AtomicTarget(R: TJsRealm; Value, IndexValue: TJsValue; WaitableOnly: Boolean; out Target: TJsTypedArray;
  out Index: SizeInt): Boolean;
var
  Requested: Int64;
begin
  Result := False;
  Target := nil;
  Index := 0;
  if not JsIsObject(Value) or not (JsAsObject(Value) is TJsTypedArray) then
  begin
    R.ThrowTypeError('Argument is not a typed array');
    Exit;
  end;
  Target := TJsTypedArray(JsAsObject(Value));
  if Target.IsOutOfBounds then
  begin
    R.ThrowTypeError('Typed array is detached or out of bounds');
    Exit;
  end;
  if WaitableOnly then
  begin
    if not (Target.ElementKind in [taInt32, taBigInt64]) then
    begin
      R.ThrowTypeError('Atomics.wait works on Int32Array and BigInt64Array only');
      Exit;
    end;
  end
  else if Target.ElementKind in [taUint8Clamped, taFloat16, taFloat32, taFloat64] then
  begin
    R.ThrowTypeError('Atomics operations work on integer typed arrays only');
    Exit;
  end;
  if not ToIndex(R, IndexValue, Requested) then
    Exit;
  if Requested >= Target.CurrentLength then
  begin
    R.ThrowRangeError('Invalid atomic access index');
    Exit;
  end;
  Index := Requested;
  Result := True;
end;

{ The operand as the integer bits stored (low 64 bits). }
function OperandBits(R: TJsRealm; Kind: TJsTypedArrayKind; Value: TJsValue): QWord;
begin
  if IsBigIntKind(Kind) then
    Result := QWord(BigIntToInt64(TJsBigInt(JsAsCell(Value))))
  else
    Result := QWord(Int64(DoubleToInt32(JsNumberValue(Value)))) and QWord($FFFFFFFF);
end;

function ReadBits(Target: TJsTypedArray; Index: SizeInt): QWord;
var
  Address: PByte;
begin
  Address := Target.ElementAddress(Index);
  case Target.ElementSize of
    1: Result := Address^;
    2: Result := PWord(Address)^;
    4: Result := PLongWord(Address)^;
  else
    Result := PQWord(Address)^;
  end;
end;

procedure WriteBits(Target: TJsTypedArray; Index: SizeInt; Bits: QWord);
var
  Address: PByte;
begin
  Address := Target.ElementAddress(Index);
  case Target.ElementSize of
    1: Address^ := Byte(Bits);
    2: PWord(Address)^ := Word(Bits);
    4: PLongWord(Address)^ := LongWord(Bits);
  else
    PQWord(Address)^ := Bits;
  end;
end;

function AtomicsOperation(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Index: SizeInt;
  Value, Replacement: TJsValue;
  Old, Operand, Bits, Expected: QWord;
  Mask: QWord;
begin
  if not AtomicTarget(R, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1), False, Target, Index) then
    Exit(JsException);
  if Callee.Magic = OperationLoad then
    Exit(TypedArrayGet(R, Target, Index));
  Value := ConvertForKind(R, Target.ElementKind, Arg(Args, ArgCount, 2));
  if Value = JsException then
    Exit(JsException);
  Replacement := JsUndefined;
  if Callee.Magic = OperationCompareExchange then
  begin
    Replacement := ConvertForKind(R, Target.ElementKind, Arg(Args, ArgCount, 3));
    if Replacement = JsException then
      Exit(JsException);
  end;
  { The conversions may have detached or shrunk the buffer. }
  if Target.IsOutOfBounds or (Index >= Target.CurrentLength) then
    Exit(R.ThrowTypeError('Typed array is detached or out of bounds'));
  if Callee.Magic = OperationStore then
  begin
    WriteElement(R, Target.ElementKind, Target.ElementAddress(Index), Value);
    if IsBigIntKind(Target.ElementKind) then
      Exit(Value);
    { The value stored is ToIntegerOrInfinity of the number. }
    if IsNaNDouble(JsNumberValue(Value)) then
      Exit(JsInteger(0));
    if IsFiniteDouble(JsNumberValue(Value)) then
      Exit(JsNumber(Int(JsNumberValue(Value)) + 0));
    Exit(Value);
  end;
  Result := TypedArrayGet(R, Target, Index);
  Old := ReadBits(Target, Index);
  Operand := OperandBits(R, Target.ElementKind, Value);
  if Target.ElementSize = 8 then
    Mask := QWord($FFFFFFFFFFFFFFFF)
  else
    Mask := (QWord(1) shl (Target.ElementSize * 8)) - 1;
  case Callee.Magic of
    OperationAdd: Bits := Old + Operand;
    OperationAnd: Bits := Old and Operand;
    OperationExchange: Bits := Operand;
    OperationOr: Bits := Old or Operand;
    OperationSub: Bits := Old - Operand;
    OperationXor: Bits := Old xor Operand;
  else
    begin
      Expected := Operand and Mask;
      if (Old and Mask) <> Expected then
        Exit;
      Bits := OperandBits(R, Target.ElementKind, Replacement);
    end;
  end;
  WriteBits(Target, Index, Bits and Mask);
end;

function AtomicsIsLockFree(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Size: Double;
begin
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Size) then
    Exit(JsException);
  Result := JsBoolean((Size = 1) or (Size = 2) or (Size = 4) or (Size = 8));
end;

function AtomicsWait(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Index: SizeInt;
  Value: TJsValue;
  Timeout: Double;
begin
  if not AtomicTarget(R, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1), True, Target, Index) then
    Exit(JsException);
  if not Target.Buffer.Shared then
    Exit(R.ThrowTypeError('Atomics.wait needs a shared typed array'));
  Value := ConvertForKind(R, Target.ElementKind, Arg(Args, ArgCount, 2));
  if Value = JsException then
    Exit(JsException);
  if not ToDouble(R, Arg(Args, ArgCount, 3), Timeout) then
    Exit(JsException);
  Result := R.ThrowTypeError('Atomics.wait cannot be called in this context');
end;

function AtomicsNotify(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Index: SizeInt;
  Count: Double;
begin
  if not AtomicTarget(R, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1), True, Target, Index) then
    Exit(JsException);
  if (Arg(Args, ArgCount, 2) <> JsUndefined) and not ToIntegerOrInfinity(R, Args^[2], Count) then
    Exit(JsException);
  Result := JsInteger(0);
end;

function AtomicsPause(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Hint: TJsValue;
begin
  Hint := Arg(Args, ArgCount, 0);
  if (Hint <> JsUndefined) and not (JsIsInteger(Hint) or (JsIsDouble(Hint) and
    (Int(JsAsDouble(Hint)) = JsAsDouble(Hint)))) then
    Exit(R.ThrowTypeError('Atomics.pause expects an integer'));
  Result := JsUndefined;
end;

procedure InstallAtomics(R: TJsInterpreterRealm);
var
  Atomics: TJsObject;
begin
  Atomics := R.NewObject(R.Intrinsics[inObjectPrototype]);
  R.GlobalObject.DefineData(R, R.Intern('Atomics'), JsObjectValue(Atomics), PropertyHidden);
  DefineMethod(R, Atomics, 'add', @AtomicsOperation, 3, OperationAdd);
  DefineMethod(R, Atomics, 'and', @AtomicsOperation, 3, OperationAnd);
  DefineMethod(R, Atomics, 'compareExchange', @AtomicsOperation, 4, OperationCompareExchange);
  DefineMethod(R, Atomics, 'exchange', @AtomicsOperation, 3, OperationExchange);
  DefineMethod(R, Atomics, 'isLockFree', @AtomicsIsLockFree, 1);
  DefineMethod(R, Atomics, 'load', @AtomicsOperation, 2, OperationLoad);
  DefineMethod(R, Atomics, 'notify', @AtomicsNotify, 3);
  DefineMethod(R, Atomics, 'or', @AtomicsOperation, 3, OperationOr);
  DefineMethod(R, Atomics, 'pause', @AtomicsPause, 0);
  DefineMethod(R, Atomics, 'store', @AtomicsOperation, 3, OperationStore);
  DefineMethod(R, Atomics, 'sub', @AtomicsOperation, 3, OperationSub);
  DefineMethod(R, Atomics, 'wait', @AtomicsWait, 4);
  DefineMethod(R, Atomics, 'xor', @AtomicsOperation, 3, OperationXor);
  Atomics.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Atomics'), PropertyConfigurable);
end;

end.
