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
  The garbage collected heap of a store: structs, arrays, exception
  objects and the boxes that carry an embedder's reference in the any
  hierarchy (any.convert_extern of a host value).

  Objects never move (embedders hold pointers to them). Each has a 24
  byte header (its descriptor, a length, the mark epoch, its kind) and
  its payload after it. A reference value is a 64-bit word: 0 is null,
  an odd word is an i31 (the value shifted left by one, plus one), and
  an even one is an object of this heap, a function (func hierarchy) or,
  in the extern hierarchy, a pointer the embedder owns. Which even words
  are objects the heap knows from its table of live objects, so an
  extern reference can be told apart without trusting its bits; embedder
  pointers must be even (any aligned pointer is).

  Collection is mark and sweep. Marking starts from roots the store
  enumerates (Wasm.Runtime: globals, tables, element segments, the
  slots of suspended frames by the compiler's safepoint maps, pinned
  objects, objects handed to the embedder, exceptions in flight) and
  follows each object's references by its descriptor: the offsets of
  traced fields, whether array elements are traced. A traced slot is
  internal (objects or i31s only) or external (an extern reference, which
  may also be an embedder pointer: those are given to the host visitor,
  for an embedder's own collector to keep). Marks are an epoch number,
  so nothing has to be cleared between collections; the sweep frees
  every object not marked in the current epoch.
}
unit Wasm.GcHeap;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

uses
  Wasm.PointerTable;

type
  TWasmGcObjectKind = (okStruct, okArray, okHostBox, okException);

  { What the collector needs of an object's type: where its references
    are. TracedOffsets holds payload byte offsets times two, plus one
    for an external (extern hierarchy) slot. }
  TWasmGcDescriptor = class
  public
    TracedOffsets: array of Int32;
    ElementSize: Integer;
    ElementsTraced: Boolean;
    ElementsExternal: Boolean;
  end;

  PWasmGcObject = ^TWasmGcObject;
  TWasmGcObject = packed record
    Descriptor: TWasmGcDescriptor;
    { Array elements, exception payload slots or struct payload bytes. }
    Length: Cardinal;
    Epoch: Cardinal;
    Kind: TWasmGcObjectKind;
    Flags: Byte;
    Reserved: array[0..5] of Byte;
  end;

  { Visits a pointer the embedder owns, found where the store keeps it. }
  TWasmHostReferenceVisitor = procedure(Reference: Pointer) of object;

  TWasmGcHeap = class
  private
    FObjects: TWasmPointerTable;
    FPins: TWasmPointerTable;
    FExposed: TWasmPointerTable;
    FEpoch: Cardinal;
    FWorklist: array of PWasmGcObject;
    FWorkCount: Integer;
    FBytesInUse: QWord;
    FBytesSinceCollection: QWord;
    FThreshold: QWord;
    FMinimumThreshold: QWord;
    FMaximumBytes: QWord;
    FInhibit: Integer;
    FHostVisitor: TWasmHostReferenceVisitor;
    FCollections: Integer;
    function Allocate(Kind: TWasmGcObjectKind; Descriptor: TWasmGcDescriptor; PayloadBytes: QWord): PWasmGcObject;
    procedure Push(Item: PWasmGcObject);
    procedure TraceObject(Item: PWasmGcObject);
    procedure MarkSlot(Slot: PQWord; External: Boolean); inline;
  public
    constructor Create(MaximumBytes, Threshold: QWord);
    destructor Destroy; override;
    { Allocation; nil when the heap's limit would be passed. Payloads
      are zeroed. }
    function AllocateStruct(Descriptor: TWasmGcDescriptor; PayloadBytes: Integer): PWasmGcObject;
    function AllocateArray(Descriptor: TWasmGcDescriptor; Length: QWord): PWasmGcObject;
    function AllocateHostBox(HostReference: Pointer): PWasmGcObject;
    function AllocateException(Descriptor: TWasmGcDescriptor; PayloadSlots: Integer): PWasmGcObject;
    { Whether an even, non-null word is an object of this heap. }
    function IsObject(Reference: Pointer): Boolean; inline;
    { Whether enough was allocated since the last collection to collect
      (and collection is not inhibited). }
    function WantsCollection: Boolean; inline;
    { While inhibited (nested), no collection runs: for code that holds
      new objects where no root shows them (constant expressions). }
    procedure Inhibit;
    procedure Allow;
    { Marking: BeginMark starts an epoch; MarkReference marks a
      reference word (and later, in DrainMarks, what it reaches);
      external words that are no object go to the host visitor. }
    procedure BeginMark(HostVisitor: TWasmHostReferenceVisitor);
    { Goes on marking in the current epoch with another visitor. }
    procedure ContinueMark(HostVisitor: TWasmHostReferenceVisitor);
    procedure MarkReference(Reference: QWord; External: Boolean);
    procedure MarkPinned;
    procedure MarkExposed;
    procedure DrainMarks;
    function IsMarked(Item: PWasmGcObject): Boolean; inline;
    { Frees every object not marked in the current epoch. }
    procedure Sweep;
    { Forgets the exposed objects not marked in the current epoch. }
    procedure PruneExposed;
    procedure Pin(Reference: Pointer);
    procedure Unpin(Reference: Pointer);
    { An object the embedder now holds (no-op for anything else). }
    procedure Expose(Reference: Pointer); inline;
    procedure ForgetExposed;
    function ObjectCount: Integer;
    function PinnedCount: Integer;
    function ExposedCount: Integer;
    property BytesInUse: QWord read FBytesInUse;
    property Collections: Integer read FCollections;
  end;

const
  GcHeaderSize = SizeOf(TWasmGcObject);

{ The payload of an object. }
function ObjectPayload(Item: PWasmGcObject): PByte; inline;

implementation

uses
  SysUtils;

function ObjectPayload(Item: PWasmGcObject): PByte;
begin
  Result := PByte(Item) + GcHeaderSize;
end;

constructor TWasmGcHeap.Create(MaximumBytes, Threshold: QWord);
begin
  inherited Create;
  FObjects := TWasmPointerTable.Create;
  FPins := TWasmPointerTable.Create;
  FExposed := TWasmPointerTable.Create;
  FMaximumBytes := MaximumBytes;
  FMinimumThreshold := Threshold;
  FThreshold := Threshold;
  FEpoch := 1;
end;

destructor TWasmGcHeap.Destroy;
var
  Slot: Integer;
begin
  for Slot := 0 to FObjects.Capacity - 1 do
    if FObjects.KeyAt(Slot) <> nil then
      FreeMem(FObjects.KeyAt(Slot));
  FObjects.Free;
  FPins.Free;
  FExposed.Free;
  inherited Destroy;
end;

function TWasmGcHeap.Allocate(Kind: TWasmGcObjectKind; Descriptor: TWasmGcDescriptor;
  PayloadBytes: QWord): PWasmGcObject;
var
  Size: QWord;
begin
  Result := nil;
  if PayloadBytes > FMaximumBytes then
    Exit;
  Size := (GcHeaderSize + PayloadBytes + 7) and not QWord(7);
  if FBytesInUse + Size > FMaximumBytes then
    Exit;
  try
    Result := AllocMem(Size);
  except
    on EOutOfMemory do
      Exit(nil);
  end;
  if Result = nil then
    Exit;
  Result^.Descriptor := Descriptor;
  Result^.Kind := Kind;
  Result^.Epoch := 0;
  FObjects.Add(Result);
  Inc(FBytesInUse, Size);
  Inc(FBytesSinceCollection, Size);
end;

function TWasmGcHeap.AllocateStruct(Descriptor: TWasmGcDescriptor; PayloadBytes: Integer): PWasmGcObject;
begin
  Result := Allocate(okStruct, Descriptor, PayloadBytes);
  if Result <> nil then
    Result^.Length := PayloadBytes;
end;

function TWasmGcHeap.AllocateArray(Descriptor: TWasmGcDescriptor; Length: QWord): PWasmGcObject;
begin
  Result := nil;
  if Length > High(Cardinal) then
    Exit;
  Result := Allocate(okArray, Descriptor, Length * QWord(Descriptor.ElementSize));
  if Result <> nil then
    Result^.Length := Length;
end;

function TWasmGcHeap.AllocateHostBox(HostReference: Pointer): PWasmGcObject;
begin
  Result := Allocate(okHostBox, nil, SizeOf(Pointer));
  if Result <> nil then
    PPointer(ObjectPayload(Result))^ := HostReference;
end;

function TWasmGcHeap.AllocateException(Descriptor: TWasmGcDescriptor; PayloadSlots: Integer): PWasmGcObject;
begin
  Result := Allocate(okException, Descriptor, QWord(PayloadSlots) * 8);
  if Result <> nil then
    Result^.Length := PayloadSlots;
end;

function TWasmGcHeap.IsObject(Reference: Pointer): Boolean;
begin
  Result := (PtrUInt(Reference) and 1 = 0) and (Reference <> nil) and FObjects.Contains(Reference);
end;

function TWasmGcHeap.WantsCollection: Boolean;
begin
  Result := (FBytesSinceCollection >= FThreshold) and (FInhibit = 0);
end;

procedure TWasmGcHeap.Inhibit;
begin
  Inc(FInhibit);
end;

procedure TWasmGcHeap.Allow;
begin
  Dec(FInhibit);
end;

procedure TWasmGcHeap.Push(Item: PWasmGcObject);
begin
  if FWorkCount >= Length(FWorklist) then
    SetLength(FWorklist, FWorkCount * 2 + 64);
  FWorklist[FWorkCount] := Item;
  Inc(FWorkCount);
end;

procedure TWasmGcHeap.BeginMark(HostVisitor: TWasmHostReferenceVisitor);
begin
  Inc(FEpoch);
  if FEpoch = 0 then
    FEpoch := 1;
  FHostVisitor := HostVisitor;
  FWorkCount := 0;
end;

procedure TWasmGcHeap.ContinueMark(HostVisitor: TWasmHostReferenceVisitor);
begin
  FHostVisitor := HostVisitor;
end;

procedure TWasmGcHeap.MarkReference(Reference: QWord; External: Boolean);
var
  Item: PWasmGcObject;
begin
  if (Reference = 0) or (Reference and 1 <> 0) then
    Exit;
  Item := PWasmGcObject(PtrUInt(Reference));
  if not FObjects.Contains(Item) then
  begin
    if External and Assigned(FHostVisitor) then
      FHostVisitor(Item);
    Exit;
  end;
  if Item^.Epoch = FEpoch then
    Exit;
  Item^.Epoch := FEpoch;
  Push(Item);
end;

procedure TWasmGcHeap.MarkSlot(Slot: PQWord; External: Boolean);
begin
  if Slot^ <> 0 then
    MarkReference(Slot^, External);
end;

procedure TWasmGcHeap.TraceObject(Item: PWasmGcObject);
var
  Payload: PByte;
  Index: Integer;
  Element: QWord;
  Offset: Int32;
begin
  Payload := ObjectPayload(Item);
  case Item^.Kind of
    okHostBox:
      if Assigned(FHostVisitor) and (PPointer(Payload)^ <> nil) then
        FHostVisitor(PPointer(Payload)^);
    okArray:
      if Item^.Descriptor.ElementsTraced and (Item^.Length > 0) then
        for Element := 0 to Item^.Length - 1 do
          MarkSlot(PQWord(Payload + Element * 8), Item^.Descriptor.ElementsExternal);
  else
    if Item^.Descriptor <> nil then
      for Index := 0 to High(Item^.Descriptor.TracedOffsets) do
      begin
        Offset := Item^.Descriptor.TracedOffsets[Index];
        MarkSlot(PQWord(Payload + (Offset shr 1)), Offset and 1 <> 0);
      end;
  end;
end;

procedure TWasmGcHeap.DrainMarks;
var
  Item: PWasmGcObject;
begin
  while FWorkCount > 0 do
  begin
    Dec(FWorkCount);
    Item := FWorklist[FWorkCount];
    TraceObject(Item);
  end;
end;

function TWasmGcHeap.IsMarked(Item: PWasmGcObject): Boolean;
begin
  Result := Item^.Epoch = FEpoch;
end;

procedure TWasmGcHeap.MarkPinned;
var
  Slot: Integer;
begin
  for Slot := 0 to FPins.Capacity - 1 do
    if FPins.KeyAt(Slot) <> nil then
      MarkReference(QWord(PtrUInt(FPins.KeyAt(Slot))), False);
end;

procedure TWasmGcHeap.MarkExposed;
var
  Slot: Integer;
begin
  for Slot := 0 to FExposed.Capacity - 1 do
    if FExposed.KeyAt(Slot) <> nil then
      MarkReference(QWord(PtrUInt(FExposed.KeyAt(Slot))), False);
end;

procedure TWasmGcHeap.Sweep;
var
  Dead: array of Pointer;
  Count, Slot, Index: Integer;
  Item: PWasmGcObject;
  Size: QWord;
begin
  Dead := nil;
  Count := 0;
  for Slot := 0 to FObjects.Capacity - 1 do
  begin
    Item := FObjects.KeyAt(Slot);
    if (Item <> nil) and (Item^.Epoch <> FEpoch) then
    begin
      if Count >= Length(Dead) then
        SetLength(Dead, Count * 2 + 64);
      Dead[Count] := Item;
      Inc(Count);
    end;
  end;
  for Index := 0 to Count - 1 do
  begin
    Item := Dead[Index];
    case Item^.Kind of
      okArray: Size := QWord(Item^.Length) * QWord(Item^.Descriptor.ElementSize);
      okHostBox: Size := SizeOf(Pointer);
      okException: Size := QWord(Item^.Length) * 8;
    else
      Size := Item^.Length;
    end;
    FObjects.Remove(Item);
    FExposed.Remove(Item);
    Size := (GcHeaderSize + Size + 7) and not QWord(7);
    if Size <= FBytesInUse then
      Dec(FBytesInUse, Size)
    else
      FBytesInUse := 0;
    FreeMem(Item);
  end;
  FBytesSinceCollection := 0;
  FThreshold := FBytesInUse;
  if FThreshold < FMinimumThreshold then
    FThreshold := FMinimumThreshold;
  Inc(FCollections);
  FHostVisitor := nil;
end;

procedure TWasmGcHeap.PruneExposed;
var
  Slot: Integer;
  Item: PWasmGcObject;
  Dropped: array of Pointer;
  Count, Index: Integer;
begin
  Dropped := nil;
  Count := 0;
  for Slot := 0 to FExposed.Capacity - 1 do
  begin
    Item := FExposed.KeyAt(Slot);
    if (Item <> nil) and (Item^.Epoch <> FEpoch) then
    begin
      if Count >= Length(Dropped) then
        SetLength(Dropped, Count * 2 + 16);
      Dropped[Count] := Item;
      Inc(Count);
    end;
  end;
  for Index := 0 to Count - 1 do
    FExposed.Remove(Dropped[Index]);
end;

procedure TWasmGcHeap.Pin(Reference: Pointer);
begin
  if IsObject(Reference) then
    FPins.Add(Reference);
end;

procedure TWasmGcHeap.Unpin(Reference: Pointer);
begin
  FPins.Release(Reference);
end;

procedure TWasmGcHeap.Expose(Reference: Pointer);
begin
  if (Reference <> nil) and (PtrUInt(Reference) and 1 = 0) and FObjects.Contains(Reference) and
    not FExposed.Contains(Reference) then
    FExposed.Add(Reference);
end;

procedure TWasmGcHeap.ForgetExposed;
begin
  FExposed.Clear;
end;

function TWasmGcHeap.ObjectCount: Integer;
begin
  Result := FObjects.Count;
end;

function TWasmGcHeap.PinnedCount: Integer;
begin
  Result := FPins.Count;
end;

function TWasmGcHeap.ExposedCount: Integer;
begin
  Result := FExposed.Count;
end;

end.
