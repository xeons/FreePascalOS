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
  The iterator objects of the built-ins: %IteratorPrototype%, array
  iterators (keys, values, entries over any array-like) and string
  iterators (by code point), and the iterator helpers of
  Iterator.prototype (map, filter, take, drop, flatMap, reduce,
  toArray, forEach, some, every, find) with Iterator.from.

  The array iterator's next is marked (Magic $A11) so that for-of and
  spreading recognise it untouched and walk plain arrays directly.
}
unit Js.Builtins.Iterators;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
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
  Js.Interpreter;

const
  IterateKeys = 0;
  IterateValues = 1;
  IterateEntries = 2;
  ArrayIteratorNextMagic = $A11;

type
  TJsArrayIterator = class(TJsObject)
  public
    Target: TJsValue;
    Position: Int64;
    IterationKind: Integer;
    Done: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  TJsStringIterator = class(TJsObject)
  public
    Text: TJsString;
    Position: Integer;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  { An iterator helper: the underlying iterator and what to do. }
  TJsIteratorHelper = class(TJsObject)
  public
    Underlying: TJsIteratorRecord;
    Mapper: TJsValue;
    Operation: Integer;
    Counter: Int64;
    Limit: Double;
    Inner: TJsIteratorRecord;
    InnerActive: Boolean;
    Done: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

procedure InstallIterators(R: TJsInterpreterRealm);
function CreateArrayIterator(R: TJsRealm; Target: TJsValue; Kind: Integer): TJsValue;
function CreateStringIterator(R: TJsRealm; Text: TJsString): TJsValue;

implementation

procedure TJsArrayIterator.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Target);
end;

procedure TJsStringIterator.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Text);
end;

procedure TJsIteratorHelper.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Underlying.Iterator);
  Tracer.MarkValue(Underlying.NextMethod);
  Tracer.MarkValue(Mapper);
  Tracer.MarkValue(Inner.Iterator);
  Tracer.MarkValue(Inner.NextMethod);
end;

function CreateArrayIterator(R: TJsRealm; Target: TJsValue; Kind: Integer): TJsValue;
var
  Iterator: TJsArrayIterator;
begin
  Iterator := TJsArrayIterator(R.NewObjectOfClass(TJsArrayIterator, R.Intrinsics[inArrayIteratorPrototype],
    ocIterator));
  Iterator.Target := Target;
  Iterator.IterationKind := Kind;
  Result := JsObjectValue(Iterator);
end;

function CreateStringIterator(R: TJsRealm; Text: TJsString): TJsValue;
var
  Iterator: TJsStringIterator;
begin
  Iterator := TJsStringIterator(R.NewObjectOfClass(TJsStringIterator, R.Intrinsics[inStringIteratorPrototype],
    ocIterator));
  Iterator.Text := Text;
  Result := JsObjectValue(Iterator);
end;

function IteratorPrototypeIterator(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

function ArrayIteratorNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Iterator: TJsArrayIterator;
  Target: TJsObject;
  Length: Int64;
  Value, Entry: TJsValue;
  Index: Int64;
  Pair: TJsArray;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsArrayIterator) then
    Exit(R.ThrowTypeError('next method called on incompatible receiver'));
  Iterator := TJsArrayIterator(JsAsObject(This));
  if Iterator.Done then
    Exit(CreateIterResult(R, JsUndefined, True));
  Target := JsAsObject(Iterator.Target);
  if not LengthOfArrayLike(R, Target, Length) then
    Exit(JsException);
  Index := Iterator.Position;
  if Index >= Length then
  begin
    Iterator.Done := True;
    Iterator.Target := JsUndefined;
    Exit(CreateIterResult(R, JsUndefined, True));
  end;
  Iterator.Position := Index + 1;
  if Iterator.IterationKind = IterateKeys then
    Exit(CreateIterResult(R, JsNumber(Index), False));
  if (Index < Target.ElementCount) and (Target.Elements^[Index] <> JsHole) and
    ((Target.ObjectFlags and ObjectExotic) = 0) then
    Value := Target.Elements^[Index]
  else
  begin
    Value := Target.Get(R, IndexKey(R, Index), JsObjectValue(Target));
    if Value = JsException then
      Exit(JsException);
  end;
  if Iterator.IterationKind = IterateValues then
    Exit(CreateIterResult(R, Value, False));
  Pair := R.NewArray(0);
  Pair.CreateDataProperty(R, JsInteger(0), JsNumber(Index));
  Pair.CreateDataProperty(R, JsInteger(1), Value);
  Entry := JsObjectValue(Pair);
  Result := CreateIterResult(R, Entry, False);
end;

function StringIteratorNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Iterator: TJsStringIterator;
  Text: TJsString;
  First, Second: Word;
  Count: Integer;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsStringIterator) then
    Exit(R.ThrowTypeError('next method called on incompatible receiver'));
  Iterator := TJsStringIterator(JsAsObject(This));
  Text := Iterator.Text;
  if (Text = nil) or (Iterator.Position >= Text.Length) then
  begin
    Iterator.Text := nil;
    Exit(CreateIterResult(R, JsUndefined, True));
  end;
  Text.Flatten(R.Heap);
  First := Text.CharAt(Iterator.Position);
  Count := 1;
  if (First >= $D800) and (First <= $DBFF) and (Iterator.Position + 1 < Text.Length) then
  begin
    Second := Text.CharAt(Iterator.Position + 1);
    if (Second >= $DC00) and (Second <= $DFFF) then
      Count := 2;
  end;
  if Count = 1 then
    Result := CreateIterResult(R, JsStringValue(R.Runtime.CharacterString(First)), False)
  else
    Result := CreateIterResult(R, JsStringValue(SubString(R.Heap, Text, Iterator.Position, 2)), False);
  Inc(Iterator.Position, Count);
end;

{ Iterator helpers }

const
  HelperMap = 0;
  HelperFilter = 1;
  HelperTake = 2;
  HelperDrop = 3;
  HelperFlatMap = 4;

function GetIteratorDirect(R: TJsRealm; Value: TJsValue; out Iterator: TJsIteratorRecord): Boolean;
begin
  Iterator.Iterator := Value;
  Iterator.Done := False;
  Iterator.NextMethod := JsUndefined;
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError('Iterator helper called on non-object');
    Exit(False);
  end;
  Iterator.NextMethod := JsAsObject(Value).GetValue(R, R.Atom(anNext));
  Result := Iterator.NextMethod <> JsException;
end;

function HelperNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Helper: TJsIteratorHelper;
  Value, Mapped: TJsValue;
  Pair: array[0..1] of TJsValue;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsIteratorHelper) then
    Exit(R.ThrowTypeError('Iterator helper next called on incompatible receiver'));
  Helper := TJsIteratorHelper(JsAsObject(This));
  while not Helper.Done do
  begin
    if Helper.InnerActive then
    begin
      if IteratorStep(R, Helper.Inner, Value) then
        Exit(CreateIterResult(R, Value, False));
      if R.HasException then
      begin
        IteratorClose(R, Helper.Underlying.Iterator, True);
        Exit(JsException);
      end;
      Helper.InnerActive := False;
    end;
    if (Helper.Operation = HelperTake) and (Helper.Counter >= Helper.Limit) then
    begin
      Helper.Done := True;
      if not IteratorClose(R, Helper.Underlying.Iterator, False) then
        Exit(JsException);
      Break;
    end;
    if not IteratorStep(R, Helper.Underlying, Value) then
    begin
      Helper.Done := True;
      if R.HasException then
        Exit(JsException);
      Break;
    end;
    Pair[0] := Value;
    Pair[1] := JsNumber(Helper.Counter);
    Inc(Helper.Counter);
    case Helper.Operation of
      HelperMap:
        begin
          Mapped := R.Call(Helper.Mapper, JsUndefined, @Pair[0], 2);
          if Mapped = JsException then
          begin
            IteratorClose(R, Helper.Underlying.Iterator, True);
            Exit(JsException);
          end;
          Exit(CreateIterResult(R, Mapped, False));
        end;
      HelperFilter:
        begin
          Mapped := R.Call(Helper.Mapper, JsUndefined, @Pair[0], 2);
          if Mapped = JsException then
          begin
            IteratorClose(R, Helper.Underlying.Iterator, True);
            Exit(JsException);
          end;
          if ToBoolean(Mapped) then
            Exit(CreateIterResult(R, Value, False));
        end;
      HelperTake:
        Exit(CreateIterResult(R, Value, False));
      HelperDrop:
        if Helper.Counter > Helper.Limit then
          Exit(CreateIterResult(R, Value, False));
      HelperFlatMap:
        begin
          Mapped := R.Call(Helper.Mapper, JsUndefined, @Pair[0], 2);
          if Mapped = JsException then
          begin
            IteratorClose(R, Helper.Underlying.Iterator, True);
            Exit(JsException);
          end;
          if not GetIterator(R, Mapped, False, Helper.Inner) then
          begin
            IteratorClose(R, Helper.Underlying.Iterator, True);
            Exit(JsException);
          end;
          Helper.InnerActive := True;
        end;
    end;
  end;
  Result := CreateIterResult(R, JsUndefined, True);
end;

function HelperReturn(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Helper: TJsIteratorHelper;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsIteratorHelper) then
    Exit(R.ThrowTypeError('Iterator helper return called on incompatible receiver'));
  Helper := TJsIteratorHelper(JsAsObject(This));
  if not Helper.Done then
  begin
    Helper.Done := True;
    if Helper.InnerActive then
      IteratorClose(R, Helper.Inner.Iterator, True);
    if not IteratorClose(R, Helper.Underlying.Iterator, False) then
      Exit(JsException);
  end;
  Result := CreateIterResult(R, JsUndefined, True);
end;

function IteratorMakeHelper(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Helper: TJsIteratorHelper;
  Limit: Double;
begin
  Helper := TJsIteratorHelper(R.NewObjectOfClass(TJsIteratorHelper, JsAsObject(Callee.Data), ocIterator));
  Helper.Mapper := JsUndefined;
  Helper.Inner.Iterator := JsUndefined;
  Helper.Inner.NextMethod := JsUndefined;
  Helper.Operation := Callee.Magic;
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('Iterator helper called on non-object'));
  if Callee.Magic in [HelperTake, HelperDrop] then
  begin
    if not ToDouble(R, Arg(Args, ArgCount, 0), Limit) then
      Exit(JsException);
    if IsNaNDouble(Limit) then
      Exit(R.ThrowRangeError(ValueToPascal(R, Arg(Args, ArgCount, 0)) + ' must be positive'));
    if IsFiniteDouble(Limit) then
      Limit := Int(Limit);
    if Limit < 0 then
      Exit(R.ThrowRangeError(ValueToPascal(R, Arg(Args, ArgCount, 0)) + ' must be positive'));
    Helper.Limit := Limit;
  end
  else
  begin
    if not JsIsCallable(Arg(Args, ArgCount, 0)) then
      Exit(R.ThrowTypeError(ValueToPascal(R, Arg(Args, ArgCount, 0)) + ' is not a function'));
    Helper.Mapper := Args^[0];
  end;
  if not GetIteratorDirect(R, This, Helper.Underlying) then
    Exit(JsException);
  Result := JsObjectValue(Helper);
end;

{ reduce, toArray, forEach, some, every, find: Magic 0..5. }
function IteratorConsume(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Iterator: TJsIteratorRecord;
  Value, Outcome, Accumulator: TJsValue;
  Collected: TJsArray;
  Counter: Int64;
  Pair: array[0..2] of TJsValue;
  HasAccumulator: Boolean;
  Mark: Integer;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('Iterator method called on non-object'));
  if (Callee.Magic <> 1) and not JsIsCallable(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError(ValueToPascal(R, Arg(Args, ArgCount, 0)) + ' is not a function'));
  if not GetIteratorDirect(R, This, Iterator) then
    Exit(JsException);
  Collected := nil;
  Accumulator := JsUndefined;
  HasAccumulator := (Callee.Magic = 0) and (ArgCount > 1);
  if HasAccumulator then
    Accumulator := Args^[1];
  if Callee.Magic = 1 then
    Collected := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Collected));
  R.Runtime.PushRoot(Accumulator);
  try
    Counter := 0;
    while IteratorStep(R, Iterator, Value) do
    begin
      case Callee.Magic of
        0:
          begin
            if not HasAccumulator then
            begin
              Accumulator := Value;
              R.Runtime.SetRoot(Mark + 1, Accumulator);
              HasAccumulator := True;
              Inc(Counter);
              Continue;
            end;
            Pair[0] := Accumulator;
            Pair[1] := Value;
            Pair[2] := JsNumber(Counter);
            Accumulator := R.Call(Args^[0], JsUndefined, @Pair[0], 3);
            if Accumulator = JsException then
            begin
              IteratorClose(R, Iterator.Iterator, True);
              Exit(JsException);
            end;
            R.Runtime.SetRoot(Mark + 1, Accumulator);
          end;
        1:
          Collected.CreateDataProperty(R, JsInteger(Collected.ArrayLength), Value);
      else
        Pair[0] := Value;
        Pair[1] := JsNumber(Counter);
        Outcome := R.Call(Args^[0], JsUndefined, @Pair[0], 2);
        if Outcome = JsException then
        begin
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        case Callee.Magic of
          3:
            if ToBoolean(Outcome) then
            begin
              if not IteratorClose(R, Iterator.Iterator, False) then
                Exit(JsException);
              Exit(JsTrue);
            end;
          4:
            if not ToBoolean(Outcome) then
            begin
              if not IteratorClose(R, Iterator.Iterator, False) then
                Exit(JsException);
              Exit(JsFalse);
            end;
          5:
            if ToBoolean(Outcome) then
            begin
              if not IteratorClose(R, Iterator.Iterator, False) then
                Exit(JsException);
              Exit(Value);
            end;
        end;
      end;
      Inc(Counter);
    end;
    if R.HasException then
      Exit(JsException);
    case Callee.Magic of
      0:
        if not HasAccumulator then
          Exit(R.ThrowTypeError('Reduce of empty iterator with no initial value'))
        else
          Result := Accumulator;
      1: Result := JsObjectValue(Collected);
      3: Result := JsFalse;
      4: Result := JsTrue;
    else
      Result := JsUndefined;
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function IteratorFrom(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Method: TJsValue;
  Iterator: TJsIteratorRecord;
  Walk: TJsObject;
begin
  Value := Arg(Args, ArgCount, 0);
  if JsIsString(Value) then
    Exit(CreateStringIterator(R, JsAsString(Value)));
  Method := GetMethod(R, Value, R.Runtime.SymbolValue(wsIterator));
  if Method = JsException then
    Exit(JsException);
  if Method = JsUndefined then
  begin
    if not GetIteratorDirect(R, Value, Iterator) then
      Exit(JsException);
  end
  else if not GetIterator(R, Value, False, Iterator) then
    Exit(JsException);
  { Already inheriting from Iterator.prototype: as it is. }
  Walk := JsAsObject(Iterator.Iterator).Proto;
  while Walk <> nil do
  begin
    if Walk = R.Intrinsics[inIteratorPrototype] then
      Exit(Iterator.Iterator);
    Walk := Walk.Proto;
  end;
  Result := Iterator.Iterator;
end;

function IteratorConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Prototype: TJsObject;
begin
  if (NewTarget = JsUndefined) or (NewTarget = JsObjectValue(Callee)) then
    Exit(R.ThrowTypeError('Abstract class Iterator not directly constructable'));
  Prototype := PrototypeFromConstructor(R, NewTarget, inIteratorPrototype);
  if Prototype = nil then
    Exit(JsException);
  Result := JsObjectValue(R.NewObject(Prototype));
end;

procedure InstallIterators(R: TJsInterpreterRealm);
var
  IteratorPrototype, HelperPrototype: TJsObject;
  Next: TJsNativeFunction;
  Constructor_: TJsNativeFunction;

  procedure Helper(const Name: string; Operation: Integer);
  var
    Function_: TJsNativeFunction;
  begin
    Function_ := NewNativeFunction(R, Name, @IteratorMakeHelper, 1, Operation);
    Function_.Data := JsObjectValue(HelperPrototype);
    IteratorPrototype.DefineData(R, R.Intern(Name), JsObjectValue(Function_), PropertyHidden);
  end;

begin
  IteratorPrototype := R.Intrinsics[inIteratorPrototype];
  DefineSymbolMethod(R, IteratorPrototype, wsIterator, '[Symbol.iterator]', @IteratorPrototypeIterator, 0);
  DefineSymbolMethod(R, R.Intrinsics[inAsyncIteratorPrototype], wsAsyncIterator, '[Symbol.asyncIterator]',
    @IteratorPrototypeIterator, 0);
  Next := NewNativeFunction(R, 'next', @ArrayIteratorNext, 0, ArrayIteratorNextMagic);
  R.Intrinsics[inArrayIteratorPrototype].DefineData(R, R.Atom(anNext), JsObjectValue(Next), PropertyHidden);
  R.Intrinsics[inArrayIteratorPrototype].DefineData(R, R.Runtime.SymbolValue(wsToStringTag),
    R.NewString('Array Iterator'), PropertyConfigurable);
  DefineMethod(R, R.Intrinsics[inStringIteratorPrototype], 'next', @StringIteratorNext, 0);
  R.Intrinsics[inStringIteratorPrototype].DefineData(R, R.Runtime.SymbolValue(wsToStringTag),
    R.NewString('String Iterator'), PropertyConfigurable);
  { Iterator and its helpers. }
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Iterator', @IteratorConstructor, 0, IteratorPrototype);
  DefineMethod(R, Constructor_, 'from', @IteratorFrom, 1);
  HelperPrototype := R.NewObject(IteratorPrototype);
  DefineMethod(R, HelperPrototype, 'next', @HelperNext, 0);
  DefineMethod(R, HelperPrototype, 'return', @HelperReturn, 0);
  HelperPrototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Iterator Helper'),
    PropertyConfigurable);
  Helper('map', HelperMap);
  Helper('filter', HelperFilter);
  Helper('take', HelperTake);
  Helper('drop', HelperDrop);
  Helper('flatMap', HelperFlatMap);
  DefineMethod(R, IteratorPrototype, 'reduce', @IteratorConsume, 1, 0);
  DefineMethod(R, IteratorPrototype, 'toArray', @IteratorConsume, 0, 1);
  DefineMethod(R, IteratorPrototype, 'forEach', @IteratorConsume, 1, 2);
  DefineMethod(R, IteratorPrototype, 'some', @IteratorConsume, 1, 3);
  DefineMethod(R, IteratorPrototype, 'every', @IteratorConsume, 1, 4);
  DefineMethod(R, IteratorPrototype, 'find', @IteratorConsume, 1, 5);
end;

end.
