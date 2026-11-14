{
  Intrusive circular doubly linked lists.

  A TListEntry is embedded in the record that should be linked, and a list
  head is just a TListEntry whose Next and Previous point back at itself
  when the list is empty. Inserting and removing never allocates memory,
  which makes these lists usable anywhere in the kernel.

  To get from a list entry back to the record containing it, use
  ContainingRecord with the offset of the entry field, for example:

    Thread := PThread(ContainingRecord(Entry, FieldOffset(PThread(nil)^.Link)));

  Read-only list heads are passed as "constref", never "const": the
  emptiness test compares against the head's own address, and a "const"
  record of this size may be passed as a copy.
}
unit Runtime.LinkedList;

{$mode objfpc}

interface

type
  PListEntry = ^TListEntry;
  TListEntry = record
    Next: PListEntry;
    Previous: PListEntry;
  end;

procedure InitializeListHead(var Head: TListEntry);
function ListIsEmpty(constref Head: TListEntry): Boolean;

procedure InsertAtHead(var Head: TListEntry; Entry: PListEntry);
procedure InsertAtTail(var Head: TListEntry; Entry: PListEntry);

{ Inserts Entry immediately before Successor. }
procedure InsertBefore(Successor: PListEntry; Entry: PListEntry);

procedure RemoveListEntry(Entry: PListEntry);

{ Removes and returns the first entry, or nil when the list is empty. }
function RemoveHeadEntry(var Head: TListEntry): PListEntry;

function FirstListEntry(constref Head: TListEntry): PListEntry;

{ Returns the address of the record that contains a list entry located
  OffsetOfEntry bytes from the start of that record. }
function ContainingRecord(Entry: PListEntry; OffsetOfEntry: PtrUInt): Pointer;

{ Returns the byte offset of a field, given its address within a record
  placed at address zero. }
function FieldOffset(const Field): PtrUInt;

implementation

procedure InitializeListHead(var Head: TListEntry);
begin
  Head.Next := @Head;
  Head.Previous := @Head;
end;

function ListIsEmpty(constref Head: TListEntry): Boolean;
begin
  Result := Head.Next = @Head;
end;

procedure InsertBefore(Successor: PListEntry; Entry: PListEntry);
var
  Predecessor: PListEntry;
begin
  Predecessor := Successor^.Previous;
  Entry^.Next := Successor;
  Entry^.Previous := Predecessor;
  Predecessor^.Next := Entry;
  Successor^.Previous := Entry;
end;

procedure InsertAtHead(var Head: TListEntry; Entry: PListEntry);
begin
  InsertBefore(Head.Next, Entry);
end;

procedure InsertAtTail(var Head: TListEntry; Entry: PListEntry);
begin
  InsertBefore(@Head, Entry);
end;

procedure RemoveListEntry(Entry: PListEntry);
begin
  Entry^.Previous^.Next := Entry^.Next;
  Entry^.Next^.Previous := Entry^.Previous;
  Entry^.Next := Entry;
  Entry^.Previous := Entry;
end;

function RemoveHeadEntry(var Head: TListEntry): PListEntry;
begin
  if ListIsEmpty(Head) then
    Exit(nil);
  Result := Head.Next;
  RemoveListEntry(Result);
end;

function FirstListEntry(constref Head: TListEntry): PListEntry;
begin
  if ListIsEmpty(Head) then
    Result := nil
  else
    Result := Head.Next;
end;

function ContainingRecord(Entry: PListEntry; OffsetOfEntry: PtrUInt): Pointer;
begin
  Result := Pointer(PtrUInt(Entry) - OffsetOfEntry);
end;

function FieldOffset(const Field): PtrUInt;
begin
  Result := PtrUInt(@Field);
end;

end.
