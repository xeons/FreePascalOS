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
  The store (spec section 4.2): function, table, memory and global
  instances, module instances, and the execution stack.

  A store belongs to one thread of execution (one JS agent); nothing in
  the engine is shared between stores, and the store owns every instance
  made in it until it is destroyed (instances live as long as anything
  could still reach them, which without a collector of our own is the
  store's lifetime).

  Function types are made canonical per store: equal types get the same
  TypeId, so call_indirect's check and import matching compare numbers.

  The execution stack is one array of 64-bit slots shared by all frames
  (Wasm.Code), with a record of the suspended frames beside it; it
  grows on demand up to Options.MaximumStackSlots, and the call depth is
  limited by Options.MaximumCallDepth. Exceeding either traps with "call
  stack exhausted" instead of running the host thread out of stack, as
  does nesting host calls into WebAssembly too deeply.
}
unit Wasm.Runtime;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Wasm.Types,
  Wasm.Module,
  Wasm.Code;

type
  TWasmStore = class;
  TWasmModuleInstance = class;
  TWasmFunction = class;

  { A host function: Arguments has one value per parameter, Results one
    per result, already typed; the callback fills in the values. It may
    raise any exception to unwind the WebAssembly frames (EWasmTrap for
    a trap) and may call back into WebAssembly. }
  TWasmHostCallback = procedure(Func: TWasmFunction; const Arguments: TWasmValueArray;
    var Results: TWasmValueArray) of object;

  TWasmFunction = class
  public
    Store: TWasmStore;
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
    constructor Create(const AMemoryType: TWasmMemoryType);
    destructor Destroy; override;
    { Grows by Delta pages; the old size in pages, or -1 if it cannot. }
    function Grow(Delta: QWord): Int64;
    function PageCount: QWord; inline;
    property Data: PByte read FData;
    property ByteLength: QWord read FByteLength;
    property MemoryType: TWasmMemoryType read FMemoryType;
  end;

  TWasmTable = class
  public
    TableType: TWasmTableType;
    Elements: array of Pointer;
    constructor Create(const ATableType: TWasmTableType; InitialValue: Pointer);
    function Size: Cardinal; inline;
    { Grows by Delta elements set to Value; the old size, or -1. }
    function Grow(Delta: Cardinal; Value: Pointer): Int64;
  end;

  TWasmGlobal = class
  public
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
  end;
  TWasmExternalArray = array of TWasmExternal;

  TWasmModuleInstance = class
  public
    Store: TWasmStore;
    Module: TWasmModule;
    TypeIds: array of Integer;
    Functions: array of TWasmFunction;
    Tables: array of TWasmTable;
    Memories: array of TWasmMemory;
    Globals: array of TWasmGlobal;
    { Element segments' references; a dropped segment is empty. }
    ElementSegments: array of array of Pointer;
    DataDropped: array of Boolean;
    function FindExport(const Name: AnsiString; out Found: TWasmExternal): Boolean;
    function ExternalFor(Kind: TWasmExternalKind; Index: Cardinal): TWasmExternal;
  end;

  TWasmCallFrame = record
    Func: TWasmFunction;
    ResumeIndex: Integer;   { the instruction to continue at }
    Base: SizeInt;          { the frame's first slot }
  end;

  { Returns True to stop the running code (it traps with tkInterrupted). }
  TWasmInterruptHook = function(Store: TWasmStore): Boolean of object;
  { Called once for every externref an embedder's collector must keep. }
  TWasmReferenceVisitor = procedure(Reference: Pointer) of object;

  TWasmStoreOptions = record
    MaximumCallDepth: Integer;
    MaximumStackSlots: SizeInt;
    MaximumHostNesting: Integer;
    InterruptInterval: Integer;
  end;

  TWasmStore = class
  private
    FObjects: TFPList;
    FTypeKeys: TStringList;
    FTypes: array of TWasmFunctionType;
    procedure Own(Item: TObject);
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
    function CanonicalTypeId(const FunctionType: TWasmFunctionType): Integer;
    function TypeOfId(TypeId: Integer): TWasmFunctionType;
    function NewHostFunction(const FunctionType: TWasmFunctionType; Callback: TWasmHostCallback;
      Data: Pointer): TWasmFunction;
    function NewFunction(Instance: TWasmModuleInstance; FunctionIndex: Cardinal): TWasmFunction;
    function NewMemory(const MemoryType: TWasmMemoryType): TWasmMemory;
    function NewTable(const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
    function NewGlobal(const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;
    function NewInstance(Module: TWasmModule): TWasmModuleInstance;
    { Makes room for Count more slots after StackTop (may move Stack). }
    procedure ReserveStack(Count: SizeInt);
    function PushFrame(Func: TWasmFunction; ResumeIndex: Integer; Base: SizeInt): Boolean; inline;
    { Calls the interrupt hook when the countdown runs out; True to stop. }
    function InterruptRequested: Boolean;
    { Every externref held by a table, a global, an element segment or a
      suspended frame of this store. }
    procedure EnumerateReferences(Visitor: TWasmReferenceVisitor);
    { Every host function's HostData. }
    procedure EnumerateHostData(Visitor: TWasmReferenceVisitor);
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

constructor TWasmMemory.Create(const AMemoryType: TWasmMemoryType);
begin
  inherited Create;
  FMemoryType := AMemoryType;
  if AMemoryType.Limits.HasMaximum then
    FMaximumPages := AMemoryType.Limits.Maximum
  else
    FMaximumPages := MaximumMemoryPages;
  if FMaximumPages > MaximumMemoryPages then
    FMaximumPages := MaximumMemoryPages;
  FByteLength := AMemoryType.Limits.Minimum * WasmPageSize;
  if FByteLength > 0 then
  begin
    FData := AllocMem(FByteLength);
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

function TWasmTable.Grow(Delta: Cardinal; Value: Pointer): Int64;
var
  OldSize, NewSize: QWord;
  Index: SizeInt;
begin
  OldSize := Length(Elements);
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
  for Index := OldSize to NewSize - 1 do
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

{ TWasmStore }

constructor TWasmStore.Create;
begin
  Create(DefaultOptions);
end;

constructor TWasmStore.Create(const AOptions: TWasmStoreOptions);
begin
  inherited Create;
  Options := AOptions;
  FObjects := TFPList.Create;
  FTypeKeys := TStringList.Create;
  FTypeKeys.Sorted := True;
  FTypeKeys.CaseSensitive := True;
  SetLength(Stack, DefaultInitialStackSlots);
  SetLength(Frames, 256);
  InterruptCountdown := Options.InterruptInterval;
end;

destructor TWasmStore.Destroy;
var
  Index: Integer;
begin
  for Index := FObjects.Count - 1 downto 0 do
    TObject(FObjects[Index]).Free;
  FObjects.Free;
  FTypeKeys.Free;
  inherited Destroy;
end;

class function TWasmStore.DefaultOptions: TWasmStoreOptions;
begin
  Result.MaximumCallDepth := DefaultMaximumCallDepth;
  Result.MaximumStackSlots := DefaultMaximumStackSlots;
  Result.MaximumHostNesting := DefaultMaximumHostNesting;
  Result.InterruptInterval := DefaultInterruptInterval;
end;

procedure TWasmStore.Own(Item: TObject);
begin
  FObjects.Add(Item);
end;

function TypeKey(const FunctionType: TWasmFunctionType): AnsiString;
var
  Index: Integer;

  function TypeCode(const ValueType: TWasmValueType): AnsiString;
  begin
    Result := IntToStr(Ord(ValueType.Kind));
    if ValueType.Kind = vkReference then
      Result := Result + ':' + IntToStr(Ord(ValueType.Nullable)) + ':' + IntToStr(ValueType.HeapType);
    Result := Result + ',';
  end;

begin
  Result := '';
  for Index := 0 to High(FunctionType.Params) do
    Result := Result + TypeCode(FunctionType.Params[Index]);
  Result := Result + '>';
  for Index := 0 to High(FunctionType.Results) do
    Result := Result + TypeCode(FunctionType.Results[Index]);
end;

function TWasmStore.CanonicalTypeId(const FunctionType: TWasmFunctionType): Integer;
var
  Key: AnsiString;
  Position: Integer;
begin
  Key := TypeKey(FunctionType);
  if FTypeKeys.Find(Key, Position) then
    Exit(PtrInt(FTypeKeys.Objects[Position]));
  Result := Length(FTypes);
  SetLength(FTypes, Result + 1);
  FTypes[Result] := FunctionType;
  FTypeKeys.AddObject(Key, TObject(PtrInt(Result)));
end;

function TWasmStore.TypeOfId(TypeId: Integer): TWasmFunctionType;
begin
  Result := FTypes[TypeId];
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
  Result.FunctionType := Instance.Module.FunctionType(FunctionIndex);
  Result.TypeId := CanonicalTypeId(Result.FunctionType);
  Result.ParamSlots := SlotCountOf(Result.FunctionType.Params);
  Result.ResultSlots := SlotCountOf(Result.FunctionType.Results);
  Result.Instance := Instance;
  Result.FunctionIndex := FunctionIndex;
  Result.Code := TCompiledFunction(Instance.Module.Bodies[FunctionIndex - Instance.Module.ImportedFunctionCount].Compiled);
end;

function TWasmStore.NewMemory(const MemoryType: TWasmMemoryType): TWasmMemory;
begin
  Result := TWasmMemory.Create(MemoryType);
  Own(Result);
end;

function TWasmStore.NewTable(const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
begin
  Result := TWasmTable.Create(TableType, InitialValue);
  Own(Result);
end;

function TWasmStore.NewGlobal(const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;
begin
  Result := TWasmGlobal.Create(GlobalType);
  Own(Result);
  Result.SetValue(Value);
end;

function TWasmStore.NewInstance(Module: TWasmModule): TWasmModuleInstance;
begin
  Result := TWasmModuleInstance.Create;
  Own(Result);
  Result.Store := Self;
  Result.Module := Module;
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

procedure TWasmStore.EnumerateReferences(Visitor: TWasmReferenceVisitor);
var
  Index, Item, Frame, First, Limit: Integer;
  Item_: TObject;
  Code: TCompiledFunction;
begin
  for Index := 0 to FObjects.Count - 1 do
  begin
    Item_ := TObject(FObjects[Index]);
    if Item_ is TWasmTable then
    begin
      with TWasmTable(Item_) do
        if TableType.ElementType.HeapType = HeapTypeExtern then
          for Item := 0 to High(Elements) do
            if Elements[Item] <> nil then
              Visitor(Elements[Item]);
    end
    else if Item_ is TWasmGlobal then
    begin
      with TWasmGlobal(Item_) do
        if (GlobalType.ValueType.Kind = vkReference) and (GlobalType.ValueType.HeapType = HeapTypeExtern) and
          (Value.QWords[0] <> 0) then
          Visitor(Pointer(PtrUInt(Value.QWords[0])));
    end
    else if Item_ is TWasmModuleInstance then
    begin
      with TWasmModuleInstance(Item_) do
        for Item := 0 to High(ElementSegments) do
          if Module.Elements[Item].ElementType.HeapType = HeapTypeExtern then
            for Frame := 0 to High(ElementSegments[Item]) do
              if ElementSegments[Item][Frame] <> nil then
                Visitor(ElementSegments[Item][Frame]);
    end;
  end;
  { A suspended frame stopped at a call or a back edge: the instruction
    before its resume index, whose safepoint lists the live slots. }
  for Frame := 0 to FrameCount - 1 do
  begin
    if (Frames[Frame].Func = nil) or (Frames[Frame].Func.Code = nil) then
      Continue;
    Code := Frames[Frame].Func.Code;
    if Code.FindSafepoint(Frames[Frame].ResumeIndex - 1, First, Limit) then
      for Item := First to Limit - 1 do
        if Stack[Frames[Frame].Base + Code.SafepointSlots[Item]] <> 0 then
          Visitor(Pointer(PtrUInt(Stack[Frames[Frame].Base + Code.SafepointSlots[Item]])));
  end;
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

end.
