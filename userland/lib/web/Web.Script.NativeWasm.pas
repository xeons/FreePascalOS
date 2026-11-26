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
  The natives behind the WebAssembly namespace (platform/57-webassembly.js,
  which does the WebIDL side: arguments, dictionaries, overloads,
  promises, streaming). Objects are checked here (the host class is the
  brand); numbers arrive converted.

    wasmRegister(moduleProto, memoryProto, tableProto, globalProto,
      CompileError, LinkError, RuntimeError)
                                     what this realm's objects and
                                     errors are made with
    wasmInstall(scope)               a worker's global scope (a realm of
                                     this window's runtime) gets a
                                     WebAssembly namespace of its own:
                                     the platform script runs there with
                                     natives of that realm (returned)
    wasmCheck(value, kind)           TypeError unless value is a Module,
                                     Memory, Table or Global (kind 0..3)
    wasmCopyBytes(source)            an ArrayBuffer copy of a BufferSource
                                     (TypeError for anything else)
    wasmValidate(source)             boolean
    wasmCompile(source, proto)       a Module object, or CompileError (also
                                     when CSP forbids compiling)
    wasmModuleExports(module), wasmModuleImports(module)
                                     the descriptors, as plain objects
    wasmCustomSections(module, name) an array of ArrayBuffers
    wasmImportKinds(module)          [module, name, kind, valueType] per
                                     import (valueType for globals)
    wasmInstantiate(module, values)  the exports object, from one value per
                                     import (functions, Global objects or
                                     numbers, Memory and Table objects)
    wasmCloneModule(module)          a new Module object of the same
                                     compiled module (structured clone)
    wasmNewMemory(initial, maximum, shared, proto)
    wasmMemoryBuffer(memory), wasmMemoryGrow(memory, delta)
    wasmMemoryFixedBuffer(memory), wasmMemoryResizableBuffer(memory)
    wasmNewTable(element, initial, maximum, value, hasValue, proto)
    wasmTableLength(table), wasmTableGet(table, index),
    wasmTableSet(table, index, value, hasValue),
    wasmTableGrow(table, delta, value, hasValue)
    wasmNewGlobal(valueType, mutable, value, hasValue, proto)
    wasmGlobalGet(global), wasmGlobalSet(global, value)

  maximum is undefined when absent. A missing value is the type's
  default (JS API DefaultValue: undefined for externref, else the zero
  value or null).
}
unit Web.Script.NativeWasm;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Js.Engine,
  Web.Bindings.Context;

procedure DefineWasmNatives(Context: TBindingContext; Natives: TJsObject);
{ The natives of another realm of Context's runtime (a worker's scope):
  functions of that realm, so what they make and throw is its. }
procedure DefineWasmNativesIn(Engine: TJsEngine; Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Runtime,
  Js.Shapes,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.ArrayBuffers,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Limits,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api,
  Web.Fetch.Requests,
  Web.Fetch.CspChecks,
  Web.Script.PlatformSources,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects,
  Web.Script.WasmValues;

const
  KindNames: array[TWasmExternalKind] of string = ('function', 'table', 'memory', 'global');

type
  TNativeRoutine = function(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function ArgNumber(R: TJsRealm; Args: PJsValueArray; Count, Index: Integer): Double;
begin
  if not ToDouble(R, Arg(Args, Count, Index), Result) then
    Result := 0;
end;

function ArgPrototype(Args: PJsValueArray; Count, Index: Integer): TJsObject;
begin
  if JsIsObject(Arg(Args, Count, Index)) then
    Result := JsAsObject(Arg(Args, Count, Index))
  else
    Result := nil;
end;

function SourceBytes(R: TJsRealm; Source: TJsValue; out Bytes: TBytes): Boolean;
var
  Data: PByte;
  Length_: SizeInt;
begin
  Bytes := nil;
  if not JsIsObject(Source) or not BufferSourceBytes(Source, Data, Length_) then
  begin
    { A detached buffer is an empty one; anything else is no BufferSource. }
    if JsIsObject(Source) and ((JsAsObject(Source) is TJsArrayBuffer) or (JsAsObject(Source) is TJsTypedArray) or
      (JsAsObject(Source) is TJsDataView)) then
      Exit(True);
    R.ThrowTypeError('WebAssembly: the argument must be a BufferSource');
    Exit(False);
  end;
  SetLength(Bytes, Length_);
  if Length_ > 0 then
    Move(Data^, Bytes[0], Length_);
  Result := True;
end;

function TextOf(R: TJsRealm; const Text: string): TJsValue; inline;
begin
  Result := R.NewString(Text);
end;

function NewDescriptor(R: TJsRealm; const Keys: array of string; const Values: array of string): TJsValue;
var
  Made: TJsObject;
  Index: Integer;
begin
  Made := R.NewPlainObject;
  for Index := 0 to High(Keys) do
    Made.CreateDataProperty(R, R.Intern(Keys[Index]), TextOf(R, Values[Index]));
  Result := JsObjectValue(Made);
end;

function ValueTypeName(const ValueType: TWasmValueType): string;
begin
  if (ValueType.Kind = vkReference) and (ValueType.HeapType = HeapTypeFunc) then
    Result := 'anyfunc'
  else
    Result := ValueTypeToString(ValueType);
end;

function ValueTypeFromName(const Name: string; out ValueType: TWasmValueType): Boolean;
begin
  Result := True;
  if Name = 'i32' then
    ValueType := WasmI32Type
  else if Name = 'i64' then
    ValueType := WasmI64Type
  else if Name = 'f32' then
    ValueType := WasmF32Type
  else if Name = 'f64' then
    ValueType := WasmF64Type
  else if Name = 'v128' then
    ValueType := WasmV128Type
  else if Name = 'externref' then
    ValueType := WasmExternRefType
  else if Name = 'anyfunc' then
    ValueType := WasmFuncRefType
  else
    Result := False;
end;

{ The JS API's DefaultValue, or the value converted. }
function ValueOrDefault(R: TJsRealm; Value: TJsValue; HasValue: Boolean; const ValueType: TWasmValueType;
  out Converted: TWasmValue): Boolean;
begin
  if HasValue then
    Exit(ToWebAssemblyValue(R, Value, ValueType, Converted));
  if (ValueType.Kind = vkReference) and (ValueType.HeapType = HeapTypeExtern) then
    Exit(ToWebAssemblyValue(R, JsUndefined, ValueType, Converted));
  Converted := WasmDefaultValue(ValueType);
  Result := True;
end;

function Checked(R: TJsRealm; Value: TJsValue; Kind: TWasmObjectKind; out Data: Pointer): Boolean;
const
  Names: array[TWasmObjectKind] of string = ('Module', 'Memory', 'Table', 'Global');
begin
  Data := WasmObjectData(Value, Kind);
  Result := Data <> nil;
  if not Result then
    R.ThrowTypeError('Illegal invocation: not a WebAssembly.' + Names[Kind]);
end;

{ Registration and checks }

function NativeRegister(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Data: TWasmRealmData;
  Kind: TWasmPrototypeKind;
  ErrorKind: TWasmErrorKind;
begin
  Data := RegisterRealm(R, Context);
  for Kind := Low(Kind) to High(Kind) do
    Data.Prototypes[Kind] := ArgPrototype(Args, ArgCount, Ord(Kind));
  for ErrorKind := Low(ErrorKind) to High(ErrorKind) do
    Data.ErrorConstructors[ErrorKind] := ArgPrototype(Args, ArgCount, 4 + Ord(ErrorKind));
  Result := JsUndefined;
end;

{ The platform script's WebAssembly namespace in a worker's scope. }
function NativeInstall(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
const
  ScriptName = '57-webassembly.js';
var
  Scope, Factory, WindowInternal: TJsValue;
  Engine: TJsEngine;
  Natives, Internal: TJsObject;
  Index, Script: Integer;
begin
  Result := JsUndefined;
  Scope := Arg(Args, ArgCount, 0);
  Engine := nil;
  for Index := 0 to High(Context.WorkerEngines) do
    if JsObjectValue(Context.WorkerEngines[Index].GlobalObject) = Scope then
      Engine := Context.WorkerEngines[Index];
  Script := -1;
  for Index := 0 to PlatformScriptCount - 1 do
    if PlatformScriptNames[Index] = ScriptName then
      Script := Index;
  if (Engine = nil) or (Script < 0) then
    Exit;
  Natives := Engine.NewObject;
  DefineWasmNativesIn(Engine, Context, Natives);
  { The window's helpers (tasks, the Response internals) through the
    prototype; clone hooks of its own, which nothing calls: structured
    clone is the window's. }
  WindowInternal := Context.Singleton(SingletonPlatformInternal);
  Internal := Engine.NewObject;
  if JsIsObject(WindowInternal) then
    Internal.Proto := JsAsObject(WindowInternal);
  Engine.SetProperty(JsObjectValue(Internal), 'cloneHooks', Engine.NewArray([]));
  Factory := Engine.EvaluateBuiltin(PlatformScriptSource(Script), 'platform/' + ScriptName);
  Engine.Call(Factory, JsUndefined, [JsObjectValue(Natives), Scope, JsObjectValue(Internal)]);
  Result := JsObjectValue(Natives);
end;

function NativeCheck(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Data: Pointer;
  Kind: Integer;
begin
  Kind := Trunc(ArgNumber(R, Args, ArgCount, 1));
  if (Kind < Ord(Low(TWasmObjectKind))) or (Kind > Ord(High(TWasmObjectKind))) then
    Kind := 0;
  if not Checked(R, Arg(Args, ArgCount, 0), TWasmObjectKind(Kind), Data) then
    Exit(JsException);
  Result := JsUndefined;
end;

{ Modules }

function NativeCopyBytes(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Bytes: TBytes;
  Buffer: TJsArrayBuffer;
begin
  if not SourceBytes(R, Arg(Args, ArgCount, 0), Bytes) then
    Exit(JsException);
  Buffer := NewArrayBuffer(R, R.Intrinsics[inArrayBufferPrototype], Length(Bytes));
  if Buffer = nil then
    Exit(JsException);
  if Length(Bytes) > 0 then
    Move(Bytes[0], Buffer.Data^, Length(Bytes));
  Result := JsObjectValue(Buffer);
end;

function NativeValidate(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Bytes: TBytes;
begin
  if not SourceBytes(R, Arg(Args, ArgCount, 0), Bytes) then
    Exit(JsException);
  Result := JsBoolean(WasmValidate(Bytes));
end;

function NativeCompile(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Bytes: TBytes;
  Module: TWasmModule;
begin
  if not SourceBytes(R, Arg(Args, ArgCount, 0), Bytes) then
    Exit(JsException);
  if (Context.Document <> nil) and CspBlocksWasm(TFetchClient(Context.Document.SecurityPolicy)) then
    Exit(ThrowWasmErrorOfKind(R, weCompileError,
      'WebAssembly compilation is refused by the page''s Content Security Policy (script-src without ' +
      '''wasm-unsafe-eval'')'));
  try
    Module := WasmCompile(Bytes);
  except
    on Error: Exception do
      Exit(ThrowWasmError(R, Error));
  end;
  try
    Result := NewModuleObject(R, Module, ArgPrototype(Args, ArgCount, 1));
  finally
    Module.Release;
  end;
end;

function NativeModuleExports(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Descriptors: TWasmExportDescriptorArray;
  List: TJsArray;
  Index, Mark: Integer;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Descriptors := WasmModuleExports(Module);
  List := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(List));
  for Index := 0 to High(Descriptors) do
    List.CreateDataProperty(R, JsInteger(Index), NewDescriptor(R, ['name', 'kind'],
      [Descriptors[Index].Name, KindNames[Descriptors[Index].Kind]]));
  R.Runtime.PopRoots(Mark);
  Result := JsObjectValue(List);
end;

function NativeModuleImports(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Descriptors: TWasmImportDescriptorArray;
  List: TJsArray;
  Index, Mark: Integer;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Descriptors := WasmModuleImports(Module);
  List := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(List));
  for Index := 0 to High(Descriptors) do
    List.CreateDataProperty(R, JsInteger(Index), NewDescriptor(R, ['module', 'name', 'kind'],
      [Descriptors[Index].ModuleName, Descriptors[Index].Name, KindNames[Descriptors[Index].Kind]]));
  R.Runtime.PopRoots(Mark);
  Result := JsObjectValue(List);
end;

function NativeCustomSections(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Sections: TBytesArray;
  List: TJsArray;
  Buffer: TJsArrayBuffer;
  Index, Mark: Integer;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Sections := WasmCustomSections(Module, ValueToText(R, Arg(Args, ArgCount, 1)));
  List := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(List));
  try
    for Index := 0 to High(Sections) do
    begin
      Buffer := NewArrayBuffer(R, R.Intrinsics[inArrayBufferPrototype], Length(Sections[Index]));
      if Buffer = nil then
        Exit(JsException);
      if Length(Sections[Index]) > 0 then
        Move(Sections[Index][0], Buffer.Data^, Length(Sections[Index]));
      List.CreateDataProperty(R, JsInteger(Index), JsObjectValue(Buffer));
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(List);
end;

function NativeImportKinds(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Descriptors: TWasmImportDescriptorArray;
  List: TJsArray;
  Entry: TJsArray;
  Index, Mark: Integer;
  TypeName: string;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Descriptors := WasmModuleImports(Module);
  List := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(List));
  for Index := 0 to High(Descriptors) do
  begin
    TypeName := '';
    if Descriptors[Index].Kind = ekGlobal then
      TypeName := ValueTypeName(Descriptors[Index].GlobalType.ValueType);
    Entry := R.NewArray(0);
    List.CreateDataProperty(R, JsInteger(Index), JsObjectValue(Entry));
    Entry.CreateDataProperty(R, JsInteger(0), TextOf(R, Descriptors[Index].ModuleName));
    Entry.CreateDataProperty(R, JsInteger(1), TextOf(R, Descriptors[Index].Name));
    Entry.CreateDataProperty(R, JsInteger(2), TextOf(R, KindNames[Descriptors[Index].Kind]));
    Entry.CreateDataProperty(R, JsInteger(3), TextOf(R, TypeName));
  end;
  R.Runtime.PopRoots(Mark);
  Result := JsObjectValue(List);
end;

{ The exports object (JS API "initialize an instance object"): null
  prototype, one read-only enumerable property per export, frozen. }
function ExportsObject(R: TJsRealm; Instance: TWasmModuleInstance): TJsValue;
var
  Exported: TWasmNamedExternalArray;
  Target: TJsObject;
  Value: TJsValue;
  Index, Mark: Integer;
begin
  Exported := WasmInstanceExports(Instance);
  Target := R.NewObject(nil);
  Result := JsObjectValue(Target);
  Mark := R.Runtime.PushRoot(Result);
  try
    for Index := 0 to High(Exported) do
    begin
      case Exported[Index].External.Kind of
        ekFunction: Value := ExportedFunctionValue(R, Exported[Index].External.Func);
        ekTable: Value := StoreObjectValue(R, woTable, Exported[Index].External.Table);
        ekMemory: Value := StoreObjectValue(R, woMemory, Exported[Index].External.Memory);
      else
        Value := StoreObjectValue(R, woGlobal, Exported[Index].External.Global);
      end;
      Target.DefineData(R, ToPropertyKey(R, R.NewString(Exported[Index].Name)), Value, PropertyEnumerable);
    end;
    Target.PreventExtensions(R);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function NativeInstantiate(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Agent: TWasmAgent;
  Descriptors: TWasmImportDescriptorArray;
  Imports: TWasmExternalArray;
  Values: TJsValue;
  Item: TJsValue;
  Converted: TWasmValue;
  Instance: TWasmModuleInstance;
  Index, Mark: Integer;
  ConstantType: TWasmGlobalType;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Values := Arg(Args, ArgCount, 1);
  if not JsIsObject(Values) then
    Exit(R.ThrowTypeError('WebAssembly: no import values'));
  Agent := AgentOf(Context);
  Descriptors := WasmModuleImports(Module);
  Imports := nil;
  SetLength(Imports, Length(Descriptors));
  Mark := R.Runtime.PushRoot(Values);
  try
    try
      for Index := 0 to High(Descriptors) do
      begin
        Item := JsAsObject(Values).Get(R, JsInteger(Index), Values);
        if Item = JsException then
          Exit(JsException);
        Imports[Index].Kind := Descriptors[Index].Kind;
        case Descriptors[Index].Kind of
          ekFunction:
            begin
              Imports[Index].Func := ExportedFunctionOf(Item);
              if Imports[Index].Func = nil then
              begin
                if not JsIsCallable(Item) then
                  Exit(ThrowWasmErrorOfKind(R, weLinkError, 'WebAssembly: import ' + Descriptors[Index].ModuleName +
                    '.' + Descriptors[Index].Name + ' is not a function'));
                Imports[Index].Func := NewImportedFunction(Agent, Descriptors[Index].FunctionType, Item);
              end;
            end;
          ekGlobal:
            begin
              Imports[Index].Global := TWasmGlobal(WasmObjectData(Item, woGlobal));
              if Imports[Index].Global = nil then
              begin
                if not ToWebAssemblyValue(R, Item, Descriptors[Index].GlobalType.ValueType, Converted) then
                  Exit(JsException);
                ConstantType := Descriptors[Index].GlobalType;
                ConstantType.Mutable := False;
                Imports[Index].Global := WasmNewGlobal(Agent, ConstantType, Converted);
              end;
            end;
          ekMemory: Imports[Index].Memory := TWasmMemory(WasmObjectData(Item, woMemory));
          ekTable: Imports[Index].Table := TWasmTable(WasmObjectData(Item, woTable));
        end;
        if (Imports[Index].Func = nil) and (Imports[Index].Global = nil) and (Imports[Index].Memory = nil) and
          (Imports[Index].Table = nil) then
          Exit(ThrowWasmErrorOfKind(R, weLinkError, 'WebAssembly: import ' + Descriptors[Index].ModuleName + '.' +
            Descriptors[Index].Name + ' must be a WebAssembly.' + KindNames[Descriptors[Index].Kind]));
      end;
      Instance := WasmInstantiate(Agent, Module, Imports);
    except
      on Error: Exception do
        Exit(ThrowWasmError(R, Error));
    end;
    Result := ExportsObject(R, Instance);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function NativeCloneModule(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Result := NewModuleObject(R, Module, nil);
end;

{ Memories }

function NativeNewMemory(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  MemoryType: TWasmMemoryType;
  Memory: TWasmMemory;
begin
  MemoryType := Default(TWasmMemoryType);
  MemoryType.Limits.Minimum := Trunc(ArgNumber(R, Args, ArgCount, 0));
  MemoryType.Limits.HasMaximum := Arg(Args, ArgCount, 1) <> JsUndefined;
  if MemoryType.Limits.HasMaximum then
    MemoryType.Limits.Maximum := Trunc(ArgNumber(R, Args, ArgCount, 1));
  if MemoryType.Limits.Minimum > MaximumMemoryPages then
    Exit(R.ThrowRangeError('WebAssembly.Memory: initial is larger than the most pages a memory may have'));
  if MemoryType.Limits.HasMaximum and (MemoryType.Limits.Maximum > MaximumMemoryPages) then
    Exit(R.ThrowRangeError('WebAssembly.Memory: maximum is larger than the most pages a memory may have'));
  if MemoryType.Limits.HasMaximum and (MemoryType.Limits.Maximum < MemoryType.Limits.Minimum) then
    Exit(R.ThrowRangeError('WebAssembly.Memory: maximum is less than initial'));
  if ToBoolean(Arg(Args, ArgCount, 2)) then
  begin
    if not MemoryType.Limits.HasMaximum then
      Exit(R.ThrowTypeError('WebAssembly.Memory: a shared memory needs a maximum'));
    Exit(R.ThrowTypeError('WebAssembly.Memory: shared memories are not supported'));
  end;
  try
    Memory := WasmNewMemory(AgentOf(Context), MemoryType);
  except
    on Error: Exception do
      Exit(ThrowWasmError(R, Error));
  end;
  Result := NewStoreObject(R, woMemory, Memory, ArgPrototype(Args, ArgCount, 3));
end;

function NativeMemoryBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  Result := MemoryBufferValue(R, Memory);
end;

function NativeMemoryFixedBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  Result := MemoryFixedBufferValue(R, Memory);
end;

function NativeMemoryResizableBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  Result := MemoryResizableBufferValue(R, Memory);
end;

function NativeMemoryGrow(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
  OldPages: Int64;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  { A growth, even of 0 pages, detaches the buffer (OnGrow). }
  try
    OldPages := WasmMemoryGrow(Memory, QWord(Trunc(ArgNumber(R, Args, ArgCount, 1))));
  except
    on Error: Exception do
      Exit(ThrowWasmError(R, Error));
  end;
  if OldPages < 0 then
    Exit(R.ThrowRangeError('WebAssembly.Memory.grow: the memory cannot grow that much'));
  Result := JsNumber(OldPages);
end;

{ Tables }

function ElementTypeOf(R: TJsRealm; Value: TJsValue; out ValueType: TWasmValueType): Boolean;
var
  Name: string;
begin
  Name := ValueToText(R, Value);
  Result := (Name = 'anyfunc') or (Name = 'externref');
  if Name = 'anyfunc' then
    ValueType := WasmFuncRefType
  else
    ValueType := WasmExternRefType;
  if not Result then
    R.ThrowTypeError('WebAssembly.Table: the element type must be "anyfunc" or "externref"');
end;

function NativeNewTable(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  TableType: TWasmTableType;
  Initial: TWasmValue;
  Table: TWasmTable;
  Mark: Integer;
begin
  TableType := Default(TWasmTableType);
  if not ElementTypeOf(R, Arg(Args, ArgCount, 0), TableType.ElementType) then
    Exit(JsException);
  TableType.Limits.Minimum := Trunc(ArgNumber(R, Args, ArgCount, 1));
  TableType.Limits.HasMaximum := Arg(Args, ArgCount, 2) <> JsUndefined;
  if TableType.Limits.HasMaximum then
    TableType.Limits.Maximum := Trunc(ArgNumber(R, Args, ArgCount, 2));
  if TableType.Limits.Minimum > MaximumTableElements then
    Exit(R.ThrowRangeError('WebAssembly.Table: initial is larger than the most elements a table may have'));
  if TableType.Limits.HasMaximum and (TableType.Limits.Maximum < TableType.Limits.Minimum) then
    Exit(R.ThrowRangeError('WebAssembly.Table: maximum is less than initial'));
  if not ValueOrDefault(R, Arg(Args, ArgCount, 3), ToBoolean(Arg(Args, ArgCount, 4)), TableType.ElementType,
    Initial) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Arg(Args, ArgCount, 3));
  try
    try
      Table := WasmNewTable(AgentOf(Context), TableType, Initial.Reference);
    except
      on Error: Exception do
        Exit(ThrowWasmError(R, Error));
    end;
    Result := NewStoreObject(R, woTable, Table, ArgPrototype(Args, ArgCount, 5));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function NativeTableLength(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table)) then
    Exit(JsException);
  Result := JsNumber(Table.Size);
end;

function NativeTableGet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
  Index: Double;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table)) then
    Exit(JsException);
  Index := ArgNumber(R, Args, ArgCount, 1);
  if Index >= Table.Size then
    Exit(R.ThrowRangeError('WebAssembly.Table.get: index out of bounds'));
  Result := ToJSValue(R, WasmReference(Table.TableType.ElementType, Table.Elements[Trunc(Index)]));
end;

function NativeTableSet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
  Index: Double;
  Value: TWasmValue;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table)) then
    Exit(JsException);
  Index := ArgNumber(R, Args, ArgCount, 1);
  if Index >= Table.Size then
    Exit(R.ThrowRangeError('WebAssembly.Table.set: index out of bounds'));
  if not ValueOrDefault(R, Arg(Args, ArgCount, 2), ToBoolean(Arg(Args, ArgCount, 3)), Table.TableType.ElementType,
    Value) then
    Exit(JsException);
  Table.Elements[Trunc(Index)] := Value.Reference;
  Result := JsUndefined;
end;

function NativeTableGrow(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
  Delta: Double;
  Value: TWasmValue;
  OldSize: Int64;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table)) then
    Exit(JsException);
  Delta := ArgNumber(R, Args, ArgCount, 1);
  if not ValueOrDefault(R, Arg(Args, ArgCount, 2), ToBoolean(Arg(Args, ArgCount, 3)), Table.TableType.ElementType,
    Value) then
    Exit(JsException);
  OldSize := WasmTableGrow(Table, Cardinal(Trunc(Delta)), Value.Reference);
  if OldSize < 0 then
    Exit(R.ThrowRangeError('WebAssembly.Table.grow: the table cannot grow that much'));
  Result := JsNumber(OldSize);
end;

{ Globals }

function NativeNewGlobal(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  GlobalType: TWasmGlobalType;
  Value: TWasmValue;
  Global: TWasmGlobal;
  Mark: Integer;
begin
  GlobalType := Default(TWasmGlobalType);
  if not ValueTypeFromName(ValueToText(R, Arg(Args, ArgCount, 0)), GlobalType.ValueType) then
    Exit(R.ThrowTypeError('WebAssembly.Global: unknown value type'));
  if GlobalType.ValueType.Kind = vkV128 then
    Exit(R.ThrowTypeError('WebAssembly.Global: a v128 global cannot be made from JavaScript'));
  GlobalType.Mutable := ToBoolean(Arg(Args, ArgCount, 1));
  if not ValueOrDefault(R, Arg(Args, ArgCount, 2), ToBoolean(Arg(Args, ArgCount, 3)), GlobalType.ValueType, Value) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Arg(Args, ArgCount, 2));
  try
    try
      Global := WasmNewGlobal(AgentOf(Context), GlobalType, Value);
    except
      on Error: Exception do
        Exit(ThrowWasmError(R, Error));
    end;
    Result := NewStoreObject(R, woGlobal, Global, ArgPrototype(Args, ArgCount, 4));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function NativeGlobalGet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Global: TWasmGlobal;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woGlobal, Pointer(Global)) then
    Exit(JsException);
  Result := ToJSValue(R, WasmGlobalGet(Global));
end;

function NativeGlobalSet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Global: TWasmGlobal;
  Value: TWasmValue;
begin
  if not Checked(R, Arg(Args, ArgCount, 0), woGlobal, Pointer(Global)) then
    Exit(JsException);
  if not Global.GlobalType.Mutable then
    Exit(R.ThrowTypeError('WebAssembly.Global: the global is immutable'));
  if Global.GlobalType.ValueType.Kind = vkV128 then
    Exit(R.ThrowTypeError('WebAssembly.Global: a v128 global cannot be set from JavaScript'));
  if not ToWebAssemblyValue(R, Arg(Args, ArgCount, 1), Global.GlobalType.ValueType, Value) then
    Exit(JsException);
  WasmGlobalSet(Global, Value);
  Result := JsUndefined;
end;

const
  NativeCount = 29;
  NativeNames: array[0..NativeCount - 1] of string = (
    'wasmRegister', 'wasmCheck', 'wasmCopyBytes', 'wasmValidate', 'wasmCompile', 'wasmModuleExports',
    'wasmModuleImports', 'wasmCustomSections', 'wasmImportKinds', 'wasmInstantiate', 'wasmCloneModule',
    'wasmNewMemory', 'wasmMemoryBuffer', 'wasmMemoryGrow', 'wasmNewTable', 'wasmTableLength', 'wasmTableGet',
    'wasmTableSet', 'wasmTableGrow', 'wasmNewGlobal', 'wasmGlobalGet', 'wasmGlobalSet', 'wasmIsModule',
    'wasmIsMemory', 'wasmIsTable', 'wasmIsGlobal', 'wasmMemoryFixedBuffer', 'wasmMemoryResizableBuffer',
    'wasmInstall');
  NativeLengths: array[0..NativeCount - 1] of Integer = (7, 2, 1, 1, 2, 1, 1, 2, 1, 2, 1, 4, 1, 2, 6, 1, 2, 4, 4,
    5, 1, 2, 1, 1, 1, 1, 1, 1, 1);

function NativeIsKind(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer;
  Kind: TWasmObjectKind): TJsValue; inline;
begin
  Result := JsBoolean(WasmObjectData(Arg(Args, ArgCount, 0), Kind) <> nil);
end;

function NativeIsModule(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(R, Context, Args, ArgCount, woModule);
end;

function NativeIsMemory(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(R, Context, Args, ArgCount, woMemory);
end;

function NativeIsTable(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(R, Context, Args, ArgCount, woTable);
end;

function NativeIsGlobal(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(R, Context, Args, ArgCount, woGlobal);
end;

const
  NativeRoutines: array[0..NativeCount - 1] of TNativeRoutine = (
    @NativeRegister, @NativeCheck, @NativeCopyBytes, @NativeValidate, @NativeCompile, @NativeModuleExports,
    @NativeModuleImports, @NativeCustomSections, @NativeImportKinds, @NativeInstantiate, @NativeCloneModule,
    @NativeNewMemory, @NativeMemoryBuffer, @NativeMemoryGrow, @NativeNewTable, @NativeTableLength, @NativeTableGet,
    @NativeTableSet, @NativeTableGrow, @NativeNewGlobal, @NativeGlobalGet, @NativeGlobalSet, @NativeIsModule,
    @NativeIsMemory, @NativeIsTable, @NativeIsGlobal, @NativeMemoryFixedBuffer, @NativeMemoryResizableBuffer,
    @NativeInstall);

{ Every native: a Pascal exception becomes a script error. A worker
  realm's natives carry their window's context. }
function NativeEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  if Callee.HostData <> nil then
    Context := TBindingContext(Callee.HostData)
  else
    Context := ContextOfRealm(R);
  try
    Result := NativeRoutines[Callee.Magic](R, Context, Args, ArgCount);
  except
    on Error: Exception do
      Result := ThrowWasmError(R, Error);
  end;
end;

procedure DefineWasmNatives(Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to NativeCount - 1 do
    Context.Engine.DefineFunction(Natives, NativeNames[Index], @NativeEntry, NativeLengths[Index], Index);
end;

procedure DefineWasmNativesIn(Engine: TJsEngine; Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to NativeCount - 1 do
    Engine.DefineFunction(Natives, NativeNames[Index], @NativeEntry, NativeLengths[Index], Index).HostData :=
      Context;
end;

end.
