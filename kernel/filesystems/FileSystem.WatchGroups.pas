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
  Watch groups (inotify): many watches read through one handle.

  A group holds watches (FileSystem.Watches) as members, each with a
  watch descriptor (1, 2, ... in the order they were added) and a mask
  of GroupWatch* events. A member's changes do not go to its own queue
  but to the group's (DeliverToWatchGroup), as records in the Linux
  inotify_event layout (TAbiGroupWatchRecord):

    created              GroupWatchCreate (GroupWatchMovedTo when moved in)
    removed              GroupWatchDelete (GroupWatchMovedFrom when moved out)
    renamed in a folder  GroupWatchMovedFrom (old name) and
                         GroupWatchMovedTo (new name), one cookie
    written, resized     GroupWatchModify
    attributes           GroupWatchAttributes
    the item removed     GroupWatchDeleteSelf, then GroupWatchIgnored
    the item moved       GroupWatchMoveSelf
    its volume gone      GroupWatchUnmount, then GroupWatchIgnored

  each only if the mask asks for it (GroupWatchIgnored and
  GroupWatchUnmount always), with GroupWatchIsDirectory for folders. The
  file systems report no opening, closing or reading, so GroupWatchOpen,
  GroupWatchAccess and the closes are accepted and never come. A one
  shot member ends after its first record. An ended member (removed,
  gone, one shot, or its item gone) gets GroupWatchIgnored and stays
  among the members until the next call on the group gives its watch
  back.

  Adding a path watched already (the same volume and node) changes that
  member's mask (or adds to it, GroupWatchMaskAdd) and returns its
  descriptor, or fails with ErrorExists (GroupWatchMaskCreate). Up to GroupWatchMaximumQueued records wait; then one
  GroupWatchQueueOverflow record (descriptor -1) and nothing more until
  the program has read. A record repeating the newest one waiting is not
  queued again.

  The group's state is guarded by the watch lock (LockWatches), which
  changes are reported under; the order is volume lock, then watch lock.
  Its Ready event is signaled while records wait.
}
unit FileSystem.WatchGroups;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Kernel.Events,
  FileSystem.Types;

type
  PWatchGroupRecord = ^TWatchGroupRecord;
  TWatchGroupRecord = record
    Next: PWatchGroupRecord;
    Descriptor: LongInt;
    Mask: LongWord;
    Cookie: LongWord;
    { nil for none. }
    Name: PChar;
  end;

  PWatchGroup = ^TWatchGroup;
  TWatchGroup = record
    Ready: TEvent;
    NonBlocking: Boolean;
    Members: TListEntry;
    NextDescriptor: LongInt;
    First: PWatchGroupRecord;
    Last: PWatchGroupRecord;
    RecordCount: LongInt;
    HasOverflowed: Boolean;
  end;

procedure InitializeWatchGroups;
{ A new empty group with one reference (the caller's), or nil. }
function CreateWatchGroup(NonBlocking: Boolean): PWatchGroup;

{ Adds a member watching the node (Volume nil: the list of volumes), or
  changes the mask of the member that does already: returns its
  descriptor, or a negative Abi error. Called with the volume's lock
  held (FileSystem.Files' WatchPathForGroup). }
function AddGroupWatch(Group: PWatchGroup; Volume: PVolume; NodeNumber: QWord; IsDirectory: Boolean;
  Mask: LongWord): LongInt;
{ Ends member Descriptor (a GroupWatchIgnored record follows):
  ErrorNone or ErrorInvalidArgument. }
function RemoveGroupWatch(Group: PWatchGroup; Descriptor: LongInt): LongInt;

{ From FileSystem.Watches, the watch lock held: a change of a member. }
procedure DeliverToWatchGroup(Member: Pointer; Kind: Word; IsDirectory, Moved: Boolean; Name, OldName: PChar;
  Cookie: LongWord);

{ Moves whole records into Buffer (a kernel buffer of Capacity bytes):
  the bytes, or a negative Abi error (ErrorInvalidArgument when the
  first does not fit, ErrorWouldBlock, ErrorInterrupted). Waits while
  none is queued unless non-blocking. }
function ReadWatchGroup(Group: PWatchGroup; Buffer: PByte; Capacity: QWord): Int64;
function WatchGroupReadiness(Group: PWatchGroup): LongWord;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager,
  FileSystem.Watches;

const
  { Events reported whatever the mask. }
  AlwaysReported = GroupWatchIgnored or GroupWatchUnmount or GroupWatchQueueOverflow;

var
  WatchGroupType: TObjectType;

function MemberFromLink(Entry: PListEntry): PWatch;
begin
  Result := PWatch(ContainingRecord(Entry, FieldOffset(PWatch(nil)^.GroupLink)));
end;

{ --- The queue (watch lock held) ------------------------------------------- }

function NameLengthOf(Name: PChar): QWord;
begin
  if Name = nil then
    Exit(0);
  Result := TextLength(Name);
end;

{ The name's room in a record: its bytes and a zero, padded to 16; 0
  for none. }
function PaddedNameLength(Name: PChar): QWord;
var
  Length: QWord;
begin
  Length := NameLengthOf(Name);
  if Length = 0 then
    Exit(0);
  Result := (Length + 1 + 15) and not QWord(15);
end;

function RecordSize(Entry: PWatchGroupRecord): QWord;
begin
  Result := SizeOf(TAbiGroupWatchRecord) + PaddedNameLength(Entry^.Name);
end;

function NamesAreEqual(First, Second: PChar): Boolean;
begin
  if (NameLengthOf(First) = 0) or (NameLengthOf(Second) = 0) then
    Exit(NameLengthOf(First) = NameLengthOf(Second));
  Result := TextIsEqual(First, Second);
end;

function RepeatsNewest(Group: PWatchGroup; Descriptor: LongInt; Mask, Cookie: LongWord; Name: PChar): Boolean;
var
  Newest: PWatchGroupRecord;
begin
  Newest := Group^.Last;
  Result := (Newest <> nil) and (Newest^.Descriptor = Descriptor) and (Newest^.Mask = Mask) and
    (Newest^.Cookie = Cookie) and NamesAreEqual(Newest^.Name, Name);
end;

procedure AppendRecord(Group: PWatchGroup; Entry: PWatchGroupRecord);
begin
  Entry^.Next := nil;
  if Group^.Last = nil then
    Group^.First := Entry
  else
    Group^.Last^.Next := Entry;
  Group^.Last := Entry;
  Inc(Group^.RecordCount);
  SignalEvent(Group^.Ready);
end;

function NewRecord(Descriptor: LongInt; Mask, Cookie: LongWord; Name: PChar): PWatchGroupRecord;
var
  Length: QWord;
begin
  Result := PWatchGroupRecord(AllocateZeroedKernelMemory(SizeOf(TWatchGroupRecord)));
  if Result = nil then
    Exit;
  Result^.Descriptor := Descriptor;
  Result^.Mask := Mask;
  Result^.Cookie := Cookie;
  Length := NameLengthOf(Name);
  if Length = 0 then
    Exit;
  Result^.Name := PChar(AllocateKernelMemory(Length + 1));
  if Result^.Name = nil then
  begin
    FreeKernelMemory(Result);
    Exit(nil);
  end;
  CopyMemory(Result^.Name, Name, Length + 1);
end;

procedure FreeRecord(Entry: PWatchGroupRecord);
begin
  FreeKernelMemory(Entry^.Name);
  FreeKernelMemory(Entry);
end;

procedure QueueOverflow(Group: PWatchGroup);
var
  Entry: PWatchGroupRecord;
begin
  Group^.HasOverflowed := True;
  Entry := NewRecord(-1, GroupWatchQueueOverflow, 0, nil);
  if Entry <> nil then
    AppendRecord(Group, Entry);
end;

procedure QueueGroupRecord(Group: PWatchGroup; Descriptor: LongInt; Mask, Cookie: LongWord; Name: PChar);
var
  Entry: PWatchGroupRecord;
begin
  if Group^.HasOverflowed or RepeatsNewest(Group, Descriptor, Mask, Cookie, Name) then
    Exit;
  if Group^.RecordCount >= GroupWatchMaximumQueued - 1 then
  begin
    QueueOverflow(Group);
    Exit;
  end;
  Entry := NewRecord(Descriptor, Mask, Cookie, Name);
  if Entry = nil then
    QueueOverflow(Group)
  else
    AppendRecord(Group, Entry);
end;

{ --- Members (watch lock held) --------------------------------------------- }

{ The member's record of Event, if its mask asks for it. True if queued. }
function QueueMemberEvent(Member: PWatch; Event: LongWord; IsDirectory: Boolean; Name: PChar;
  Cookie: LongWord): Boolean;
var
  Mask: LongWord;
begin
  Result := ((Member^.GroupMask and Event) <> 0) or ((Event and AlwaysReported) <> 0);
  if not Result then
    Exit;
  Mask := Event;
  if IsDirectory then
    Mask := Mask or GroupWatchIsDirectory;
  QueueGroupRecord(PWatchGroup(Member^.Group), Member^.GroupDescriptor, Mask, Cookie, Name);
end;

procedure EndMember(Member: PWatch);
begin
  if Member^.HasEnded then
    Exit;
  QueueMemberEvent(Member, GroupWatchIgnored, False, nil, 0);
  Member^.HasEnded := True;
end;

procedure DeliverToWatchGroup(Member: Pointer; Kind: Word; IsDirectory, Moved: Boolean; Name, OldName: PChar;
  Cookie: LongWord);
var
  Watch: PWatch;
  Queued: Boolean;
begin
  Watch := PWatch(Member);
  if Watch^.HasEnded then
    Exit;
  Queued := False;
  case Kind of
    WatchChangeCreated:
      if Moved then
        Queued := QueueMemberEvent(Watch, GroupWatchMovedTo, IsDirectory, Name, Cookie)
      else
        Queued := QueueMemberEvent(Watch, GroupWatchCreate, IsDirectory, Name, 0);
    WatchChangeRemoved:
      if Moved then
        Queued := QueueMemberEvent(Watch, GroupWatchMovedFrom, IsDirectory, Name, Cookie)
      else
        Queued := QueueMemberEvent(Watch, GroupWatchDelete, IsDirectory, Name, 0);
    WatchChangeRenamed:
      begin
        Queued := QueueMemberEvent(Watch, GroupWatchMovedFrom, IsDirectory, OldName, Cookie);
        if QueueMemberEvent(Watch, GroupWatchMovedTo, IsDirectory, Name, Cookie) then
          Queued := True;
      end;
    WatchChangeWritten:
      Queued := QueueMemberEvent(Watch, GroupWatchModify, IsDirectory, Name, 0);
    WatchChangeAttributes:
      Queued := QueueMemberEvent(Watch, GroupWatchAttributes, IsDirectory, Name, 0);
    WatchChangeWatchedItemMoved:
      Queued := QueueMemberEvent(Watch, GroupWatchMoveSelf, False, nil, 0);
    WatchChangeWatchedItemRemoved:
      begin
        QueueMemberEvent(Watch, GroupWatchDeleteSelf, False, nil, 0);
        EndMember(Watch);
      end;
    WatchChangeVolumeGone:
      begin
        QueueMemberEvent(Watch, GroupWatchUnmount, False, nil, 0);
        EndMember(Watch);
      end;
  end;
  if Queued and ((Watch^.GroupMask and GroupWatchOneShot) <> 0) then
    EndMember(Watch);
end;

{ Takes the ended members out of the group into Ended (watch lock held);
  their watches are given back with ReleaseMembers once it is not. }
procedure TakeEndedMembers(Group: PWatchGroup; var Ended: TListEntry; Everyone: Boolean);
var
  Entry: PListEntry;
  Following: PListEntry;
  Member: PWatch;
begin
  Entry := Group^.Members.Next;
  while Entry <> @Group^.Members do
  begin
    Following := Entry^.Next;
    Member := MemberFromLink(Entry);
    if Everyone or Member^.HasEnded then
    begin
      RemoveListEntry(Entry);
      Member^.HasEnded := True;
      Member^.Group := nil;
      InsertAtTail(Ended, Entry);
    end;
    Entry := Following;
  end;
end;

procedure ReleaseMembers(var Ended: TListEntry);
var
  Entry: PListEntry;
begin
  while not ListIsEmpty(Ended) do
  begin
    Entry := Ended.Next;
    RemoveListEntry(Entry);
    DereferenceObject(MemberFromLink(Entry));
  end;
end;

procedure ReleaseEndedMembers(Group: PWatchGroup);
var
  Ended: TListEntry;
begin
  InitializeListHead(Ended);
  LockWatches;
  TakeEndedMembers(Group, Ended, False);
  UnlockWatches;
  ReleaseMembers(Ended);
end;

{ --- Objects ---------------------------------------------------------------- }

procedure DeleteWatchGroup(ObjectBody: Pointer);
var
  Group: PWatchGroup;
  Ended: TListEntry;
  Entry: PWatchGroupRecord;
begin
  Group := PWatchGroup(ObjectBody);
  InitializeListHead(Ended);
  LockWatches;
  TakeEndedMembers(Group, Ended, True);
  while Group^.First <> nil do
  begin
    Entry := Group^.First;
    Group^.First := Entry^.Next;
    FreeRecord(Entry);
  end;
  Group^.Last := nil;
  Group^.RecordCount := 0;
  UnlockWatches;
  ReleaseMembers(Ended);
end;

procedure InitializeWatchGroups;
begin
  RegisterObjectType(WatchGroupType, 'WatchGroup', SizeOf(TWatchGroup), @DeleteWatchGroup);
end;

function CreateWatchGroup(NonBlocking: Boolean): PWatchGroup;
begin
  Result := PWatchGroup(CreateObject(WatchGroupType, nil));
  if Result = nil then
    Exit;
  InitializeEvent(Result^.Ready, EventKindNotification, False);
  Result^.NonBlocking := NonBlocking;
  InitializeListHead(Result^.Members);
  Result^.NextDescriptor := 1;
end;

{ The live member watching the node, or nil (watch lock held). }
function FindMember(Group: PWatchGroup; Volume: PVolume; NodeNumber: QWord): PWatch;
var
  Entry: PListEntry;
  Member: PWatch;
begin
  Entry := Group^.Members.Next;
  while Entry <> @Group^.Members do
  begin
    Member := MemberFromLink(Entry);
    if not Member^.HasEnded and (Member^.Volume = Volume) and
       ((Volume = nil) or (Member^.NodeNumber = NodeNumber)) then
      Exit(Member);
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

function FindMemberByDescriptor(Group: PWatchGroup; Descriptor: LongInt): PWatch;
var
  Entry: PListEntry;
  Member: PWatch;
begin
  Entry := Group^.Members.Next;
  while Entry <> @Group^.Members do
  begin
    Member := MemberFromLink(Entry);
    if not Member^.HasEnded and (Member^.GroupDescriptor = Descriptor) then
      Exit(Member);
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

procedure SetMemberMask(Member: PWatch; Mask: LongWord);
begin
  Member^.GroupMask := Mask;
  Member^.Flags := WatchFlagsOfGroupMask(Mask);
end;

function AddGroupWatch(Group: PWatchGroup; Volume: PVolume; NodeNumber: QWord; IsDirectory: Boolean;
  Mask: LongWord): LongInt;
var
  Member: PWatch;
  Created: PWatch;
begin
  ReleaseEndedMembers(Group);
  LockWatches;
  Member := FindMember(Group, Volume, NodeNumber);
  if (Member <> nil) and ((Mask and GroupWatchMaskCreate) <> 0) then
  begin
    UnlockWatches;
    Exit(-ErrorExists);
  end;
  Mask := Mask and not GroupWatchMaskCreate;
  if Member <> nil then
  begin
    if (Mask and GroupWatchMaskAdd) <> 0 then
      SetMemberMask(Member, (Member^.GroupMask or Mask) and not GroupWatchMaskAdd)
    else
      SetMemberMask(Member, Mask);
    Result := Member^.GroupDescriptor;
    UnlockWatches;
    Exit;
  end;
  UnlockWatches;
  { Made outside the watch lock (CreateWatch takes it); the volume's lock,
    held, keeps changes away until it joins the group. }
  Created := CreateWatch(Volume, NodeNumber, IsDirectory, WatchFlagsOfGroupMask(Mask));
  if Created = nil then
    Exit(-ErrorOutOfMemory);
  LockWatches;
  Created^.Group := Group;
  Created^.GroupMask := Mask and not GroupWatchMaskAdd;
  Created^.GroupDescriptor := Group^.NextDescriptor;
  if Group^.NextDescriptor < High(LongInt) then
    Inc(Group^.NextDescriptor);
  InsertAtTail(Group^.Members, @Created^.GroupLink);
  Result := Created^.GroupDescriptor;
  UnlockWatches;
end;

function RemoveGroupWatch(Group: PWatchGroup; Descriptor: LongInt): LongInt;
var
  Member: PWatch;
begin
  LockWatches;
  Member := FindMemberByDescriptor(Group, Descriptor);
  if Member = nil then
    Result := ErrorInvalidArgument
  else
  begin
    EndMember(Member);
    Result := ErrorNone;
  end;
  UnlockWatches;
  ReleaseEndedMembers(Group);
end;

{ --- Reading ---------------------------------------------------------------- }

procedure WriteRecord(Entry: PWatchGroupRecord; Destination: PByte);
var
  Header: PAbiGroupWatchRecord;
begin
  ZeroMemory(Destination, RecordSize(Entry));
  Header := PAbiGroupWatchRecord(Destination);
  Header^.Descriptor := Entry^.Descriptor;
  Header^.Mask := Entry^.Mask;
  Header^.Cookie := Entry^.Cookie;
  Header^.NameLength := LongWord(PaddedNameLength(Entry^.Name));
  if Header^.NameLength > 0 then
    CopyMemory(Destination + SizeOf(TAbiGroupWatchRecord), Entry^.Name, NameLengthOf(Entry^.Name));
end;

{ Moves records (watch lock held): the bytes, 0 for none queued, -1 when
  the first does not fit. }
function TakeRecordsLocked(Group: PWatchGroup; Buffer: PByte; Capacity: QWord): Int64;
var
  Entry: PWatchGroupRecord;
  Used: QWord;
begin
  if Group^.First = nil then
    Exit(0);
  if RecordSize(Group^.First) > Capacity then
    Exit(-1);
  Used := 0;
  while (Group^.First <> nil) and (Used + RecordSize(Group^.First) <= Capacity) do
  begin
    Entry := Group^.First;
    WriteRecord(Entry, Buffer + Used);
    Used := Used + RecordSize(Entry);
    Group^.First := Entry^.Next;
    if Group^.First = nil then
      Group^.Last := nil;
    Dec(Group^.RecordCount);
    if Entry^.Mask = GroupWatchQueueOverflow then
      Group^.HasOverflowed := False;
    FreeRecord(Entry);
  end;
  if Group^.First = nil then
    ResetEvent(Group^.Ready);
  Result := Int64(Used);
end;

function ReadWatchGroup(Group: PWatchGroup; Buffer: PByte; Capacity: QWord): Int64;
begin
  ReleaseEndedMembers(Group);
  repeat
    LockWatches;
    Result := TakeRecordsLocked(Group, Buffer, Capacity);
    UnlockWatches;
    if Result < 0 then
      Exit(-Int64(ErrorInvalidArgument));
    if Result > 0 then
      Exit;
    if Group^.NonBlocking then
      Exit(-Int64(ErrorWouldBlock));
    if WaitForEventWithOptions(Group^.Ready, InfiniteTimeout, True) <> WaitSignaled then
      Exit(-Int64(ErrorInterrupted));
  until False;
end;

function WatchGroupReadiness(Group: PWatchGroup): LongWord;
begin
  Result := 0;
  if Group^.First <> nil then
    Result := PollReadable;
end;

end.
