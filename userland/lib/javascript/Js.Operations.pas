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
  The generic operations behind the interpreter's fast paths, also used
  by the built-ins.

  Property access on any value (primitives look their properties up on
  their prototype with themselves as the receiver), the arithmetic and
  bitwise operators for every operand type (BigInt included), the
  iterator protocol, spreading, CopyDataProperties, and the helpers
  for making built-in function objects.
}
unit Js.Operations;

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
  Js.Bytecode;

type
  { An iterator and its next method (GetIterator). }
  TJsIteratorRecord = record
    Iterator: TJsValue;
    NextMethod: TJsValue;
    Done: Boolean;
  end;

{ The object whose properties a primitive has (its prototype), or nil. }
function PrototypeForPrimitive(R: TJsRealm; Value: TJsValue): TJsObject;
function GetProperty(R: TJsRealm; Base, Key: TJsValue): TJsValue;
{ Key must already be a property key. }
function GetPropertyByKey(R: TJsRealm; Base, Key: TJsValue): TJsValue;
{ False when it threw (a refused assignment throws in strict code). }
function SetProperty(R: TJsRealm; Base, Key, Value: TJsValue; Strict: Boolean): Boolean;
function SetPropertyByKey(R: TJsRealm; Base, Key, Value: TJsValue; Strict: Boolean): Boolean;
function DeleteProperty(R: TJsRealm; Base, Key: TJsValue; Strict: Boolean): TJsValue;
function HasPropertyValue(R: TJsRealm; Key, Target: TJsValue): TJsValue;
{ The method under Key, undefined when null or undefined; JsException. }
function GetMethod(R: TJsRealm; Value, Key: TJsValue): TJsValue;
function CallMethod(R: TJsRealm; Value: TJsValue; Name: TJsAtomName; Args: PJsValue; Count: Integer): TJsValue;

function Arithmetic(R: TJsRealm; Opcode: TJsOpcode; First, Second: TJsValue): TJsValue;
function AddValues(R: TJsRealm; First, Second: TJsValue): TJsValue;
function UnaryArithmetic(R: TJsRealm; Opcode: TJsOpcode; Value: TJsValue): TJsValue;
function ConcatValues(R: TJsRealm; First, Second: TJsString): TJsValue;

function GetIterator(R: TJsRealm; Value: TJsValue; Async: Boolean; out Iterator: TJsIteratorRecord): Boolean;
{ The next value: False when the iterator is done (Value undefined) or
  threw (R.HasException). }
function IteratorStep(R: TJsRealm; var Iterator: TJsIteratorRecord; out Value: TJsValue): Boolean;
{ Calls return() if there is one. Quiet: errors are ignored (closing on
  a throw). }
function IteratorClose(R: TJsRealm; Iterator: TJsValue; Quiet: Boolean): Boolean;
function CreateIterResult(R: TJsRealm; Value: TJsValue; Done: Boolean): TJsValue;
{ Appends the values of an iterable to an array (spread). }
function SpreadInto(R: TJsRealm; Target: TJsArray; Iterable: TJsValue): Boolean;
function IterableToList(R: TJsRealm; Iterable: TJsValue; out Values: TJsValueList): Boolean;
function CopyDataProperties(R: TJsRealm; Target: TJsObject; Source: TJsValue; Excluded: TJsObject): Boolean;
{ An array-like's length (ToLength(Get(length))). }
function LengthOfArrayLike(R: TJsRealm; Target: TJsObject; out Length: Int64): Boolean;
{ Array.prototype[@@iterator] and %ArrayIteratorPrototype%.next are
  untouched, so iterating this array can skip the protocol. }
function IsPlainArrayIteration(R: TJsRealm; Value: TJsValue): Boolean;
{ %ArrayIteratorPrototype%.next is the original. }
function IsPlainArrayIterator(R: TJsRealm): Boolean;
function IndexKey(R: TJsRealm; Index: Int64): TJsValue;
function CreateListFromArrayLike(R: TJsRealm; Value: TJsValue; out Values: TJsValueList): Boolean;
function SpeciesConstructor(R: TJsRealm; Target: TJsObject; Default: TJsValue): TJsValue;

{ Built-in function objects. }
function NewNativeFunction(R: TJsRealm; const Name: string; Callback: TJsNativeCallback; Length: Integer;
  Magic: Integer = 0): TJsNativeFunction;
function NewNativeFunctionWithKey(R: TJsRealm; NameKey: TJsValue; Callback: TJsNativeCallback;
  Length: Integer; Magic: Integer = 0): TJsNativeFunction;
procedure DefineMethod(R: TJsRealm; Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Length: Integer; Magic: Integer = 0);
procedure DefineSymbolMethod(R: TJsRealm; Target: TJsObject; Symbol: TJsWellKnownSymbol; const Name: string;
  Callback: TJsNativeCallback; Length: Integer; Flags: Byte = PropertyHidden);
procedure DefineGetter(R: TJsRealm; Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Magic: Integer = 0);
procedure DefineValue(R: TJsRealm; Target: TJsObject; const Name: string; Value: TJsValue;
  Flags: Byte = PropertyHidden);
{ A constructor function with its prototype object linked both ways. }
function DefineConstructor(R: TJsRealm; Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Length: Integer; Prototype: TJsObject): TJsNativeFunction;
procedure SetFunctionName(R: TJsRealm; Target: TJsObject; Key: TJsValue; const Prefix: string);
{ The prototype from a new.target (GetPrototypeFromConstructor). }
function PrototypeFromConstructor(R: TJsRealm; NewTarget: TJsValue; Fallback: TJsIntrinsic): TJsObject;
function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;

implementation

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function PrototypeForPrimitive(R: TJsRealm; Value: TJsValue): TJsObject;
begin
  if JsIsNumber(Value) then
    Result := R.Intrinsics[inNumberPrototype]
  else if JsIsString(Value) then
    Result := R.Intrinsics[inStringPrototype]
  else if JsIsBoolean(Value) then
    Result := R.Intrinsics[inBooleanPrototype]
  else if JsIsSymbol(Value) then
    Result := R.Intrinsics[inSymbolPrototype]
  else if JsIsBigInt(Value) then
    Result := R.Intrinsics[inBigIntPrototype]
  else
    Result := nil;
end;

function GetPropertyByKey(R: TJsRealm; Base, Key: TJsValue): TJsValue;
var
  Text: TJsString;
  Index: LongInt;
  Prototype: TJsObject;
begin
  if JsIsObject(Base) then
    Exit(JsAsObject(Base).Get(R, Key, Base));
  if JsIsString(Base) then
  begin
    Text := JsAsString(Base);
    if JsIsInteger(Key) then
    begin
      Index := JsAsInteger(Key);
      if Index < Text.Length then
      begin
        Text.Flatten(R.Heap);
        Exit(JsStringValue(R.Runtime.CharacterString(Text.CharAt(Index))));
      end;
    end
    else if Key = R.LengthKey then
      Exit(JsInteger(Text.Length));
  end;
  if JsIsNullish(Base) then
    Exit(R.ThrowTypeError('Cannot read properties of ' + ValueToPascal(R, Base) + ' (reading ''' +
      KeyToPascal(R, Key) + ''')'));
  Prototype := PrototypeForPrimitive(R, Base);
  Result := Prototype.Get(R, Key, Base);
end;

function GetProperty(R: TJsRealm; Base, Key: TJsValue): TJsValue;
begin
  if JsIsNullish(Base) then
  begin
    if JsIsObject(Key) then
      Exit(R.ThrowTypeError('Cannot read properties of ' + ValueToPascal(R, Base)));
    Exit(R.ThrowTypeError('Cannot read properties of ' + ValueToPascal(R, Base) + ' (reading ''' +
      ValueToPascal(R, Key) + ''')'));
  end;
  if not (JsIsInteger(Key) and (JsAsInteger(Key) >= 0)) then
  begin
    Key := ToPropertyKey(R, Key);
    if Key = JsException then
      Exit(JsException);
  end;
  Result := GetPropertyByKey(R, Base, Key);
end;

function SetPropertyByKey(R: TJsRealm; Base, Key, Value: TJsValue; Strict: Boolean): Boolean;
var
  Outcome: Integer;
  Prototype: TJsObject;
begin
  if JsIsObject(Base) then
    Outcome := JsAsObject(Base).SetValue(R, Key, Value, Base)
  else
  begin
    if JsIsNullish(Base) then
    begin
      R.ThrowTypeError('Cannot set properties of ' + ValueToPascal(R, Base) + ' (setting ''' +
        KeyToPascal(R, Key) + ''')');
      Exit(False);
    end;
    Prototype := PrototypeForPrimitive(R, Base);
    Outcome := Prototype.SetValue(R, Key, Value, Base);
  end;
  if Outcome < 0 then
    Exit(False);
  if (Outcome = 0) and Strict then
  begin
    if JsIsObject(Base) then
      R.ThrowTypeError('Cannot assign to read only property ''' + KeyToPascal(R, Key) + ''' of object')
    else
      R.ThrowTypeError('Cannot create property ''' + KeyToPascal(R, Key) + ''' on ' + ValueToPascal(R, Base));
    Exit(False);
  end;
  Result := True;
end;

function SetProperty(R: TJsRealm; Base, Key, Value: TJsValue; Strict: Boolean): Boolean;
begin
  if JsIsNullish(Base) then
  begin
    R.ThrowTypeError('Cannot set properties of ' + ValueToPascal(R, Base));
    Exit(False);
  end;
  if not (JsIsInteger(Key) and (JsAsInteger(Key) >= 0)) then
  begin
    Key := ToPropertyKey(R, Key);
    if Key = JsException then
      Exit(False);
  end;
  Result := SetPropertyByKey(R, Base, Key, Value, Strict);
end;

function DeleteProperty(R: TJsRealm; Base, Key: TJsValue; Strict: Boolean): TJsValue;
var
  Target: TJsValue;
  Outcome: Integer;
begin
  Target := ToObject(R, Base);
  if Target = JsException then
    Exit(JsException);
  Key := ToPropertyKey(R, Key);
  if Key = JsException then
    Exit(JsException);
  Outcome := JsAsObject(Target).DeleteProperty(R, Key);
  if Outcome < 0 then
    Exit(JsException);
  if (Outcome = 0) and Strict then
    Exit(R.ThrowTypeError('Cannot delete property ''' + KeyToPascal(R, Key) + ''''));
  Result := JsBoolean(Outcome > 0);
end;

function HasPropertyValue(R: TJsRealm; Key, Target: TJsValue): TJsValue;
var
  Outcome: Integer;
begin
  if not JsIsObject(Target) then
    Exit(R.ThrowTypeError('Cannot use ''in'' operator to search for ''' + ValueToPascal(R, Key) + ''' in ' +
      ValueToPascal(R, Target)));
  Key := ToPropertyKey(R, Key);
  if Key = JsException then
    Exit(JsException);
  Outcome := JsAsObject(Target).HasProperty(R, Key);
  if Outcome < 0 then
    Exit(JsException);
  Result := JsBoolean(Outcome > 0);
end;

function GetMethod(R: TJsRealm; Value, Key: TJsValue): TJsValue;
begin
  Result := GetPropertyByKey(R, Value, Key);
  if Result = JsException then
    Exit;
  if JsIsNullish(Result) then
    Exit(JsUndefined);
  if not JsIsCallable(Result) then
    Exit(R.ThrowTypeError(KeyToPascal(R, Key) + ' is not a function'));
end;

function CallMethod(R: TJsRealm; Value: TJsValue; Name: TJsAtomName; Args: PJsValue; Count: Integer): TJsValue;
var
  Method: TJsValue;
begin
  Method := GetPropertyByKey(R, Value, R.Atom(Name));
  if Method = JsException then
    Exit(JsException);
  Result := R.Call(Method, Value, Args, Count);
end;

{ Arithmetic }

function ConcatValues(R: TJsRealm; First, Second: TJsString): TJsValue;
var
  Joined: TJsString;
begin
  Joined := ConcatStrings(R.Heap, First, Second);
  if Joined = nil then
    Exit(R.ThrowRangeError('Invalid string length'));
  Result := JsStringValue(Joined);
end;

function AddValues(R: TJsRealm; First, Second: TJsValue): TJsValue;
var
  A, B: TJsString;
begin
  if JsIsNumber(First) and JsIsNumber(Second) then
    Exit(JsNumber(JsNumberValue(First) + JsNumberValue(Second)));
  if JsIsString(First) and JsIsString(Second) then
    Exit(ConcatValues(R, JsAsString(First), JsAsString(Second)));
  First := ToPrimitive(R, First);
  if First = JsException then
    Exit(JsException);
  Second := ToPrimitive(R, Second);
  if Second = JsException then
    Exit(JsException);
  if JsIsString(First) or JsIsString(Second) then
  begin
    A := ToJsString(R, First);
    if A = nil then
      Exit(JsException);
    B := ToJsString(R, Second);
    if B = nil then
      Exit(JsException);
    Exit(ConcatValues(R, A, B));
  end;
  Result := Arithmetic(R, opAdd, First, Second);
end;

function NumberModulo(A, B: Double): Double;
begin
  if IsNaNDouble(A) or IsNaNDouble(B) or not IsFiniteDouble(A) or (B = 0) then
    Exit(BitsDouble(JsNaN));
  if not IsFiniteDouble(B) then
    Exit(A);
  if A = 0 then
    Exit(A);
  Result := FMod(A, B);
  if (Result = 0) and (A < 0) then
    Result := -0.0;
end;

function NumberPower(Base, Exponent: Double): Double;
begin
  if IsNaNDouble(Exponent) then
    Exit(BitsDouble(JsNaN));
  if Exponent = 0 then
    Exit(1);
  if ((Base = 1) or (Base = -1)) and not IsFiniteDouble(Exponent) then
    Exit(BitsDouble(JsNaN));
  Result := Power(Base, Exponent);
end;

function BigIntBinary(R: TJsRealm; Opcode: TJsOpcode; A, B: TJsBigInt): TJsValue;
var
  Heap: TJsHeap;
  Shift: Int64;
begin
  Heap := R.Heap;
  case Opcode of
    opAdd: Result := JsCellValue(JsBigIntBase, BigIntAdd(Heap, A, B));
    opSubtract: Result := JsCellValue(JsBigIntBase, BigIntSubtract(Heap, A, B));
    opMultiply: Result := JsCellValue(JsBigIntBase, BigIntMultiply(Heap, A, B));
    opDivide, opModulo:
      begin
        if B.IsZero then
          Exit(R.ThrowRangeError('Division by zero'));
        if Opcode = opDivide then
          Result := JsCellValue(JsBigIntBase, BigIntDivide(Heap, A, B))
        else
          Result := JsCellValue(JsBigIntBase, BigIntRemainder(Heap, A, B));
      end;
    opExponent:
      begin
        if B.Negative then
          Exit(R.ThrowRangeError('Exponent must be non-negative'));
        if Length(B.Digits) > 1 then
          Exit(R.ThrowRangeError('Maximum BigInt size exceeded'));
        Result := JsCellValue(JsBigIntBase, BigIntPower(Heap, A, BigIntToInt64(B)));
      end;
    opBitAnd: Result := JsCellValue(JsBigIntBase, BigIntAnd(Heap, A, B));
    opBitOr: Result := JsCellValue(JsBigIntBase, BigIntOr(Heap, A, B));
    opBitXor: Result := JsCellValue(JsBigIntBase, BigIntXor(Heap, A, B));
    opShiftLeft, opShiftRight:
      begin
        if Length(B.Digits) > 1 then
          Exit(R.ThrowRangeError('Maximum BigInt size exceeded'));
        Shift := BigIntToInt64(B);
        if Opcode = opShiftRight then
          Shift := -Shift;
        Result := JsCellValue(JsBigIntBase, BigIntShiftLeft(Heap, A, Shift));
      end;
    opShiftRightUnsigned:
      Result := R.ThrowTypeError('BigInts have no unsigned right shift, use >> instead');
  else
    Result := R.ThrowTypeError('Invalid BigInt operation');
  end;
end;

function Arithmetic(R: TJsRealm; Opcode: TJsOpcode; First, Second: TJsValue): TJsValue;
var
  A, B: Double;
  X, Y: LongInt;
begin
  if Opcode = opAdd then
  begin
    { Strings and objects take the + of strings; primitives add as numbers. }
    if JsIsString(First) or JsIsString(Second) or JsIsObject(First) or JsIsObject(Second) then
      Exit(AddValues(R, First, Second));
  end;
  if not JsIsNumber(First) then
  begin
    First := ToNumeric(R, First);
    if First = JsException then
      Exit(JsException);
  end;
  if not JsIsNumber(Second) then
  begin
    Second := ToNumeric(R, Second);
    if Second = JsException then
      Exit(JsException);
  end;
  if JsIsBigInt(First) or JsIsBigInt(Second) then
  begin
    if not (JsIsBigInt(First) and JsIsBigInt(Second)) then
      Exit(R.ThrowTypeError('Cannot mix BigInt and other types, use explicit conversions'));
    Exit(BigIntBinary(R, Opcode, TJsBigInt(JsAsCell(First)), TJsBigInt(JsAsCell(Second))));
  end;
  A := JsNumberValue(First);
  B := JsNumberValue(Second);
  case Opcode of
    opAdd: Result := JsNumber(A + B);
    opSubtract: Result := JsNumber(A - B);
    opMultiply: Result := JsNumber(A * B);
    opDivide:
      if B = 0 then
      begin
        if IsNaNDouble(A) or (A = 0) then
          Result := JsNaN
        else if (A > 0) = (DoubleBits(B) = 0) then
          Result := JsDouble(Infinity)
        else
          Result := JsDouble(NegInfinity);
      end
      else
        Result := JsNumber(A / B);
    opModulo: Result := JsNumber(NumberModulo(A, B));
    opExponent: Result := JsNumber(NumberPower(A, B));
  else
    X := DoubleToInt32(A);
    Y := DoubleToInt32(B);
    case Opcode of
      opBitAnd: Result := JsInteger(X and Y);
      opBitOr: Result := JsInteger(X or Y);
      opBitXor: Result := JsInteger(X xor Y);
      opShiftLeft: Result := JsInteger(LongInt(LongWord(X) shl (Y and 31)));
      opShiftRight: Result := JsInteger(SarLongint(X, Y and 31));
      opShiftRightUnsigned: Result := JsNumber(LongWord(X) shr (Y and 31));
    else
      Result := R.ThrowTypeError('Invalid operation');
    end;
  end;
end;

function UnaryArithmetic(R: TJsRealm; Opcode: TJsOpcode; Value: TJsValue): TJsValue;
var
  Big: TJsBigInt;
  One: TJsBigInt;
begin
  Value := ToNumeric(R, Value);
  if Value = JsException then
    Exit(JsException);
  if JsIsBigInt(Value) then
  begin
    Big := TJsBigInt(JsAsCell(Value));
    case Opcode of
      opNegate: Exit(JsCellValue(JsBigIntBase, BigIntNegate(R.Heap, Big)));
      opBitNot: Exit(JsCellValue(JsBigIntBase, BigIntNot(R.Heap, Big)));
      opIncrement, opDecrement:
        begin
          One := BigIntFromInt64(R.Heap, 1);
          if Opcode = opIncrement then
            Exit(JsCellValue(JsBigIntBase, BigIntAdd(R.Heap, Big, One)));
          Exit(JsCellValue(JsBigIntBase, BigIntSubtract(R.Heap, Big, One)));
        end;
      opToNumeric: Exit(Value);
      opPlus: Exit(R.ThrowTypeError('Cannot convert a BigInt value to a number'));
    end;
  end;
  case Opcode of
    opNegate: Result := JsNumber(-JsNumberValue(Value));
    opBitNot: Result := JsInteger(not DoubleToInt32(JsNumberValue(Value)));
    opIncrement: Result := JsNumber(JsNumberValue(Value) + 1);
    opDecrement: Result := JsNumber(JsNumberValue(Value) - 1);
  else
    Result := Value;
  end;
end;

{ Iterators }

function IsPlainArrayIteration(R: TJsRealm; Value: TJsValue): Boolean;
var
  Target: TJsObject;
  Method: TJsValue;
  ArrayPrototype: TJsObject;
  Slot: Integer;
  Flags: Byte;
begin
  Result := False;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  ArrayPrototype := R.Intrinsics[inArrayPrototype];
  if (Target.ObjectClass <> ocArray) or (Target.Proto <> ArrayPrototype) or
    ((Target.ObjectFlags and (ObjectExotic or ObjectIndexedByName)) <> 0) then
    Exit;
  { No own @@iterator. }
  if Target.Shape.Find(R.Runtime.SymbolValue(wsIterator), Flags) >= 0 then
    Exit;
  Slot := ArrayPrototype.Shape.Find(R.Runtime.SymbolValue(wsIterator), Flags);
  if (Slot < 0) or ((Flags and PropertyAccessor) <> 0) then
    Exit;
  Method := ArrayPrototype.GetSlot(Slot);
  if Method <> JsObjectValue(R.Intrinsics[inArrayValues]) then
    Exit;
  Result := IsPlainArrayIterator(R);
end;

function IsPlainArrayIterator(R: TJsRealm): Boolean;
var
  IteratorPrototype: TJsObject;
  Next: TJsValue;
  Slot: Integer;
  Flags: Byte;
begin
  Result := False;
  IteratorPrototype := R.Intrinsics[inArrayIteratorPrototype];
  Slot := IteratorPrototype.Shape.Find(R.Atom(anNext), Flags);
  if (Slot < 0) or ((Flags and PropertyAccessor) <> 0) then
    Exit;
  Next := IteratorPrototype.GetSlot(Slot);
  Result := JsIsObject(Next) and (JsAsObject(Next) is TJsNativeFunction) and
    (TJsNativeFunction(JsAsObject(Next)).Magic = $A11);
end;

function GetIterator(R: TJsRealm; Value: TJsValue; Async: Boolean; out Iterator: TJsIteratorRecord): Boolean;
var
  Method, Made: TJsValue;
begin
  Iterator.Iterator := JsUndefined;
  Iterator.NextMethod := JsUndefined;
  Iterator.Done := False;
  if Async then
  begin
    Method := GetMethod(R, Value, R.Runtime.SymbolValue(wsAsyncIterator));
    if Method = JsException then
      Exit(False);
    if Method = JsUndefined then
    begin
      { CreateAsyncFromSyncIterator: the sync iterator, its values
        awaited by the caller. }
      Method := GetMethod(R, Value, R.Runtime.SymbolValue(wsIterator));
      if Method = JsException then
        Exit(False);
    end;
  end
  else
  begin
    if JsIsNullish(Value) then
    begin
      R.ThrowTypeError(ValueToPascal(R, Value) + ' is not iterable');
      Exit(False);
    end;
    Method := GetMethod(R, Value, R.Runtime.SymbolValue(wsIterator));
    if Method = JsException then
      Exit(False);
  end;
  if Method = JsUndefined then
  begin
    R.ThrowTypeError(ValueToPascal(R, Value) + ' is not iterable');
    Exit(False);
  end;
  Made := R.Call(Method, Value, nil, 0);
  if Made = JsException then
    Exit(False);
  if not JsIsObject(Made) then
  begin
    R.ThrowTypeError('Result of the Symbol.iterator method is not an object');
    Exit(False);
  end;
  Iterator.Iterator := Made;
  Iterator.NextMethod := JsAsObject(Made).GetValue(R, R.Atom(anNext));
  if Iterator.NextMethod = JsException then
    Exit(False);
  Result := True;
end;

function IteratorStep(R: TJsRealm; var Iterator: TJsIteratorRecord; out Value: TJsValue): Boolean;
var
  Outcome, Done: TJsValue;
begin
  Value := JsUndefined;
  if Iterator.Done then
    Exit(False);
  Outcome := R.Call(Iterator.NextMethod, Iterator.Iterator, nil, 0);
  if Outcome = JsException then
  begin
    Iterator.Done := True;
    Exit(False);
  end;
  if not JsIsObject(Outcome) then
  begin
    Iterator.Done := True;
    R.ThrowTypeError('Iterator result ' + ValueToPascal(R, Outcome) + ' is not an object');
    Exit(False);
  end;
  Done := JsAsObject(Outcome).GetValue(R, R.Atom(anDone));
  if Done = JsException then
  begin
    Iterator.Done := True;
    Exit(False);
  end;
  if ToBoolean(Done) then
  begin
    Iterator.Done := True;
    Exit(False);
  end;
  Value := JsAsObject(Outcome).GetValue(R, R.Atom(anValue));
  if Value = JsException then
  begin
    Iterator.Done := True;
    Exit(False);
  end;
  Result := True;
end;

function IteratorClose(R: TJsRealm; Iterator: TJsValue; Quiet: Boolean): Boolean;
var
  Method, Outcome, Saved: TJsValue;
  HadException: Boolean;
begin
  HadException := R.Runtime.HasException;
  Saved := R.Runtime.Exception;
  Result := True;
  if not JsIsObject(Iterator) then
    Exit;
  Method := GetMethod(R, Iterator, R.Atom(anReturn));
  if Method = JsException then
    Outcome := JsException
  else if Method = JsUndefined then
    Outcome := JsUndefined
  else
    Outcome := R.Call(Method, Iterator, nil, 0);
  if Quiet then
  begin
    { The original completion wins. }
    R.Runtime.Exception := Saved;
    R.Runtime.HasException := HadException;
    Exit(True);
  end;
  if Outcome = JsException then
    Exit(False);
  if not JsIsObject(Outcome) then
  begin
    R.ThrowTypeError('Iterator result is not an object');
    Exit(False);
  end;
end;

function CreateIterResult(R: TJsRealm; Value: TJsValue; Done: Boolean): TJsValue;
var
  Outcome: TJsObject;
begin
  Outcome := R.NewPlainObject;
  Outcome.DefineData(R, R.Atom(anValue), Value);
  Outcome.DefineData(R, R.Atom(anDone), JsBoolean(Done));
  Result := JsObjectValue(Outcome);
end;

procedure AppendElement(R: TJsRealm; Target: TJsArray; Value: TJsValue);
var
  Index: LongWord;
begin
  Index := Target.ArrayLength;
  if (LongWord(Target.ElementCount) = Index) and ((Target.ObjectFlags and ObjectIndexedByName) = 0) then
  begin
    Target.EnsureElementCapacity(R, Integer(Index) + 1);
    Target.Elements^[Index] := Value;
    Target.ElementCount := Integer(Index) + 1;
    Target.ArrayLength := Index + 1;
  end
  else
    Target.CreateDataProperty(R, JsInteger(LongInt(Index)), Value);
end;

function SpreadInto(R: TJsRealm; Target: TJsArray; Iterable: TJsValue): Boolean;
var
  Iterator: TJsIteratorRecord;
  Value: TJsValue;
  Source: TJsArray;
  Index: Integer;
  Mark: Integer;
begin
  if IsPlainArrayIteration(R, Iterable) then
  begin
    Source := TJsArray(JsAsObject(Iterable));
    Index := 0;
    while LongWord(Index) < Source.ArrayLength do
    begin
      if (Index < Source.ElementCount) and (Source.Elements^[Index] <> JsHole) then
        Value := Source.Elements^[Index]
      else
      begin
        Value := Source.Get(R, JsInteger(Index), Iterable);
        if Value = JsException then
          Exit(False);
      end;
      AppendElement(R, Target, Value);
      Inc(Index);
    end;
    Exit(True);
  end;
  if not GetIterator(R, Iterable, False, Iterator) then
    Exit(False);
  Mark := R.Runtime.PushRoot(Iterator.Iterator);
  R.Runtime.PushRoot(Iterator.NextMethod);
  try
    while IteratorStep(R, Iterator, Value) do
      AppendElement(R, Target, Value);
    Result := not R.HasException;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function IterableToList(R: TJsRealm; Iterable: TJsValue; out Values: TJsValueList): Boolean;
var
  Holder: TJsArray;
  Mark, Index: Integer;
begin
  Values := nil;
  Holder := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Holder));
  try
    Result := SpreadInto(R, Holder, Iterable);
    if Result then
    begin
      SetLength(Values, Holder.ElementCount);
      for Index := 0 to Holder.ElementCount - 1 do
        Values[Index] := Holder.Elements^[Index];
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function CopyDataProperties(R: TJsRealm; Target: TJsObject; Source: TJsValue; Excluded: TJsObject): Boolean;
var
  From: TJsObject;
  Keys: TJsValueList;
  Index, Position, Found, Mark: Integer;
  Key, Value: TJsValue;
  Desc: TJsPropertyDescriptor;
  Skip: Boolean;
begin
  if JsIsNullish(Source) then
    Exit(True);
  Source := ToObject(R, Source);
  if Source = JsException then
    Exit(False);
  From := JsAsObject(Source);
  if not From.OwnPropertyKeys(R, KeysAll, Keys) then
    Exit(False);
  Mark := R.Runtime.PushRoot(Source);
  try
    for Index := 0 to High(Keys) do
    begin
      Key := Keys[Index];
      Skip := False;
      if Excluded <> nil then
        for Position := 0 to Excluded.ElementCount - 1 do
          if SameValue(Excluded.Elements^[Position], Key, R.Heap) then
            Skip := True;
      if Skip then
        Continue;
      Found := From.GetOwnProperty(R, Key, Desc);
      if Found < 0 then
        Exit(False);
      if (Found = 0) or ((Desc.Flags and PropertyEnumerable) = 0) then
        Continue;
      Value := From.Get(R, Key, Source);
      if Value = JsException then
        Exit(False);
      Target.CreateDataProperty(R, Key, Value);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := True;
end;

function LengthOfArrayLike(R: TJsRealm; Target: TJsObject; out Length: Int64): Boolean;
var
  Value: TJsValue;
begin
  if Target.ObjectClass = ocArray then
  begin
    Length := TJsArray(Target).ArrayLength;
    Exit(True);
  end;
  Value := Target.GetValue(R, R.LengthKey);
  if Value = JsException then
  begin
    Length := 0;
    Exit(False);
  end;
  Result := ToLength(R, Value, Length);
end;

function IndexKey(R: TJsRealm; Index: Int64): TJsValue;
begin
  if (Index >= 0) and (Index <= 2147483647) then
    Result := JsInteger(LongInt(Index))
  else
    Result := R.Intern(IntToStr(Index));
end;

function CreateListFromArrayLike(R: TJsRealm; Value: TJsValue; out Values: TJsValueList): Boolean;
var
  Target: TJsObject;
  Length, Index: Int64;
  Element: TJsValue;
begin
  Values := nil;
  if JsIsNullish(Value) then
    Exit(True);
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError('CreateListFromArrayLike called on non-object');
    Exit(False);
  end;
  Target := JsAsObject(Value);
  if not LengthOfArrayLike(R, Target, Length) then
    Exit(False);
  if Length > 10000000 then
  begin
    R.ThrowRangeError('Too many arguments');
    Exit(False);
  end;
  SetLength(Values, Length);
  for Index := 0 to Length - 1 do
  begin
    if (Index < Target.ElementCount) and (Target.Elements^[Index] <> JsHole) and
      ((Target.ObjectFlags and ObjectExotic) = 0) then
      Element := Target.Elements^[Index]
    else
    begin
      Element := Target.Get(R, IndexKey(R, Index), Value);
      if Element = JsException then
        Exit(False);
    end;
    Values[Index] := Element;
  end;
  Result := True;
end;

function SpeciesConstructor(R: TJsRealm; Target: TJsObject; Default: TJsValue): TJsValue;
var
  Constructor_, Species: TJsValue;
begin
  Constructor_ := Target.GetValue(R, R.ConstructorKey);
  if Constructor_ = JsException then
    Exit(JsException);
  if Constructor_ = JsUndefined then
    Exit(Default);
  if not JsIsObject(Constructor_) then
    Exit(R.ThrowTypeError('object.constructor is not an object'));
  Species := JsAsObject(Constructor_).GetValue(R, R.Runtime.SymbolValue(wsSpecies));
  if Species = JsException then
    Exit(JsException);
  if JsIsNullish(Species) then
    Exit(Default);
  if JsIsConstructor(Species) then
    Exit(Species);
  Result := R.ThrowTypeError('object.constructor[Symbol.species] is not a constructor');
end;

{ Built-in functions }

function NewNativeFunctionWithKey(R: TJsRealm; NameKey: TJsValue; Callback: TJsNativeCallback;
  Length: Integer; Magic: Integer): TJsNativeFunction;
begin
  Result := TJsNativeFunction(R.NewObjectOfClass(TJsNativeFunction, R.Intrinsics[inFunctionPrototype], ocFunction));
  Result.ObjectFlags := Result.ObjectFlags or ObjectCallable;
  Result.Callback := Callback;
  Result.Realm := R;
  Result.Magic := Magic;
  Result.Data := JsUndefined;
  Result.Data2 := JsUndefined;
  Result.DefineData(R, R.LengthKey, JsInteger(Length), PropertyConfigurable);
  if JsIsSymbol(NameKey) then
    SetFunctionName(R, Result, NameKey, '')
  else
    Result.DefineData(R, R.Atom(anName), NameKey, PropertyConfigurable);
end;

function NewNativeFunction(R: TJsRealm; const Name: string; Callback: TJsNativeCallback; Length: Integer;
  Magic: Integer): TJsNativeFunction;
begin
  Result := NewNativeFunctionWithKey(R, R.Intern(Name), Callback, Length, Magic);
end;

procedure DefineMethod(R: TJsRealm; Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Length: Integer; Magic: Integer);
var
  Key: TJsValue;
begin
  Key := R.Intern(Name);
  Target.DefineData(R, Key, JsObjectValue(NewNativeFunctionWithKey(R, Key, Callback, Length, Magic)),
    PropertyHidden);
end;

procedure DefineSymbolMethod(R: TJsRealm; Target: TJsObject; Symbol: TJsWellKnownSymbol; const Name: string;
  Callback: TJsNativeCallback; Length: Integer; Flags: Byte);
var
  Function_: TJsNativeFunction;
begin
  Function_ := NewNativeFunction(R, Name, Callback, Length);
  Target.DefineData(R, R.Runtime.SymbolValue(Symbol), JsObjectValue(Function_), Flags);
end;

procedure DefineGetter(R: TJsRealm; Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Magic: Integer);
var
  Getter: TJsNativeFunction;
begin
  Getter := NewNativeFunction(R, 'get ' + Name, Callback, 0, Magic);
  Target.DefineAccessor(R, R.Intern(Name), JsObjectValue(Getter), JsUndefined, PropertyConfigurable);
end;

procedure DefineValue(R: TJsRealm; Target: TJsObject; const Name: string; Value: TJsValue; Flags: Byte);
begin
  Target.DefineData(R, R.Intern(Name), Value, Flags);
end;

function DefineConstructor(R: TJsRealm; Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Length: Integer; Prototype: TJsObject): TJsNativeFunction;
begin
  Result := NewNativeFunction(R, Name, Callback, Length);
  Result.ObjectFlags := Result.ObjectFlags or ObjectConstructor;
  if Prototype <> nil then
  begin
    Result.DefineData(R, R.PrototypeKey, JsObjectValue(Prototype), 0);
    Prototype.DefineData(R, R.ConstructorKey, JsObjectValue(Result), PropertyHidden);
    R.NoteIsPrototype(Prototype);
  end;
  if Target <> nil then
    Target.DefineData(R, R.Intern(Name), JsObjectValue(Result), PropertyHidden);
end;

procedure SetFunctionName(R: TJsRealm; Target: TJsObject; Key: TJsValue; const Prefix: string);
var
  Name: TJsValue;
  Text: TJsString;
  Symbol: TJsSymbol;
begin
  if JsIsSymbol(Key) then
  begin
    Symbol := JsAsSymbol(Key);
    if Symbol.Description = nil then
      Name := R.Atom(anEmpty)
    else
    begin
      Text := ConcatStrings(R.Heap, NewStringFromUtf8(R.Heap, '['), Symbol.Description);
      Text := ConcatStrings(R.Heap, Text, NewStringFromUtf8(R.Heap, ']'));
      Name := JsStringValue(Text);
    end;
  end
  else
    Name := KeyToStringValue(R, Key);
  if Prefix <> '' then
    Name := JsStringValue(ConcatStrings(R.Heap, NewStringFromUtf8(R.Heap, Prefix + ' '), JsAsString(Name)));
  Target.DefineOwnProperty(R, R.Atom(anName), DataDescriptor(Name, PropertyConfigurable), False);
end;

function PrototypeFromConstructor(R: TJsRealm; NewTarget: TJsValue; Fallback: TJsIntrinsic): TJsObject;
var
  Prototype: TJsValue;
begin
  Result := R.Intrinsics[Fallback];
  if not JsIsObject(NewTarget) then
    Exit;
  Prototype := JsAsObject(NewTarget).GetValue(R, R.PrototypeKey);
  if Prototype = JsException then
    Exit(nil);
  if JsIsObject(Prototype) then
    Result := JsAsObject(Prototype);
end;

end.
