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
}
unit Wasm.Api;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime;

type
  TWasmImportDescriptor = record
    ModuleName: AnsiString;
    Name: AnsiString;
    Kind: TWasmExternalKind;
    FunctionType: TWasmFunctionType;
    TableType: TWasmTableType;
    MemoryType: TWasmMemoryType;
    GlobalType: TWasmGlobalType;
  end;
  TWasmImportDescriptorArray = array of TWasmImportDescriptor;

  TWasmExportDescriptor = record
    Name: AnsiString;
    Kind: TWasmExternalKind;
    FunctionType: TWasmFunctionType;
    TableType: TWasmTableType;
    MemoryType: TWasmMemoryType;
    GlobalType: TWasmGlobalType;
  end;
  TWasmExportDescriptorArray = array of TWasmExportDescriptor;

  TWasmNamedExternal = record
    Name: AnsiString;
    External: TWasmExternal;
  end;
  TWasmNamedExternalArray = array of TWasmNamedExternal;

  TBytesArray = array of TBytes;

  { Finds the external value for an import; False if there is none. }
  TWasmImportResolver = function(const Import: TWasmImportDescriptor; out External: TWasmExternal): Boolean of object;

function WasmCompile(const Bytes: TBytes): TWasmModule;
function WasmValidate(const Bytes: TBytes): Boolean;
function WasmModuleImports(Module: TWasmModule): TWasmImportDescriptorArray;
function WasmModuleExports(Module: TWasmModule): TWasmExportDescriptorArray;
function WasmCustomSections(Module: TWasmModule; const Name: AnsiString): TBytesArray;

function WasmInstantiate(Store: TWasmStore; Module: TWasmModule; const Imports: TWasmExternalArray): TWasmModuleInstance;
function WasmInstantiateWith(Store: TWasmStore; Module: TWasmModule; Resolver: TWasmImportResolver): TWasmModuleInstance;
function WasmInstanceExports(Instance: TWasmModuleInstance): TWasmNamedExternalArray;

function WasmCall(Func: TWasmFunction; const Arguments: TWasmValueArray): TWasmValueArray;
function WasmNewHostFunction(Store: TWasmStore; const FunctionType: TWasmFunctionType;
  Callback: TWasmHostCallback; Data: Pointer = nil): TWasmFunction;

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

implementation

uses
  Math,
  Wasm.Decoder,
  Wasm.Validator,
  Wasm.Compiler,
  Wasm.Instantiation,
  Wasm.Interpreter;

function WasmCompile(const Bytes: TBytes): TWasmModule;
begin
  Result := DecodeModule(Bytes);
  try
    ValidateModule(Result);
    CompileModule(Result);
  except
    Result.Release;
    raise;
  end;
end;

function WasmValidate(const Bytes: TBytes): Boolean;
var
  Module: TWasmModule;
begin
  try
    Module := DecodeModule(Bytes);
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

function WasmNewMemory(Store: TWasmStore; const MemoryType: TWasmMemoryType): TWasmMemory;
begin
  Result := Store.NewMemory(MemoryType);
end;

function WasmNewTable(Store: TWasmStore; const TableType: TWasmTableType; InitialValue: Pointer): TWasmTable;
begin
  Result := Store.NewTable(TableType, InitialValue);
end;

function WasmNewGlobal(Store: TWasmStore; const GlobalType: TWasmGlobalType; const Value: TWasmValue): TWasmGlobal;
begin
  if Value.ValueType <> GlobalType.ValueType then
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
  if Value.ValueType <> Global.GlobalType.ValueType then
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
  Table.Elements[Index] := Value;
end;

function WasmTableGrow(Table: TWasmTable; Delta: Cardinal; Value: Pointer): Int64;
begin
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

end.
