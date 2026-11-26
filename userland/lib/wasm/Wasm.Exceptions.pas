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
  WebAssembly exceptions outside WebAssembly code.

  An exception is a garbage collected object (Wasm.GcHeap, kind
  okException) whose descriptor is its tag and whose payload is a slot
  per tag parameter (two for a v128): what exnref values point to.

  When an exception leaves WebAssembly (no handler up to the first host
  frame) it becomes the Pascal exception EWasmException, which carries
  the object and pins it while it lives; it is how an exception crosses
  host functions too: a host callback that raises EWasmException (one it
  let through, or a new one made with RaiseWasmException) throws that
  exception into the calling WebAssembly code, where try_table, catch
  and catch_all see it like any other. The JavaScript layer maps it to
  WebAssembly.Exception (Tag and Payload) and back.

  An EWasmException must be freed before its store (the RTL frees it
  when its handler ends).
}
unit Wasm.Exceptions;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Types,
  Wasm.Errors,
  Wasm.GcHeap,
  Wasm.Runtime;

type
  EWasmException = class(EWasmError)
  private
    FStore: TWasmStore;
    FReference: Pointer;
  public
    { Takes an exception object (an exnref); pins it until destroyed. }
    constructor CreateFor(AStore: TWasmStore; AReference: Pointer);
    destructor Destroy; override;
    function Tag: TWasmTag;
    function Payload: TWasmValueArray;
    property Store: TWasmStore read FStore;
    { The exnref. }
    property Reference: Pointer read FReference;
  end;

{ A new exception object of Tag with Values (one per parameter); traps
  with tkOutOfMemory when the heap is full. }
function NewExceptionObject(Store: TWasmStore; Tag: TWasmTag; const Values: TWasmValueArray): Pointer;
function ExceptionTagOf(Reference: Pointer): TWasmTag;
function ExceptionPayloadOf(Reference: Pointer): TWasmValueArray;
{ Raises EWasmException with a new exception of Tag. }
procedure RaiseWasmException(Store: TWasmStore; Tag: TWasmTag; const Values: TWasmValueArray);

implementation

constructor EWasmException.CreateFor(AStore: TWasmStore; AReference: Pointer);
begin
  inherited Create('uncaught WebAssembly exception');
  FStore := AStore;
  FReference := AReference;
  FStore.Heap.Pin(FReference);
end;

destructor EWasmException.Destroy;
begin
  if FStore <> nil then
    FStore.Heap.Unpin(FReference);
  inherited Destroy;
end;

function EWasmException.Tag: TWasmTag;
begin
  Result := ExceptionTagOf(FReference);
end;

function EWasmException.Payload: TWasmValueArray;
begin
  Result := ExceptionPayloadOf(FReference);
  FStore.Heap.Expose(FReference);
end;

function NewExceptionObject(Store: TWasmStore; Tag: TWasmTag; const Values: TWasmValueArray): Pointer;
var
  Item: PWasmGcObject;
  Slots: PQWord;
  Index, Slot: Integer;
begin
  if Length(Values) <> Length(Tag.FunctionType.Params) then
    raise EWasmError.CreateFmt('expected %d exception values, got %d', [Length(Tag.FunctionType.Params), Length(Values)]);
  for Index := 0 to High(Values) do
    if Values[Index].ValueType.Kind <> Tag.FunctionType.Params[Index].Kind then
      raise EWasmError.CreateFmt('exception value %d of the wrong type', [Index]);
  Item := Store.Heap.AllocateException(Tag, Tag.PayloadSlots);
  if Item = nil then
  begin
    Store.CollectGarbage;
    Item := Store.Heap.AllocateException(Tag, Tag.PayloadSlots);
    if Item = nil then
      raise EWasmTrap.CreateTrap(tkOutOfMemory);
  end;
  Slots := PQWord(ObjectPayload(Item));
  Slot := 0;
  for Index := 0 to High(Values) do
  begin
    case Values[Index].ValueType.Kind of
      vkI32, vkF32: Slots[Slot] := Values[Index].F32Bits;
      vkV128:
        begin
          Slots[Slot] := Values[Index].V128.QWords[0];
          Slots[Slot + 1] := Values[Index].V128.QWords[1];
          Inc(Slot);
        end;
    else
      Slots[Slot] := Values[Index].F64Bits;
    end;
    Inc(Slot);
  end;
  Result := Item;
end;

function ExceptionTagOf(Reference: Pointer): TWasmTag;
begin
  Result := TWasmTag(PWasmGcObject(Reference)^.Descriptor);
end;

function ExceptionPayloadOf(Reference: Pointer): TWasmValueArray;
var
  Tag: TWasmTag;
  Slots: PQWord;
  Index, Slot: Integer;
begin
  Tag := ExceptionTagOf(Reference);
  Result := nil;
  SetLength(Result, Length(Tag.FunctionType.Params));
  Slots := PQWord(ObjectPayload(PWasmGcObject(Reference)));
  Slot := 0;
  for Index := 0 to High(Result) do
  begin
    Result[Index] := WasmDefaultValue(Tag.FunctionType.Params[Index]);
    case Tag.FunctionType.Params[Index].Kind of
      vkI32, vkF32: Result[Index].F32Bits := DWord(Slots[Slot]);
      vkV128:
        begin
          Result[Index].V128.QWords[0] := Slots[Slot];
          Result[Index].V128.QWords[1] := Slots[Slot + 1];
          Inc(Slot);
        end;
    else
      Result[Index].F64Bits := Slots[Slot];
    end;
    if Tag.FunctionType.Params[Index].Kind = vkReference then
      Tag.Store.Heap.Expose(Result[Index].Reference);
    Inc(Slot);
  end;
end;

procedure RaiseWasmException(Store: TWasmStore; Tag: TWasmTag; const Values: TWasmValueArray);
begin
  raise EWasmException.CreateFor(Store, NewExceptionObject(Store, Tag, Values));
end;

end.
