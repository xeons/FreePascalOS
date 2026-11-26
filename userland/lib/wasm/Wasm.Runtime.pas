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
  The store (spec section 4.2): function, table, memory, global and tag
  instances, module instances, the garbage collected heap and the
  execution stack.

  A store belongs to one thread of execution (one JS agent); nothing in
  the engine is shared between stores, and the store owns every instance
  made in it until it is destroyed (instances live as long as anything
  could still reach them, which without a collector for them is the
  store's lifetime). Garbage collected objects (structs, arrays,
  exceptions) are collected (Wasm.GcHeap) from the roots the store
  enumerates here.

  Types are made canonical per store (Wasm.TypeRegistry): equivalent
  types get the same id, so call_indirect's check, casts and import
  matching compare numbers or walk a supertype chain.

  The execution stack is one array of 64-bit slots shared by all frames
  (Wasm.Code), with a record of the suspended frames beside it; it
  grows on demand up to Options.MaximumStackSlots, and the call depth is
  limited by Options.MaximumCallDepth. Exceeding either traps with "call
  stack exhausted" instead of running the host thread out of stack, as
  does nesting host calls into WebAssembly too deeply.

  Collection and the embedder (see Wasm.Api for the protocol): the roots
  are the store's globals, tables and element segments, the slots of
  suspended frames by the compiler's safepoint maps, pinned objects, the
  objects handed to the embedder since its last trace (exposed), and
  exceptions in flight (pinned by EWasmException).
}
unit Wasm.Runtime;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Wasm.Types,
  Wasm.TypeDefinitions,
  Wasm.Module,
  Wasm.Code,
  Wasm.GcHeap,
  Wasm.TypeRegistry;

type
  TWasmStore = class;
  TWasmModuleInstance = class;
  TWasmFunction = class;

  { A host function: Arguments has one value per parameter, Results one
    per result, already typed; the callback fills in the values. It may
    raise any exception to unwind the WebAssembly frames (EWasmTrap for
    a trap, EWasmException to throw a WebAssembly exception) and may call
    back into WebAssembly. }
  TWasmHostCallback = procedure(Func: TWasmFunction; const Arguments: TWasmValueArray;
    var Results: TWasmValueArray) of object;

  TWasmFunction = class
  public
    Store: TWasmStore;
    { Heap types in it are the store's type ids. }
    FunctionType: TWasmFunctionType;
    TypeId: Integer;
    ParamSlots: Integer;
    ResultSlots: Integer;
    { WebAssembly functions: the instance, the index in its module and
      the compiled code. }
    Instance: TWasmModuleInstance;
    FunctionIndex: Cardinal;
    Code: TCompiledFunction;
    { Host functions. }
    HostCallback: TWasmHostCallback;
    HostData: Pointer;
    function IsHost: Boolean; inline;
  end;

  { A tag (exception handling): identity matters, two tags of one type
    are different tags. The payload of its exceptions is a slot per
    parameter (two for a v128); TracedOffsets (TWasmGcDescriptor) are
    where references are, for the collector. }
  TWasmTag = class(TWasmGcDescriptor)
  public
    Store: TWasmStore;
    FunctionType: TWasmFunctionType;
    TypeId: Integer;
    PayloadSlots: Integer;
  end;

  TWasmMemory = class;
  { After a memory grows: OldData and OldLength are what the memory was
    (Data may have moved); an embedder detaches views of the old one. }
  TWasmMemoryGrowEvent = procedure(Memory: TWasmMemory; OldData: Pointer; OldLength: QWord) of object;

  TWasmMemory = class
  private
    FData: PByte;
    FByteLength: QWord;
    FMemoryType: TWasmMemoryType;
    FMaximumPages: QWord;
  public
    OnGrow: TWasmMemoryGrowEvent;
    { MaximumBytes caps what the memory may really take (0: 4 GiB). }
    constructor Create(const AMemoryType: TWasmMemoryType; MaximumBytes: QWord = 0);
    destructor Destroy; override;
    { Grows by Delta pages; the old size in pages, or -1 if it cannot. }
    function Grow(Delta: QWord): Int64;
    function PageCount: QWord; inline;
    function Is64: Boolean; inline;
    property Data: PByte read FData;
    property ByteLength: QWord read FByteLength;
    property MemoryType: TWasmMemoryType read FMemoryType;
  end;

  TWasmTable = class
  public
    Store: TWasmStore;
    { The element type's heap type is a store type id when concrete. }
    TableType: TWasmTableType;
    Elements: array of Pointer;
    constructor Create(const ATableType: TWasmTableType; InitialValue: Pointer);
    function Size: Cardinal; inline;
    function Is64: Boolean; inline;
    { Grows by Delta elements set to Value; the old size, or -1. }
    function Grow(Delta: QWord; Value: Pointer): Int64;
  end;

  TWasmGlobal = class
  public
    Store: TWasmStore;
    GlobalType: TWasmGlobalType;
    { The value's bits: scalars and references in the low eight bytes. }
    Value: TWasmV128;
    constructor Create(const AGlobalType: TWasmGlobalType);
    function GetValue: TWasmValue;
    procedure SetValue(const NewValue: TWasmValue);
  end;

  TWasmExternal = record
    Kind: TWasmExternalKind;
    Func: TWasmFunction;
    Table: TWasmTable;
    Memory: TWasmMemory;
    Global: TWasmGlobal;
    Tag: TWasmTag;
  end;
  TWasmExternalArray = array of TWasmExternal;

  TWasmModuleInstance = class
  public
    Store: TWasmStore;
    Module: TWasmModule;
    { The store's type id of each of the module's type indices. }
    TypeIds: array of Integer;
    RuntimeTypes: array of TWasmRuntimeType;
    Functions: array of TWasmFunction;
    Tables: array of TWasmTable;
    Memories: array of TWasmMemory;
    { Memory 0, or nil: what the interpreter keeps at hand. }
    DefaultMemory: TWasmMemory;
    Globals: array of TWasmGlobal;
    Tags: array of TWasmTag;
    { Element segments' references; a dropped segment is empty. }
    ElementSegments: array of array of Pointer;
    DataDropped: array of Boolean;
    function FindExport(const Name: AnsiString; out Found: TWasmExternal): Boolean;
    function ExternalFor(Kind: TWasmExternalKind; Index: Cardinal): TWasmExternal;
    { A module value type with its concrete heap type as a store id. }
    function RuntimeValueType(const ValueType: TWasmValueType): TWasmValueType;
  end;

  TWasmCallFrame = record
    Func: TWasmFunction;
    ResumeIndex: Integer;   { the instruction to continue at }
    Base: SizeInt;          { the frame's first slot }
  end;

  { Returns True to stop the running code (it traps with tkInterrupted). }
  TWasmInterruptHook = function(Store: TWasmStore): Boolean of object;
  { Called for every pointer of the embedder's an embedder's collector
    must keep (externrefs and host values in the any hierarchy). }
  TWasmReferenceVisitor = TWasmHostReferenceVisitor;

  { Zero for a size option means its default. }
  TWasmStoreOptions = record
    MaximumCallDepth: Integer;
    MaximumStackSlots: SizeInt;
    MaximumHostNesting: Integer;
    InterruptInterval: Integer;
    MaximumMemoryBytes: QWord;
    MaximumHeapBytes: QWord;
    CollectionThreshold: QWord;
  end;

  TWasmStore = class
  private
    FObjects: TFPList;
    FRegistry: TWasmTypeRegistry;
    FHeap: TWasmGcHeap;
    procedure Own(Item: TObject);
    function TraceOfRuntimeType(const ValueType: TWasmValueType): TWasmReferenceTrace;
    procedure MarkRoots(IncludeExposed: Boolean);
    procedure MarkFrames;
  public
    Options: TWasmStoreOptions;
    { The execution stack (see the unit's header). }
    Stack: array of QWord;
    StackTop: SizeInt;
    Frames: array of TWasmCallFrame;
    FrameCount: Integer;
    HostNesting: Integer;
    InterruptCountdown: Integer;
    OnInterrupt: TWasmInterruptHook;
    constructor Create;
    constructor Create(const AOptions: TWasmStoreOptions);
    destructor Destroy; override;
    class function DefaultOptions: TWasmStoreOptions; static;
    { The store type id of a function type (heap types already ids). }
    function CanonicalTypeId(const FunctionType: TWasmFunctionType): Integer;
    function TypeOfId(TypeId: Integer): TWasmFunctionType;
    function NewHostFunction(const FunctionType: TWasmFunctionType; Callback: TWasmHostCallback;
      Data: Pointer): TWasmFunction;
    function NewFunction(Instance: TWasmModuleInstance; FunctionIndex: Cardinal): TWasmFunction;
    function NewMemory(const MemoryType: TWasmMemoryType): TWasmMemory;
    function NewTable(const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
    function NewGlobal(const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;
    { TypeId: the store type id of the tag's type, or -1 to register
      FunctionType as a type of its own. }
    function NewTag(const FunctionType: TWasmFunctionType; TypeId: Integer = -1): TWasmTag;
    function NewModuleInstance(Module: TWasmModule): TWasmModuleInstance;
    { Makes room for Count more slots after StackTop (may move Stack). }
    procedure ReserveStack(Count: SizeInt);
    function PushFrame(Func: TWasmFunction; ResumeIndex: Integer; Base: SizeInt): Boolean; inline;
    { Calls the interrupt hook when the countdown runs out; True to stop. }
    function InterruptRequested: Boolean;
    { A full collection of the heap (every frame must be suspended at a
      safepoint). }
    procedure CollectGarbage;
    { Every pointer of the embedder's that anything of the store keeps
      alive: externrefs in tables, globals, element segments, suspended
      frames, and in the objects reachable from those, pinned and exposed
      objects (host values boxed into the any hierarchy included). }
    procedure EnumerateReferences(Visitor: TWasmReferenceVisitor);
    { Every host function's HostData. }
    procedure EnumerateHostData(Visitor: TWasmReferenceVisitor);
    { The embedder's tracing protocol (see Wasm.Api). }
    procedure BeginHostTrace(Visitor: TWasmReferenceVisitor);
    procedure TraceFromHost(Reference: Pointer; Visitor: TWasmReferenceVisitor);
    procedure EndHostTrace;
    property Registry: TWasmTypeRegistry read FRegistry;
    property Heap: TWasmGcHeap read FHeap;
  end;

implementation

uses
  Wasm.Errors,
  Wasm.Limits;

function TWasmFunction.IsHost: Boolean;
begin
  Result := Code = nil;
end;

{ TWasmMemory }

constructor TWasmMemory.Create(const AMemoryType: TWasmMemoryType; MaximumBytes: QWord);
var
  Cap: QWord;
begin
  inherited Create;
  FMemoryType := AMemoryType;
  if MaximumBytes = 0 then
    MaximumBytes := DefaultMaximumMemoryBytes;
  if AMemoryType.AddressType = vkI64 then
    Cap := MaximumMemory64Pages
  else
    Cap := MaximumMemoryPages;
  if MaximumBytes div WasmPageSize < Cap then
    Cap := MaximumBytes div WasmPageSize;
  if AMemoryType.Limits.HasMaximum and (AMemoryType.Limits.Maximum < Cap) then
    FMaximumPages := AMemoryType.Limits.Maximum
  else
    FMaximumPages := Cap;
  if AMemoryType.Limits.Minimum > FMaximumPages then
    raise EWasmResourceError.Create('could not allocate memory');
  FByteLength := AMemoryType.Limits.Minimum * WasmPageSize;
  if FByteLength > 0 then
  begin
    try
      FData := AllocMem(FByteLength);
    except
      on EOutOfMemory do
        FData := nil;
    end;
    if FData = nil then
      raise EWasmResourceError.Create('could not allocate memory');
  end;
end;

destructor TWasmMemory.Destroy;
begin
  if FData <> nil then
    FreeMem(FData);
  inherited Destroy;
end;

function TWasmMemory.PageCount: QWord;
begin
  Result := FByteLength div WasmPageSize;
end;

function TWasmMemory.Is64: Boolean;
begin
  Result := FMemoryType.AddressType = vkI64;
end;

function TWasmMemory.Grow(Delta: QWord): Int64;
var
  OldData: PByte;
  OldLength, NewLength: QWord;
  NewData: PByte;
begin
  Result := PageCount;
  if Delta > FMaximumPages - PageCount then
    Exit(-1);
  OldData := FData;
  OldLength := FByteLength;
  if Delta > 0 then
  begin
    NewLength := (PageCount + Delta) * WasmPageSize;
    {$IFDEF CPU32}
    if NewLength > High(SizeInt) then
      Exit(-1);
    {$ENDIF}
    NewData := nil;
    try
      NewData := AllocMem(NewLength);
    except
      on EOutOfMemory do
        NewData := nil;
    end;
    if NewData = nil then
      Exit(-1);
    if OldLength > 0 then
      Move(FData^, NewData^, OldLength);
    FData := NewData;
    FByteLength := NewLength;
    if Assigned(OnGrow) then
      OnGrow(Self, OldData, OldLength);
    if OldData <> nil then
      FreeMem(OldData);
  end
  else if Assigned(OnGrow) then
    OnGrow(Self, OldData, OldLength);
end;

{ TWasmTable }

constructor TWasmTable.Create(const ATableType: TWasmTableType; InitialValue: Pointer);
var
  Index: SizeInt;
begin
  inherited Create;
  TableType := ATableType;
  if ATableType.Limits.Minimum > MaximumTableElements then
    raise EWasmResourceError.Create('table too large');
  SetLength(Elements, ATableType.Limits.Minimum);
  for Index := 0 to High(Elements) do
    Elements[Index] := InitialValue;
end;

function TWasmTable.Size: Cardinal;
begin
  Result := Length(Elements);
end;

function TWasmTable.Is64: Boolean;
begin
  Result := TableType.AddressType = vkI64;
end;

function TWasmTable.Grow(Delta: QWord; Value: Pointer): Int64;
var
  OldSize, NewSize: QWord;
  Index: SizeInt;
begin
  OldSize := Length(Elements);
  if Delta > MaximumTableElements then
    Exit(-1);
  NewSize := OldSize + Delta;
  if TableType.Limits.HasMaximum and (NewSize > TableType.Limits.Maximum) then
    Exit(-1);
  if NewSize > MaximumTableElements then
    Exit(-1);
  try
    SetLength(Elements, NewSize);
  except
    on EOutOfMemory do
      Exit(-1);
  end;
  for Index := SizeInt(OldSize) to SizeInt(NewSize) - 1 do
    Elements[Index] := Value;
  Result := OldSize;
end;

{ TWasmGlobal }

constructor TWasmGlobal.Create(const AGlobalType: TWasmGlobalType);
begin
  inherited Create;
  GlobalType := AGlobalType;
  FillChar(Value, SizeOf(Value), 0);
end;

function TWasmGlobal.GetValue: TWasmValue;
begin
  Result.ValueType := GlobalType.ValueType;
  Result.V128 := Value;
end;

procedure TWasmGlobal.SetValue(const NewValue: TWasmValue);
begin
  Value := NewValue.V128;
  if GlobalType.ValueType.Kind in [vkI32, vkF32] then
    Value.DWords[1] := 0;
  if GlobalType.ValueType.Kind <> vkV128 then
    Value.QWords[1] := 0;
end;

{ TWasmModuleInstance }

function TWasmModuleInstance.ExternalFor(Kind: TWasmExternalKind; Index: Cardinal): TWasmExternal;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := Kind;
  case Kind of
    ekFunction: Result.Func := Functions[Index];
    ekTable: Result.Table := Tables[Index];
    ekMemory: Result.Memory := Memories[Index];
    ekGlobal: Result.Global := Globals[Index];
    ekTag: Result.Tag := Tags[Index];
  end;
end;

function TWasmModuleInstance.FindExport(const Name: AnsiString; out Found: TWasmExternal): Boolean;
var
  Entry: TWasmExport;
begin
  Result := Module.FindExport(Name, Entry);
  if Result then
    Found := ExternalFor(Entry.Kind, Entry.Index)
  else
    FillChar(Found, SizeOf(Found), 0);
end;

function TWasmModuleInstance.RuntimeValueType(const ValueType: TWasmValueType): TWasmValueType;
begin
  Result := ValueType;
  if (Result.Kind = vkReference) and (Result.HeapType >= 0) then
    Result.HeapType := TypeIds[Result.HeapType];
end;

{ TWasmStore }

constructor TWasmStore.Create;
begin
  Create(DefaultOptions);
end;

constructor TWasmStore.Create(const AOptions: TWasmStoreOptions);
begin
  inherited Create;
  Options := AOptions;
  if Options.MaximumMemoryBytes = 0 then
    Options.MaximumMemoryBytes := DefaultMaximumMemoryBytes;
  if Options.MaximumHeapBytes = 0 then
    Options.MaximumHeapBytes := DefaultMaximumHeapBytes;
  if Options.CollectionThreshold = 0 then
    Options.CollectionThreshold := DefaultCollectionThreshold;
  FObjects := TFPList.Create;
  FRegistry := TWasmTypeRegistry.Create;
  FHeap := TWasmGcHeap.Create(Options.MaximumHeapBytes, Options.CollectionThreshold);
  SetLength(Stack, DefaultInitialStackSlots);
  SetLength(Frames, 256);
  InterruptCountdown := Options.InterruptInterval;
end;

destructor TWasmStore.Destroy;
var
  Index: Integer;
begin
  for Index := FObjects.Count - 1 downto 0 do
  begin
    if TObject(FObjects[Index]) is TWasmModuleInstance then
      TWasmModuleInstance(FObjects[Index]).Module.Release;
    TObject(FObjects[Index]).Free;
  end;
  FObjects.Free;
  FHeap.Free;
  FRegistry.Free;
  inherited Destroy;
end;

class function TWasmStore.DefaultOptions: TWasmStoreOptions;
begin
  Result.MaximumCallDepth := DefaultMaximumCallDepth;
  Result.MaximumStackSlots := DefaultMaximumStackSlots;
  Result.MaximumHostNesting := DefaultMaximumHostNesting;
  Result.InterruptInterval := DefaultInterruptInterval;
  Result.MaximumMemoryBytes := DefaultMaximumMemoryBytes;
  Result.MaximumHeapBytes := DefaultMaximumHeapBytes;
  Result.CollectionThreshold := DefaultCollectionThreshold;
end;

procedure TWasmStore.Own(Item: TObject);
begin
  FObjects.Add(Item);
end;

function TWasmStore.CanonicalTypeId(const FunctionType: TWasmFunctionType): Integer;
begin
  Result := FRegistry.RegisterFunctionType(FunctionType);
end;

function TWasmStore.TypeOfId(TypeId: Integer): TWasmFunctionType;
begin
  Result := FRegistry.TypeOf(TypeId).Definition.FunctionType;
end;

function TWasmStore.NewHostFunction(const FunctionType: TWasmFunctionType; Callback: TWasmHostCallback;
  Data: Pointer): TWasmFunction;
begin
  Result := TWasmFunction.Create;
  Own(Result);
  Result.Store := Self;
  Result.FunctionType := FunctionType;
  Result.TypeId := CanonicalTypeId(FunctionType);
  Result.ParamSlots := SlotCountOf(FunctionType.Params);
  Result.ResultSlots := SlotCountOf(FunctionType.Results);
  Result.HostCallback := Callback;
  Result.HostData := Data;
end;

function TWasmStore.NewFunction(Instance: TWasmModuleInstance; FunctionIndex: Cardinal): TWasmFunction;
begin
  Result := TWasmFunction.Create;
  Own(Result);
  Result.Store := Self;
  Result.TypeId := Instance.TypeIds[Instance.Module.FunctionTypes[FunctionIndex]];
  Result.FunctionType := TypeOfId(Result.TypeId);
  Result.ParamSlots := SlotCountOf(Result.FunctionType.Params);
  Result.ResultSlots := SlotCountOf(Result.FunctionType.Results);
  Result.Instance := Instance;
  Result.FunctionIndex := FunctionIndex;
  Result.Code := TCompiledFunction(Instance.Module.Bodies[FunctionIndex - Instance.Module.ImportedFunctionCount].Compiled);
end;

function TWasmStore.NewMemory(const MemoryType: TWasmMemoryType): TWasmMemory;
begin
  Result := TWasmMemory.Create(MemoryType, Options.MaximumMemoryBytes);
  Own(Result);
end;

function TWasmStore.NewTable(const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
begin
  Result := TWasmTable.Create(TableType, InitialValue);
  Own(Result);
  Result.Store := Self;
end;

function TWasmStore.NewGlobal(const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;
begin
  Result := TWasmGlobal.Create(GlobalType);
  Own(Result);
  Result.Store := Self;
  Result.SetValue(Value);
end;

function TWasmStore.NewTag(const FunctionType: TWasmFunctionType; TypeId: Integer): TWasmTag;
var
  Index, Slot, Count: Integer;
  Trace: TWasmReferenceTrace;
begin
  Result := TWasmTag.Create;
  Own(Result);
  Result.Store := Self;
  Result.FunctionType := FunctionType;
  if TypeId >= 0 then
    Result.TypeId := TypeId
  else
    Result.TypeId := CanonicalTypeId(FunctionType);
  Result.PayloadSlots := SlotCountOf(FunctionType.Params);
  Slot := 0;
  Count := 0;
  for Index := 0 to High(FunctionType.Params) do
  begin
    Trace := TraceOfRuntimeType(FunctionType.Params[Index]);
    if Trace <> rtNone then
    begin
      SetLength(Result.TracedOffsets, Count + 1);
      Result.TracedOffsets[Count] := Slot * 8 * 2 + Ord(Trace = rtExternal);
      Inc(Count);
    end;
    Inc(Slot, SlotCount(FunctionType.Params[Index]));
  end;
end;

function TWasmStore.NewModuleInstance(Module: TWasmModule): TWasmModuleInstance;
begin
  Result := TWasmModuleInstance.Create;
  Own(Result);
  Result.Store := Self;
  Result.Module := Module;
  Module.Retain;
end;

procedure TWasmStore.ReserveStack(Count: SizeInt);
var
  Needed, NewLength: SizeInt;
begin
  Needed := StackTop + Count;
  if Needed <= Length(Stack) then
    Exit;
  if Needed > Options.MaximumStackSlots then
    raise EWasmTrap.CreateTrap(tkCallStackExhausted);
  NewLength := Length(Stack) * 2;
  while NewLength < Needed do
    NewLength := NewLength * 2;
  if NewLength > Options.MaximumStackSlots then
    NewLength := Options.MaximumStackSlots;
  SetLength(Stack, NewLength);
end;

function TWasmStore.PushFrame(Func: TWasmFunction; ResumeIndex: Integer; Base: SizeInt): Boolean;
begin
  if FrameCount >= Options.MaximumCallDepth then
    Exit(False);
  if FrameCount >= Length(Frames) then
    SetLength(Frames, Length(Frames) * 2);
  Frames[FrameCount].Func := Func;
  Frames[FrameCount].ResumeIndex := ResumeIndex;
  Frames[FrameCount].Base := Base;
  Inc(FrameCount);
  Result := True;
end;

function TWasmStore.InterruptRequested: Boolean;
begin
  InterruptCountdown := Options.InterruptInterval;
  Result := Assigned(OnInterrupt) and OnInterrupt(Self);
end;

function TWasmStore.TraceOfRuntimeType(const ValueType: TWasmValueType): TWasmReferenceTrace;
begin
  Result := ReferenceTrace(ValueType, (ValueType.Kind = vkReference) and (ValueType.HeapType >= 0) and
    (FRegistry.KindOf(ValueType.HeapType) = ckFunction));
end;

{ A suspended frame stopped at a call, a back edge or an allocation:
  the instruction before its resume index, whose safepoint lists the
  live reference slots (slot times two, plus one for an extern slot). }
procedure TWasmStore.MarkFrames;
var
  Frame, Item, First, Limit, Encoded: Integer;
  Code: TCompiledFunction;
begin
  for Frame := 0 to FrameCount - 1 do
  begin
    if (Frames[Frame].Func = nil) or (Frames[Frame].Func.Code = nil) then
      Continue;
    Code := Frames[Frame].Func.Code;
    if Code.FindSafepoint(Frames[Frame].ResumeIndex - 1, First, Limit) then
      for Item := First to Limit - 1 do
      begin
        Encoded := Code.SafepointSlots[Item];
        FHeap.MarkReference(Stack[Frames[Frame].Base + (Encoded shr 1)], Encoded and 1 <> 0);
      end;
  end;
end;

procedure TWasmStore.MarkRoots(IncludeExposed: Boolean);
var
  Index, Item, Element: Integer;
  Entry: TObject;
  Trace: TWasmReferenceTrace;
  Instance: TWasmModuleInstance;
begin
  for Index := 0 to FObjects.Count - 1 do
  begin
    Entry := TObject(FObjects[Index]);
    if Entry is TWasmTable then
    begin
      Trace := TraceOfRuntimeType(TWasmTable(Entry).TableType.ElementType);
      if Trace <> rtNone then
        with TWasmTable(Entry) do
          for Item := 0 to High(Elements) do
            FHeap.MarkReference(QWord(PtrUInt(Elements[Item])), Trace = rtExternal);
    end
    else if Entry is TWasmGlobal then
    begin
      Trace := TraceOfRuntimeType(TWasmGlobal(Entry).GlobalType.ValueType);
      if Trace <> rtNone then
        FHeap.MarkReference(TWasmGlobal(Entry).Value.QWords[0], Trace = rtExternal);
    end
    else if Entry is TWasmModuleInstance then
    begin
      Instance := TWasmModuleInstance(Entry);
      for Item := 0 to High(Instance.ElementSegments) do
      begin
        if Length(Instance.ElementSegments[Item]) = 0 then
          Continue;
        Trace := TraceOfRuntimeType(Instance.RuntimeValueType(Instance.Module.Elements[Item].ElementType));
        if Trace <> rtNone then
          for Element := 0 to High(Instance.ElementSegments[Item]) do
            FHeap.MarkReference(QWord(PtrUInt(Instance.ElementSegments[Item][Element])), Trace = rtExternal);
      end;
    end;
  end;
  MarkFrames;
  FHeap.MarkPinned;
  if IncludeExposed then
    FHeap.MarkExposed;
end;

procedure TWasmStore.CollectGarbage;
begin
  FHeap.BeginMark(nil);
  MarkRoots(True);
  FHeap.DrainMarks;
  FHeap.Sweep;
end;

procedure TWasmStore.EnumerateReferences(Visitor: TWasmReferenceVisitor);
begin
  FHeap.BeginMark(Visitor);
  MarkRoots(True);
  FHeap.DrainMarks;
  FHeap.BeginMark(nil);
end;

procedure TWasmStore.EnumerateHostData(Visitor: TWasmReferenceVisitor);
var
  Index: Integer;
begin
  for Index := 0 to FObjects.Count - 1 do
    if (TObject(FObjects[Index]) is TWasmFunction) and TWasmFunction(FObjects[Index]).IsHost and
      (TWasmFunction(FObjects[Index]).HostData <> nil) then
      Visitor(TWasmFunction(FObjects[Index]).HostData);
end;

procedure TWasmStore.BeginHostTrace(Visitor: TWasmReferenceVisitor);
begin
  FHeap.BeginMark(Visitor);
  MarkRoots(False);
  FHeap.DrainMarks;
end;

procedure TWasmStore.TraceFromHost(Reference: Pointer; Visitor: TWasmReferenceVisitor);
begin
  FHeap.ContinueMark(Visitor);
  FHeap.MarkReference(QWord(PtrUInt(Reference)), False);
  FHeap.DrainMarks;
end;

procedure TWasmStore.EndHostTrace;
begin
  FHeap.PruneExposed;
  FHeap.Sweep;
end;

end.
