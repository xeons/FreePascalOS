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
  The object namespace: a tree of directories in which objects have
  names, written as paths from the root with backslashes:

    \                     the root
    \Device\keyboard      a device (every device listed under /dev)
    \Storage\disk1p2      a disk or partition
    \Ports\display        a port programs connect to by name
    \Kernel\Console       the console, the system process
    \Shared\...           what programs name (mode 1777, like /tmp)

  A directory is an object of type Directory holding a list of entries:
  the name records (TObjectNameRecord) in the headers of the objects
  named in it. Every name record says which directory the object is in,
  its name there, and the owner, group and mode that guard it.

  Lifetimes
    A named object holds a reference to its directory, so a directory
    lives while anything is named in it. The namespace holds no
    reference to an ordinary named object: its name goes when the
    object is deleted (DetachObjectName), or earlier when removed
    (RemoveObjectName). Directories are permanent instead: the namespace
    holds a reference to each until its name is removed (only an empty
    one, and only one a program made). Looking a name up takes a
    reference only if the object is not already being deleted
    (TryReferenceObject): an object whose count reached zero is still
    listed until its deletion takes it out.

  Permissions
    Like files'. Looking up a name needs search permission on every
    directory on the way, naming or removing in a directory write and
    search permission on it (and in a sticky directory, removing needs
    to own the name or the directory), listing read permission. What an
    opened object needs is its caller's to say (Access). The checks are
    made through the caller's TNamespaceCaller: the kernel's own calls
    (KernelNamespaceCaller) are not checked; a program's
    (Processes.ObjectNameCalls) carries its credentials and the routines
    that judge them.

  One spin lock guards the whole tree: lookups are short walks of short
  lists, and names come and go at DispatchLevel too (an object's last
  reference may be dropped there).
}
unit Objects.Namespace;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

const
  { Access bits, as in a mode's rwx. }
  NameAccessRead = 4;
  NameAccessWrite = 2;
  NameAccessSearch = 1;
  { Leaves a field of ChangeObjectSecurity alone. }
  KeepSecurityField = -1;

type
  { May the caller (Credentials, as the caller gave them) have Access to
    something owned by OwnerId and GroupId with Mode? }
  TNameAccessCheck = function(Credentials: Pointer; OwnerId, GroupId, Mode, Access: LongWord): Boolean;
  { Is the caller in group GroupId? }
  TNameGroupCheck = function(Credentials: Pointer; GroupId: LongWord): Boolean;

  { Who asks: unchecked (the kernel) or a program with its credentials. }
  PNamespaceCaller = ^TNamespaceCaller;
  TNamespaceCaller = record
    Checked: Boolean;
    UserId: LongWord;
    Credentials: Pointer;
    MayAccess: TNameAccessCheck;
    IsInGroup: TNameGroupCheck;
  end;

const
  KernelNamespaceCaller: TNamespaceCaller = (Checked: False; UserId: 0; Credentials: nil;
    MayAccess: nil; IsInGroup: nil);

{ Makes the root and the kernel's directories. Once, at startup (from
  InitializeObjectManager). }
procedure InitializeObjectNamespace;

{ Names ObjectBody (which must have no name) Path, owned by OwnerId and
  GroupId with Mode. Errors as for CallNameObject. }
function InsertObjectName(ObjectBody: Pointer; Path: PChar; OwnerId, GroupId, Mode: LongWord;
  const Caller: TNamespaceCaller): LongInt;
{ Takes the object's name away if it still has one (called as a named
  object is deleted). }
procedure DetachObjectName(ObjectBody: Pointer);
{ The object named Path, referenced, if Caller may reach it and has
  Access to it (0: only reaching it); of ExpectedType unless that is
  nil (ErrorInvalidArgument otherwise). }
function LookupObjectPath(Path: PChar; ExpectedType: Pointer; const Caller: TNamespaceCaller;
  Access: LongWord; out ObjectBody: Pointer): LongInt;

{ A new permanent directory. }
function CreateObjectDirectory(Path: PChar; OwnerId, GroupId, Mode: LongWord;
  const Caller: TNamespaceCaller): LongInt;
{ Removes the name Path (CallRemoveObjectName). }
function RemoveObjectName(Path: PChar; const Caller: TNamespaceCaller): LongInt;
{ Changes a name's mode, owner and group (KeepSecurityField: unchanged). }
function ChangeObjectSecurity(Path: PChar; Mode, OwnerId, GroupId: Int64;
  const Caller: TNamespaceCaller): LongInt;
{ Fills up to Capacity entries of directory Path from FirstIndex on;
  Total is how many it has. }
function ListObjectDirectory(Path: PChar; FirstIndex: LongWord; Entries: PAbiObjectDirectoryEntry;
  Capacity: LongWord; out Total: LongWord; out Filled: LongWord; const Caller: TNamespaceCaller): LongInt;

{ The full path of a named object into Buffer; False if it has none (or
  it does not fit). }
function GetObjectPath(ObjectBody: Pointer; Buffer: PChar; Capacity: LongWord): Boolean;
{ How many directories programs have made. }
function ProgramDirectoryCount: LongWord;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Runtime.Atomic,
  Runtime.LinkedList,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Objects.Manager;

const
  DirectoryTypeName: PChar = 'Directory';
  KernelDirectoryMode = $1ED; { rwxr-xr-x }
  OpenDirectoryMode = $3FF;   { rwxrwxrwt }

type
  PObjectDirectory = ^TObjectDirectory;
  TObjectDirectory = record
    Entries: TListEntry;
    EntryCount: LongWord;
  end;

  TNameBuffer = array[0..ObjectNameLength - 1] of Char;

var
  NamespaceLock: TSpinLock;
  DirectoryType: TObjectType;
  RootDirectory: PObjectDirectory;
  ProgramDirectories: LongWord;

function IsDirectory(ObjectBody: Pointer): Boolean;
begin
  Result := ObjectTypeOf(ObjectBody) = @DirectoryType;
end;

{ --- Paths ------------------------------------------------------------- }

{ Copies the next name of a path at Cursor into Name and moves Cursor
  past it (and the backslash after it). }
function TakePathName(var Cursor: PChar; var Name: TNameBuffer): LongInt;
var
  Length: LongWord;
begin
  Length := 0;
  while (Cursor^ <> #0) and (Cursor^ <> '\') do
  begin
    if Length >= ObjectNameLength - 1 then
      Exit(ErrorNameTooLong);
    Name[Length] := Cursor^;
    Inc(Length);
    Inc(Cursor);
  end;
  Name[Length] := #0;
  if Length = 0 then
    Exit(ErrorInvalidArgument);
  if Cursor^ = '\' then
  begin
    Inc(Cursor);
    { A path does not end in a backslash. }
    if Cursor^ = #0 then
      Exit(ErrorInvalidArgument);
  end;
  Result := ErrorNone;
end;

function CheckPathShape(Path: PChar): LongInt;
begin
  if (Path = nil) or (Path^ <> '\') then
    Exit(ErrorInvalidArgument);
  if TextLength(Path) >= MaximumObjectPathLength then
    Exit(ErrorNameTooLong);
  Result := ErrorNone;
end;

{ --- Checks ------------------------------------------------------------ }

function CallerMayAccess(const Caller: TNamespaceCaller; NameRecord: PObjectNameRecord;
  Access: LongWord): Boolean;
begin
  if not Caller.Checked or (Access = 0) then
    Exit(True);
  Result := Caller.MayAccess(Caller.Credentials, NameRecord^.OwnerId, NameRecord^.GroupId,
    NameRecord^.Mode, Access);
end;

function CallerIsRoot(const Caller: TNamespaceCaller): Boolean;
begin
  Result := not Caller.Checked or (Caller.UserId = 0);
end;

{ --- Walking the tree (lock held) ----------------------------------------- }

function FindEntryLocked(Directory: PObjectDirectory; Name: PChar): Pointer;
var
  Entry: PListEntry;
  Candidate: Pointer;
begin
  Entry := Directory^.Entries.Next;
  while Entry <> @Directory^.Entries do
  begin
    Candidate := ObjectOfNameLink(Entry);
    if TextIsEqual(@ObjectNameRecordOf(Candidate)^.Name[0], Name) then
      Exit(Candidate);
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

{ Walks Path to the directory its last name is in: Directory, with that
  name in LastName. Each directory on the way, the last included, must
  be searchable by Caller. The root itself (Path '\') has no last name:
  Directory is nil then. }
function WalkToParentLocked(Path: PChar; const Caller: TNamespaceCaller; out Directory: PObjectDirectory;
  var LastName: TNameBuffer): LongInt;
var
  Cursor: PChar;
  Current: PObjectDirectory;
  Next: Pointer;
begin
  Directory := nil;
  Result := CheckPathShape(Path);
  if Result <> ErrorNone then
    Exit;
  Cursor := Path + 1;
  if Cursor^ = #0 then
    Exit(ErrorNone);
  Current := RootDirectory;
  while True do
  begin
    if not CallerMayAccess(Caller, ObjectNameRecordOf(Current), NameAccessSearch) then
      Exit(ErrorAccessDenied);
    Result := TakePathName(Cursor, LastName);
    if Result <> ErrorNone then
      Exit;
    if Cursor^ = #0 then
    begin
      Directory := Current;
      Exit(ErrorNone);
    end;
    Next := FindEntryLocked(Current, @LastName[0]);
    if Next = nil then
      Exit(ErrorNotFound);
    if not IsDirectory(Next) then
      Exit(ErrorNotDirectory);
    Current := PObjectDirectory(Next);
  end;
end;

{ The object Path names (the root for '\'), or an error. }
function FindPathLocked(Path: PChar; const Caller: TNamespaceCaller; out Found: Pointer): LongInt;
var
  Directory: PObjectDirectory;
  LastName: TNameBuffer;
begin
  Found := nil;
  Result := WalkToParentLocked(Path, Caller, Directory, LastName);
  if Result <> ErrorNone then
    Exit;
  if Directory = nil then
    Found := RootDirectory
  else
    Found := FindEntryLocked(Directory, @LastName[0]);
  if Found = nil then
    Result := ErrorNotFound;
end;

{ Links ObjectBody into Directory as Name (the directory referenced for
  it). }
procedure LinkEntryLocked(Directory: PObjectDirectory; ObjectBody: Pointer; Name: PChar;
  OwnerId, GroupId, Mode: LongWord);
var
  NameRecord: PObjectNameRecord;
begin
  NameRecord := ObjectNameRecordOf(ObjectBody);
  CopyText(@NameRecord^.Name[0], Name, ObjectNameLength);
  NameRecord^.OwnerId := OwnerId;
  NameRecord^.GroupId := GroupId;
  NameRecord^.Mode := Mode and $FFF;
  NameRecord^.Flags := NameRecord^.Flags or NameFlagEverNamed;
  NameRecord^.Parent := Directory;
  InsertAtTail(Directory^.Entries, @NameRecord^.Link);
  Inc(Directory^.EntryCount);
end;

{ Takes an entry out of its directory; returns the directory, whose
  reference the caller drops once the lock is released. }
function UnlinkEntryLocked(ObjectBody: Pointer): PObjectDirectory;
var
  NameRecord: PObjectNameRecord;
begin
  NameRecord := ObjectNameRecordOf(ObjectBody);
  Result := PObjectDirectory(NameRecord^.Parent);
  if Result = nil then
    Exit;
  RemoveListEntry(@NameRecord^.Link);
  InitializeListHead(NameRecord^.Link);
  Dec(Result^.EntryCount);
  NameRecord^.Parent := nil;
end;

{ --- Naming ---------------------------------------------------------------- }

function InsertLocked(ObjectBody: Pointer; Path: PChar; OwnerId, GroupId, Mode: LongWord;
  const Caller: TNamespaceCaller): LongInt;
var
  Directory: PObjectDirectory;
  LastName: TNameBuffer;
begin
  if ObjectNameRecordOf(ObjectBody)^.Parent <> nil then
    Exit(ErrorBusy);
  Result := WalkToParentLocked(Path, Caller, Directory, LastName);
  if Result <> ErrorNone then
    Exit;
  if Directory = nil then
    Exit(ErrorExists);
  if not CallerMayAccess(Caller, ObjectNameRecordOf(Directory), NameAccessWrite) then
    Exit(ErrorAccessDenied);
  if FindEntryLocked(Directory, @LastName[0]) <> nil then
    Exit(ErrorExists);
  { Named in it, the object holds the directory. A directory in the
    tree is never being deleted (the namespace holds it), so this
    cannot fail. }
  if not TryReferenceObject(Directory) then
    Exit(ErrorNotFound);
  LinkEntryLocked(Directory, ObjectBody, @LastName[0], OwnerId, GroupId, Mode);
  Result := ErrorNone;
end;

function InsertObjectName(ObjectBody: Pointer; Path: PChar; OwnerId, GroupId, Mode: LongWord;
  const Caller: TNamespaceCaller): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Result := InsertLocked(ObjectBody, Path, OwnerId, GroupId, Mode, Caller);
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

procedure DetachObjectName(ObjectBody: Pointer);
var
  PreviousLevel: TPriorityLevel;
  Directory: PObjectDirectory;
begin
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Directory := UnlinkEntryLocked(ObjectBody);
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
  if Directory <> nil then
    DereferenceObject(Directory);
end;

function LookupObjectPath(Path: PChar; ExpectedType: Pointer; const Caller: TNamespaceCaller;
  Access: LongWord; out ObjectBody: Pointer): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Found: Pointer;
begin
  ObjectBody := nil;
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Result := FindPathLocked(Path, Caller, Found);
  if (Result = ErrorNone) and (ExpectedType <> nil) and (ObjectTypeOf(Found) <> ExpectedType) then
    Result := ErrorInvalidArgument;
  if (Result = ErrorNone) and not CallerMayAccess(Caller, ObjectNameRecordOf(Found), Access) then
    Result := ErrorAccessDenied;
  { Referenced under the lock: its last other reference may go the
    moment the lock does. One already being deleted is as good as gone. }
  if (Result = ErrorNone) and not TryReferenceObject(Found) then
    Result := ErrorNotFound;
  if Result = ErrorNone then
    ObjectBody := Found;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

{ --- Directories ------------------------------------------------------------ }

function NewDirectoryObject: PObjectDirectory;
begin
  Result := PObjectDirectory(CreateObject(DirectoryType, nil));
  if Result = nil then
    Exit;
  InitializeListHead(Result^.Entries);
  Result^.EntryCount := 0;
  { Its creation reference becomes the namespace's own. }
  ObjectNameRecordOf(Result)^.Flags := NameFlagPermanent;
end;

function CreateObjectDirectory(Path: PChar; OwnerId, GroupId, Mode: LongWord;
  const Caller: TNamespaceCaller): LongInt;
var
  NameRecord: PObjectNameRecord;
  Directory: PObjectDirectory;
  PreviousLevel: TPriorityLevel;
begin
  Directory := NewDirectoryObject;
  if Directory = nil then
    Exit(ErrorOutOfMemory);
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  if Caller.Checked and (ProgramDirectories >= MaximumObjectDirectories) then
    Result := ErrorNoSpace
  else
    Result := InsertLocked(Directory, Path, OwnerId, GroupId, Mode, Caller);
  if (Result = ErrorNone) and Caller.Checked then
  begin
    Inc(ProgramDirectories);
    NameRecord := ObjectNameRecordOf(Directory);
    NameRecord^.Flags := NameRecord^.Flags or NameFlagMadeByProgram;
  end;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
  if Result <> ErrorNone then
    DereferenceObject(Directory);
end;

{ The kernel's own directories, made at startup; never removed. }
procedure CreateKernelDirectory(Path: PChar; Mode: LongWord);
var
  Error: LongInt;
begin
  Error := CreateObjectDirectory(Path, 0, 0, Mode, KernelNamespaceCaller);
  if Error <> ErrorNone then
    KernelPanicWithCode(PanicObjectReferenceFailure, 'could not make a directory of the object namespace',
      QWord(Error), 0, 0, 0);
end;

procedure InitializeObjectNamespace;
begin
  InitializeSpinLock(NamespaceLock);
  RegisterObjectType(DirectoryType, DirectoryTypeName, SizeOf(TObjectDirectory), nil);
  ProgramDirectories := 0;
  RootDirectory := NewDirectoryObject;
  if RootDirectory = nil then
    KernelPanic('could not make the root of the object namespace');
  ObjectNameRecordOf(RootDirectory)^.Mode := KernelDirectoryMode;
  CreateKernelDirectory('\Device', KernelDirectoryMode);
  CreateKernelDirectory('\Storage', KernelDirectoryMode);
  CreateKernelDirectory('\Kernel', KernelDirectoryMode);
  CreateKernelDirectory('\Ports', OpenDirectoryMode);
  CreateKernelDirectory('\Shared', OpenDirectoryMode);
end;

{ True for a directory the kernel made (\Device and the others), which
  stays for good. }
function IsKernelDirectory(ObjectBody: Pointer): Boolean;
begin
  Result := IsDirectory(ObjectBody) and
    ((ObjectNameRecordOf(ObjectBody)^.Flags and NameFlagMadeByProgram) = 0);
end;

{ --- Removing and changing names ------------------------------------------- }

{ In a sticky directory only the name's owner, the directory's owner or
  root may remove (or replace) a name. }
function StickyAllowsLocked(const Caller: TNamespaceCaller; Directory: PObjectDirectory;
  Target: PObjectNameRecord): Boolean;
var
  DirectoryRecord: PObjectNameRecord;
begin
  DirectoryRecord := ObjectNameRecordOf(Directory);
  if CallerIsRoot(Caller) or ((DirectoryRecord^.Mode and ObjectModeSticky) = 0) then
    Exit(True);
  Result := (Caller.UserId = Target^.OwnerId) or (Caller.UserId = DirectoryRecord^.OwnerId);
end;

function RemoveObjectName(Path: PChar; const Caller: TNamespaceCaller): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Directory: PObjectDirectory;
  LastName: TNameBuffer;
  Target: Pointer;
  NameRecord: PObjectNameRecord;
  WasPermanent: Boolean;
begin
  WasPermanent := False;
  Target := nil;
  Directory := nil;
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Result := WalkToParentLocked(Path, Caller, Directory, LastName);
  if (Result = ErrorNone) and (Directory = nil) then
    Result := ErrorNotPermitted;
  if Result = ErrorNone then
  begin
    Target := FindEntryLocked(Directory, @LastName[0]);
    if Target = nil then
      Result := ErrorNotFound;
  end;
  if Result = ErrorNone then
  begin
    NameRecord := ObjectNameRecordOf(Target);
    if not CallerMayAccess(Caller, ObjectNameRecordOf(Directory), NameAccessWrite) or
       not StickyAllowsLocked(Caller, Directory, NameRecord) then
      Result := ErrorAccessDenied
    else if IsKernelDirectory(Target) then
      Result := ErrorNotPermitted
    else if IsDirectory(Target) and (PObjectDirectory(Target)^.EntryCount <> 0) then
      Result := ErrorDirectoryNotEmpty;
  end;
  if Result = ErrorNone then
  begin
    UnlinkEntryLocked(Target);
    WasPermanent := (NameRecord^.Flags and NameFlagPermanent) <> 0;
    NameRecord^.Flags := NameRecord^.Flags and not NameFlagPermanent;
    if IsDirectory(Target) and (ProgramDirectories > 0) then
      Dec(ProgramDirectories);
  end
  else
    Directory := nil;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
  { The entry's hold on its directory, and the namespace's own on a
    directory, go now, outside the lock (either may delete). }
  if Directory <> nil then
    DereferenceObject(Directory);
  if WasPermanent then
    DereferenceObject(Target);
end;

function ChangeObjectSecurity(Path: PChar; Mode, OwnerId, GroupId: Int64;
  const Caller: TNamespaceCaller): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Found: Pointer;
  NameRecord: PObjectNameRecord;
  IsOwner: Boolean;
begin
  if ((Mode <> KeepSecurityField) and ((Mode < 0) or (Mode > $FFF))) or
     ((OwnerId <> KeepSecurityField) and ((OwnerId < 0) or (OwnerId > High(LongWord)))) or
     ((GroupId <> KeepSecurityField) and ((GroupId < 0) or (GroupId > High(LongWord)))) then
    Exit(ErrorInvalidArgument);
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Result := FindPathLocked(Path, Caller, Found);
  if Result = ErrorNone then
  begin
    NameRecord := ObjectNameRecordOf(Found);
    IsOwner := CallerIsRoot(Caller) or (Caller.UserId = NameRecord^.OwnerId);
    if (Mode <> KeepSecurityField) and not IsOwner then
      Result := ErrorNotPermitted;
    if (OwnerId <> KeepSecurityField) and (LongWord(OwnerId) <> NameRecord^.OwnerId) and
       not CallerIsRoot(Caller) then
      Result := ErrorNotPermitted;
    if (GroupId <> KeepSecurityField) and (LongWord(GroupId) <> NameRecord^.GroupId) and
       not CallerIsRoot(Caller) and
       (not IsOwner or not Caller.IsInGroup(Caller.Credentials, LongWord(GroupId))) then
      Result := ErrorNotPermitted;
  end;
  if Result = ErrorNone then
  begin
    if Mode <> KeepSecurityField then
      NameRecord^.Mode := LongWord(Mode);
    if OwnerId <> KeepSecurityField then
      NameRecord^.OwnerId := LongWord(OwnerId);
    if GroupId <> KeepSecurityField then
      NameRecord^.GroupId := LongWord(GroupId);
  end;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

{ --- Listing ------------------------------------------------------------------ }

procedure DescribeEntry(ObjectBody: Pointer; out Entry: TAbiObjectDirectoryEntry);
var
  NameRecord: PObjectNameRecord;
  ObjectType: PObjectType;
begin
  FillMemory(@Entry, SizeOf(Entry), 0);
  NameRecord := ObjectNameRecordOf(ObjectBody);
  ObjectType := ObjectTypeOf(ObjectBody);
  CopyText(@Entry.Name[0], @NameRecord^.Name[0], ObjectNameCapacity);
  CopyText(@Entry.TypeName[0], @ObjectType^.Name[0], SizeOf(Entry.TypeName));
  Entry.Kind := ObjectType^.OpenKind;
  if IsDirectory(ObjectBody) then
  begin
    Entry.Flags := Entry.Flags or ObjectEntryDirectory;
    Entry.EntryCount := PObjectDirectory(ObjectBody)^.EntryCount;
  end;
  if (NameRecord^.Flags and NameFlagPermanent) <> 0 then
    Entry.Flags := Entry.Flags or ObjectEntryPermanent;
  Entry.OwnerId := NameRecord^.OwnerId;
  Entry.GroupId := NameRecord^.GroupId;
  Entry.Mode := NameRecord^.Mode;
  Entry.ReferenceCount := QWord(ObjectReferenceCount(ObjectBody));
end;

function ListObjectDirectory(Path: PChar; FirstIndex: LongWord; Entries: PAbiObjectDirectoryEntry;
  Capacity: LongWord; out Total: LongWord; out Filled: LongWord; const Caller: TNamespaceCaller): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Found: Pointer;
  Directory: PObjectDirectory;
  Entry: PListEntry;
  Index: LongWord;
begin
  Total := 0;
  Filled := 0;
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Result := FindPathLocked(Path, Caller, Found);
  if (Result = ErrorNone) and not IsDirectory(Found) then
    Result := ErrorNotDirectory;
  if (Result = ErrorNone) and not CallerMayAccess(Caller, ObjectNameRecordOf(Found), NameAccessRead) then
    Result := ErrorAccessDenied;
  if Result = ErrorNone then
  begin
    Directory := PObjectDirectory(Found);
    Total := Directory^.EntryCount;
    Index := 0;
    Entry := Directory^.Entries.Next;
    while (Entry <> @Directory^.Entries) and (Filled < Capacity) do
    begin
      if Index >= FirstIndex then
      begin
        DescribeEntry(ObjectOfNameLink(Entry), Entries[Filled]);
        Inc(Filled);
      end;
      Inc(Index);
      Entry := Entry^.Next;
    end;
  end;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

{ --- Paths of objects ------------------------------------------------------------ }

function GetObjectPath(ObjectBody: Pointer; Buffer: PChar; Capacity: LongWord): Boolean;
const
  MaximumDepth = MaximumObjectPathLength div 2;
var
  PreviousLevel: TPriorityLevel;
  Chain: array[0..MaximumDepth - 1] of PObjectNameRecord;
  Depth: LongWord;
  Current: Pointer;
  Used: LongWord;
  Length: LongWord;
begin
  Result := False;
  if Capacity < 2 then
    Exit;
  PreviousLevel := AcquireSpinLock(NamespaceLock);
  Depth := 0;
  Current := ObjectBody;
  while (Current <> RootDirectory) and (Depth < MaximumDepth) do
  begin
    Chain[Depth] := ObjectNameRecordOf(Current);
    Current := Chain[Depth]^.Parent;
    Inc(Depth);
    if Current = nil then
      Break;
  end;
  if (Current = RootDirectory) and ((Depth > 0) or (ObjectBody = RootDirectory)) then
  begin
    Result := True;
    Used := 0;
    if Depth = 0 then
    begin
      Buffer[0] := '\';
      Used := 1;
    end;
    while Result and (Depth > 0) do
    begin
      Dec(Depth);
      Length := TextLength(@Chain[Depth]^.Name[0]);
      if Used + 1 + Length >= Capacity then
        Result := False
      else
      begin
        Buffer[Used] := '\';
        CopyMemory(@Buffer[Used + 1], @Chain[Depth]^.Name[0], Length);
        Inc(Used, 1 + Length);
      end;
    end;
    Buffer[Used] := #0;
  end;
  ReleaseSpinLock(NamespaceLock, PreviousLevel);
end;

function ProgramDirectoryCount: LongWord;
begin
  Result := ProgramDirectories;
end;

end.
