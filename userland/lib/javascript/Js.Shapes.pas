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
  Shapes (hidden classes): which named properties an object has, in
  which slots, with which attributes.

  Objects built the same way share a shape. A shape is its parent plus
  one property (key, attributes, slot); adding a property follows the
  transition from the object's shape to the child with that key and
  attributes, making the child the first time. Transitions are weak:
  a child shape no object uses any more is collected and leaves its
  parent's list (Dying).

  Small shapes are searched by walking up to the root; a shape with
  more properties gets a hash table of all of them the first time it
  is searched.

  An object that has many properties, or has one deleted or
  reconfigured, gets a dictionary shape of its own: a table it changes
  in place. Every such change bumps the shape's Generation, which the
  inline caches compare along with the shape, so a cache never trusts a
  dictionary that changed under it. Tree shapes keep Generation 0.

  Keys are values: an atom (string), a symbol, or an integer for an
  index property kept by name (one with non-default attributes, or far
  past the dense elements).
}
unit Js.Shapes;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings;

const
  PropertyWritable = 1;
  PropertyEnumerable = 2;
  PropertyConfigurable = 4;
  PropertyAccessor = 8;
  PropertyDefault = PropertyWritable or PropertyEnumerable or PropertyConfigurable;
  { Writable and configurable, not enumerable: methods of built-ins. }
  PropertyHidden = PropertyWritable or PropertyConfigurable;

  { Shapes with more properties are searched through a table. }
  ShapeLinearSearchLimit = 8;
  { An object with more properties goes to a dictionary. }
  ShapeTreeLimit = 128;

type
  TJsShapeEntry = record
    Key: TJsValue;
    Flags: Byte;
    Slot: Integer;
  end;
  TJsShapeEntryList = array of TJsShapeEntry;

  { A hash table of keys to entries in insertion order. A removed
    entry keeps its place with the key JsHole. }
  TJsShapeTable = class
  public
    Entries: array of TJsShapeEntry;
    EntryCount: Integer;
    Index: array of Integer;
    IndexMask: Integer;
    LiveCount: Integer;
    procedure Rehash;
    function Find(Key: TJsValue): Integer;
    procedure Add(Key: TJsValue; Flags: Byte; Slot: Integer);
    procedure Remove(EntryIndex: Integer);
    function Clone: TJsShapeTable;
    function MemorySize: SizeInt;
  end;

  TJsShape = class(TJsCell)
  private
    FTransitions: array of TJsShape;
    FTransitionCount: Integer;
    procedure AddTransition(Child: TJsShape);
    procedure RemoveTransition(Child: TJsShape);
    procedure BuildTable;
  public
    Parent: TJsShape;
    Key: TJsValue;
    Flags: Byte;
    Slot: Integer;
    { Properties (live entries for a dictionary). }
    PropertyCount: Integer;
    { Slots used: the next property's slot. }
    SlotCount: Integer;
    IsDictionary: Boolean;
    Generation: LongWord;
    Table: TJsShapeTable;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    procedure Dying; override;
    function MemorySize: SizeInt; override;
    { The slot of Key, or -1; Flags gets its attributes. }
    function Find(SearchKey: TJsValue; out PropertyFlags: Byte): Integer;
    { The entries in the order the properties were added. }
    function Entries: TJsShapeEntryList;
  end;

function KeyHash(Key: TJsValue): LongWord; inline;
function NewRootShape(Heap: TJsHeap): TJsShape;
{ The shape with Key added (a transition for a tree shape; the same
  dictionary, changed, for a dictionary). }
function ShapeWithProperty(Heap: TJsHeap; Shape: TJsShape; Key: TJsValue; PropertyFlags: Byte): TJsShape;
{ A dictionary shape with the properties of Shape. }
function ShapeToDictionary(Heap: TJsHeap; Shape: TJsShape): TJsShape;
{ Dictionary shapes only. }
procedure DictionaryRemove(Heap: TJsHeap; Shape: TJsShape; Key: TJsValue);
procedure DictionarySetFlags(Shape: TJsShape; Key: TJsValue; PropertyFlags: Byte);

implementation

function KeyHash(Key: TJsValue): LongWord;
var
  Bits: QWord;
begin
  if (Key shr JsTagShift) = JsTagString then
    Result := TJsString(JsAsCell(Key)).Hash
  else
  begin
    Bits := Key * QWord($9E3779B97F4A7C15);
    Result := LongWord(Bits shr 32);
  end;
end;

{ TJsShapeTable }

procedure TJsShapeTable.Rehash;
var
  Size, EntryIndex, Slot: Integer;
begin
  Size := 8;
  while Size < LiveCount * 2 + 2 do
    Size := Size * 2;
  Index := nil;
  SetLength(Index, Size);
  IndexMask := Size - 1;
  for EntryIndex := 0 to EntryCount - 1 do
    if Entries[EntryIndex].Key <> JsHole then
    begin
      Slot := Integer(KeyHash(Entries[EntryIndex].Key) and LongWord(IndexMask));
      while Index[Slot] <> 0 do
        Slot := (Slot + 1) and IndexMask;
      Index[Slot] := EntryIndex + 1;
    end;
end;

function TJsShapeTable.Find(Key: TJsValue): Integer;
var
  Slot, Entry: Integer;
begin
  Slot := Integer(KeyHash(Key) and LongWord(IndexMask));
  while True do
  begin
    Entry := Index[Slot];
    if Entry = 0 then
      Exit(-1);
    if (Entry > 0) and (Entries[Entry - 1].Key = Key) then
      Exit(Entry - 1);
    Slot := (Slot + 1) and IndexMask;
  end;
end;

procedure TJsShapeTable.Add(Key: TJsValue; Flags: Byte; Slot: Integer);
var
  Position, Old: Integer;
begin
  if EntryCount >= Length(Entries) then
    SetLength(Entries, Length(Entries) * 2 + 4);
  Entries[EntryCount].Key := Key;
  Entries[EntryCount].Flags := Flags;
  Entries[EntryCount].Slot := Slot;
  Inc(EntryCount);
  Inc(LiveCount);
  if (Length(Index) = 0) or (EntryCount * 2 > Length(Index)) then
  begin
    if (LiveCount * 2 < EntryCount) then
    begin
      { Many removed entries: drop them. }
      Position := 0;
      for Old := 0 to EntryCount - 1 do
        if Entries[Old].Key <> JsHole then
        begin
          Entries[Position] := Entries[Old];
          Inc(Position);
        end;
      EntryCount := Position;
    end;
    Rehash;
    Exit;
  end;
  Position := Integer(KeyHash(Key) and LongWord(IndexMask));
  while Index[Position] > 0 do
    Position := (Position + 1) and IndexMask;
  Index[Position] := EntryCount;
end;

procedure TJsShapeTable.Remove(EntryIndex: Integer);
var
  Slot: Integer;
begin
  Slot := Integer(KeyHash(Entries[EntryIndex].Key) and LongWord(IndexMask));
  while Index[Slot] <> EntryIndex + 1 do
    Slot := (Slot + 1) and IndexMask;
  Index[Slot] := -1;
  Entries[EntryIndex].Key := JsHole;
  Dec(LiveCount);
end;

function TJsShapeTable.Clone: TJsShapeTable;
begin
  Result := TJsShapeTable.Create;
  Result.Entries := Copy(Entries, 0, EntryCount);
  Result.EntryCount := EntryCount;
  Result.LiveCount := LiveCount;
  Result.Rehash;
end;

function TJsShapeTable.MemorySize: SizeInt;
begin
  Result := InstanceSize + Length(Entries) * SizeOf(TJsShapeEntry) + Length(Index) * SizeOf(Integer);
end;

{ TJsShape }

destructor TJsShape.Destroy;
begin
  Table.Free;
  inherited Destroy;
end;

procedure TJsShape.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  if Parent <> nil then
    Tracer.MarkCell(Parent);
  Tracer.MarkValue(Key);
  if IsDictionary then
    for Index := 0 to Table.EntryCount - 1 do
      Tracer.MarkValue(Table.Entries[Index].Key);
end;

procedure TJsShape.Dying;
begin
  if (Parent <> nil) and Parent.Marked then
    Parent.RemoveTransition(Self);
end;

function TJsShape.MemorySize: SizeInt;
begin
  Result := InstanceSize + Length(FTransitions) * SizeOf(Pointer);
  if Table <> nil then
    Inc(Result, Table.MemorySize);
end;

procedure TJsShape.AddTransition(Child: TJsShape);
begin
  if FTransitionCount >= Length(FTransitions) then
    SetLength(FTransitions, Length(FTransitions) * 2 + 2);
  FTransitions[FTransitionCount] := Child;
  Inc(FTransitionCount);
end;

procedure TJsShape.RemoveTransition(Child: TJsShape);
var
  Index: Integer;
begin
  for Index := 0 to FTransitionCount - 1 do
    if FTransitions[Index] = Child then
    begin
      FTransitions[Index] := FTransitions[FTransitionCount - 1];
      Dec(FTransitionCount);
      Exit;
    end;
end;

procedure TJsShape.BuildTable;
var
  Chain: array of TJsShape;
  Count, Index: Integer;
  Shape: TJsShape;
begin
  Chain := nil;
  SetLength(Chain, PropertyCount);
  Count := 0;
  Shape := Self;
  while Shape.Parent <> nil do
  begin
    Chain[Count] := Shape;
    Inc(Count);
    Shape := Shape.Parent;
  end;
  Table := TJsShapeTable.Create;
  SetLength(Table.Entries, Count);
  for Index := Count - 1 downto 0 do
    Table.Add(Chain[Index].Key, Chain[Index].Flags, Chain[Index].Slot);
end;

function TJsShape.Find(SearchKey: TJsValue; out PropertyFlags: Byte): Integer;
var
  Shape: TJsShape;
  Entry: Integer;
begin
  if Table <> nil then
  begin
    Entry := Table.Find(SearchKey);
    if Entry < 0 then
    begin
      PropertyFlags := 0;
      Exit(-1);
    end;
    PropertyFlags := Table.Entries[Entry].Flags;
    Exit(Table.Entries[Entry].Slot);
  end;
  if PropertyCount > ShapeLinearSearchLimit then
  begin
    BuildTable;
    Exit(Find(SearchKey, PropertyFlags));
  end;
  Shape := Self;
  while Shape.Parent <> nil do
  begin
    if Shape.Key = SearchKey then
    begin
      PropertyFlags := Shape.Flags;
      Exit(Shape.Slot);
    end;
    Shape := Shape.Parent;
  end;
  PropertyFlags := 0;
  Result := -1;
end;

function TJsShape.Entries: TJsShapeEntryList;
var
  Count, Index: Integer;
  Shape: TJsShape;
begin
  Result := nil;
  if IsDictionary then
  begin
    SetLength(Result, Table.LiveCount);
    Count := 0;
    for Index := 0 to Table.EntryCount - 1 do
      if Table.Entries[Index].Key <> JsHole then
      begin
        Result[Count] := Table.Entries[Index];
        Inc(Count);
      end;
    Exit;
  end;
  SetLength(Result, PropertyCount);
  Index := PropertyCount - 1;
  Shape := Self;
  while Shape.Parent <> nil do
  begin
    Result[Index].Key := Shape.Key;
    Result[Index].Flags := Shape.Flags;
    Result[Index].Slot := Shape.Slot;
    Dec(Index);
    Shape := Shape.Parent;
  end;
end;

function NewRootShape(Heap: TJsHeap): TJsShape;
begin
  Result := TJsShape.Create;
  Heap.Register(Result, ckShape);
  Result.Key := JsUndefined;
end;

function ShapeWithProperty(Heap: TJsHeap; Shape: TJsShape; Key: TJsValue; PropertyFlags: Byte): TJsShape;
var
  Index: Integer;
  Child: TJsShape;
begin
  if Shape.IsDictionary then
  begin
    Shape.Table.Add(Key, PropertyFlags, Shape.SlotCount);
    Inc(Shape.SlotCount);
    Inc(Shape.PropertyCount);
    Inc(Shape.Generation);
    Exit(Shape);
  end;
  for Index := 0 to Shape.FTransitionCount - 1 do
  begin
    Child := Shape.FTransitions[Index];
    if (Child.Key = Key) and (Child.Flags = PropertyFlags) then
      Exit(Child);
  end;
  Child := TJsShape.Create;
  Heap.Register(Child, ckShape);
  Child.Parent := Shape;
  Child.Key := Key;
  Child.Flags := PropertyFlags;
  Child.Slot := Shape.SlotCount;
  Child.SlotCount := Shape.SlotCount + 1;
  Child.PropertyCount := Shape.PropertyCount + 1;
  Shape.AddTransition(Child);
  Heap.Account(SizeOf(Pointer));
  Result := Child;
end;

function ShapeToDictionary(Heap: TJsHeap; Shape: TJsShape): TJsShape;
var
  List: TJsShapeEntryList;
  Index: Integer;
begin
  Result := TJsShape.Create;
  Heap.Register(Result, ckShape);
  Result.Key := JsUndefined;
  Result.IsDictionary := True;
  Result.Table := TJsShapeTable.Create;
  List := Shape.Entries;
  SetLength(Result.Table.Entries, Length(List) + 4);
  for Index := 0 to High(List) do
    Result.Table.Add(List[Index].Key, List[Index].Flags, List[Index].Slot);
  if Result.Table.Index = nil then
    Result.Table.Rehash;
  Result.PropertyCount := Length(List);
  Result.SlotCount := Shape.SlotCount;
  Heap.Account(Result.Table.MemorySize);
end;

procedure DictionaryRemove(Heap: TJsHeap; Shape: TJsShape; Key: TJsValue);
var
  Entry: Integer;
begin
  Entry := Shape.Table.Find(Key);
  if Entry < 0 then
    Exit;
  Shape.Table.Remove(Entry);
  Dec(Shape.PropertyCount);
  Inc(Shape.Generation);
end;

procedure DictionarySetFlags(Shape: TJsShape; Key: TJsValue; PropertyFlags: Byte);
var
  Entry: Integer;
begin
  Entry := Shape.Table.Find(Key);
  if Entry < 0 then
    Exit;
  Shape.Table.Entries[Entry].Flags := PropertyFlags;
  Inc(Shape.Generation);
end;

end.
