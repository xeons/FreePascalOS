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

  A named object has a place in the object namespace (Objects.Namespace):
  a tree of directories, with paths like \Device\keyboard. Its name
  goes when the object is deleted, or earlier if it is removed. The
  name, the directory it is in, and the owner and mode that guard it
  are in the header's name record (TObjectNameRecord), which the
  namespace manages.

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
  Abi.SystemCalls,
  Runtime.LinkedList;

const
  { One name of a path, its terminating zero included. }
  ObjectNameLength = ObjectNameCapacity;
  ObjectTypeNameLength = 32;
  { Where a reference count saturates. }
  ObjectReferenceCountLimit = Int64(1) shl 40;

  { TObjectNameRecord.Flags. }
  { The object was given a name once (it may have been removed since):
    its deletion asks the namespace to let go of the name. }
  NameFlagEverNamed = $01;
  { The namespace holds a reference of its own (a directory), so the
    object stays until its name is removed. }
  NameFlagPermanent = $02;
  { A directory a program made (CallCreateObjectDirectory): one that may
    be removed. The kernel's stay. }
  NameFlagMadeByProgram = $04;

type
  TObjectDeleteRoutine = procedure(ObjectBody: Pointer);

  PObjectType = ^TObjectType;
  TObjectType = record
    Name: array[0..ObjectTypeNameLength - 1] of Char;
    BodySize: QWord;
    DeleteRoutine: TObjectDeleteRoutine;
    LiveObjectCount: Int64;
    { The handle kind (Abi HandleKind*) a program opens an object of this
      type by name as (CallOpenNamedObject); 0 if it cannot. }
    OpenKind: LongWord;
    TypeLink: TListEntry;
  end;

  { Where an object is in the namespace; changed only by
    Objects.Namespace, under its lock. }
  PObjectNameRecord = ^TObjectNameRecord;
  TObjectNameRecord = record
    { The directory (its body) the object is named in; nil while it has
      no name. }
    Parent: Pointer;
    { In the parent directory's list of entries. }
    Link: TListEntry;
    OwnerId: LongWord;
    GroupId: LongWord;
    { Permission bits as for files (rwx for owner, group, others), and
      ObjectModeSticky for a directory. }
    Mode: LongWord;
    Flags: LongWord;
    Name: array[0..ObjectNameLength - 1] of Char;
  end;

procedure InitializeObjectManager;

{ Registers a new object type. BodySize is the size of the type specific
  data. DeleteRoutine (optional) runs just before an object's memory is
  released. }
procedure RegisterObjectType(var ObjectType: TObjectType; Name: PChar;
  BodySize: QWord; DeleteRoutine: TObjectDeleteRoutine);
{ Lets programs open objects of the type by name, as handles of Kind. }
procedure SetObjectTypeOpenKind(var ObjectType: TObjectType; Kind: LongWord);

{ Creates an object with a reference count of one, owned by the caller.
  The body is zero filled. Path (a full namespace path, \Kernel\Console)
  may be nil for an unnamed object; a named one is owned by root, mode
  0600. Returns nil if memory ran out or the name could not be had. }
function CreateObject(var ObjectType: TObjectType; Path: PChar): Pointer;
{ The same with the name's owner and mode, and why it failed. }
function CreateNamedObject(var ObjectType: TObjectType; Path: PChar; OwnerId, GroupId, Mode: LongWord;
  out Error: LongInt): Pointer;

procedure ReferenceObject(ObjectBody: Pointer);
{ Adds a reference unless the object is being deleted (its count
  reached zero): False then. For finding objects in lists that do not
  hold references (the namespace). }
function TryReferenceObject(ObjectBody: Pointer): Boolean;
procedure DereferenceObject(ObjectBody: Pointer);

{ Finds a named object by its full path and returns it with an extra
  reference, or nil; no permission checks (for the kernel). When
  ExpectedType is not nil the object must be of that type. }
function LookupObjectByName(Path: PChar; ExpectedType: PObjectType): Pointer;

function ObjectTypeOf(ObjectBody: Pointer): PObjectType;
{ The object's own name (the last part of its path), '' if unnamed. }
function ObjectNameOf(ObjectBody: Pointer): PChar;
function ObjectReferenceCount(ObjectBody: Pointer): Int64;
{ For Objects.Namespace: the name record in an object's header, and the
  object a record's Link belongs to. }
function ObjectNameRecordOf(ObjectBody: Pointer): PObjectNameRecord;
function ObjectOfNameLink(Entry: PListEntry): Pointer;

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
  Objects.Namespace,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Debug.Output,
  Debug.FramebufferConsole;

const
  ObjectHeaderSignature = LongWord($4A424F46); { 'FOBJ' }
  DeletedObjectSignature = LongWord($44454C44); { 'DLED' }

  KernelNameMode = $180; { rw------- }

type
  PObjectHeader = ^TObjectHeader;
  TObjectHeader = record
    Signature: LongWord;
    Reserved: LongWord;
    ReferenceCount: Int64;
    ObjectType: PObjectType;
    NameRecord: TObjectNameRecord;
  end;

var
  { Guards the list of types. }
  TypeListLock: TSpinLock;
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

function HeaderOfNameLink(Entry: PListEntry): PObjectHeader;
begin
  Result := PObjectHeader(ContainingRecord(Entry, FieldOffset(PObjectHeader(nil)^.NameRecord.Link)));
end;

function TypeFromTypeLink(Entry: PListEntry): PObjectType;
begin
  Result := PObjectType(ContainingRecord(Entry, FieldOffset(PObjectType(nil)^.TypeLink)));
end;

procedure InitializeObjectManager;
begin
  InitializeSpinLock(TypeListLock);
  InitializeListHead(ObjectTypes);
  InitializeObjectNamespace;
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
  ObjectType.OpenKind := 0;

  PreviousLevel := AcquireSpinLock(TypeListLock);
  InsertAtTail(ObjectTypes, @ObjectType.TypeLink);
  ReleaseSpinLock(TypeListLock, PreviousLevel);
end;

procedure SetObjectTypeOpenKind(var ObjectType: TObjectType; Kind: LongWord);
begin
  ObjectType.OpenKind := Kind;
end;

function CreateNamedObject(var ObjectType: TObjectType; Path: PChar; OwnerId, GroupId, Mode: LongWord;
  out Error: LongInt): Pointer;
var
  Header: PObjectHeader;
begin
  Error := ErrorNone;
  Header := PObjectHeader(AllocateZeroedKernelMemory(HeaderSize + ObjectType.BodySize));
  if Header = nil then
  begin
    Error := ErrorOutOfMemory;
    Exit(nil);
  end;

  Header^.Signature := ObjectHeaderSignature;
  Header^.ReferenceCount := 1;
  Header^.ObjectType := @ObjectType;
  InitializeListHead(Header^.NameRecord.Link);

  if (Path <> nil) and (Path^ <> #0) then
  begin
    Error := InsertObjectName(BodyOf(Header), Path, OwnerId, GroupId, Mode, KernelNamespaceCaller);
    if Error <> ErrorNone then
    begin
      Header^.Signature := DeletedObjectSignature;
      FreeKernelMemory(Header);
      Exit(nil);
    end;
  end;

  AtomicIncrement(ObjectType.LiveObjectCount);
  Result := BodyOf(Header);
end;

function CreateObject(var ObjectType: TObjectType; Path: PChar): Pointer;
var
  Error: LongInt;
begin
  Result := CreateNamedObject(ObjectType, Path, 0, 0, KernelNameMode, Error);
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
  if Header^.NameRecord.Name[0] <> #0 then
  begin
    DebugWrite(' (');
    DebugWrite(@Header^.NameRecord.Name[0]);
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

function TryReferenceObject(ObjectBody: Pointer): Boolean;
var
  Header: PObjectHeader;
begin
  Header := HeaderOf(ObjectBody);
  Result := TakeReference(Header) > 1;
  if not Result then
    AtomicDecrement(Header^.ReferenceCount);
end;

procedure DeleteObject(Header: PObjectHeader);
var
  ObjectType: PObjectType;
begin
  ObjectType := Header^.ObjectType;

  { Unnamed objects (most) never touch the namespace's lock. }
  if (Header^.NameRecord.Flags and NameFlagEverNamed) <> 0 then
    DetachObjectName(BodyOf(Header));

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

function LookupObjectByName(Path: PChar; ExpectedType: PObjectType): Pointer;
begin
  if LookupObjectPath(Path, ExpectedType, KernelNamespaceCaller, 0, Result) <> ErrorNone then
    Result := nil;
end;

function ObjectTypeOf(ObjectBody: Pointer): PObjectType;
begin
  Result := HeaderOf(ObjectBody)^.ObjectType;
end;

function ObjectNameOf(ObjectBody: Pointer): PChar;
begin
  Result := @HeaderOf(ObjectBody)^.NameRecord.Name[0];
end;

function ObjectNameRecordOf(ObjectBody: Pointer): PObjectNameRecord;
begin
  Result := @HeaderOf(ObjectBody)^.NameRecord;
end;

function ObjectOfNameLink(Entry: PListEntry): Pointer;
begin
  Result := BodyOf(HeaderOfNameLink(Entry));
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
  MaximumReportedTypes = 24;
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
  ReportedTypes: array[0..MaximumReportedTypes - 1] of PObjectType;
  ReportedCounts: array[0..MaximumReportedTypes - 1] of Int64;
  ReportedTypeCount: Integer;
  Index: Integer;
begin
  { Take a snapshot first: the debug output lock runs at HighLevel, where
    the dispatch level type list lock can no longer be acquired. }
  ReportedTypeCount := 0;
  PreviousLevel := AcquireSpinLock(TypeListLock);
  Entry := ObjectTypes.Next;
  while (Entry <> @ObjectTypes) and (ReportedTypeCount < MaximumReportedTypes) do
  begin
    ReportedTypes[ReportedTypeCount] := TypeFromTypeLink(Entry);
    ReportedCounts[ReportedTypeCount] := ReportedTypes[ReportedTypeCount]^.LiveObjectCount;
    Inc(ReportedTypeCount);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(TypeListLock, PreviousLevel);

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
