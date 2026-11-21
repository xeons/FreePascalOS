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
  Object manager.

  Kernel resources that outlive a single function call (processes,
  threads, and later files, devices and so on) are objects. Every object
  has a header that records its type, an optional name and a reference
  count. Whoever holds a pointer to an object holds a reference to it; the
  object is deleted (through its type's delete routine) when the last
  reference is dropped.

  Named objects are entered in a single, flat namespace and can be found
  by name. A hierarchical namespace can be layered on top later.

  A reference count never wraps: one that reaches ObjectReferenceCountLimit
  (only a reference leak gets there) stays there, with a warning in the
  log, and the object is never deleted - a leak instead of a use after
  free.

  Memory layout of an object:

    +----------------+  <- allocation
    | TObjectHeader  |
    +----------------+  <- "object body", the pointer callers work with
    | type specific  |
    | data           |
    +----------------+
}
unit Objects.Manager;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList;

const
  ObjectNameLength = 32;
  { Where a reference count saturates. }
  ObjectReferenceCountLimit = Int64(1) shl 40;

type
  TObjectDeleteRoutine = procedure(ObjectBody: Pointer);

  PObjectType = ^TObjectType;
  TObjectType = record
    Name: array[0..ObjectNameLength - 1] of Char;
    BodySize: QWord;
    DeleteRoutine: TObjectDeleteRoutine;
    LiveObjectCount: Int64;
    TypeLink: TListEntry;
  end;

procedure InitializeObjectManager;

{ Registers a new object type. BodySize is the size of the type specific
  data. DeleteRoutine (optional) runs just before an object's memory is
  released. }
procedure RegisterObjectType(var ObjectType: TObjectType; Name: PChar;
  BodySize: QWord; DeleteRoutine: TObjectDeleteRoutine);

{ Creates an object with a reference count of one, owned by the caller.
  The body is zero filled. Name may be nil for an unnamed object. Returns
  nil if memory ran out or the name is already taken. }
function CreateObject(var ObjectType: TObjectType; Name: PChar): Pointer;

procedure ReferenceObject(ObjectBody: Pointer);
procedure DereferenceObject(ObjectBody: Pointer);

{ Finds a named object and returns it with an extra reference, or nil.
  When ExpectedType is not nil the object must be of that type. }
function LookupObjectByName(Name: PChar; ExpectedType: PObjectType): Pointer;

function ObjectTypeOf(ObjectBody: Pointer): PObjectType;
function ObjectNameOf(ObjectBody: Pointer): PChar;
function ObjectReferenceCount(ObjectBody: Pointer): Int64;

{ For the self tests only: puts an object's count at Count, so the
  saturation can be reached without 2^40 references. }
procedure SetObjectReferenceCountForTest(ObjectBody: Pointer; Count: Int64);

procedure WriteObjectManagerSummary;

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Debug.Output,
  Debug.FramebufferConsole;

const
  ObjectHeaderSignature = LongWord($4A424F46); { 'FOBJ' }
  DeletedObjectSignature = LongWord($44454C44); { 'DLED' }

  ObjectFlagNamed = 1;

type
  PObjectHeader = ^TObjectHeader;
  TObjectHeader = record
    Signature: LongWord;
    Flags: LongWord;
    ReferenceCount: Int64;
    ObjectType: PObjectType;
    NamespaceLink: TListEntry;
    Name: array[0..ObjectNameLength - 1] of Char;
  end;

var
  NamespaceLock: TSpinLock;
  NamedObjects: TListEntry;
  ObjectTypes: TListEntry;

{ The header is padded to a multiple of 16 bytes so bodies stay aligned. }
function HeaderSize: QWord;
begin
  Result := (SizeOf(TObjectHeader) + 15) and not QWord(15);
end;

function HeaderOf(ObjectBody: Pointer): PObjectHeader;
var
  Header: PObjectHeader;
begin
  Header := PObjectHeader(PByte(ObjectBody) - HeaderSize);
  if Header^.Signature <> ObjectHeaderSignature then
    KernelPanicWithCode(PanicObjectReferenceFailure,
      'pointer does not refer to a live object', QWord(ObjectBody), Header^.Signature, 0, 0);
  Result := Header;
end;

function BodyOf(Header: PObjectHeader): Pointer;
begin
  Result := Pointer(PByte(Header) + HeaderSize);
end;

function HeaderFromNamespaceLink(Entry: PListEntry): PObjectHeader;
begin
  Result := PObjectHeader(ContainingRecord(Entry, FieldOffset(PObjectHeader(nil)^.NamespaceLink)));
end;

function TypeFromTypeLink(Entry: PListEntry): PObjectType;
begin
  Result := PObjectType(ContainingRecord(Entry, FieldOffset(PObjectType(nil)^.TypeLink)));
end;

procedure InitializeObjectManager;
begin
  InitializeSpinLock(NamespaceLock);
  InitializeListHead(NamedObjects);
  InitializeListHead(ObjectTypes);
end;

procedure RegisterObjectType(var ObjectType: TObjectType; Name: PChar;
  BodySize: QWord; DeleteRoutine: TObjectDeleteRoutine);
var
  PreviousLevel: TPriorityLevel;
begin
  CopyText(@ObjectType.Name[0], Name, ObjectNameLength);
  ObjectType.BodySize := BodySize;
  ObjectType.DeleteRoutine := DeleteRoutine;
  ObjectType.LiveObjectCount := 0;

  PreviousLevel := AcquireSpinLock(NamespaceLock);
  InsertAtTail(ObjectTypes, @ObjectType.TypeLink);
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

{ Called with the namespace lock held. }
function FindNamedObjectLocked(Name: PChar): PObjectHeader;
var
  Entry: PListEntry;
  Header: PObjectHeader;
begin
  Entry := NamedObjects.Next;
  while Entry <> @NamedObjects do
  begin
    Header := HeaderFromNamespaceLink(Entry);
    if TextIsEqual(@Header^.Name[0], Name) then
      Exit(Header);
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

function CreateObject(var ObjectType: TObjectType; Name: PChar): Pointer;
var
  Header: PObjectHeader;
  PreviousLevel: TPriorityLevel;
  IsNamed: Boolean;
begin
  Header := PObjectHeader(AllocateZeroedKernelMemory(HeaderSize + ObjectType.BodySize));
  if Header = nil then
    Exit(nil);

  Header^.Signature := ObjectHeaderSignature;
  Header^.ReferenceCount := 1;
  Header^.ObjectType := @ObjectType;
  InitializeListHead(Header^.NamespaceLink);

  IsNamed := (Name <> nil) and (Name^ <> #0);
  if IsNamed then
  begin
    CopyText(@Header^.Name[0], Name, ObjectNameLength);
    Header^.Flags := ObjectFlagNamed;

    PreviousLevel := AcquireSpinLock(NamespaceLock);
    if FindNamedObjectLocked(@Header^.Name[0]) <> nil then
    begin
      ReleaseSpinLock(NamespaceLock, PreviousLevel);
      Header^.Signature := DeletedObjectSignature;
      FreeKernelMemory(Header);
      Exit(nil);
    end;
    InsertAtTail(NamedObjects, @Header^.NamespaceLink);
    ReleaseSpinLock(NamespaceLock, PreviousLevel);
  end;

  AtomicIncrement(ObjectType.LiveObjectCount);
  Result := BodyOf(Header);
end;

procedure WarnReferenceCountSaturated(Header: PObjectHeader);
begin
  DebugBeginMessage;
  DebugWriteTag('object');
  DebugSetColor(ColorYellow);
  DebugWrite('Warning: ');
  DebugResetColor;
  DebugWrite('the reference count of ');
  DebugWrite(@Header^.ObjectType^.Name[0]);
  DebugWrite(' object ');
  DebugWriteAddress(QWord(BodyOf(Header)));
  if Header^.Name[0] <> #0 then
  begin
    DebugWrite(' (');
    DebugWrite(@Header^.Name[0]);
    DebugWrite(')');
  end;
  DebugWriteLine(' saturated (a reference leak); the object is kept for good');
  DebugEndMessage;
end;

{ Adds a reference and returns the new count, which stays at the limit
  once it got there. }
function TakeReference(Header: PObjectHeader): Int64;
begin
  Result := AtomicIncrement(Header^.ReferenceCount);
  if Result < ObjectReferenceCountLimit then
    Exit;
  if Result = ObjectReferenceCountLimit then
    WarnReferenceCountSaturated(Header)
  else
    AtomicDecrement(Header^.ReferenceCount);
end;

procedure ReferenceObject(ObjectBody: Pointer);
var
  Header: PObjectHeader;
begin
  Header := HeaderOf(ObjectBody);
  if TakeReference(Header) <= 1 then
    KernelPanicWithCode(PanicObjectReferenceFailure,
      'referencing an object that is being deleted', QWord(ObjectBody), 0, 0, 0);
end;

procedure DeleteObject(Header: PObjectHeader);
var
  PreviousLevel: TPriorityLevel;
  ObjectType: PObjectType;
begin
  ObjectType := Header^.ObjectType;

  if (Header^.Flags and ObjectFlagNamed) <> 0 then
  begin
    PreviousLevel := AcquireSpinLock(NamespaceLock);
    RemoveListEntry(@Header^.NamespaceLink);
    ReleaseSpinLock(NamespaceLock, PreviousLevel);
  end;

  if Assigned(ObjectType^.DeleteRoutine) then
    ObjectType^.DeleteRoutine(BodyOf(Header));

  AtomicDecrement(ObjectType^.LiveObjectCount);
  Header^.Signature := DeletedObjectSignature;
  FreeKernelMemory(Header);
end;

procedure DereferenceObject(ObjectBody: Pointer);
var
  Header: PObjectHeader;
  RemainingReferences: Int64;
begin
  Header := HeaderOf(ObjectBody);
  { A saturated count no longer counts: the object stays. }
  if Header^.ReferenceCount >= ObjectReferenceCountLimit then
    Exit;
  RemainingReferences := AtomicDecrement(Header^.ReferenceCount);
  if RemainingReferences < 0 then
    KernelPanicWithCode(PanicObjectReferenceFailure,
      'object reference count dropped below zero', QWord(ObjectBody), 0, 0, 0);
  if RemainingReferences = 0 then
    DeleteObject(Header);
end;

function LookupObjectByName(Name: PChar; ExpectedType: PObjectType): Pointer;
var
  PreviousLevel: TPriorityLevel;
  Header: PObjectHeader;
begin
  Result := nil;
  PreviousLevel := AcquireSpinLock(NamespaceLock);

  Header := FindNamedObjectLocked(Name);
  if (Header <> nil) and ((ExpectedType = nil) or (Header^.ObjectType = ExpectedType)) then
  begin
    { Taking the reference under the lock keeps the object alive even if
      its last other reference is dropped right after we unlock. }
    if TakeReference(Header) > 1 then
      Result := BodyOf(Header)
    else
      AtomicDecrement(Header^.ReferenceCount);
  end;

  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

function ObjectTypeOf(ObjectBody: Pointer): PObjectType;
begin
  Result := HeaderOf(ObjectBody)^.ObjectType;
end;

function ObjectNameOf(ObjectBody: Pointer): PChar;
begin
  Result := @HeaderOf(ObjectBody)^.Name[0];
end;

function ObjectReferenceCount(ObjectBody: Pointer): Int64;
begin
  Result := HeaderOf(ObjectBody)^.ReferenceCount;
end;

procedure SetObjectReferenceCountForTest(ObjectBody: Pointer; Count: Int64);
begin
  HeaderOf(ObjectBody)^.ReferenceCount := Count;
end;

procedure WriteObjectManagerSummary;
const
  MaximumReportedTypes = 16;
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
  ReportedTypes: array[0..MaximumReportedTypes - 1] of PObjectType;
  ReportedCounts: array[0..MaximumReportedTypes - 1] of Int64;
  ReportedTypeCount: Integer;
  Index: Integer;
begin
  { Take a snapshot first: the debug output lock runs at HighLevel, where
    the dispatch level namespace lock can no longer be acquired. }
  ReportedTypeCount := 0;
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Entry := ObjectTypes.Next;
  while (Entry <> @ObjectTypes) and (ReportedTypeCount < MaximumReportedTypes) do
  begin
    ReportedTypes[ReportedTypeCount] := TypeFromTypeLink(Entry);
    ReportedCounts[ReportedTypeCount] := ReportedTypes[ReportedTypeCount]^.LiveObjectCount;
    Inc(ReportedTypeCount);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);

  DebugBeginMessage;
  DebugWriteTag('objects');
  DebugWrite('Live objects by type:');
  for Index := 1 to ReportedTypeCount do
  begin
    DebugWrite(' ');
    DebugWrite(@ReportedTypes[Index - 1]^.Name[0]);
    DebugWrite('=');
    DebugWriteDecimal(QWord(ReportedCounts[Index - 1]));
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
