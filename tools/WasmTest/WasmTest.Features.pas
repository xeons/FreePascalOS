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
  WasmTest: decoding and validation errors, and one small module for
  each feature area of WebAssembly 2.0 (numbers, control with multiple
  values, bulk memory, reference types, SIMD) with the traps each can
  raise.
}
unit WasmTest.Features;

{$mode objfpc}
{$H+}

interface

procedure RunFeatureTests;

implementation

uses
  SysUtils,
  TestChecks,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Runtime,
  Wasm.Api,
  WasmTest.Support;

procedure TestDecoding;
var
  Message: AnsiString;
  Bytes: TBytes;
begin
  Bytes := TBytes.Create(0, $61, $73, $6E, 1, 0, 0, 0);
  Check(CompileFailure(Bytes, Message) = 'EWasmMalformed', 'bad magic is malformed');
  Bytes := TBytes.Create(0, $61, $73, $6D, 2, 0, 0, 0);
  Check(CompileFailure(Bytes, Message) = 'EWasmMalformed', 'unknown version is malformed');
  { A type section whose count is a six byte LEB128. }
  Bytes := TBytes.Create(0, $61, $73, $6D, 1, 0, 0, 0, 1, 6, $80, $80, $80, $80, $80, 0);
  Check((CompileFailure(Bytes, Message) = 'EWasmMalformed') and (Message = 'integer representation too long'),
    'overlong LEB128 is malformed: ' + Message);
  Bytes := TBytes.Create(0, $61, $73, $6D, 1, 0, 0, 0, 1, 5, 1, $60, 0);
  Check(CompileFailure(Bytes, Message) = 'EWasmMalformed', 'truncated section is malformed');
  Bytes := TBytes.Create(0, $61, $73, $6D, 1, 0, 0, 0);
  Check(CompileFailure(Bytes, Message) = '', 'empty module compiles');
  Check(CompileFailure(WatBytes('(module (func (result i32) (i64.const 1)))'), Message) = 'EWasmInvalid',
    'result type mismatch is invalid');
  Check(Message = 'type mismatch', 'message: type mismatch (' + Message + ')');
  Check(CompileFailure(WatBytes('(module (func (local.get 3)))'), Message) = 'EWasmInvalid', 'unknown local is invalid');
  Check(Pos('unknown local', Message) = 1, 'message: unknown local (' + Message + ')');
  Check(CompileFailure(WatBytes('(module (global i32 (i32.const 0)) (func (global.set 0 (i32.const 1))))'),
    Message) = 'EWasmInvalid', 'setting an immutable global is invalid');
  Check(CompileFailure(WatBytes('(module (func (block (result i32) (br 0)) (drop)))'), Message) = 'EWasmInvalid',
    'branch without its value is invalid');
  Check(CompileFailure(WatBytes('(module (func unreachable (i32.add) (drop)))'), Message) = '',
    'unreachable code is polymorphic');
  Check(not WasmValidate(TBytes.Create(1, 2, 3)), 'WasmValidate rejects junk');
end;

procedure TestNumbers;
var
  Test: TTestModule;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (func (export "div") (param i32 i32) (result i32) (i32.div_s (local.get 0) (local.get 1)))' +
    '  (func (export "rem") (param i32 i32) (result i32) (i32.rem_s (local.get 0) (local.get 1)))' +
    '  (func (export "rotl") (param i64 i64) (result i64) (i64.rotl (local.get 0) (local.get 1)))' +
    '  (func (export "shl") (param i32 i32) (result i32) (i32.shl (local.get 0) (local.get 1)))' +
    '  (func (export "clz") (param i64) (result i64) (i64.clz (local.get 0)))' +
    '  (func (export "trunc") (param f64) (result i32) (i32.trunc_f64_s (local.get 0)))' +
    '  (func (export "sat") (param f32) (result i64) (i64.trunc_sat_f32_u (local.get 0)))' +
    '  (func (export "nearest") (param f32) (result f32) (f32.nearest (local.get 0)))' +
    '  (func (export "min") (param f64 f64) (result f64) (f64.min (local.get 0) (local.get 1)))' +
    '  (func (export "convert") (param i64) (result f32) (f32.convert_i64_u (local.get 0)))' +
    '  (func (export "ext") (param i32) (result i64) (i64.extend8_s (i64.extend_i32_u (local.get 0))))' +
    ')');
  try
    Check(Test.CallI32('div', [WasmI32(-7), WasmI32(2)]) = -3, 'i32.div_s truncates');
    Check(Test.TrapOf('div', [WasmI32(1), WasmI32(0)]) = tkIntegerDivideByZero, 'i32.div_s by zero traps');
    Check(Test.TrapOf('div', [WasmI32(Low(Int32)), WasmI32(-1)]) = tkIntegerOverflow, 'i32.div_s overflow traps');
    Check(Test.CallI32('rem', [WasmI32(Low(Int32)), WasmI32(-1)]) = 0, 'i32.rem_s of the lowest by -1 is 0');
    Check(Test.CallI64('rotl', [WasmI64($0123456789ABCDEF), WasmI64(68)]) = Int64($123456789ABCDEF0), 'i64.rotl modulo 64');
    Check(Test.CallI32('shl', [WasmI32(1), WasmI32(33)]) = 2, 'i32.shl modulo 32');
    Check(Test.CallI64('clz', [WasmI64(0)]) = 64, 'i64.clz of zero');
    Check(Test.CallI32('trunc', [WasmF64(-2147483648.9)]) = Low(Int32), 'i32.trunc_f64_s at the lower edge');
    Check(Test.TrapOf('trunc', [WasmF64(2147483648.0)]) = tkIntegerOverflow, 'i32.trunc_f64_s out of range traps');
    Check(Test.TrapOf('trunc', [WasmF64FromBits($7FF8000000000000)]) = tkInvalidConversion, 'i32.trunc_f64_s of NaN traps');
    Check(QWord(Test.CallI64('sat', [WasmF32(1e30)])) = High(QWord), 'i64.trunc_sat_f32_u saturates');
    Check(Test.Call('nearest', [WasmF32(2.5)])[0].F32Bits = $40000000, 'f32.nearest rounds half to even');
    Check(Test.Call('nearest', [WasmF32(-0.4)])[0].F32Bits = $80000000, 'f32.nearest keeps the sign of zero');
    Check(Test.Call('min', [WasmF64(0.0), WasmF64FromBits(QWord($8000000000000000))])[0].F64Bits = QWord($8000000000000000),
      'f64.min orders -0 below +0');
    Check(Test.Call('min', [WasmF64(1.0), WasmF64FromBits($7FF4000000000000)])[0].F64Bits and $7FF8000000000000 =
      $7FF8000000000000, 'f64.min of a NaN is a quiet NaN');
    { 2^64 - 1 rounds to 2^64 in single precision, through double it could round differently. }
    Check(Test.Call('convert', [WasmI64(Int64($FFFFFFFFFFFFFFFF))])[0].F32Bits = $5F800000, 'f32.convert_i64_u');
    Check(Test.Call('convert', [WasmI64($0020000020000001)])[0].F32Bits = $5A000001,
      'f32.convert_i64_u rounds once');
    Check(Test.CallI64('ext', [WasmI32($80)]) = -128, 'i64.extend8_s');
  finally
    Test.Free;
  end;
end;

procedure TestControl;
var
  Test: TTestModule;
  Results: TWasmValueArray;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (type $pair (func (param i32 i32) (result i32 i32)))' +
    '  (func (export "swap") (param i32 i32) (result i32 i32)' +
    '    (local.get 0) (local.get 1) (block (type $pair) (local.set 0) (local.set 1) (local.get 0) (local.get 1)))' +
    '  (func (export "sum") (param i32) (result i32) (local i32)' +
    '    (block (loop' +
    '      (br_if 1 (i32.eqz (local.get 0)))' +
    '      (local.set 1 (i32.add (local.get 1) (local.get 0)))' +
    '      (local.set 0 (i32.sub (local.get 0) (i32.const 1)))' +
    '      (br 0)))' +
    '    (local.get 1))' +
    '  (func (export "switch") (param i32) (result i32)' +
    '    (block (block (block (br_table 0 1 2 (local.get 0))) (return (i32.const 10))) (return (i32.const 11)))' +
    '    (i32.const 12))' +
    '  (func (export "select") (param i32) (result i64) (select (i64.const 5) (i64.const 6) (local.get 0)))' +
    '  (func $fac (export "fac") (param i64) (result i64)' +
    '    (if (result i64) (i64.eqz (local.get 0)) (then (i64.const 1))' +
    '      (else (i64.mul (local.get 0) (call $fac (i64.sub (local.get 0) (i64.const 1)))))))' +
    '  (func $deep (export "deep") (param i32) (result i32) (i32.add (call $deep (local.get 0)) (i32.const 1)))' +
    '  (func (export "crash") (call $inner))' +
    '  (func $inner unreachable)' +
    ')');
  try
    Results := Test.Call('swap', [WasmI32(1), WasmI32(2)]);
    Check((Length(Results) = 2) and (Results[0].I32 = 2) and (Results[1].I32 = 1), 'multi-value block');
    Check(Test.CallI32('sum', [WasmI32(100)]) = 5050, 'loop with br_if');
    Check((Test.CallI32('switch', [WasmI32(0)]) = 10) and (Test.CallI32('switch', [WasmI32(2)]) = 12) and
      (Test.CallI32('switch', [WasmI32(99)]) = 12), 'br_table with its default');
    Check((Test.CallI64('select', [WasmI32(1)]) = 5) and (Test.CallI64('select', [WasmI32(0)]) = 6), 'select');
    Check(Test.CallI64('fac', [WasmI64(20)]) = 2432902008176640000, 'recursive factorial');
    Check(Test.TrapOf('deep', [WasmI32(0)]) = tkCallStackExhausted, 'runaway recursion: call stack exhausted');
    Check(Test.CallI64('fac', [WasmI64(5)]) = 120, 'the store works after exhaustion');
    try
      Test.Call('crash', []);
      Check(False, 'unreachable traps');
    except
      on E: EWasmTrap do
      begin
        Check(E.Kind = tkUnreachable, 'unreachable traps');
        Check((Length(E.StackTrace) = 2) and (E.StackTrace[0].FunctionIndex = 7) and
          (E.StackTrace[1].FunctionIndex = 6) and (E.StackTrace[0].ByteOffset > 0), 'trap stack trace: ' +
          Trim(Copy(E.StackTraceText, 1, Pos(LineEnding, E.StackTraceText))));
      end;
    end;
  finally
    Test.Free;
  end;
end;

procedure TestBulkMemory;
var
  Test: TTestModule;
  Memory: TWasmMemory;
begin
  Test := TTestModule.Create(
    '(module (memory (export "memory") 1)' +
    '  (data $hello "hello")' +
    '  (data (i32.const 100) "\01\02\03")' +
    '  (func (export "init") (param i32) (memory.init $hello (local.get 0) (i32.const 0) (i32.const 5)))' +
    '  (func (export "drop") (data.drop $hello))' +
    '  (func (export "fill") (memory.fill (i32.const 10) (i32.const 7) (i32.const 4)))' +
    '  (func (export "copy") (memory.copy (i32.const 101) (i32.const 100) (i32.const 3)))' +
    '  (func (export "load") (param i32) (result i32) (i32.load8_u (local.get 0)))' +
    '  (func (export "load64") (param i32) (result i64) (i64.load offset=8 (local.get 0)))' +
    ')');
  try
    Memory := Test.Export_('memory').Memory;
    Check(Test.CallI32('load', [WasmI32(102)]) = 3, 'active data segment');
    Test.Call('init', [WasmI32(200)]);
    Check(CompareByte(Memory.Data[200], PAnsiChar('hello')^, 5) = 0, 'memory.init');
    Check(Test.TrapOf('init', [WasmI32(65534)]) = tkMemoryOutOfBounds, 'memory.init out of bounds traps');
    Test.Call('fill', []);
    Check((Memory.Data[10] = 7) and (Memory.Data[13] = 7) and (Memory.Data[14] = 0), 'memory.fill');
    Test.Call('copy', []);
    Check((Memory.Data[101] = 1) and (Memory.Data[102] = 2) and (Memory.Data[103] = 3), 'overlapping memory.copy');
    Test.Call('drop', []);
    Check(Test.TrapOf('init', [WasmI32(0)]) = tkMemoryOutOfBounds, 'memory.init of a dropped segment traps');
    Check(Test.TrapOf('load', [WasmI32(65536)]) = tkMemoryOutOfBounds, 'load past the end traps');
    Check(Test.TrapOf('load64', [WasmI32(65528)]) = tkMemoryOutOfBounds, 'offset is part of the bounds check');
    Check(Test.TrapOf('load64', [WasmI32(-1)]) = tkMemoryOutOfBounds, 'addresses are unsigned');
  finally
    Test.Free;
  end;
end;

procedure TestReferences;
var
  Test: TTestModule;
  Table: TWasmTable;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (type $unary (func (param i32) (result i32)))' +
    '  (table $functions (export "functions") 4 funcref)' +
    '  (table $externs (export "externs") 0 externref)' +
    '  (elem (table $functions) (i32.const 0) func $double $nothing)' +
    '  (func $double (type $unary) (i32.mul (local.get 0) (i32.const 2)))' +
    '  (func $nothing)' +
    '  (func (export "call") (param i32 i32) (result i32) (call_indirect (type $unary) (local.get 1) (local.get 0)))' +
    '  (func (export "grow") (param externref i32) (result i32) (table.grow $externs (local.get 0) (local.get 1)))' +
    '  (func (export "get") (param i32) (result externref) (table.get $externs (local.get 0)))' +
    '  (func (export "isnull") (param externref) (result i32) (ref.is_null (local.get 0)))' +
    '  (func (export "funcref") (result funcref) (ref.func $double))' +
    '  (elem declare func $double)' +
    ')');
  try
    Check(Test.CallI32('call', [WasmI32(0), WasmI32(21)]) = 42, 'call_indirect');
    Check(Test.TrapOf('call', [WasmI32(1), WasmI32(0)]) = tkIndirectCallTypeMismatch, 'call_indirect type mismatch traps');
    Check(Test.TrapOf('call', [WasmI32(2), WasmI32(0)]) = tkUninitializedElement, 'call_indirect of null traps');
    Check(Test.TrapOf('call', [WasmI32(4), WasmI32(0)]) = tkUndefinedElement, 'call_indirect past the table traps');
    Check(Test.CallI32('grow', [WasmExternRef(Pointer(1234)), WasmI32(3)]) = 0, 'table.grow returns the old size');
    Table := Test.Export_('externs').Table;
    Check((Table.Size = 3) and (Table.Elements[2] = Pointer(1234)), 'table.grow fills with the value');
    Check(Test.Call('get', [WasmI32(1)])[0].Reference = Pointer(1234), 'table.get of an externref');
    Check(Test.TrapOf('get', [WasmI32(3)]) = tkTableOutOfBounds, 'table.get past the end traps');
    Check((Test.CallI32('isnull', [WasmExternRef(nil)]) = 1) and (Test.CallI32('isnull', [WasmExternRef(Pointer(8))]) = 0),
      'ref.is_null');
    Check(Test.Call('funcref', [])[0].Reference = Pointer(Test.Instance.Functions[0]), 'ref.func is the function instance');
  finally
    Test.Free;
  end;
end;

procedure TestSimd;
var
  Test: TTestModule;
  Results: TWasmValueArray;
begin
  Test := TTestModule.Create(
    '(module' +
    '  (func (export "add") (result v128) (i32x4.add (v128.const i32x4 1 2 3 4) (v128.const i32x4 10 20 30 -1)))' +
    '  (func (export "shuffle") (result v128)' +
    '    (i8x16.shuffle 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 16' +
    '      (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15) (v128.const i8x16 99 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))' +
    '  (func (export "min") (result v128) (f32x4.min (v128.const f32x4 0 -0 nan 1) (v128.const f32x4 -0 0 1 2)))' +
    '  (func (export "lane") (param v128) (result i32) (i16x8.extract_lane_s 3 (local.get 0)))' +
    '  (func (export "sat") (result v128) (i8x16.add_sat_s (v128.const i8x16 120 -120 0 0 0 0 0 0 0 0 0 0 0 0 0 0)' +
    '    (v128.const i8x16 10 -10 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))' +
    ')');
  try
    Results := Test.Call('add', []);
    Check((Results[0].V128.DWords[0] = 11) and (Results[0].V128.DWords[3] = 3), 'i32x4.add wraps');
    Results := Test.Call('shuffle', []);
    Check((Results[0].V128.Bytes[0] = 15) and (Results[0].V128.Bytes[15] = 99), 'i8x16.shuffle');
    Results := Test.Call('min', []);
    Check((Results[0].V128.DWords[0] = $80000000) and (Results[0].V128.DWords[1] = $80000000) and
      (Results[0].V128.DWords[2] and $7FC00000 = $7FC00000) and (Results[0].V128.DWords[3] = $3F800000), 'f32x4.min');
    Results[0].V128.Words[3] := $8001;
    Check(Test.CallI32('lane', [Results[0]]) = -32767, 'i16x8.extract_lane_s');
    Results := Test.Call('sat', []);
    Check((Results[0].V128.Bytes[0] = 127) and (Results[0].V128.Bytes[1] = $80), 'i8x16.add_sat_s');
  finally
    Test.Free;
  end;
end;

procedure RunFeatureTests;
begin
  TestDecoding;
  TestNumbers;
  TestControl;
  TestBulkMemory;
  TestReferences;
  TestSimd;
end;

end.
