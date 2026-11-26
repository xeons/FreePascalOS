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
  WasmTest: the garbage collector and what crosses between WebAssembly
  and the host.

  A store with a small collection threshold runs code that allocates
  much garbage while it holds objects in a global, a local, the operand
  stack across a call and in an object handed to the host, and checks
  they all survive many collections while the garbage goes. Then the
  embedder's side: externrefs inside objects found by
  EnumerateReferences, the trace protocol (an object only the host
  reaches survives a host trace when the host traces it and goes when
  it does not), i31 and boxed host values through the interface, and
  exceptions: one leaving WebAssembly as EWasmException with its tag and
  payload, one a host function throws into WebAssembly, one passing
  through a host function between two WebAssembly frames, and one made
  with a host tag (the JavaScript layer's JSTag).
}
unit WasmTest.Collector;

{$mode objfpc}
{$H+}

interface

procedure RunCollectorTests;

implementation

uses
  SysUtils,
  Classes,
  TestChecks,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Runtime,
  Wasm.Exceptions,
  Wasm.Api,
  WasmTest.Support;

type
  THost = class
  public
    Store: TWasmStore;
    Visited: TList;
    Tag: TWasmTag;
    JsTag: TWasmTag;
    Inner: TWasmFunction;
    procedure ThrowJs(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure Visit(Reference: Pointer);
    procedure Throw(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure CallInner(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure Collect(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    function VisitedCount(Reference: Pointer): Integer;
  end;

procedure THost.Visit(Reference: Pointer);
begin
  Visited.Add(Reference);
end;

function THost.VisitedCount(Reference: Pointer): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Visited.Count - 1 do
    if Visited[Index] = Reference then
      Inc(Result);
end;

procedure THost.Throw(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
var
  Payload: TWasmValueArray;
begin
  Payload := nil;
  SetLength(Payload, 1);
  Payload[0] := WasmI32(Arguments[0].I32 * 2);
  WasmThrow(Store, Tag, Payload);
end;

{ What the JavaScript layer does with a JavaScript exception: throw it
  with its JSTag, the JavaScript value as the externref payload. }
procedure THost.ThrowJs(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
var
  Payload: TWasmValueArray;
begin
  Payload := nil;
  SetLength(Payload, 1);
  Payload[0] := WasmExternRef(Pointer(PtrUInt($100)));
  WasmThrow(Store, JsTag, Payload);
end;

procedure THost.CallInner(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
  WasmCall(Inner, Arguments);
end;

procedure THost.Collect(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
  WasmCollectGarbage(Store);
end;

const
  CollectorModule: PChar =
    '(module' +
    '  (type $node (struct (field $value i32) (field $next (ref null $node))))' +
    '  (type $junk (array (mut i64)))' +
    '  (type $box (struct (field $held externref)))' +
    '  (import "host" "collect" (func $collect))' +
    '  (global $list (mut (ref null $node)) (ref.null $node))' +
    '  (global $kept (mut (ref null $box)) (ref.null $box))' +
    '  (func $churn (param $n i32)' +
    '    (loop $l' +
    '      (drop (array.new_default $junk (i32.const 64)))' +
    '      (local.set $n (i32.sub (local.get $n) (i32.const 1)))' +
    '      (br_if $l (i32.gt_s (local.get $n) (i32.const 0)))))' +
    '  (func (export "build") (param $n i32)' +
    '    (local $i i32)' +
    '    (loop $l' +
    '      (global.set $list (struct.new $node (local.get $i) (global.get $list)))' +
    '      (call $churn (i32.const 20))' +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' +
    '      (br_if $l (i32.lt_u (local.get $i) (local.get $n)))))' +
    '  (func (export "sum") (result i32)' +
    '    (local $node (ref null $node)) (local $sum i32)' +
    '    (local.set $node (global.get $list))' +
    '    (block $done (loop $l' +
    '      (br_if $done (ref.is_null (local.get $node)))' +
    '      (local.set $sum (i32.add (local.get $sum) (struct.get $node $value (local.get $node))))' +
    '      (local.set $node (struct.get $node $next (local.get $node)))' +
    '      (br $l)))' +
    '    (local.get $sum))' +
    '  (func (export "local") (result i32)' +
    '    (local $mine (ref null $node))' +
    '    (local.set $mine (struct.new $node (i32.const 77) (ref.null $node)))' +
    '    (call $churn (i32.const 5000))' +
    '    (struct.get $node $value (local.get $mine)))' +
    '  (func (export "operand") (result i32)' +
    '    (struct.get $node $value' +
    '      (struct.new $node (i32.const 55) (ref.null $node))' +
    '      (call $churn (i32.const 5000))' +
    '      (call $collect)))' +
    '  (func (export "make") (param i32) (result (ref $node)) (struct.new $node (local.get 0) (ref.null $node)))' +
    '  (func (export "read") (param (ref $node)) (result i32) (struct.get $node $value (local.get 0)))' +
    '  (func (export "churn") (param i32) (call $churn (local.get 0)))' +
    '  (func (export "keep") (param externref) (global.set $kept (struct.new $box (local.get 0))))' +
    '  (func (export "box") (param externref) (result (ref $box)) (struct.new $box (local.get 0)))' +
    '  (func (export "drop_kept") (global.set $kept (ref.null $box))))';

function NewTestStore: TWasmStore;
var
  Options: TWasmStoreOptions;
begin
  Options := TWasmStore.DefaultOptions;
  Options.CollectionThreshold := 256 * 1024;
  Options.MaximumHeapBytes := 64 * 1024 * 1024;
  Result := TWasmStore.Create(Options);
end;

procedure TestSurvival(Host: THost);
var
  Imports: TWasmExternalArray;
  Test: TTestModule;
  Made: TWasmValueArray;
  Collections, Objects: Integer;
  Arguments: TWasmValueArray;
  HostValue: Pointer;
begin
  Host.Store := NewTestStore;
  SetLength(Imports, 1);
  Imports[0] := FunctionExternal(WasmNewHostFunction(Host.Store, MakeFunctionType([], []), @Host.Collect));
  Test := TTestModule.CreateWithImports(StrPas(CollectorModule), Host.Store, Imports);
  try
    Test.Call('build', [WasmI32(2000)]);
    Collections := Host.Store.Heap.Collections;
    Check(Collections > 5, 'allocation runs collections (' + IntToStr(Collections) + ')');
    Check(Test.CallI32('sum', []) = 2000 * 1999 div 2, 'a list in a global survives the collections');
    Objects := Host.Store.Heap.ObjectCount;
    Check(Objects < 2000 + 5000, 'garbage is freed (' + IntToStr(Objects) + ' objects left)');
    Check(Test.CallI32('local', []) = 77, 'an object in a local survives collections in a callee');
    Check(Test.CallI32('operand', []) = 55, 'an object on the operand stack survives a call that collects');

    Made := Test.Call('make', [WasmI32(91)]);
    Test.Call('churn', [WasmI32(20000)]);
    WasmCollectGarbage(Host.Store);
    SetLength(Arguments, 1);
    Arguments[0] := Made[0];
    Check(WasmCall(Test.Export_('read').Func, Arguments)[0].I32 = 91,
      'an object handed to the host survives while exposed');
    Check(WasmClassifyReference(Host.Store, Made[0].Reference, Made[0].ValueType) = rkStruct,
      'WasmClassifyReference: a struct');
    Check(WasmStructGetField(Host.Store, Made[0].Reference, 0).I32 = 91, 'WasmStructGetField');

    { Externrefs inside objects reach the embedder's collector. }
    HostValue := Pointer(PtrUInt($5000));
    SetLength(Arguments, 1);
    Arguments[0] := WasmExternRef(HostValue);
    WasmCall(Test.Export_('keep').Func, Arguments);
    Host.Visited.Clear;
    Host.Store.EnumerateReferences(@Host.Visit);
    Check(Host.VisitedCount(HostValue) = 1, 'EnumerateReferences finds an externref held by a struct in a global');
    Test.Call('drop_kept', []);
    WasmForgetExposed(Host.Store);
    WasmCollectGarbage(Host.Store);
    Host.Visited.Clear;
    Host.Store.EnumerateReferences(@Host.Visit);
    Check(Host.VisitedCount(HostValue) = 0, 'and no longer once the struct is unreachable');
  finally
    Test.Free;
    Host.Store.Free;
  end;
end;

procedure TestHostTrace(Host: THost);
var
  Imports: TWasmExternalArray;
  Test: TTestModule;
  Box: TWasmValueArray;
  Arguments: TWasmValueArray;
  HostValue: Pointer;
  Before: Integer;
begin
  Host.Store := NewTestStore;
  SetLength(Imports, 1);
  Imports[0] := FunctionExternal(WasmNewHostFunction(Host.Store, MakeFunctionType([], []), @Host.Collect));
  Test := TTestModule.CreateWithImports(StrPas(CollectorModule), Host.Store, Imports);
  try
    HostValue := Pointer(PtrUInt($7000));
    SetLength(Arguments, 1);
    Arguments[0] := WasmExternRef(HostValue);
    Box := WasmCall(Test.Export_('box').Func, Arguments);
    Before := Host.Store.Heap.ObjectCount;
    { The host's marking reaches its wrapper of the box: the box lives,
      and the externref inside it is reported back. }
    Host.Visited.Clear;
    Host.Store.BeginHostTrace(@Host.Visit);
    Check(Host.VisitedCount(HostValue) = 0, 'host trace: the store alone does not reach the box');
    Host.Store.TraceFromHost(Box[0].Reference, @Host.Visit);
    Check(Host.VisitedCount(HostValue) = 1, 'host trace: tracing the box reports its externref');
    Host.Store.EndHostTrace;
    Check(Host.Store.Heap.ObjectCount = Before, 'host trace: the traced box survives');
    Check(WasmStructGetField(Host.Store, Box[0].Reference, 0).Reference = HostValue, 'and still holds its value');
    { A trace that does not reach it: the box goes. }
    Host.Store.BeginHostTrace(@Host.Visit);
    Host.Store.EndHostTrace;
    Check(Host.Store.Heap.ObjectCount = Before - 1, 'host trace: a box the host no longer reaches is freed');
    { Pinned objects live without traces. }
    Box := WasmCall(Test.Export_('box').Func, Arguments);
    WasmPin(Host.Store, Box[0].Reference);
    Host.Store.BeginHostTrace(@Host.Visit);
    Host.Store.EndHostTrace;
    Check(Host.Store.Heap.IsObject(Box[0].Reference), 'a pinned object survives a host trace');
    WasmUnpin(Host.Store, Box[0].Reference);
    Host.Store.BeginHostTrace(@Host.Visit);
    Host.Store.EndHostTrace;
    Check(not Host.Store.Heap.IsObject(Box[0].Reference), 'and goes once unpinned');
  finally
    Test.Free;
    Host.Store.Free;
  end;
end;

procedure TestReferenceInterface;
var
  Store: TWasmStore;
  Boxed, I31: Pointer;
begin
  Store := NewTestStore;
  try
    I31 := WasmMakeI31(-123);
    Check((WasmI31Value(I31) = -123) and (WasmI31Value(I31, False) = $7FFFFF85), 'i31 values through the interface');
    Check(WasmClassifyReference(Store, I31, MakeReferenceType(HeapTypeAny)) = rkI31, 'an i31 is classified');
    Boxed := WasmInternalize(Store, Pointer(PtrUInt($9000)));
    Check(WasmClassifyReference(Store, Boxed, MakeReferenceType(HeapTypeAny)) = rkBoxedHostValue,
      'a host value internalized is boxed');
    Check(WasmExternalize(Store, Boxed) = Pointer(PtrUInt($9000)), 'and externalizes back to itself');
    Check(WasmInternalize(Store, I31) = I31, 'an i31 internalizes as itself');
    Check(WasmValueMatchesType(Store, WasmReference(MakeReferenceType(HeapTypeAny), I31),
      MakeReferenceType(HeapTypeEq, False)), 'an i31 matches (ref eq)');
    Check(not WasmValueMatchesType(Store, WasmReference(MakeReferenceType(HeapTypeAny), Boxed),
      MakeReferenceType(HeapTypeEq)), 'a boxed host value does not match eqref');
  finally
    Store.Free;
  end;
end;

procedure TestExceptionsAcrossTheHost(Host: THost);
var
  Store: TWasmStore;
  Imports: TWasmExternalArray;
  Test: TTestModule;
  Tag, JsTag: TWasmTag;
  Caught: Boolean;
  Payload: TWasmValueArray;
begin
  Store := NewTestStore;
  Host.Store := Store;
  try
    Tag := WasmNewTag(Store, MakeFunctionType([WasmI32Type], []));
    JsTag := WasmNewTag(Store, MakeFunctionType([WasmExternRefType], []));
    Host.Tag := Tag;
    Host.JsTag := JsTag;
    SetLength(Imports, 5);
    FillChar(Imports[0], SizeOf(TWasmExternal) * 5, 0);
    Imports[0].Kind := ekTag;
    Imports[0].Tag := Tag;
    Imports[1].Kind := ekTag;
    Imports[1].Tag := JsTag;
    Imports[2] := FunctionExternal(WasmNewHostFunction(Store, MakeFunctionType([WasmI32Type], []), @Host.Throw));
    Imports[3] := FunctionExternal(WasmNewHostFunction(Store, MakeFunctionType([WasmI32Type], []), @Host.CallInner));
    Imports[4] := FunctionExternal(WasmNewHostFunction(Store, MakeFunctionType([], []), @Host.ThrowJs));
    Test := TTestModule.CreateWithImports(
      '(module' +
      '  (import "host" "tag" (tag $e (param i32)))' +
      '  (import "host" "js" (tag $js (param externref)))' +
      '  (import "host" "throw" (func $host_throw (param i32)))' +
      '  (import "host" "call_inner" (func $call_inner (param i32)))' +
      '  (import "host" "throw_js" (func $throw_js))' +
      '  (func (export "inner") (param i32) (throw $e (local.get 0)))' +
      '  (func (export "escape") (param i32) (throw $e (local.get 0)))' +
      '  (func (export "from_host") (param i32) (result i32)' +
      '    (block $caught (result i32)' +
      '      (try_table (catch $e $caught) (call $host_throw (local.get 0)))' +
      '      (i32.const -1)))' +
      '  (func (export "through_host") (param i32) (result i32)' +
      '    (block $caught (result i32)' +
      '      (try_table (catch $e $caught) (call $call_inner (local.get 0)))' +
      '      (i32.const -1)))' +
      '  (func (export "js") (result i32)' +
      '    (block $caught (result externref)' +
      '      (try_table (catch $e 1) (catch $js $caught) (call $throw_js))' +
      '      (ref.null extern))' +
      '    (ref.is_null))' +
      '  (func (export "js_all") (result i32)' +
      '    (block $caught' +
      '      (try_table (catch_all $caught) (call $throw_js))' +
      '      (return (i32.const 0)))' +
      '    (i32.const 1)))', Store, Imports);
    try
      Host.Inner := Test.Export_('inner').Func;
      Caught := False;
      try
        Test.Call('escape', [WasmI32(31)]);
      except
        on E: EWasmException do
        begin
          Payload := E.Payload;
          Caught := (E.Tag = Tag) and (Length(Payload) = 1) and (Payload[0].I32 = 31);
        end;
      end;
      Check(Caught, 'an uncaught exception reaches the host as EWasmException with its tag and payload');
      Check(Store.Heap.PinnedCount = 0, 'and unpins its exception once handled');
      Check(Test.CallI32('from_host', [WasmI32(21)]) = 42, 'a host function throws into WebAssembly (WasmThrow)');
      Check(Test.CallI32('through_host', [WasmI32(8)]) = 8,
        'an exception passes through a host function between WebAssembly frames');
      Check(Test.CallI32('js', []) = 0, 'a host exception with the JS tag is caught by catch $js with its value');
      Check(Test.CallI32('js_all', []) = 1, 'and by catch_all');
      SetLength(Payload, 1);
      Payload[0] := WasmExternRef(Pointer(PtrUInt($100)));
      Check(WasmExceptionPayload(WasmNewException(Store, JsTag, Payload))[0].Reference = Pointer(PtrUInt($100)),
        'WasmNewException and WasmExceptionPayload with a host tag');
    finally
      Test.Free;
    end;
  finally
    Store.Free;
  end;
end;

procedure MeasureAllocation;
var
  Store: TWasmStore;
  Test: TTestModule;
  Started: QWord;
  Milliseconds: Int64;
begin
  Store := TWasmStore.Create;
  Test := TTestModule.Create(
    '(module (type $pair (struct (field i32) (field (ref null $pair))))' +
    '  (func (export "run") (param $n i32) (result i32)' +
    '    (local $p (ref null $pair))' +
    '    (loop $l' +
    '      (local.set $p (struct.new $pair (local.get $n) (local.get $p)))' +
    '      (if (i32.eqz (i32.and (local.get $n) (i32.const 1023))) (then (local.set $p (ref.null $pair))))' +
    '      (local.set $n (i32.sub (local.get $n) (i32.const 1)))' +
    '      (br_if $l (local.get $n)))' +
    '    (i32.const 0)))', Store);
  try
    Started := GetTickCount64;
    Test.Call('run', [WasmI32(2000000)]);
    Milliseconds := GetTickCount64 - Started;
    if Milliseconds < 1 then
      Milliseconds := 1;
    WriteLn(Format('perf gc: 2 million structs in %d ms, %.1f million a second, %d collections',
      [Milliseconds, 2000 / Milliseconds, Store.Heap.Collections]));
  finally
    Test.Free;
    Store.Free;
  end;
end;

procedure RunCollectorTests;
var
  Host: THost;
begin
  Host := THost.Create;
  Host.Visited := TList.Create;
  try
    TestSurvival(Host);
    TestHostTrace(Host);
    TestReferenceInterface;
    TestExceptionsAcrossTheHost(Host);
    MeasureAllocation;
  finally
    Host.Visited.Free;
    Host.Free;
  end;
end;

end.
