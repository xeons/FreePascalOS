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
  The engine's interface for embedders (the JavaScript WebAssembly
  object is built on it). Everything else is reachable too, but this is
  the part meant to stay stable.

  Modules
    WasmCompile(Bytes) decodes, validates and compiles: a TWasmModule
    (Wasm.Module), or EWasmMalformed / EWasmInvalid with the reason.
    WasmValidate says yes or no. A module is reference counted: the
    caller owns the reference WasmCompile returns and gives it back with
    Module.Release; instances keep their own. WasmModuleImports and
    WasmModuleExports describe it (kind and type of each), and
    WasmCustomSections gives the contents of custom sections by name.

  Instances
    A TWasmStore (Wasm.Runtime) holds everything made at run time; use
    one per agent (thread). WasmInstantiate takes one external value per
    import, in order; WasmInstantiateWith asks a resolver for each.
    Exports are found with Instance.FindExport, or listed with
    WasmInstanceExports.

  Calls and values
    WasmCall(Func, Arguments) runs a function with TWasmValue arguments
    (Wasm.Types) and returns its results; a trap is EWasmTrap with Kind,
    message and StackTrace. Host functions come from
    WasmNewHostFunction: a method that gets typed arguments and fills in
    typed results, and may raise to unwind (EWasmTrap to trap).

  References
    funcref values are TWasmFunction objects. externref values are
    pointers the embedder owns, nil being null; the engine never looks
    at them. Store.EnumerateReferences visits every externref the store
    holds (tables, globals, element segments, the slots of suspended
    frames), for a tracing collector to mark; EnumerateHostData visits
    host functions' data pointers.

  Memories, tables, globals
    TWasmMemory: Data and ByteLength, Grow(Pages); OnGrow tells the
    embedder after every successful grow (an ArrayBuffer over the old
    memory must be detached; Data may have moved). Tables and globals
    through the functions below, which check bounds, types and
    mutability (raising EWasmError) the way the JS API needs.

  Long running code
    Store.OnInterrupt is called every Store.Options.InterruptInterval
    back edges and calls; returning True stops the code with a trap of
    kind tkInterrupted (a watchdog's way to end a runaway module).

  Features
    WasmCompile and WasmValidate take an optional feature set
    (Wasm.Features): all of 3.0 and legacy exceptions by default.

  Tags and exceptions (WebAssembly.Tag, WebAssembly.Exception)
    WasmNewTag makes a tag of a function type without results; tags are
    imported and exported as ekTag (TWasmExternal.Tag). An exception is
    an exnref: WasmNewException makes one, WasmExceptionTag and
    WasmExceptionPayload read it. A WebAssembly exception that leaves
    WebAssembly (WasmCall, WasmInstantiate's start function) raises
    EWasmException (Wasm.Exceptions) with Tag, Payload and Reference;
    a host function raises EWasmException (WasmThrow, or by letting one
    through) to throw into its caller, where try_table, catch and
    catch_all see it. A JavaScript exception crossing into WebAssembly is
    thrown with the embedder's own tag (WebAssembly.JSTag: a tag with an
    externref parameter). Traps (EWasmTrap) are never caught by
    WebAssembly code.

  References of the garbage collected kinds
    A reference value is a pointer-sized word: nil is null, an odd word
    an i31 (WasmMakeI31, WasmI31Value), otherwise a struct, an array or an
    exception of the store's heap, a TWasmFunction (func hierarchy), or in
    the extern hierarchy a pointer the embedder owns; WasmClassifyReference
    tells which. Embedder pointers given as externref must be even (they
    are aligned) since odd words are i31s once internalized. A host value
    entering the any hierarchy (WasmInternalize, any.convert_extern) is
    boxed; WasmExternalize unboxes it again, so values round-trip.
    WasmValueMatchesType checks a value against a (store) value type the
    way ToWebAssemblyValue must; WasmStruct... and WasmArray... read and
    write fields and elements.

  Collection and the embedder's collector
    Objects live while the store reaches them (globals, tables, element
    segments, the frames of running code), while pinned (WasmPin /
    WasmUnpin, counted) and while exposed: every object handed to the
    embedder (results, host function arguments, values read through this
    interface, exception payloads) stays alive until the embedder's next
    trace says it no longer holds it. An embedder without a tracing
    collector pins what it keeps and calls WasmForgetExposed now and then.
    One with a tracing collector (the JavaScript engine) either
      a) at each of its collections calls Store.EnumerateReferences and
         keeps every pointer it is given (simple; a cycle through both
         heaps lives until the store goes), or
      b) traces through both heaps: Store.BeginHostTrace(Visitor) marks
         what the store's own roots reach and gives the embedder pointers
         it finds to Visitor; for every wasm reference the embedder's
         marking reaches (a wrapper object holding it) it calls
         Store.TraceFromHost(Reference, Visitor), which marks on and gives
         more pointers; when its marking is complete, Store.EndHostTrace
         forgets exposed objects not reached and frees every unmarked
         object. No WebAssembly code may run between Begin and End.
    The store collects by itself when enough was allocated since the last
    collection (Options.CollectionThreshold), at safepoints only.
}
unit Wasm.Api;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Types,
  Wasm.Features,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.TypeRegistry,
  Wasm.Exceptions;

type
  TWasmIdArray = Wasm.TypeRegistry.TWasmIdArray;

  TWasmImportDescriptor = record
    ModuleName: AnsiString;
    Name: AnsiString;
    Kind: TWasmExternalKind;
    FunctionType: TWasmFunctionType;
    TableType: TWasmTableType;
    MemoryType: TWasmMemoryType;
    GlobalType: TWasmGlobalType;
    TagType: TWasmFunctionType;
  end;
  TWasmImportDescriptorArray = array of TWasmImportDescriptor;

  TWasmExportDescriptor = record
    Name: AnsiString;
    Kind: TWasmExternalKind;
    FunctionType: TWasmFunctionType;
    TableType: TWasmTableType;
    MemoryType: TWasmMemoryType;
    GlobalType: TWasmGlobalType;
    TagType: TWasmFunctionType;
  end;
  TWasmExportDescriptorArray = array of TWasmExportDescriptor;

  TWasmReferenceKind = (rkNull, rkI31, rkStruct, rkArray, rkException, rkBoxedHostValue, rkFunction, rkHostValue);

  EWasmException = Wasm.Exceptions.EWasmException;

  TWasmNamedExternal = record
    Name: AnsiString;
    External: TWasmExternal;
  end;
  TWasmNamedExternalArray = array of TWasmNamedExternal;

  TBytesArray = array of TBytes;

  { Finds the external value for an import; False if there is none. }
  TWasmImportResolver = function(const Import: TWasmImportDescriptor; out External: TWasmExternal): Boolean of object;

function WasmCompile(const Bytes: TBytes): TWasmModule;
function WasmCompile(const Bytes: TBytes; Features: TWasmFeatures): TWasmModule;
function WasmValidate(const Bytes: TBytes): Boolean;
function WasmValidate(const Bytes: TBytes; Features: TWasmFeatures): Boolean;
function WasmModuleImports(Module: TWasmModule): TWasmImportDescriptorArray;
function WasmModuleExports(Module: TWasmModule): TWasmExportDescriptorArray;
function WasmCustomSections(Module: TWasmModule; const Name: AnsiString): TBytesArray;

function WasmInstantiate(Store: TWasmStore; Module: TWasmModule; const Imports: TWasmExternalArray): TWasmModuleInstance;
function WasmInstantiateWith(Store: TWasmStore; Module: TWasmModule; Resolver: TWasmImportResolver): TWasmModuleInstance;
function WasmInstanceExports(Instance: TWasmModuleInstance): TWasmNamedExternalArray;

function WasmCall(Func: TWasmFunction; const Arguments: TWasmValueArray): TWasmValueArray;
function WasmNewHostFunction(Store: TWasmStore; const FunctionType: TWasmFunctionType;
  Callback: TWasmHostCallback; Data: Pointer = nil): TWasmFunction;
{ A host function of a module's type: TypeId is the store's id of it
  (Store.Registry.RegisterModule's ids), FunctionType that type. }
function WasmNewHostFunctionOfType(Store: TWasmStore; TypeId: Integer; Callback: TWasmHostCallback;
  Data: Pointer = nil): TWasmFunction;
{ The store type ids of a module's types (what an instance would use). }
function WasmModuleTypeIds(Store: TWasmStore; Module: TWasmModule): TWasmIdArray;
{ A module value type with its concrete heap type as a store id. }
function WasmStoreValueType(const TypeIds: TWasmIdArray; const ValueType: TWasmValueType): TWasmValueType;

function WasmNewMemory(Store: TWasmStore; const MemoryType: TWasmMemoryType): TWasmMemory;
function WasmNewTable(Store: TWasmStore; const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
function WasmNewGlobal(Store: TWasmStore; const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;

function WasmGlobalGet(Global: TWasmGlobal): TWasmValue;
procedure WasmGlobalSet(Global: TWasmGlobal; const Value: TWasmValue);
function WasmTableGet(Table: TWasmTable; Index: Cardinal): Pointer;
procedure WasmTableSet(Table: TWasmTable; Index: Cardinal; Value: Pointer);
{ The old size, or -1 if the table cannot grow by Delta. }
function WasmTableGrow(Table: TWasmTable; Delta: Cardinal; Value: Pointer): Int64;
{ The old size in pages, or -1. }
function WasmMemoryGrow(Memory: TWasmMemory; DeltaPages: QWord): Int64;

function MakeFunctionType(const Params, Results: array of TWasmValueType): TWasmFunctionType;

{ Tags and exceptions. }
function WasmNewTag(Store: TWasmStore; const FunctionType: TWasmFunctionType): TWasmTag;
function WasmTagType(Tag: TWasmTag): TWasmFunctionType;
function WasmNewException(Store: TWasmStore; Tag: TWasmTag; const Payload: TWasmValueArray): Pointer;
function WasmExceptionTag(Exception: Pointer): TWasmTag;
function WasmExceptionPayload(Exception: Pointer): TWasmValueArray;
{ Raises EWasmException: from a host function, throws into WebAssembly. }
procedure WasmThrow(Store: TWasmStore; Tag: TWasmTag; const Payload: TWasmValueArray);
procedure WasmThrowException(Store: TWasmStore; Exception: Pointer);

{ References. ValueType tells the hierarchy (a store value type). }
function WasmClassifyReference(Store: TWasmStore; Reference: Pointer; const ValueType: TWasmValueType): TWasmReferenceKind;
function WasmMakeI31(Value: Int32): Pointer;
function WasmI31Value(Reference: Pointer; Signed: Boolean = True): Int32;
function WasmInternalize(Store: TWasmStore; Reference: Pointer): Pointer;
function WasmExternalize(Store: TWasmStore; Reference: Pointer): Pointer;
function WasmValueMatchesType(Store: TWasmStore; const Value: TWasmValue; const ValueType: TWasmValueType): Boolean;
function WasmStructFieldCount(Reference: Pointer): Integer;
function WasmStructGetField(Store: TWasmStore; Reference: Pointer; Field: Integer): TWasmValue;
procedure WasmStructSetField(Store: TWasmStore; Reference: Pointer; Field: Integer; const Value: TWasmValue);
function WasmArrayLength(Reference: Pointer): Cardinal;
function WasmArrayGetElement(Store: TWasmStore; Reference: Pointer; Index: Cardinal): TWasmValue;
procedure WasmArraySetElement(Store: TWasmStore; Reference: Pointer; Index: Cardinal; const Value: TWasmValue);

{ Collection. }
procedure WasmCollectGarbage(Store: TWasmStore);
procedure WasmPin(Store: TWasmStore; Reference: Pointer);
procedure WasmUnpin(Store: TWasmStore; Reference: Pointer);
procedure WasmForgetExposed(Store: TWasmStore);

implementation

uses
  Math,
  Wasm.TypeDefinitions,
  Wasm.Subtyping,
  Wasm.GcHeap,
  Wasm.GcOperations,
  Wasm.Code,
  Wasm.Decoder,
  Wasm.Validator,
  Wasm.Compiler,
  Wasm.Instantiation,
  Wasm.Interpreter;

function WasmCompile(const Bytes: TBytes): TWasmModule;
begin
  Result := WasmCompile(Bytes, WasmFeaturesAll);
end;

function WasmValidate(const Bytes: TBytes): Boolean;
begin
  Result := WasmValidate(Bytes, WasmFeaturesAll);
end;

function WasmCompile(const Bytes: TBytes; Features: TWasmFeatures): TWasmModule;
begin
  Result := DecodeModule(Bytes, Features);
  try
    ValidateModule(Result);
    CompileModule(Result);
  except
    Result.Release;
    raise;
  end;
end;

function WasmValidate(const Bytes: TBytes; Features: TWasmFeatures): Boolean;
var
  Module: TWasmModule;
begin
  try
    Module := DecodeModule(Bytes, Features);
    try
      ValidateModule(Module);
    finally
      Module.Release;
    end;
    Result := True;
  except
    on EWasmError do
      Result := False;
  end;
end;

function WasmModuleImports(Module: TWasmModule): TWasmImportDescriptorArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Module.Imports));
  for Index := 0 to High(Module.Imports) do
    with Module.Imports[Index] do
    begin
      Result[Index].ModuleName := ModuleName;
      Result[Index].Name := FieldName;
      Result[Index].Kind := Kind;
      if Kind = ekFunction then
        Result[Index].FunctionType := Module.Types[TypeIndex];
      if Kind = ekTag then
        Result[Index].TagType := Module.Types[TagTypeIndex];
      Result[Index].TableType := TableType;
      Result[Index].MemoryType := MemoryType;
      Result[Index].GlobalType := GlobalType;
    end;
end;

function WasmModuleExports(Module: TWasmModule): TWasmExportDescriptorArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Module.ExportList));
  for Index := 0 to High(Module.ExportList) do
  begin
    Result[Index].Name := Module.ExportList[Index].Name;
    Result[Index].Kind := Module.ExportList[Index].Kind;
    case Module.ExportList[Index].Kind of
      ekFunction: Result[Index].FunctionType := Module.FunctionType(Module.ExportList[Index].Index);
      ekTable: Result[Index].TableType := Module.Tables[Module.ExportList[Index].Index];
      ekMemory: Result[Index].MemoryType := Module.Memories[Module.ExportList[Index].Index];
      ekGlobal: Result[Index].GlobalType := Module.Globals[Module.ExportList[Index].Index];
      ekTag: Result[Index].TagType := Module.TagType(Module.ExportList[Index].Index);
    end;
  end;
end;

function WasmCustomSections(Module: TWasmModule; const Name: AnsiString): TBytesArray;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to High(Module.CustomSections) do
    if Module.CustomSections[Index].Name = Name then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Module.Bytes, Module.CustomSections[Index].DataStart,
        Module.CustomSections[Index].DataLength);
    end;
end;

function WasmInstantiate(Store: TWasmStore; Module: TWasmModule; const Imports: TWasmExternalArray): TWasmModuleInstance;
var
  SavedMask: TFPUExceptionMask;
begin
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Result := InstantiateModule(Store, Module, Imports);
  finally
    SetExceptionMask(SavedMask);
  end;
end;

function WasmInstantiateWith(Store: TWasmStore; Module: TWasmModule; Resolver: TWasmImportResolver): TWasmModuleInstance;
var
  Descriptors: TWasmImportDescriptorArray;
  Imports: TWasmExternalArray;
  Index: Integer;
begin
  Descriptors := WasmModuleImports(Module);
  SetLength(Imports, Length(Descriptors));
  for Index := 0 to High(Descriptors) do
    if not Resolver(Descriptors[Index], Imports[Index]) then
      raise EWasmLinkError.CreateFmt('unknown import %s.%s', [Descriptors[Index].ModuleName, Descriptors[Index].Name]);
  Result := WasmInstantiate(Store, Module, Imports);
end;

function WasmInstanceExports(Instance: TWasmModuleInstance): TWasmNamedExternalArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Instance.Module.ExportList));
  for Index := 0 to High(Result) do
  begin
    Result[Index].Name := Instance.Module.ExportList[Index].Name;
    Result[Index].External := Instance.ExternalFor(Instance.Module.ExportList[Index].Kind,
      Instance.Module.ExportList[Index].Index);
  end;
end;

function WasmCall(Func: TWasmFunction; const Arguments: TWasmValueArray): TWasmValueArray;
begin
  Result := Invoke(Func, Arguments);
end;

function WasmNewHostFunction(Store: TWasmStore; const FunctionType: TWasmFunctionType;
  Callback: TWasmHostCallback; Data: Pointer): TWasmFunction;
begin
  Result := Store.NewHostFunction(FunctionType, Callback, Data);
end;

function WasmNewHostFunctionOfType(Store: TWasmStore; TypeId: Integer; Callback: TWasmHostCallback;
  Data: Pointer): TWasmFunction;
begin
  Result := Store.NewHostFunction(Store.TypeOfId(TypeId), Callback, Data, TypeId);
end;

function WasmModuleTypeIds(Store: TWasmStore; Module: TWasmModule): TWasmIdArray;
begin
  Result := Store.Registry.RegisterModule(Module);
end;

function WasmStoreValueType(const TypeIds: TWasmIdArray; const ValueType: TWasmValueType): TWasmValueType;
begin
  Result := ValueType;
  if (Result.Kind = vkReference) and (Result.HeapType >= 0) then
    Result.HeapType := TypeIds[Result.HeapType];
end;

function WasmNewMemory(Store: TWasmStore; const MemoryType: TWasmMemoryType): TWasmMemory;
begin
  if not (MemoryType.AddressType in [vkI32, vkI64]) then
    raise EWasmError.Create('memory address type must be i32 or i64');
  Result := Store.NewMemory(MemoryType);
end;

function WasmNewTable(Store: TWasmStore; const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
begin
  if not (TableType.AddressType in [vkI32, vkI64]) then
    raise EWasmError.Create('table address type must be i32 or i64');
  Result := Store.NewTable(TableType, InitialValue);
end;

function WasmNewGlobal(Store: TWasmStore; const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;
begin
  if not WasmValueMatchesType(Store, Value, GlobalType.ValueType) then
    raise EWasmError.Create('global value of the wrong type');
  Result := Store.NewGlobal(GlobalType, Value);
end;

function WasmGlobalGet(Global: TWasmGlobal): TWasmValue;
begin
  Result := Global.GetValue;
end;

procedure WasmGlobalSet(Global: TWasmGlobal; const Value: TWasmValue);
begin
  if not Global.GlobalType.Mutable then
    raise EWasmError.Create('global is immutable');
  if not WasmValueMatchesType(Global.Store, Value, Global.GlobalType.ValueType) then
    raise EWasmError.Create('global value of the wrong type');
  Global.SetValue(Value);
end;

function WasmTableGet(Table: TWasmTable; Index: Cardinal): Pointer;
begin
  if Index >= Table.Size then
    raise EWasmTrap.CreateTrap(tkTableOutOfBounds);
  Result := Table.Elements[Index];
end;

procedure WasmTableSet(Table: TWasmTable; Index: Cardinal; Value: Pointer);
begin
  if Index >= Table.Size then
    raise EWasmTrap.CreateTrap(tkTableOutOfBounds);
  if not WasmValueMatchesType(Table.Store, WasmReference(Table.TableType.ElementType, Value),
    Table.TableType.ElementType) then
    raise EWasmError.Create('table value of the wrong type');
  Table.Elements[Index] := Value;
end;

function WasmTableGrow(Table: TWasmTable; Delta: Cardinal; Value: Pointer): Int64;
begin
  if not WasmValueMatchesType(Table.Store, WasmReference(Table.TableType.ElementType, Value),
    Table.TableType.ElementType) then
    raise EWasmError.Create('table value of the wrong type');
  Result := Table.Grow(Delta, Value);
end;

function WasmMemoryGrow(Memory: TWasmMemory; DeltaPages: QWord): Int64;
begin
  Result := Memory.Grow(DeltaPages);
end;

function MakeFunctionType(const Params, Results: array of TWasmValueType): TWasmFunctionType;
var
  Index: Integer;
begin
  Result := Default(TWasmFunctionType);
  SetLength(Result.Params, Length(Params));
  for Index := 0 to High(Params) do
    Result.Params[Index] := Params[Index];
  SetLength(Result.Results, Length(Results));
  for Index := 0 to High(Results) do
    Result.Results[Index] := Results[Index];
end;

{$I Wasm.Api.References.inc}

end.
