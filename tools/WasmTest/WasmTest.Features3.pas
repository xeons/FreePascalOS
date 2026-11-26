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
  WasmTest: one small module for each WebAssembly 3.0 feature area that
  needs no host interplay: tail calls (a million deep without growing
  the frames), multiple memories, memory64 and table64, extended
  constant expressions, typed function references with non-nullable
  locals, the struct, array, i31 and cast instructions, relaxed SIMD,
  and exceptions caught inside WebAssembly (try_table and the legacy
  try, catch, rethrow and delegate). Exceptions and objects crossing to
  the host are WasmTest.Collector's.
}
unit WasmTest.Features3;

{$mode objfpc}
{$H+}

interface

procedure RunFeature3Tests;

implementation

uses
  SysUtils,
  TestChecks,
  Wasm.Types,
  Wasm.Features,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api,
  WasmTest.Support;

procedure TestTailCalls;
var
  Test: TTestModule;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (type $t (func (param i32 i32) (result i32)))' +
    '  (table funcref (elem $even $odd))' +
    '  (func $count (export "count") (param i32 i32) (result i32)' +
    '    (if (result i32) (i32.eqz (local.get 0)) (then (local.get 1))' +
    '      (else (return_call $count (i32.sub (local.get 0) (i32.const 1)) (i32.add (local.get 1) (i32.const 1))))))' +
    '  (func $even (export "even") (param i32 i32) (result i32)' +
    '    (if (result i32) (i32.eqz (local.get 0)) (then (i32.const 1))' +
    '      (else (return_call_indirect (type $t) (i32.sub (local.get 0) (i32.const 1)) (i32.const 0) (i32.const 1)))))' +
    '  (func $odd (param i32 i32) (result i32)' +
    '    (if (result i32) (i32.eqz (local.get 0)) (then (i32.const 0))' +
    '      (else (return_call_ref $t (i32.sub (local.get 0) (i32.const 1)) (i32.const 0) (ref.func $even)))))' +
    '  (elem declare func $even))');
  try
    Check(Test.CallI32('count', [WasmI32(1000000), WasmI32(0)]) = 1000000,
      'return_call: a million calls deep in constant stack');
    Check(Test.CallI32('even', [WasmI32(100001), WasmI32(0)]) = 0, 'return_call_indirect and return_call_ref alternate');
    Check(Test.Store.FrameCount = 0, 'no frames left after tail calls');
  finally
    Test.Free;
  end;
end;

procedure TestMultipleMemories;
var
  Test: TTestModule;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (memory $a 1) (memory $b 1 2)' +
    '  (data (memory $b) (i32.const 8) "\2a")' +
    '  (func (export "store") (param i32 i32) (i32.store $b (local.get 0) (local.get 1)))' +
    '  (func (export "load") (param i32) (result i32) (i32.load $b (local.get 0)))' +
    '  (func (export "load0") (param i32) (result i32) (i32.load $a (local.get 0)))' +
    '  (func (export "copy") (memory.copy $a $b (i32.const 0) (i32.const 0) (i32.const 16)))' +
    '  (func (export "grow") (result i32) (memory.grow $b (i32.const 1)))' +
    '  (func (export "size") (result i32) (memory.size $b)))');
  try
    Check(Test.CallI32('load', [WasmI32(8)]) = 42, 'multiple memories: data segment into memory 1');
    Test.Call('store', [WasmI32(4), WasmI32(1234)]);
    Check((Test.CallI32('load', [WasmI32(4)]) = 1234) and (Test.CallI32('load0', [WasmI32(4)]) = 0),
      'multiple memories: stores go to their memory');
    Test.Call('copy', []);
    Check(Test.CallI32('load0', [WasmI32(4)]) = 1234, 'memory.copy between memories');
    Check((Test.CallI32('grow', []) = 1) and (Test.CallI32('size', []) = 2) and (Test.CallI32('grow', []) = -1),
      'memory.grow and memory.size of memory 1, within its maximum');
    Check(Test.TrapOf('load', [WasmI32(2 * 65536)]) = tkMemoryOutOfBounds, 'memory 1 bounds');
  finally
    Test.Free;
  end;
end;

procedure TestMemory64;
var
  Test: TTestModule;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (memory i64 1)' +
    '  (table $t i64 2 funcref)' +
    '  (func $seven (result i32) (i32.const 7))' +
    '  (elem (table $t) (i64.const 1) func $seven)' +
    '  (func (export "store") (param i64 i64) (i64.store offset=8 (local.get 0) (local.get 1)))' +
    '  (func (export "load") (param i64) (result i64) (i64.load offset=8 (local.get 0)))' +
    '  (func (export "grow") (param i64) (result i64) (memory.grow (local.get 0)))' +
    '  (func (export "call") (param i64) (result i32) (call_indirect $t (result i32) (local.get 0)))' +
    '  (func (export "tsize") (result i64) (table.size $t)))');
  try
    Test.Call('store', [WasmI64(100), WasmI64($123456789ABC)]);
    Check(Test.CallI64('load', [WasmI64(100)]) = $123456789ABC, 'memory64: i64 addresses');
    Check(Test.TrapOf('load', [WasmI64(Int64($FFFFFFFFFFFFFFFC))]) = tkMemoryOutOfBounds,
      'memory64: address plus offset past 2^64 traps without overflow');
    Check(Test.TrapOf('load', [WasmI64(Int64(1) shl 40)]) = tkMemoryOutOfBounds, 'memory64: address past 4 GiB traps');
    Check(Test.CallI64('grow', [WasmI64(1)]) = 1, 'memory64: memory.grow takes and gives i64');
    Check(Test.CallI64('grow', [WasmI64(Int64(1) shl 40)]) = -1, 'memory64: an impossible grow gives -1');
    Check((Test.CallI32('call', [WasmI64(1)]) = 7) and (Test.CallI64('tsize', []) = 2),
      'table64: call_indirect and table.size with i64');
    Check(Test.TrapOf('call', [WasmI64(Int64(1) shl 33)]) = tkUndefinedElement, 'table64: index past the table');
  finally
    Test.Free;
  end;
end;

procedure TestConstantsAndReferences;
var
  Test: TTestModule;
  Message: AnsiString;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (global $base i32 (i32.const 40))' +
    '  (global $sum i32 (i32.add (global.get $base) (i32.mul (i32.const 1) (i32.const 2))))' +
    '  (type $binary (func (param i32 i32) (result i32)))' +
    '  (func $add (type $binary) (i32.add (local.get 0) (local.get 1)))' +
    '  (elem declare func $add)' +
    '  (func (export "sum") (result i32) (global.get $sum))' +
    '  (func (export "call_ref") (param i32) (result i32)' +
    '    (local $f (ref $binary))' +
    '    (local.set $f (ref.func $add))' +
    '    (call_ref $binary (local.get 0) (i32.const 1) (local.get $f)))' +
    '  (func (export "on_null") (param i32) (result i32)' +
    '    (block $null' +
    '      (return (call_ref $binary (i32.const 2) (i32.const 3)' +
    '        (br_on_null $null (select (result (ref null $binary)) (ref.func $add) (ref.null $binary) (local.get 0))))))' +
    '    (i32.const -1))' +
    '  (func (export "as_non_null") (drop (ref.as_non_null (ref.null func)))))');
  try
    Check(Test.CallI32('sum', []) = 42, 'extended constant expressions: global.get, i32.add, i32.mul');
    Check(Test.CallI32('call_ref', [WasmI32(41)]) = 42, 'call_ref through a non-nullable local');
    Check((Test.CallI32('on_null', [WasmI32(1)]) = 5) and (Test.CallI32('on_null', [WasmI32(0)]) = -1),
      'br_on_null');
    Check(Test.TrapOf('as_non_null', []) = tkNullReference, 'ref.as_non_null of null traps');
  finally
    Test.Free;
  end;
  Check(CompileFailure(WatBytes('(module (func (local (ref func)) (drop (local.get 0))))'), Message) = 'EWasmInvalid',
    'a non-nullable local read before it is set is invalid');
  Check(CompileFailure(WatBytes('(module (type $s (struct)) (type $t (sub $s (struct))))'), Message) = 'EWasmInvalid',
    'a final type cannot be a supertype');
end;

procedure TestAggregates;
var
  Test: TTestModule;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (type $point (sub (struct (field $x (mut i32)) (field $y (mut i32)))))' +
    '  (type $point3 (sub final $point (struct (field $x (mut i32)) (field $y (mut i32)) (field $z i8))))' +
    '  (type $bytes (array (mut i8)))' +
    '  (type $refs (array (mut anyref)))' +
    '  (data $d "\01\02\03\fe")' +
    '  (func (export "struct") (result i32)' +
    '    (local $p (ref $point))' +
    '    (local.set $p (struct.new $point3 (i32.const 3) (i32.const 4) (i32.const -1)))' +
    '    (struct.set $point $x (local.get $p) (i32.const 30))' +
    '    (i32.add (struct.get $point $x (local.get $p))' +
    '      (i32.add (struct.get $point $y (local.get $p))' +
    '        (struct.get_s $point3 $z (ref.cast (ref $point3) (local.get $p))))))' +
    '  (func (export "array") (result i32)' +
    '    (local $a (ref $bytes)) (local $b (ref $bytes))' +
    '    (local.set $a (array.new_data $bytes $d (i32.const 0) (i32.const 4)))' +
    '    (local.set $b (array.new_default $bytes (i32.const 8)))' +
    '    (array.fill $bytes (local.get $b) (i32.const 0) (i32.const 9) (i32.const 8))' +
    '    (array.copy $bytes $bytes (local.get $b) (i32.const 2) (local.get $a) (i32.const 1) (i32.const 3))' +
    '    (i32.add (i32.add (array.get_u $bytes (local.get $b) (i32.const 4)) (array.get_s $bytes (local.get $b) (i32.const 4)))' +
    '      (i32.add (array.get_u $bytes (local.get $b) (i32.const 7)) (array.len (local.get $b)))))' +
    '  (func (export "out_of_bounds") (drop (array.get_u $bytes (array.new_default $bytes (i32.const 2)) (i32.const 2))))' +
    '  (func (export "casts") (param i32) (result i32)' +
    '    (local $r anyref)' +
    '    (local.set $r (select (result anyref) (ref.i31 (i32.const -5)) (struct.new_default $point) (local.get 0)))' +
    '    (block $is_struct (result (ref $point))' +
    '      (return (i31.get_s (ref.cast i31ref (br_on_cast $is_struct anyref (ref $point) (local.get $r))))))' +
    '    (drop) (i32.const 100))' +
    '  (func (export "test") (result i32)' +
    '    (i32.add (ref.test (ref eq) (ref.i31 (i32.const 1)))' +
    '      (i32.add (ref.test (ref struct) (array.new_fixed $refs 0))' +
    '        (ref.test (ref null $point3) (ref.null none)))))' +
    '  (func (export "bad_cast") (drop (ref.cast (ref $point3) (struct.new_default $point)))))');
  try
    Check(Test.CallI32('struct', []) = 33, 'struct.new of a subtype, struct.set, struct.get, get_s of a packed field');
    Check(Test.CallI32('array', []) = 254 - 2 + 9 + 8, 'array.new_data, fill, copy, get_u / get_s and len');
    Check(Test.TrapOf('out_of_bounds', []) = tkArrayOutOfBounds, 'array index past the end traps');
    Check((Test.CallI32('casts', [WasmI32(1)]) = -5) and (Test.CallI32('casts', [WasmI32(0)]) = 100),
      'br_on_cast, ref.cast and i31.get_s');
    Check(Test.CallI32('test', []) = 2, 'ref.test of eq, struct and a nullable concrete type');
    Check(Test.TrapOf('bad_cast', []) = tkCastFailure, 'a cast to a subtype the object is not traps');
  finally
    Test.Free;
  end;
end;

procedure TestRelaxedSimd;
var
  Test: TTestModule;
  Result_: TWasmValueArray;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (func (export "madd") (result v128)' +
    '    (f32x4.relaxed_madd (v128.const f32x4 0x1.000002p+0 0 0 0) (v128.const f32x4 0x1.000002p+0 0 0 0)' +
    '      (v128.const f32x4 -0x1.000004p+0 0 0 0)))' +
    '  (func (export "laneselect") (result v128)' +
    '    (i8x16.relaxed_laneselect (v128.const i64x2 -1 -1) (v128.const i64x2 0 0) (v128.const i64x2 0xff 0))))');
  try
    Result_ := Test.Call('madd', []);
    Check(Result_[0].V128.DWords[0] = 0, 'relaxed_madd rounds the product first (deterministic profile)');
    Result_ := Test.Call('laneselect', []);
    Check((Result_[0].V128.QWords[0] = $FF) and (Result_[0].V128.QWords[1] = 0), 'relaxed_laneselect is bitselect');
  finally
    Test.Free;
  end;
end;

procedure TestExceptionsInside;
var
  Test: TTestModule;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (tag $e (param i32))' +
    '  (tag $other)' +
    '  (func $thrower (param i32) (throw $e (local.get 0)))' +
    '  (func (export "catch") (param i32) (result i32)' +
    '    (block $caught (result i32)' +
    '      (try_table (catch $e $caught) (call $thrower (local.get 0)))' +
    '      (i32.const -1)))' +
    '  (func (export "rethrow_ref") (result i32)' +
    '    (block $outer (result i32)' +
    '      (try_table (catch $e $outer)' +
    '        (block $inner (result exnref)' +
    '          (try_table (catch_all_ref $inner) (call $thrower (i32.const 9)))' +
    '          (unreachable))' +
    '        (throw_ref))' +
    '      (i32.const -1)))' +
    '  (func (export "legacy") (param i32) (result i32)' +
    '    (try (result i32)' +
    '      (do (try (result i32)' +
    '        (do (call $thrower (local.get 0)) (i32.const 0))' +
    '        (catch $other (i32.const -2))' +
    '        (catch $e (drop) (rethrow 0))))' +
    '      (catch $e (i32.const 100) (i32.add))))' +
    '  (func (export "delegate") (result i32)' +
    '    (try $t (result i32)' +
    '      (do (try (result i32) (do (throw $e (i32.const 5))) (delegate $t)))' +
    '      (catch $e)))' +
    '  (func (export "trap") (result i32)' +
    '    (block $caught' +
    '      (try_table (catch_all $caught) (unreachable)))' +
    '    (i32.const -1)))');
  try
    Check(Test.CallI32('catch', [WasmI32(42)]) = 42, 'try_table catches a throw from a callee with its payload');
    Check(Test.CallI32('rethrow_ref', []) = 9, 'catch_all_ref and throw_ref pass the exception on');
    Check(Test.CallI32('legacy', [WasmI32(7)]) = 107, 'legacy try, catch and rethrow');
    Check(Test.CallI32('delegate', []) = 5, 'legacy delegate to an outer try');
    Check(Test.TrapOf('trap', []) = tkUnreachable, 'catch_all does not catch traps');
  finally
    Test.Free;
  end;
end;

procedure TestFeatureSwitch;
var
  Message: AnsiString;
  Module: TWasmModule;
begin
  Message := '';
  try
    Module := WasmCompile(WatBytes('(module (memory 1) (memory 1))'), WasmFeatures20);
    Module.Release;
  except
    on E: EWasmInvalid do
      Message := E.Message;
  end;
  Check(Message = 'multiple memories', 'without the 3.0 features a second memory is invalid');
  Check(CompileFailure(WatBytes('(module (memory 1) (memory 1))'), Message) = '', 'with them it is valid');
end;

procedure RunFeature3Tests;
begin
  TestTailCalls;
  TestMultipleMemories;
  TestMemory64;
  TestConstantsAndReferences;
  TestAggregates;
  TestRelaxedSimd;
  TestExceptionsInside;
  TestFeatureSwitch;
end;

end.
