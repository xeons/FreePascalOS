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
  The natives of WebAssembly.Memory, Table and Global (called by
  platform/57-webassembly.js with their arguments converted):

    wasmNewMemory(initial, maximum, shared, proto, address64)
    wasmMemoryBuffer(memory), wasmMemoryGrow(memory, delta)
    wasmMemoryFixedBuffer(memory), wasmMemoryResizableBuffer(memory)
    wasmNewTable(element, initial, maximum, value, hasValue, proto, address64)
    wasmTableLength(table), wasmTableGet(table, index),
    wasmTableSet(table, index, value, hasValue),
    wasmTableGrow(table, delta, value, hasValue)
    wasmAddressType(memoryOrTable)   "i32" or "i64"
    wasmToAddress(value)             AddressValueToU64 for "i64" (a BigInt)
    wasmNewGlobal(valueType, mutable, value, hasValue, proto)
    wasmGlobalGet(global), wasmGlobalSet(global, value)

  Sizes, indices and deltas are address values (Web.Script.
  WasmNativeArguments): Numbers for an i32 memory or table, BigInts for
  an i64 one, both ways. maximum is undefined when absent. A missing
  value is the type's default (JS API DefaultValue: undefined for
  externref, null for other nullable references, the zero value; a
  TypeError for a non-nullable reference type).
}
unit Web.Script.NativeWasmStorage;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Web.Bindings.Context;

function NativeNewMemory(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeMemoryBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeMemoryFixedBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
function NativeMemoryResizableBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
function NativeMemoryGrow(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeNewTable(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeTableLength(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeTableGet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeTableSet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeTableGrow(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeAddressType(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeToAddress(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeNewGlobal(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeGlobalGet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeGlobalSet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

implementation

uses
  SysUtils,
  Js.Conversions,
  Wasm.Types,
  Wasm.Limits,
  Wasm.Runtime,
  Wasm.Api,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects,
  Web.Script.WasmValues,
  Web.Script.WasmNativeArguments;

function AddressTypeOf(Args: PJsValueArray; ArgCount, Index: Integer): TWasmValueKind;
begin
  if ToBoolean(Arg(Args, ArgCount, Index)) then
    Result := vkI64
  else
    Result := vkI32;
end;

{ The JS API's DefaultValue, or the value converted. }
function ValueOrDefault(R: TJsRealm; Value: TJsValue; HasValue: Boolean; const ValueType: TWasmValueType;
  out Converted: TWasmValue): Boolean;
begin
  if HasValue then
    Exit(ToWebAssemblyValue(R, Value, ValueType, Converted));
  if (ValueType.Kind = vkReference) and (ValueType.HeapType = HeapTypeExtern) and ValueType.Nullable then
    Exit(ToWebAssemblyValue(R, JsUndefined, ValueType, Converted));
  Converted := WasmDefaultValue(ValueType);
  if (ValueType.Kind = vkReference) and not ValueType.Nullable then
  begin
    R.ThrowTypeError('WebAssembly: a value is required: the type ' + ValueTypeToString(ValueType) +
      ' has no default');
    Exit(False);
  end;
  Result := True;
end;

{ Memories }

function NativeNewMemory(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  MemoryType: TWasmMemoryType;
  Memory: TWasmMemory;
  MaximumPages: QWord;
begin
  MemoryType := Default(TWasmMemoryType);
  MemoryType.AddressType := AddressTypeOf(Args, ArgCount, 4);
  MemoryType.Limits.Minimum := ArgAddress(Args, ArgCount, 0);
  MemoryType.Limits.HasMaximum := Arg(Args, ArgCount, 1) <> JsUndefined;
  if MemoryType.Limits.HasMaximum then
    MemoryType.Limits.Maximum := ArgAddress(Args, ArgCount, 1);
  if MemoryType.AddressType = vkI64 then
    MaximumPages := MaximumMemory64Pages
  else
    MaximumPages := MaximumMemoryPages;
  if MemoryType.Limits.Minimum > MaximumPages then
    Exit(R.ThrowRangeError('WebAssembly.Memory: initial is larger than the most pages a memory may have'));
  if MemoryType.Limits.HasMaximum and (MemoryType.Limits.Maximum > MaximumPages) then
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  Result := MemoryBufferValue(R, Memory);
end;

function NativeMemoryFixedBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  Result := MemoryFixedBufferValue(R, Memory);
end;

function NativeMemoryResizableBuffer(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  Result := MemoryResizableBufferValue(R, Memory);
end;

function NativeMemoryGrow(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
  OldPages: Int64;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woMemory, Pointer(Memory)) then
    Exit(JsException);
  { A growth, even of 0 pages, detaches the buffer (OnGrow). }
  try
    OldPages := WasmMemoryGrow(Memory, ArgAddress(Args, ArgCount, 1));
  except
    on Error: Exception do
      Exit(ThrowWasmError(R, Error));
  end;
  if OldPages < 0 then
    Exit(R.ThrowRangeError('WebAssembly.Memory.grow: the memory cannot grow that much'));
  Result := AddressValue(R, QWord(OldPages), Memory.MemoryType.AddressType);
end;

{ Tables }

function NativeNewTable(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  TableType: TWasmTableType;
  Initial: TWasmValue;
  Table: TWasmTable;
  Mark: Integer;
begin
  TableType := Default(TWasmTableType);
  if not ValueTypeFromName(ValueToText(R, Arg(Args, ArgCount, 0)), TableType.ElementType) or
    (TableType.ElementType.Kind <> vkReference) then
    Exit(R.ThrowTypeError('WebAssembly.Table: the element type must be a reference type'));
  TableType.AddressType := AddressTypeOf(Args, ArgCount, 6);
  TableType.Limits.Minimum := ArgAddress(Args, ArgCount, 1);
  TableType.Limits.HasMaximum := Arg(Args, ArgCount, 2) <> JsUndefined;
  if TableType.Limits.HasMaximum then
    TableType.Limits.Maximum := ArgAddress(Args, ArgCount, 2);
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

function CheckedTable(R: TJsRealm; Args: PJsValueArray; ArgCount: Integer; out Table: TWasmTable): Boolean;
begin
  Result := CheckedWasmObject(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table));
  if Result and IsOpaqueType(Table.Store, Table.TableType.ElementType) then
  begin
    R.ThrowTypeError('WebAssembly.Table: a table of exnref cannot be used from JavaScript');
    Result := False;
  end;
end;

function NativeTableLength(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table)) then
    Exit(JsException);
  Result := AddressValue(R, Table.Size, Table.TableType.AddressType);
end;

function NativeTableGet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
  Index: QWord;
begin
  if not CheckedTable(R, Args, ArgCount, Table) then
    Exit(JsException);
  Index := ArgAddress(Args, ArgCount, 1);
  if Index >= Table.Size then
    Exit(R.ThrowRangeError('WebAssembly.Table.get: index out of bounds'));
  Result := ToJSValue(R, WasmReference(Table.TableType.ElementType, WasmTableGet(Table, Cardinal(Index))));
end;

function NativeTableSet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
  Index: QWord;
  Value: TWasmValue;
begin
  if not CheckedTable(R, Args, ArgCount, Table) then
    Exit(JsException);
  Index := ArgAddress(Args, ArgCount, 1);
  if not ValueOrDefault(R, Arg(Args, ArgCount, 2), ToBoolean(Arg(Args, ArgCount, 3)), Table.TableType.ElementType,
    Value) then
    Exit(JsException);
  if Index >= Table.Size then
    Exit(R.ThrowRangeError('WebAssembly.Table.set: index out of bounds'));
  WasmTableSet(Table, Cardinal(Index), Value.Reference);
  Result := JsUndefined;
end;

function NativeTableGrow(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Table: TWasmTable;
  Delta: QWord;
  Value: TWasmValue;
  OldSize: Int64;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woTable, Pointer(Table)) then
    Exit(JsException);
  Delta := ArgAddress(Args, ArgCount, 1);
  if not ValueOrDefault(R, Arg(Args, ArgCount, 2), ToBoolean(Arg(Args, ArgCount, 3)), Table.TableType.ElementType,
    Value) then
    Exit(JsException);
  OldSize := -1;
  if Delta <= MaximumTableElements then
    OldSize := WasmTableGrow(Table, Cardinal(Delta), Value.Reference);
  if OldSize < 0 then
    Exit(R.ThrowRangeError('WebAssembly.Table.grow: the table cannot grow that much'));
  Result := AddressValue(R, QWord(OldSize), Table.TableType.AddressType);
end;

function NativeAddressType(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Memory: TWasmMemory;
  Table: TWasmTable;
  AddressType: TWasmValueKind;
begin
  Memory := TWasmMemory(WasmObjectData(Arg(Args, ArgCount, 0), woMemory));
  Table := TWasmTable(WasmObjectData(Arg(Args, ArgCount, 0), woTable));
  if Memory <> nil then
    AddressType := Memory.MemoryType.AddressType
  else if Table <> nil then
    AddressType := Table.TableType.AddressType
  else
    Exit(R.ThrowTypeError('Illegal invocation: not a WebAssembly.Memory or WebAssembly.Table'));
  if AddressType = vkI64 then
    Result := R.NewString('i64')
  else
    Result := R.NewString('i32');
end;

function NativeToAddress(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := ToAddressBigInt(R, Arg(Args, ArgCount, 0));
end;

{ Globals }

function NativeNewGlobal(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  GlobalType: TWasmGlobalType;
  Value: TWasmValue;
  Global: TWasmGlobal;
  Agent: TWasmAgent;
  Mark: Integer;
begin
  GlobalType := Default(TWasmGlobalType);
  if not ValueTypeFromName(ValueToText(R, Arg(Args, ArgCount, 0)), GlobalType.ValueType) then
    Exit(R.ThrowTypeError('WebAssembly.Global: unknown value type'));
  Agent := AgentOf(Context);
  if IsOpaqueType(Agent, GlobalType.ValueType) then
    Exit(R.ThrowTypeError('WebAssembly.Global: a v128 or exnref global cannot be made from JavaScript'));
  GlobalType.Mutable := ToBoolean(Arg(Args, ArgCount, 1));
  if not ValueOrDefault(R, Arg(Args, ArgCount, 2), ToBoolean(Arg(Args, ArgCount, 3)), GlobalType.ValueType, Value) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Arg(Args, ArgCount, 2));
  try
    try
      Global := WasmNewGlobal(Agent, GlobalType, Value);
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
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woGlobal, Pointer(Global)) then
    Exit(JsException);
  if IsOpaqueType(Global.Store, Global.GlobalType.ValueType) then
    Exit(R.ThrowTypeError('WebAssembly.Global: a v128 or exnref global cannot be read from JavaScript'));
  Result := ToJSValue(R, WasmGlobalGet(Global));
end;

function NativeGlobalSet(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Global: TWasmGlobal;
  Value: TWasmValue;
begin
  if not CheckedWasmObject(R, Arg(Args, ArgCount, 0), woGlobal, Pointer(Global)) then
    Exit(JsException);
  if IsOpaqueType(Global.Store, Global.GlobalType.ValueType) then
    Exit(R.ThrowTypeError('WebAssembly.Global: a v128 or exnref global cannot be set from JavaScript'));
  if not Global.GlobalType.Mutable then
    Exit(R.ThrowTypeError('WebAssembly.Global: the global is immutable'));
  if not ToWebAssemblyValue(R, Arg(Args, ArgCount, 1), Global.GlobalType.ValueType, Value) then
    Exit(JsException);
  WasmGlobalSet(Global, Value);
  Result := JsUndefined;
end;

end.
