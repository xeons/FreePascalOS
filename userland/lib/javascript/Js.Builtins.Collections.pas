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
  Map, Set, WeakMap, WeakSet, WeakRef and FinalizationRegistry.

  Map and Set are ordered hash tables: entries in insertion order in a
  linked list, found through hash chains. A deleted entry leaves its
  chain at once but stays in the order list while an iterator stands
  on it (a reference count), so iterators survive deletions and see
  entries added after them, as the specification wants. Keys compare
  by SameValueZero.

  WeakMap and WeakSet are ephemeron tables: a value is kept alive only
  while its key is. The collector's weak processor marks the values of
  marked keys until nothing changes, then drops entries with dead keys.
  WeakRef targets are cleared when collected; a FinalizationRegistry
  queues its cleanup callback for each registered target that died.
}
unit Js.Builtins.Collections;

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
  Js.BigIntegers,
  Js.Conversions,
  Js.Operations,
  Js.Inspect,
  Js.Interpreter;

type
  PJsEntry = ^TJsEntry;
  TJsEntry = record
    Key: TJsValue;
    Value: TJsValue;
    Hash: LongWord;
    NextInChain: PJsEntry;
    Previous: PJsEntry;
    Next: PJsEntry;
    Deleted: Boolean;
    References: Integer;
  end;

  TJsCollection = class(TJsObject)
  private
    FBuckets: array of PJsEntry;
    FMask: Integer;
    procedure Rehash;
    procedure Unlink(Entry: PJsEntry);
  public
    First: PJsEntry;
    Last: PJsEntry;
    Count: Integer;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;
    function Find(R: TJsRealm; Key: TJsValue): PJsEntry;
    procedure Store(R: TJsRealm; Key, Value: TJsValue);
    function Remove(R: TJsRealm; Key: TJsValue): Boolean;
    procedure Clear;
    procedure Release(Entry: PJsEntry);
  end;

  TJsCollectionIterator = class(TJsObject)
  public
    Collection: TJsCollection;
    { The last entry handed out (held by a reference), nil before the
      first. }
    Current: PJsEntry;
    IterationKind: Integer;
    Done: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
    procedure Dying; override;
    class function NeedsDying: Boolean; override;
  end;

procedure InstallCollections(R: TJsInterpreterRealm);

implementation

uses
  Js.Builtins.Iterators;

const
  KindMap = 0;
  KindSet = 1;

function NormalizeKey(Key: TJsValue): TJsValue;
begin
  if JsIsDouble(Key) then
    Result := JsNumber(JsAsDouble(Key))
  else
    Result := Key;
  if Result = JsNegativeZeroBits then
    Result := JsInteger(0);
end;

function HashOf(R: TJsRealm; Key: TJsValue): LongWord;
var
  Bits: QWord;
  Big: TJsBigInt;
  Index: Integer;
begin
  if JsIsString(Key) then
  begin
    JsAsString(Key).Flatten(R.Heap);
    Exit(JsAsString(Key).Hash);
  end;
  if JsIsBigInt(Key) then
  begin
    Big := TJsBigInt(JsAsCell(Key));
    Result := 7;
    for Index := 0 to High(Big.Digits) do
      Result := Result * 31 + Big.Digits[Index];
    if Big.Negative then
      Result := not Result;
    Exit;
  end;
  Bits := Key * QWord($9E3779B97F4A7C15);
  Result := LongWord(Bits shr 32);
end;

{ TJsCollection }

destructor TJsCollection.Destroy;
var
  Entry, Next: PJsEntry;
begin
  Entry := First;
  while Entry <> nil do
  begin
    Next := Entry^.Next;
    Dispose(Entry);
    Entry := Next;
  end;
  inherited Destroy;
end;

procedure TJsCollection.Trace(Tracer: TJsTracer);
var
  Entry: PJsEntry;
begin
  inherited Trace(Tracer);
  Entry := First;
  while Entry <> nil do
  begin
    if not Entry^.Deleted then
    begin
      Tracer.MarkValue(Entry^.Key);
      Tracer.MarkValue(Entry^.Value);
    end;
    Entry := Entry^.Next;
  end;
end;

function TJsCollection.MemorySize: SizeInt;
begin
  Result := inherited MemorySize + Count * SizeOf(TJsEntry) + Length(FBuckets) * SizeOf(Pointer);
end;

procedure TJsCollection.Rehash;
var
  Entry: PJsEntry;
  Size, Slot: Integer;
begin
  Size := 8;
  while Size < Count * 2 do
    Size := Size * 2;
  FBuckets := nil;
  SetLength(FBuckets, Size);
  FMask := Size - 1;
  Entry := First;
  while Entry <> nil do
  begin
    if not Entry^.Deleted then
    begin
      Slot := Integer(Entry^.Hash and LongWord(FMask));
      Entry^.NextInChain := FBuckets[Slot];
      FBuckets[Slot] := Entry;
    end;
    Entry := Entry^.Next;
  end;
end;

function TJsCollection.Find(R: TJsRealm; Key: TJsValue): PJsEntry;
var
  Hash: LongWord;
begin
  if Length(FBuckets) = 0 then
    Exit(nil);
  Key := NormalizeKey(Key);
  Hash := HashOf(R, Key);
  Result := FBuckets[Integer(Hash and LongWord(FMask))];
  while Result <> nil do
  begin
    if (Result^.Hash = Hash) and SameValueZero(Result^.Key, Key, R.Heap) then
      Exit;
    Result := Result^.NextInChain;
  end;
end;

procedure TJsCollection.Store(R: TJsRealm; Key, Value: TJsValue);
var
  Entry: PJsEntry;
  Slot: Integer;
begin
  Entry := Find(R, Key);
  if Entry <> nil then
  begin
    Entry^.Value := Value;
    Exit;
  end;
  New(Entry);
  Entry^.Key := NormalizeKey(Key);
  Entry^.Value := Value;
  Entry^.Hash := HashOf(R, Entry^.Key);
  Entry^.Deleted := False;
  Entry^.References := 0;
  Entry^.Next := nil;
  Entry^.Previous := Last;
  if Last <> nil then
    Last^.Next := Entry
  else
    First := Entry;
  Last := Entry;
  Inc(Count);
  R.Heap.Account(SizeOf(TJsEntry));
  if Count * 2 > Length(FBuckets) then
    Rehash
  else
  begin
    Slot := Integer(Entry^.Hash and LongWord(FMask));
    Entry^.NextInChain := FBuckets[Slot];
    FBuckets[Slot] := Entry;
  end;
end;

procedure TJsCollection.Unlink(Entry: PJsEntry);
begin
  if Entry^.Previous <> nil then
    Entry^.Previous^.Next := Entry^.Next
  else
    First := Entry^.Next;
  if Entry^.Next <> nil then
    Entry^.Next^.Previous := Entry^.Previous
  else
    Last := Entry^.Previous;
  Dispose(Entry);
end;

function TJsCollection.Remove(R: TJsRealm; Key: TJsValue): Boolean;
var
  Entry, Walk: PJsEntry;
  Slot: Integer;
begin
  Entry := Find(R, Key);
  if Entry = nil then
    Exit(False);
  Slot := Integer(Entry^.Hash and LongWord(FMask));
  if FBuckets[Slot] = Entry then
    FBuckets[Slot] := Entry^.NextInChain
  else
  begin
    Walk := FBuckets[Slot];
    while Walk^.NextInChain <> Entry do
      Walk := Walk^.NextInChain;
    Walk^.NextInChain := Entry^.NextInChain;
  end;
  Entry^.Deleted := True;
  Entry^.Key := JsUndefined;
  Entry^.Value := JsUndefined;
  Dec(Count);
  if Entry^.References = 0 then
    Unlink(Entry);
  Result := True;
end;

procedure TJsCollection.Clear;
var
  Entry, Next: PJsEntry;
begin
  Entry := First;
  while Entry <> nil do
  begin
    Next := Entry^.Next;
    if not Entry^.Deleted then
    begin
      Entry^.Deleted := True;
      Entry^.Key := JsUndefined;
      Entry^.Value := JsUndefined;
      if Entry^.References = 0 then
        Unlink(Entry);
    end;
    Entry := Next;
  end;
  Count := 0;
  FBuckets := nil;
  FMask := 0;
end;

procedure TJsCollection.Release(Entry: PJsEntry);
begin
  if Entry = nil then
    Exit;
  Dec(Entry^.References);
  if (Entry^.References = 0) and Entry^.Deleted then
    Unlink(Entry);
end;

{ TJsCollectionIterator }

procedure TJsCollectionIterator.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Collection);
end;

class function TJsCollectionIterator.NeedsDying: Boolean;
begin
  Result := True;
end;

procedure TJsCollectionIterator.Dying;
begin
  if (Collection <> nil) and Collection.Marked and (Current <> nil) then
    Collection.Release(Current);
end;

{ Map and Set }

function ThisCollection(R: TJsRealm; Value: TJsValue; Kind: Integer; out Collection: TJsCollection): Boolean;
var
  Expected: TJsObjectClass;
begin
  Collection := nil;
  if Kind = KindMap then
    Expected := ocMap
  else
    Expected := ocSet;
  if not JsIsObject(Value) or (JsAsObject(Value).ObjectClass <> Expected) then
  begin
    if Kind = KindMap then
      R.ThrowTypeError('Method Map.prototype called on incompatible receiver ' + ValueToPascal(R, Value))
    else
      R.ThrowTypeError('Method Set.prototype called on incompatible receiver ' + ValueToPascal(R, Value));
    Exit(False);
  end;
  Collection := TJsCollection(JsAsObject(Value));
  Result := True;
end;

function CollectionConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsCollection;
  Prototype: TJsObject;
  Iterable, Adder, Value, Key, Entry: TJsValue;
  Iterator: TJsIteratorRecord;
  Pair: array[0..1] of TJsValue;
  Mark: Integer;
  Fast: Boolean;
begin
  if NewTarget = JsUndefined then
  begin
    if Callee.Magic = KindMap then
      Exit(R.ThrowTypeError('Constructor Map requires ''new'''));
    Exit(R.ThrowTypeError('Constructor Set requires ''new'''));
  end;
  if Callee.Magic = KindMap then
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inMapPrototype);
    if Prototype = nil then
      Exit(JsException);
    Collection := TJsCollection(R.NewObjectOfClass(TJsCollection, Prototype, ocMap));
  end
  else
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inSetPrototype);
    if Prototype = nil then
      Exit(JsException);
    Collection := TJsCollection(R.NewObjectOfClass(TJsCollection, Prototype, ocSet));
  end;
  Result := JsObjectValue(Collection);
  Iterable := Arg(Args, ArgCount, 0);
  if JsIsNullish(Iterable) then
    Exit;
  if Callee.Magic = KindMap then
    Adder := Collection.GetValue(R, R.Atom(anSet))
  else
    Adder := Collection.GetValue(R, R.Atom(anAdd));
  if Adder = JsException then
    Exit(JsException);
  if not JsIsCallable(Adder) then
    Exit(R.ThrowTypeError('''' + ValueToPascal(R, Adder) + ''' returned for property ''add'' is not a function'));
  { The original adder can be skipped over. }
  Fast := JsIsObject(Adder) and (JsAsObject(Adder) is TJsNativeFunction) and
    (TJsNativeFunction(JsAsObject(Adder)).Data = JsTrue);
  if not GetIterator(R, Iterable, False, Iterator) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Result);
  R.Runtime.PushRoot(Iterator.Iterator);
  R.Runtime.PushRoot(Iterator.NextMethod);
  try
    while IteratorStep(R, Iterator, Value) do
    begin
      if Callee.Magic = KindMap then
      begin
        if not JsIsObject(Value) then
        begin
          R.ThrowTypeError('Iterator value ' + ValueToPascal(R, Value) + ' is not an entry object');
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        Entry := Value;
        Key := GetPropertyByKey(R, Entry, JsInteger(0));
        if Key = JsException then
        begin
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        Value := GetPropertyByKey(R, Entry, JsInteger(1));
        if Value = JsException then
        begin
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        if Fast then
          Collection.Store(R, Key, Value)
        else
        begin
          Pair[0] := Key;
          Pair[1] := Value;
          if R.Call(Adder, Result, @Pair[0], 2) = JsException then
          begin
            IteratorClose(R, Iterator.Iterator, True);
            Exit(JsException);
          end;
        end;
      end
      else if Fast then
        Collection.Store(R, Value, JsUndefined)
      else if R.Call(Adder, Result, @Value, 1) = JsException then
      begin
        IteratorClose(R, Iterator.Iterator, True);
        Exit(JsException);
      end;
    end;
    if R.HasException then
      Exit(JsException);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ get (0), set (1), has (2), delete (3), clear (4), add (5) }
function CollectionOperation(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsCollection;
  Entry: PJsEntry;
  Kind: Integer;
begin
  Kind := Callee.Magic div 16;
  if not ThisCollection(R, This, Kind, Collection) then
    Exit(JsException);
  case Callee.Magic mod 16 of
    0:
      begin
        Entry := Collection.Find(R, Arg(Args, ArgCount, 0));
        if Entry = nil then
          Exit(JsUndefined);
        Result := Entry^.Value;
      end;
    1:
      begin
        Collection.Store(R, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1));
        Result := This;
      end;
    2: Result := JsBoolean(Collection.Find(R, Arg(Args, ArgCount, 0)) <> nil);
    3: Result := JsBoolean(Collection.Remove(R, Arg(Args, ArgCount, 0)));
    4:
      begin
        Collection.Clear;
        Result := JsUndefined;
      end;
  else
    Collection.Store(R, Arg(Args, ArgCount, 0), JsUndefined);
    Result := This;
  end;
end;

function CollectionSize(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsCollection;
begin
  if not ThisCollection(R, This, Callee.Magic, Collection) then
    Exit(JsException);
  Result := JsInteger(Collection.Count);
end;

function CollectionForEach(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsCollection;
  Entry, Next: PJsEntry;
  Triple: array[0..2] of TJsValue;
  Outcome: TJsValue;
begin
  if not ThisCollection(R, This, Callee.Magic, Collection) then
    Exit(JsException);
  if not JsIsCallable(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError(ValueToPascal(R, Arg(Args, ArgCount, 0)) + ' is not a function'));
  Entry := Collection.First;
  if Entry <> nil then
    Inc(Entry^.References);
  while Entry <> nil do
  begin
    if not Entry^.Deleted then
    begin
      if Callee.Magic = KindMap then
      begin
        Triple[0] := Entry^.Value;
        Triple[1] := Entry^.Key;
      end
      else
      begin
        Triple[0] := Entry^.Key;
        Triple[1] := Entry^.Key;
      end;
      Triple[2] := This;
      Outcome := R.Call(Args^[0], Arg(Args, ArgCount, 1), @Triple[0], 3);
      if Outcome = JsException then
      begin
        Collection.Release(Entry);
        Exit(JsException);
      end;
    end;
    Next := Entry^.Next;
    if Next <> nil then
      Inc(Next^.References);
    Collection.Release(Entry);
    Entry := Next;
  end;
  Result := JsUndefined;
end;

function NewCollectionIterator(R: TJsRealm; Collection: TJsCollection; Kind: Integer; Prototype: TJsObject): TJsValue;
var
  Iterator: TJsCollectionIterator;
begin
  Iterator := TJsCollectionIterator(R.NewObjectOfClass(TJsCollectionIterator, Prototype, ocIterator));
  Iterator.Collection := Collection;
  Iterator.IterationKind := Kind;
  Result := JsObjectValue(Iterator);
end;

{ keys, values, entries: Magic = collection kind * 16 + iteration kind }
function CollectionIteratorMethod(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsCollection;
begin
  if not ThisCollection(R, This, Callee.Magic div 16, Collection) then
    Exit(JsException);
  if Callee.Magic div 16 = KindMap then
    Result := NewCollectionIterator(R, Collection, Callee.Magic mod 16, R.Intrinsics[inMapIteratorPrototype])
  else
    Result := NewCollectionIterator(R, Collection, Callee.Magic mod 16, R.Intrinsics[inSetIteratorPrototype]);
end;

function CollectionIteratorNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Iterator: TJsCollectionIterator;
  Entry: PJsEntry;
  Pair: TJsArray;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsCollectionIterator) then
    Exit(R.ThrowTypeError('next method called on incompatible receiver'));
  Iterator := TJsCollectionIterator(JsAsObject(This));
  if Iterator.Done then
    Exit(CreateIterResult(R, JsUndefined, True));
  if Iterator.Current = nil then
    Entry := Iterator.Collection.First
  else
    Entry := Iterator.Current^.Next;
  while (Entry <> nil) and Entry^.Deleted do
    Entry := Entry^.Next;
  if Iterator.Current <> nil then
    Iterator.Collection.Release(Iterator.Current);
  Iterator.Current := Entry;
  if Entry = nil then
  begin
    Iterator.Done := True;
    Exit(CreateIterResult(R, JsUndefined, True));
  end;
  Inc(Entry^.References);
  case Iterator.IterationKind of
    IterateKeys: Result := CreateIterResult(R, Entry^.Key, False);
    IterateValues:
      if Iterator.Collection.ObjectClass = ocSet then
        Result := CreateIterResult(R, Entry^.Key, False)
      else
        Result := CreateIterResult(R, Entry^.Value, False);
  else
    Pair := R.NewArray(0);
    Pair.CreateDataProperty(R, JsInteger(0), Entry^.Key);
    if Iterator.Collection.ObjectClass = ocSet then
      Pair.CreateDataProperty(R, JsInteger(1), Entry^.Key)
    else
      Pair.CreateDataProperty(R, JsInteger(1), Entry^.Value);
    Result := CreateIterResult(R, JsObjectValue(Pair), False);
  end;
end;

function MapGroupBy(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Items: TJsValueList;
  Created: TJsCollection;
  Index, Mark: Integer;
  Pair: array[0..1] of TJsValue;
  Key: TJsValue;
  Entry: PJsEntry;
  Bucket: TJsArray;
begin
  if not JsIsCallable(Arg(Args, ArgCount, 1)) then
    Exit(R.ThrowTypeError('callback is not a function'));
  if not IterableToList(R, Arg(Args, ArgCount, 0), Items) then
    Exit(JsException);
  Created := TJsCollection(R.NewObjectOfClass(TJsCollection, R.Intrinsics[inMapPrototype], ocMap));
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  try
    for Index := 0 to High(Items) do
    begin
      Pair[0] := Items[Index];
      Pair[1] := JsInteger(Index);
      Key := R.Call(Args^[1], JsUndefined, @Pair[0], 2);
      if Key = JsException then
        Exit(JsException);
      Entry := Created.Find(R, Key);
      if Entry = nil then
      begin
        Bucket := R.NewArray(0);
        Created.Store(R, Key, JsObjectValue(Bucket));
      end
      else
        Bucket := TJsArray(JsAsObject(Entry^.Value));
      Bucket.CreateDataProperty(R, JsInteger(Bucket.ArrayLength), Items[Index]);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Created);
end;

function CollectionSpecies(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

function InspectEntries(R: TJsRealm; Target: TJsObject; out Values: TJsValueList): Boolean;
var
  Entry: PJsEntry;
  Count: Integer;
begin
  Values := nil;
  Count := 0;
  Entry := TJsCollection(Target).First;
  while Entry <> nil do
  begin
    if not Entry^.Deleted then
    begin
      SetLength(Values, Count + 2);
      Values[Count] := Entry^.Key;
      Inc(Count);
      if Target.ObjectClass = ocMap then
      begin
        Values[Count] := Entry^.Value;
        Inc(Count);
      end;
    end;
    Entry := Entry^.Next;
  end;
  SetLength(Values, Count);
  Result := True;
end;

{ Set methods (union, intersection...) }

{ The "set-like" argument: its size, has and keys. }
type
  TJsSetRecord = record
    Target: TJsValue;
    Size: Double;
    Has: TJsValue;
    Keys: TJsValue;
  end;

function GetSetRecord(R: TJsRealm; Value: TJsValue; out Record_: TJsSetRecord): Boolean;
var
  Size: TJsValue;
begin
  Result := False;
  Record_.Target := Value;
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError(ValueToPascal(R, Value) + ' is not an object');
    Exit;
  end;
  Size := JsAsObject(Value).GetValue(R, R.Atom(anSize));
  if Size = JsException then
    Exit;
  if not ToDouble(R, Size, Record_.Size) then
    Exit;
  if IsNaNDouble(Record_.Size) then
  begin
    R.ThrowTypeError('The size property is NaN');
    Exit;
  end;
  Record_.Has := JsAsObject(Value).GetValue(R, R.Atom(anHas));
  if Record_.Has = JsException then
    Exit;
  if not JsIsCallable(Record_.Has) then
  begin
    R.ThrowTypeError('The has property is not callable');
    Exit;
  end;
  Record_.Keys := JsAsObject(Value).GetValue(R, R.Intern('keys'));
  if Record_.Keys = JsException then
    Exit;
  if not JsIsCallable(Record_.Keys) then
  begin
    R.ThrowTypeError('The keys property is not callable');
    Exit;
  end;
  Result := True;
end;

{ union 0, intersection 1, difference 2, symmetricDifference 3,
  isSubsetOf 4, isSupersetOf 5, isDisjointFrom 6 }
function SetAlgebra(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection, Created: TJsCollection;
  Other: TJsSetRecord;
  Iterator: TJsIteratorRecord;
  Keys, Value, Found: TJsValue;
  Entry: PJsEntry;
  Mark: Integer;
  Inside: Boolean;
begin
  if not ThisCollection(R, This, KindSet, Collection) then
    Exit(JsException);
  if not GetSetRecord(R, Arg(Args, ArgCount, 0), Other) then
    Exit(JsException);
  Created := nil;
  if Callee.Magic <= 3 then
  begin
    Created := TJsCollection(R.NewObjectOfClass(TJsCollection, R.Intrinsics[inSetPrototype], ocSet));
    if Callee.Magic in [0, 2, 3] then
    begin
      Entry := Collection.First;
      while Entry <> nil do
      begin
        if not Entry^.Deleted then
          Created.Store(R, Entry^.Key, JsUndefined);
        Entry := Entry^.Next;
      end;
    end;
  end;
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  R.Runtime.PushRoot(Other.Target);
  try
    case Callee.Magic of
      1, 4, 6:
        begin
          { Walk this set, asking the other. }
          Entry := Collection.First;
          while Entry <> nil do
          begin
            if not Entry^.Deleted then
            begin
              Value := Entry^.Key;
              Found := R.Call(Other.Has, Other.Target, @Value, 1);
              if Found = JsException then
                Exit(JsException);
              Inside := ToBoolean(Found);
              case Callee.Magic of
                1:
                  if Inside then
                    Created.Store(R, Value, JsUndefined);
                4:
                  if not Inside then
                    Exit(JsFalse);
                6:
                  if Inside then
                    Exit(JsFalse);
              end;
            end;
            Entry := Entry^.Next;
          end;
          if Callee.Magic = 1 then
            Exit(JsObjectValue(Created));
          Exit(JsTrue);
        end;
    end;
    { Walk the other's keys. }
    Keys := R.Call(Other.Keys, Other.Target, nil, 0);
    if Keys = JsException then
      Exit(JsException);
    if not JsIsObject(Keys) then
      Exit(R.ThrowTypeError('keys() did not return an object'));
    Iterator.Iterator := Keys;
    Iterator.Done := False;
    Iterator.NextMethod := JsAsObject(Keys).GetValue(R, R.Atom(anNext));
    if Iterator.NextMethod = JsException then
      Exit(JsException);
    R.Runtime.PushRoot(Keys);
    while IteratorStep(R, Iterator, Value) do
      case Callee.Magic of
        0: Created.Store(R, Value, JsUndefined);
        2: Created.Remove(R, Value);
        3:
          if Collection.Find(R, Value) <> nil then
            Created.Remove(R, Value)
          else
            Created.Store(R, Value, JsUndefined);
        5:
          if Collection.Find(R, Value) = nil then
          begin
            IteratorClose(R, Keys, False);
            Exit(JsFalse);
          end;
      end;
    if R.HasException then
      Exit(JsException);
    if Callee.Magic = 5 then
      Exit(JsTrue);
    Result := JsObjectValue(Created);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ Weak collections }

type
  TJsWeakEntry = record
    Key: TJsCell;
    Value: TJsValue;
  end;

  { An open addressing table keyed by cell identity; a removed entry
    is a tombstone. }
  TJsWeakCollection = class(TJsObject)
  private
    procedure Grow;
  public
    Entries: array of TJsWeakEntry;
    Count: Integer;
    Used: Integer;
    function IndexOf(Key: TJsCell): Integer;
    procedure Store(Key: TJsCell; Value: TJsValue);
    function Remove(Key: TJsCell): Boolean;
    procedure RemoveAt(Index: Integer);
    function MemorySize: SizeInt; override;
  end;

  TJsWeakReference = class(TJsObject)
  public
    Target: TJsCell;
  end;

  TJsFinalizationEntry = record
    Target: TJsCell;
    Held: TJsValue;
    Token: TJsCell;
  end;

  TJsFinalizationRegistry = class(TJsObject)
  public
    Cleanup: TJsValue;
    Entries: array of TJsFinalizationEntry;
    Count: Integer;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  { The realm's weak things, processed at each collection. }
  TJsWeakRegistry = class
  public
    Realm: TJsRealm;
    Collections: array of TJsWeakCollection;
    References: array of TJsWeakReference;
    Registries: array of TJsFinalizationRegistry;
    function Process(Tracer: TJsTracer; Phase: Integer): Boolean;
  end;

function WeakRegistry(R: TJsRealm): TJsWeakRegistry; inline;
begin
  Result := TJsWeakRegistry(TJsInterpreterRealm(R).WeakState);
end;

{ The key of a removed entry. }
function Tombstone: TJsCell; inline;
begin
  Result := TJsCell(Pointer(1));
end;

function SlotOf(Key: TJsCell; Mask: Integer): Integer; inline;
begin
  Result := Integer(LongWord((QWord(PtrUInt(Key)) * QWord($9E3779B97F4A7C15)) shr 32) and LongWord(Mask));
end;

function TJsWeakCollection.MemorySize: SizeInt;
begin
  Result := inherited MemorySize + Length(Entries) * SizeOf(TJsWeakEntry);
end;

function TJsWeakCollection.IndexOf(Key: TJsCell): Integer;
var
  Mask, Slot: Integer;
begin
  if Length(Entries) = 0 then
    Exit(-1);
  Mask := Length(Entries) - 1;
  Slot := SlotOf(Key, Mask);
  while Entries[Slot].Key <> nil do
  begin
    if Entries[Slot].Key = Key then
      Exit(Slot);
    Slot := (Slot + 1) and Mask;
  end;
  Result := -1;
end;

procedure TJsWeakCollection.Grow;
var
  Old: array of TJsWeakEntry;
  Index, Size: Integer;
begin
  Old := Entries;
  Size := 16;
  while Size < Count * 4 do
    Size := Size * 2;
  Entries := nil;
  SetLength(Entries, Size);
  Used := 0;
  Count := 0;
  for Index := 0 to High(Old) do
    if (Old[Index].Key <> nil) and (Old[Index].Key <> Tombstone) then
      Store(Old[Index].Key, Old[Index].Value);
end;

procedure TJsWeakCollection.Store(Key: TJsCell; Value: TJsValue);
var
  Index, Mask, Slot: Integer;
begin
  Index := IndexOf(Key);
  if Index >= 0 then
  begin
    Entries[Index].Value := Value;
    Exit;
  end;
  if (Used + 1) * 2 > Length(Entries) then
    Grow;
  Mask := Length(Entries) - 1;
  Slot := SlotOf(Key, Mask);
  while (Entries[Slot].Key <> nil) and (Entries[Slot].Key <> Tombstone) do
    Slot := (Slot + 1) and Mask;
  if Entries[Slot].Key = nil then
    Inc(Used);
  Entries[Slot].Key := Key;
  Entries[Slot].Value := Value;
  Inc(Count);
end;

procedure TJsWeakCollection.RemoveAt(Index: Integer);
begin
  Entries[Index].Key := Tombstone;
  Entries[Index].Value := JsUndefined;
  Dec(Count);
end;

function TJsWeakCollection.Remove(Key: TJsCell): Boolean;
var
  Index: Integer;
begin
  Index := IndexOf(Key);
  if Index < 0 then
    Exit(False);
  RemoveAt(Index);
  Result := True;
end;

procedure TJsFinalizationRegistry.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Cleanup);
  for Index := 0 to Count - 1 do
    Tracer.MarkValue(Entries[Index].Held);
end;

procedure CleanupJob(R: TJsRealm; const Values: array of TJsValue);
var
  Held: TJsValue;
begin
  Held := Values[1];
  R.Call(Values[0], JsUndefined, @Held, 1);
  if R.HasException then
    R.Runtime.TakeException;
end;

function TJsWeakRegistry.Process(Tracer: TJsTracer; Phase: Integer): Boolean;
var
  Index, Entry, Count: Integer;
  Collection: TJsWeakCollection;
  Registry: TJsFinalizationRegistry;
begin
  Result := False;
  if Phase = 0 then
  begin
    for Index := 0 to High(Collections) do
    begin
      Collection := Collections[Index];
      if not Collection.Marked then
        Continue;
      for Entry := 0 to High(Collection.Entries) do
        if (Collection.Entries[Entry].Key <> nil) and (Collection.Entries[Entry].Key <> Tombstone) and
          Collection.Entries[Entry].Key.Marked and JsIsCell(Collection.Entries[Entry].Value) and
          not JsAsCell(Collection.Entries[Entry].Value).Marked then
        begin
          Tracer.MarkValue(Collection.Entries[Entry].Value);
          Result := True;
        end;
    end;
    Exit;
  end;
  { Forget the dead. }
  Count := 0;
  for Index := 0 to High(Collections) do
  begin
    Collection := Collections[Index];
    if not Collection.Marked then
      Continue;
    for Entry := 0 to High(Collection.Entries) do
      if (Collection.Entries[Entry].Key <> nil) and (Collection.Entries[Entry].Key <> Tombstone) and
        not Collection.Entries[Entry].Key.Marked then
        Collection.RemoveAt(Entry);
    Collections[Count] := Collection;
    Inc(Count);
  end;
  SetLength(Collections, Count);
  Count := 0;
  for Index := 0 to High(References) do
  begin
    if not References[Index].Marked then
      Continue;
    if (References[Index].Target <> nil) and not References[Index].Target.Marked then
      References[Index].Target := nil;
    References[Count] := References[Index];
    Inc(Count);
  end;
  SetLength(References, Count);
  Count := 0;
  for Index := 0 to High(Registries) do
  begin
    Registry := Registries[Index];
    if not Registry.Marked then
      Continue;
    Entry := 0;
    while Entry < Registry.Count do
    begin
      if not Registry.Entries[Entry].Target.Marked then
      begin
        Realm.EnqueueJob(@CleanupJob, Registry.Cleanup, Registry.Entries[Entry].Held, JsUndefined, JsUndefined);
        Registry.Entries[Entry] := Registry.Entries[Registry.Count - 1];
        Dec(Registry.Count);
        Continue;
      end;
      if (Registry.Entries[Entry].Token <> nil) and not Registry.Entries[Entry].Token.Marked then
        Registry.Entries[Entry].Token := nil;
      Inc(Entry);
    end;
    Registries[Count] := Registry;
    Inc(Count);
  end;
  SetLength(Registries, Count);
end;

{ An object, or a symbol not made by Symbol.for. }
function CanBeHeldWeakly(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) or (JsIsSymbol(Value) and not JsAsSymbol(Value).IsRegistered);
end;

function WeakConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsWeakCollection;
  Prototype: TJsObject;
  Iterator: TJsIteratorRecord;
  Item, Key, Value: TJsValue;
  Adder: TJsValue;
  Pair: array[0..1] of TJsValue;
  Mark: Integer;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor requires ''new'''));
  Value := JsUndefined;
  if Callee.Magic = KindMap then
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inWeakMapPrototype);
    if Prototype = nil then
      Exit(JsException);
    Collection := TJsWeakCollection(R.NewObjectOfClass(TJsWeakCollection, Prototype, ocWeakMap));
  end
  else
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inWeakSetPrototype);
    if Prototype = nil then
      Exit(JsException);
    Collection := TJsWeakCollection(R.NewObjectOfClass(TJsWeakCollection, Prototype, ocWeakSet));
  end;
  SetLength(WeakRegistry(R).Collections, Length(WeakRegistry(R).Collections) + 1);
  WeakRegistry(R).Collections[High(WeakRegistry(R).Collections)] := Collection;
  Result := JsObjectValue(Collection);
  if JsIsNullish(Arg(Args, ArgCount, 0)) then
    Exit;
  if Callee.Magic = KindMap then
    Adder := Collection.GetValue(R, R.Atom(anSet))
  else
    Adder := Collection.GetValue(R, R.Atom(anAdd));
  if Adder = JsException then
    Exit(JsException);
  if not JsIsCallable(Adder) then
    Exit(R.ThrowTypeError('''' + ValueToPascal(R, Adder) + ''' returned for the adder is not a function'));
  { Entries are taken one at a time (the iterable may never end), the
    iterator closed when one fails. }
  if not GetIterator(R, Args^[0], False, Iterator) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Result);
  R.Runtime.PushRoot(Iterator.Iterator);
  R.Runtime.PushRoot(Iterator.NextMethod);
  try
    while IteratorStep(R, Iterator, Item) do
    begin
      if Callee.Magic = KindMap then
      begin
        if not JsIsObject(Item) then
        begin
          R.ThrowTypeError('Iterator value ' + ValueToPascal(R, Item) + ' is not an entry object');
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        Key := GetProperty(R, Item, JsInteger(0));
        if Key <> JsException then
          Value := GetProperty(R, Item, JsInteger(1));
        if (Key = JsException) or (Value = JsException) then
        begin
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
        Pair[0] := Key;
        Pair[1] := Value;
        if R.Call(Adder, Result, @Pair[0], 2) = JsException then
        begin
          IteratorClose(R, Iterator.Iterator, True);
          Exit(JsException);
        end;
      end
      else if R.Call(Adder, Result, @Item, 1) = JsException then
      begin
        IteratorClose(R, Iterator.Iterator, True);
        Exit(JsException);
      end;
    end;
    if R.HasException then
      Exit(JsException);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ get (0), set (1), has (2), delete (3), add (5); Magic div 16: kind }
function WeakOperation(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Collection: TJsWeakCollection;
  Key: TJsValue;
  Index: Integer;
  Expected: TJsObjectClass;
begin
  if Callee.Magic div 16 = KindMap then
    Expected := ocWeakMap
  else
    Expected := ocWeakSet;
  if not JsIsObject(This) or (JsAsObject(This).ObjectClass <> Expected) then
    Exit(R.ThrowTypeError('Method called on incompatible receiver ' + ValueToPascal(R, This)));
  Collection := TJsWeakCollection(JsAsObject(This));
  Key := Arg(Args, ArgCount, 0);
  if not CanBeHeldWeakly(Key) then
  begin
    case Callee.Magic mod 16 of
      1, 5: Exit(R.ThrowTypeError('Invalid value used as weak map key'));
      0: Exit(JsUndefined);
    else
      Exit(JsFalse);
    end;
  end;
  case Callee.Magic mod 16 of
    0:
      begin
        Index := Collection.IndexOf(JsAsCell(Key));
        if Index < 0 then
          Exit(JsUndefined);
        Result := Collection.Entries[Index].Value;
      end;
    1:
      begin
        Collection.Store(JsAsCell(Key), Arg(Args, ArgCount, 1));
        Result := This;
      end;
    2: Result := JsBoolean(Collection.IndexOf(JsAsCell(Key)) >= 0);
    3: Result := JsBoolean(Collection.Remove(JsAsCell(Key)));
  else
    Collection.Store(JsAsCell(Key), JsTrue);
    Result := This;
  end;
end;

function WeakRefConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Reference: TJsWeakReference;
  Prototype: TJsObject;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor WeakRef requires ''new'''));
  if not CanBeHeldWeakly(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('WeakRef: target must be an object'));
  Prototype := PrototypeFromConstructor(R, NewTarget, inWeakRefPrototype);
  if Prototype = nil then
    Exit(JsException);
  Reference := TJsWeakReference(R.NewObjectOfClass(TJsWeakReference, Prototype, ocWeakRef));
  Reference.Target := JsAsCell(Args^[0]);
  SetLength(WeakRegistry(R).References, Length(WeakRegistry(R).References) + 1);
  WeakRegistry(R).References[High(WeakRegistry(R).References)] := Reference;
  Result := JsObjectValue(Reference);
end;

function WeakRefDeref(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Reference: TJsWeakReference;
begin
  if not JsIsObject(This) or (JsAsObject(This).ObjectClass <> ocWeakRef) then
    Exit(R.ThrowTypeError('WeakRef.prototype.deref called on incompatible receiver'));
  Reference := TJsWeakReference(JsAsObject(This));
  if Reference.Target = nil then
    Exit(JsUndefined);
  if Reference.Target is TJsSymbol then
    Result := JsSymbolValue(TJsSymbol(Reference.Target))
  else
    Result := JsCellValue(JsObjectBase, Reference.Target);
end;

function RegistryConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Registry: TJsFinalizationRegistry;
  Prototype: TJsObject;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor FinalizationRegistry requires ''new'''));
  if not JsIsCallable(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('FinalizationRegistry: cleanup must be callable'));
  Prototype := PrototypeFromConstructor(R, NewTarget, inFinalizationRegistryPrototype);
  if Prototype = nil then
    Exit(JsException);
  Registry := TJsFinalizationRegistry(R.NewObjectOfClass(TJsFinalizationRegistry, Prototype, ocFinalizationRegistry));
  Registry.Cleanup := Args^[0];
  SetLength(WeakRegistry(R).Registries, Length(WeakRegistry(R).Registries) + 1);
  WeakRegistry(R).Registries[High(WeakRegistry(R).Registries)] := Registry;
  Result := JsObjectValue(Registry);
end;

{ register (0), unregister (1) }
function RegistryOperation(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Registry: TJsFinalizationRegistry;
  Target, Token: TJsValue;
  Index: Integer;
  Removed: Boolean;
begin
  if not JsIsObject(This) or (JsAsObject(This).ObjectClass <> ocFinalizationRegistry) then
    Exit(R.ThrowTypeError('FinalizationRegistry method called on incompatible receiver'));
  Registry := TJsFinalizationRegistry(JsAsObject(This));
  if Callee.Magic = 0 then
  begin
    Target := Arg(Args, ArgCount, 0);
    Token := Arg(Args, ArgCount, 2);
    if not CanBeHeldWeakly(Target) then
      Exit(R.ThrowTypeError('FinalizationRegistry.prototype.register: invalid target'));
    if SameValue(Target, Arg(Args, ArgCount, 1), R.Heap) then
      Exit(R.ThrowTypeError('FinalizationRegistry.prototype.register: target and holdings must not be same'));
    if (Token <> JsUndefined) and not CanBeHeldWeakly(Token) then
      Exit(R.ThrowTypeError('FinalizationRegistry.prototype.register: invalid unregister token'));
    if Registry.Count >= Length(Registry.Entries) then
      SetLength(Registry.Entries, Length(Registry.Entries) * 2 + 4);
    Registry.Entries[Registry.Count].Target := JsAsCell(Target);
    Registry.Entries[Registry.Count].Held := Arg(Args, ArgCount, 1);
    if Token <> JsUndefined then
      Registry.Entries[Registry.Count].Token := JsAsCell(Token)
    else
      Registry.Entries[Registry.Count].Token := nil;
    Inc(Registry.Count);
    Exit(JsUndefined);
  end;
  Token := Arg(Args, ArgCount, 0);
  if not CanBeHeldWeakly(Token) then
    Exit(R.ThrowTypeError('Invalid unregisterToken'));
  Removed := False;
  Index := 0;
  while Index < Registry.Count do
    if Registry.Entries[Index].Token = JsAsCell(Token) then
    begin
      Registry.Entries[Index] := Registry.Entries[Registry.Count - 1];
      Dec(Registry.Count);
      Removed := True;
    end
    else
      Inc(Index);
  Result := JsBoolean(Removed);
end;

procedure InstallCollections(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
  Species: TJsNativeFunction;
  Function_: TJsValue;
  Registry: TJsWeakRegistry;

  procedure Operation(const Name: string; Magic, Length: Integer; Original: Boolean = False);
  begin
    DefineMethod(R, Prototype, Name, @CollectionOperation, Length, Magic);
    if Original then
      TJsNativeFunction(JsAsObject(Prototype.GetValue(R, R.Intern(Name)))).Data := JsTrue;
  end;

begin
  Registry := TJsWeakRegistry.Create;
  Registry.Realm := R;
  R.WeakState := Registry;
  R.Heap.AddWeakProcessor(@Registry.Process);
  JsCollectionEntries := @InspectEntries;
  Species := NewNativeFunction(R, 'get [Symbol.species]', @CollectionSpecies, 0);

  Prototype := R.Intrinsics[inMapPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Map', @CollectionConstructor, 0, Prototype);
  Constructor_.Magic := KindMap;
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies), JsObjectValue(Species), JsUndefined,
    PropertyConfigurable);
  DefineMethod(R, Constructor_, 'groupBy', @MapGroupBy, 2);
  Operation('get', 0, 1);
  Operation('set', 1, 2, True);
  Operation('has', 2, 1);
  Operation('delete', 3, 1);
  Operation('clear', 4, 0);
  DefineGetter(R, Prototype, 'size', @CollectionSize, KindMap);
  DefineMethod(R, Prototype, 'forEach', @CollectionForEach, 1, KindMap);
  DefineMethod(R, Prototype, 'keys', @CollectionIteratorMethod, 0, KindMap * 16 + IterateKeys);
  DefineMethod(R, Prototype, 'values', @CollectionIteratorMethod, 0, KindMap * 16 + IterateValues);
  DefineMethod(R, Prototype, 'entries', @CollectionIteratorMethod, 0, KindMap * 16 + IterateEntries);
  Function_ := Prototype.GetValue(R, R.Intern('entries'));
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsIterator), Function_, PropertyHidden);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Map'), PropertyConfigurable);
  DefineMethod(R, R.Intrinsics[inMapIteratorPrototype], 'next', @CollectionIteratorNext, 0);
  R.Intrinsics[inMapIteratorPrototype].DefineData(R, R.Runtime.SymbolValue(wsToStringTag),
    R.NewString('Map Iterator'), PropertyConfigurable);

  Prototype := R.Intrinsics[inSetPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Set', @CollectionConstructor, 0, Prototype);
  Constructor_.Magic := KindSet;
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies), JsObjectValue(Species), JsUndefined,
    PropertyConfigurable);
  Operation('has', KindSet * 16 + 2, 1);
  Operation('add', KindSet * 16 + 5, 1, True);
  Operation('delete', KindSet * 16 + 3, 1);
  Operation('clear', KindSet * 16 + 4, 0);
  DefineGetter(R, Prototype, 'size', @CollectionSize, KindSet);
  DefineMethod(R, Prototype, 'forEach', @CollectionForEach, 1, KindSet);
  DefineMethod(R, Prototype, 'entries', @CollectionIteratorMethod, 0, KindSet * 16 + IterateEntries);
  DefineMethod(R, Prototype, 'values', @CollectionIteratorMethod, 0, KindSet * 16 + IterateValues);
  Function_ := Prototype.GetValue(R, R.Intern('values'));
  Prototype.DefineData(R, R.Intern('keys'), Function_, PropertyHidden);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsIterator), Function_, PropertyHidden);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Set'), PropertyConfigurable);
  DefineMethod(R, Prototype, 'union', @SetAlgebra, 1, 0);
  DefineMethod(R, Prototype, 'intersection', @SetAlgebra, 1, 1);
  DefineMethod(R, Prototype, 'difference', @SetAlgebra, 1, 2);
  DefineMethod(R, Prototype, 'symmetricDifference', @SetAlgebra, 1, 3);
  DefineMethod(R, Prototype, 'isSubsetOf', @SetAlgebra, 1, 4);
  DefineMethod(R, Prototype, 'isSupersetOf', @SetAlgebra, 1, 5);
  DefineMethod(R, Prototype, 'isDisjointFrom', @SetAlgebra, 1, 6);
  DefineMethod(R, R.Intrinsics[inSetIteratorPrototype], 'next', @CollectionIteratorNext, 0);
  R.Intrinsics[inSetIteratorPrototype].DefineData(R, R.Runtime.SymbolValue(wsToStringTag),
    R.NewString('Set Iterator'), PropertyConfigurable);

  Prototype := R.Intrinsics[inWeakMapPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'WeakMap', @WeakConstructor, 0, Prototype);
  Constructor_.Magic := KindMap;
  DefineMethod(R, Prototype, 'get', @WeakOperation, 1, 0);
  DefineMethod(R, Prototype, 'set', @WeakOperation, 2, 1);
  DefineMethod(R, Prototype, 'has', @WeakOperation, 1, 2);
  DefineMethod(R, Prototype, 'delete', @WeakOperation, 1, 3);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('WeakMap'), PropertyConfigurable);

  Prototype := R.Intrinsics[inWeakSetPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'WeakSet', @WeakConstructor, 0, Prototype);
  Constructor_.Magic := KindSet;
  DefineMethod(R, Prototype, 'add', @WeakOperation, 1, KindSet * 16 + 5);
  DefineMethod(R, Prototype, 'has', @WeakOperation, 1, KindSet * 16 + 2);
  DefineMethod(R, Prototype, 'delete', @WeakOperation, 1, KindSet * 16 + 3);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('WeakSet'), PropertyConfigurable);

  Prototype := R.Intrinsics[inWeakRefPrototype];
  DefineConstructor(R, R.GlobalObject, 'WeakRef', @WeakRefConstructor, 1, Prototype);
  DefineMethod(R, Prototype, 'deref', @WeakRefDeref, 0);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('WeakRef'), PropertyConfigurable);

  Prototype := R.Intrinsics[inFinalizationRegistryPrototype];
  DefineConstructor(R, R.GlobalObject, 'FinalizationRegistry', @RegistryConstructor, 1, Prototype);
  DefineMethod(R, Prototype, 'register', @RegistryOperation, 2, 0);
  DefineMethod(R, Prototype, 'unregister', @RegistryOperation, 1, 1);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('FinalizationRegistry'),
    PropertyConfigurable);
end;

end.
