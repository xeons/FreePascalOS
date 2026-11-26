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
  WasmTest: what an embedder relies on. Host functions (typed arguments
  and results, exceptions through WebAssembly frames, calls back into
  WebAssembly), import matching, memory growth notifications, the
  externrefs a collector must see, the interrupt hook, and the module
  and export descriptions.
}
unit WasmTest.Embedding;

{$mode objfpc}
{$H+}

interface

procedure RunEmbeddingTests;

implementation

uses
  SysUtils,
  Classes,
  TestChecks,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api,
  WasmTest.Support;

type
  EHostFailure = class(Exception);

  TEmbedder = class
  public
    Store: TWasmStore;
    Reentry: TWasmFunction;
    GrowCalls: Integer;
    GrowOldLength: QWord;
    Visited: TFPList;
    Interrupts: Integer;
    procedure Add(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure Fail(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure CallBack(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure Collect(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure Grown(Memory: TWasmMemory; OldData: Pointer; OldLength: QWord);
    procedure Visit(Reference: Pointer);
    function Interrupt(AStore: TWasmStore): Boolean;
  end;

procedure TEmbedder.Add(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
  Results[0].I64 := Arguments[0].I32 + Arguments[1].I64;
  Results[1].F64Bits := Arguments[2].F64Bits;
end;

procedure TEmbedder.Fail(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
  raise EHostFailure.Create('from the host');
end;

procedure TEmbedder.CallBack(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
var
  Inner: TWasmValueArray;
begin
  if Arguments[0].I32 <= 0 then
  begin
    Results[0].I32 := 0;
    Exit;
  end;
  Inner := nil;
  SetLength(Inner, 1);
  Inner[0] := WasmI32(Arguments[0].I32 - 1);
  Results[0].I32 := WasmCall(Reentry, Inner)[0].I32 + 1;
end;

procedure TEmbedder.Collect(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
  Store.EnumerateReferences(@Visit);
end;

procedure TEmbedder.Grown(Memory: TWasmMemory; OldData: Pointer; OldLength: QWord);
begin
  Inc(GrowCalls);
  GrowOldLength := OldLength;
end;

procedure TEmbedder.Visit(Reference: Pointer);
begin
  Visited.Add(Reference);
end;

function TEmbedder.Interrupt(AStore: TWasmStore): Boolean;
begin
  Inc(Interrupts);
  Result := Interrupts >= 3;
end;

procedure TestHostFunctions(Embedder: TEmbedder);
var
  Imports: TWasmExternalArray;
  Test: TTestModule;
  Results: TWasmValueArray;
  Raised: Boolean;
begin
  Imports := nil;
  SetLength(Imports, 3);
  Imports[0] := FunctionExternal(WasmNewHostFunction(Embedder.Store,
    MakeFunctionType([WasmI32Type, WasmI64Type, WasmF64Type], [WasmI64Type, WasmF64Type]), @Embedder.Add));
  Imports[1] := FunctionExternal(WasmNewHostFunction(Embedder.Store, MakeFunctionType([], []), @Embedder.Fail));
  Imports[2] := FunctionExternal(WasmNewHostFunction(Embedder.Store, MakeFunctionType([WasmI32Type], [WasmI32Type]),
    @Embedder.CallBack));
  Test := TTestModule.CreateWithImports(
    '(module' +
    '  (import "host" "add" (func $add (param i32 i64 f64) (result i64 f64)))' +
    '  (import "host" "fail" (func $fail))' +
    '  (import "host" "back" (func $back (param i32) (result i32)))' +
    '  (func (export "add") (result i64 f64) (call $add (i32.const 40) (i64.const 2) (f64.const 1.5)))' +
    '  (func (export "fail") (result i32) (call $fail) (i32.const 1))' +
    '  (func (export "down") (param i32) (result i32) (i32.add (call $back (local.get 0)) (i32.const 0)))' +
    ')', Embedder.Store, Imports);
  try
    Results := Test.Call('add', []);
    Check((Results[0].I64 = 42) and (Results[1].F64Bits = PQWord(@Results[1].F64Bits)^) and
      (PDouble(@Results[1].F64Bits)^ = 1.5), 'host function with typed arguments and results');
    Raised := False;
    try
      Test.Call('fail', []);
    except
      on E: EHostFailure do
        Raised := True;
    end;
    Check(Raised, 'a host exception unwinds through WebAssembly');
    Check(Embedder.Store.FrameCount = 0, 'no frames left after the exception');
    Embedder.Reentry := Test.Export_('down').Func;
    Check(Test.CallI32('down', [WasmI32(50)]) = 50, 'host calls back into WebAssembly, nested 50 deep');
  finally
    Test.Free;
  end;
end;

procedure TestImports(Embedder: TEmbedder);
var
  Imports: TWasmExternalArray;
  Module: TWasmModule;
  Linked: Boolean;
  Descriptors: TWasmImportDescriptorArray;
  Exported: TWasmExportDescriptorArray;
begin
  Module := WasmCompile(WatBytes('(module (import "m" "f" (func (param i32))) (import "m" "g" (global (mut i64)))' +
    ' (memory (export "mem") 1 2) (func (export "run") (result i32) (i32.const 0)))'));
  try
    Descriptors := WasmModuleImports(Module);
    Check((Length(Descriptors) = 2) and (Descriptors[0].Kind = ekFunction) and (Descriptors[0].Name = 'f') and
      (Length(Descriptors[0].FunctionType.Params) = 1) and (Descriptors[1].Kind = ekGlobal) and
      Descriptors[1].GlobalType.Mutable, 'import descriptors');
    Exported := WasmModuleExports(Module);
    Check((Length(Exported) = 2) and (Exported[0].Kind = ekMemory) and (Exported[0].MemoryType.Limits.Maximum = 2) and
      (Exported[1].Name = 'run') and (Length(Exported[1].FunctionType.Results) = 1), 'export descriptors');
    Imports := nil;
    SetLength(Imports, 2);
    Imports[0] := FunctionExternal(WasmNewHostFunction(Embedder.Store, MakeFunctionType([WasmI64Type], []), @Embedder.Fail));
    Imports[1].Kind := ekGlobal;
    Linked := True;
    try
      WasmInstantiate(Embedder.Store, Module, Imports);
    except
      on EWasmLinkError do
        Linked := False;
    end;
    Check(not Linked, 'a function import of the wrong type does not link');
  finally
    Module.Release;
  end;
end;

procedure TestMemoryGrowth(Embedder: TEmbedder);
var
  Test: TTestModule;
  Memory: TWasmMemory;
  OldData: Pointer;
begin
  Test := TTestModule.Create('(module (memory (export "memory") 1 3)' +
    ' (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))' +
    ' (func (export "size") (result i32) (memory.size))' +
    ' (func (export "poke") (param i32) (i32.store8 (local.get 0) (i32.const 9))))', Embedder.Store);
  try
    Memory := Test.Export_('memory').Memory;
    Memory.OnGrow := @Embedder.Grown;
    Memory.Data[5] := 77;
    OldData := Memory.Data;
    Check(Test.CallI32('grow', [WasmI32(1)]) = 1, 'memory.grow returns the old size');
    Check((Embedder.GrowCalls = 1) and (Embedder.GrowOldLength = WasmPageSize), 'grow notification with the old length');
    Check((Memory.ByteLength = 2 * WasmPageSize) and (Memory.Data[5] = 77), 'grown memory keeps its contents');
    Test.Call('poke', [WasmI32(2 * WasmPageSize - 1)]);
    Check(Memory.Data[2 * WasmPageSize - 1] = 9, 'the new page is usable from WebAssembly');
    Check(Test.CallI32('grow', [WasmI32(2)]) = -1, 'memory.grow past the maximum fails');
    Check(Embedder.GrowCalls = 1, 'no notification when growing fails');
    Check(WasmMemoryGrow(Memory, 1) = 2, 'the embedder grows memory');
    Check(Test.CallI32('size', []) = 3, 'WebAssembly sees the embedder''s growth');
    Check(OldData <> nil, 'memory had data');
  finally
    Test.Free;
  end;
end;

procedure TestReferences(Embedder: TEmbedder);
var
  Imports: TWasmExternalArray;
  Test: TTestModule;
  Global: TWasmGlobal;
begin
  Imports := nil;
  SetLength(Imports, 1);
  Imports[0] := FunctionExternal(WasmNewHostFunction(Embedder.Store, MakeFunctionType([], []), @Embedder.Collect));
  Test := TTestModule.CreateWithImports(
    '(module (import "host" "collect" (func $collect))' +
    '  (table $t (export "table") 2 externref)' +
    '  (global $g (export "global") (mut externref) (ref.null extern))' +
    '  (func (export "keep") (param externref externref)' +
    '    (table.set $t (i32.const 1) (local.get 0))' +
    '    (call $collect)' +
    '    (drop (local.get 1)))' +
    ')', Embedder.Store, Imports);
  try
    Global := Test.Export_('global').Global;
    WasmGlobalSet(Global, WasmExternRef(Pointer(3000)));
    Embedder.Visited.Clear;
    Test.Call('keep', [WasmExternRef(Pointer(1000)), WasmExternRef(Pointer(2000))]);
    Check(Embedder.Visited.IndexOf(Pointer(1000)) >= 0, 'collector sees an externref in a table');
    Check(Embedder.Visited.IndexOf(Pointer(2000)) >= 0, 'collector sees an externref in a suspended frame');
    Check(Embedder.Visited.IndexOf(Pointer(3000)) >= 0, 'collector sees an externref in a global');
    Check(WasmGlobalGet(Global).Reference = Pointer(3000), 'global holds the externref');
  finally
    Test.Free;
  end;
end;

procedure TestInterrupt(Embedder: TEmbedder);
var
  Test: TTestModule;
begin
  Embedder.Store.Options.InterruptInterval := 10000;
  Embedder.Store.InterruptCountdown := 10000;
  Embedder.Store.OnInterrupt := @Embedder.Interrupt;
  Test := TTestModule.Create('(module (func (export "spin") (loop (br 0))))', Embedder.Store);
  try
    Check(Test.TrapOf('spin', []) = tkInterrupted, 'the interrupt hook stops an endless loop');
    Check(Embedder.Interrupts = 3, 'the hook was asked until it said stop');
  finally
    Test.Free;
    Embedder.Store.OnInterrupt := nil;
  end;
end;

procedure RunEmbeddingTests;
var
  Embedder: TEmbedder;
begin
  Embedder := TEmbedder.Create;
  Embedder.Store := TWasmStore.Create;
  Embedder.Visited := TFPList.Create;
  try
    TestHostFunctions(Embedder);
    TestImports(Embedder);
    TestMemoryGrowth(Embedder);
    TestReferences(Embedder);
    TestInterrupt(Embedder);
  finally
    Embedder.Visited.Free;
    Embedder.Store.Free;
    Embedder.Free;
  end;
end;

end.
