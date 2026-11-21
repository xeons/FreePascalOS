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
  Objects and the realm they are made in.

  An object has a shape (its named properties: Js.Shapes), slots for
  their values - the first JsInlineSlotCount inside the object, the
  rest in a buffer - a prototype, and dense elements: the values of
  index properties 0, 1, 2... in an array of their own, holes marked
  JsHole. Elements are plain data properties (writable, enumerable,
  configurable, unless the object is sealed or frozen, which the
  flags say for all elements at once). An index property with other
  attributes, an accessor, or one far beyond the elements is kept by
  name in the shape, with the integer as its key.

  Property keys are values: an integer for an index below 2^31, an atom
  for any other string key, a symbol. ToPropertyKey (Js.Conversions)
  makes them.

  The object protocol - the essential internal methods of the
  specification - is virtual: GetOwnProperty, DefineOwnProperty,
  HasProperty, Get, SetValue, DeleteProperty, OwnPropertyKeys and the
  prototype and extensibility methods. Ordinary objects, arrays (the
  length property) and the primitive wrappers (a String object's
  indices) are handled here; exotic objects elsewhere (proxies, typed
  arrays, host objects) override them.

  Every operation that can run JavaScript (an accessor) or throw takes
  the realm and returns JsException or -1 when it has thrown.

  TJsRealm is the realm as objects see it: the intrinsics, the global
  object, and the abstract operations the interpreter provides (Call,
  Construct, making errors with a stack trace).
}
unit Js.Objects;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime;

const
  JsInlineSlotCount = 4;

  ObjectExtensible = 1;
  ObjectCallable = 2;
  ObjectConstructor = 4;
  ObjectIsPrototype = 8;
  { GetOwnProperty and the others must go through the virtual methods. }
  ObjectExotic = 16;
  ObjectElementsFrozen = 32;
  ObjectElementsSealed = 64;
  { A function whose prototype property is made the first time it is
    looked at. }
  ObjectLazyPrototype = 128;
  { Some index properties are kept by name. }
  ObjectIndexedByName = 256;
  { An array whose length is read-only. }
  ObjectLengthReadOnly = 512;
  { A class constructor: calling it without new throws. }
  ObjectClassConstructor = 1024;
  { Arguments objects of sloppy functions, error objects: their class
    only informs Object.prototype.toString. }
  ObjectHostData = 2048;

  { Descriptor fields present. }
  HasValue = 1;
  HasGetter = 2;
  HasSetter = 4;
  HasWritable = 8;
  HasEnumerable = 16;
  HasConfigurable = 32;

  { Key filters for OwnPropertyKeys. }
  KeysStrings = 1;
  KeysSymbols = 2;
  KeysAll = 3;

type
  TJsObjectClass = (
    ocObject, ocArray, ocFunction, ocError, ocBoolean, ocNumber, ocString,
    ocSymbol, ocBigInt, ocDate, ocRegExp, ocArguments, ocMap, ocSet, ocWeakMap,
    ocWeakSet, ocWeakRef, ocFinalizationRegistry, ocPromise, ocGenerator,
    ocAsyncGenerator, ocIterator, ocProxy, ocHost, ocArrayBuffer, ocTypedArray,
    ocDataView, ocForIn, ocEnvironmentRecord);

  TJsErrorKind = (ekError, ekEval, ekRange, ekReference, ekSyntax, ekType, ekUri,
    ekAggregate, ekInternal);

  TJsIntrinsic = (
    inObjectPrototype, inFunctionPrototype, inArrayPrototype, inStringPrototype,
    inNumberPrototype, inBooleanPrototype, inSymbolPrototype, inBigIntPrototype,
    inErrorPrototype, inEvalErrorPrototype, inRangeErrorPrototype,
    inReferenceErrorPrototype, inSyntaxErrorPrototype, inTypeErrorPrototype,
    inUriErrorPrototype, inAggregateErrorPrototype, inInternalErrorPrototype,
    inIteratorPrototype, inArrayIteratorPrototype, inStringIteratorPrototype,
    inMapIteratorPrototype, inSetIteratorPrototype, inRegExpStringIteratorPrototype,
    inGeneratorPrototype, inGeneratorFunctionPrototype, inAsyncFunctionPrototype,
    inAsyncGeneratorPrototype, inAsyncGeneratorFunctionPrototype,
    inAsyncIteratorPrototype, inAsyncFromSyncIteratorPrototype,
    inPromisePrototype, inPromise, inMapPrototype, inSetPrototype,
    inWeakMapPrototype, inWeakSetPrototype, inWeakRefPrototype,
    inFinalizationRegistryPrototype, inRegExpPrototype, inRegExp, inDatePrototype,
    inArrayBufferPrototype, inDataViewPrototype, inTypedArrayPrototype,
    inThrowTypeError, inObject, inFunction, inArray, inArrayValues, inEval,
    inProxy, inPromiseResolveFunctions, inError,
    inArrayBuffer, inSharedArrayBuffer, inSharedArrayBufferPrototype, inDataView, inTypedArray,
    inInt8ArrayPrototype, inUint8ArrayPrototype, inUint8ClampedArrayPrototype, inInt16ArrayPrototype,
    inUint16ArrayPrototype, inInt32ArrayPrototype, inUint32ArrayPrototype, inFloat16ArrayPrototype,
    inFloat32ArrayPrototype, inFloat64ArrayPrototype, inBigInt64ArrayPrototype, inBigUint64ArrayPrototype,
    inInt8Array, inUint8Array, inUint8ClampedArray, inInt16Array, inUint16Array, inInt32Array, inUint32Array,
    inFloat16Array, inFloat32Array, inFloat64Array, inBigInt64Array, inBigUint64Array);

  TJsRealm = class;
  TJsObject = class;

  TJsPropertyDescriptor = record
    Value: TJsValue;
    Getter: TJsValue;
    Setter: TJsValue;
    Flags: Byte;
    Present: Byte;
  end;

  { The getter and setter of an accessor property, kept in its slot. }
  TJsAccessorPair = class(TJsCell)
  public
    Getter: TJsValue;
    Setter: TJsValue;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  TJsObject = class(TJsCell)
  protected
    function FindNamed(Key: TJsValue; out PropertyFlags: Byte): Integer; inline;
    function AddNamed(R: TJsRealm; Key: TJsValue; PropertyFlags: Byte; Value: TJsValue): Boolean;
    procedure MakeDictionary(R: TJsRealm);
    function ElementFlags: Byte; inline;
    function StoreNewElement(R: TJsRealm; Index: LongWord; Value: TJsValue): Boolean;
    function ApplyDescriptor(R: TJsRealm; Key: TJsValue; const Current: TJsPropertyDescriptor;
      const Desc: TJsPropertyDescriptor): Boolean;
    function OrdinaryDefine(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer;
    function SetSlow(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
  public
    Shape: TJsShape;
    Proto: TJsObject;
    ObjectFlags: Word;
    ObjectClass: TJsObjectClass;
    InlineSlots: array[0..JsInlineSlotCount - 1] of TJsValue;
    ExtraSlots: PJsValueArray;
    ExtraCapacity: Integer;
    Elements: PJsValueArray;
    ElementCount: Integer;
    ElementCapacity: Integer;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;

    function GetSlot(Index: Integer): TJsValue; inline;
    procedure SetSlot(Index: Integer; Value: TJsValue); inline;
    function SlotAddress(Index: Integer): PJsValue; inline;
    procedure EnsureSlotCapacity(R: TJsRealm; Count: Integer);
    procedure EnsureElementCapacity(R: TJsRealm; Count: Integer);
    { Makes the lazily made properties (a function's prototype). }
    procedure MaterializeLazy(R: TJsRealm); virtual;
    function IsCallable: Boolean; inline;
    function IsExtensibleFlag: Boolean; inline;

    { The internal methods. }
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; virtual;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; virtual;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; virtual;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; virtual;
    { 1 set, 0 refused (read-only, no setter), -1 thrown. }
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; virtual;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; virtual;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; virtual;
    function GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean; virtual;
    function SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer; virtual;
    function PreventExtensions(R: TJsRealm): Integer; virtual;
    function IsExtensible(R: TJsRealm): Integer; virtual;
    { [[Call]] and [[Construct]] of exotic callable objects (proxies, host
      objects); the realm handles closures, natives and bound functions. }
    function CallAsFunction(R: TJsRealm; This: TJsValue; Args: PJsValue; Count: Integer): TJsValue; virtual;
    function ConstructAsFunction(R: TJsRealm; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue; virtual;

    { Conveniences over the protocol. }
    function GetValue(R: TJsRealm; Key: TJsValue): TJsValue; inline;
    function Put(R: TJsRealm; Key, Value: TJsValue): Boolean;
    { Defines a data property with the attributes; for building objects
      (no checks that could fail on a fresh extensible object). }
    procedure DefineData(R: TJsRealm; Key, Value: TJsValue; PropertyFlags: Byte = PropertyDefault);
    procedure DefineAccessor(R: TJsRealm; Key, Getter, Setter: TJsValue; PropertyFlags: Byte);
    { CreateDataProperty: false when refused or thrown (see R.HasException). }
    function CreateDataProperty(R: TJsRealm; Key, Value: TJsValue): Boolean;
  end;

  TJsObjectClassType = class of TJsObject;

  TJsArray = class(TJsObject)
  public
    ArrayLength: LongWord;
    { The length set by assignment or defineProperty. }
    function SetLength(R: TJsRealm; NewLength: LongWord): Boolean;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
  end;

  { Boolean, Number, String, Symbol and BigInt objects. A String
    object's indices and length are its own read-only properties. }
  TJsPrimitiveObject = class(TJsObject)
  public
    PrimitiveValue: TJsValue;
    procedure Trace(Tracer: TJsTracer); override;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
  end;

  { A job of the job queue (promise reactions and the like): a Pascal
    handler and up to four values. }
  TJsJobHandler = procedure(R: TJsRealm; const Values: array of TJsValue);
  TJsJob = record
    Handler: TJsJobHandler;
    Values: array[0..3] of TJsValue;
  end;

  TJsRealm = class
  private
    FJobs: array of TJsJob;
    FJobHead: Integer;
    FJobCount: Integer;
    procedure MarkRoots(Tracer: TJsTracer);
  protected
    procedure TraceRealm(Tracer: TJsTracer); virtual;
  public
    Runtime: TJsRuntime;
    Heap: TJsHeap;
    Intrinsics: array[TJsIntrinsic] of TJsObject;
    GlobalObject: TJsObject;
    LengthKey: TJsValue;
    PrototypeKey: TJsValue;
    ConstructorKey: TJsValue;
    { A realm whose engine went while others share its runtime: its
      roots are no longer marked and its functions run in the caller's
      realm. }
    Detached: Boolean;
    { The shared runtime was freed before this realm (nothing of the heap
      may be touched). }
    HeapGone: Boolean;
    { While a function of this realm runs because another realm called
      it: that realm (the incumbent, for postMessage's source). }
    CallerRealm: TJsRealm;
    constructor Create(ARuntime: TJsRuntime);
    destructor Destroy; override;
    { The realm's engine goes but its runtime stays (other realms use it):
      functions of this realm may still be reachable from them. }
    procedure Detach; virtual;
    { Calls F (any value: not callable throws a TypeError). }
    function Call(F, This: TJsValue; Args: PJsValue; Count: Integer): TJsValue; virtual; abstract;
    function Construct(F: TJsValue; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue; virtual; abstract;
    { An Error object of the kind, with its stack trace. }
    function NewError(Kind: TJsErrorKind; const Message: string): TJsObject; virtual; abstract;
    function Throw(Value: TJsValue): TJsValue;
    function ThrowError(Kind: TJsErrorKind; const Message: string): TJsValue;
    function ThrowTypeError(const Message: string): TJsValue;
    function ThrowRangeError(const Message: string): TJsValue;
    function ThrowReferenceError(const Message: string): TJsValue;
    function HasException: Boolean; inline;
    { The job queue (microtasks): run in order by RunJobs. }
    procedure EnqueueJob(Handler: TJsJobHandler; V0, V1, V2, V3: TJsValue);
    { Runs jobs until the queue is empty; False when a job threw (the
      exception is left pending, the remaining jobs stay queued). }
    function RunJobs: Boolean;
    function PendingJobCount: Integer; inline;

    function NewObject(Prototype: TJsObject): TJsObject;
    function NewPlainObject: TJsObject;
    function NewObjectOfClass(ObjectType: TJsObjectClassType; Prototype: TJsObject;
      AClass: TJsObjectClass): TJsObject;
    function NewArray(Count: Integer = 0): TJsArray;
    function NewArrayFrom(Values: PJsValue; Count: Integer): TJsArray;
    function NewString(const Text: string): TJsValue; inline;
    function Intern(const Text: string): TJsValue; inline;
    function Atom(Name: TJsAtomName): TJsValue; inline;
    { Marks an object as some object's prototype. }
    procedure NoteIsPrototype(Prototype: TJsObject);
  end;

function JsAsObject(Value: TJsValue): TJsObject; inline;
function JsObjectValue(Value: TJsObject): TJsValue; inline;
function DataDescriptor(Value: TJsValue; PropertyFlags: Byte): TJsPropertyDescriptor;
function AccessorDescriptor(Getter, Setter: TJsValue; PropertyFlags: Byte): TJsPropertyDescriptor;
{ The value of an own-property lookup: data value or getter result. }
function DescriptorIsAccessor(const Desc: TJsPropertyDescriptor): Boolean; inline;
function SameValue(First, Second: TJsValue; Heap: TJsHeap): Boolean;
function SameValueZero(First, Second: TJsValue; Heap: TJsHeap): Boolean;
{ Strict equality (===). }
function StrictEquals(First, Second: TJsValue; Heap: TJsHeap): Boolean;
{ Sorts integer keys ascending (insertion sort; key lists are short). }
procedure SortIndexKeys(var Keys: TJsValueList; Start, Count: Integer);

var
  { ToNumber, for an array length set to something not a number; set by
    Js.Conversions. }
  JsToNumberHook: function(R: TJsRealm; Value: TJsValue): TJsValue = nil;

implementation

uses
  SysUtils,
  Js.BigIntegers;

function JsAsObject(Value: TJsValue): TJsObject;
begin
  Result := TJsObject(Pointer(PtrUInt(Value and JsPayloadMask)));
end;

function JsObjectValue(Value: TJsObject): TJsValue;
begin
  Result := JsObjectBase or QWord(PtrUInt(Value));
end;

function DataDescriptor(Value: TJsValue; PropertyFlags: Byte): TJsPropertyDescriptor;
begin
  Result.Value := Value;
  Result.Getter := JsUndefined;
  Result.Setter := JsUndefined;
  Result.Flags := PropertyFlags and not PropertyAccessor;
  Result.Present := HasValue or HasWritable or HasEnumerable or HasConfigurable;
end;

function AccessorDescriptor(Getter, Setter: TJsValue; PropertyFlags: Byte): TJsPropertyDescriptor;
begin
  Result.Value := JsUndefined;
  Result.Getter := Getter;
  Result.Setter := Setter;
  Result.Flags := (PropertyFlags or PropertyAccessor) and not PropertyWritable;
  Result.Present := HasGetter or HasSetter or HasEnumerable or HasConfigurable;
end;

function DescriptorIsAccessor(const Desc: TJsPropertyDescriptor): Boolean;
begin
  Result := (Desc.Flags and PropertyAccessor) <> 0;
end;

function NumbersSameValue(First, Second: Double): Boolean;
begin
  if IsNaNDouble(First) then
    Exit(IsNaNDouble(Second));
  Result := DoubleBits(First) = DoubleBits(Second);
end;

function SameValue(First, Second: TJsValue; Heap: TJsHeap): Boolean;
begin
  if First = Second then
    Exit(True);
  if JsIsNumber(First) and JsIsNumber(Second) then
    Exit(NumbersSameValue(JsNumberValue(First), JsNumberValue(Second)));
  if JsIsString(First) and JsIsString(Second) then
    Exit(StringsEqual(Heap, JsAsString(First), JsAsString(Second)));
  if JsIsBigInt(First) and JsIsBigInt(Second) then
    Exit(BigIntCompare(TJsBigInt(JsAsCell(First)), TJsBigInt(JsAsCell(Second))) = 0);
  Result := False;
end;

function SameValueZero(First, Second: TJsValue; Heap: TJsHeap): Boolean;
begin
  if JsIsNumber(First) and JsIsNumber(Second) then
  begin
    if IsNaNDouble(JsNumberValue(First)) then
      Exit(IsNaNDouble(JsNumberValue(Second)));
    Exit(JsNumberValue(First) = JsNumberValue(Second));
  end;
  Result := SameValue(First, Second, Heap);
end;

function StrictEquals(First, Second: TJsValue; Heap: TJsHeap): Boolean;
begin
  if JsIsNumber(First) and JsIsNumber(Second) then
  begin
    if JsIsInteger(First) and JsIsInteger(Second) then
      Exit(First = Second);
    Exit(JsNumberValue(First) = JsNumberValue(Second));
  end;
  if First = Second then
    Exit(True);
  if JsIsString(First) and JsIsString(Second) then
    Exit(StringsEqual(Heap, JsAsString(First), JsAsString(Second)));
  if JsIsBigInt(First) and JsIsBigInt(Second) then
    Exit(BigIntCompare(TJsBigInt(JsAsCell(First)), TJsBigInt(JsAsCell(Second))) = 0);
  Result := False;
end;

procedure SortIndexKeys(var Keys: TJsValueList; Start, Count: Integer);
var
  Index, Position: Integer;
  Key: TJsValue;
begin
  for Index := Start + 1 to Start + Count - 1 do
  begin
    Key := Keys[Index];
    Position := Index - 1;
    while (Position >= Start) and (JsAsInteger(Keys[Position]) > JsAsInteger(Key)) do
    begin
      Keys[Position + 1] := Keys[Position];
      Dec(Position);
    end;
    Keys[Position + 1] := Key;
  end;
end;

{ TJsAccessorPair }

procedure TJsAccessorPair.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkValue(Getter);
  Tracer.MarkValue(Setter);
end;

{ TJsObject }

destructor TJsObject.Destroy;
begin
  if ExtraSlots <> nil then
    FreeMem(ExtraSlots);
  if Elements <> nil then
    FreeMem(Elements);
  inherited Destroy;
end;

procedure TJsObject.Trace(Tracer: TJsTracer);
var
  Index, Count: Integer;
begin
  Tracer.MarkCell(Shape);
  if Proto <> nil then
    Tracer.MarkCell(Proto);
  Count := Shape.SlotCount;
  if Count > JsInlineSlotCount then
  begin
    Tracer.MarkValues(@InlineSlots[0], JsInlineSlotCount);
    Tracer.MarkValues(PJsValue(ExtraSlots), Count - JsInlineSlotCount);
  end
  else
    for Index := 0 to Count - 1 do
      Tracer.MarkValue(InlineSlots[Index]);
  if ElementCount > 0 then
    Tracer.MarkValues(PJsValue(Elements), ElementCount);
end;

function TJsObject.MemorySize: SizeInt;
begin
  Result := InstanceSize + (ExtraCapacity + ElementCapacity) * SizeOf(TJsValue);
end;

function TJsObject.GetSlot(Index: Integer): TJsValue;
begin
  if Index < JsInlineSlotCount then
    Result := InlineSlots[Index]
  else
    Result := ExtraSlots^[Index - JsInlineSlotCount];
end;

procedure TJsObject.SetSlot(Index: Integer; Value: TJsValue);
begin
  if Index < JsInlineSlotCount then
    InlineSlots[Index] := Value
  else
    ExtraSlots^[Index - JsInlineSlotCount] := Value;
end;

function TJsObject.SlotAddress(Index: Integer): PJsValue;
begin
  if Index < JsInlineSlotCount then
    Result := @InlineSlots[Index]
  else
    Result := @ExtraSlots^[Index - JsInlineSlotCount];
end;

procedure TJsObject.EnsureSlotCapacity(R: TJsRealm; Count: Integer);
var
  Needed, NewCapacity: Integer;
begin
  Needed := Count - JsInlineSlotCount;
  if Needed <= ExtraCapacity then
    Exit;
  NewCapacity := ExtraCapacity * 2;
  if NewCapacity < 4 then
    NewCapacity := 4;
  if NewCapacity < Needed then
    NewCapacity := Needed;
  ReAllocMem(ExtraSlots, NewCapacity * SizeOf(TJsValue));
  R.Heap.Account((NewCapacity - ExtraCapacity) * SizeOf(TJsValue));
  ExtraCapacity := NewCapacity;
end;

procedure TJsObject.EnsureElementCapacity(R: TJsRealm; Count: Integer);
var
  NewCapacity: Integer;
begin
  if Count <= ElementCapacity then
    Exit;
  NewCapacity := ElementCapacity + ElementCapacity div 2;
  if NewCapacity < 4 then
    NewCapacity := 4;
  if NewCapacity < Count then
    NewCapacity := Count;
  ReAllocMem(Elements, NewCapacity * SizeOf(TJsValue));
  R.Heap.Account((NewCapacity - ElementCapacity) * SizeOf(TJsValue));
  ElementCapacity := NewCapacity;
end;

procedure TJsObject.MaterializeLazy(R: TJsRealm);
begin
  ObjectFlags := ObjectFlags and not ObjectLazyPrototype;
end;

function TJsObject.IsCallable: Boolean;
begin
  Result := (ObjectFlags and ObjectCallable) <> 0;
end;

function TJsObject.IsExtensibleFlag: Boolean;
begin
  Result := (ObjectFlags and ObjectExtensible) <> 0;
end;

function TJsObject.FindNamed(Key: TJsValue; out PropertyFlags: Byte): Integer;
begin
  Result := Shape.Find(Key, PropertyFlags);
end;

function TJsObject.ElementFlags: Byte;
begin
  Result := PropertyDefault;
  if (ObjectFlags and ObjectElementsFrozen) <> 0 then
    Result := PropertyEnumerable
  else if (ObjectFlags and ObjectElementsSealed) <> 0 then
    Result := PropertyEnumerable or PropertyWritable;
end;

procedure TJsObject.MakeDictionary(R: TJsRealm);
begin
  if not Shape.IsDictionary then
    Shape := ShapeToDictionary(R.Heap, Shape);
end;

function TJsObject.AddNamed(R: TJsRealm; Key: TJsValue; PropertyFlags: Byte; Value: TJsValue): Boolean;
var
  Slot: Integer;
begin
  if (not Shape.IsDictionary) and (Shape.PropertyCount >= ShapeTreeLimit) then
    MakeDictionary(R);
  Slot := Shape.SlotCount;
  EnsureSlotCapacity(R, Slot + 1);
  Shape := ShapeWithProperty(R.Heap, Shape, Key, PropertyFlags);
  SetSlot(Slot, Value);
  if JsIsInteger(Key) then
    ObjectFlags := ObjectFlags or ObjectIndexedByName;
  if ((ObjectFlags and ObjectIsPrototype) <> 0) and
    ((PropertyFlags and (PropertyAccessor or PropertyWritable)) <> PropertyWritable) then
    Inc(R.Runtime.PrototypeEpoch);
  Result := True;
end;

{ Stores a new element at Index (no property there yet): dense when it
  extends the elements by little, by name when it is far beyond them. }
function TJsObject.StoreNewElement(R: TJsRealm; Index: LongWord; Value: TJsValue): Boolean;
var
  Position: Integer;
begin
  if (Index < LongWord(ElementCount)) then
  begin
    Elements^[Index] := Value;
    Exit(True);
  end;
  if (Index <= 2147483646) and ((Index < LongWord(ElementCount) + 1024) or (Index < LongWord(ElementCount) * 2)) and
    (ElementFlags = PropertyDefault) then
  begin
    EnsureElementCapacity(R, Integer(Index) + 1);
    for Position := ElementCount to Integer(Index) - 1 do
      Elements^[Position] := JsHole;
    Elements^[Index] := Value;
    ElementCount := Integer(Index) + 1;
    Exit(True);
  end;
  if Index > 2147483646 then
    Result := AddNamed(R, R.Runtime.Intern(IntToStr(Index)), PropertyDefault, Value)
  else
    Result := AddNamed(R, JsInteger(LongInt(Index)), PropertyDefault, Value);
end;

function TJsObject.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Index: LongInt;
  Slot: Integer;
  PropertyFlags: Byte;
  Pair: TJsAccessorPair;
  Value: TJsValue;
begin
  if JsIsInteger(Key) then
  begin
    Index := JsAsInteger(Key);
    if Index < ElementCount then
    begin
      Value := Elements^[Index];
      if Value <> JsHole then
      begin
        Desc := DataDescriptor(Value, ElementFlags);
        Exit(1);
      end;
    end;
    if (ObjectFlags and ObjectIndexedByName) = 0 then
      Exit(0);
  end
  else if (ObjectClass = ocArray) and (Key = R.LengthKey) then
  begin
    if (ObjectFlags and ObjectLengthReadOnly) <> 0 then
      PropertyFlags := 0
    else
      PropertyFlags := PropertyWritable;
    Desc := DataDescriptor(JsNumber(TJsArray(Self).ArrayLength), PropertyFlags);
    Exit(1);
  end
  else if ((ObjectFlags and ObjectLazyPrototype) <> 0) and (Key = R.PrototypeKey) then
    MaterializeLazy(R);
  Slot := Shape.Find(Key, PropertyFlags);
  if Slot < 0 then
    Exit(0);
  if (PropertyFlags and PropertyAccessor) <> 0 then
  begin
    Pair := TJsAccessorPair(JsAsCell(GetSlot(Slot)));
    Desc := AccessorDescriptor(Pair.Getter, Pair.Setter, PropertyFlags);
  end
  else
    Desc := DataDescriptor(GetSlot(Slot), PropertyFlags);
  Result := 1;
end;

function TJsObject.ApplyDescriptor(R: TJsRealm; Key: TJsValue; const Current: TJsPropertyDescriptor;
  const Desc: TJsPropertyDescriptor): Boolean;
var
  NewFlags: Byte;
  NewValue, NewGetter, NewSetter: TJsValue;
  Index: LongInt;
  Slot: Integer;
  OldFlags: Byte;
  Pair: TJsAccessorPair;
  ToAccessor: Boolean;
begin
  NewFlags := Current.Flags and (PropertyEnumerable or PropertyConfigurable or PropertyWritable);
  if (Desc.Present and HasEnumerable) <> 0 then
    NewFlags := (NewFlags and not PropertyEnumerable) or (Desc.Flags and PropertyEnumerable);
  if (Desc.Present and HasConfigurable) <> 0 then
    NewFlags := (NewFlags and not PropertyConfigurable) or (Desc.Flags and PropertyConfigurable);
  if (Desc.Present and (HasGetter or HasSetter)) <> 0 then
    ToAccessor := True
  else if (Desc.Present and (HasValue or HasWritable)) <> 0 then
    ToAccessor := False
  else
    ToAccessor := DescriptorIsAccessor(Current);
  if ToAccessor then
  begin
    NewFlags := (NewFlags and not PropertyWritable) or PropertyAccessor;
    if DescriptorIsAccessor(Current) then
    begin
      NewGetter := Current.Getter;
      NewSetter := Current.Setter;
    end
    else
    begin
      NewGetter := JsUndefined;
      NewSetter := JsUndefined;
    end;
    if (Desc.Present and HasGetter) <> 0 then
      NewGetter := Desc.Getter;
    if (Desc.Present and HasSetter) <> 0 then
      NewSetter := Desc.Setter;
    NewValue := JsUndefined;
  end
  else
  begin
    if DescriptorIsAccessor(Current) then
    begin
      NewFlags := NewFlags and not PropertyWritable;
      NewValue := JsUndefined;
    end
    else
      NewValue := Current.Value;
    if (Desc.Present and HasWritable) <> 0 then
      NewFlags := (NewFlags and not PropertyWritable) or (Desc.Flags and PropertyWritable);
    if (Desc.Present and HasValue) <> 0 then
      NewValue := Desc.Value;
  end;

  if JsIsInteger(Key) then
  begin
    Index := JsAsInteger(Key);
    if (Index < ElementCount) and (Elements^[Index] <> JsHole) then
    begin
      if (not ToAccessor) and (NewFlags = ElementFlags) then
      begin
        Elements^[Index] := NewValue;
        Exit(True);
      end;
      { Leaves the elements for the name table. }
      Elements^[Index] := JsHole;
      if ToAccessor then
      begin
        Pair := TJsAccessorPair.Create;
        R.Heap.Register(Pair, ckAccessor);
        Pair.Getter := NewGetter;
        Pair.Setter := NewSetter;
        Exit(AddNamed(R, Key, NewFlags, JsCellValue(JsObjectBase, Pair)));
      end;
      Exit(AddNamed(R, Key, NewFlags, NewValue));
    end;
  end;
  Slot := Shape.Find(Key, OldFlags);
  if Slot < 0 then
    Exit(False);
  if OldFlags <> NewFlags then
  begin
    MakeDictionary(R);
    DictionarySetFlags(Shape, Key, NewFlags);
    if ((ObjectFlags and ObjectIsPrototype) <> 0) then
      Inc(R.Runtime.PrototypeEpoch);
  end;
  if ToAccessor then
  begin
    if (OldFlags and PropertyAccessor) <> 0 then
      Pair := TJsAccessorPair(JsAsCell(GetSlot(Slot)))
    else
    begin
      Pair := TJsAccessorPair.Create;
      R.Heap.Register(Pair, ckAccessor);
      SetSlot(Slot, JsCellValue(JsObjectBase, Pair));
    end;
    Pair.Getter := NewGetter;
    Pair.Setter := NewSetter;
  end
  else
    SetSlot(Slot, NewValue);
  Result := True;
end;

function TJsObject.OrdinaryDefine(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Current: TJsPropertyDescriptor;
  Found: Integer;
  PropertyFlags: Byte;
  Pair: TJsAccessorPair;
  Value: TJsValue;
  Index: LongWord;

  function Reject: Integer;
  begin
    if ThrowOnFailure then
    begin
      R.ThrowTypeError('Cannot redefine property');
      Exit(-1);
    end;
    Result := 0;
  end;

begin
  Found := GetOwnProperty(R, Key, Current);
  if Found < 0 then
    Exit(-1);
  if Found = 0 then
  begin
    if (ObjectFlags and ObjectExtensible) = 0 then
    begin
      if ThrowOnFailure then
      begin
        R.ThrowTypeError('Cannot define property, object is not extensible');
        Exit(-1);
      end;
      Exit(0);
    end;
    PropertyFlags := Desc.Flags and (PropertyEnumerable or PropertyConfigurable);
    if (Desc.Present and (HasGetter or HasSetter)) <> 0 then
    begin
      Pair := TJsAccessorPair.Create;
      R.Heap.Register(Pair, ckAccessor);
      Pair.Getter := JsUndefined;
      Pair.Setter := JsUndefined;
      if (Desc.Present and HasGetter) <> 0 then
        Pair.Getter := Desc.Getter;
      if (Desc.Present and HasSetter) <> 0 then
        Pair.Setter := Desc.Setter;
      PropertyFlags := PropertyFlags or PropertyAccessor;
      Value := JsCellValue(JsObjectBase, Pair);
    end
    else
    begin
      if (Desc.Present and HasWritable) <> 0 then
        PropertyFlags := PropertyFlags or (Desc.Flags and PropertyWritable);
      Value := JsUndefined;
      if (Desc.Present and HasValue) <> 0 then
        Value := Desc.Value;
      if JsIsInteger(Key) and (PropertyFlags = PropertyDefault) and (ElementFlags = PropertyDefault) then
      begin
        Index := LongWord(JsAsInteger(Key));
        if (ObjectClass = ocArray) and (Index >= TJsArray(Self).ArrayLength) then
        begin
          if (ObjectFlags and ObjectLengthReadOnly) <> 0 then
            Exit(Reject);
          TJsArray(Self).ArrayLength := Index + 1;
        end;
        if StoreNewElement(R, Index, Value) then
          Exit(1);
        Exit(-1);
      end;
    end;
    if JsIsInteger(Key) and (ObjectClass = ocArray) then
    begin
      Index := LongWord(JsAsInteger(Key));
      if Index >= TJsArray(Self).ArrayLength then
      begin
        if (ObjectFlags and ObjectLengthReadOnly) <> 0 then
          Exit(Reject);
        TJsArray(Self).ArrayLength := Index + 1;
      end;
    end;
    AddNamed(R, Key, PropertyFlags, Value);
    Exit(1);
  end;
  { ValidateAndApplyPropertyDescriptor for an existing property. }
  if (Current.Flags and PropertyConfigurable) = 0 then
  begin
    if ((Desc.Present and HasConfigurable) <> 0) and ((Desc.Flags and PropertyConfigurable) <> 0) then
      Exit(Reject);
    if ((Desc.Present and HasEnumerable) <> 0) and
      ((Desc.Flags and PropertyEnumerable) <> (Current.Flags and PropertyEnumerable)) then
      Exit(Reject);
    if (Desc.Present and (HasGetter or HasSetter or HasValue or HasWritable)) <> 0 then
    begin
      if DescriptorIsAccessor(Current) <> ((Desc.Present and (HasGetter or HasSetter)) <> 0) then
        Exit(Reject);
      if DescriptorIsAccessor(Current) then
      begin
        if ((Desc.Present and HasGetter) <> 0) and not SameValue(Desc.Getter, Current.Getter, R.Heap) then
          Exit(Reject);
        if ((Desc.Present and HasSetter) <> 0) and not SameValue(Desc.Setter, Current.Setter, R.Heap) then
          Exit(Reject);
      end
      else if (Current.Flags and PropertyWritable) = 0 then
      begin
        if ((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) <> 0) then
          Exit(Reject);
        if ((Desc.Present and HasValue) <> 0) and not SameValue(Desc.Value, Current.Value, R.Heap) then
          Exit(Reject);
      end;
    end;
  end;
  if ApplyDescriptor(R, Key, Current, Desc) then
    Result := 1
  else
    Result := Reject;
end;

function TJsObject.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  NewLength: Double;
  NumberValue: TJsValue;
  Current: TJsPropertyDescriptor;
  Changed: TJsPropertyDescriptor;
begin
  if (ObjectClass = ocArray) and (Key = R.LengthKey) then
  begin
    { ArraySetLength. }
    if (Desc.Present and (HasGetter or HasSetter)) <> 0 then
    begin
      if ThrowOnFailure then
      begin
        R.ThrowTypeError('Cannot redefine property: length');
        Exit(-1);
      end;
      Exit(0);
    end;
    if (Desc.Present and HasValue) <> 0 then
    begin
      NumberValue := Desc.Value;
      if not JsIsNumber(NumberValue) then
      begin
        NumberValue := JsToNumberHook(R, NumberValue);
        if NumberValue = JsException then
          Exit(-1);
      end;
      NewLength := JsNumberValue(NumberValue);
      if (NewLength < 0) or (NewLength > 4294967295.0) or (Trunc(NewLength) <> NewLength) then
      begin
        R.ThrowRangeError('Invalid array length');
        Exit(-1);
      end;
    end
    else
      NewLength := TJsArray(Self).ArrayLength;
    GetOwnProperty(R, Key, Current);
    if (((Desc.Present and HasConfigurable) <> 0) and ((Desc.Flags and PropertyConfigurable) <> 0)) or
      (((Desc.Present and HasEnumerable) <> 0) and ((Desc.Flags and PropertyEnumerable) <> 0)) or
      (((ObjectFlags and ObjectLengthReadOnly) <> 0) and
      ((((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) <> 0)) or
      (LongWord(Trunc(NewLength)) <> TJsArray(Self).ArrayLength))) then
    begin
      if ThrowOnFailure then
      begin
        R.ThrowTypeError('Cannot redefine property: length');
        Exit(-1);
      end;
      Exit(0);
    end;
    if not TJsArray(Self).SetLength(R, LongWord(Trunc(NewLength))) then
    begin
      if ThrowOnFailure then
      begin
        R.ThrowTypeError('Cannot delete array element');
        Exit(-1);
      end;
      Exit(0);
    end;
    if ((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) = 0) then
      ObjectFlags := ObjectFlags or ObjectLengthReadOnly;
    Exit(1);
  end;
  Changed := Desc;
  Result := OrdinaryDefine(R, Key, Changed, ThrowOnFailure);
end;

function TJsObject.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Current: TJsObject;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Current := Self;
  while Current <> nil do
  begin
    if ((Current.ObjectFlags and ObjectExotic) <> 0) and (Current <> Self) then
      Exit(Current.HasProperty(R, Key));
    Found := Current.GetOwnProperty(R, Key, Desc);
    if Found <> 0 then
      Exit(Found);
    Current := Current.Proto;
  end;
  Result := 0;
end;

function TJsObject.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Current: TJsObject;
  Index: LongInt;
  Slot: Integer;
  PropertyFlags: Byte;
  Pair: TJsAccessorPair;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Current := Self;
  while Current <> nil do
  begin
    if (Current.ObjectFlags and ObjectExotic) <> 0 then
    begin
      if Current <> Self then
        Exit(Current.Get(R, Key, Receiver));
      Found := Current.GetOwnProperty(R, Key, Desc);
      if Found < 0 then
        Exit(JsException);
      if Found > 0 then
      begin
        if not DescriptorIsAccessor(Desc) then
          Exit(Desc.Value);
        if Desc.Getter = JsUndefined then
          Exit(JsUndefined);
        Exit(R.Call(Desc.Getter, Receiver, nil, 0));
      end;
      Current := Current.Proto;
      Continue;
    end;
    if JsIsInteger(Key) then
    begin
      Index := JsAsInteger(Key);
      if (Index < Current.ElementCount) and (Current.Elements^[Index] <> JsHole) then
        Exit(Current.Elements^[Index]);
      if (Current.ObjectFlags and ObjectIndexedByName) = 0 then
      begin
        Current := Current.Proto;
        Continue;
      end;
    end
    else if (Current.ObjectClass = ocArray) and (Key = R.LengthKey) then
      Exit(JsNumber(TJsArray(Current).ArrayLength))
    else if ((Current.ObjectFlags and ObjectLazyPrototype) <> 0) and (Key = R.PrototypeKey) then
      Current.MaterializeLazy(R);
    Slot := Current.Shape.Find(Key, PropertyFlags);
    if Slot >= 0 then
    begin
      if (PropertyFlags and PropertyAccessor) = 0 then
        Exit(Current.GetSlot(Slot));
      Pair := TJsAccessorPair(JsAsCell(Current.GetSlot(Slot)));
      if Pair.Getter = JsUndefined then
        Exit(JsUndefined);
      Exit(R.Call(Pair.Getter, Receiver, nil, 0));
    end;
    Current := Current.Proto;
  end;
  Result := JsUndefined;
end;

function TJsObject.CallAsFunction(R: TJsRealm; This: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
begin
  Result := R.ThrowTypeError('object is not a function');
end;

function TJsObject.ConstructAsFunction(R: TJsRealm; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue;
begin
  Result := R.ThrowTypeError('object is not a constructor');
end;

function TJsObject.GetValue(R: TJsRealm; Key: TJsValue): TJsValue;
begin
  Result := Get(R, Key, JsObjectValue(Self));
end;

{ OrdinarySet when the receiver is not this object, or the fast path
  could not decide. }
function TJsObject.SetSlow(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  OwnDesc, ReceiverDesc: TJsPropertyDescriptor;
  Found: Integer;
  Parent: TJsObject;
  ReceiverObject: TJsObject;
begin
  Found := GetOwnProperty(R, Key, OwnDesc);
  if Found < 0 then
    Exit(-1);
  if Found = 0 then
  begin
    if not GetPrototype(R, Parent) then
      Exit(-1);
    if Parent <> nil then
      Exit(Parent.SetValue(R, Key, Value, Receiver));
    OwnDesc := DataDescriptor(JsUndefined, PropertyDefault);
  end;
  if not DescriptorIsAccessor(OwnDesc) then
  begin
    if (OwnDesc.Flags and PropertyWritable) = 0 then
      Exit(0);
    if not JsIsObject(Receiver) then
      Exit(0);
    ReceiverObject := JsAsObject(Receiver);
    Found := ReceiverObject.GetOwnProperty(R, Key, ReceiverDesc);
    if Found < 0 then
      Exit(-1);
    if Found > 0 then
    begin
      if DescriptorIsAccessor(ReceiverDesc) or ((ReceiverDesc.Flags and PropertyWritable) = 0) then
        Exit(0);
      ReceiverDesc.Value := Value;
      ReceiverDesc.Present := HasValue;
      Exit(ReceiverObject.DefineOwnProperty(R, Key, ReceiverDesc, False));
    end;
    Exit(ReceiverObject.DefineOwnProperty(R, Key, DataDescriptor(Value, PropertyDefault), False));
  end;
  if OwnDesc.Setter = JsUndefined then
    Exit(0);
  if R.Call(OwnDesc.Setter, Receiver, @Value, 1) = JsException then
    Exit(-1);
  Result := 1;
end;

function TJsObject.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  Index: LongInt;
  Slot: Integer;
  PropertyFlags: Byte;
  Current: TJsObject;
  Pair: TJsAccessorPair;
begin
  if (Receiver <> JsObjectValue(Self)) or ((ObjectFlags and ObjectExotic) <> 0) then
    Exit(SetSlow(R, Key, Value, Receiver));
  { The common case: an ordinary receiver that is this object. }
  if JsIsInteger(Key) then
  begin
    Index := JsAsInteger(Key);
    if (Index < ElementCount) and (Elements^[Index] <> JsHole) then
    begin
      if (ObjectFlags and ObjectElementsFrozen) <> 0 then
        Exit(0);
      Elements^[Index] := Value;
      Exit(1);
    end;
  end
  else if (ObjectClass = ocArray) and (Key = R.LengthKey) then
    Exit(SetSlow(R, Key, Value, Receiver))
  else if ((ObjectFlags and ObjectLazyPrototype) <> 0) and (Key = R.PrototypeKey) then
    MaterializeLazy(R);
  if not JsIsInteger(Key) or ((ObjectFlags and ObjectIndexedByName) <> 0) then
  begin
    Slot := Shape.Find(Key, PropertyFlags);
    if Slot >= 0 then
    begin
      if (PropertyFlags and PropertyAccessor) <> 0 then
      begin
        Pair := TJsAccessorPair(JsAsCell(GetSlot(Slot)));
        if Pair.Setter = JsUndefined then
          Exit(0);
        if R.Call(Pair.Setter, Receiver, @Value, 1) = JsException then
          Exit(-1);
        Exit(1);
      end;
      if (PropertyFlags and PropertyWritable) = 0 then
        Exit(0);
      SetSlot(Slot, Value);
      Exit(1);
    end;
  end;
  { Not an own property: the prototypes may have a setter or a
    read-only property of that name. }
  Current := Proto;
  while Current <> nil do
  begin
    if (Current.ObjectFlags and ObjectExotic) <> 0 then
      Exit(Current.SetValue(R, Key, Value, Receiver));
    if JsIsInteger(Key) then
    begin
      Index := JsAsInteger(Key);
      if (Index < Current.ElementCount) and (Current.Elements^[Index] <> JsHole) then
      begin
        if (Current.ObjectFlags and ObjectElementsFrozen) <> 0 then
          Exit(0);
        Break;
      end;
    end
    else if (Current.ObjectClass = ocArray) and (Key = R.LengthKey) then
    begin
      if (Current.ObjectFlags and ObjectLengthReadOnly) <> 0 then
        Exit(0);
      Break;
    end;
    if not JsIsInteger(Key) or ((Current.ObjectFlags and ObjectIndexedByName) <> 0) then
    begin
      if ((Current.ObjectFlags and ObjectLazyPrototype) <> 0) and (Key = R.PrototypeKey) then
        Current.MaterializeLazy(R);
      Slot := Current.Shape.Find(Key, PropertyFlags);
      if Slot >= 0 then
      begin
        if (PropertyFlags and PropertyAccessor) <> 0 then
        begin
          Pair := TJsAccessorPair(JsAsCell(Current.GetSlot(Slot)));
          if Pair.Setter = JsUndefined then
            Exit(0);
          if R.Call(Pair.Setter, Receiver, @Value, 1) = JsException then
            Exit(-1);
          Exit(1);
        end;
        if (PropertyFlags and PropertyWritable) = 0 then
          Exit(0);
        Break;
      end;
    end;
    Current := Current.Proto;
  end;
  { A new own data property. }
  if (ObjectFlags and ObjectExtensible) = 0 then
    Exit(0);
  if JsIsInteger(Key) then
  begin
    Index := JsAsInteger(Key);
    if ObjectClass = ocArray then
    begin
      if LongWord(Index) >= TJsArray(Self).ArrayLength then
      begin
        if (ObjectFlags and ObjectLengthReadOnly) <> 0 then
          Exit(0);
        TJsArray(Self).ArrayLength := LongWord(Index) + 1;
      end;
    end;
    if (ElementFlags = PropertyDefault) and StoreNewElement(R, LongWord(Index), Value) then
      Exit(1);
    AddNamed(R, Key, PropertyDefault, Value);
    Exit(1);
  end;
  AddNamed(R, Key, PropertyDefault, Value);
  Result := 1;
end;

function TJsObject.Put(R: TJsRealm; Key, Value: TJsValue): Boolean;
begin
  Result := SetValue(R, Key, Value, JsObjectValue(Self)) >= 0;
end;

function TJsObject.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Index: LongInt;
  Slot: Integer;
  PropertyFlags: Byte;
begin
  if JsIsInteger(Key) then
  begin
    Index := JsAsInteger(Key);
    if (Index < ElementCount) and (Elements^[Index] <> JsHole) then
    begin
      if (ObjectFlags and ObjectElementsSealed) <> 0 then
        Exit(0);
      Elements^[Index] := JsHole;
      if Index = ElementCount - 1 then
        while (ElementCount > 0) and (Elements^[ElementCount - 1] = JsHole) do
          Dec(ElementCount);
      Exit(1);
    end;
    if (ObjectFlags and ObjectIndexedByName) = 0 then
      Exit(1);
  end
  else if (ObjectClass = ocArray) and (Key = R.LengthKey) then
    Exit(0)
  else if ((ObjectFlags and ObjectLazyPrototype) <> 0) and (Key = R.PrototypeKey) then
    MaterializeLazy(R);
  Slot := Shape.Find(Key, PropertyFlags);
  if Slot < 0 then
    Exit(1);
  if (PropertyFlags and PropertyConfigurable) = 0 then
    Exit(0);
  MakeDictionary(R);
  SetSlot(Slot, JsUndefined);
  DictionaryRemove(R.Heap, Shape, Key);
  Result := 1;
end;

function TJsObject.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Entries: TJsShapeEntryList;
  Count, Index, IndexCount, NamedIntegers: Integer;
  Key: TJsValue;
begin
  Keys := nil;
  if (ObjectFlags and ObjectLazyPrototype) <> 0 then
    MaterializeLazy(R);
  Entries := Shape.Entries;
  System.SetLength(Keys, ElementCount + Length(Entries));
  Count := 0;
  if (Filter and KeysStrings) <> 0 then
  begin
    for Index := 0 to ElementCount - 1 do
      if Elements^[Index] <> JsHole then
      begin
        Keys[Count] := JsInteger(Index);
        Inc(Count);
      end;
    IndexCount := Count;
    NamedIntegers := 0;
    for Index := 0 to High(Entries) do
      if JsIsInteger(Entries[Index].Key) then
      begin
        Keys[Count] := Entries[Index].Key;
        Inc(Count);
        Inc(NamedIntegers);
      end;
    if NamedIntegers > 0 then
      SortIndexKeys(Keys, 0, Count);
    if IndexCount < 0 then
      Exit(False);
    for Index := 0 to High(Entries) do
      if JsIsString(Entries[Index].Key) then
      begin
        Keys[Count] := Entries[Index].Key;
        Inc(Count);
      end;
  end;
  if (Filter and KeysSymbols) <> 0 then
    for Index := 0 to High(Entries) do
    begin
      Key := Entries[Index].Key;
      if JsIsSymbol(Key) and not JsAsSymbol(Key).IsPrivate then
      begin
        Keys[Count] := Key;
        Inc(Count);
      end;
    end;
  System.SetLength(Keys, Count);
  Result := True;
end;

function TJsObject.GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean;
begin
  Prototype := Proto;
  Result := True;
end;

function TJsObject.SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer;
var
  Walk: TJsObject;
begin
  if Prototype = Proto then
    Exit(1);
  if (ObjectFlags and ObjectExtensible) = 0 then
    Exit(0);
  Walk := Prototype;
  while Walk <> nil do
  begin
    if Walk = Self then
      Exit(0);
    if (Walk.ObjectFlags and ObjectExotic) <> 0 then
      Break;
    Walk := Walk.Proto;
  end;
  Proto := Prototype;
  if Prototype <> nil then
    R.NoteIsPrototype(Prototype);
  Inc(R.Runtime.PrototypeEpoch);
  Result := 1;
end;

function TJsObject.PreventExtensions(R: TJsRealm): Integer;
begin
  ObjectFlags := ObjectFlags and not ObjectExtensible;
  Inc(R.Runtime.PrototypeEpoch);
  Result := 1;
end;

function TJsObject.IsExtensible(R: TJsRealm): Integer;
begin
  if (ObjectFlags and ObjectExtensible) <> 0 then
    Result := 1
  else
    Result := 0;
end;

procedure TJsObject.DefineData(R: TJsRealm; Key, Value: TJsValue; PropertyFlags: Byte);
var
  Slot: Integer;
  OldFlags: Byte;
begin
  if JsIsInteger(Key) or (ObjectClass = ocArray) or ((ObjectFlags and ObjectExotic) <> 0) then
  begin
    DefineOwnProperty(R, Key, DataDescriptor(Value, PropertyFlags), False);
    Exit;
  end;
  Slot := Shape.Find(Key, OldFlags);
  if Slot < 0 then
    AddNamed(R, Key, PropertyFlags, Value)
  else
    OrdinaryDefine(R, Key, DataDescriptor(Value, PropertyFlags), False);
end;

procedure TJsObject.DefineAccessor(R: TJsRealm; Key, Getter, Setter: TJsValue; PropertyFlags: Byte);
var
  Desc: TJsPropertyDescriptor;
begin
  Desc := AccessorDescriptor(Getter, Setter, PropertyFlags);
  DefineOwnProperty(R, Key, Desc, False);
end;

function TJsObject.CreateDataProperty(R: TJsRealm; Key, Value: TJsValue): Boolean;
var
  PropertyFlags: Byte;
begin
  if ((ObjectFlags and (ObjectExotic or ObjectIndexedByName)) = 0) and (ObjectClass <> ocArray) and
    not JsIsInteger(Key) and ((ObjectFlags and ObjectExtensible) <> 0) and
    ((ObjectFlags and ObjectLazyPrototype) = 0) then
  begin
    if Shape.Find(Key, PropertyFlags) < 0 then
    begin
      AddNamed(R, Key, PropertyDefault, Value);
      Exit(True);
    end;
  end;
  Result := DefineOwnProperty(R, Key, DataDescriptor(Value, PropertyDefault), False) > 0;
end;

{ TJsArray }

function TJsArray.SetLength(R: TJsRealm; NewLength: LongWord): Boolean;
var
  Index: Integer;
  Keys: TJsValueList;
  Entries: TJsShapeEntryList;
  Key: TJsValue;
begin
  Result := True;
  if NewLength < LongWord(ElementCount) then
  begin
    if (ObjectFlags and ObjectElementsSealed) <> 0 then
    begin
      { Sealed elements cannot go: the length stops above the last. }
      ArrayLength := ElementCount;
      Exit(False);
    end;
    for Index := Integer(NewLength) to ElementCount - 1 do
      Elements^[Index] := JsHole;
    ElementCount := Integer(NewLength);
  end;
  if ((ObjectFlags and ObjectIndexedByName) <> 0) and (NewLength < ArrayLength) then
  begin
    Entries := Shape.Entries;
    Keys := nil;
    for Index := High(Entries) downto 0 do
    begin
      Key := Entries[Index].Key;
      if JsIsInteger(Key) and (LongWord(JsAsInteger(Key)) >= NewLength) then
      begin
        if DeleteProperty(R, Key) = 0 then
        begin
          ArrayLength := LongWord(JsAsInteger(Key)) + 1;
          Exit(False);
        end;
      end;
    end;
  end;
  ArrayLength := NewLength;
end;

function TJsArray.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Count, Index, Position: Integer;
begin
  Result := inherited OwnPropertyKeys(R, Filter, Keys);
  if (Filter and KeysStrings) = 0 then
    Exit;
  { length comes after the indices, before the other names. }
  Count := Length(Keys);
  Position := 0;
  while (Position < Count) and JsIsInteger(Keys[Position]) do
    Inc(Position);
  System.SetLength(Keys, Count + 1);
  for Index := Count downto Position + 1 do
    Keys[Index] := Keys[Index - 1];
  Keys[Position] := R.LengthKey;
end;

{ TJsPrimitiveObject }

procedure TJsPrimitiveObject.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(PrimitiveValue);
end;

function TJsPrimitiveObject.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Text: TJsString;
  Index: LongInt;
begin
  if ObjectClass = ocString then
  begin
    Text := JsAsString(PrimitiveValue);
    if JsIsInteger(Key) then
    begin
      Index := JsAsInteger(Key);
      if (Index >= 0) and (Index < Text.Length) then
      begin
        Text.Flatten(R.Heap);
        Desc := DataDescriptor(JsStringValue(R.Runtime.CharacterString(Text.CharAt(Index))), PropertyEnumerable);
        Exit(1);
      end;
    end
    else if Key = R.LengthKey then
    begin
      Desc := DataDescriptor(JsInteger(Text.Length), 0);
      Exit(1);
    end;
  end;
  Result := inherited GetOwnProperty(R, Key, Desc);
end;

function TJsPrimitiveObject.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Current: TJsPropertyDescriptor;
begin
  if (ObjectClass = ocString) and (JsIsInteger(Key) or (Key = R.LengthKey)) and
    (GetOwnProperty(R, Key, Current) > 0) and ((JsIsInteger(Key) and (Current.Flags = PropertyEnumerable)) or
    (Key = R.LengthKey)) then
  begin
    { The string's own characters are read-only and fixed. }
    if (((Desc.Present and HasValue) = 0) or SameValue(Desc.Value, Current.Value, R.Heap)) and
      (((Desc.Present and HasWritable) = 0) or ((Desc.Flags and PropertyWritable) = 0)) and
      (((Desc.Present and HasConfigurable) = 0) or ((Desc.Flags and PropertyConfigurable) = 0)) and
      (((Desc.Present and HasEnumerable) = 0) or ((Desc.Flags and PropertyEnumerable) =
      (Current.Flags and PropertyEnumerable))) and ((Desc.Present and (HasGetter or HasSetter)) = 0) then
      Exit(1);
    if ThrowOnFailure then
    begin
      R.ThrowTypeError('Cannot redefine property');
      Exit(-1);
    end;
    Exit(0);
  end;
  Result := inherited DefineOwnProperty(R, Key, Desc, ThrowOnFailure);
end;

function TJsPrimitiveObject.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Desc: TJsPropertyDescriptor;
begin
  if (ObjectClass = ocString) and (GetOwnProperty(R, Key, Desc) > 0) then
    Exit(1);
  Result := inherited HasProperty(R, Key);
end;

function TJsPrimitiveObject.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Desc: TJsPropertyDescriptor;
begin
  if (ObjectClass = ocString) and (JsIsInteger(Key) or (Key = R.LengthKey)) and
    (GetOwnProperty(R, Key, Desc) > 0) and not DescriptorIsAccessor(Desc) then
    Exit(Desc.Value);
  Result := inherited Get(R, Key, Receiver);
end;

function TJsPrimitiveObject.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
begin
  Result := SetSlow(R, Key, Value, Receiver);
end;

function TJsPrimitiveObject.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Desc: TJsPropertyDescriptor;
begin
  if (ObjectClass = ocString) and (JsIsInteger(Key) or (Key = R.LengthKey)) and
    (GetOwnProperty(R, Key, Desc) > 0) and ((Desc.Flags and PropertyConfigurable) = 0) and
    ((Key = R.LengthKey) or (Desc.Flags = PropertyEnumerable)) then
    Exit(0);
  Result := inherited DeleteProperty(R, Key);
end;

function TJsPrimitiveObject.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Own: TJsValueList;
  Text: TJsString;
  Count, Index, Position: Integer;
begin
  Result := inherited OwnPropertyKeys(R, Filter, Own);
  if (ObjectClass <> ocString) or ((Filter and KeysStrings) = 0) then
  begin
    Keys := Own;
    Exit;
  end;
  Text := JsAsString(PrimitiveValue);
  Keys := nil;
  System.SetLength(Keys, Text.Length + Length(Own) + 1);
  Count := 0;
  for Index := 0 to Text.Length - 1 do
  begin
    Keys[Count] := JsInteger(Index);
    Inc(Count);
  end;
  Position := 0;
  while (Position < Length(Own)) and JsIsInteger(Own[Position]) do
  begin
    if JsAsInteger(Own[Position]) >= Text.Length then
    begin
      Keys[Count] := Own[Position];
      Inc(Count);
    end;
    Inc(Position);
  end;
  Keys[Count] := R.LengthKey;
  Inc(Count);
  while Position < Length(Own) do
  begin
    Keys[Count] := Own[Position];
    Inc(Count);
    Inc(Position);
  end;
  System.SetLength(Keys, Count);
end;

{ TJsRealm }

constructor TJsRealm.Create(ARuntime: TJsRuntime);
begin
  inherited Create;
  Runtime := ARuntime;
  Heap := ARuntime.Heap;
  LengthKey := ARuntime.AtomValue(anLength);
  PrototypeKey := ARuntime.AtomValue(anPrototype);
  ConstructorKey := ARuntime.AtomValue(anConstructor);
  Heap.AddRootProvider(@MarkRoots);
end;

destructor TJsRealm.Destroy;
begin
  if not HeapGone then
    Heap.RemoveRootProvider(@MarkRoots);
  inherited Destroy;
end;

procedure TJsRealm.MarkRoots(Tracer: TJsTracer);
begin
  if not Detached then
    TraceRealm(Tracer);
end;

procedure TJsRealm.Detach;
begin
  Detached := True;
  FJobCount := 0;
  FJobHead := 0;
  FJobs := nil;
end;

procedure TJsRealm.TraceRealm(Tracer: TJsTracer);
var
  Intrinsic: TJsIntrinsic;
  Index: Integer;
begin
  for Index := FJobHead to FJobHead + FJobCount - 1 do
    Tracer.MarkValues(@FJobs[Index].Values[0], 4);
  for Intrinsic := Low(TJsIntrinsic) to High(TJsIntrinsic) do
    if Intrinsics[Intrinsic] <> nil then
      Tracer.MarkCell(Intrinsics[Intrinsic]);
  if GlobalObject <> nil then
    Tracer.MarkCell(GlobalObject);
end;

function TJsRealm.Throw(Value: TJsValue): TJsValue;
begin
  Runtime.Exception := Value;
  Runtime.HasException := True;
  Result := JsException;
end;

function TJsRealm.ThrowError(Kind: TJsErrorKind; const Message: string): TJsValue;
begin
  Result := Throw(JsObjectValue(NewError(Kind, Message)));
end;

function TJsRealm.ThrowTypeError(const Message: string): TJsValue;
begin
  Result := ThrowError(ekType, Message);
end;

function TJsRealm.ThrowRangeError(const Message: string): TJsValue;
begin
  Result := ThrowError(ekRange, Message);
end;

function TJsRealm.ThrowReferenceError(const Message: string): TJsValue;
begin
  Result := ThrowError(ekReference, Message);
end;

function TJsRealm.HasException: Boolean;
begin
  Result := Runtime.HasException;
end;

procedure TJsRealm.EnqueueJob(Handler: TJsJobHandler; V0, V1, V2, V3: TJsValue);
var
  Index: Integer;
begin
  if FJobHead + FJobCount >= Length(FJobs) then
  begin
    if FJobHead > 0 then
    begin
      for Index := 0 to FJobCount - 1 do
        FJobs[Index] := FJobs[FJobHead + Index];
      FJobHead := 0;
    end;
    if FJobCount >= Length(FJobs) then
      SetLength(FJobs, Length(FJobs) * 2 + 16);
  end;
  Index := FJobHead + FJobCount;
  FJobs[Index].Handler := Handler;
  FJobs[Index].Values[0] := V0;
  FJobs[Index].Values[1] := V1;
  FJobs[Index].Values[2] := V2;
  FJobs[Index].Values[3] := V3;
  Inc(FJobCount);
end;

function TJsRealm.RunJobs: Boolean;
var
  Job: TJsJob;
  Mark: Integer;
begin
  Result := True;
  while FJobCount > 0 do
  begin
    Job := FJobs[FJobHead];
    Inc(FJobHead);
    Dec(FJobCount);
    if FJobCount = 0 then
      FJobHead := 0;
    Mark := Runtime.PushRoot(Job.Values[0]);
    Runtime.PushRoot(Job.Values[1]);
    Runtime.PushRoot(Job.Values[2]);
    Runtime.PushRoot(Job.Values[3]);
    Job.Handler(Self, Job.Values);
    Runtime.PopRoots(Mark);
    if Runtime.HasException then
      Exit(False);
  end;
end;

function TJsRealm.PendingJobCount: Integer;
begin
  Result := FJobCount;
end;

function TJsRealm.NewObjectOfClass(ObjectType: TJsObjectClassType; Prototype: TJsObject;
  AClass: TJsObjectClass): TJsObject;
begin
  Result := ObjectType.Create;
  Heap.Register(Result, ckObject);
  Result.Shape := Runtime.RootShape;
  Result.Proto := Prototype;
  Result.ObjectFlags := ObjectExtensible;
  Result.ObjectClass := AClass;
end;

function TJsRealm.NewObject(Prototype: TJsObject): TJsObject;
begin
  Result := NewObjectOfClass(TJsObject, Prototype, ocObject);
end;

function TJsRealm.NewPlainObject: TJsObject;
begin
  Result := NewObjectOfClass(TJsObject, Intrinsics[inObjectPrototype], ocObject);
end;

function TJsRealm.NewArray(Count: Integer): TJsArray;
var
  Index: Integer;
begin
  Result := TJsArray(NewObjectOfClass(TJsArray, Intrinsics[inArrayPrototype], ocArray));
  if Count > 0 then
  begin
    Result.EnsureElementCapacity(Self, Count);
    for Index := 0 to Count - 1 do
      Result.Elements^[Index] := JsUndefined;
    Result.ElementCount := Count;
    Result.ArrayLength := Count;
  end;
end;

function TJsRealm.NewArrayFrom(Values: PJsValue; Count: Integer): TJsArray;
begin
  Result := NewArray(0);
  if Count > 0 then
  begin
    Result.EnsureElementCapacity(Self, Count);
    Move(Values^, Result.Elements^[0], Count * SizeOf(TJsValue));
    Result.ElementCount := Count;
    Result.ArrayLength := Count;
  end;
end;

function TJsRealm.NewString(const Text: string): TJsValue;
begin
  Result := Runtime.NewString(Text);
end;

function TJsRealm.Intern(const Text: string): TJsValue;
begin
  Result := Runtime.Intern(Text);
end;

function TJsRealm.Atom(Name: TJsAtomName): TJsValue;
begin
  Result := Runtime.AtomValue(Name);
end;

procedure TJsRealm.NoteIsPrototype(Prototype: TJsObject);
begin
  if (Prototype.ObjectFlags and ObjectIsPrototype) = 0 then
  begin
    Prototype.ObjectFlags := Prototype.ObjectFlags or ObjectIsPrototype;
    Inc(Runtime.PrototypeEpoch);
  end;
end;

end.
