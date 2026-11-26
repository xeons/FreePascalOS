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
  The types of WebAssembly 3.0 as the text front end keeps them: already
  in their binary encoding (core specification 3.0, section 5.3), so
  that comparing two types is comparing bytes and writing one is copying
  them.

  A value type is a byte string: one byte for a number or vector type
  and for the nullable abstract reference types (funcref, anyref, ...,
  which are the same byte as their heap type), otherwise 0x63 (ref null)
  or 0x64 (ref) followed by the heap type as a signed LEB128 (s33): an
  abstract heap type as its negative one byte code, a type index as a
  non-negative number. (ref null func) and funcref are thus written the
  same, as the binary format writes them shortest.

  Type definitions: function, structure and array types (composite
  types), each a subtype (final or not, with its supertypes) in a
  recursion group. The type section is a list of groups; a type written
  without "rec" is a group of its own, and one written as plainly final
  without supertypes is encoded as just its composite type.
}
unit WasmText.Types;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WasmText.Binary;

const
  ValueTypeI32 = $7F;
  ValueTypeI64 = $7E;
  ValueTypeF32 = $7D;
  ValueTypeF64 = $7C;
  ValueTypeV128 = $7B;

  HeapTypeFunc = $70;
  HeapTypeExtern = $6F;
  HeapTypeAny = $6E;
  HeapTypeEq = $6D;
  HeapTypeI31 = $6C;
  HeapTypeStruct = $6B;
  HeapTypeArray = $6A;
  HeapTypeExn = $69;
  HeapTypeNone = $71;
  HeapTypeNoFunc = $73;
  HeapTypeNoExtern = $72;
  HeapTypeNoExn = $74;

  { The nullable abstract reference types share their heap type's byte. }
  ValueTypeFuncRef = HeapTypeFunc;
  ValueTypeExternRef = HeapTypeExtern;

  ReferenceNullable = $63;
  ReferenceNonNullable = $64;

  StorageTypeI8 = $78;
  StorageTypeI16 = $77;

  CompositeFunction = $60;
  CompositeStruct = $5F;
  CompositeArray = $5E;
  SubTypeOpen = $50;
  SubTypeFinal = $4F;
  RecursionGroup = $4E;

type
  TNameArray = array of AnsiString;

  { One value type (or storage type) in its binary encoding. }
  TValueType = TBytes;
  TValueTypeArray = array of TValueType;

  TFunctionType = record
    Parameters: TValueTypeArray;
    Results: TValueTypeArray;
  end;

  TFieldType = record
    StorageType: TValueType;
    Mutable: Boolean;
  end;

  TFieldTypeArray = array of TFieldType;

  TCompositeKind = (ckFunction, ckStruct, ckArray);

  TTypeDefinition = record
    Kind: TCompositeKind;
    FunctionType: TFunctionType;
    { A structure's fields; an array's element type as the only one. }
    Fields: TFieldTypeArray;
    { The fields' identifiers ('' when unnamed), for struct.get $t $f. }
    FieldNames: TNameArray;
    IsFinal: Boolean;
    SuperTypes: array of Cardinal;
    { The size of the recursion group this type belongs to. }
    GroupSize: Cardinal;
  end;

  TTypeGroup = record
    First, Count: Cardinal;
    { Written as "(rec ...)": encoded as a group even when it holds one
      type (or none). }
    IsRecursive: Boolean;
  end;

{ Single byte codes: number and vector types, abstract heap types, the
  reference type abbreviations, storage types. False when Keyword is
  not one. }
function NumberTypeCode(const Keyword: AnsiString; out Code: Byte): Boolean;
function AbstractHeapTypeCode(const Keyword: AnsiString; out Code: Byte): Boolean;
function ReferenceAbbreviationCode(const Keyword: AnsiString; out Code: Byte): Boolean;
function PackedTypeCode(const Keyword: AnsiString; out Code: Byte): Boolean;

function SingleByte(Code: Byte): TValueType;
function HeapTypeOfIndex(Index: Cardinal): TValueType;
{ True for the encoding of an abstract heap type (a type index's first
  byte is below $40). }
function IsAbstractHeapType(const HeapType: TValueType): Boolean;
{ (ref null? HeapType), shortest. }
function MakeReferenceType(Nullable: Boolean; const HeapType: TValueType): TValueType;
{ Splits a reference type into nullability and heap type. False for a
  number or vector type. }
function SplitReferenceType(const ReferenceType: TValueType; out Nullable: Boolean;
  out HeapType: TValueType): Boolean;

function SameValueType(const Left, Right: TValueType): Boolean;
function SameValueTypes(const Left, Right: TValueTypeArray): Boolean;
function SameFunctionType(const Left, Right: TFunctionType): Boolean;
procedure AppendValueType(var Types: TValueTypeArray; const ValueType: TValueType);

procedure WriteValueType(Writer: TBinaryWriter; const ValueType: TValueType);
{ A vector of value types: the count, then each. }
procedure WriteValueTypes(Writer: TBinaryWriter; const Types: TValueTypeArray);
{ A subtype: (sub final? x* comptype), or just the composite type. }
procedure WriteTypeDefinition(Writer: TBinaryWriter; const Definition: TTypeDefinition);

{ A function type alone in its group, final, without supertypes: the
  only kind an implicit type use may reuse. }
function IsStandaloneFunctionType(const Definition: TTypeDefinition): Boolean;

implementation

function NumberTypeCode(const Keyword: AnsiString; out Code: Byte): Boolean;
begin
  Result := True;
  if Keyword = 'i32' then Code := ValueTypeI32
  else if Keyword = 'i64' then Code := ValueTypeI64
  else if Keyword = 'f32' then Code := ValueTypeF32
  else if Keyword = 'f64' then Code := ValueTypeF64
  else if Keyword = 'v128' then Code := ValueTypeV128
  else
  begin
    Code := 0;
    Result := False;
  end;
end;

function AbstractHeapTypeCode(const Keyword: AnsiString; out Code: Byte): Boolean;
begin
  Result := True;
  if Keyword = 'func' then Code := HeapTypeFunc
  else if Keyword = 'extern' then Code := HeapTypeExtern
  else if Keyword = 'any' then Code := HeapTypeAny
  else if Keyword = 'eq' then Code := HeapTypeEq
  else if Keyword = 'i31' then Code := HeapTypeI31
  else if Keyword = 'struct' then Code := HeapTypeStruct
  else if Keyword = 'array' then Code := HeapTypeArray
  else if Keyword = 'exn' then Code := HeapTypeExn
  else if Keyword = 'none' then Code := HeapTypeNone
  else if Keyword = 'nofunc' then Code := HeapTypeNoFunc
  else if Keyword = 'noextern' then Code := HeapTypeNoExtern
  else if Keyword = 'noexn' then Code := HeapTypeNoExn
  else
  begin
    Code := 0;
    Result := False;
  end;
end;

function ReferenceAbbreviationCode(const Keyword: AnsiString; out Code: Byte): Boolean;
begin
  Result := True;
  if Keyword = 'funcref' then Code := HeapTypeFunc
  else if Keyword = 'externref' then Code := HeapTypeExtern
  else if Keyword = 'anyref' then Code := HeapTypeAny
  else if Keyword = 'eqref' then Code := HeapTypeEq
  else if Keyword = 'i31ref' then Code := HeapTypeI31
  else if Keyword = 'structref' then Code := HeapTypeStruct
  else if Keyword = 'arrayref' then Code := HeapTypeArray
  else if Keyword = 'exnref' then Code := HeapTypeExn
  else if Keyword = 'nullref' then Code := HeapTypeNone
  else if Keyword = 'nullfuncref' then Code := HeapTypeNoFunc
  else if Keyword = 'nullexternref' then Code := HeapTypeNoExtern
  else if Keyword = 'nullexnref' then Code := HeapTypeNoExn
  else
  begin
    Code := 0;
    Result := False;
  end;
end;

function PackedTypeCode(const Keyword: AnsiString; out Code: Byte): Boolean;
begin
  Result := True;
  if Keyword = 'i8' then Code := StorageTypeI8
  else if Keyword = 'i16' then Code := StorageTypeI16
  else
  begin
    Code := 0;
    Result := False;
  end;
end;

function SingleByte(Code: Byte): TValueType;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := Code;
end;

function HeapTypeOfIndex(Index: Cardinal): TValueType;
var
  Writer: TBinaryWriter;
begin
  Writer := TBinaryWriter.Create;
  try
    Writer.WriteSigned(Index);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

function IsAbstractHeapType(const HeapType: TValueType): Boolean;
begin
  Result := (Length(HeapType) = 1) and (HeapType[0] >= $40);
end;

function MakeReferenceType(Nullable: Boolean; const HeapType: TValueType): TValueType;
begin
  if Nullable and IsAbstractHeapType(HeapType) then
    Exit(Copy(HeapType));
  Result := nil;
  SetLength(Result, Length(HeapType) + 1);
  if Nullable then
    Result[0] := ReferenceNullable
  else
    Result[0] := ReferenceNonNullable;
  if HeapType <> nil then
    Move(HeapType[0], Result[1], Length(HeapType));
end;

function SplitReferenceType(const ReferenceType: TValueType; out Nullable: Boolean;
  out HeapType: TValueType): Boolean;
begin
  Nullable := False;
  HeapType := nil;
  Result := False;
  if Length(ReferenceType) = 0 then
    Exit;
  if (ReferenceType[0] = ReferenceNullable) or (ReferenceType[0] = ReferenceNonNullable) then
  begin
    Nullable := ReferenceType[0] = ReferenceNullable;
    HeapType := Copy(ReferenceType, 1, Length(ReferenceType) - 1);
    Result := True;
  end
  else if (Length(ReferenceType) = 1) and (ReferenceType[0] >= HeapTypeExn) and
          (ReferenceType[0] <= HeapTypeNoExn) then
  begin
    Nullable := True;
    HeapType := Copy(ReferenceType);
    Result := True;
  end;
end;

function SameValueType(const Left, Right: TValueType): Boolean;
var
  Index: Integer;
begin
  Result := Length(Left) = Length(Right);
  if Result then
    for Index := 0 to High(Left) do
      if Left[Index] <> Right[Index] then
        Exit(False);
end;

function SameValueTypes(const Left, Right: TValueTypeArray): Boolean;
var
  Index: Integer;
begin
  Result := Length(Left) = Length(Right);
  if Result then
    for Index := 0 to High(Left) do
      if not SameValueType(Left[Index], Right[Index]) then
        Exit(False);
end;

function SameFunctionType(const Left, Right: TFunctionType): Boolean;
begin
  Result := SameValueTypes(Left.Parameters, Right.Parameters) and SameValueTypes(Left.Results, Right.Results);
end;

procedure AppendValueType(var Types: TValueTypeArray; const ValueType: TValueType);
begin
  SetLength(Types, Length(Types) + 1);
  Types[High(Types)] := ValueType;
end;

procedure WriteValueType(Writer: TBinaryWriter; const ValueType: TValueType);
begin
  if ValueType <> nil then
    Writer.WriteRaw(ValueType[0], Length(ValueType));
end;

procedure WriteValueTypes(Writer: TBinaryWriter; const Types: TValueTypeArray);
var
  Index: Integer;
begin
  Writer.WriteUnsigned(Length(Types));
  for Index := 0 to High(Types) do
    WriteValueType(Writer, Types[Index]);
end;

procedure WriteField(Writer: TBinaryWriter; const Field: TFieldType);
begin
  WriteValueType(Writer, Field.StorageType);
  Writer.WriteByte(Ord(Field.Mutable));
end;

procedure WriteTypeDefinition(Writer: TBinaryWriter; const Definition: TTypeDefinition);
var
  Index: Integer;
begin
  if not Definition.IsFinal or (Length(Definition.SuperTypes) > 0) then
  begin
    if Definition.IsFinal then
      Writer.WriteByte(SubTypeFinal)
    else
      Writer.WriteByte(SubTypeOpen);
    Writer.WriteUnsigned(Length(Definition.SuperTypes));
    for Index := 0 to High(Definition.SuperTypes) do
      Writer.WriteUnsigned(Definition.SuperTypes[Index]);
  end;
  case Definition.Kind of
    ckFunction:
      begin
        Writer.WriteByte(CompositeFunction);
        WriteValueTypes(Writer, Definition.FunctionType.Parameters);
        WriteValueTypes(Writer, Definition.FunctionType.Results);
      end;
    ckStruct:
      begin
        Writer.WriteByte(CompositeStruct);
        Writer.WriteUnsigned(Length(Definition.Fields));
        for Index := 0 to High(Definition.Fields) do
          WriteField(Writer, Definition.Fields[Index]);
      end;
    ckArray:
      begin
        Writer.WriteByte(CompositeArray);
        WriteField(Writer, Definition.Fields[0]);
      end;
  end;
end;

function IsStandaloneFunctionType(const Definition: TTypeDefinition): Boolean;
begin
  Result := (Definition.Kind = ckFunction) and Definition.IsFinal and (Length(Definition.SuperTypes) = 0) and
    (Definition.GroupSize = 1);
end;

end.
