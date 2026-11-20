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
  %TypedArray% and its twelve kinds (Int8Array ... BigUint64Array,
  Float16Array): the constructors, from/of, and the prototype methods.

  The methods work on the buffer's bytes: copies between arrays of the
  same kind are moves, sorting without a comparator sorts the raw
  numbers, fill and set write converted values directly. Whatever runs
  JavaScript (callbacks, valueOf) may detach or shrink the buffer, so
  the element paths check the index each time (TypedArrayGet/Set) and
  the methods revalidate where the specification says so.
}
unit Js.Builtins.TypedArrays;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
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
  Js.Interpreter;

procedure InstallTypedArrays(R: TJsInterpreterRealm);
{ Notes the kinds' prototypes' shapes once they are complete (after the
  units adding methods to one kind, like Uint8Array's base64). }
procedure RecordTypedArrayShapes(R: TJsInterpreterRealm);
{ A new typed array of Kind with Length zero elements (a buffer of its
  own); nil when the allocation failed (RangeError thrown). }
function NewTypedArray(R: TJsRealm; Kind: TJsTypedArrayKind; Length: SizeInt): TJsTypedArray;

implementation

uses
  SysUtils,
  Math,
  Js.BigIntegers,
  Js.Builtins.Iterators;

const
  MethodForEach = 0;
  MethodEvery = 1;
  MethodSome = 2;
  MethodFind = 3;
  MethodFindIndex = 4;
  MethodFindLast = 5;
  MethodFindLastIndex = 6;
  MethodMap = 7;
  MethodFilter = 8;

  SearchIncludes = 0;
  SearchIndexOf = 1;
  SearchLastIndexOf = 2;

{ Helpers }

function ValidateTypedArray(R: TJsRealm; const This: TJsValue; const Method: string; out Target: TJsTypedArray;
  out Length: SizeInt): Boolean;
begin
  Target := nil;
  Length := 0;
  if not JsIsObject(This) or not (JsAsObject(This) is TJsTypedArray) then
  begin
    R.ThrowTypeError('this is not a typed array.');
    Exit(False);
  end;
  Target := TJsTypedArray(JsAsObject(This));
  if Target.IsOutOfBounds then
  begin
    R.ThrowTypeError('Cannot perform %TypedArray%.prototype.' + Method + ' on a detached ArrayBuffer');
    Exit(False);
  end;
  Length := Target.CurrentLength;
  Result := True;
end;

function AllocateTypedArray(R: TJsRealm; Kind: TJsTypedArrayKind; Prototype: TJsObject;
  Length: Int64): TJsTypedArray;
var
  Buffer: TJsArrayBuffer;
  Mark: Integer;
begin
  Result := nil;
  if Length * TypedArrayElementSizes[Kind] > MaximumArrayBufferLength then
  begin
    R.ThrowRangeError('Invalid typed array length: ' + IntToStr(Length));
    Exit;
  end;
  Buffer := NewArrayBuffer(R, R.Intrinsics[inArrayBufferPrototype], Length * TypedArrayElementSizes[Kind]);
  if Buffer = nil then
    Exit;
  Mark := R.Runtime.PushRoot(JsObjectValue(Buffer));
  Result := NewTypedArrayObject(R, Prototype, Kind, Buffer, 0, Length);
  R.Runtime.PopRoots(Mark);
end;

function NewTypedArray(R: TJsRealm; Kind: TJsTypedArrayKind; Length: SizeInt): TJsTypedArray;
begin
  Result := AllocateTypedArray(R, Kind, R.Intrinsics[TypedArrayPrototypes[Kind]], Length);
end;

{ TypedArrayCreateFromConstructor: Construct, validate, and check the
  length when one number was passed. }
function CreateFromConstructor(R: TJsRealm; Constructor_: TJsValue; Args: PJsValue; Count: Integer;
  out Target: TJsTypedArray): Boolean;
var
  Made: TJsValue;
  Length: SizeInt;
begin
  Target := nil;
  Made := R.Construct(Constructor_, Args, Count, Constructor_);
  if Made = JsException then
    Exit(False);
  if not ValidateTypedArray(R, Made, 'constructor', Target, Length) then
    Exit(False);
  if (Count = 1) and JsIsNumber(Args[0]) and (Length < JsNumberValue(Args[0])) then
  begin
    R.ThrowTypeError('Derived TypedArray constructor created an array which was too small');
    Exit(False);
  end;
  Result := True;
end;

function SpeciesCreate(R: TJsRealm; Exemplar: TJsTypedArray; Args: PJsValue; Count: Integer;
  out Target: TJsTypedArray): Boolean;
var
  Constructor_: TJsValue;
begin
  Target := nil;
  Constructor_ := SpeciesConstructor(R, Exemplar, JsObjectValue(R.Intrinsics[TypedArrayConstructors[Exemplar.ElementKind]]));
  if Constructor_ = JsException then
    Exit(False);
  if not CreateFromConstructor(R, Constructor_, Args, Count, Target) then
    Exit(False);
  if IsBigIntKind(Target.ElementKind) <> IsBigIntKind(Exemplar.ElementKind) then
  begin
    R.ThrowTypeError('Content type of the species constructor''s typed array does not match');
    Exit(False);
  end;
  Result := True;
end;

function SpeciesCreateWithLength(R: TJsRealm; Exemplar: TJsTypedArray; Length: SizeInt;
  out Target: TJsTypedArray): Boolean;
var
  Argument: TJsValue;
begin
  Argument := JsNumber(Length);
  Result := SpeciesCreate(R, Exemplar, @Argument, 1, Target);
end;

function CreateSameType(R: TJsRealm; Exemplar: TJsTypedArray; Length: SizeInt): TJsTypedArray;
begin
  Result := NewTypedArray(R, Exemplar.ElementKind, Length);
end;

function RequireCallable(R: TJsRealm; Value: TJsValue): Boolean;
begin
  Result := JsIsCallable(Value);
  if not Result then
    R.ThrowTypeError(ValueToPascal(R, Value) + ' is not a function');
end;

{ Copies Count elements between arrays, converting when the kinds
  differ (same content type). }
procedure CopyElements(R: TJsRealm; Source: TJsTypedArray; SourceIndex: SizeInt; Target: TJsTypedArray;
  TargetIndex, Count: SizeInt);
var
  Index: SizeInt;
begin
  if Count <= 0 then
    Exit;
  if Source.ElementKind = Target.ElementKind then
  begin
    Move(Source.ElementAddress(SourceIndex)^, Target.ElementAddress(TargetIndex)^, Count * Source.ElementSize);
    Exit;
  end;
  for Index := 0 to Count - 1 do
    WriteElement(R, Target.ElementKind, Target.ElementAddress(TargetIndex + Index),
      ReadElement(R, Source.ElementKind, Source.ElementAddress(SourceIndex + Index)));
end;

{ Constructors }

function AbstractConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := R.ThrowTypeError('Abstract class TypedArray not directly constructable');
end;

function InitializeFromBuffer(R: TJsRealm; Target: TJsTypedArray; Buffer: TJsArrayBuffer; OffsetValue,
  LengthValue: TJsValue): Boolean;
var
  Offset, NewLength: Int64;
  Size: Integer;
  BufferLength, NewByteLength: Int64;
begin
  Result := False;
  Size := Target.ElementSize;
  if not ToIndex(R, OffsetValue, Offset) then
    Exit;
  if Offset mod Size <> 0 then
  begin
    R.ThrowRangeError('start offset of ' + TypedArrayNames[Target.ElementKind] + ' should be a multiple of ' +
      IntToStr(Size));
    Exit;
  end;
  NewLength := 0;
  if (LengthValue <> JsUndefined) and not ToIndex(R, LengthValue, NewLength) then
    Exit;
  if Buffer.Detached then
  begin
    R.ThrowTypeError('Cannot construct a typed array on a detached ArrayBuffer');
    Exit;
  end;
  BufferLength := Buffer.ByteLength;
  Target.Buffer := Buffer;
  Target.ByteOffset := Offset;
  if (LengthValue = JsUndefined) and Buffer.Resizable then
  begin
    if Offset > BufferLength then
    begin
      R.ThrowRangeError('Start offset ' + IntToStr(Offset) + ' is outside the bounds of the buffer');
      Exit;
    end;
    Target.LengthTracking := True;
    Target.FixedLength := 0;
    Target.FixedByteEnd := Offset;
    Exit(True);
  end;
  if LengthValue = JsUndefined then
  begin
    if BufferLength mod Size <> 0 then
    begin
      R.ThrowRangeError('byte length of ' + TypedArrayNames[Target.ElementKind] + ' should be a multiple of ' +
        IntToStr(Size));
      Exit;
    end;
    NewByteLength := BufferLength - Offset;
    if NewByteLength < 0 then
    begin
      R.ThrowRangeError('Start offset ' + IntToStr(Offset) + ' is outside the bounds of the buffer');
      Exit;
    end;
  end
  else
  begin
    NewByteLength := NewLength * Size;
    if Offset + NewByteLength > BufferLength then
    begin
      R.ThrowRangeError('Invalid typed array length: ' + IntToStr(NewLength));
      Exit;
    end;
  end;
  Target.LengthTracking := False;
  Target.FixedLength := NewByteLength div Size;
  Target.FixedByteEnd := Offset + NewByteLength;
  Result := True;
end;

{ Fills a fresh typed array from a list of values (rooted by the
  caller). }
function FillFromValues(R: TJsRealm; Target: TJsTypedArray; const Values: TJsValueList): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Values) do
    if not TypedArraySet(R, Target, Index, Values[Index]) then
      Exit(False);
  Result := True;
end;

function ConcreteConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Kind: TJsTypedArrayKind;
  Prototype: TJsObject;
  First, Method, Value: TJsValue;
  Length: Int64;
  Target, Source: TJsTypedArray;
  SourceLength: SizeInt;
  Values: TJsValueList;
  Mark, Index: Integer;
  ArrayLength: Int64;
  Holder: TJsArray;
begin
  Kind := TJsTypedArrayKind(Callee.Magic);
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor ' + TypedArrayNames[Kind] + ' requires ''new'''));
  First := Arg(Args, ArgCount, 0);
  if not JsIsObject(First) then
  begin
    if not ToIndex(R, First, Length) then
      Exit(JsException);
    Prototype := PrototypeFromConstructor(R, NewTarget, TypedArrayPrototypes[Kind]);
    if Prototype = nil then
      Exit(JsException);
    Target := AllocateTypedArray(R, Kind, Prototype, Length);
    if Target = nil then
      Exit(JsException);
    Exit(JsObjectValue(Target));
  end;
  Prototype := PrototypeFromConstructor(R, NewTarget, TypedArrayPrototypes[Kind]);
  if Prototype = nil then
    Exit(JsException);
  if JsAsObject(First) is TJsArrayBuffer then
  begin
    Target := NewTypedArrayObject(R, Prototype, Kind, TJsArrayBuffer(JsAsObject(First)), 0, 0);
    Mark := R.Runtime.PushRoot(JsObjectValue(Target));
    try
      if not InitializeFromBuffer(R, Target, TJsArrayBuffer(JsAsObject(First)), Arg(Args, ArgCount, 1),
        Arg(Args, ArgCount, 2)) then
        Exit(JsException);
    finally
      R.Runtime.PopRoots(Mark);
    end;
    Exit(JsObjectValue(Target));
  end;
  if JsAsObject(First) is TJsTypedArray then
  begin
    Source := TJsTypedArray(JsAsObject(First));
    if Source.IsOutOfBounds then
      Exit(R.ThrowTypeError('Cannot construct a typed array from a detached ArrayBuffer'));
    SourceLength := Source.CurrentLength;
    if IsBigIntKind(Source.ElementKind) <> IsBigIntKind(Kind) then
      Exit(R.ThrowTypeError('Cannot mix BigInt and other types, use explicit conversions'));
    Target := AllocateTypedArray(R, Kind, Prototype, SourceLength);
    if Target = nil then
      Exit(JsException);
    CopyElements(R, Source, 0, Target, 0, SourceLength);
    Exit(JsObjectValue(Target));
  end;
  { An iterable, or an array-like. }
  Method := GetMethod(R, First, R.Runtime.SymbolValue(wsIterator));
  if Method = JsException then
    Exit(JsException);
  if Method <> JsUndefined then
  begin
    if IsPlainArrayIteration(R, First) then
    begin
      if not CreateListFromArrayLike(R, First, Values) then
        Exit(JsException);
    end
    else if not IterableToList(R, First, Values) then
      Exit(JsException);
    Holder := R.NewArrayFrom(@Values[0], System.Length(Values));
    Mark := R.Runtime.PushRoot(JsObjectValue(Holder));
    try
      Target := AllocateTypedArray(R, Kind, Prototype, System.Length(Values));
      if Target = nil then
        Exit(JsException);
      R.Runtime.PushRoot(JsObjectValue(Target));
      if not FillFromValues(R, Target, Values) then
        Exit(JsException);
    finally
      R.Runtime.PopRoots(Mark);
    end;
    Exit(JsObjectValue(Target));
  end;
  if not LengthOfArrayLike(R, JsAsObject(First), ArrayLength) then
    Exit(JsException);
  Target := AllocateTypedArray(R, Kind, Prototype, ArrayLength);
  if Target = nil then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(JsObjectValue(Target));
  try
    Index := 0;
    while Index < ArrayLength do
    begin
      Value := JsAsObject(First).Get(R, IndexKey(R, Index), First);
      if Value = JsException then
        Exit(JsException);
      if not TypedArraySet(R, Target, Index, Value) then
        Exit(JsException);
      Inc(Index);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Target);
end;

{ Statics }

function TypedArraySpecies(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

function TypedArrayFrom(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Source, Mapper, ThisArgument, Method, Value, LengthValue: TJsValue;
  Mapping: Boolean;
  Values: TJsValueList;
  Holder: TJsArray;
  Target: TJsTypedArray;
  Mark: Integer;
  Index, Length: Int64;
  SourceObject: TJsValue;
  Pair: array[0..1] of TJsValue;
begin
  if not JsIsConstructor(This) then
    Exit(R.ThrowTypeError(ValueToPascal(R, This) + ' is not a constructor'));
  Source := Arg(Args, ArgCount, 0);
  Mapper := Arg(Args, ArgCount, 1);
  ThisArgument := Arg(Args, ArgCount, 2);
  Mapping := Mapper <> JsUndefined;
  if Mapping and not RequireCallable(R, Mapper) then
    Exit(JsException);
  Method := GetMethod(R, Source, R.Runtime.SymbolValue(wsIterator));
  if Method = JsException then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(JsUndefined);
  try
    if Method <> JsUndefined then
    begin
      if not IterableToList(R, Source, Values) then
        Exit(JsException);
      Holder := R.NewArrayFrom(@Values[0], System.Length(Values));
      R.Runtime.SetRoot(Mark, JsObjectValue(Holder));
      SourceObject := JsObjectValue(Holder);
      Length := System.Length(Values);
    end
    else
    begin
      SourceObject := ToObject(R, Source);
      if SourceObject = JsException then
        Exit(JsException);
      R.Runtime.SetRoot(Mark, SourceObject);
      if not LengthOfArrayLike(R, JsAsObject(SourceObject), Length) then
        Exit(JsException);
    end;
    LengthValue := JsNumber(Length);
    if not CreateFromConstructor(R, This, @LengthValue, 1, Target) then
      Exit(JsException);
    R.Runtime.PushRoot(JsObjectValue(Target));
    Index := 0;
    while Index < Length do
    begin
      Value := JsAsObject(SourceObject).Get(R, IndexKey(R, Index), SourceObject);
      if Value = JsException then
        Exit(JsException);
      if Mapping then
      begin
        Pair[0] := Value;
        Pair[1] := JsNumber(Index);
        Value := R.Call(Mapper, ThisArgument, @Pair[0], 2);
        if Value = JsException then
          Exit(JsException);
      end;
      if Target.SetValue(R, IndexKey(R, Index), Value, JsObjectValue(Target)) < 0 then
        Exit(JsException);
      Inc(Index);
    end;
    Result := JsObjectValue(Target);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function TypedArrayOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  LengthValue: TJsValue;
  Target: TJsTypedArray;
  Mark, Index: Integer;
begin
  if not JsIsConstructor(This) then
    Exit(R.ThrowTypeError(ValueToPascal(R, This) + ' is not a constructor'));
  LengthValue := JsInteger(ArgCount);
  if not CreateFromConstructor(R, This, @LengthValue, 1, Target) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(JsObjectValue(Target));
  try
    for Index := 0 to ArgCount - 1 do
      if Target.SetValue(R, JsInteger(Index), Args^[Index], JsObjectValue(Target)) < 0 then
        Exit(JsException);
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Target);
end;

{ Accessors: buffer (0), byteLength (1), byteOffset (2), length (3). }
function TypedArrayProperty(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsTypedArray) then
    Exit(R.ThrowTypeError('this is not a typed array.'));
  Target := TJsTypedArray(JsAsObject(This));
  case Callee.Magic of
    0: Result := JsObjectValue(Target.Buffer);
    1: Result := JsNumber(Target.CurrentLength * Target.ElementSize);
    2:
      if Target.IsOutOfBounds then
        Result := JsInteger(0)
      else
        Result := JsNumber(Target.ByteOffset);
  else
    Result := JsNumber(Target.CurrentLength);
  end;
end;

function TypedArrayToStringTag(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsTypedArray) then
    Exit(JsUndefined);
  Result := R.Intern(TypedArrayNames[TJsTypedArray(JsAsObject(This)).ElementKind]);
end;

{ Methods }

function TypedArrayAt(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length: SizeInt;
  Number: Double;
begin
  if not ValidateTypedArray(R, This, 'at', Target, Length) then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if Number < 0 then
    Number := Number + Length;
  if (Number < 0) or (Number >= Length) then
    Exit(JsUndefined);
  Result := TypedArrayGet(R, Target, Trunc(Number));
end;

function TypedArrayCopyWithin(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length: SizeInt;
  ToIndex_, From, Final, Count: Int64;
  Size: Integer;
  Limit, ToByte, FromByte, CountBytes: Int64;
begin
  if not ValidateTypedArray(R, This, 'copyWithin', Target, Length) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Length, 0, ToIndex_) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 1), Length, 0, From) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 2), Length, Length, Final) then
    Exit(JsException);
  Count := Min(Final - From, Length - ToIndex_);
  if Count > 0 then
  begin
    if Target.IsOutOfBounds then
      Exit(R.ThrowTypeError('Cannot perform %TypedArray%.prototype.copyWithin on a detached ArrayBuffer'));
    Length := Target.CurrentLength;
    Size := Target.ElementSize;
    Limit := Length * Size + Target.ByteOffset;
    ToByte := ToIndex_ * Size + Target.ByteOffset;
    FromByte := From * Size + Target.ByteOffset;
    CountBytes := Count * Size;
    if FromByte + CountBytes > Limit then
      CountBytes := Limit - FromByte;
    if ToByte + CountBytes > Limit then
      CountBytes := Limit - ToByte;
    if CountBytes > 0 then
      Move((Target.Buffer.Data + FromByte)^, (Target.Buffer.Data + ToByte)^, CountBytes);
  end;
  Result := This;
end;

function TypedArrayIteratorMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length: SizeInt;
begin
  if not ValidateTypedArray(R, This, 'values', Target, Length) then
    Exit(JsException);
  Result := CreateArrayIterator(R, This, Callee.Magic);
end;

{ forEach, every, some, find, findIndex, findLast, findLastIndex, map,
  filter. }
function TypedArrayIterate(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Names: array[0..8] of string = ('forEach', 'every', 'some', 'find', 'findIndex', 'findLast',
    'findLastIndex', 'map', 'filter');
var
  Target, Made: TJsTypedArray;
  Length, Index, Step, Finish: SizeInt;
  Callback, ThisArgument, Value, Outcome: TJsValue;
  Triple: array[0..2] of TJsValue;
  Mark: Integer;
  Kept: TJsValueList;
  KeptCount: Integer;
  Holder: TJsArray;
begin
  if not ValidateTypedArray(R, This, Names[Callee.Magic], Target, Length) then
    Exit(JsException);
  Callback := Arg(Args, ArgCount, 0);
  ThisArgument := Arg(Args, ArgCount, 1);
  if not RequireCallable(R, Callback) then
    Exit(JsException);
  Made := nil;
  Kept := nil;
  KeptCount := 0;
  Mark := R.Runtime.PushRoot(JsUndefined);
  try
    if Callee.Magic = MethodMap then
    begin
      if not SpeciesCreateWithLength(R, Target, Length, Made) then
        Exit(JsException);
      R.Runtime.SetRoot(Mark, JsObjectValue(Made));
    end
    else if Callee.Magic = MethodFilter then
    begin
      Holder := R.NewArray(0);
      R.Runtime.SetRoot(Mark, JsObjectValue(Holder));
    end;
    if Callee.Magic in [MethodFindLast, MethodFindLastIndex] then
    begin
      Index := Length - 1;
      Step := -1;
      Finish := -1;
    end
    else
    begin
      Index := 0;
      Step := 1;
      Finish := Length;
    end;
    while Index <> Finish do
    begin
      Value := TypedArrayGet(R, Target, Index);
      Triple[0] := Value;
      Triple[1] := JsNumber(Index);
      Triple[2] := This;
      Outcome := R.Call(Callback, ThisArgument, @Triple[0], 3);
      if Outcome = JsException then
        Exit(JsException);
      case Callee.Magic of
        MethodEvery:
          if not ToBoolean(Outcome) then
            Exit(JsFalse);
        MethodSome:
          if ToBoolean(Outcome) then
            Exit(JsTrue);
        MethodFind, MethodFindLast:
          if ToBoolean(Outcome) then
            Exit(Value);
        MethodFindIndex, MethodFindLastIndex:
          if ToBoolean(Outcome) then
            Exit(JsNumber(Index));
        MethodMap:
          if Made.SetValue(R, IndexKey(R, Index), Outcome, JsObjectValue(Made)) < 0 then
            Exit(JsException);
        MethodFilter:
          if ToBoolean(Outcome) then
          begin
            Holder.CreateDataProperty(R, JsInteger(KeptCount), Value);
            Inc(KeptCount);
          end;
      end;
      Inc(Index, Step);
    end;
    case Callee.Magic of
      MethodEvery: Result := JsTrue;
      MethodSome: Result := JsFalse;
      MethodFindIndex, MethodFindLastIndex: Result := JsInteger(-1);
      MethodMap: Result := JsObjectValue(Made);
      MethodFilter:
        begin
          if not SpeciesCreateWithLength(R, Target, KeptCount, Made) then
            Exit(JsException);
          for Index := 0 to KeptCount - 1 do
            if not TypedArraySet(R, Made, Index, Holder.Elements^[Index]) then
              Exit(JsException);
          Result := JsObjectValue(Made);
        end;
    else
      Result := JsUndefined;
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function TypedArrayFill(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length: SizeInt;
  Value: TJsValue;
  First, Final, Index: Int64;
  Size: Integer;
  Address: PByte;
begin
  if not ValidateTypedArray(R, This, 'fill', Target, Length) then
    Exit(JsException);
  Value := ConvertForKind(R, Target.ElementKind, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 1), Length, 0, First) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 2), Length, Length, Final) then
    Exit(JsException);
  if Target.IsOutOfBounds then
    Exit(R.ThrowTypeError('Cannot perform %TypedArray%.prototype.fill on a detached ArrayBuffer'));
  Length := Target.CurrentLength;
  if Final > Length then
    Final := Length;
  if First >= Final then
    Exit(This);
  Size := Target.ElementSize;
  Address := Target.ElementAddress(First);
  WriteElement(R, Target.ElementKind, Address, Value);
  if Size = 1 then
    FillChar((Address + 1)^, Final - First - 1, Address^)
  else
    for Index := First + 1 to Final - 1 do
      Move(Address^, Target.ElementAddress(Index)^, Size);
  Result := This;
end;

function SameValueZeroOf(R: TJsRealm; A, B: TJsValue): Boolean;
begin
  Result := SameValueZero(A, B, R.Heap);
end;

function TypedArraySearch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Names: array[0..2] of string = ('includes', 'indexOf', 'lastIndexOf');
var
  Target: TJsTypedArray;
  Length: SizeInt;
  Search, Element: TJsValue;
  Number: Double;
  Index: Int64;
begin
  if not ValidateTypedArray(R, This, Names[Callee.Magic], Target, Length) then
    Exit(JsException);
  if Length = 0 then
  begin
    if Callee.Magic = SearchIncludes then
      Exit(JsFalse);
    Exit(JsInteger(-1));
  end;
  Search := Arg(Args, ArgCount, 0);
  if Callee.Magic = SearchLastIndexOf then
  begin
    if ArgCount > 1 then
    begin
      if not ToIntegerOrInfinity(R, Args^[1], Number) then
        Exit(JsException);
    end
    else
      Number := Length - 1;
    if Number = NegInfinity then
      Exit(JsInteger(-1));
    if Number >= 0 then
      Index := Trunc(Min(Number, Length - 1))
    else
      Index := Trunc(Length + Number);
    while Index >= 0 do
    begin
      if Index < Target.CurrentLength then
      begin
        Element := TypedArrayGet(R, Target, Index);
        if StrictEquals(Element, Search, R.Heap) then
          Exit(JsNumber(Index));
      end;
      Dec(Index);
    end;
    Exit(JsInteger(-1));
  end;
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 1), Number) then
    Exit(JsException);
  if Number = Infinity then
  begin
    if Callee.Magic = SearchIncludes then
      Exit(JsFalse);
    Exit(JsInteger(-1));
  end;
  if Number = NegInfinity then
    Number := 0;
  if Number >= 0 then
    Index := Trunc(Number)
  else
  begin
    Index := Trunc(Length + Number);
    if Index < 0 then
      Index := 0;
  end;
  while Index < Length do
  begin
    Element := TypedArrayGet(R, Target, Index);
    if Callee.Magic = SearchIncludes then
    begin
      if SameValueZeroOf(R, Element, Search) then
        Exit(JsTrue);
    end
    else if (Index < Target.CurrentLength) and StrictEquals(Element, Search, R.Heap) then
      Exit(JsNumber(Index));
    Inc(Index);
  end;
  if Callee.Magic = SearchIncludes then
    Result := JsFalse
  else
    Result := JsInteger(-1);
end;

function TypedArrayJoin(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length, Index: SizeInt;
  Separator, Outcome, Text: TJsString;
  Element: TJsValue;
  Mark: Integer;
begin
  if not ValidateTypedArray(R, This, 'join', Target, Length) then
    Exit(JsException);
  if Arg(Args, ArgCount, 0) = JsUndefined then
    Separator := JsAsString(R.Intern(','))
  else
  begin
    Separator := ToJsString(R, Args^[0]);
    if Separator = nil then
      Exit(JsException);
  end;
  Mark := R.Runtime.PushRoot(JsStringValue(Separator));
  Outcome := R.Runtime.EmptyString;
  for Index := 0 to Length - 1 do
  begin
    if Index > 0 then
      Outcome := ConcatStrings(R.Heap, Outcome, Separator);
    Element := TypedArrayGet(R, Target, Index);
    if Element <> JsUndefined then
    begin
      Text := ToJsString(R, Element);
      Outcome := ConcatStrings(R.Heap, Outcome, Text);
    end;
  end;
  R.Runtime.PopRoots(Mark);
  Result := JsStringValue(Outcome);
end;

function TypedArrayReduce(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length, Index, Step, Finish: SizeInt;
  Callback, Accumulator: TJsValue;
  Quad: array[0..3] of TJsValue;
  Mark: Integer;
begin
  if Callee.Magic = 0 then
  begin
    if not ValidateTypedArray(R, This, 'reduce', Target, Length) then
      Exit(JsException);
  end
  else if not ValidateTypedArray(R, This, 'reduceRight', Target, Length) then
    Exit(JsException);
  Callback := Arg(Args, ArgCount, 0);
  if not RequireCallable(R, Callback) then
    Exit(JsException);
  if Callee.Magic = 0 then
  begin
    Index := 0;
    Step := 1;
    Finish := Length;
  end
  else
  begin
    Index := Length - 1;
    Step := -1;
    Finish := -1;
  end;
  if ArgCount >= 2 then
    Accumulator := Args^[1]
  else
  begin
    if Length = 0 then
      Exit(R.ThrowTypeError('Reduce of empty array with no initial value'));
    Accumulator := TypedArrayGet(R, Target, Index);
    Inc(Index, Step);
  end;
  Mark := R.Runtime.PushRoot(Accumulator);
  try
    while Index <> Finish do
    begin
      Quad[0] := Accumulator;
      Quad[1] := TypedArrayGet(R, Target, Index);
      Quad[2] := JsNumber(Index);
      Quad[3] := This;
      Accumulator := R.Call(Callback, JsUndefined, @Quad[0], 4);
      if Accumulator = JsException then
        Exit(JsException);
      R.Runtime.SetRoot(Mark, Accumulator);
      Inc(Index, Step);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := Accumulator;
end;

procedure ReverseElements(Target: TJsTypedArray; Length: SizeInt);
var
  Low, High: SizeInt;
  Size: Integer;
  Swap: array[0..7] of Byte;
begin
  Size := Target.ElementSize;
  Low := 0;
  High := Length - 1;
  while Low < High do
  begin
    Move(Target.ElementAddress(Low)^, Swap[0], Size);
    Move(Target.ElementAddress(High)^, Target.ElementAddress(Low)^, Size);
    Move(Swap[0], Target.ElementAddress(High)^, Size);
    Inc(Low);
    Dec(High);
  end;
end;

function TypedArrayReverse(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length: SizeInt;
begin
  if not ValidateTypedArray(R, This, 'reverse', Target, Length) then
    Exit(JsException);
  ReverseElements(Target, Length);
  Result := This;
end;

function TypedArrayToReversed(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Made: TJsTypedArray;
  Length: SizeInt;
begin
  if not ValidateTypedArray(R, This, 'toReversed', Target, Length) then
    Exit(JsException);
  Made := CreateSameType(R, Target, Length);
  if Made = nil then
    Exit(JsException);
  CopyElements(R, Target, 0, Made, 0, Length);
  ReverseElements(Made, Length);
  Result := JsObjectValue(Made);
end;

function SetFromTypedArray(R: TJsRealm; Target: TJsTypedArray; Offset: Double; Source: TJsTypedArray): Boolean;
var
  TargetLength, SourceLength: SizeInt;
  Copy: PByte;
  Bytes: SizeInt;
  Index: SizeInt;
begin
  Result := False;
  if Target.IsOutOfBounds or Source.IsOutOfBounds then
  begin
    R.ThrowTypeError('Cannot perform %TypedArray%.prototype.set on a detached ArrayBuffer');
    Exit;
  end;
  TargetLength := Target.CurrentLength;
  SourceLength := Source.CurrentLength;
  if IsBigIntKind(Target.ElementKind) <> IsBigIntKind(Source.ElementKind) then
  begin
    R.ThrowTypeError('Cannot mix BigInt and other types, use explicit conversions');
    Exit;
  end;
  if (Offset = Infinity) or (SourceLength + Offset > TargetLength) then
  begin
    R.ThrowRangeError('offset is out of bounds');
    Exit;
  end;
  if Source.ElementKind = Target.ElementKind then
  begin
    Move(Source.ElementAddress(0)^, Target.ElementAddress(Trunc(Offset))^, SourceLength * Source.ElementSize);
    Exit(True);
  end;
  if Source.Buffer = Target.Buffer then
  begin
    { Overlapping views of one buffer: read from a copy. }
    Bytes := SourceLength * Source.ElementSize;
    Copy := GetMem(Bytes + 1);
    try
      Move(Source.ElementAddress(0)^, Copy^, Bytes);
      for Index := 0 to SourceLength - 1 do
        WriteElement(R, Target.ElementKind, Target.ElementAddress(Trunc(Offset) + Index),
          ReadElement(R, Source.ElementKind, Copy + Index * Source.ElementSize));
    finally
      FreeMem(Copy);
    end;
    Exit(True);
  end;
  CopyElements(R, Source, 0, Target, Trunc(Offset), SourceLength);
  Result := True;
end;

function TypedArraySet_(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Offset: Double;
  Source, SourceObject, Value: TJsValue;
  TargetLength: SizeInt;
  SourceLength, Index: Int64;
  Mark: Integer;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsTypedArray) then
    Exit(R.ThrowTypeError('this is not a typed array.'));
  Target := TJsTypedArray(JsAsObject(This));
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 1), Offset) then
    Exit(JsException);
  if Offset < 0 then
    Exit(R.ThrowRangeError('offset is out of bounds'));
  Source := Arg(Args, ArgCount, 0);
  if JsIsObject(Source) and (JsAsObject(Source) is TJsTypedArray) then
  begin
    if not SetFromTypedArray(R, Target, Offset, TJsTypedArray(JsAsObject(Source))) then
      Exit(JsException);
    Exit(JsUndefined);
  end;
  if Target.IsOutOfBounds then
    Exit(R.ThrowTypeError('Cannot perform %TypedArray%.prototype.set on a detached ArrayBuffer'));
  TargetLength := Target.CurrentLength;
  SourceObject := ToObject(R, Source);
  if SourceObject = JsException then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(SourceObject);
  try
    if not LengthOfArrayLike(R, JsAsObject(SourceObject), SourceLength) then
      Exit(JsException);
    if (Offset = Infinity) or (SourceLength + Offset > TargetLength) then
      Exit(R.ThrowRangeError('offset is out of bounds'));
    Index := 0;
    while Index < SourceLength do
    begin
      Value := JsAsObject(SourceObject).Get(R, IndexKey(R, Index), SourceObject);
      if Value = JsException then
        Exit(JsException);
      if not TypedArraySet(R, Target, Trunc(Offset) + Index, Value) then
        Exit(JsException);
      Inc(Index);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsUndefined;
end;

function TypedArraySlice(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Made: TJsTypedArray;
  Length: SizeInt;
  First, Final, Count, Index: Int64;
  Mark: Integer;
begin
  if not ValidateTypedArray(R, This, 'slice', Target, Length) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Length, 0, First) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 1), Length, Length, Final) then
    Exit(JsException);
  Count := Final - First;
  if Count < 0 then
    Count := 0;
  if not SpeciesCreateWithLength(R, Target, Count, Made) then
    Exit(JsException);
  if Count > 0 then
  begin
    if Target.IsOutOfBounds then
      Exit(R.ThrowTypeError('Cannot perform %TypedArray%.prototype.slice on a detached ArrayBuffer'));
    Length := Target.CurrentLength;
    if Final > Length then
      Final := Length;
    Count := Final - First;
    if Count < 0 then
      Count := 0;
    if Made.ElementKind = Target.ElementKind then
    begin
      if Count > Made.CurrentLength then
        Count := Made.CurrentLength;
      Move(Target.ElementAddress(First)^, Made.ElementAddress(0)^, Count * Target.ElementSize);
    end
    else
    begin
      Mark := R.Runtime.PushRoot(JsObjectValue(Made));
      try
        Index := 0;
        while Index < Count do
        begin
          if not TypedArraySet(R, Made, Index, TypedArrayGet(R, Target, First + Index)) then
            Exit(JsException);
          Inc(Index);
        end;
      finally
        R.Runtime.PopRoots(Mark);
      end;
    end;
  end;
  Result := JsObjectValue(Made);
end;

{ Sorting }

type
  TSortState = record
    Realm: TJsRealm;
    Comparator: TJsValue;
    Failed: Boolean;
  end;

function CompareNumbers(X, Y: Double): Integer;
begin
  if IsNaNDouble(X) then
  begin
    if IsNaNDouble(Y) then
      Exit(0);
    Exit(1);
  end;
  if IsNaNDouble(Y) then
    Exit(-1);
  if X < Y then
    Exit(-1);
  if X > Y then
    Exit(1);
  if (X = 0) and (Y = 0) then
  begin
    if (DoubleBits(X) <> 0) and (DoubleBits(Y) = 0) then
      Exit(-1);
    if (DoubleBits(X) = 0) and (DoubleBits(Y) <> 0) then
      Exit(1);
  end;
  Result := 0;
end;

function CompareValues(var State: TSortState; A, B: TJsValue): Integer;
var
  Pair: array[0..1] of TJsValue;
  Outcome: TJsValue;
  Number: Double;
begin
  Result := 0;
  if State.Failed then
    Exit;
  if State.Comparator = JsUndefined then
  begin
    if JsIsBigInt(A) then
      Exit(BigIntCompare(TJsBigInt(JsAsCell(A)), TJsBigInt(JsAsCell(B))));
    Exit(CompareNumbers(JsNumberValue(A), JsNumberValue(B)));
  end;
  Pair[0] := A;
  Pair[1] := B;
  Outcome := State.Realm.Call(State.Comparator, JsUndefined, @Pair[0], 2);
  if (Outcome = JsException) or not ToDouble(State.Realm, Outcome, Number) then
  begin
    State.Failed := True;
    Exit(0);
  end;
  if Number < 0 then
    Result := -1
  else if Number > 0 then
    Result := 1;
end;

procedure MergeSortValues(var State: TSortState; var Values, Scratch: TJsValueList; Low, High: SizeInt);
var
  Middle, Left, Right, Position: SizeInt;
  Value: TJsValue;
begin
  if (High - Low < 1) or State.Failed then
    Exit;
  if High - Low < 8 then
  begin
    for Left := Low + 1 to High do
    begin
      Value := Values[Left];
      Position := Left - 1;
      while (Position >= Low) and (CompareValues(State, Values[Position], Value) > 0) do
      begin
        Values[Position + 1] := Values[Position];
        Dec(Position);
      end;
      Values[Position + 1] := Value;
      if State.Failed then
        Exit;
    end;
    Exit;
  end;
  Middle := (Low + High) div 2;
  MergeSortValues(State, Values, Scratch, Low, Middle);
  MergeSortValues(State, Values, Scratch, Middle + 1, High);
  if State.Failed or (CompareValues(State, Values[Middle], Values[Middle + 1]) <= 0) then
    Exit;
  for Position := Low to High do
    Scratch[Position] := Values[Position];
  Left := Low;
  Right := Middle + 1;
  Position := Low;
  while (Left <= Middle) and (Right <= High) do
  begin
    if CompareValues(State, Scratch[Right], Scratch[Left]) < 0 then
    begin
      Values[Position] := Scratch[Right];
      Inc(Right);
    end
    else
    begin
      Values[Position] := Scratch[Left];
      Inc(Left);
    end;
    Inc(Position);
  end;
  while Left <= Middle do
  begin
    Values[Position] := Scratch[Left];
    Inc(Left);
    Inc(Position);
  end;
  while Right <= High do
  begin
    Values[Position] := Scratch[Right];
    Inc(Right);
    Inc(Position);
  end;
end;

{ Sorts Length elements of Source into Destination (which may be the
  same array). }
function SortInto(R: TJsRealm; Source: TJsTypedArray; Length: SizeInt; Comparator: TJsValue;
  Destination: TJsTypedArray): Boolean;
var
  Values, Scratch: TJsValueList;
  Holder: TJsArray;
  State: TSortState;
  Mark: Integer;
  Index: SizeInt;
begin
  Values := nil;
  Scratch := nil;
  SetLength(Values, Length);
  for Index := 0 to Length - 1 do
    Values[Index] := TypedArrayGet(R, Source, Index);
  SetLength(Scratch, Length);
  Holder := nil;
  Mark := R.Runtime.PushRoot(JsObjectValue(Destination));
  try
    if IsBigIntKind(Source.ElementKind) or (Comparator <> JsUndefined) then
    begin
      { BigInts are cells, and comparators may collect. }
      Holder := R.NewArrayFrom(@Values[0], Length);
      R.Runtime.PushRoot(JsObjectValue(Holder));
    end;
    State.Realm := R;
    State.Comparator := Comparator;
    State.Failed := False;
    MergeSortValues(State, Values, Scratch, 0, Length - 1);
    if State.Failed then
      Exit(False);
    for Index := 0 to Length - 1 do
      if Index < Destination.CurrentLength then
        WriteElement(R, Destination.ElementKind, Destination.ElementAddress(Index), Values[Index]);
    Result := True;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function TypedArraySort(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Made: TJsTypedArray;
  Length: SizeInt;
  Comparator: TJsValue;
begin
  Comparator := Arg(Args, ArgCount, 0);
  if (Comparator <> JsUndefined) and not RequireCallable(R, Comparator) then
    Exit(JsException);
  if Callee.Magic = 0 then
  begin
    if not ValidateTypedArray(R, This, 'sort', Target, Length) then
      Exit(JsException);
    if not SortInto(R, Target, Length, Comparator, Target) then
      Exit(JsException);
    Exit(This);
  end;
  if not ValidateTypedArray(R, This, 'toSorted', Target, Length) then
    Exit(JsException);
  Made := CreateSameType(R, Target, Length);
  if Made = nil then
    Exit(JsException);
  if not SortInto(R, Target, Length, Comparator, Made) then
    Exit(JsException);
  Result := JsObjectValue(Made);
end;

function TypedArraySubarray(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Made: TJsTypedArray;
  SourceLength: SizeInt;
  First, Final, NewLength: Int64;
  Arguments: array[0..2] of TJsValue;
  Count: Integer;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsTypedArray) then
    Exit(R.ThrowTypeError('this is not a typed array.'));
  Target := TJsTypedArray(JsAsObject(This));
  SourceLength := Target.CurrentLength;
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), SourceLength, 0, First) then
    Exit(JsException);
  Arguments[0] := JsObjectValue(Target.Buffer);
  Arguments[1] := JsNumber(Target.ByteOffset + First * Target.ElementSize);
  if Target.LengthTracking and (Arg(Args, ArgCount, 1) = JsUndefined) then
    Count := 2
  else
  begin
    if not RelativeIndex(R, Arg(Args, ArgCount, 1), SourceLength, SourceLength, Final) then
      Exit(JsException);
    NewLength := Final - First;
    if NewLength < 0 then
      NewLength := 0;
    Arguments[2] := JsNumber(NewLength);
    Count := 3;
  end;
  if not SpeciesCreate(R, Target, @Arguments[0], Count, Made) then
    Exit(JsException);
  Result := JsObjectValue(Made);
end;

function TypedArrayToLocaleString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsTypedArray;
  Length, Index: SizeInt;
  Outcome, Text, Comma: TJsString;
  Value: TJsValue;
  Mark: Integer;
begin
  if not ValidateTypedArray(R, This, 'toLocaleString', Target, Length) then
    Exit(JsException);
  Outcome := R.Runtime.EmptyString;
  Comma := JsAsString(R.Intern(','));
  Mark := R.Runtime.PushRoot(JsStringValue(Outcome));
  try
    for Index := 0 to Length - 1 do
    begin
      if Index > 0 then
        Outcome := ConcatStrings(R.Heap, Outcome, Comma);
      Value := TypedArrayGet(R, Target, Index);
      if Value <> JsUndefined then
      begin
        R.Runtime.SetRoot(Mark, JsStringValue(Outcome));
        Value := CallMethod(R, Value, anToLocaleString, nil, 0);
        if Value = JsException then
          Exit(JsException);
        Text := ToJsString(R, Value);
        if Text = nil then
          Exit(JsException);
        Outcome := ConcatStrings(R.Heap, Outcome, Text);
      end;
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsStringValue(Outcome);
end;

function TypedArrayWith(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Made: TJsTypedArray;
  Length: SizeInt;
  Relative: Double;
  Actual: Int64;
  Value: TJsValue;
  Mark: Integer;
begin
  if not ValidateTypedArray(R, This, 'with', Target, Length) then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Relative) then
    Exit(JsException);
  if Relative >= 0 then
    Relative := Relative
  else
    Relative := Length + Relative;
  Value := ConvertForKind(R, Target.ElementKind, Arg(Args, ArgCount, 1));
  if Value = JsException then
    Exit(JsException);
  if (Relative < 0) or (Relative >= Target.CurrentLength) then
    Exit(R.ThrowRangeError('Invalid typed array index'));
  Actual := Trunc(Relative);
  Mark := R.Runtime.PushRoot(Value);
  try
    Made := CreateSameType(R, Target, Length);
    if Made = nil then
      Exit(JsException);
    CopyElements(R, Target, 0, Made, 0, Min(Length, Target.CurrentLength));
    WriteElement(R, Made.ElementKind, Made.ElementAddress(Actual), Value);
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Made);
end;

procedure RecordTypedArrayShapes(R: TJsInterpreterRealm);
var
  Kind: TJsTypedArrayKind;
begin
  for Kind := Low(TJsTypedArrayKind) to High(TJsTypedArrayKind) do
    R.TypedArrayKindShapes[Kind] := R.Intrinsics[TypedArrayPrototypes[Kind]].Shape;
end;

procedure InstallTypedArrays(R: TJsInterpreterRealm);
var
  Abstract, Constructor_: TJsNativeFunction;
  Prototype, KindPrototype: TJsObject;
  Kind: TJsTypedArrayKind;
  Values, ToStringFunction: TJsValue;
  Getter: TJsNativeFunction;
  BytesKey: TJsValue;
  Flags: Byte;
begin
  Prototype := R.Intrinsics[inTypedArrayPrototype];
  Abstract := DefineConstructor(R, nil, 'TypedArray', @AbstractConstructor, 0, Prototype);
  R.Intrinsics[inTypedArray] := Abstract;
  Getter := NewNativeFunction(R, 'get [Symbol.species]', @TypedArraySpecies, 0);
  Abstract.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies), JsObjectValue(Getter), JsUndefined,
    PropertyConfigurable);
  DefineMethod(R, Abstract, 'from', @TypedArrayFrom, 1);
  DefineMethod(R, Abstract, 'of', @TypedArrayOf, 0);

  DefineGetter(R, Prototype, 'buffer', @TypedArrayProperty, 0);
  DefineGetter(R, Prototype, 'byteLength', @TypedArrayProperty, 1);
  DefineGetter(R, Prototype, 'byteOffset', @TypedArrayProperty, 2);
  DefineGetter(R, Prototype, 'length', @TypedArrayProperty, 3);
  Getter := NewNativeFunction(R, 'get [Symbol.toStringTag]', @TypedArrayToStringTag, 0);
  Prototype.DefineAccessor(R, R.Runtime.SymbolValue(wsToStringTag), JsObjectValue(Getter), JsUndefined,
    PropertyConfigurable);
  DefineMethod(R, Prototype, 'at', @TypedArrayAt, 1);
  DefineMethod(R, Prototype, 'copyWithin', @TypedArrayCopyWithin, 2);
  DefineMethod(R, Prototype, 'entries', @TypedArrayIteratorMethod, 0, IterateEntries);
  DefineMethod(R, Prototype, 'keys', @TypedArrayIteratorMethod, 0, IterateKeys);
  DefineMethod(R, Prototype, 'values', @TypedArrayIteratorMethod, 0, IterateValues);
  Values := Prototype.GetValue(R, R.Intern('values'));
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsIterator), Values, PropertyHidden);
  R.TypedArrayValues := Values;
  DefineMethod(R, Prototype, 'every', @TypedArrayIterate, 1, MethodEvery);
  DefineMethod(R, Prototype, 'filter', @TypedArrayIterate, 1, MethodFilter);
  DefineMethod(R, Prototype, 'find', @TypedArrayIterate, 1, MethodFind);
  DefineMethod(R, Prototype, 'findIndex', @TypedArrayIterate, 1, MethodFindIndex);
  DefineMethod(R, Prototype, 'findLast', @TypedArrayIterate, 1, MethodFindLast);
  DefineMethod(R, Prototype, 'findLastIndex', @TypedArrayIterate, 1, MethodFindLastIndex);
  DefineMethod(R, Prototype, 'forEach', @TypedArrayIterate, 1, MethodForEach);
  DefineMethod(R, Prototype, 'map', @TypedArrayIterate, 1, MethodMap);
  DefineMethod(R, Prototype, 'some', @TypedArrayIterate, 1, MethodSome);
  DefineMethod(R, Prototype, 'fill', @TypedArrayFill, 1);
  DefineMethod(R, Prototype, 'includes', @TypedArraySearch, 1, SearchIncludes);
  DefineMethod(R, Prototype, 'indexOf', @TypedArraySearch, 1, SearchIndexOf);
  DefineMethod(R, Prototype, 'lastIndexOf', @TypedArraySearch, 1, SearchLastIndexOf);
  DefineMethod(R, Prototype, 'join', @TypedArrayJoin, 1);
  DefineMethod(R, Prototype, 'reduce', @TypedArrayReduce, 1, 0);
  DefineMethod(R, Prototype, 'reduceRight', @TypedArrayReduce, 1, 1);
  DefineMethod(R, Prototype, 'reverse', @TypedArrayReverse, 0);
  DefineMethod(R, Prototype, 'set', @TypedArraySet_, 1);
  DefineMethod(R, Prototype, 'slice', @TypedArraySlice, 2);
  DefineMethod(R, Prototype, 'sort', @TypedArraySort, 1, 0);
  DefineMethod(R, Prototype, 'subarray', @TypedArraySubarray, 2);
  DefineMethod(R, Prototype, 'toLocaleString', @TypedArrayToLocaleString, 0);
  DefineMethod(R, Prototype, 'toReversed', @TypedArrayToReversed, 0);
  DefineMethod(R, Prototype, 'toSorted', @TypedArraySort, 1, 1);
  DefineMethod(R, Prototype, 'with', @TypedArrayWith, 2);
  ToStringFunction := R.Intrinsics[inArrayPrototype].GetValue(R, R.Intern('toString'));
  Prototype.DefineData(R, R.Intern('toString'), ToStringFunction, PropertyHidden);

  BytesKey := R.Intern('BYTES_PER_ELEMENT');
  for Kind := Low(TJsTypedArrayKind) to High(TJsTypedArrayKind) do
  begin
    KindPrototype := R.NewObject(Prototype);
    R.Intrinsics[TypedArrayPrototypes[Kind]] := KindPrototype;
    Constructor_ := DefineConstructor(R, R.GlobalObject, TypedArrayNames[Kind], @ConcreteConstructor, 3,
      KindPrototype);
    Constructor_.Magic := Ord(Kind);
    Constructor_.Proto := Abstract;
    R.NoteIsPrototype(Abstract);
    R.Intrinsics[TypedArrayConstructors[Kind]] := Constructor_;
    Constructor_.DefineData(R, BytesKey, JsInteger(TypedArrayElementSizes[Kind]), 0);
    KindPrototype.DefineData(R, BytesKey, JsInteger(TypedArrayElementSizes[Kind]), 0);
  end;
  { The interpreter's direct length path, valid while these stay. }
  RecordTypedArrayShapes(R);
  R.TypedArrayPrototypeShape := Prototype.Shape;
  R.TypedArrayLengthSlot := Prototype.Shape.Find(R.LengthKey, Flags);
  R.TypedArrayLengthGetter := TJsAccessorPair(JsAsCell(Prototype.GetSlot(R.TypedArrayLengthSlot))).Getter;
end;

end.
