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
  The instruction names of the text format and their binary opcodes
  (WebAssembly 3.0: the MVP, sign extension, saturating truncation, bulk
  memory, reference types, fixed width and relaxed SIMD, multiple
  memories, tail calls, typed function references, garbage collection
  and exception handling, plus the legacy exception instructions try,
  catch, catch_all, delegate and rethrow), with the kind of immediates
  each takes in text and, for memory instructions, the natural alignment
  (log2 of the access size) a memarg defaults to.

  Runs of consecutive opcodes are registered from name lists, so the
  table reads like the opcode tables of the specification.
}
unit WasmText.Instructions;

{$mode objfpc}
{$H+}

interface

type
  TImmediateKind = (
    ikNone,
    ikBlock, ikLoop, ikIf, ikElse, ikEnd,
    ikTryTable,       { try_table: block type, catch clauses }
    ikTry,            { legacy try }
    ikCatch,          { legacy catch: tag index }
    ikCatchAll,       { legacy catch_all }
    ikDelegate,       { legacy delegate: label, ends a try }
    ikLabel,          { br, br_if, br_on_null, br_on_non_null, rethrow }
    ikBranchTable,
    ikFunction,       { call }
    ikCallIndirect,
    ikLocal,
    ikGlobal,
    ikTable,          { table.get/set/size/grow/fill: optional table index }
    ikMemoryArgument, { loads and stores: memory index?, offset, alignment }
    ikMemoryIndex,    { memory.size, memory.grow, memory.fill: memory index? }
    ikMemoryCopy,     { two memory indices, or none }
    ikMemoryInit,     { memory index?, data index }
    ikData,           { data.drop }
    ikTableInit,
    ikElement,        { elem.drop }
    ikTableCopy,
    ikInt32, ikInt64, ikFloat32, ikFloat64,
    ikVector,         { v128.const }
    ikShuffle,
    ikLane,
    ikMemoryLane,     { v128.loadN_lane / storeN_lane: memarg and lane }
    ikSelect,
    ikReferenceNull,
    ikReferenceFunction,
    ikTag,            { throw }
    ikType,           { call_ref, struct.new, array.get, ...: type index }
    ikTypeField,      { struct.get, struct.set: type index, field }
    ikTypeCount,      { array.new_fixed: type index, element count }
    ikTypeData,       { array.new_data, array.init_data }
    ikTypeElement,    { array.new_elem, array.init_elem }
    ikTypeType,       { array.copy: destination and source type }
    ikReferenceTest,  { ref.test, ref.cast: reference type; Code is the
                        non-null form's, the nullable one's is Code + 1 }
    ikBranchCast      { br_on_cast, br_on_cast_fail: label, two
                        reference types }
  );

  TInstructionInfo = record
    Prefix: Byte;     { 0 for single byte opcodes, $FB, $FC or $FD }
    Code: Cardinal;
    Immediate: TImmediateKind;
    Alignment: Byte;  { natural alignment (log2) for memory instructions }
  end;

{ False when Name is not an instruction. }
function LookUpInstruction(const Name: AnsiString; out Info: TInstructionInfo): Boolean;

implementation

uses
  Classes,
  SysUtils;

type
  TInstructionEntry = class
    Info: TInstructionInfo;
  end;

var
  InstructionTable: TStringList = nil;

procedure Add(const Name: AnsiString; Prefix: Byte; Code: Cardinal; Immediate: TImmediateKind;
  Alignment: Byte = 0);
var
  Entry: TInstructionEntry;
begin
  Entry := TInstructionEntry.Create;
  Entry.Info.Prefix := Prefix;
  Entry.Info.Code := Code;
  Entry.Info.Immediate := Immediate;
  Entry.Info.Alignment := Alignment;
  InstructionTable.AddObject(Name, Entry);
end;

{ Names[i] gets opcode First + i; an empty name skips an opcode. }
procedure AddRun(const Prefix: AnsiString; const Names: array of AnsiString; OpcodePrefix: Byte;
  First: Cardinal);
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if Names[Index] <> '' then
      Add(Prefix + Names[Index], OpcodePrefix, First + Cardinal(Index), ikNone);
end;

procedure AddMemory(const Name: AnsiString; Prefix: Byte; Code: Cardinal; Alignment: Byte;
  Immediate: TImmediateKind = ikMemoryArgument);
begin
  Add(Name, Prefix, Code, Immediate, Alignment);
end;

procedure AddCoreInstructions;
begin
  Add('unreachable', 0, $00, ikNone);
  Add('nop', 0, $01, ikNone);
  Add('block', 0, $02, ikBlock);
  Add('loop', 0, $03, ikLoop);
  Add('if', 0, $04, ikIf);
  Add('else', 0, $05, ikElse);
  Add('end', 0, $0B, ikEnd);
  Add('br', 0, $0C, ikLabel);
  Add('br_if', 0, $0D, ikLabel);
  Add('br_table', 0, $0E, ikBranchTable);
  Add('return', 0, $0F, ikNone);
  Add('call', 0, $10, ikFunction);
  Add('call_indirect', 0, $11, ikCallIndirect);
  Add('return_call', 0, $12, ikFunction);
  Add('return_call_indirect', 0, $13, ikCallIndirect);
  Add('call_ref', 0, $14, ikType);
  Add('return_call_ref', 0, $15, ikType);
  Add('drop', 0, $1A, ikNone);
  Add('select', 0, $1B, ikSelect);
  Add('try_table', 0, $1F, ikTryTable);
  Add('throw', 0, $08, ikTag);
  Add('throw_ref', 0, $0A, ikNone);
  Add('try', 0, $06, ikTry);
  Add('catch', 0, $07, ikCatch);
  Add('rethrow', 0, $09, ikLabel);
  Add('delegate', 0, $18, ikDelegate);
  Add('catch_all', 0, $19, ikCatchAll);
  Add('local.get', 0, $20, ikLocal);
  Add('local.set', 0, $21, ikLocal);
  Add('local.tee', 0, $22, ikLocal);
  Add('global.get', 0, $23, ikGlobal);
  Add('global.set', 0, $24, ikGlobal);
  Add('table.get', 0, $25, ikTable);
  Add('table.set', 0, $26, ikTable);
  AddMemory('i32.load', 0, $28, 2);
  AddMemory('i64.load', 0, $29, 3);
  AddMemory('f32.load', 0, $2A, 2);
  AddMemory('f64.load', 0, $2B, 3);
  AddMemory('i32.load8_s', 0, $2C, 0);
  AddMemory('i32.load8_u', 0, $2D, 0);
  AddMemory('i32.load16_s', 0, $2E, 1);
  AddMemory('i32.load16_u', 0, $2F, 1);
  AddMemory('i64.load8_s', 0, $30, 0);
  AddMemory('i64.load8_u', 0, $31, 0);
  AddMemory('i64.load16_s', 0, $32, 1);
  AddMemory('i64.load16_u', 0, $33, 1);
  AddMemory('i64.load32_s', 0, $34, 2);
  AddMemory('i64.load32_u', 0, $35, 2);
  AddMemory('i32.store', 0, $36, 2);
  AddMemory('i64.store', 0, $37, 3);
  AddMemory('f32.store', 0, $38, 2);
  AddMemory('f64.store', 0, $39, 3);
  AddMemory('i32.store8', 0, $3A, 0);
  AddMemory('i32.store16', 0, $3B, 1);
  AddMemory('i64.store8', 0, $3C, 0);
  AddMemory('i64.store16', 0, $3D, 1);
  AddMemory('i64.store32', 0, $3E, 2);
  Add('memory.size', 0, $3F, ikMemoryIndex);
  Add('memory.grow', 0, $40, ikMemoryIndex);
  Add('i32.const', 0, $41, ikInt32);
  Add('i64.const', 0, $42, ikInt64);
  Add('f32.const', 0, $43, ikFloat32);
  Add('f64.const', 0, $44, ikFloat64);
  AddRun('i32.', ['eqz', 'eq', 'ne', 'lt_s', 'lt_u', 'gt_s', 'gt_u', 'le_s', 'le_u', 'ge_s', 'ge_u'], 0, $45);
  AddRun('i64.', ['eqz', 'eq', 'ne', 'lt_s', 'lt_u', 'gt_s', 'gt_u', 'le_s', 'le_u', 'ge_s', 'ge_u'], 0, $50);
  AddRun('f32.', ['eq', 'ne', 'lt', 'gt', 'le', 'ge'], 0, $5B);
  AddRun('f64.', ['eq', 'ne', 'lt', 'gt', 'le', 'ge'], 0, $61);
  AddRun('i32.', ['clz', 'ctz', 'popcnt', 'add', 'sub', 'mul', 'div_s', 'div_u', 'rem_s', 'rem_u',
    'and', 'or', 'xor', 'shl', 'shr_s', 'shr_u', 'rotl', 'rotr'], 0, $67);
  AddRun('i64.', ['clz', 'ctz', 'popcnt', 'add', 'sub', 'mul', 'div_s', 'div_u', 'rem_s', 'rem_u',
    'and', 'or', 'xor', 'shl', 'shr_s', 'shr_u', 'rotl', 'rotr'], 0, $79);
  AddRun('f32.', ['abs', 'neg', 'ceil', 'floor', 'trunc', 'nearest', 'sqrt', 'add', 'sub', 'mul', 'div',
    'min', 'max', 'copysign'], 0, $8B);
  AddRun('f64.', ['abs', 'neg', 'ceil', 'floor', 'trunc', 'nearest', 'sqrt', 'add', 'sub', 'mul', 'div',
    'min', 'max', 'copysign'], 0, $99);
  AddRun('', ['i32.wrap_i64', 'i32.trunc_f32_s', 'i32.trunc_f32_u', 'i32.trunc_f64_s', 'i32.trunc_f64_u',
    'i64.extend_i32_s', 'i64.extend_i32_u', 'i64.trunc_f32_s', 'i64.trunc_f32_u', 'i64.trunc_f64_s',
    'i64.trunc_f64_u', 'f32.convert_i32_s', 'f32.convert_i32_u', 'f32.convert_i64_s', 'f32.convert_i64_u',
    'f32.demote_f64', 'f64.convert_i32_s', 'f64.convert_i32_u', 'f64.convert_i64_s', 'f64.convert_i64_u',
    'f64.promote_f32', 'i32.reinterpret_f32', 'i64.reinterpret_f64', 'f32.reinterpret_i32',
    'f64.reinterpret_i64', 'i32.extend8_s', 'i32.extend16_s', 'i64.extend8_s', 'i64.extend16_s',
    'i64.extend32_s'], 0, $A7);
  Add('ref.null', 0, $D0, ikReferenceNull);
  Add('ref.is_null', 0, $D1, ikNone);
  Add('ref.func', 0, $D2, ikReferenceFunction);
  Add('ref.eq', 0, $D3, ikNone);
  Add('ref.as_non_null', 0, $D4, ikNone);
  Add('br_on_null', 0, $D5, ikLabel);
  Add('br_on_non_null', 0, $D6, ikLabel);
end;

procedure AddGarbageCollectionInstructions;
const
  Gc = $FB;
begin
  Add('struct.new', Gc, 0, ikType);
  Add('struct.new_default', Gc, 1, ikType);
  Add('struct.get', Gc, 2, ikTypeField);
  Add('struct.get_s', Gc, 3, ikTypeField);
  Add('struct.get_u', Gc, 4, ikTypeField);
  Add('struct.set', Gc, 5, ikTypeField);
  Add('array.new', Gc, 6, ikType);
  Add('array.new_default', Gc, 7, ikType);
  Add('array.new_fixed', Gc, 8, ikTypeCount);
  Add('array.new_data', Gc, 9, ikTypeData);
  Add('array.new_elem', Gc, 10, ikTypeElement);
  Add('array.get', Gc, 11, ikType);
  Add('array.get_s', Gc, 12, ikType);
  Add('array.get_u', Gc, 13, ikType);
  Add('array.set', Gc, 14, ikType);
  Add('array.len', Gc, 15, ikNone);
  Add('array.fill', Gc, 16, ikType);
  Add('array.copy', Gc, 17, ikTypeType);
  Add('array.init_data', Gc, 18, ikTypeData);
  Add('array.init_elem', Gc, 19, ikTypeElement);
  Add('ref.test', Gc, 20, ikReferenceTest);
  Add('ref.cast', Gc, 22, ikReferenceTest);
  Add('br_on_cast', Gc, 24, ikBranchCast);
  Add('br_on_cast_fail', Gc, 25, ikBranchCast);
  AddRun('', ['any.convert_extern', 'extern.convert_any', 'ref.i31', 'i31.get_s', 'i31.get_u'], Gc, 26);
end;

procedure AddMiscellaneousInstructions;
begin
  AddRun('', ['i32.trunc_sat_f32_s', 'i32.trunc_sat_f32_u', 'i32.trunc_sat_f64_s', 'i32.trunc_sat_f64_u',
    'i64.trunc_sat_f32_s', 'i64.trunc_sat_f32_u', 'i64.trunc_sat_f64_s', 'i64.trunc_sat_f64_u'], $FC, 0);
  Add('memory.init', $FC, 8, ikMemoryInit);
  Add('data.drop', $FC, 9, ikData);
  Add('memory.copy', $FC, 10, ikMemoryCopy);
  Add('memory.fill', $FC, 11, ikMemoryIndex);
  Add('table.init', $FC, 12, ikTableInit);
  Add('elem.drop', $FC, 13, ikElement);
  Add('table.copy', $FC, 14, ikTableCopy);
  Add('table.grow', $FC, 15, ikTable);
  Add('table.size', $FC, 16, ikTable);
  Add('table.fill', $FC, 17, ikTable);
end;

procedure AddVectorInstructions;
const
  Vector = $FD;
begin
  AddMemory('v128.load', Vector, 0, 4);
  AddMemory('v128.load8x8_s', Vector, 1, 3);
  AddMemory('v128.load8x8_u', Vector, 2, 3);
  AddMemory('v128.load16x4_s', Vector, 3, 3);
  AddMemory('v128.load16x4_u', Vector, 4, 3);
  AddMemory('v128.load32x2_s', Vector, 5, 3);
  AddMemory('v128.load32x2_u', Vector, 6, 3);
  AddMemory('v128.load8_splat', Vector, 7, 0);
  AddMemory('v128.load16_splat', Vector, 8, 1);
  AddMemory('v128.load32_splat', Vector, 9, 2);
  AddMemory('v128.load64_splat', Vector, 10, 3);
  AddMemory('v128.store', Vector, 11, 4);
  Add('v128.const', Vector, 12, ikVector);
  Add('i8x16.shuffle', Vector, 13, ikShuffle);
  AddRun('', ['i8x16.swizzle', 'i8x16.splat', 'i16x8.splat', 'i32x4.splat', 'i64x2.splat',
    'f32x4.splat', 'f64x2.splat'], Vector, 14);
  Add('i8x16.extract_lane_s', Vector, 21, ikLane);
  Add('i8x16.extract_lane_u', Vector, 22, ikLane);
  Add('i8x16.replace_lane', Vector, 23, ikLane);
  Add('i16x8.extract_lane_s', Vector, 24, ikLane);
  Add('i16x8.extract_lane_u', Vector, 25, ikLane);
  Add('i16x8.replace_lane', Vector, 26, ikLane);
  Add('i32x4.extract_lane', Vector, 27, ikLane);
  Add('i32x4.replace_lane', Vector, 28, ikLane);
  Add('i64x2.extract_lane', Vector, 29, ikLane);
  Add('i64x2.replace_lane', Vector, 30, ikLane);
  Add('f32x4.extract_lane', Vector, 31, ikLane);
  Add('f32x4.replace_lane', Vector, 32, ikLane);
  Add('f64x2.extract_lane', Vector, 33, ikLane);
  Add('f64x2.replace_lane', Vector, 34, ikLane);
  AddRun('i8x16.', ['eq', 'ne', 'lt_s', 'lt_u', 'gt_s', 'gt_u', 'le_s', 'le_u', 'ge_s', 'ge_u'], Vector, 35);
  AddRun('i16x8.', ['eq', 'ne', 'lt_s', 'lt_u', 'gt_s', 'gt_u', 'le_s', 'le_u', 'ge_s', 'ge_u'], Vector, 45);
  AddRun('i32x4.', ['eq', 'ne', 'lt_s', 'lt_u', 'gt_s', 'gt_u', 'le_s', 'le_u', 'ge_s', 'ge_u'], Vector, 55);
  AddRun('f32x4.', ['eq', 'ne', 'lt', 'gt', 'le', 'ge'], Vector, 65);
  AddRun('f64x2.', ['eq', 'ne', 'lt', 'gt', 'le', 'ge'], Vector, 71);
  AddRun('v128.', ['not', 'and', 'andnot', 'or', 'xor', 'bitselect', 'any_true'], Vector, 77);
  AddMemory('v128.load8_lane', Vector, 84, 0, ikMemoryLane);
  AddMemory('v128.load16_lane', Vector, 85, 1, ikMemoryLane);
  AddMemory('v128.load32_lane', Vector, 86, 2, ikMemoryLane);
  AddMemory('v128.load64_lane', Vector, 87, 3, ikMemoryLane);
  AddMemory('v128.store8_lane', Vector, 88, 0, ikMemoryLane);
  AddMemory('v128.store16_lane', Vector, 89, 1, ikMemoryLane);
  AddMemory('v128.store32_lane', Vector, 90, 2, ikMemoryLane);
  AddMemory('v128.store64_lane', Vector, 91, 3, ikMemoryLane);
  AddMemory('v128.load32_zero', Vector, 92, 2);
  AddMemory('v128.load64_zero', Vector, 93, 3);
  AddRun('', ['f32x4.demote_f64x2_zero', 'f64x2.promote_low_f32x4',
    'i8x16.abs', 'i8x16.neg', 'i8x16.popcnt', 'i8x16.all_true', 'i8x16.bitmask',
    'i8x16.narrow_i16x8_s', 'i8x16.narrow_i16x8_u', 'f32x4.ceil', 'f32x4.floor', 'f32x4.trunc',
    'f32x4.nearest', 'i8x16.shl', 'i8x16.shr_s', 'i8x16.shr_u', 'i8x16.add', 'i8x16.add_sat_s',
    'i8x16.add_sat_u', 'i8x16.sub', 'i8x16.sub_sat_s', 'i8x16.sub_sat_u', 'f64x2.ceil', 'f64x2.floor',
    'i8x16.min_s', 'i8x16.min_u', 'i8x16.max_s', 'i8x16.max_u', 'f64x2.trunc', 'i8x16.avgr_u',
    'i16x8.extadd_pairwise_i8x16_s', 'i16x8.extadd_pairwise_i8x16_u',
    'i32x4.extadd_pairwise_i16x8_s', 'i32x4.extadd_pairwise_i16x8_u'], Vector, 94);
  AddRun('i16x8.', ['abs', 'neg', 'q15mulr_sat_s', 'all_true', 'bitmask', 'narrow_i32x4_s',
    'narrow_i32x4_u', 'extend_low_i8x16_s', 'extend_high_i8x16_s', 'extend_low_i8x16_u',
    'extend_high_i8x16_u', 'shl', 'shr_s', 'shr_u', 'add', 'add_sat_s', 'add_sat_u', 'sub', 'sub_sat_s',
    'sub_sat_u', '', 'mul', 'min_s', 'min_u', 'max_s', 'max_u', '', 'avgr_u', 'extmul_low_i8x16_s',
    'extmul_high_i8x16_s', 'extmul_low_i8x16_u', 'extmul_high_i8x16_u'], Vector, 128);
  Add('f64x2.nearest', Vector, 148, ikNone);
  AddRun('i32x4.', ['abs', 'neg', '', 'all_true', 'bitmask', '', '', 'extend_low_i16x8_s',
    'extend_high_i16x8_s', 'extend_low_i16x8_u', 'extend_high_i16x8_u', 'shl', 'shr_s', 'shr_u', 'add',
    '', '', 'sub', '', '', '', 'mul', 'min_s', 'min_u', 'max_s', 'max_u', 'dot_i16x8_s', '',
    'extmul_low_i16x8_s', 'extmul_high_i16x8_s', 'extmul_low_i16x8_u', 'extmul_high_i16x8_u'], Vector, 160);
  AddRun('i64x2.', ['abs', 'neg', '', 'all_true', 'bitmask', '', '', 'extend_low_i32x4_s',
    'extend_high_i32x4_s', 'extend_low_i32x4_u', 'extend_high_i32x4_u', 'shl', 'shr_s', 'shr_u', 'add',
    '', '', 'sub', '', '', '', 'mul', 'eq', 'ne', 'lt_s', 'gt_s', 'le_s', 'ge_s',
    'extmul_low_i32x4_s', 'extmul_high_i32x4_s', 'extmul_low_i32x4_u', 'extmul_high_i32x4_u'], Vector, 192);
  AddRun('f32x4.', ['abs', 'neg', '', 'sqrt', 'add', 'sub', 'mul', 'div', 'min', 'max', 'pmin', 'pmax'],
    Vector, 224);
  AddRun('f64x2.', ['abs', 'neg', '', 'sqrt', 'add', 'sub', 'mul', 'div', 'min', 'max', 'pmin', 'pmax'],
    Vector, 236);
  AddRun('', ['i32x4.trunc_sat_f32x4_s', 'i32x4.trunc_sat_f32x4_u', 'f32x4.convert_i32x4_s',
    'f32x4.convert_i32x4_u', 'i32x4.trunc_sat_f64x2_s_zero', 'i32x4.trunc_sat_f64x2_u_zero',
    'f64x2.convert_low_i32x4_s', 'f64x2.convert_low_i32x4_u'], Vector, 248);
  AddRun('', ['i8x16.relaxed_swizzle', 'i32x4.relaxed_trunc_f32x4_s', 'i32x4.relaxed_trunc_f32x4_u',
    'i32x4.relaxed_trunc_f64x2_s_zero', 'i32x4.relaxed_trunc_f64x2_u_zero', 'f32x4.relaxed_madd',
    'f32x4.relaxed_nmadd', 'f64x2.relaxed_madd', 'f64x2.relaxed_nmadd', 'i8x16.relaxed_laneselect',
    'i16x8.relaxed_laneselect', 'i32x4.relaxed_laneselect', 'i64x2.relaxed_laneselect', 'f32x4.relaxed_min',
    'f32x4.relaxed_max', 'f64x2.relaxed_min', 'f64x2.relaxed_max', 'i16x8.relaxed_q15mulr_s',
    'i16x8.relaxed_dot_i8x16_i7x16_s', 'i32x4.relaxed_dot_i8x16_i7x16_add_s'], Vector, $100);
end;

procedure BuildTable;
begin
  InstructionTable := TStringList.Create;
  InstructionTable.OwnsObjects := True;
  InstructionTable.CaseSensitive := True;
  AddCoreInstructions;
  AddGarbageCollectionInstructions;
  AddMiscellaneousInstructions;
  AddVectorInstructions;
  InstructionTable.Sorted := True;
end;

function LookUpInstruction(const Name: AnsiString; out Info: TInstructionInfo): Boolean;
var
  Index: Integer;
begin
  if InstructionTable = nil then
    BuildTable;
  Result := InstructionTable.Find(Name, Index);
  if Result then
    Info := TInstructionEntry(InstructionTable.Objects[Index]).Info;
end;

finalization
  InstructionTable.Free;
end.
