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

{ The embedder's interface (Wasm.Api): tags and exceptions, references
  of the garbage collected kinds, and collection. }

function WasmNewTag(Store: TWasmStore; const FunctionType: TWasmFunctionType): TWasmTag;
begin
  if Length(FunctionType.Results) <> 0 then
    raise EWasmError.Create('a tag type has no results');
  Result := Store.NewTag(FunctionType);
end;

function WasmTagType(Tag: TWasmTag): TWasmFunctionType;
begin
  Result := Tag.FunctionType;
end;

function WasmNewException(Store: TWasmStore; Tag: TWasmTag; const Payload: TWasmValueArray): Pointer;
begin
  Result := NewExceptionObject(Store, Tag, Payload);
  Store.Heap.Expose(Result);
end;

function WasmExceptionTag(Exception: Pointer): TWasmTag;
begin
  Result := ExceptionTagOf(Exception);
end;

function WasmExceptionPayload(Exception: Pointer): TWasmValueArray;
begin
  Result := ExceptionPayloadOf(Exception);
end;

procedure WasmThrow(Store: TWasmStore; Tag: TWasmTag; const Payload: TWasmValueArray);
begin
  RaiseWasmException(Store, Tag, Payload);
end;

procedure WasmThrowException(Store: TWasmStore; Exception: Pointer);
begin
  if Exception = nil then
    raise EWasmError.Create('null exception');
  raise EWasmException.CreateFor(Store, Exception);
end;

function WasmClassifyReference(Store: TWasmStore; Reference: Pointer; const ValueType: TWasmValueType): TWasmReferenceKind;
var
  Item: PWasmGcObject;
begin
  if Reference = nil then
    Exit(rkNull);
  if HeapTypeTop(Store.Registry, ValueType.HeapType) = HeapTypeFunc then
    Exit(rkFunction);
  if PtrUInt(Reference) and 1 <> 0 then
    Exit(rkI31);
  if not Store.Heap.IsObject(Reference) then
    Exit(rkHostValue);
  Item := PWasmGcObject(Reference);
  case Item^.Kind of
    okStruct: Result := rkStruct;
    okArray: Result := rkArray;
    okException: Result := rkException;
  else
    Result := rkBoxedHostValue;
  end;
end;

function WasmMakeI31(Value: Int32): Pointer;
begin
  Result := Pointer(PtrUInt(MakeI31(DWord(Value))));
end;

function WasmI31Value(Reference: Pointer; Signed: Boolean): Int32;
begin
  if Signed then
    Result := I31Signed(QWord(PtrUInt(Reference)))
  else
    Result := Int32(I31Unsigned(QWord(PtrUInt(Reference))));
end;

function WasmInternalize(Store: TWasmStore; Reference: Pointer): Pointer;
var
  Converted: QWord;
begin
  if not Internalize(Store, QWord(PtrUInt(Reference)), Converted) then
  begin
    Store.CollectGarbage;
    if not Internalize(Store, QWord(PtrUInt(Reference)), Converted) then
      raise EWasmTrap.CreateTrap(tkOutOfMemory);
  end;
  Result := Pointer(PtrUInt(Converted));
  Store.Heap.Expose(Result);
end;

function WasmExternalize(Store: TWasmStore; Reference: Pointer): Pointer;
begin
  Result := Pointer(PtrUInt(Externalize(Store, QWord(PtrUInt(Reference)))));
end;

function WasmValueMatchesType(Store: TWasmStore; const Value: TWasmValue; const ValueType: TWasmValueType): Boolean;
begin
  Result := ValueMatchesType(Store, Value, ValueType);
end;

function StructOf(Reference: Pointer): PWasmGcObject;
begin
  Result := PWasmGcObject(Reference);
  if (Result = nil) or (PtrUInt(Reference) and 1 <> 0) or (Result^.Kind <> okStruct) then
    raise EWasmError.Create('not a struct');
end;

function ArrayOf(Reference: Pointer): PWasmGcObject;
begin
  Result := PWasmGcObject(Reference);
  if (Result = nil) or (PtrUInt(Reference) and 1 <> 0) or (Result^.Kind <> okArray) then
    raise EWasmError.Create('not an array');
end;

{ A field's or element's value from its storage. }
function StoredValue(Store: TWasmStore; const Field: TWasmFieldType; At: PByte): TWasmValue;
var
  Slots: array[0..1] of QWord;
begin
  Result := WasmDefaultValue(FieldValueType(Field));
  Slots[0] := 0;
  Slots[1] := 0;
  case FieldAccess(Field, False) of
    AccessI8: Slots[0] := At^;
    AccessI16: Slots[0] := PWord(At)^;
    Access32: Slots[0] := PDWord(At)^;
    Access64: Slots[0] := PQWord(At)^;
  else
    begin
      Slots[0] := PQWord(At)^;
      Slots[1] := PQWord(At + 8)^;
    end;
  end;
  Result.V128.QWords[0] := Slots[0];
  Result.V128.QWords[1] := Slots[1];
  if Result.ValueType.Kind = vkReference then
    Store.Heap.Expose(Result.Reference);
end;

procedure StoreValue(const Field: TWasmFieldType; At: PByte; const Value: TWasmValue);
begin
  if not Field.Mutable then
    raise EWasmError.Create('immutable field');
  if Value.ValueType.Kind <> FieldValueType(Field).Kind then
    raise EWasmError.Create('value of the wrong type');
  case FieldAccess(Field, False) of
    AccessI8: At^ := Byte(Value.I32);
    AccessI16: PWord(At)^ := Word(Value.I32);
    Access32: PDWord(At)^ := Value.F32Bits;
    Access64: PQWord(At)^ := Value.F64Bits;
  else
    begin
      PQWord(At)^ := Value.V128.QWords[0];
      PQWord(At + 8)^ := Value.V128.QWords[1];
    end;
  end;
end;

function WasmStructFieldCount(Reference: Pointer): Integer;
begin
  Result := Length(TWasmRuntimeType(StructOf(Reference)^.Descriptor).Definition.Fields);
end;

function WasmStructGetField(Store: TWasmStore; Reference: Pointer; Field: Integer): TWasmValue;
var
  Item: PWasmGcObject;
  Fields: TWasmFieldTypeArray;
begin
  Item := StructOf(Reference);
  Fields := TWasmRuntimeType(Item^.Descriptor).Definition.Fields;
  if (Field < 0) or (Field > High(Fields)) then
    raise EWasmError.Create('no such field');
  Result := StoredValue(Store, Fields[Field], ObjectPayload(Item) + StructFieldOffset(Fields, Field));
end;

procedure WasmStructSetField(Store: TWasmStore; Reference: Pointer; Field: Integer; const Value: TWasmValue);
var
  Item: PWasmGcObject;
  Fields: TWasmFieldTypeArray;
begin
  Item := StructOf(Reference);
  Fields := TWasmRuntimeType(Item^.Descriptor).Definition.Fields;
  if (Field < 0) or (Field > High(Fields)) then
    raise EWasmError.Create('no such field');
  if not WasmValueMatchesType(Store, Value, FieldValueType(Fields[Field])) then
    raise EWasmError.Create('value of the wrong type');
  StoreValue(Fields[Field], ObjectPayload(Item) + StructFieldOffset(Fields, Field), Value);
end;

function WasmArrayLength(Reference: Pointer): Cardinal;
begin
  Result := ArrayOf(Reference)^.Length;
end;

function WasmArrayGetElement(Store: TWasmStore; Reference: Pointer; Index: Cardinal): TWasmValue;
var
  Item: PWasmGcObject;
  RuntimeType: TWasmRuntimeType;
begin
  Item := ArrayOf(Reference);
  if Index >= Item^.Length then
    raise EWasmTrap.CreateTrap(tkArrayOutOfBounds);
  RuntimeType := TWasmRuntimeType(Item^.Descriptor);
  Result := StoredValue(Store, RuntimeType.Definition.Fields[0],
    ObjectPayload(Item) + QWord(Index) * QWord(RuntimeType.ElementSize));
end;

procedure WasmArraySetElement(Store: TWasmStore; Reference: Pointer; Index: Cardinal; const Value: TWasmValue);
var
  Item: PWasmGcObject;
  RuntimeType: TWasmRuntimeType;
begin
  Item := ArrayOf(Reference);
  if Index >= Item^.Length then
    raise EWasmTrap.CreateTrap(tkArrayOutOfBounds);
  RuntimeType := TWasmRuntimeType(Item^.Descriptor);
  if not WasmValueMatchesType(Store, Value, FieldValueType(RuntimeType.Definition.Fields[0])) then
    raise EWasmError.Create('value of the wrong type');
  StoreValue(RuntimeType.Definition.Fields[0], ObjectPayload(Item) + QWord(Index) * QWord(RuntimeType.ElementSize),
    Value);
end;

procedure WasmCollectGarbage(Store: TWasmStore);
begin
  Store.CollectGarbage;
end;

procedure WasmPin(Store: TWasmStore; Reference: Pointer);
begin
  Store.Heap.Pin(Reference);
end;

procedure WasmUnpin(Store: TWasmStore; Reference: Pointer);
begin
  Store.Heap.Unpin(Reference);
end;

procedure WasmForgetExposed(Store: TWasmStore);
begin
  Store.Heap.ForgetExposed;
end;
