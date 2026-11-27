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
  Array: the constructor, Array.isArray / of / from, and
  Array.prototype.

  The methods are generic (they work on any array-like through Get and
  Set, as the specification describes) with fast paths for plain dense
  arrays. Values a method holds across a call into JavaScript (the
  array it is building, the element it is passing on) are kept in the
  runtime's temporary roots. sort is a stable merge sort.
}
unit Js.Builtins.Arrays;

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
  Js.Conversions,
  Js.Operations,
  Js.Interpreter,
  Js.Builtins.Iterators;

procedure InstallArray(R: TJsInterpreterRealm);
{ IsArray (7.2.2): an array, or a proxy whose target is one; False
  (a TypeError thrown) for a revoked proxy. }
function IsArray(R: TJsRealm; Value: TJsValue; out Outcome: Boolean): Boolean;

implementation

uses
  Js.Builtins.Reflect;

const
  MaximumSafeLength = 9007199254740991;

type
  { The receiver as an object and its length. }
  TArrayLike = record
    Target: TJsObject;
    Value: TJsValue;
    Length: Int64;
  end;

function IsArray(R: TJsRealm; Value: TJsValue; out Outcome: Boolean): Boolean;
var
  Target: TJsObject;
begin
  Outcome := False;
  Result := True;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  while Target is TJsProxy do
  begin
    if TJsProxy(Target).Handler = nil then
    begin
      R.ThrowTypeError('Cannot perform ''IsArray'' on a proxy that has been revoked');
      Exit(False);
    end;
    Target := TJsProxy(Target).Target;
  end;
  Outcome := Target.ObjectClass = ocArray;
end;

function ThisArrayLike(R: TJsRealm; This: TJsValue; out Like: TArrayLike): Boolean;
begin
  Like.Target := nil;
  Like.Length := 0;
  Like.Value := ToObject(R, This);
  if Like.Value = JsException then
    Exit(False);
  Like.Target := JsAsObject(Like.Value);
  Result := LengthOfArrayLike(R, Like.Target, Like.Length);
end;

{ A dense plain array whose elements can be read and written directly. }
function IsDense(Target: TJsObject): Boolean; inline;
begin
  Result := (Target.ObjectClass = ocArray) and
    ((Target.ObjectFlags and (ObjectExotic or ObjectIndexedByName or ObjectElementsFrozen)) = 0) and
    (LongWord(Target.ElementCount) = TJsArray(Target).ArrayLength);
end;

function GetAt(R: TJsRealm; Target: TJsObject; Index: Int64): TJsValue;
begin
  if (Index < Target.ElementCount) and ((Target.ObjectFlags and ObjectExotic) = 0) then
  begin
    Result := Target.Elements^[Index];
    if Result <> JsHole then
      Exit;
  end;
  Result := Target.Get(R, IndexKey(R, Index), JsObjectValue(Target));
end;

function HasAt(R: TJsRealm; Target: TJsObject; Index: Int64): Integer;
begin
  if (Index < Target.ElementCount) and ((Target.ObjectFlags and ObjectExotic) = 0) and
    (Target.Elements^[Index] <> JsHole) then
    Exit(1);
  Result := Target.HasProperty(R, IndexKey(R, Index));
end;

function SetAt(R: TJsRealm; Target: TJsObject; Index: Int64; Value: TJsValue): Boolean;
begin
  if (Index < Target.ElementCount) and ((Target.ObjectFlags and (ObjectExotic or ObjectElementsFrozen)) = 0) and
    (Target.Elements^[Index] <> JsHole) then
  begin
    Target.Elements^[Index] := Value;
    Exit(True);
  end;
  Result := SetPropertyByKey(R, JsObjectValue(Target), IndexKey(R, Index), Value, True);
end;

function DeleteAt(R: TJsRealm; Target: TJsObject; Index: Int64): Boolean;
var
  Outcome: Integer;
begin
  Outcome := Target.DeleteProperty(R, IndexKey(R, Index));
  if Outcome < 0 then
    Exit(False);
  if Outcome = 0 then
  begin
    R.ThrowTypeError('Cannot delete property ''' + IntToStr(Index) + ''' of [object Array]');
    Exit(False);
  end;
  Result := True;
end;

function DefineAt(R: TJsRealm; Target: TJsObject; Index: Int64; Value: TJsValue): Boolean;
begin
  if Target.CreateDataProperty(R, IndexKey(R, Index), Value) then
    Exit(True);
  if not R.HasException then
    R.ThrowTypeError('Cannot add property ' + IntToStr(Index) + ', object is not extensible');
  Result := False;
end;

{ DefineAt for an array being filled in order: appended directly when
  Index is the length of a dense, extensible array. }
function DefineNext(R: TJsRealm; Target: TJsObject; Index: Int64; Value: TJsValue): Boolean;
begin
  if IsDense(Target) and (Index = TJsArray(Target).ArrayLength) and Target.IsExtensibleFlag and
    ((Target.ObjectFlags and (ObjectLengthReadOnly or ObjectElementsSealed)) = 0) then
  begin
    AppendElement(R, TJsArray(Target), Value);
    Exit(True);
  end;
  Result := DefineAt(R, Target, Index, Value);
end;

function SetLengthOf(R: TJsRealm; Target: TJsObject; Length: Int64): Boolean;
begin
  if (Target.ObjectClass = ocArray) and ((Target.ObjectFlags and ObjectLengthReadOnly) = 0) and
    (Length <= High(LongWord)) and ((Target.ObjectFlags and ObjectElementsSealed) = 0) then
    Exit(TJsArray(Target).SetLength(R, LongWord(Length)));
  Result := SetPropertyByKey(R, JsObjectValue(Target), R.LengthKey, JsNumber(Length), True);
end;

function ArraySpeciesCreate(R: TJsRealm; Original: TJsObject; Length: Int64): TJsValue;
var
  Constructor_, Argument: TJsValue;
  OriginalIsArray: Boolean;
begin
  if not IsArray(R, JsObjectValue(Original), OriginalIsArray) then
    Exit(JsException);
  if not OriginalIsArray then
  begin
    if Length > High(LongWord) then
      Exit(R.ThrowRangeError('Invalid array length'));
    Exit(JsObjectValue(R.NewArray(0)));
  end;
  Constructor_ := Original.GetValue(R, R.ConstructorKey);
  if Constructor_ = JsException then
    Exit(JsException);
  { Another realm's %Array% makes an array of this realm (10.4.2.3). }
  if JsIsObject(Constructor_) and (JsAsObject(Constructor_) is TJsNativeFunction) and
    (TJsNativeFunction(JsAsObject(Constructor_)).Realm <> nil) and
    (TJsNativeFunction(JsAsObject(Constructor_)).Realm <> R) and
    (JsAsObject(Constructor_) = TJsNativeFunction(JsAsObject(Constructor_)).Realm.Intrinsics[inArray]) then
    Constructor_ := JsUndefined;
  if JsIsObject(Constructor_) then
  begin
    Constructor_ := JsAsObject(Constructor_).GetValue(R, R.Runtime.SymbolValue(wsSpecies));
    if Constructor_ = JsException then
      Exit(JsException);
    if Constructor_ = JsNull then
      Constructor_ := JsUndefined;
  end;
  if (Constructor_ = JsUndefined) or (Constructor_ = JsObjectValue(R.Intrinsics[inArray])) then
  begin
    if Length > High(LongWord) then
      Exit(R.ThrowRangeError('Invalid array length'));
    Exit(JsObjectValue(R.NewArray(0)));
  end;
  if not JsIsConstructor(Constructor_) then
    Exit(R.ThrowTypeError('object.constructor[Symbol.species] is not a constructor'));
  Argument := JsNumber(Length);
  Result := R.Construct(Constructor_, @Argument, 1, Constructor_);
end;

function RequireCallable(R: TJsRealm; Value: TJsValue): Boolean;
begin
  Result := JsIsCallable(Value);
  if not Result then
    R.ThrowTypeError(ValueToPascal(R, Value) + ' is not a function');
end;

{ The constructor and statics }

function ArrayConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Created: TJsArray;
  Prototype: TJsObject;
  Length: Double;
begin
  Prototype := R.Intrinsics[inArrayPrototype];
  if (NewTarget <> JsUndefined) and (NewTarget <> JsObjectValue(Callee)) then
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inArrayPrototype);
    if Prototype = nil then
      Exit(JsException);
  end;
  if (ArgCount = 1) and JsIsNumber(Args^[0]) then
  begin
    Length := JsNumberValue(Args^[0]);
    if (Length < 0) or (Length > 4294967295.0) or (Int(Length) <> Length) then
      Exit(R.ThrowRangeError('Invalid array length'));
    Created := R.NewArray(0);
    Created.ArrayLength := LongWord(Trunc(Length));
  end
  else
    Created := R.NewArrayFrom(PJsValue(Args), ArgCount);
  Created.Proto := Prototype;
  Result := JsObjectValue(Created);
end;

function ArrayIsArray(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Outcome: Boolean;
begin
  if not IsArray(R, Arg(Args, ArgCount, 0), Outcome) then
    Exit(JsException);
  Result := JsBoolean(Outcome);
end;

function ArrayOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Created: TJsValue;
  Index: Integer;
  LengthValue: TJsValue;
begin
  if JsIsConstructor(This) and (This <> JsObjectValue(R.Intrinsics[inArray])) then
  begin
    LengthValue := JsInteger(ArgCount);
    Created := R.Construct(This, @LengthValue, 1, This);
    if Created = JsException then
      Exit(JsException);
    for Index := 0 to ArgCount - 1 do
      if not DefineAt(R, JsAsObject(Created), Index, Args^[Index]) then
        Exit(JsException);
    if not SetPropertyByKey(R, Created, R.LengthKey, JsInteger(ArgCount), True) then
      Exit(JsException);
    Exit(Created);
  end;
  Result := JsObjectValue(R.NewArrayFrom(PJsValue(Args), ArgCount));
end;

function ArrayFrom(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Items, Mapper, Method, Value, Created, Mapped: TJsValue;
  Target: TJsObject;
  Iterator: TJsIteratorRecord;
  Index, Length: Int64;
  Pair: array[0..1] of TJsValue;
  Source: TJsObject;
  Mark: Integer;
  UseConstructor: Boolean;
begin
  Items := Arg(Args, ArgCount, 0);
  Mapper := Arg(Args, ArgCount, 1);
  if (Mapper <> JsUndefined) and not RequireCallable(R, Mapper) then
    Exit(JsException);
  UseConstructor := JsIsConstructor(This) and (This <> JsObjectValue(R.Intrinsics[inArray]));
  Method := GetMethod(R, Items, R.Runtime.SymbolValue(wsIterator));
  if Method = JsException then
    Exit(JsException);
  if UseConstructor then
  begin
    if Method <> JsUndefined then
      Created := R.Construct(This, nil, 0, This)
    else
    begin
      Value := ToObject(R, Items);
      if Value = JsException then
        Exit(JsException);
      if not LengthOfArrayLike(R, JsAsObject(Value), Length) then
        Exit(JsException);
      Pair[0] := JsNumber(Length);
      Created := R.Construct(This, @Pair[0], 1, This);
    end;
    if Created = JsException then
      Exit(JsException);
  end
  else
    Created := JsObjectValue(R.NewArray(0));
  Target := JsAsObject(Created);
  Mark := R.Runtime.PushRoot(Created);
  R.Runtime.PushRoot(JsUndefined);
  R.Runtime.PushRoot(JsUndefined);
  try
    Index := 0;
    if Method <> JsUndefined then
    begin
      if not GetIterator(R, Items, False, Iterator) then
        Exit(JsException);
      R.Runtime.SetRoot(Mark + 1, Iterator.Iterator);
      R.Runtime.SetRoot(Mark + 2, Iterator.NextMethod);
      while IteratorStep(R, Iterator, Value) do
      begin
        if Mapper <> JsUndefined then
        begin
          Pair[0] := Value;
          Pair[1] := JsNumber(Index);
          Mapped := R.Call(Mapper, Arg(Args, ArgCount, 2), @Pair[0], 2);
          if Mapped = JsException then
          begin
            IteratorClose(R, Iterator.Iterator, True);
            Exit(JsException);
          end;
          Value := Mapped;
        end;
        if not DefineAt(R, Target, Index, Value) then
        begin
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        Inc(Index);
      end;
      if R.HasException then
        Exit(JsException);
    end
    else
    begin
      Value := ToObject(R, Items);
      if Value = JsException then
        Exit(JsException);
      Source := JsAsObject(Value);
      R.Runtime.SetRoot(Mark + 1, Value);
      if not LengthOfArrayLike(R, Source, Length) then
        Exit(JsException);
      while Index < Length do
      begin
        Value := GetAt(R, Source, Index);
        if Value = JsException then
          Exit(JsException);
        if Mapper <> JsUndefined then
        begin
          Pair[0] := Value;
          Pair[1] := JsNumber(Index);
          Value := R.Call(Mapper, Arg(Args, ArgCount, 2), @Pair[0], 2);
          if Value = JsException then
            Exit(JsException);
        end;
        if not DefineAt(R, Target, Index, Value) then
          Exit(JsException);
        Inc(Index);
      end;
    end;
    if not SetPropertyByKey(R, Created, R.LengthKey, JsNumber(Index), True) then
      Exit(JsException);
    Result := Created;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArraySpecies(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

{ Mutators }

function ArrayPush(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Index: Integer;
  Target: TJsObject;
  Count: Integer;
begin
  if JsIsObject(This) and IsDense(JsAsObject(This)) and ((JsAsObject(This).ObjectFlags and
    (ObjectLengthReadOnly or ObjectElementsSealed)) = 0) and JsAsObject(This).IsExtensibleFlag then
  begin
    Target := JsAsObject(This);
    Count := Target.ElementCount;
    if Count + ArgCount <= 2147483647 then
    begin
      Target.EnsureElementCapacity(R, Count + ArgCount);
      for Index := 0 to ArgCount - 1 do
        Target.Elements^[Count + Index] := Args^[Index];
      Target.ElementCount := Count + ArgCount;
      TJsArray(Target).ArrayLength := Count + ArgCount;
      Exit(JsInteger(Count + ArgCount));
    end;
  end;
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if Like.Length + ArgCount > MaximumSafeLength then
    Exit(R.ThrowTypeError('Pushing ' + IntToStr(ArgCount) + ' elements on an array-like of length ' +
      IntToStr(Like.Length) + ' is disallowed'));
  for Index := 0 to ArgCount - 1 do
    if not SetPropertyByKey(R, Like.Value, IndexKey(R, Like.Length + Index), Args^[Index], True) then
      Exit(JsException);
  if not SetLengthOf(R, Like.Target, Like.Length + ArgCount) then
    Exit(JsException);
  Result := JsNumber(Like.Length + ArgCount);
end;

function ArrayPop(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Target: TJsObject;
begin
  if JsIsObject(This) and IsDense(JsAsObject(This)) and ((JsAsObject(This).ObjectFlags and
    (ObjectLengthReadOnly or ObjectElementsSealed)) = 0) then
  begin
    Target := JsAsObject(This);
    if Target.ElementCount = 0 then
      Exit(JsUndefined);
    Result := Target.Elements^[Target.ElementCount - 1];
    Target.Elements^[Target.ElementCount - 1] := JsHole;
    Dec(Target.ElementCount);
    TJsArray(Target).ArrayLength := Target.ElementCount;
    Exit;
  end;
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if Like.Length = 0 then
  begin
    if not SetLengthOf(R, Like.Target, 0) then
      Exit(JsException);
    Exit(JsUndefined);
  end;
  Result := GetAt(R, Like.Target, Like.Length - 1);
  if Result = JsException then
    Exit;
  if not DeleteAt(R, Like.Target, Like.Length - 1) then
    Exit(JsException);
  if not SetLengthOf(R, Like.Target, Like.Length - 1) then
    Exit(JsException);
end;

function ArrayShift(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Target: TJsObject;
  Index: Int64;
  Value: TJsValue;
  Found: Integer;
begin
  if JsIsObject(This) and IsDense(JsAsObject(This)) and ((JsAsObject(This).ObjectFlags and
    (ObjectLengthReadOnly or ObjectElementsSealed)) = 0) then
  begin
    Target := JsAsObject(This);
    if Target.ElementCount = 0 then
      Exit(JsUndefined);
    Result := Target.Elements^[0];
    if Target.ElementCount > 1 then
      Move(Target.Elements^[1], Target.Elements^[0], (Target.ElementCount - 1) * SizeOf(TJsValue));
    Dec(Target.ElementCount);
    Target.Elements^[Target.ElementCount] := JsHole;
    TJsArray(Target).ArrayLength := Target.ElementCount;
    if Result = JsHole then
      Result := JsUndefined;
    Exit;
  end;
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if Like.Length = 0 then
  begin
    if not SetLengthOf(R, Like.Target, 0) then
      Exit(JsException);
    Exit(JsUndefined);
  end;
  Result := GetAt(R, Like.Target, 0);
  if Result = JsException then
    Exit;
  for Index := 1 to Like.Length - 1 do
  begin
    Found := HasAt(R, Like.Target, Index);
    if Found < 0 then
      Exit(JsException);
    if Found > 0 then
    begin
      Value := GetAt(R, Like.Target, Index);
      if (Value = JsException) or not SetAt(R, Like.Target, Index - 1, Value) then
        Exit(JsException);
    end
    else if not DeleteAt(R, Like.Target, Index - 1) then
      Exit(JsException);
  end;
  if not DeleteAt(R, Like.Target, Like.Length - 1) then
    Exit(JsException);
  if not SetLengthOf(R, Like.Target, Like.Length - 1) then
    Exit(JsException);
end;

function ArrayUnshift(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Target: TJsObject;
  Index: Int64;
  Value: TJsValue;
  Found: Integer;
  Count: Integer;
begin
  if JsIsObject(This) and IsDense(JsAsObject(This)) and ((JsAsObject(This).ObjectFlags and
    (ObjectLengthReadOnly or ObjectElementsSealed)) = 0) and JsAsObject(This).IsExtensibleFlag then
  begin
    Target := JsAsObject(This);
    Count := Target.ElementCount;
    Target.EnsureElementCapacity(R, Count + ArgCount);
    if Count > 0 then
      Move(Target.Elements^[0], Target.Elements^[ArgCount], Count * SizeOf(TJsValue));
    for Index := 0 to ArgCount - 1 do
      Target.Elements^[Index] := Args^[Index];
    Target.ElementCount := Count + ArgCount;
    TJsArray(Target).ArrayLength := Count + ArgCount;
    Exit(JsInteger(Count + ArgCount));
  end;
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if (ArgCount > 0) and (Like.Length + ArgCount > MaximumSafeLength) then
    Exit(R.ThrowTypeError('Array length would exceed the maximum'));
  if ArgCount > 0 then
  begin
    Index := Like.Length;
    while Index > 0 do
    begin
      Found := HasAt(R, Like.Target, Index - 1);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Index - 1);
        if (Value = JsException) or not SetPropertyByKey(R, Like.Value, IndexKey(R, Index - 1 + ArgCount), Value,
          True) then
          Exit(JsException);
      end
      else if not DeleteAt(R, Like.Target, Index - 1 + ArgCount) then
        Exit(JsException);
      Dec(Index);
    end;
    for Index := 0 to ArgCount - 1 do
      if not SetPropertyByKey(R, Like.Value, IndexKey(R, Index), Args^[Index], True) then
        Exit(JsException);
  end;
  if not SetLengthOf(R, Like.Target, Like.Length + ArgCount) then
    Exit(JsException);
  Result := JsNumber(Like.Length + ArgCount);
end;

{ splice's moves when it takes out at least as many elements as it
  puts in, done on the elements of a dense array without holes from
  Start on: every index written is an own writable data property and
  the ones dropped are configurable, so nothing could observe the
  difference. False (nothing done) for any other array. }
function SpliceDenseInPlace(R: TJsRealm; Target: TJsObject; Length, Start, DeleteCount: Int64;
  Items: PJsValueArray; ItemCount: Integer): Boolean;
var
  Index: Int64;
begin
  if (ItemCount > DeleteCount) or not IsDense(Target) or (Target.ElementCount <> Length) or
    ((Target.ObjectFlags and (ObjectLengthReadOnly or ObjectElementsSealed)) <> 0) then
    Exit(False);
  for Index := Start to Length - 1 do
    if Target.Elements^[Index] = JsHole then
      Exit(False);
  if (ItemCount < DeleteCount) and (Length - Start - DeleteCount > 0) then
    Move(Target.Elements^[Start + DeleteCount], Target.Elements^[Start + ItemCount],
      (Length - Start - DeleteCount) * SizeOf(TJsValue));
  for Index := 0 to ItemCount - 1 do
    Target.Elements^[Start + Index] := Items^[Index];
  Result := TJsArray(Target).SetLength(R, LongWord(Length - DeleteCount + ItemCount));
end;

function ArraySplice(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Start, DeleteCount, ItemCount, Index, NewLength: Int64;
  Number: Double;
  Removed: TJsValue;
  RemovedArray: TJsObject;
  Value: TJsValue;
  Found, Mark: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Like.Length, 0, Start) then
    Exit(JsException);
  if ArgCount = 0 then
    DeleteCount := 0
  else if ArgCount = 1 then
    DeleteCount := Like.Length - Start
  else
  begin
    if not ToIntegerOrInfinity(R, Args^[1], Number) then
      Exit(JsException);
    if Number < 0 then
      Number := 0;
    if Number > Like.Length - Start then
      Number := Like.Length - Start;
    DeleteCount := Trunc(Number);
  end;
  ItemCount := 0;
  if ArgCount > 2 then
    ItemCount := ArgCount - 2;
  if Like.Length + ItemCount - DeleteCount > MaximumSafeLength then
    Exit(R.ThrowTypeError('Array length would exceed the maximum'));
  Removed := ArraySpeciesCreate(R, Like.Target, DeleteCount);
  if Removed = JsException then
    Exit(JsException);
  RemovedArray := JsAsObject(Removed);
  Mark := R.Runtime.PushRoot(Removed);
  try
    for Index := 0 to DeleteCount - 1 do
    begin
      Found := HasAt(R, Like.Target, Start + Index);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Start + Index);
        if (Value = JsException) or not DefineNext(R, RemovedArray, Index, Value) then
          Exit(JsException);
      end;
    end;
    if not SetPropertyByKey(R, Removed, R.LengthKey, JsNumber(DeleteCount), True) then
      Exit(JsException);
    if SpliceDenseInPlace(R, Like.Target, Like.Length, Start, DeleteCount, @Args^[Min(ArgCount, 2)], ItemCount) then
      Exit(Removed);
    NewLength := Like.Length - DeleteCount + ItemCount;
    if ItemCount < DeleteCount then
    begin
      for Index := Start to Like.Length - DeleteCount - 1 do
      begin
        Found := HasAt(R, Like.Target, Index + DeleteCount);
        if Found < 0 then
          Exit(JsException);
        if Found > 0 then
        begin
          Value := GetAt(R, Like.Target, Index + DeleteCount);
          if (Value = JsException) or not SetPropertyByKey(R, Like.Value, IndexKey(R, Index + ItemCount), Value,
            True) then
            Exit(JsException);
        end
        else if not DeleteAt(R, Like.Target, Index + ItemCount) then
          Exit(JsException);
      end;
      Index := Like.Length;
      while Index > NewLength do
      begin
        if not DeleteAt(R, Like.Target, Index - 1) then
          Exit(JsException);
        Dec(Index);
      end;
    end
    else if ItemCount > DeleteCount then
    begin
      Index := Like.Length - DeleteCount;
      while Index > Start do
      begin
        Found := HasAt(R, Like.Target, Index + DeleteCount - 1);
        if Found < 0 then
          Exit(JsException);
        if Found > 0 then
        begin
          Value := GetAt(R, Like.Target, Index + DeleteCount - 1);
          if (Value = JsException) or not SetPropertyByKey(R, Like.Value, IndexKey(R, Index + ItemCount - 1), Value,
            True) then
            Exit(JsException);
        end
        else if not DeleteAt(R, Like.Target, Index + ItemCount - 1) then
          Exit(JsException);
        Dec(Index);
      end;
    end;
    for Index := 0 to ItemCount - 1 do
      if not SetPropertyByKey(R, Like.Value, IndexKey(R, Start + Index), Args^[2 + Index], True) then
        Exit(JsException);
    if not SetLengthOf(R, Like.Target, NewLength) then
      Exit(JsException);
    Result := Removed;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArrayReverse(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Lower, Upper: Int64;
  LowerValue, UpperValue: TJsValue;
  LowerExists, UpperExists: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  Lower := 0;
  while Lower < Like.Length div 2 do
  begin
    Upper := Like.Length - Lower - 1;
    LowerExists := HasAt(R, Like.Target, Lower);
    if LowerExists < 0 then
      Exit(JsException);
    LowerValue := JsUndefined;
    if LowerExists > 0 then
    begin
      LowerValue := GetAt(R, Like.Target, Lower);
      if LowerValue = JsException then
        Exit(JsException);
    end;
    UpperExists := HasAt(R, Like.Target, Upper);
    if UpperExists < 0 then
      Exit(JsException);
    UpperValue := JsUndefined;
    if UpperExists > 0 then
    begin
      UpperValue := GetAt(R, Like.Target, Upper);
      if UpperValue = JsException then
        Exit(JsException);
    end;
    if UpperExists > 0 then
    begin
      if not SetAt(R, Like.Target, Lower, UpperValue) then
        Exit(JsException);
    end
    else if not DeleteAt(R, Like.Target, Lower) then
      Exit(JsException);
    if LowerExists > 0 then
    begin
      if not SetAt(R, Like.Target, Upper, LowerValue) then
        Exit(JsException);
    end
    else if not DeleteAt(R, Like.Target, Upper) then
      Exit(JsException);
    Inc(Lower);
  end;
  Result := Like.Value;
end;

function ArrayFill(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Start, Finish, Index: Int64;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 1), Like.Length, 0, Start) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 2), Like.Length, Like.Length, Finish) then
    Exit(JsException);
  for Index := Start to Finish - 1 do
    if not SetPropertyByKey(R, Like.Value, IndexKey(R, Index), Arg(Args, ArgCount, 0), True) then
      Exit(JsException);
  Result := Like.Value;
end;

function ArrayCopyWithin(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Target, Start, Finish, Count, Direction, From, To_: Int64;
  Value: TJsValue;
  Found: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Like.Length, 0, Target) or
    not RelativeIndex(R, Arg(Args, ArgCount, 1), Like.Length, 0, Start) or
    not RelativeIndex(R, Arg(Args, ArgCount, 2), Like.Length, Like.Length, Finish) then
    Exit(JsException);
  Count := Min(Finish - Start, Like.Length - Target);
  if (Start < Target) and (Target < Start + Count) then
  begin
    Direction := -1;
    From := Start + Count - 1;
    To_ := Target + Count - 1;
  end
  else
  begin
    Direction := 1;
    From := Start;
    To_ := Target;
  end;
  while Count > 0 do
  begin
    Found := HasAt(R, Like.Target, From);
    if Found < 0 then
      Exit(JsException);
    if Found > 0 then
    begin
      Value := GetAt(R, Like.Target, From);
      if (Value = JsException) or not SetPropertyByKey(R, Like.Value, IndexKey(R, To_), Value, True) then
        Exit(JsException);
    end
    else if not DeleteAt(R, Like.Target, To_) then
      Exit(JsException);
    Inc(From, Direction);
    Inc(To_, Direction);
    Dec(Count);
  end;
  Result := Like.Value;
end;

{ Sorting }

type
  TSortContext = record
    Realm: TJsRealm;
    Comparator: TJsValue;
    Failed: Boolean;
  end;

{ a < b by the comparator or the default string order; -1 on throw. }
function SortCompare(var Context: TSortContext; A, B: TJsValue): Integer;
var
  Pair: array[0..1] of TJsValue;
  Outcome: TJsValue;
  Number: Double;
  Left, Right: TJsString;
begin
  Result := 0;
  if Context.Failed then
    Exit;
  if A = JsUndefined then
  begin
    if B = JsUndefined then
      Exit(0);
    Exit(1);
  end;
  if B = JsUndefined then
    Exit(-1);
  if Context.Comparator <> JsUndefined then
  begin
    Pair[0] := A;
    Pair[1] := B;
    Outcome := Context.Realm.Call(Context.Comparator, JsUndefined, @Pair[0], 2);
    if Outcome = JsException then
    begin
      Context.Failed := True;
      Exit(0);
    end;
    if not ToDouble(Context.Realm, Outcome, Number) then
    begin
      Context.Failed := True;
      Exit(0);
    end;
    if Number < 0 then
      Exit(-1);
    if Number > 0 then
      Exit(1);
    Exit(0);
  end;
  if JsIsInteger(A) and JsIsInteger(B) and (JsAsInteger(A) >= 0) and (JsAsInteger(B) >= 0) and
    (((JsAsInteger(A) < 10) and (JsAsInteger(B) < 10))) then
    Exit(JsAsInteger(A) - JsAsInteger(B));
  Left := ToJsString(Context.Realm, A);
  if Left = nil then
  begin
    Context.Failed := True;
    Exit(0);
  end;
  Right := ToJsString(Context.Realm, B);
  if Right = nil then
  begin
    Context.Failed := True;
    Exit(0);
  end;
  Result := CompareStrings(Context.Realm.Heap, Left, Right);
end;

procedure MergeSort(var Context: TSortContext; var Values, Scratch: TJsValueList; Low, High: Integer);
var
  Middle, Left, Right, Position: Integer;
begin
  if (High - Low < 1) or Context.Failed then
    Exit;
  if High - Low < 8 then
  begin
    { Insertion sort for short runs (stable). }
    for Left := Low + 1 to High do
    begin
      Scratch[0] := Values[Left];
      Position := Left - 1;
      while (Position >= Low) and (SortCompare(Context, Values[Position], Scratch[0]) > 0) do
      begin
        Values[Position + 1] := Values[Position];
        Dec(Position);
      end;
      Values[Position + 1] := Scratch[0];
      if Context.Failed then
        Exit;
    end;
    Exit;
  end;
  Middle := (Low + High) div 2;
  MergeSort(Context, Values, Scratch, Low, Middle);
  MergeSort(Context, Values, Scratch, Middle + 1, High);
  if Context.Failed then
    Exit;
  if SortCompare(Context, Values[Middle], Values[Middle + 1]) <= 0 then
    Exit;
  for Position := Low to High do
    Scratch[Position + 1] := Values[Position];
  Left := Low;
  Right := Middle + 1;
  Position := Low;
  while (Left <= Middle) and (Right <= High) do
  begin
    if SortCompare(Context, Scratch[Right + 1], Scratch[Left + 1]) < 0 then
    begin
      Values[Position] := Scratch[Right + 1];
      Inc(Right);
    end
    else
    begin
      Values[Position] := Scratch[Left + 1];
      Inc(Left);
    end;
    Inc(Position);
  end;
  while Left <= Middle do
  begin
    Values[Position] := Scratch[Left + 1];
    Inc(Left);
    Inc(Position);
  end;
  while Right <= High do
  begin
    Values[Position] := Scratch[Right + 1];
    Inc(Right);
    Inc(Position);
  end;
end;

{ The values of the array-like with holes left out, sorted; the hole
  count in Holes. }
function SortedValues(R: TJsRealm; const Like: TArrayLike; Comparator: TJsValue; out Values: TJsValueList;
  out Holes: Int64): Boolean;
var
  Index: Int64;
  Count, Mark: Integer;
  Found: Integer;
  Value: TJsValue;
  Context: TSortContext;
  Scratch: TJsValueList;
  Holder: TJsArray;
begin
  Values := nil;
  Holes := 0;
  SetLength(Values, Like.Length);
  Count := 0;
  for Index := 0 to Like.Length - 1 do
  begin
    Found := HasAt(R, Like.Target, Index);
    if Found < 0 then
      Exit(False);
    if Found = 0 then
    begin
      Inc(Holes);
      Continue;
    end;
    Value := GetAt(R, Like.Target, Index);
    if Value = JsException then
      Exit(False);
    Values[Count] := Value;
    Inc(Count);
  end;
  SetLength(Values, Count);
  { The values are kept alive by an array while comparators run. }
  Holder := R.NewArrayFrom(@Values[0], Count);
  Mark := R.Runtime.PushRoot(JsObjectValue(Holder));
  try
    Context.Realm := R;
    Context.Comparator := Comparator;
    Context.Failed := False;
    Scratch := nil;
    SetLength(Scratch, Count + 2);
    MergeSort(Context, Values, Scratch, 0, Count - 1);
    Result := not Context.Failed;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArraySort(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Comparator: TJsValue;
  Values: TJsValueList;
  Holes, Index: Int64;
begin
  Comparator := Arg(Args, ArgCount, 0);
  if (Comparator <> JsUndefined) and not JsIsCallable(Comparator) then
    Exit(R.ThrowTypeError('The comparison function must be either a function or undefined'));
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not SortedValues(R, Like, Comparator, Values, Holes) then
    Exit(JsException);
  for Index := 0 to High(Values) do
    if not SetAt(R, Like.Target, Index, Values[Index]) then
      Exit(JsException);
  for Index := Length(Values) to Like.Length - 1 do
    if not DeleteAt(R, Like.Target, Index) then
      Exit(JsException);
  Result := Like.Value;
end;

function ArrayToSorted(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Comparator: TJsValue;
  Values: TJsValueList;
  Holes: Int64;
  Created: TJsArray;
  Index: Integer;
begin
  Comparator := Arg(Args, ArgCount, 0);
  if (Comparator <> JsUndefined) and not JsIsCallable(Comparator) then
    Exit(R.ThrowTypeError('The comparison function must be either a function or undefined'));
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if Like.Length > High(LongWord) then
    Exit(R.ThrowRangeError('Invalid array length'));
  if not SortedValues(R, Like, Comparator, Values, Holes) then
    Exit(JsException);
  Created := R.NewArrayFrom(@Values[0], Length(Values));
  for Index := 1 to Holes do
    Created.CreateDataProperty(R, JsInteger(Created.ArrayLength), JsUndefined);
  Result := JsObjectValue(Created);
end;

{ Searching and iteration }

{ forEach, map, filter, some, every, find, findIndex, findLast,
  findLastIndex: Magic selects. }
const
  IterateForEach = 0;
  IterateMap = 1;
  IterateFilter = 2;
  IterateSome = 3;
  IterateEvery = 4;
  IterateFind = 5;
  IterateFindIndex = 6;
  IterateFindLast = 7;
  IterateFindLastIndex = 8;

function ArrayIterate(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Callback, ThisArgument, Value, Outcome, Created: TJsValue;
  Index, Step, Last, Kept: Int64;
  Found, Mark: Integer;
  Triple: array[0..2] of TJsValue;
  Operation: Integer;
  Target: TJsObject;
begin
  Operation := Callee.Magic;
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  Callback := Arg(Args, ArgCount, 0);
  if not RequireCallable(R, Callback) then
    Exit(JsException);
  ThisArgument := Arg(Args, ArgCount, 1);
  Created := JsUndefined;
  Target := nil;
  if Operation in [IterateMap, IterateFilter] then
  begin
    if Operation = IterateMap then
      Created := ArraySpeciesCreate(R, Like.Target, Like.Length)
    else
      Created := ArraySpeciesCreate(R, Like.Target, 0);
    if Created = JsException then
      Exit(JsException);
    Target := JsAsObject(Created);
  end;
  Mark := R.Runtime.PushRoot(Like.Value);
  R.Runtime.PushRoot(Created);
  R.Runtime.PushRoot(JsUndefined);
  try
    if Operation in [IterateFindLast, IterateFindLastIndex] then
    begin
      Index := Like.Length - 1;
      Step := -1;
      Last := -1;
    end
    else
    begin
      Index := 0;
      Step := 1;
      Last := Like.Length;
    end;
    Kept := 0;
    while Index <> Last do
    begin
      if Operation in [IterateFind, IterateFindIndex, IterateFindLast, IterateFindLastIndex] then
        Found := 1
      else
      begin
        Found := HasAt(R, Like.Target, Index);
        if Found < 0 then
          Exit(JsException);
      end;
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Index);
        if Value = JsException then
          Exit(JsException);
        R.Runtime.SetRoot(Mark + 2, Value);
        Triple[0] := Value;
        Triple[1] := JsNumber(Index);
        Triple[2] := Like.Value;
        Outcome := R.Call(Callback, ThisArgument, @Triple[0], 3);
        if Outcome = JsException then
          Exit(JsException);
        case Operation of
          IterateMap:
            if not DefineNext(R, Target, Index, Outcome) then
              Exit(JsException);
          IterateFilter:
            if ToBoolean(Outcome) then
            begin
              if not DefineNext(R, Target, Kept, Value) then
                Exit(JsException);
              Inc(Kept);
            end;
          IterateSome:
            if ToBoolean(Outcome) then
              Exit(JsTrue);
          IterateEvery:
            if not ToBoolean(Outcome) then
              Exit(JsFalse);
          IterateFind, IterateFindLast:
            if ToBoolean(Outcome) then
              Exit(Value);
          IterateFindIndex, IterateFindLastIndex:
            if ToBoolean(Outcome) then
              Exit(JsNumber(Index));
        end;
      end;
      Inc(Index, Step);
    end;
    case Operation of
      IterateMap, IterateFilter: Result := Created;
      IterateSome: Result := JsFalse;
      IterateEvery: Result := JsTrue;
      IterateFindIndex, IterateFindLastIndex: Result := JsInteger(-1);
    else
      Result := JsUndefined;
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArrayReduce(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Callback, Accumulator, Value: TJsValue;
  Index, Step, Last: Int64;
  Found, Mark: Integer;
  Quad: array[0..3] of TJsValue;
  HasAccumulator: Boolean;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  Callback := Arg(Args, ArgCount, 0);
  if not RequireCallable(R, Callback) then
    Exit(JsException);
  if Callee.Magic = 0 then
  begin
    Index := 0;
    Step := 1;
    Last := Like.Length;
  end
  else
  begin
    Index := Like.Length - 1;
    Step := -1;
    Last := -1;
  end;
  HasAccumulator := ArgCount > 1;
  Accumulator := Arg(Args, ArgCount, 1);
  Mark := R.Runtime.PushRoot(Like.Value);
  R.Runtime.PushRoot(Accumulator);
  try
    while (not HasAccumulator) and (Index <> Last) do
    begin
      Found := HasAt(R, Like.Target, Index);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Accumulator := GetAt(R, Like.Target, Index);
        if Accumulator = JsException then
          Exit(JsException);
        HasAccumulator := True;
      end;
      Inc(Index, Step);
    end;
    if not HasAccumulator then
      Exit(R.ThrowTypeError('Reduce of empty array with no initial value'));
    while Index <> Last do
    begin
      Found := HasAt(R, Like.Target, Index);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Index);
        if Value = JsException then
          Exit(JsException);
        R.Runtime.SetRoot(Mark + 1, Accumulator);
        Quad[0] := Accumulator;
        Quad[1] := Value;
        Quad[2] := JsNumber(Index);
        Quad[3] := Like.Value;
        Accumulator := R.Call(Callback, JsUndefined, @Quad[0], 4);
        if Accumulator = JsException then
          Exit(JsException);
      end;
      Inc(Index, Step);
    end;
    Result := Accumulator;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ indexOf (0), lastIndexOf (1), includes (2). }
function ArraySearch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Wanted, Value: TJsValue;
  Index: Int64;
  Number: Double;
  Found: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  Wanted := Arg(Args, ArgCount, 0);
  if Like.Length = 0 then
  begin
    if Callee.Magic = 2 then
      Exit(JsFalse);
    Exit(JsInteger(-1));
  end;
  if Callee.Magic = 1 then
  begin
    Index := Like.Length - 1;
    if ArgCount > 1 then
    begin
      if not ToIntegerOrInfinity(R, Args^[1], Number) then
        Exit(JsException);
      if Number < 0 then
        Number := Like.Length + Number
      else if Number > Like.Length - 1 then
        Number := Like.Length - 1;
      if Number < 0 then
        Exit(JsInteger(-1));
      Index := Trunc(Number);
    end;
    while Index >= 0 do
    begin
      Found := HasAt(R, Like.Target, Index);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Index);
        if Value = JsException then
          Exit(JsException);
        if StrictEquals(Value, Wanted, R.Heap) then
          Exit(JsNumber(Index));
      end;
      Dec(Index);
    end;
    Exit(JsInteger(-1));
  end;
  if not RelativeIndex(R, Arg(Args, ArgCount, 1), Like.Length, 0, Index) then
    Exit(JsException);
  while Index < Like.Length do
  begin
    if Callee.Magic = 2 then
    begin
      Value := GetAt(R, Like.Target, Index);
      if Value = JsException then
        Exit(JsException);
      if SameValueZero(Value, Wanted, R.Heap) then
        Exit(JsTrue);
    end
    else
    begin
      Found := HasAt(R, Like.Target, Index);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Index);
        if Value = JsException then
          Exit(JsException);
        if StrictEquals(Value, Wanted, R.Heap) then
          Exit(JsNumber(Index));
      end;
    end;
    Inc(Index);
  end;
  if Callee.Magic = 2 then
    Result := JsFalse
  else
    Result := JsInteger(-1);
end;

{ Building }

function ArrayJoinValues(R: TJsRealm; const Like: TArrayLike; Separator: TJsString): TJsValue;
var
  Index: Int64;
  Value: TJsValue;
  Text: TJsString;
  Pieces: array of TJsString;
  Total, Position, Count: Integer;
  Wide: Boolean;
  Outcome: TJsString;
  Mark, PieceIndex, Unit_: Integer;
  Holder: TJsArray;
begin
  if Like.Length = 0 then
    Exit(R.Atom(anEmpty));
  Pieces := nil;
  SetLength(Pieces, Like.Length);
  Holder := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Holder));
  try
    Total := 0;
    Wide := Separator.IsWide;
    for Index := 0 to Like.Length - 1 do
    begin
      Value := GetAt(R, Like.Target, Index);
      if Value = JsException then
        Exit(JsException);
      if JsIsNullish(Value) then
        Text := R.Runtime.EmptyString
      else
      begin
        Text := ToJsString(R, Value);
        if Text = nil then
          Exit(JsException);
      end;
      Text.Flatten(R.Heap);
      AppendElement(R, Holder, JsStringValue(Text));
      Pieces[Index] := Text;
      Inc(Total, Text.Length);
      if Text.IsWide then
        Wide := True;
      if Index > 0 then
        Inc(Total, Separator.Length);
      if Total > JsMaximumStringLength then
        Exit(R.ThrowRangeError('Invalid string length'));
    end;
    Separator.Flatten(R.Heap);
    Outcome := NewBlankString(R.Heap, Total, Wide);
    Position := 0;
    Count := Length(Pieces);
    for PieceIndex := 0 to Count - 1 do
    begin
      if PieceIndex > 0 then
      begin
        for Unit_ := 0 to Separator.Length - 1 do
          if Wide then
            Outcome.Chars16[Position + Unit_] := Separator.CharAt(Unit_)
          else
            Outcome.Chars8[Position + Unit_] := Separator.CharAt(Unit_);
        Inc(Position, Separator.Length);
      end;
      Text := Pieces[PieceIndex];
      if Wide then
        for Unit_ := 0 to Text.Length - 1 do
          Outcome.Chars16[Position + Unit_] := Text.CharAt(Unit_)
      else if Text.Length > 0 then
        Move(Text.Chars8^, Outcome.Chars8[Position], Text.Length);
      Inc(Position, Text.Length);
    end;
    Result := JsStringValue(Outcome);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

var
  JoinNesting: array of TJsObject;

function ArrayJoin(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Separator: TJsString;
  Index: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if Arg(Args, ArgCount, 0) = JsUndefined then
    Separator := R.Runtime.CharacterString(Ord(','))
  else
  begin
    Separator := ToJsString(R, Args^[0]);
    if Separator = nil then
      Exit(JsException);
  end;
  { A cycle joins as an empty string. }
  for Index := 0 to High(JoinNesting) do
    if JoinNesting[Index] = Like.Target then
      Exit(R.Atom(anEmpty));
  SetLength(JoinNesting, Length(JoinNesting) + 1);
  JoinNesting[High(JoinNesting)] := Like.Target;
  try
    Result := ArrayJoinValues(R, Like, Separator);
  finally
    SetLength(JoinNesting, Length(JoinNesting) - 1);
  end;
end;

function ArrayToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target, Join: TJsValue;
begin
  Target := ToObject(R, This);
  if Target = JsException then
    Exit(JsException);
  Join := JsAsObject(Target).GetValue(R, R.Atom(anJoin));
  if Join = JsException then
    Exit(JsException);
  if JsIsCallable(Join) then
    Exit(R.Call(Join, Target, nil, 0));
  Result := R.NewString('[object Array]');
end;

function ArrayToLocaleString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Index: Int64;
  Value: TJsValue;
  Text: TJsString;
  Outcome: TJsString;
  Comma: TJsString;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  Outcome := R.Runtime.EmptyString;
  Comma := R.Runtime.CharacterString(Ord(','));
  for Index := 0 to Like.Length - 1 do
  begin
    if Index > 0 then
      Outcome := ConcatStrings(R.Heap, Outcome, Comma);
    Value := GetAt(R, Like.Target, Index);
    if Value = JsException then
      Exit(JsException);
    if not JsIsNullish(Value) then
    begin
      Value := CallMethod(R, Value, anToLocaleString, nil, 0);
      if Value = JsException then
        Exit(JsException);
      Text := ToJsString(R, Value);
      if Text = nil then
        Exit(JsException);
      Outcome := ConcatStrings(R.Heap, Outcome, Text);
    end;
  end;
  Result := JsStringValue(Outcome);
end;

function IsConcatSpreadable(R: TJsRealm; Value: TJsValue; out Spreadable: Boolean): Boolean;
var
  Flag: TJsValue;
begin
  Spreadable := False;
  if not JsIsObject(Value) then
    Exit(True);
  Flag := JsAsObject(Value).GetValue(R, R.Runtime.SymbolValue(wsIsConcatSpreadable));
  if Flag = JsException then
    Exit(False);
  if Flag <> JsUndefined then
    Spreadable := ToBoolean(Flag)
  else
    Exit(IsArray(R, Value, Spreadable));
  Result := True;
end;

function ArrayConcat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Self_, Created, Item, Value: TJsValue;
  Target, Source: TJsObject;
  Count, Index, Length: Int64;
  ItemIndex, Found, Mark: Integer;
  Spreadable: Boolean;
begin
  Self_ := ToObject(R, This);
  if Self_ = JsException then
    Exit(JsException);
  Created := ArraySpeciesCreate(R, JsAsObject(Self_), 0);
  if Created = JsException then
    Exit(JsException);
  Target := JsAsObject(Created);
  Mark := R.Runtime.PushRoot(Created);
  try
    Count := 0;
    for ItemIndex := -1 to ArgCount - 1 do
    begin
      if ItemIndex < 0 then
        Item := Self_
      else
        Item := Args^[ItemIndex];
      if not IsConcatSpreadable(R, Item, Spreadable) then
        Exit(JsException);
      if Spreadable then
      begin
        Source := JsAsObject(Item);
        if not LengthOfArrayLike(R, Source, Length) then
          Exit(JsException);
        if Count + Length > MaximumSafeLength then
          Exit(R.ThrowTypeError('Invalid array length'));
        if IsDense(Source) and IsDense(Target) and (Count = Target.ElementCount) and (Count + Length < MaxInt) then
        begin
          Target.EnsureElementCapacity(R, Count + Length);
          if Length > 0 then
            Move(Source.Elements^[0], Target.Elements^[Count], Length * SizeOf(TJsValue));
          Target.ElementCount := Count + Length;
          TJsArray(Target).ArrayLength := Count + Length;
          Inc(Count, Length);
          Continue;
        end;
        for Index := 0 to Length - 1 do
        begin
          Found := HasAt(R, Source, Index);
          if Found < 0 then
            Exit(JsException);
          if Found > 0 then
          begin
            Value := GetAt(R, Source, Index);
            if (Value = JsException) or not DefineAt(R, Target, Count, Value) then
              Exit(JsException);
          end;
          Inc(Count);
        end;
      end
      else
      begin
        if not DefineAt(R, Target, Count, Item) then
          Exit(JsException);
        Inc(Count);
      end;
    end;
    if not SetPropertyByKey(R, Created, R.LengthKey, JsNumber(Count), True) then
      Exit(JsException);
    Result := Created;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArraySlice(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Start, Finish, Index, Count: Int64;
  Created, Value: TJsValue;
  Target: TJsObject;
  Found, Mark: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Like.Length, 0, Start) or
    not RelativeIndex(R, Arg(Args, ArgCount, 1), Like.Length, Like.Length, Finish) then
    Exit(JsException);
  Count := Max(Finish - Start, 0);
  if IsDense(Like.Target) and (Like.Target.Proto = R.Intrinsics[inArrayPrototype]) and
    (Like.Target.Shape.Find(R.ConstructorKey, PByte(@Found)^) < 0) then
    Exit(JsObjectValue(R.NewArrayFrom(@Like.Target.Elements^[Start], Count)));
  Created := ArraySpeciesCreate(R, Like.Target, Count);
  if Created = JsException then
    Exit(JsException);
  Target := JsAsObject(Created);
  Mark := R.Runtime.PushRoot(Created);
  try
    for Index := 0 to Count - 1 do
    begin
      Found := HasAt(R, Like.Target, Start + Index);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        Value := GetAt(R, Like.Target, Start + Index);
        if (Value = JsException) or not DefineAt(R, Target, Index, Value) then
          Exit(JsException);
      end;
    end;
    if not SetPropertyByKey(R, Created, R.LengthKey, JsNumber(Count), True) then
      Exit(JsException);
    Result := Created;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function FlattenInto(R: TJsRealm; Target: TJsObject; Source: TJsObject; SourceLength: Int64; var Position: Int64;
  Depth: Double; Mapper, ThisArgument: TJsValue): Boolean;
var
  Index, ElementLength: Int64;
  Value: TJsValue;
  Found: Integer;
  Triple: array[0..2] of TJsValue;
  Spread: Boolean;
begin
  for Index := 0 to SourceLength - 1 do
  begin
    Found := HasAt(R, Source, Index);
    if Found < 0 then
      Exit(False);
    if Found = 0 then
      Continue;
    Value := GetAt(R, Source, Index);
    if Value = JsException then
      Exit(False);
    if Mapper <> JsUndefined then
    begin
      Triple[0] := Value;
      Triple[1] := JsNumber(Index);
      Triple[2] := JsObjectValue(Source);
      Value := R.Call(Mapper, ThisArgument, @Triple[0], 3);
      if Value = JsException then
        Exit(False);
    end;
    Spread := False;
    if (Depth > 0) and not IsArray(R, Value, Spread) then
      Exit(False);
    if Spread then
    begin
      if not LengthOfArrayLike(R, JsAsObject(Value), ElementLength) then
        Exit(False);
      if not FlattenInto(R, Target, JsAsObject(Value), ElementLength, Position, Depth - 1, JsUndefined,
        JsUndefined) then
        Exit(False);
    end
    else
    begin
      if not DefineAt(R, Target, Position, Value) then
        Exit(False);
      Inc(Position);
    end;
  end;
  Result := True;
end;

{ flat (0) and flatMap (1). }
function ArrayFlat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Depth: Double;
  Created: TJsValue;
  Position: Int64;
  Mark: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  Depth := 1;
  if Callee.Magic = 1 then
  begin
    if not RequireCallable(R, Arg(Args, ArgCount, 0)) then
      Exit(JsException);
  end
  else if Arg(Args, ArgCount, 0) <> JsUndefined then
  begin
    if not ToIntegerOrInfinity(R, Args^[0], Depth) then
      Exit(JsException);
    if Depth < 0 then
      Depth := 0;
  end;
  Created := ArraySpeciesCreate(R, Like.Target, 0);
  if Created = JsException then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Created);
  try
    Position := 0;
    if Callee.Magic = 1 then
    begin
      if not FlattenInto(R, JsAsObject(Created), Like.Target, Like.Length, Position, 1, Args^[0],
        Arg(Args, ArgCount, 1)) then
        Exit(JsException);
    end
    else if not FlattenInto(R, JsAsObject(Created), Like.Target, Like.Length, Position, Depth, JsUndefined,
      JsUndefined) then
      Exit(JsException);
    Result := Created;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArrayAt(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Number: Double;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if Number < 0 then
    Number := Like.Length + Number;
  if (Number < 0) or (Number >= Like.Length) then
    Exit(JsUndefined);
  Result := GetAt(R, Like.Target, Trunc(Number));
end;

{ keys (0), values (1), entries (2). }
function ArrayIterator(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsValue;
begin
  Target := ToObject(R, This);
  if Target = JsException then
    Exit(JsException);
  Result := CreateArrayIterator(R, Target, Callee.Magic);
end;

function ArrayToReversed(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Created: TJsArray;
  Index: Int64;
  Value: TJsValue;
  Mark: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if Like.Length > High(LongWord) then
    Exit(R.ThrowRangeError('Invalid array length'));
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  try
    for Index := 0 to Like.Length - 1 do
    begin
      Value := GetAt(R, Like.Target, Like.Length - 1 - Index);
      if Value = JsException then
        Exit(JsException);
      Created.CreateDataProperty(R, IndexKey(R, Index), Value);
    end;
    Result := JsObjectValue(Created);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArrayWith(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Created: TJsArray;
  Index, Chosen: Int64;
  Number: Double;
  Value: TJsValue;
  Mark: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if Number < 0 then
    Number := Like.Length + Number;
  if (Number < 0) or (Number >= Like.Length) then
    Exit(R.ThrowRangeError('Invalid index : ' + ValueToPascal(R, Arg(Args, ArgCount, 0))));
  Chosen := Trunc(Number);
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  try
    for Index := 0 to Like.Length - 1 do
    begin
      if Index = Chosen then
        Value := Arg(Args, ArgCount, 1)
      else
      begin
        Value := GetAt(R, Like.Target, Index);
        if Value = JsException then
          Exit(JsException);
      end;
      Created.CreateDataProperty(R, IndexKey(R, Index), Value);
    end;
    Result := JsObjectValue(Created);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ArrayToSpliced(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Like: TArrayLike;
  Start, Skip, Index, Position: Int64;
  Number: Double;
  Created: TJsArray;
  Value: TJsValue;
  Mark, Item: Integer;
begin
  if not ThisArrayLike(R, This, Like) then
    Exit(JsException);
  if not RelativeIndex(R, Arg(Args, ArgCount, 0), Like.Length, 0, Start) then
    Exit(JsException);
  if ArgCount = 0 then
    Skip := 0
  else if ArgCount = 1 then
    Skip := Like.Length - Start
  else
  begin
    if not ToIntegerOrInfinity(R, Args^[1], Number) then
      Exit(JsException);
    Number := Max(0, Min(Number, Like.Length - Start));
    Skip := Trunc(Number);
  end;
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  try
    Position := 0;
    for Index := 0 to Start - 1 do
    begin
      Value := GetAt(R, Like.Target, Index);
      if Value = JsException then
        Exit(JsException);
      Created.CreateDataProperty(R, IndexKey(R, Position), Value);
      Inc(Position);
    end;
    for Item := 2 to ArgCount - 1 do
    begin
      Created.CreateDataProperty(R, IndexKey(R, Position), Args^[Item]);
      Inc(Position);
    end;
    for Index := Start + Skip to Like.Length - 1 do
    begin
      Value := GetAt(R, Like.Target, Index);
      if Value = JsException then
        Exit(JsException);
      Created.CreateDataProperty(R, IndexKey(R, Position), Value);
      Inc(Position);
    end;
    Result := JsObjectValue(Created);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

procedure InstallArray(R: TJsInterpreterRealm);
var
  Prototype, Unscopables: TJsObject;
  Constructor_: TJsNativeFunction;
  Values: TJsValue;
  Name: string;
begin
  Prototype := R.Intrinsics[inArrayPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Array', @ArrayConstructor, 1, Prototype);
  R.Intrinsics[inArray] := Constructor_;
  DefineMethod(R, Constructor_, 'isArray', @ArrayIsArray, 1);
  DefineMethod(R, Constructor_, 'of', @ArrayOf, 0);
  DefineMethod(R, Constructor_, 'from', @ArrayFrom, 1);
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies),
    JsObjectValue(NewNativeFunction(R, 'get [Symbol.species]', @ArraySpecies, 0)), JsUndefined, PropertyConfigurable);
  DefineMethod(R, Prototype, 'at', @ArrayAt, 1);
  DefineMethod(R, Prototype, 'concat', @ArrayConcat, 1);
  DefineMethod(R, Prototype, 'copyWithin', @ArrayCopyWithin, 2);
  DefineMethod(R, Prototype, 'fill', @ArrayFill, 1);
  DefineMethod(R, Prototype, 'forEach', @ArrayIterate, 1, IterateForEach);
  DefineMethod(R, Prototype, 'map', @ArrayIterate, 1, IterateMap);
  DefineMethod(R, Prototype, 'filter', @ArrayIterate, 1, IterateFilter);
  DefineMethod(R, Prototype, 'some', @ArrayIterate, 1, IterateSome);
  DefineMethod(R, Prototype, 'every', @ArrayIterate, 1, IterateEvery);
  DefineMethod(R, Prototype, 'find', @ArrayIterate, 1, IterateFind);
  DefineMethod(R, Prototype, 'findIndex', @ArrayIterate, 1, IterateFindIndex);
  DefineMethod(R, Prototype, 'findLast', @ArrayIterate, 1, IterateFindLast);
  DefineMethod(R, Prototype, 'findLastIndex', @ArrayIterate, 1, IterateFindLastIndex);
  DefineMethod(R, Prototype, 'reduce', @ArrayReduce, 1, 0);
  DefineMethod(R, Prototype, 'reduceRight', @ArrayReduce, 1, 1);
  DefineMethod(R, Prototype, 'indexOf', @ArraySearch, 1, 0);
  DefineMethod(R, Prototype, 'lastIndexOf', @ArraySearch, 1, 1);
  DefineMethod(R, Prototype, 'includes', @ArraySearch, 1, 2);
  DefineMethod(R, Prototype, 'join', @ArrayJoin, 1);
  DefineMethod(R, Prototype, 'toString', @ArrayToString, 0);
  DefineMethod(R, Prototype, 'toLocaleString', @ArrayToLocaleString, 0);
  DefineMethod(R, Prototype, 'push', @ArrayPush, 1);
  DefineMethod(R, Prototype, 'pop', @ArrayPop, 0);
  DefineMethod(R, Prototype, 'shift', @ArrayShift, 0);
  DefineMethod(R, Prototype, 'unshift', @ArrayUnshift, 1);
  DefineMethod(R, Prototype, 'splice', @ArraySplice, 2);
  DefineMethod(R, Prototype, 'slice', @ArraySlice, 2);
  DefineMethod(R, Prototype, 'reverse', @ArrayReverse, 0);
  DefineMethod(R, Prototype, 'sort', @ArraySort, 1);
  DefineMethod(R, Prototype, 'flat', @ArrayFlat, 0, 0);
  DefineMethod(R, Prototype, 'flatMap', @ArrayFlat, 1, 1);
  DefineMethod(R, Prototype, 'keys', @ArrayIterator, 0, IterateKeys);
  DefineMethod(R, Prototype, 'entries', @ArrayIterator, 0, IterateEntries);
  DefineMethod(R, Prototype, 'values', @ArrayIterator, 0, IterateValues);
  DefineMethod(R, Prototype, 'toReversed', @ArrayToReversed, 0);
  DefineMethod(R, Prototype, 'toSorted', @ArrayToSorted, 1);
  DefineMethod(R, Prototype, 'toSpliced', @ArrayToSpliced, 2);
  DefineMethod(R, Prototype, 'with', @ArrayWith, 2);
  Values := Prototype.GetValue(R, R.Intern('values'));
  R.Intrinsics[inArrayValues] := JsAsObject(Values);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsIterator), Values, PropertyHidden);
  Unscopables := R.NewObject(nil);
  for Name in ['at', 'copyWithin', 'entries', 'fill', 'find', 'findIndex', 'findLast', 'findLastIndex', 'flat',
    'flatMap', 'includes', 'keys', 'toReversed', 'toSorted', 'toSpliced', 'values'] do
    Unscopables.DefineData(R, R.Intern(Name), JsTrue);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsUnscopables), JsObjectValue(Unscopables), PropertyConfigurable);
end;

end.
