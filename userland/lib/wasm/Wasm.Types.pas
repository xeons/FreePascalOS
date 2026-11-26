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
  WebAssembly's types (spec section 2.3) and values.

  A value type is a record rather than a byte: a kind, and for references
  whether null is allowed and the heap type. Abstract heap types (func,
  extern, any, eq, i31, struct, array, exn and the bottom types none,
  nofunc, noextern, noexn) are their binary codes as negative numbers
  (HeapTypeFunc = -16 for 0x70 ...); a concrete heap type is a type
  index, zero or more. In a module's types (Wasm.Module) the index is
  the module's own, made canonical by the validator (the first of the
  equivalent types); in the run time's types (functions, globals, tables
  and tags of a store) it is the store's canonical type id
  (Wasm.TypeRegistry). Storage types add the packed i8 and i16 of struct
  fields and array elements.

  A TWasmValue is a value as the embedder sees it: its type and its bits.
  Floating point values are kept as bits (F32Bits, F64Bits) so that NaN
  payloads pass through unchanged. References are pointers: a funcref
  is the TWasmFunction (Wasm.Runtime), an externref whatever the embedder
  gave; nil is null for both.
}
unit Wasm.Types;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

const
  HeapTypeNoExn = -12;    { 0x74 }
  HeapTypeNoFunc = -13;   { 0x73 }
  HeapTypeNoExtern = -14; { 0x72 }
  HeapTypeNone = -15;     { 0x71 }
  HeapTypeFunc = -16;     { 0x70 }
  HeapTypeExtern = -17;   { 0x6F }
  HeapTypeAny = -18;      { 0x6E }
  HeapTypeEq = -19;       { 0x6D }
  HeapTypeI31 = -20;      { 0x6C }
  HeapTypeStruct = -21;   { 0x6B }
  HeapTypeArray = -22;    { 0x6A }
  HeapTypeExn = -23;      { 0x69 }
  { The lowest abstract heap type code. }
  FirstAbstractHeapType = HeapTypeExn;

type
  TWasmValueKind = (vkI32, vkI64, vkF32, vkF64, vkV128, vkReference);

  TWasmValueType = record
    Kind: TWasmValueKind;
    Nullable: Boolean;
    HeapType: Int32;
    class operator =(const A, B: TWasmValueType): Boolean;
    class operator <>(const A, B: TWasmValueType): Boolean;
  end;
  TWasmValueTypeArray = array of TWasmValueType;

  TWasmFunctionType = record
    Params: TWasmValueTypeArray;
    Results: TWasmValueTypeArray;
  end;
  TWasmFunctionTypeArray = array of TWasmFunctionType;

  TWasmLimits = record
    Minimum: QWord;
    Maximum: QWord;
    HasMaximum: Boolean;
  end;

  { Tables and memories are addressed with i32 or, with memory64 and
    table64, i64 (AddressType vkI64). }
  TWasmTableType = record
    ElementType: TWasmValueType;
    Limits: TWasmLimits;
    AddressType: TWasmValueKind;
  end;

  TWasmMemoryType = record
    Limits: TWasmLimits;
    AddressType: TWasmValueKind;
  end;

  TWasmGlobalType = record
    ValueType: TWasmValueType;
    Mutable: Boolean;
  end;

  TWasmExternalKind = (ekFunction, ekTable, ekMemory, ekGlobal, ekTag);

  { A tag (exception handling): the type of its payload, a function type
    without results. TypeIndex is the module's type index (in a module)
    or the store's canonical type id (at run time). }
  TWasmTagType = record
    TypeIndex: Cardinal;
    FunctionType: TWasmFunctionType;
  end;

  TWasmV128 = record
    case Integer of
      0: (Bytes: array[0..15] of Byte);
      1: (Words: array[0..7] of Word);
      2: (DWords: array[0..3] of DWord);
      3: (QWords: array[0..1] of QWord);
  end;

  TWasmValue = record
    ValueType: TWasmValueType;
    case Integer of
      0: (I32: Int32);
      1: (I64: Int64);
      2: (F32Bits: DWord);
      3: (F64Bits: QWord);
      4: (V128: TWasmV128);
      5: (Reference: Pointer);
  end;
  TWasmValueArray = array of TWasmValue;

const
  WasmPageSize = 65536;

function MakeNumberType(Kind: TWasmValueKind): TWasmValueType; inline;
function MakeReferenceType(HeapType: Int32; Nullable: Boolean = True): TWasmValueType; inline;
function WasmI32Type: TWasmValueType; inline;
function WasmI64Type: TWasmValueType; inline;
function WasmF32Type: TWasmValueType; inline;
function WasmF64Type: TWasmValueType; inline;
function WasmV128Type: TWasmValueType; inline;
function WasmFuncRefType: TWasmValueType; inline;
function WasmExternRefType: TWasmValueType; inline;

function IsReferenceType(const ValueType: TWasmValueType): Boolean; inline;
function IsNumberOrVectorType(const ValueType: TWasmValueType): Boolean; inline;
{ Whether a local of the type starts with a default value (all but the
  non-nullable references). }
function IsDefaultable(const ValueType: TWasmValueType): Boolean; inline;
function IsAbstractHeapType(HeapType: Int32): Boolean; inline;
{ The top of an abstract heap type's hierarchy: func, extern, any or exn
  (for a concrete type, its kind decides: see Wasm.Subtyping). }
function AbstractHeapTypeTop(HeapType: Int32): Int32;
{ The bottom of the hierarchy whose top is Top: nofunc, noextern, none,
  noexn. }
function HierarchyBottom(Top: Int32): Int32;
function HeapTypeName(HeapType: Int32): AnsiString;
{ An abstract heap type from its binary code (0x69 to 0x74). }
function DecodeAbstractHeapType(Code: Byte; out HeapType: Int32): Boolean;
{ The 64-bit slots a value of the type takes in a frame: two for v128. }
function SlotCount(const ValueType: TWasmValueType): Integer; inline;
function SlotCountOf(const Types: TWasmValueTypeArray): Integer;

{ The value type a one byte binary code names (0x7F i32 ... 0x6F
  externref, and the other nullable abstract reference shorthands);
  the two byte forms 0x63 / 0x64 are read by Wasm.Reader. }
function DecodeValueType(Code: Byte; out ValueType: TWasmValueType): Boolean;
function ValueTypeToString(const ValueType: TWasmValueType): AnsiString;
function ValueTypesToString(const Types: TWasmValueTypeArray): AnsiString;
function FunctionTypeToString(const FunctionType: TWasmFunctionType): AnsiString;
function FunctionTypesEqual(const A, B: TWasmFunctionType): Boolean;
function ExternalKindName(Kind: TWasmExternalKind): AnsiString;

function WasmI32(Value: Int32): TWasmValue;
function WasmI64(Value: Int64): TWasmValue;
function WasmF32(Value: Single): TWasmValue;
function WasmF64(Value: Double): TWasmValue;
function WasmF32FromBits(Bits: DWord): TWasmValue;
function WasmF64FromBits(Bits: QWord): TWasmValue;
function WasmV128(const Value: TWasmV128): TWasmValue;
function WasmReference(const ValueType: TWasmValueType; Reference: Pointer): TWasmValue;
function WasmFuncRef(FunctionInstance: Pointer): TWasmValue;
function WasmExternRef(Reference: Pointer): TWasmValue;
{ The default value of a type (zero, or null). }
function WasmDefaultValue(const ValueType: TWasmValueType): TWasmValue;

implementation

uses
  SysUtils;

class operator TWasmValueType.=(const A, B: TWasmValueType): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  if A.Kind <> vkReference then
    Exit(True);
  Result := (A.Nullable = B.Nullable) and (A.HeapType = B.HeapType);
end;

class operator TWasmValueType.<>(const A, B: TWasmValueType): Boolean;
begin
  Result := not (A = B);
end;

function MakeNumberType(Kind: TWasmValueKind): TWasmValueType;
begin
  Result.Kind := Kind;
  Result.Nullable := False;
  Result.HeapType := 0;
end;

function MakeReferenceType(HeapType: Int32; Nullable: Boolean): TWasmValueType;
begin
  Result.Kind := vkReference;
  Result.Nullable := Nullable;
  Result.HeapType := HeapType;
end;

function WasmI32Type: TWasmValueType;
begin
  Result := MakeNumberType(vkI32);
end;

function WasmI64Type: TWasmValueType;
begin
  Result := MakeNumberType(vkI64);
end;

function WasmF32Type: TWasmValueType;
begin
  Result := MakeNumberType(vkF32);
end;

function WasmF64Type: TWasmValueType;
begin
  Result := MakeNumberType(vkF64);
end;

function WasmV128Type: TWasmValueType;
begin
  Result := MakeNumberType(vkV128);
end;

function WasmFuncRefType: TWasmValueType;
begin
  Result := MakeReferenceType(HeapTypeFunc);
end;

function WasmExternRefType: TWasmValueType;
begin
  Result := MakeReferenceType(HeapTypeExtern);
end;

function IsReferenceType(const ValueType: TWasmValueType): Boolean;
begin
  Result := ValueType.Kind = vkReference;
end;

function IsNumberOrVectorType(const ValueType: TWasmValueType): Boolean;
begin
  Result := ValueType.Kind <> vkReference;
end;

function IsDefaultable(const ValueType: TWasmValueType): Boolean;
begin
  Result := (ValueType.Kind <> vkReference) or ValueType.Nullable;
end;

function IsAbstractHeapType(HeapType: Int32): Boolean;
begin
  Result := HeapType < 0;
end;

function AbstractHeapTypeTop(HeapType: Int32): Int32;
begin
  case HeapType of
    HeapTypeFunc, HeapTypeNoFunc: Result := HeapTypeFunc;
    HeapTypeExtern, HeapTypeNoExtern: Result := HeapTypeExtern;
    HeapTypeExn, HeapTypeNoExn: Result := HeapTypeExn;
  else
    Result := HeapTypeAny;
  end;
end;

function HierarchyBottom(Top: Int32): Int32;
begin
  case Top of
    HeapTypeFunc: Result := HeapTypeNoFunc;
    HeapTypeExtern: Result := HeapTypeNoExtern;
    HeapTypeExn: Result := HeapTypeNoExn;
  else
    Result := HeapTypeNone;
  end;
end;

function HeapTypeName(HeapType: Int32): AnsiString;
begin
  case HeapType of
    HeapTypeNoExn: Result := 'noexn';
    HeapTypeNoFunc: Result := 'nofunc';
    HeapTypeNoExtern: Result := 'noextern';
    HeapTypeNone: Result := 'none';
    HeapTypeFunc: Result := 'func';
    HeapTypeExtern: Result := 'extern';
    HeapTypeAny: Result := 'any';
    HeapTypeEq: Result := 'eq';
    HeapTypeI31: Result := 'i31';
    HeapTypeStruct: Result := 'struct';
    HeapTypeArray: Result := 'array';
    HeapTypeExn: Result := 'exn';
  else
    Result := IntToStr(HeapType);
  end;
end;

function DecodeAbstractHeapType(Code: Byte; out HeapType: Int32): Boolean;
begin
  Result := (Code >= $69) and (Code <= $74);
  if Result then
    HeapType := Int32(Code) - $80
  else
    HeapType := 0;
end;

function SlotCount(const ValueType: TWasmValueType): Integer;
begin
  if ValueType.Kind = vkV128 then
    Result := 2
  else
    Result := 1;
end;

function SlotCountOf(const Types: TWasmValueTypeArray): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Types) do
    Inc(Result, SlotCount(Types[Index]));
end;

function DecodeValueType(Code: Byte; out ValueType: TWasmValueType): Boolean;
begin
  Result := True;
  case Code of
    $7F: ValueType := WasmI32Type;
    $7E: ValueType := WasmI64Type;
    $7D: ValueType := WasmF32Type;
    $7C: ValueType := WasmF64Type;
    $7B: ValueType := WasmV128Type;
    $69..$74: ValueType := MakeReferenceType(Int32(Code) - $80);
  else
    ValueType := WasmI32Type;
    Result := False;
  end;
end;

function ValueTypeToString(const ValueType: TWasmValueType): AnsiString;
begin
  case ValueType.Kind of
    vkI32: Result := 'i32';
    vkI64: Result := 'i64';
    vkF32: Result := 'f32';
    vkF64: Result := 'f64';
    vkV128: Result := 'v128';
  else
    if ValueType.Nullable and (ValueType.HeapType = HeapTypeFunc) then
      Result := 'funcref'
    else if ValueType.Nullable and (ValueType.HeapType = HeapTypeExtern) then
      Result := 'externref'
    else
    begin
      Result := '(ref ';
      if ValueType.Nullable then
        Result := Result + 'null ';
      Result := Result + HeapTypeName(ValueType.HeapType) + ')';
    end;
  end;
end;

function ValueTypesToString(const Types: TWasmValueTypeArray): AnsiString;
var
  Index: Integer;
begin
  Result := '[';
  for Index := 0 to High(Types) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + ValueTypeToString(Types[Index]);
  end;
  Result := Result + ']';
end;

function FunctionTypeToString(const FunctionType: TWasmFunctionType): AnsiString;
begin
  Result := ValueTypesToString(FunctionType.Params) + ' -> ' + ValueTypesToString(FunctionType.Results);
end;

function FunctionTypesEqual(const A, B: TWasmFunctionType): Boolean;
var
  Index: Integer;
begin
  if (Length(A.Params) <> Length(B.Params)) or (Length(A.Results) <> Length(B.Results)) then
    Exit(False);
  for Index := 0 to High(A.Params) do
    if A.Params[Index] <> B.Params[Index] then
      Exit(False);
  for Index := 0 to High(A.Results) do
    if A.Results[Index] <> B.Results[Index] then
      Exit(False);
  Result := True;
end;

function ExternalKindName(Kind: TWasmExternalKind): AnsiString;
begin
  case Kind of
    ekFunction: Result := 'function';
    ekTable: Result := 'table';
    ekMemory: Result := 'memory';
    ekTag: Result := 'tag';
  else
    Result := 'global';
  end;
end;

function WasmI32(Value: Int32): TWasmValue;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ValueType := WasmI32Type;
  Result.I32 := Value;
end;

function WasmI64(Value: Int64): TWasmValue;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ValueType := WasmI64Type;
  Result.I64 := Value;
end;

function WasmF32(Value: Single): TWasmValue;
begin
  Result := WasmF32FromBits(PDWord(@Value)^);
end;

function WasmF64(Value: Double): TWasmValue;
begin
  Result := WasmF64FromBits(PQWord(@Value)^);
end;

function WasmF32FromBits(Bits: DWord): TWasmValue;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ValueType := WasmF32Type;
  Result.F32Bits := Bits;
end;

function WasmF64FromBits(Bits: QWord): TWasmValue;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ValueType := WasmF64Type;
  Result.F64Bits := Bits;
end;

function WasmV128(const Value: TWasmV128): TWasmValue;
begin
  Result.ValueType := WasmV128Type;
  Result.V128 := Value;
end;

function WasmReference(const ValueType: TWasmValueType; Reference: Pointer): TWasmValue;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ValueType := ValueType;
  Result.Reference := Reference;
end;

function WasmFuncRef(FunctionInstance: Pointer): TWasmValue;
begin
  Result := WasmReference(WasmFuncRefType, FunctionInstance);
end;

function WasmExternRef(Reference: Pointer): TWasmValue;
begin
  Result := WasmReference(WasmExternRefType, Reference);
end;

function WasmDefaultValue(const ValueType: TWasmValueType): TWasmValue;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ValueType := ValueType;
end;

end.
