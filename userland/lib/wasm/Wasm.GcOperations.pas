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
  The garbage collection instructions at run time (the compiled forms
  of Wasm.Code, called by the interpreter) and the reference tests they
  and the embedder's interface share.

  Struct fields take a slot each (two for a v128) in the order of the
  operand stack, so struct.new copies its operands as they are; array
  elements take their storage size. Packed fields keep the low bits and
  are widened on reading. References are 64-bit words as Wasm.GcHeap
  describes; i31 values are their 31 bits shifted left by one, plus one,
  so equal i31s are equal words and ref.eq compares words.

  The operations return NoTrap or the trap kind (as an integer) instead
  of raising, so that the interpreter keeps its one place for traps.
  Allocating ones return Ord(tkOutOfMemory) when the heap is full; the
  interpreter collects and tries once more.
}
unit Wasm.GcOperations;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

uses
  Wasm.Types,
  Wasm.TypeDefinitions,
  Wasm.Code,
  Wasm.GcHeap,
  Wasm.TypeRegistry,
  Wasm.Runtime;

const
  NoTrap = -1;

function MakeI31(Value: DWord): QWord; inline;
function I31Signed(Reference: QWord): Int32; inline;
function I31Unsigned(Reference: QWord): DWord; inline;

{ Whether a non-null or null reference matches a heap type: an abstract
  one (negative) or Target (a store type) when concrete. The reference
  is known to be of the target's hierarchy. }
function ReferenceMatches(Store: TWasmStore; Reference: QWord; HeapType: Int32; Target: TWasmRuntimeType;
  Nullable: Boolean): Boolean;

{ any.convert_extern of a reference; nil (and False) when a box could not
  be allocated. }
function Internalize(Store: TWasmStore; Reference: QWord; out Converted: QWord): Boolean;
function Externalize(Store: TWasmStore; Reference: QWord): QWord;

{ The allocating instructions (struct.new and its forms, array.new and
  its forms, any.convert_extern). }
function ExecuteAllocation(Store: TWasmStore; Instance: TWasmModuleInstance; const Instruction: TCodeInstruction;
  Slots: PQWord): Integer;
{ The other garbage collection instructions. }
function ExecuteGcOperation(Store: TWasmStore; Instance: TWasmModuleInstance; const Instruction: TCodeInstruction;
  Slots: PQWord): Integer;

{ The access kind of a field (Wasm.Code's Access constants). }
function FieldAccess(const Field: TWasmFieldType; Signed: Boolean): Integer;

implementation

uses
  Wasm.Errors;

function MakeI31(Value: DWord): QWord;
begin
  Result := (QWord(Value and $7FFFFFFF) shl 1) or 1;
end;

function I31Signed(Reference: QWord): Int32;
begin
  Result := Int32(DWord(Reference shr 1) shl 1) div 2;
end;

function I31Unsigned(Reference: QWord): DWord;
begin
  Result := DWord(Reference shr 1) and $7FFFFFFF;
end;

function FieldAccess(const Field: TWasmFieldType; Signed: Boolean): Integer;
begin
  case Field.Storage of
    skI8: Result := AccessI8;
    skI16: Result := AccessI16;
  else
    case Field.ValueType.Kind of
      vkI32, vkF32: Result := Access32;
      vkV128: Result := Access128;
    else
      Result := Access64;
    end;
  end;
  if Signed then
    Result := Result or AccessSigned;
end;

function ReferenceMatches(Store: TWasmStore; Reference: QWord; HeapType: Int32; Target: TWasmRuntimeType;
  Nullable: Boolean): Boolean;
var
  Item: PWasmGcObject;
begin
  if Reference = 0 then
    Exit(Nullable);
  if HeapType >= 0 then
  begin
    if Target.Definition.Kind = ckFunction then
      Exit(Store.Registry.TypeOf(TWasmFunction(PtrUInt(Reference)).TypeId).IsSubtypeOf(Target));
    if Reference and 1 <> 0 then
      Exit(False);
    Item := PWasmGcObject(PtrUInt(Reference));
    if not (Item^.Kind in [okStruct, okArray]) then
      Exit(False);
    Exit(TWasmRuntimeType(Item^.Descriptor).IsSubtypeOf(Target));
  end;
  case HeapType of
    HeapTypeAny, HeapTypeFunc, HeapTypeExtern, HeapTypeExn:
      Result := True;
    HeapTypeI31:
      Result := Reference and 1 <> 0;
    HeapTypeEq, HeapTypeStruct, HeapTypeArray:
      begin
        if Reference and 1 <> 0 then
          Exit(HeapType = HeapTypeEq);
        Item := PWasmGcObject(PtrUInt(Reference));
        case HeapType of
          HeapTypeStruct: Result := Item^.Kind = okStruct;
          HeapTypeArray: Result := Item^.Kind = okArray;
        else
          Result := Item^.Kind in [okStruct, okArray];
        end;
      end;
  else
    Result := False;
  end;
end;

function Internalize(Store: TWasmStore; Reference: QWord; out Converted: QWord): Boolean;
var
  Box: PWasmGcObject;
begin
  Result := True;
  Converted := Reference;
  if (Reference = 0) or (Reference and 1 <> 0) or Store.Heap.IsObject(Pointer(PtrUInt(Reference))) then
    Exit;
  Box := Store.Heap.AllocateHostBox(Pointer(PtrUInt(Reference)));
  if Box = nil then
    Exit(False);
  Converted := QWord(PtrUInt(Box));
end;

function Externalize(Store: TWasmStore; Reference: QWord): QWord;
var
  Item: PWasmGcObject;
begin
  Result := Reference;
  if (Reference = 0) or (Reference and 1 <> 0) or not Store.Heap.IsObject(Pointer(PtrUInt(Reference))) then
    Exit;
  Item := PWasmGcObject(PtrUInt(Reference));
  if Item^.Kind = okHostBox then
    Result := QWord(PtrUInt(PPointer(ObjectPayload(Item))^));
end;

procedure ReadElement(Source: PByte; Access: Integer; Destination: PQWord); inline;
begin
  case Access of
    AccessI8: PDWord(Destination)^ := Source^;
    AccessI8 or AccessSigned: PInt32(Destination)^ := PShortInt(Source)^;
    AccessI16: PDWord(Destination)^ := PWord(Source)^;
    AccessI16 or AccessSigned: PInt32(Destination)^ := PSmallInt(Source)^;
    Access32: PDWord(Destination)^ := PDWord(Source)^;
    Access64: Destination^ := PQWord(Source)^;
  else
    begin
      Destination[0] := PQWord(Source)^;
      Destination[1] := PQWord(Source + 8)^;
    end;
  end;
end;

procedure WriteElement(Destination: PByte; Access: Integer; Source: PQWord); inline;
begin
  case Access and 7 of
    AccessI8: Destination^ := Byte(Source^);
    AccessI16: PWord(Destination)^ := Word(Source^);
    Access32: PDWord(Destination)^ := DWord(Source^);
    Access64: PQWord(Destination)^ := Source^;
  else
    begin
      PQWord(Destination)^ := Source[0];
      PQWord(Destination + 8)^ := Source[1];
    end;
  end;
end;

function AccessSlots(Access: Integer): Integer; inline;
begin
  if Access and 7 = Access128 then
    Result := 2
  else
    Result := 1;
end;

function ArrayAccess(RuntimeType: TWasmRuntimeType): Integer;
begin
  Result := FieldAccess(RuntimeType.Definition.Fields[0], False);
end;

function DataBytes(Instance: TWasmModuleInstance; Segment: Integer; out Bytes: PByte): QWord;
begin
  Bytes := nil;
  if Instance.DataDropped[Segment] then
    Exit(0);
  Result := Instance.Module.Data[Segment].DataLength;
  if Result > 0 then
    Bytes := @Instance.Module.Bytes[Instance.Module.Data[Segment].DataStart];
end;

function ExecuteAllocation(Store: TWasmStore; Instance: TWasmModuleInstance; const Instruction: TCodeInstruction;
  Slots: PQWord): Integer;
var
  RuntimeType: TWasmRuntimeType;
  Item: PWasmGcObject;
  Payload, Bytes: PByte;
  Length_, Offset, Index, Available: QWord;
  Access, Size, ValueSlots: Integer;
  Converted: QWord;
  Segment: array of Pointer;
begin
  Result := NoTrap;
  case Instruction.Operation of
    CodeAnyConvertExtern:
      begin
        if not Internalize(Store, Slots[Instruction.B], Converted) then
          Exit(Ord(tkOutOfMemory));
        Slots[Instruction.A] := Converted;
        Exit;
      end;
    CodeStructNew, CodeStructNewDefault:
      begin
        RuntimeType := Instance.RuntimeTypes[Instruction.B];
        Item := Store.Heap.AllocateStruct(RuntimeType, RuntimeType.PayloadSize);
        if Item = nil then
          Exit(Ord(tkOutOfMemory));
        if (Instruction.Operation = CodeStructNew) and (RuntimeType.PayloadSize > 0) then
          Move(Slots[Instruction.A], ObjectPayload(Item)^, RuntimeType.PayloadSize);
        Slots[Instruction.A] := QWord(PtrUInt(Item));
        Exit;
      end;
  end;
  { Arrays. }
  RuntimeType := Instance.RuntimeTypes[Instruction.B];
  Access := ArrayAccess(RuntimeType);
  Size := RuntimeType.ElementSize;
  ValueSlots := AccessSlots(Access);
  case Instruction.Operation of
    CodeArrayNew: Length_ := PDWord(@Slots[Instruction.A + ValueSlots])^;
    CodeArrayNewDefault: Length_ := PDWord(@Slots[Instruction.A])^;
    CodeArrayNewFixed: Length_ := DWord(Instruction.C);
  else
    Length_ := PDWord(@Slots[Instruction.A + 1])^;
  end;
  { Sources are checked before anything is allocated. }
  Offset := 0;
  Bytes := nil;
  Segment := nil;
  case Instruction.Operation of
    CodeArrayNewData:
      begin
        Offset := PDWord(@Slots[Instruction.A])^;
        Available := DataBytes(Instance, Instruction.C, Bytes);
        if (Offset > Available) or (Length_ * QWord(Size) > Available - Offset) then
          Exit(Ord(tkMemoryOutOfBounds));
      end;
    CodeArrayNewElem:
      begin
        Offset := PDWord(@Slots[Instruction.A])^;
        Segment := Instance.ElementSegments[Instruction.C];
        if (Offset > QWord(System.Length(Segment))) or (Length_ > QWord(System.Length(Segment)) - Offset) then
          Exit(Ord(tkTableOutOfBounds));
      end;
  end;
  Item := Store.Heap.AllocateArray(RuntimeType, Length_);
  if Item = nil then
    Exit(Ord(tkOutOfMemory));
  Payload := ObjectPayload(Item);
  case Instruction.Operation of
    CodeArrayNew:
      if Length_ > 0 then
        for Index := 0 to Length_ - 1 do
          WriteElement(Payload + Index * QWord(Size), Access, @Slots[Instruction.A]);
    CodeArrayNewFixed:
      if Length_ > 0 then
        for Index := 0 to Length_ - 1 do
          WriteElement(Payload + Index * QWord(Size), Access, @Slots[Instruction.A + Integer(Index) * ValueSlots]);
    CodeArrayNewData:
      if Length_ > 0 then
        Move(Bytes[Offset], Payload^, Length_ * QWord(Size));
    CodeArrayNewElem:
      if Length_ > 0 then
        Move(Segment[Offset], Payload^, Length_ * SizeOf(Pointer));
  end;
  Slots[Instruction.A] := QWord(PtrUInt(Item));
end;

{ The array at a slot, checked: NoTrap or the trap. }
function CheckedArray(Reference: QWord; out Item: PWasmGcObject): Integer; inline;
begin
  Item := PWasmGcObject(PtrUInt(Reference));
  if Item = nil then
    Result := Ord(tkNullArrayReference)
  else
    Result := NoTrap;
end;

function ExecuteGcOperation(Store: TWasmStore; Instance: TWasmModuleInstance; const Instruction: TCodeInstruction;
  Slots: PQWord): Integer;
var
  Item, Source: PWasmGcObject;
  Payload, Bytes: PByte;
  Index, Offset, SourceOffset, Count, Available: QWord;
  Size, ValueSlots: Integer;
  Target: TWasmRuntimeType;
  Matches: Boolean;
  Segment: array of Pointer;
  Reference: QWord;
begin
  Result := NoTrap;
  case Instruction.Operation of
    CodeRefTest, CodeRefCast:
      begin
        Target := nil;
        if Instruction.C >= 0 then
          Target := Instance.RuntimeTypes[Instruction.C];
        Reference := Slots[Instruction.B];
        Matches := ReferenceMatches(Store, Reference, Instruction.C, Target, Instruction.Extra and 1 <> 0);
        if Instruction.Operation = CodeRefCast then
        begin
          if not Matches then
            Exit(Ord(tkCastFailure));
          Slots[Instruction.A] := Reference;
        end
        else
          PDWord(@Slots[Instruction.A])^ := Ord(Matches <> (Instruction.Extra and 2 <> 0));
      end;
    CodeStructGet:
      begin
        Item := PWasmGcObject(PtrUInt(Slots[Instruction.B]));
        if Item = nil then
          Exit(Ord(tkNullStructureReference));
        ReadElement(ObjectPayload(Item) + Instruction.C, Instruction.Extra, @Slots[Instruction.A]);
      end;
    CodeStructSet:
      begin
        Item := PWasmGcObject(PtrUInt(Slots[Instruction.A]));
        if Item = nil then
          Exit(Ord(tkNullStructureReference));
        WriteElement(ObjectPayload(Item) + Instruction.C, Instruction.Extra, @Slots[Instruction.B]);
      end;
    CodeArrayLen:
      begin
        Result := CheckedArray(Slots[Instruction.B], Item);
        if Result = NoTrap then
          PDWord(@Slots[Instruction.A])^ := Item^.Length;
      end;
    CodeArrayGet:
      begin
        Result := CheckedArray(Slots[Instruction.B], Item);
        if Result <> NoTrap then
          Exit;
        Index := PDWord(@Slots[Instruction.C])^;
        if Index >= Item^.Length then
          Exit(Ord(tkArrayOutOfBounds));
        ReadElement(ObjectPayload(Item) + Index * QWord(Item^.Descriptor.ElementSize), Instruction.Extra,
          @Slots[Instruction.A]);
      end;
    CodeArraySet:
      begin
        Result := CheckedArray(Slots[Instruction.A], Item);
        if Result <> NoTrap then
          Exit;
        Index := PDWord(@Slots[Instruction.A + 1])^;
        if Index >= Item^.Length then
          Exit(Ord(tkArrayOutOfBounds));
        WriteElement(ObjectPayload(Item) + Index * QWord(Item^.Descriptor.ElementSize), Instruction.Extra,
          @Slots[Instruction.A + 2]);
      end;
    CodeArrayFill:
      begin
        Result := CheckedArray(Slots[Instruction.A], Item);
        if Result <> NoTrap then
          Exit;
        ValueSlots := AccessSlots(Instruction.Extra);
        Offset := PDWord(@Slots[Instruction.A + 1])^;
        Count := PDWord(@Slots[Instruction.A + 2 + ValueSlots])^;
        if (Offset > Item^.Length) or (Count > Item^.Length - Offset) then
          Exit(Ord(tkArrayOutOfBounds));
        Size := Item^.Descriptor.ElementSize;
        Payload := ObjectPayload(Item);
        Index := 0;
        while Index < Count do
        begin
          WriteElement(Payload + (Offset + Index) * QWord(Size), Instruction.Extra, @Slots[Instruction.A + 2]);
          Inc(Index);
        end;
      end;
    CodeArrayCopy:
      begin
        Result := CheckedArray(Slots[Instruction.A], Item);
        if Result = NoTrap then
          Result := CheckedArray(Slots[Instruction.A + 2], Source);
        if Result <> NoTrap then
          Exit;
        Offset := PDWord(@Slots[Instruction.A + 1])^;
        SourceOffset := PDWord(@Slots[Instruction.A + 3])^;
        Count := PDWord(@Slots[Instruction.A + 4])^;
        if (Offset > Item^.Length) or (Count > Item^.Length - Offset) or (SourceOffset > Source^.Length) or
          (Count > Source^.Length - SourceOffset) then
          Exit(Ord(tkArrayOutOfBounds));
        Size := Item^.Descriptor.ElementSize;
        if Count > 0 then
          Move(ObjectPayload(Source)[SourceOffset * QWord(Size)], ObjectPayload(Item)[Offset * QWord(Size)],
            Count * QWord(Size));
      end;
    CodeArrayInitData, CodeArrayInitElem:
      begin
        Result := CheckedArray(Slots[Instruction.A], Item);
        if Result <> NoTrap then
          Exit;
        Offset := PDWord(@Slots[Instruction.A + 1])^;
        SourceOffset := PDWord(@Slots[Instruction.A + 2])^;
        Count := PDWord(@Slots[Instruction.A + 3])^;
        if (Offset > Item^.Length) or (Count > Item^.Length - Offset) then
          Exit(Ord(tkArrayOutOfBounds));
        Size := Item^.Descriptor.ElementSize;
        if Instruction.Operation = CodeArrayInitData then
        begin
          Available := DataBytes(Instance, Instruction.C, Bytes);
          if (SourceOffset > Available) or (Count * QWord(Size) > Available - SourceOffset) then
            Exit(Ord(tkMemoryOutOfBounds));
          if Count > 0 then
            Move(Bytes[SourceOffset], ObjectPayload(Item)[Offset * QWord(Size)], Count * QWord(Size));
        end
        else
        begin
          Segment := Instance.ElementSegments[Instruction.C];
          if (SourceOffset > QWord(Length(Segment))) or (Count > QWord(Length(Segment)) - SourceOffset) then
            Exit(Ord(tkTableOutOfBounds));
          if Count > 0 then
            Move(Segment[SourceOffset], ObjectPayload(Item)[Offset * 8], Count * 8);
        end;
      end;
    CodeExternConvertAny:
      Slots[Instruction.A] := Externalize(Store, Slots[Instruction.B]);
    CodeRefI31:
      Slots[Instruction.A] := MakeI31(PDWord(@Slots[Instruction.B])^);
    CodeI31Get:
      begin
        Reference := Slots[Instruction.B];
        if Reference = 0 then
          Exit(Ord(tkNullI31Reference));
        if Instruction.Extra <> 0 then
          PInt32(@Slots[Instruction.A])^ := I31Signed(Reference)
        else
          PDWord(@Slots[Instruction.A])^ := I31Unsigned(Reference);
      end;
  end;
end;

end.
