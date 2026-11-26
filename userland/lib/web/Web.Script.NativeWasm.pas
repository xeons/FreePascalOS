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
  The natives behind the WebAssembly namespace (platform/57-webassembly.js
  and the scripts after it, which do the WebIDL side: arguments,
  dictionaries, overloads, promises, streaming). Objects are checked here
  (the host class is the brand); numbers arrive converted. This unit has
  the registration, modules and instantiation, and the table of every
  native; memories, tables and globals are Web.Script.NativeWasmStorage's,
  tags and exceptions Web.Script.NativeWasmExceptions', the string
  builtins Web.Script.WasmStringBuiltins'.

    wasmRegister(moduleProto, memoryProto, tableProto, globalProto,
      tagProto, exceptionProto, CompileError, LinkError, RuntimeError)
                                     what this realm's objects and
                                     errors are made with
    wasmInstall(scope)               a worker's global scope (a realm of
                                     this window's runtime) gets a
                                     WebAssembly namespace of its own:
                                     the platform scripts run there with
                                     natives of that realm (returned)
    wasmCheck(value, kind)           TypeError unless value is a Module,
                                     Memory, Table, Global, Tag or
                                     Exception (kind 0..5)
    wasmIsModule(value) ... wasmIsException(value)
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
                                     values, Memory, Table and Tag objects)
    wasmCloneModule(module)          a new Module object of the same
                                     compiled module (structured clone)
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
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api,
  Web.Fetch.Requests,
  Web.Fetch.CspChecks,
  Web.Script.PlatformSources,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects,
  Web.Script.WasmValues,
  Web.Script.WasmNativeArguments,
  Web.Script.NativeWasmStorage,
  Web.Script.NativeWasmExceptions,
  Web.Script.WasmStringBuiltins;

const
  KindNames: array[TWasmExternalKind] of string = ('function', 'table', 'memory', 'global', 'tag');

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

{ Registration and checks }

function NativeRegister(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Data: TWasmRealmData;
  Kind: TWasmPrototypeKind;
  ErrorKind: TWasmErrorKind;
  Given: TJsObject;
begin
  { What is undefined stays as registered before (each platform script
    registers its own). }
  Data := RegisterRealm(R, Context);
  for Kind := Low(Kind) to High(Kind) do
  begin
    Given := ArgPrototype(Args, ArgCount, Ord(Kind));
    if Given <> nil then
      Data.Prototypes[Kind] := Given;
  end;
  for ErrorKind := Low(ErrorKind) to High(ErrorKind) do
  begin
    Given := ArgPrototype(Args, ArgCount, Ord(High(TWasmPrototypeKind)) + 1 + Ord(ErrorKind));
    if Given <> nil then
      Data.ErrorConstructors[ErrorKind] := Given;
  end;
  Result := JsUndefined;
end;

{ The platform scripts of the WebAssembly namespace in a worker's scope:
  every platform/5x-webassembly*.js, in order, with the same natives. }
function NativeInstall(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Scope, Factory, WindowInternal: TJsValue;
  Engine: TJsEngine;
  Natives, Internal: TJsObject;
  Index: Integer;
begin
  Result := JsUndefined;
  Scope := Arg(Args, ArgCount, 0);
  Engine := nil;
  for Index := 0 to High(Context.WorkerEngines) do
    if JsObjectValue(Context.WorkerEngines[Index].GlobalObject) = Scope then
      Engine := Context.WorkerEngines[Index];
  if Engine = nil then
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
  for Index := 0 to PlatformScriptCount - 1 do
    if Pos('-webassembly', PlatformScriptNames[Index]) > 0 then
    begin
      Factory := Engine.EvaluateBuiltin(PlatformScriptSource(Index), 'platform/' + PlatformScriptNames[Index]);
      Engine.Call(Factory, JsUndefined, [JsObjectValue(Natives), Scope, JsObjectValue(Internal)]);
    end;
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), TWasmObjectKind(Kind), Data) then
    Exit(JsException);
  Result := JsUndefined;
end;

function NativeIsKind(Args: PJsValueArray; ArgCount: Integer; Kind: TWasmObjectKind): TJsValue; inline;
begin
  Result := JsBoolean(WasmObjectData(Arg(Args, ArgCount, 0), Kind) <> nil);
end;

function NativeIsModule(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(Args, ArgCount, woModule);
end;

function NativeIsMemory(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(Args, ArgCount, woMemory);
end;

function NativeIsTable(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(Args, ArgCount, woTable);
end;

function NativeIsGlobal(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(Args, ArgCount, woGlobal);
end;

function NativeIsTag(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(Args, ArgCount, woTag);
end;

function NativeIsException(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := NativeIsKind(Args, ArgCount, woException);
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
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
        ekGlobal: Value := StoreObjectValue(R, woGlobal, Exported[Index].External.Global);
      else
        Value := StoreObjectValue(R, woTag, Exported[Index].External.Tag);
      end;
      Target.DefineData(R, ToPropertyKey(R, R.NewString(Exported[Index].Name)), Value, PropertyEnumerable);
    end;
    Target.PreventExtensions(R);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ImportName(const Descriptor: TWasmImportDescriptor): string;
begin
  Result := 'WebAssembly: import ' + Descriptor.ModuleName + '.' + Descriptor.Name;
end;

{ A value for a global import that is no Global: a constant global of
  the import's type; a value of the wrong type is a LinkError (JS API
  "read the imports"). }
function ConstantGlobalImport(R: TJsRealm; Agent: TWasmAgent; Item: TJsValue; const Descriptor: TWasmImportDescriptor;
  const TypeIds: TWasmIdArray; out Global: TWasmGlobal): Boolean;
var
  ConstantType: TWasmGlobalType;
  Converted: TWasmValue;
begin
  Global := nil;
  ConstantType := Descriptor.GlobalType;
  ConstantType.ValueType := WasmStoreValueType(TypeIds, ConstantType.ValueType);
  ConstantType.Mutable := False;
  if IsOpaqueType(Agent, ConstantType.ValueType) then
  begin
    ThrowWasmErrorOfKind(R, weLinkError, ImportName(Descriptor) + ' must be a WebAssembly.Global');
    Exit(False);
  end;
  if not ToWebAssemblyValue(R, Item, ConstantType.ValueType, Converted) then
  begin
    if R.Runtime.HasException and not R.Runtime.Terminating then
    begin
      R.Runtime.TakeException;
      ThrowWasmErrorOfKind(R, weLinkError, ImportName(Descriptor) + ': the value is not of the global''s type');
    end;
    Exit(False);
  end;
  Global := WasmNewGlobal(Agent, ConstantType, Converted);
  Result := True;
end;

function NativeInstantiate(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Module: TWasmModule;
  Agent: TWasmAgent;
  Descriptors: TWasmImportDescriptorArray;
  Imports: TWasmExternalArray;
  TypeIds: TWasmIdArray;
  Values: TJsValue;
  Item: TJsValue;
  Instance: TWasmModuleInstance;
  Index, Mark: Integer;
  Found: Boolean;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Values := Arg(Args, ArgCount, 1);
  if not JsIsObject(Values) then
    Exit(R.ThrowTypeError('WebAssembly: no import values'));
  Agent := AgentOf(Context);
  Descriptors := WasmModuleImports(Module);
  TypeIds := WasmModuleTypeIds(Agent, Module);
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
                  Exit(ThrowWasmErrorOfKind(R, weLinkError, ImportName(Descriptors[Index]) + ' is not a function'));
                Imports[Index].Func := NewImportedFunction(Agent, TypeIds[Module.Imports[Index].TypeIndex], Item);
              end;
            end;
          ekGlobal:
            begin
              Imports[Index].Global := TWasmGlobal(WasmObjectData(Item, woGlobal));
              if (Imports[Index].Global = nil) and not ConstantGlobalImport(R, Agent, Item, Descriptors[Index],
                TypeIds, Imports[Index].Global) then
                Exit(JsException);
            end;
          ekMemory: Imports[Index].Memory := TWasmMemory(WasmObjectData(Item, woMemory));
          ekTable: Imports[Index].Table := TWasmTable(WasmObjectData(Item, woTable));
          ekTag: Imports[Index].Tag := TWasmTag(WasmObjectData(Item, woTag));
        end;
        Found := (Imports[Index].Func <> nil) or (Imports[Index].Global <> nil) or (Imports[Index].Memory <> nil) or
          (Imports[Index].Table <> nil) or (Imports[Index].Tag <> nil);
        if not Found then
          Exit(ThrowWasmErrorOfKind(R, weLinkError, ImportName(Descriptors[Index]) + ' must be a WebAssembly.' +
            KindNames[Descriptors[Index].Kind]));
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woModule, Pointer(Module)) then
    Exit(JsException);
  Result := NewModuleObject(R, Module, nil);
end;

type
  TNativeEntry = record
    Name: string;
    Length: Integer;
    Routine: TWasmNativeRoutine;
  end;

const
  NativeCount = 40;
  NativeTable: array[0..NativeCount - 1] of TNativeEntry = (
    (Name: 'wasmRegister'; Length: 9; Routine: @NativeRegister),
    (Name: 'wasmInstall'; Length: 1; Routine: @NativeInstall),
    (Name: 'wasmCheck'; Length: 2; Routine: @NativeCheck),
    (Name: 'wasmIsModule'; Length: 1; Routine: @NativeIsModule),
    (Name: 'wasmIsMemory'; Length: 1; Routine: @NativeIsMemory),
    (Name: 'wasmIsTable'; Length: 1; Routine: @NativeIsTable),
    (Name: 'wasmIsGlobal'; Length: 1; Routine: @NativeIsGlobal),
    (Name: 'wasmIsTag'; Length: 1; Routine: @NativeIsTag),
    (Name: 'wasmIsException'; Length: 1; Routine: @NativeIsException),
    (Name: 'wasmCopyBytes'; Length: 1; Routine: @NativeCopyBytes),
    (Name: 'wasmValidate'; Length: 1; Routine: @NativeValidate),
    (Name: 'wasmCompile'; Length: 2; Routine: @NativeCompile),
    (Name: 'wasmModuleExports'; Length: 1; Routine: @NativeModuleExports),
    (Name: 'wasmModuleImports'; Length: 1; Routine: @NativeModuleImports),
    (Name: 'wasmCustomSections'; Length: 2; Routine: @NativeCustomSections),
    (Name: 'wasmImportKinds'; Length: 1; Routine: @NativeImportKinds),
    (Name: 'wasmInstantiate'; Length: 2; Routine: @NativeInstantiate),
    (Name: 'wasmCloneModule'; Length: 1; Routine: @NativeCloneModule),
    (Name: 'wasmNewMemory'; Length: 5; Routine: @NativeNewMemory),
    (Name: 'wasmMemoryBuffer'; Length: 1; Routine: @NativeMemoryBuffer),
    (Name: 'wasmMemoryGrow'; Length: 2; Routine: @NativeMemoryGrow),
    (Name: 'wasmMemoryFixedBuffer'; Length: 1; Routine: @NativeMemoryFixedBuffer),
    (Name: 'wasmMemoryResizableBuffer'; Length: 1; Routine: @NativeMemoryResizableBuffer),
    (Name: 'wasmNewTable'; Length: 7; Routine: @NativeNewTable),
    (Name: 'wasmTableLength'; Length: 1; Routine: @NativeTableLength),
    (Name: 'wasmTableGet'; Length: 2; Routine: @NativeTableGet),
    (Name: 'wasmTableSet'; Length: 4; Routine: @NativeTableSet),
    (Name: 'wasmTableGrow'; Length: 4; Routine: @NativeTableGrow),
    (Name: 'wasmAddressType'; Length: 1; Routine: @NativeAddressType),
    (Name: 'wasmToAddress'; Length: 1; Routine: @NativeToAddress),
    (Name: 'wasmNewGlobal'; Length: 5; Routine: @NativeNewGlobal),
    (Name: 'wasmGlobalGet'; Length: 1; Routine: @NativeGlobalGet),
    (Name: 'wasmGlobalSet'; Length: 2; Routine: @NativeGlobalSet),
    (Name: 'wasmNewTag'; Length: 2; Routine: @NativeNewTag),
    (Name: 'wasmJSTag'; Length: 0; Routine: @NativeJsTag),
    (Name: 'wasmNewException'; Length: 3; Routine: @NativeNewException),
    (Name: 'wasmExceptionGetArg'; Length: 2; Routine: @NativeExceptionGetArg),
    (Name: 'wasmExceptionIs'; Length: 2; Routine: @NativeExceptionIs),
    (Name: 'wasmValidateBuiltins'; Length: 3; Routine: @NativeValidateBuiltins),
    (Name: 'wasmStringBuiltins'; Length: 0; Routine: @NativeStringBuiltins));

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
    Result := NativeTable[Callee.Magic].Routine(R, Context, Args, ArgCount);
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
    Context.Engine.DefineFunction(Natives, NativeTable[Index].Name, @NativeEntry, NativeTable[Index].Length, Index);
end;

procedure DefineWasmNativesIn(Engine: TJsEngine; Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to NativeCount - 1 do
    Engine.DefineFunction(Natives, NativeTable[Index].Name, @NativeEntry, NativeTable[Index].Length, Index).HostData :=
      Context;
end;

end.
