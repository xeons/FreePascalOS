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
  The WebAssembly 3.0 instruction set as one dense numbering, and what the
  validator needs to know about each instruction.

  An instruction's code is its one byte opcode (0x00 to 0xFF); the 0xFC
  prefixed instructions are $100 plus their index, the 0xFD (SIMD and
  relaxed SIMD) ones $200 plus theirs and the 0xFB (garbage collection)
  ones $380 plus theirs. The compiled code (Wasm.Code) uses the same
  numbers for the operations it keeps as they are and numbers above
  LastWasmOpcode for its own.

  Each entry has the text format's name (for error messages and the
  text parser), the kind of immediate that follows the opcode, and for
  the instructions whose typing is fixed a signature: the operand types
  popped and the result types pushed, one letter each (i i32, l i64,
  f f32, d f64, v v128, r funcref), e.g. 'ii>i' for i32.add. An empty
  signature means the validator handles the instruction itself. Memory
  instructions give the largest alignment they allow (log2 of their
  access size), lane instructions the number of lanes.

  The table was made from the spec's instruction index
  (document/core/appendix/index-instructions.py).
}
unit Wasm.Opcodes;

{$mode objfpc}
{$H+}

interface

type
  TWasmImmediateKind = (
    ikNone,
    ikBlockType,      { block, loop, if }
    ikLabel,          { br, br_if }
    ikLabelTable,     { br_table }
    ikFunction,       { call, ref.func }
    ikCallIndirect,   { type index, table index }
    ikLocal,
    ikGlobal,
    ikTable,
    ikMemory,         { memory.size, memory.grow, memory.fill }
    ikMemarg,         { alignment, offset (and the memory, see Wasm.Instructions) }
    ikMemargLane,     { memarg and a lane index }
    ikLane,           { a lane index }
    ikSelectTypes,    { select t* }
    ikI32,
    ikI64,
    ikF32,
    ikF64,
    ikV128,
    ikShuffle,        { sixteen lane indices }
    ikReferenceType,  { ref.null }
    ikDataMemory,     { memory.init }
    ikData,           { data.drop }
    ikMemoryMemory,   { memory.copy }
    ikElementTable,   { table.init }
    ikElement,        { elem.drop }
    ikTableTable,     { table.copy }
    ikTag,            { throw, catch: a tag index }
    ikTryTable,       { try_table: block type and catch clauses }
    ikTypeIndex,      { call_ref, struct.new, array.new ...: a type index }
    ikTypeField,      { struct.get / set: type and field index }
    ikTypeCount,      { array.new_fixed: type and element count }
    ikTypeData,       { array.new_data, array.init_data: type and data index }
    ikTypeElement,    { array.new_elem, array.init_elem: type and element index }
    ikTypeType,       { array.copy: destination and source type }
    ikHeapType,       { ref.test, ref.cast }
    ikBranchCast      { br_on_cast(_fail): flags, label, two heap types }
  );

  TWasmOpcodeInfo = record
    Name: string[39];
    Signature: string[7];
    Immediate: TWasmImmediateKind;
    Alignment: ShortInt;
    Lanes: Byte;
  end;


const
  OpUnreachable               = $000;
  OpNop                       = $001;
  OpBlock                     = $002;
  OpLoop                      = $003;
  OpIf                        = $004;
  OpElse                      = $005;
  OpEnd                       = $00B;
  OpBr                        = $00C;
  OpBrIf                      = $00D;
  OpBrTable                   = $00E;
  OpReturn                    = $00F;
  OpCall                      = $010;
  OpCallIndirect              = $011;
  OpDrop                      = $01A;
  OpSelect                    = $01B;
  OpSelectTyped               = $01C;
  OpLocalGet                  = $020;
  OpLocalSet                  = $021;
  OpLocalTee                  = $022;
  OpGlobalGet                 = $023;
  OpGlobalSet                 = $024;
  OpTableGet                  = $025;
  OpTableSet                  = $026;
  OpI32Load                   = $028;
  OpI64Load                   = $029;
  OpF32Load                   = $02A;
  OpF64Load                   = $02B;
  OpI32Load8S                 = $02C;
  OpI32Load8U                 = $02D;
  OpI32Load16S                = $02E;
  OpI32Load16U                = $02F;
  OpI64Load8S                 = $030;
  OpI64Load8U                 = $031;
  OpI64Load16S                = $032;
  OpI64Load16U                = $033;
  OpI64Load32S                = $034;
  OpI64Load32U                = $035;
  OpI32Store                  = $036;
  OpI64Store                  = $037;
  OpF32Store                  = $038;
  OpF64Store                  = $039;
  OpI32Store8                 = $03A;
  OpI32Store16                = $03B;
  OpI64Store8                 = $03C;
  OpI64Store16                = $03D;
  OpI64Store32                = $03E;
  OpMemorySize                = $03F;
  OpMemoryGrow                = $040;
  OpI32Const                  = $041;
  OpI64Const                  = $042;
  OpF32Const                  = $043;
  OpF64Const                  = $044;
  OpI32Eqz                    = $045;
  OpI32Eq                     = $046;
  OpI32Ne                     = $047;
  OpI32LtS                    = $048;
  OpI32LtU                    = $049;
  OpI32GtS                    = $04A;
  OpI32GtU                    = $04B;
  OpI32LeS                    = $04C;
  OpI32LeU                    = $04D;
  OpI32GeS                    = $04E;
  OpI32GeU                    = $04F;
  OpI64Eqz                    = $050;
  OpI64Eq                     = $051;
  OpI64Ne                     = $052;
  OpI64LtS                    = $053;
  OpI64LtU                    = $054;
  OpI64GtS                    = $055;
  OpI64GtU                    = $056;
  OpI64LeS                    = $057;
  OpI64LeU                    = $058;
  OpI64GeS                    = $059;
  OpI64GeU                    = $05A;
  OpF32Eq                     = $05B;
  OpF32Ne                     = $05C;
  OpF32Lt                     = $05D;
  OpF32Gt                     = $05E;
  OpF32Le                     = $05F;
  OpF32Ge                     = $060;
  OpF64Eq                     = $061;
  OpF64Ne                     = $062;
  OpF64Lt                     = $063;
  OpF64Gt                     = $064;
  OpF64Le                     = $065;
  OpF64Ge                     = $066;
  OpI32Clz                    = $067;
  OpI32Ctz                    = $068;
  OpI32Popcnt                 = $069;
  OpI32Add                    = $06A;
  OpI32Sub                    = $06B;
  OpI32Mul                    = $06C;
  OpI32DivS                   = $06D;
  OpI32DivU                   = $06E;
  OpI32RemS                   = $06F;
  OpI32RemU                   = $070;
  OpI32And                    = $071;
  OpI32Or                     = $072;
  OpI32Xor                    = $073;
  OpI32Shl                    = $074;
  OpI32ShrS                   = $075;
  OpI32ShrU                   = $076;
  OpI32Rotl                   = $077;
  OpI32Rotr                   = $078;
  OpI64Clz                    = $079;
  OpI64Ctz                    = $07A;
  OpI64Popcnt                 = $07B;
  OpI64Add                    = $07C;
  OpI64Sub                    = $07D;
  OpI64Mul                    = $07E;
  OpI64DivS                   = $07F;
  OpI64DivU                   = $080;
  OpI64RemS                   = $081;
  OpI64RemU                   = $082;
  OpI64And                    = $083;
  OpI64Or                     = $084;
  OpI64Xor                    = $085;
  OpI64Shl                    = $086;
  OpI64ShrS                   = $087;
  OpI64ShrU                   = $088;
  OpI64Rotl                   = $089;
  OpI64Rotr                   = $08A;
  OpF32Abs                    = $08B;
  OpF32Neg                    = $08C;
  OpF32Ceil                   = $08D;
  OpF32Floor                  = $08E;
  OpF32Trunc                  = $08F;
  OpF32Nearest                = $090;
  OpF32Sqrt                   = $091;
  OpF32Add                    = $092;
  OpF32Sub                    = $093;
  OpF32Mul                    = $094;
  OpF32Div                    = $095;
  OpF32Min                    = $096;
  OpF32Max                    = $097;
  OpF32Copysign               = $098;
  OpF64Abs                    = $099;
  OpF64Neg                    = $09A;
  OpF64Ceil                   = $09B;
  OpF64Floor                  = $09C;
  OpF64Trunc                  = $09D;
  OpF64Nearest                = $09E;
  OpF64Sqrt                   = $09F;
  OpF64Add                    = $0A0;
  OpF64Sub                    = $0A1;
  OpF64Mul                    = $0A2;
  OpF64Div                    = $0A3;
  OpF64Min                    = $0A4;
  OpF64Max                    = $0A5;
  OpF64Copysign               = $0A6;
  OpI32WrapI64                = $0A7;
  OpI32TruncF32S              = $0A8;
  OpI32TruncF32U              = $0A9;
  OpI32TruncF64S              = $0AA;
  OpI32TruncF64U              = $0AB;
  OpI64ExtendI32S             = $0AC;
  OpI64ExtendI32U             = $0AD;
  OpI64TruncF32S              = $0AE;
  OpI64TruncF32U              = $0AF;
  OpI64TruncF64S              = $0B0;
  OpI64TruncF64U              = $0B1;
  OpF32ConvertI32S            = $0B2;
  OpF32ConvertI32U            = $0B3;
  OpF32ConvertI64S            = $0B4;
  OpF32ConvertI64U            = $0B5;
  OpF32DemoteF64              = $0B6;
  OpF64ConvertI32S            = $0B7;
  OpF64ConvertI32U            = $0B8;
  OpF64ConvertI64S            = $0B9;
  OpF64ConvertI64U            = $0BA;
  OpF64PromoteF32             = $0BB;
  OpI32ReinterpretF32         = $0BC;
  OpI64ReinterpretF64         = $0BD;
  OpF32ReinterpretI32         = $0BE;
  OpF64ReinterpretI64         = $0BF;
  OpI32Extend8S               = $0C0;
  OpI32Extend16S              = $0C1;
  OpI64Extend8S               = $0C2;
  OpI64Extend16S              = $0C3;
  OpI64Extend32S              = $0C4;
  OpRefNull                   = $0D0;
  OpRefIsNull                 = $0D1;
  OpRefFunc                   = $0D2;
  OpI32TruncSatF32S           = $100;
  OpI32TruncSatF32U           = $101;
  OpI32TruncSatF64S           = $102;
  OpI32TruncSatF64U           = $103;
  OpI64TruncSatF32S           = $104;
  OpI64TruncSatF32U           = $105;
  OpI64TruncSatF64S           = $106;
  OpI64TruncSatF64U           = $107;
  OpMemoryInit                = $108;
  OpDataDrop                  = $109;
  OpMemoryCopy                = $10A;
  OpMemoryFill                = $10B;
  OpTableInit                 = $10C;
  OpElemDrop                  = $10D;
  OpTableCopy                 = $10E;
  OpTableGrow                 = $10F;
  OpTableSize                 = $110;
  OpTableFill                 = $111;
  OpV128Load                  = $200;
  OpV128Load8x8S              = $201;
  OpV128Load8x8U              = $202;
  OpV128Load16x4S             = $203;
  OpV128Load16x4U             = $204;
  OpV128Load32x2S             = $205;
  OpV128Load32x2U             = $206;
  OpV128Load8Splat            = $207;
  OpV128Load16Splat           = $208;
  OpV128Load32Splat           = $209;
  OpV128Load64Splat           = $20A;
  OpV128Store                 = $20B;
  OpV128Const                 = $20C;
  OpI8x16Shuffle              = $20D;
  OpI8x16Swizzle              = $20E;
  OpI8x16Splat                = $20F;
  OpI16x8Splat                = $210;
  OpI32x4Splat                = $211;
  OpI64x2Splat                = $212;
  OpF32x4Splat                = $213;
  OpF64x2Splat                = $214;
  OpI8x16ExtractLaneS         = $215;
  OpI8x16ExtractLaneU         = $216;
  OpI8x16ReplaceLane          = $217;
  OpI16x8ExtractLaneS         = $218;
  OpI16x8ExtractLaneU         = $219;
  OpI16x8ReplaceLane          = $21A;
  OpI32x4ExtractLane          = $21B;
  OpI32x4ReplaceLane          = $21C;
  OpI64x2ExtractLane          = $21D;
  OpI64x2ReplaceLane          = $21E;
  OpF32x4ExtractLane          = $21F;
  OpF32x4ReplaceLane          = $220;
  OpF64x2ExtractLane          = $221;
  OpF64x2ReplaceLane          = $222;
  OpI8x16Eq                   = $223;
  OpI8x16Ne                   = $224;
  OpI8x16LtS                  = $225;
  OpI8x16LtU                  = $226;
  OpI8x16GtS                  = $227;
  OpI8x16GtU                  = $228;
  OpI8x16LeS                  = $229;
  OpI8x16LeU                  = $22A;
  OpI8x16GeS                  = $22B;
  OpI8x16GeU                  = $22C;
  OpI16x8Eq                   = $22D;
  OpI16x8Ne                   = $22E;
  OpI16x8LtS                  = $22F;
  OpI16x8LtU                  = $230;
  OpI16x8GtS                  = $231;
  OpI16x8GtU                  = $232;
  OpI16x8LeS                  = $233;
  OpI16x8LeU                  = $234;
  OpI16x8GeS                  = $235;
  OpI16x8GeU                  = $236;
  OpI32x4Eq                   = $237;
  OpI32x4Ne                   = $238;
  OpI32x4LtS                  = $239;
  OpI32x4LtU                  = $23A;
  OpI32x4GtS                  = $23B;
  OpI32x4GtU                  = $23C;
  OpI32x4LeS                  = $23D;
  OpI32x4LeU                  = $23E;
  OpI32x4GeS                  = $23F;
  OpI32x4GeU                  = $240;
  OpF32x4Eq                   = $241;
  OpF32x4Ne                   = $242;
  OpF32x4Lt                   = $243;
  OpF32x4Gt                   = $244;
  OpF32x4Le                   = $245;
  OpF32x4Ge                   = $246;
  OpF64x2Eq                   = $247;
  OpF64x2Ne                   = $248;
  OpF64x2Lt                   = $249;
  OpF64x2Gt                   = $24A;
  OpF64x2Le                   = $24B;
  OpF64x2Ge                   = $24C;
  OpV128Not                   = $24D;
  OpV128And                   = $24E;
  OpV128Andnot                = $24F;
  OpV128Or                    = $250;
  OpV128Xor                   = $251;
  OpV128Bitselect             = $252;
  OpV128AnyTrue               = $253;
  OpV128Load8Lane             = $254;
  OpV128Load16Lane            = $255;
  OpV128Load32Lane            = $256;
  OpV128Load64Lane            = $257;
  OpV128Store8Lane            = $258;
  OpV128Store16Lane           = $259;
  OpV128Store32Lane           = $25A;
  OpV128Store64Lane           = $25B;
  OpV128Load32Zero            = $25C;
  OpV128Load64Zero            = $25D;
  OpF32x4DemoteF64x2Zero      = $25E;
  OpF64x2PromoteLowF32x4      = $25F;
  OpI8x16Abs                  = $260;
  OpI8x16Neg                  = $261;
  OpI8x16Popcnt               = $262;
  OpI8x16AllTrue              = $263;
  OpI8x16Bitmask              = $264;
  OpI8x16NarrowI16x8S         = $265;
  OpI8x16NarrowI16x8U         = $266;
  OpF32x4Ceil                 = $267;
  OpF32x4Floor                = $268;
  OpF32x4Trunc                = $269;
  OpF32x4Nearest              = $26A;
  OpI8x16Shl                  = $26B;
  OpI8x16ShrS                 = $26C;
  OpI8x16ShrU                 = $26D;
  OpI8x16Add                  = $26E;
  OpI8x16AddSatS              = $26F;
  OpI8x16AddSatU              = $270;
  OpI8x16Sub                  = $271;
  OpI8x16SubSatS              = $272;
  OpI8x16SubSatU              = $273;
  OpF64x2Ceil                 = $274;
  OpF64x2Floor                = $275;
  OpI8x16MinS                 = $276;
  OpI8x16MinU                 = $277;
  OpI8x16MaxS                 = $278;
  OpI8x16MaxU                 = $279;
  OpF64x2Trunc                = $27A;
  OpI8x16AvgrU                = $27B;
  OpI16x8ExtaddPairwiseI8x16S = $27C;
  OpI16x8ExtaddPairwiseI8x16U = $27D;
  OpI32x4ExtaddPairwiseI16x8S = $27E;
  OpI32x4ExtaddPairwiseI16x8U = $27F;
  OpI16x8Abs                  = $280;
  OpI16x8Neg                  = $281;
  OpI16x8Q15mulrSatS          = $282;
  OpI16x8AllTrue              = $283;
  OpI16x8Bitmask              = $284;
  OpI16x8NarrowI32x4S         = $285;
  OpI16x8NarrowI32x4U         = $286;
  OpI16x8ExtendLowI8x16S      = $287;
  OpI16x8ExtendHighI8x16S     = $288;
  OpI16x8ExtendLowI8x16U      = $289;
  OpI16x8ExtendHighI8x16U     = $28A;
  OpI16x8Shl                  = $28B;
  OpI16x8ShrS                 = $28C;
  OpI16x8ShrU                 = $28D;
  OpI16x8Add                  = $28E;
  OpI16x8AddSatS              = $28F;
  OpI16x8AddSatU              = $290;
  OpI16x8Sub                  = $291;
  OpI16x8SubSatS              = $292;
  OpI16x8SubSatU              = $293;
  OpF64x2Nearest              = $294;
  OpI16x8Mul                  = $295;
  OpI16x8MinS                 = $296;
  OpI16x8MinU                 = $297;
  OpI16x8MaxS                 = $298;
  OpI16x8MaxU                 = $299;
  OpI16x8AvgrU                = $29B;
  OpI16x8ExtmulLowI8x16S      = $29C;
  OpI16x8ExtmulHighI8x16S     = $29D;
  OpI16x8ExtmulLowI8x16U      = $29E;
  OpI16x8ExtmulHighI8x16U     = $29F;
  OpI32x4Abs                  = $2A0;
  OpI32x4Neg                  = $2A1;
  OpI32x4AllTrue              = $2A3;
  OpI32x4Bitmask              = $2A4;
  OpI32x4ExtendLowI16x8S      = $2A7;
  OpI32x4ExtendHighI16x8S     = $2A8;
  OpI32x4ExtendLowI16x8U      = $2A9;
  OpI32x4ExtendHighI16x8U     = $2AA;
  OpI32x4Shl                  = $2AB;
  OpI32x4ShrS                 = $2AC;
  OpI32x4ShrU                 = $2AD;
  OpI32x4Add                  = $2AE;
  OpI32x4Sub                  = $2B1;
  OpI32x4Mul                  = $2B5;
  OpI32x4MinS                 = $2B6;
  OpI32x4MinU                 = $2B7;
  OpI32x4MaxS                 = $2B8;
  OpI32x4MaxU                 = $2B9;
  OpI32x4DotI16x8S            = $2BA;
  OpI32x4ExtmulLowI16x8S      = $2BC;
  OpI32x4ExtmulHighI16x8S     = $2BD;
  OpI32x4ExtmulLowI16x8U      = $2BE;
  OpI32x4ExtmulHighI16x8U     = $2BF;
  OpI64x2Abs                  = $2C0;
  OpI64x2Neg                  = $2C1;
  OpI64x2AllTrue              = $2C3;
  OpI64x2Bitmask              = $2C4;
  OpI64x2ExtendLowI32x4S      = $2C7;
  OpI64x2ExtendHighI32x4S     = $2C8;
  OpI64x2ExtendLowI32x4U      = $2C9;
  OpI64x2ExtendHighI32x4U     = $2CA;
  OpI64x2Shl                  = $2CB;
  OpI64x2ShrS                 = $2CC;
  OpI64x2ShrU                 = $2CD;
  OpI64x2Add                  = $2CE;
  OpI64x2Sub                  = $2D1;
  OpI64x2Mul                  = $2D5;
  OpI64x2Eq                   = $2D6;
  OpI64x2Ne                   = $2D7;
  OpI64x2LtS                  = $2D8;
  OpI64x2GtS                  = $2D9;
  OpI64x2LeS                  = $2DA;
  OpI64x2GeS                  = $2DB;
  OpI64x2ExtmulLowI32x4S      = $2DC;
  OpI64x2ExtmulHighI32x4S     = $2DD;
  OpI64x2ExtmulLowI32x4U      = $2DE;
  OpI64x2ExtmulHighI32x4U     = $2DF;
  OpF32x4Abs                  = $2E0;
  OpF32x4Neg                  = $2E1;
  OpF32x4Sqrt                 = $2E3;
  OpF32x4Add                  = $2E4;
  OpF32x4Sub                  = $2E5;
  OpF32x4Mul                  = $2E6;
  OpF32x4Div                  = $2E7;
  OpF32x4Min                  = $2E8;
  OpF32x4Max                  = $2E9;
  OpF32x4Pmin                 = $2EA;
  OpF32x4Pmax                 = $2EB;
  OpF64x2Abs                  = $2EC;
  OpF64x2Neg                  = $2ED;
  OpF64x2Sqrt                 = $2EF;
  OpF64x2Add                  = $2F0;
  OpF64x2Sub                  = $2F1;
  OpF64x2Mul                  = $2F2;
  OpF64x2Div                  = $2F3;
  OpF64x2Min                  = $2F4;
  OpF64x2Max                  = $2F5;
  OpF64x2Pmin                 = $2F6;
  OpF64x2Pmax                 = $2F7;
  OpI32x4TruncSatF32x4S       = $2F8;
  OpI32x4TruncSatF32x4U       = $2F9;
  OpF32x4ConvertI32x4S        = $2FA;
  OpF32x4ConvertI32x4U        = $2FB;
  OpI32x4TruncSatF64x2SZero   = $2FC;
  OpI32x4TruncSatF64x2UZero   = $2FD;
  OpF64x2ConvertLowI32x4S     = $2FE;
  OpF64x2ConvertLowI32x4U     = $2FF;

  { WebAssembly 3.0: exception handling, tail calls, typed references. }
  OpTry                       = $006;
  OpCatch                     = $007;
  OpThrow                     = $008;
  OpRethrow                   = $009;
  OpThrowRef                  = $00A;
  OpReturnCall                = $012;
  OpReturnCallIndirect        = $013;
  OpCallRef                   = $014;
  OpReturnCallRef             = $015;
  OpDelegate                  = $018;
  OpCatchAll                  = $019;
  OpTryTable                  = $01F;
  OpRefEq                     = $0D3;
  OpRefAsNonNull              = $0D4;
  OpBrOnNull                  = $0D5;
  OpBrOnNonNull               = $0D6;
  { Relaxed SIMD: $200 plus the 0xFD index ($100 on). }
  OpI8x16RelaxedSwizzle       = $300;
  OpI32x4RelaxedTruncF32x4S   = $301;
  OpI32x4RelaxedTruncF32x4U   = $302;
  OpI32x4RelaxedTruncF64x2SZero= $303;
  OpI32x4RelaxedTruncF64x2UZero= $304;
  OpF32x4RelaxedMadd          = $305;
  OpF32x4RelaxedNmadd         = $306;
  OpF64x2RelaxedMadd          = $307;
  OpF64x2RelaxedNmadd         = $308;
  OpI8x16RelaxedLaneselect    = $309;
  OpI16x8RelaxedLaneselect    = $30A;
  OpI32x4RelaxedLaneselect    = $30B;
  OpI64x2RelaxedLaneselect    = $30C;
  OpF32x4RelaxedMin           = $30D;
  OpF32x4RelaxedMax           = $30E;
  OpF64x2RelaxedMin           = $30F;
  OpF64x2RelaxedMax           = $310;
  OpI16x8RelaxedQ15mulrS      = $311;
  OpI16x8RelaxedDotI8x16I7x16S= $312;
  OpI32x4RelaxedDotI8x16I7x16AddS= $313;
  { Garbage collection: the 0xFB instructions are $380 plus their index. }
  OpStructNew                 = $380;
  OpStructNewDefault          = $381;
  OpStructGet                 = $382;
  OpStructGetS                = $383;
  OpStructGetU                = $384;
  OpStructSet                 = $385;
  OpArrayNew                  = $386;
  OpArrayNewDefault           = $387;
  OpArrayNewFixed             = $388;
  OpArrayNewData              = $389;
  OpArrayNewElem              = $38A;
  OpArrayGet                  = $38B;
  OpArrayGetS                 = $38C;
  OpArrayGetU                 = $38D;
  OpArraySet                  = $38E;
  OpArrayLen                  = $38F;
  OpArrayFill                 = $390;
  OpArrayCopy                 = $391;
  OpArrayInitData             = $392;
  OpArrayInitElem             = $393;
  OpRefTest                   = $394;
  OpRefTestNull               = $395;
  OpRefCast                   = $396;
  OpRefCastNull               = $397;
  OpBrOnCast                  = $398;
  OpBrOnCastFail              = $399;
  OpAnyConvertExtern          = $39A;
  OpExternConvertAny          = $39B;
  OpRefI31                    = $39C;
  OpI31GetS                   = $39D;
  OpI31GetU                   = $39E;

  { The last 0xFD index and the first code of the 0xFB instructions. }
  LastSimdIndex = $113;
  GcOpcodeBase = $380;
  LastGcIndex = 30;
  { The highest code of a WebAssembly instruction. }
  LastWasmOpcode = $39F;

  WasmOpcodeTable: array[0..LastWasmOpcode] of TWasmOpcodeInfo = (
    (Name: 'unreachable'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'nop'; Signature: '>'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'block'; Signature: ''; Immediate: ikBlockType; Alignment: -1; Lanes: 0),
    (Name: 'loop'; Signature: ''; Immediate: ikBlockType; Alignment: -1; Lanes: 0),
    (Name: 'if'; Signature: ''; Immediate: ikBlockType; Alignment: -1; Lanes: 0),
    (Name: 'else'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'try'; Signature: ''; Immediate: ikBlockType; Alignment: -1; Lanes: 0),
    (Name: 'catch'; Signature: ''; Immediate: ikTag; Alignment: -1; Lanes: 0),
    (Name: 'throw'; Signature: ''; Immediate: ikTag; Alignment: -1; Lanes: 0),
    (Name: 'rethrow'; Signature: ''; Immediate: ikLabel; Alignment: -1; Lanes: 0),
    (Name: 'throw_ref'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'end'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'br'; Signature: ''; Immediate: ikLabel; Alignment: -1; Lanes: 0),
    (Name: 'br_if'; Signature: ''; Immediate: ikLabel; Alignment: -1; Lanes: 0),
    (Name: 'br_table'; Signature: ''; Immediate: ikLabelTable; Alignment: -1; Lanes: 0),
    (Name: 'return'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'call'; Signature: ''; Immediate: ikFunction; Alignment: -1; Lanes: 0),
    (Name: 'call_indirect'; Signature: ''; Immediate: ikCallIndirect; Alignment: -1; Lanes: 0),
    (Name: 'return_call'; Signature: ''; Immediate: ikFunction; Alignment: -1; Lanes: 0),
    (Name: 'return_call_indirect'; Signature: ''; Immediate: ikCallIndirect; Alignment: -1; Lanes: 0),
    (Name: 'call_ref'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'return_call_ref'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'delegate'; Signature: ''; Immediate: ikLabel; Alignment: -1; Lanes: 0),
    (Name: 'catch_all'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'drop'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'select'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'select'; Signature: ''; Immediate: ikSelectTypes; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'try_table'; Signature: ''; Immediate: ikTryTable; Alignment: -1; Lanes: 0),
    (Name: 'local.get'; Signature: ''; Immediate: ikLocal; Alignment: -1; Lanes: 0),
    (Name: 'local.set'; Signature: ''; Immediate: ikLocal; Alignment: -1; Lanes: 0),
    (Name: 'local.tee'; Signature: ''; Immediate: ikLocal; Alignment: -1; Lanes: 0),
    (Name: 'global.get'; Signature: ''; Immediate: ikGlobal; Alignment: -1; Lanes: 0),
    (Name: 'global.set'; Signature: ''; Immediate: ikGlobal; Alignment: -1; Lanes: 0),
    (Name: 'table.get'; Signature: ''; Immediate: ikTable; Alignment: -1; Lanes: 0),
    (Name: 'table.set'; Signature: ''; Immediate: ikTable; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.load'; Signature: 'i>i'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'i64.load'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'f32.load'; Signature: 'i>f'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'f64.load'; Signature: 'i>d'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'i32.load8_s'; Signature: 'i>i'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'i32.load8_u'; Signature: 'i>i'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'i32.load16_s'; Signature: 'i>i'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'i32.load16_u'; Signature: 'i>i'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'i64.load8_s'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'i64.load8_u'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'i64.load16_s'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'i64.load16_u'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'i64.load32_s'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'i64.load32_u'; Signature: 'i>l'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'i32.store'; Signature: 'ii>'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'i64.store'; Signature: 'il>'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'f32.store'; Signature: 'if>'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'f64.store'; Signature: 'id>'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'i32.store8'; Signature: 'ii>'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'i32.store16'; Signature: 'ii>'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'i64.store8'; Signature: 'il>'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'i64.store16'; Signature: 'il>'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'i64.store32'; Signature: 'il>'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'memory.size'; Signature: '>i'; Immediate: ikMemory; Alignment: -1; Lanes: 0),
    (Name: 'memory.grow'; Signature: 'i>i'; Immediate: ikMemory; Alignment: -1; Lanes: 0),
    (Name: 'i32.const'; Signature: '>i'; Immediate: ikI32; Alignment: -1; Lanes: 0),
    (Name: 'i64.const'; Signature: '>l'; Immediate: ikI64; Alignment: -1; Lanes: 0),
    (Name: 'f32.const'; Signature: '>f'; Immediate: ikF32; Alignment: -1; Lanes: 0),
    (Name: 'f64.const'; Signature: '>d'; Immediate: ikF64; Alignment: -1; Lanes: 0),
    (Name: 'i32.eqz'; Signature: 'i>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.eq'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.ne'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.lt_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.lt_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.gt_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.gt_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.le_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.le_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.ge_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.ge_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.eqz'; Signature: 'l>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.eq'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.ne'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.lt_s'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.lt_u'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.gt_s'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.gt_u'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.le_s'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.le_u'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.ge_s'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.ge_u'; Signature: 'll>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.eq'; Signature: 'ff>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.ne'; Signature: 'ff>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.lt'; Signature: 'ff>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.gt'; Signature: 'ff>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.le'; Signature: 'ff>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.ge'; Signature: 'ff>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.eq'; Signature: 'dd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.ne'; Signature: 'dd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.lt'; Signature: 'dd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.gt'; Signature: 'dd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.le'; Signature: 'dd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.ge'; Signature: 'dd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.clz'; Signature: 'i>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.ctz'; Signature: 'i>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.popcnt'; Signature: 'i>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.add'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.sub'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.mul'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.div_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.div_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.rem_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.rem_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.and'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.or'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.xor'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.shl'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.shr_s'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.shr_u'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.rotl'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.rotr'; Signature: 'ii>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.clz'; Signature: 'l>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.ctz'; Signature: 'l>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.popcnt'; Signature: 'l>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.add'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.sub'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.mul'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.div_s'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.div_u'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.rem_s'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.rem_u'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.and'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.or'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.xor'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.shl'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.shr_s'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.shr_u'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.rotl'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.rotr'; Signature: 'll>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.abs'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.neg'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.ceil'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.floor'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.trunc'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.nearest'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.sqrt'; Signature: 'f>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.add'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.sub'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.mul'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.div'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.min'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.max'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.copysign'; Signature: 'ff>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.abs'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.neg'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.ceil'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.floor'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.trunc'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.nearest'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.sqrt'; Signature: 'd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.add'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.sub'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.mul'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.div'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.min'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.max'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.copysign'; Signature: 'dd>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.wrap_i64'; Signature: 'l>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_f32_s'; Signature: 'f>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_f32_u'; Signature: 'f>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_f64_s'; Signature: 'd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_f64_u'; Signature: 'd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.extend_i32_s'; Signature: 'i>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.extend_i32_u'; Signature: 'i>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_f32_s'; Signature: 'f>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_f32_u'; Signature: 'f>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_f64_s'; Signature: 'd>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_f64_u'; Signature: 'd>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.convert_i32_s'; Signature: 'i>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.convert_i32_u'; Signature: 'i>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.convert_i64_s'; Signature: 'l>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.convert_i64_u'; Signature: 'l>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.demote_f64'; Signature: 'd>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.convert_i32_s'; Signature: 'i>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.convert_i32_u'; Signature: 'i>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.convert_i64_s'; Signature: 'l>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.convert_i64_u'; Signature: 'l>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.promote_f32'; Signature: 'f>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.reinterpret_f32'; Signature: 'f>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.reinterpret_f64'; Signature: 'd>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32.reinterpret_i32'; Signature: 'i>f'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64.reinterpret_i64'; Signature: 'l>d'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.extend8_s'; Signature: 'i>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.extend16_s'; Signature: 'i>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.extend8_s'; Signature: 'l>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.extend16_s'; Signature: 'l>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.extend32_s'; Signature: 'l>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'ref.null'; Signature: ''; Immediate: ikReferenceType; Alignment: -1; Lanes: 0),
    (Name: 'ref.is_null'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'ref.func'; Signature: '>r'; Immediate: ikFunction; Alignment: -1; Lanes: 0),
    (Name: 'ref.eq'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'ref.as_non_null'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'br_on_null'; Signature: ''; Immediate: ikLabel; Alignment: -1; Lanes: 0),
    (Name: 'br_on_non_null'; Signature: ''; Immediate: ikLabel; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_sat_f32_s'; Signature: 'f>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_sat_f32_u'; Signature: 'f>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_sat_f64_s'; Signature: 'd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32.trunc_sat_f64_u'; Signature: 'd>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_sat_f32_s'; Signature: 'f>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_sat_f32_u'; Signature: 'f>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_sat_f64_s'; Signature: 'd>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64.trunc_sat_f64_u'; Signature: 'd>l'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'memory.init'; Signature: 'iii>'; Immediate: ikDataMemory; Alignment: -1; Lanes: 0),
    (Name: 'data.drop'; Signature: '>'; Immediate: ikData; Alignment: -1; Lanes: 0),
    (Name: 'memory.copy'; Signature: 'iii>'; Immediate: ikMemoryMemory; Alignment: -1; Lanes: 0),
    (Name: 'memory.fill'; Signature: 'iii>'; Immediate: ikMemory; Alignment: -1; Lanes: 0),
    (Name: 'table.init'; Signature: 'iii>'; Immediate: ikElementTable; Alignment: -1; Lanes: 0),
    (Name: 'elem.drop'; Signature: '>'; Immediate: ikElement; Alignment: -1; Lanes: 0),
    (Name: 'table.copy'; Signature: 'iii>'; Immediate: ikTableTable; Alignment: -1; Lanes: 0),
    (Name: 'table.grow'; Signature: ''; Immediate: ikTable; Alignment: -1; Lanes: 0),
    (Name: 'table.size'; Signature: '>i'; Immediate: ikTable; Alignment: -1; Lanes: 0),
    (Name: 'table.fill'; Signature: ''; Immediate: ikTable; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.load'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 4; Lanes: 0),
    (Name: 'v128.load8x8_s'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.load8x8_u'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.load16x4_s'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.load16x4_u'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.load32x2_s'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.load32x2_u'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.load8_splat'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 0; Lanes: 0),
    (Name: 'v128.load16_splat'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 1; Lanes: 0),
    (Name: 'v128.load32_splat'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'v128.load64_splat'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'v128.store'; Signature: 'iv>'; Immediate: ikMemarg; Alignment: 4; Lanes: 0),
    (Name: 'v128.const'; Signature: '>v'; Immediate: ikV128; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.shuffle'; Signature: 'vv>v'; Immediate: ikShuffle; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.swizzle'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.splat'; Signature: 'i>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.splat'; Signature: 'i>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.splat'; Signature: 'i>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.splat'; Signature: 'l>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.splat'; Signature: 'f>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.splat'; Signature: 'd>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.extract_lane_s'; Signature: 'v>i'; Immediate: ikLane; Alignment: -1; Lanes: 16),
    (Name: 'i8x16.extract_lane_u'; Signature: 'v>i'; Immediate: ikLane; Alignment: -1; Lanes: 16),
    (Name: 'i8x16.replace_lane'; Signature: 'vi>v'; Immediate: ikLane; Alignment: -1; Lanes: 16),
    (Name: 'i16x8.extract_lane_s'; Signature: 'v>i'; Immediate: ikLane; Alignment: -1; Lanes: 8),
    (Name: 'i16x8.extract_lane_u'; Signature: 'v>i'; Immediate: ikLane; Alignment: -1; Lanes: 8),
    (Name: 'i16x8.replace_lane'; Signature: 'vi>v'; Immediate: ikLane; Alignment: -1; Lanes: 8),
    (Name: 'i32x4.extract_lane'; Signature: 'v>i'; Immediate: ikLane; Alignment: -1; Lanes: 4),
    (Name: 'i32x4.replace_lane'; Signature: 'vi>v'; Immediate: ikLane; Alignment: -1; Lanes: 4),
    (Name: 'i64x2.extract_lane'; Signature: 'v>l'; Immediate: ikLane; Alignment: -1; Lanes: 2),
    (Name: 'i64x2.replace_lane'; Signature: 'vl>v'; Immediate: ikLane; Alignment: -1; Lanes: 2),
    (Name: 'f32x4.extract_lane'; Signature: 'v>f'; Immediate: ikLane; Alignment: -1; Lanes: 4),
    (Name: 'f32x4.replace_lane'; Signature: 'vf>v'; Immediate: ikLane; Alignment: -1; Lanes: 4),
    (Name: 'f64x2.extract_lane'; Signature: 'v>d'; Immediate: ikLane; Alignment: -1; Lanes: 2),
    (Name: 'f64x2.replace_lane'; Signature: 'vd>v'; Immediate: ikLane; Alignment: -1; Lanes: 2),
    (Name: 'i8x16.eq'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.ne'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.lt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.lt_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.gt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.gt_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.le_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.le_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.ge_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.ge_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.eq'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.ne'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.lt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.lt_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.gt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.gt_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.le_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.le_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.ge_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.ge_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.eq'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.ne'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.lt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.lt_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.gt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.gt_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.le_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.le_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.ge_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.ge_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.eq'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.ne'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.lt'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.gt'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.le'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.ge'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.eq'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.ne'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.lt'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.gt'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.le'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.ge'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.not'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.and'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.andnot'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.or'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.xor'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.bitselect'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.any_true'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'v128.load8_lane'; Signature: 'iv>v'; Immediate: ikMemargLane; Alignment: 0; Lanes: 16),
    (Name: 'v128.load16_lane'; Signature: 'iv>v'; Immediate: ikMemargLane; Alignment: 1; Lanes: 8),
    (Name: 'v128.load32_lane'; Signature: 'iv>v'; Immediate: ikMemargLane; Alignment: 2; Lanes: 4),
    (Name: 'v128.load64_lane'; Signature: 'iv>v'; Immediate: ikMemargLane; Alignment: 3; Lanes: 2),
    (Name: 'v128.store8_lane'; Signature: 'iv>'; Immediate: ikMemargLane; Alignment: 0; Lanes: 16),
    (Name: 'v128.store16_lane'; Signature: 'iv>'; Immediate: ikMemargLane; Alignment: 1; Lanes: 8),
    (Name: 'v128.store32_lane'; Signature: 'iv>'; Immediate: ikMemargLane; Alignment: 2; Lanes: 4),
    (Name: 'v128.store64_lane'; Signature: 'iv>'; Immediate: ikMemargLane; Alignment: 3; Lanes: 2),
    (Name: 'v128.load32_zero'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 2; Lanes: 0),
    (Name: 'v128.load64_zero'; Signature: 'i>v'; Immediate: ikMemarg; Alignment: 3; Lanes: 0),
    (Name: 'f32x4.demote_f64x2_zero'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.promote_low_f32x4'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.abs'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.neg'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.popcnt'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.all_true'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.bitmask'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.narrow_i16x8_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.narrow_i16x8_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.ceil'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.floor'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.trunc'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.nearest'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.shl'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.shr_s'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.shr_u'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.add'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.add_sat_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.add_sat_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.sub'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.sub_sat_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.sub_sat_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.ceil'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.floor'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.min_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.min_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.max_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.max_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.trunc'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.avgr_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extadd_pairwise_i8x16_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extadd_pairwise_i8x16_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extadd_pairwise_i16x8_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extadd_pairwise_i16x8_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.abs'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.neg'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.q15mulr_sat_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.all_true'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.bitmask'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.narrow_i32x4_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.narrow_i32x4_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extend_low_i8x16_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extend_high_i8x16_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extend_low_i8x16_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extend_high_i8x16_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.shl'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.shr_s'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.shr_u'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.add'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.add_sat_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.add_sat_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.sub'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.sub_sat_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.sub_sat_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.nearest'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.mul'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.min_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.min_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.max_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.max_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.avgr_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extmul_low_i8x16_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extmul_high_i8x16_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extmul_low_i8x16_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.extmul_high_i8x16_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.abs'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.neg'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.all_true'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.bitmask'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extend_low_i16x8_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extend_high_i16x8_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extend_low_i16x8_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extend_high_i16x8_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.shl'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.shr_s'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.shr_u'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.add'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.sub'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.mul'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.min_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.min_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.max_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.max_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.dot_i16x8_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extmul_low_i16x8_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extmul_high_i16x8_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extmul_low_i16x8_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.extmul_high_i16x8_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.abs'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.neg'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.all_true'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.bitmask'; Signature: 'v>i'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extend_low_i32x4_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extend_high_i32x4_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extend_low_i32x4_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extend_high_i32x4_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.shl'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.shr_s'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.shr_u'; Signature: 'vi>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.add'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.sub'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.mul'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.eq'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.ne'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.lt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.gt_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.le_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.ge_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extmul_low_i32x4_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extmul_high_i32x4_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extmul_low_i32x4_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.extmul_high_i32x4_u'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.abs'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.neg'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.sqrt'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.add'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.sub'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.mul'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.div'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.min'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.max'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.pmin'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.pmax'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.abs'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.neg'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.sqrt'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.add'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.sub'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.mul'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.div'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.min'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.max'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.pmin'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.pmax'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.trunc_sat_f32x4_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.trunc_sat_f32x4_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.convert_i32x4_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.convert_i32x4_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.trunc_sat_f64x2_s_zero'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.trunc_sat_f64x2_u_zero'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.convert_low_i32x4_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.convert_low_i32x4_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.relaxed_swizzle'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.relaxed_trunc_f32x4_s'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.relaxed_trunc_f32x4_u'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.relaxed_trunc_f64x2_s_zero'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.relaxed_trunc_f64x2_u_zero'; Signature: 'v>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.relaxed_madd'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.relaxed_nmadd'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.relaxed_madd'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.relaxed_nmadd'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i8x16.relaxed_laneselect'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.relaxed_laneselect'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.relaxed_laneselect'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i64x2.relaxed_laneselect'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.relaxed_min'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f32x4.relaxed_max'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.relaxed_min'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'f64x2.relaxed_max'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.relaxed_q15mulr_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i16x8.relaxed_dot_i8x16_i7x16_s'; Signature: 'vv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i32x4.relaxed_dot_i8x16_i7x16_add_s'; Signature: 'vvv>v'; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'struct.new'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'struct.new_default'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'struct.get'; Signature: ''; Immediate: ikTypeField; Alignment: -1; Lanes: 0),
    (Name: 'struct.get_s'; Signature: ''; Immediate: ikTypeField; Alignment: -1; Lanes: 0),
    (Name: 'struct.get_u'; Signature: ''; Immediate: ikTypeField; Alignment: -1; Lanes: 0),
    (Name: 'struct.set'; Signature: ''; Immediate: ikTypeField; Alignment: -1; Lanes: 0),
    (Name: 'array.new'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.new_default'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.new_fixed'; Signature: ''; Immediate: ikTypeCount; Alignment: -1; Lanes: 0),
    (Name: 'array.new_data'; Signature: ''; Immediate: ikTypeData; Alignment: -1; Lanes: 0),
    (Name: 'array.new_elem'; Signature: ''; Immediate: ikTypeElement; Alignment: -1; Lanes: 0),
    (Name: 'array.get'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.get_s'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.get_u'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.set'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.len'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'array.fill'; Signature: ''; Immediate: ikTypeIndex; Alignment: -1; Lanes: 0),
    (Name: 'array.copy'; Signature: ''; Immediate: ikTypeType; Alignment: -1; Lanes: 0),
    (Name: 'array.init_data'; Signature: ''; Immediate: ikTypeData; Alignment: -1; Lanes: 0),
    (Name: 'array.init_elem'; Signature: ''; Immediate: ikTypeElement; Alignment: -1; Lanes: 0),
    (Name: 'ref.test'; Signature: ''; Immediate: ikHeapType; Alignment: -1; Lanes: 0),
    (Name: 'ref.test'; Signature: ''; Immediate: ikHeapType; Alignment: -1; Lanes: 0),
    (Name: 'ref.cast'; Signature: ''; Immediate: ikHeapType; Alignment: -1; Lanes: 0),
    (Name: 'ref.cast'; Signature: ''; Immediate: ikHeapType; Alignment: -1; Lanes: 0),
    (Name: 'br_on_cast'; Signature: ''; Immediate: ikBranchCast; Alignment: -1; Lanes: 0),
    (Name: 'br_on_cast_fail'; Signature: ''; Immediate: ikBranchCast; Alignment: -1; Lanes: 0),
    (Name: 'any.convert_extern'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'extern.convert_any'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'ref.i31'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i31.get_s'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: 'i31.get_u'; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0),
    (Name: ''; Signature: ''; Immediate: ikNone; Alignment: -1; Lanes: 0)
  );

{ The text format name of an instruction code, or 'opcode 0x..' when the
  code names none. }
function WasmOpcodeName(Code: Integer): AnsiString;

{ Whether Code is an instruction of WebAssembly 3.0. }
function IsWasmOpcode(Code: Integer): Boolean; inline;

implementation

uses
  SysUtils;

function IsWasmOpcode(Code: Integer): Boolean;
begin
  Result := (Code >= 0) and (Code <= LastWasmOpcode) and (WasmOpcodeTable[Code].Name <> '');
end;

function WasmOpcodeName(Code: Integer): AnsiString;
begin
  if IsWasmOpcode(Code) then
    Result := WasmOpcodeTable[Code].Name
  else if Code >= GcOpcodeBase then
    Result := Format('opcode 0xFB %d', [Code - GcOpcodeBase])
  else if Code >= $200 then
    Result := Format('opcode 0xFD %d', [Code - $200])
  else if Code >= $100 then
    Result := Format('opcode 0xFC %d', [Code - $100])
  else
    Result := Format('opcode 0x%.2X', [Code]);
end;

end.
