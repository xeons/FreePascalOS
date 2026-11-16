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
  Watches: objects (of type "Watch") that collect the changes made to a
  folder, a file, or the list of volumes, for a program to read.

  The VFS (FileSystem.Files) reports every change it makes, whichever
  process asked for it and whichever driver carried it out, with
  ReportChange: what happened, the trail of the folder it happened in
  (FileSystem.NodeTrails), the name, and the node it is about. Volumes
  arriving and going away are reported by FileSystem.Volumes. Each
  watch the change concerns gets a record:

    * a watch on a folder, for a name in that folder (with WatchSubtree,
      in any folder below it: the name is then the path from the
      watched folder down);
    * a watch on anything, for a change to the watched node itself
      (written, attributes changed; renamed or moved, which the watch
      follows; removed, which ends the watch);
    * every watch on a volume when the volume goes away (it ends them);
    * a watch on the namespace root (Volume nil: the list of volumes,
      /volumes for programs), for volumes arriving and going away, and
      with WatchSubtree for every change on every volume, the name
      starting with the volume's name.

  A watch knows its node by number, as the node cache does; formats
  whose node numbers change on renaming (FAT and exFAT number a node by
  its directory entry) report the number afterwards, and the watch
  follows it.

  Records wait in a queue of MaximumQueuedWatchRecords. When it is full
  the last place goes to an overflow record and everything else is
  dropped until the program has read it, so the program knows to look
  at the folder again. A record of a write or attribute change that
  repeats the newest one waiting (a file written in many pieces) is not
  queued again.

  Each watch has a notification event, Ready, kept signaled while
  records wait, which CallWaitForHandles waits on. One mutex guards all
  watches; changes are reported with the volume's lock held, so the
  order is: volume lock, then the watch lock.
}
unit FileSystem.Watches;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Abi.SystemCalls,
  Kernel.Events,
  FileSystem.Types,
  FileSystem.NodeTrails;

type
  PWatchRecord = ^TWatchRecord;
  TWatchRecord = record
    Kind: Word;
    Flags: Word;
    Name: PChar;
    OldName: PChar;
  end;

  PWatch = ^TWatch;
  TWatch = record
    Link: TListEntry;
    Ready: TEvent;
    { nil: the namespace root (the list of volumes). }
    Volume: PVolume;
    NodeNumber: QWord;
    IsDirectory: Boolean;
    { Abi Watch* flags. }
    Flags: LongWord;
    { The watched item was removed or its volume went away. }
    HasEnded: Boolean;
    { The overflow record is queued; nothing else is until it is read. }
    HasOverflowed: Boolean;
    Records: array[0..MaximumQueuedWatchRecords - 1] of TWatchRecord;
    FirstRecord: Integer;
    RecordCount: Integer;
  end;

  { A change, as the VFS reports it. }
  TChangeReport = record
    Volume: PVolume;
    { Abi WatchChange*: created, removed, renamed, written, attributes. }
    Kind: Word;
    IsDirectory: Boolean;
    { The folder the change happened in, and the name in it. }
    ParentTrail: PNodeTrail;
    Name: PChar;
    { The node the change is about. }
    NodeNumber: QWord;
    { Renames: the folder and name it went to, and its node number
      there (the same, except on formats that number nodes by place). }
    TargetTrail: PNodeTrail;
    TargetName: PChar;
    NewNodeNumber: QWord;
  end;

  TWatchReadResult = (WatchReadDone, WatchReadEmpty, WatchReadTooSmall);

procedure InitializeWatches;

{ A new watch with one reference (the caller's), or nil. Volume nil
  watches the namespace root. Called with the volume's lock held, so no
  change on it can slip by between resolving the path and watching. }
function CreateWatch(Volume: PVolume; NodeNumber: QWord; IsDirectory: Boolean; Flags: LongWord): PWatch;

{ True while any watch exists: name changes are reported only then
  (open files always keep their trail, for watches made later). }
function WatchesExist: Boolean;

procedure ReportChange(const Report: TChangeReport);
procedure ReportVolumeArrival(Volume: PVolume);
procedure ReportVolumeDeparture(Volume: PVolume);

{ Moves the oldest records that fit into Buffer as Abi watch records
  and says how many bytes they took. }
function ReadWatchRecords(Watch: PWatch; Buffer: PByte; Capacity: QWord; out Used: QWord): TWatchReadResult;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Mutex,
  Objects.Manager;

const
  RecordCapacity = MaximumQueuedWatchRecords;
  { A path inside a watched subtree, with a volume name in front. }
  RelativeNameCapacity = MaximumTrailTextBytes + VolumeNameLength + MaximumNameBytes;

var
  WatchObjectType: TObjectType;
  WatchLock: TMutex;
  AllWatches: TListEntry;
  LiveWatchCount: Integer;

{ --- The queue (watch lock held) ----------------------------------------- }

function RecordAt(Watch: PWatch; Position: Integer): PWatchRecord;
begin
  Result := @Watch^.Records[(Watch^.FirstRecord + Position) mod RecordCapacity];
end;

procedure FreeRecordNames(Entry: PWatchRecord);
begin
  FreeKernelMemory(Entry^.Name);
  FreeKernelMemory(Entry^.OldName);
  Entry^.Name := nil;
  Entry^.OldName := nil;
end;

{ A heap copy of Text (nil stays nil). Allocated tells whether that
  worked. }
function CopyName(Text: PChar; out Allocated: Boolean): PChar;
var
  Length: PtrUInt;
begin
  Allocated := True;
  if Text = nil then
    Exit(nil);
  Length := TextLength(Text);
  Result := PChar(AllocateKernelMemory(Length + 1));
  if Result = nil then
  begin
    Allocated := False;
    Exit;
  end;
  CopyMemory(Result, Text, Length + 1);
end;

function NamesAreEqual(First, Second: PChar): Boolean;
begin
  if (First = nil) or (Second = nil) then
    Exit(First = Second);
  Result := TextIsEqual(First, Second);
end;

{ A write or attribute change repeating the newest record waiting. }
function RepeatsNewestRecord(Watch: PWatch; Kind: Word; Name: PChar): Boolean;
var
  Newest: PWatchRecord;
begin
  Result := False;
  if (Watch^.RecordCount = 0) or ((Kind <> WatchChangeWritten) and (Kind <> WatchChangeAttributes)) then
    Exit;
  Newest := RecordAt(Watch, Watch^.RecordCount - 1);
  Result := (Newest^.Kind = Kind) and NamesAreEqual(Newest^.Name, Name);
end;

procedure AppendRecord(Watch: PWatch; Kind, Flags: Word; Name, OldName: PChar);
var
  Entry: PWatchRecord;
begin
  Entry := RecordAt(Watch, Watch^.RecordCount);
  Entry^.Kind := Kind;
  Entry^.Flags := Flags;
  Entry^.Name := Name;
  Entry^.OldName := OldName;
  Inc(Watch^.RecordCount);
  SignalEvent(Watch^.Ready);
end;

procedure QueueOverflow(Watch: PWatch);
begin
  Watch^.HasOverflowed := True;
  AppendRecord(Watch, WatchChangeOverflow, 0, nil, nil);
end;

procedure QueueRecord(Watch: PWatch; Kind: Word; IsDirectory: Boolean; Name, OldName: PChar);
var
  Flags: Word;
  NameCopy: PChar;
  OldNameCopy: PChar;
  NameAllocated: Boolean;
  OldNameAllocated: Boolean;
begin
  if Watch^.HasEnded or Watch^.HasOverflowed or RepeatsNewestRecord(Watch, Kind, Name) then
    Exit;
  if Watch^.RecordCount >= RecordCapacity - 1 then
  begin
    QueueOverflow(Watch);
    Exit;
  end;
  NameCopy := CopyName(Name, NameAllocated);
  OldNameCopy := CopyName(OldName, OldNameAllocated);
  if not NameAllocated or not OldNameAllocated then
  begin
    { A record that cannot be kept is a lost record, like a full queue. }
    FreeKernelMemory(NameCopy);
    FreeKernelMemory(OldNameCopy);
    QueueOverflow(Watch);
    Exit;
  end;
  Flags := 0;
  if IsDirectory then
    Flags := WatchRecordDirectory;
  AppendRecord(Watch, Kind, Flags, NameCopy, OldNameCopy);
end;

{ Records the end of the watch: nothing is queued after this one. }
procedure QueueEnding(Watch: PWatch; Kind: Word);
begin
  QueueRecord(Watch, Kind, Watch^.IsDirectory, '', nil);
  Watch^.HasEnded := True;
end;

{ --- Objects ---------------------------------------------------------------- }

procedure DeleteWatch(ObjectBody: Pointer);
var
  Watch: PWatch;
  Position: Integer;
begin
  Watch := PWatch(ObjectBody);
  AcquireMutex(WatchLock);
  RemoveListEntry(@Watch^.Link);
  Dec(LiveWatchCount);
  for Position := 0 to Watch^.RecordCount - 1 do
    FreeRecordNames(RecordAt(Watch, Position));
  Watch^.RecordCount := 0;
  ReleaseMutex(WatchLock);
end;

procedure InitializeWatches;
begin
  RegisterObjectType(WatchObjectType, 'Watch', SizeOf(TWatch), @DeleteWatch);
  InitializeMutex(WatchLock);
  InitializeListHead(AllWatches);
  LiveWatchCount := 0;
end;

function CreateWatch(Volume: PVolume; NodeNumber: QWord; IsDirectory: Boolean; Flags: LongWord): PWatch;
begin
  Result := PWatch(CreateObject(WatchObjectType, nil));
  if Result = nil then
    Exit;
  InitializeEvent(Result^.Ready, EventKindNotification, False);
  Result^.Volume := Volume;
  Result^.NodeNumber := NodeNumber;
  Result^.IsDirectory := IsDirectory;
  Result^.Flags := Flags;
  AcquireMutex(WatchLock);
  InsertAtTail(AllWatches, @Result^.Link);
  Inc(LiveWatchCount);
  ReleaseMutex(WatchLock);
end;

function WatchesExist: Boolean;
begin
  Result := LiveWatchCount > 0;
end;

function WatchFromLink(Entry: PListEntry): PWatch;
begin
  Result := PWatch(ContainingRecord(Entry, FieldOffset(PWatch(nil)^.Link)));
end;

{ --- Matching (watch lock held) ----------------------------------------------- }

{ The Watch* flag a kind of change is reported under. }
function FlagForKind(Kind: Word): LongWord;
begin
  case Kind of
    WatchChangeWritten: Result := WatchContents;
    WatchChangeAttributes: Result := WatchAttributes;
  else
    Result := WatchNames;
  end;
end;

procedure AppendText(Destination: PChar; Capacity: PtrUInt; Text: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Destination);
  CopyText(Destination + Length, Text, Capacity - Length);
end;

{ The name of Name (in the folder Trail ends at) as Watch reports it:
  the name itself in the watched folder, the path below it in a watched
  subtree. False if the folder is outside what Watch watches. }
function NameForWatch(Watch: PWatch; Volume: PVolume; Trail: PNodeTrail; Name: PChar;
  RelativeName: PChar): Boolean;
var
  Index: Integer;
begin
  RelativeName[0] := #0;
  if Watch^.Volume = nil then
  begin
    { The namespace root sees every volume as a folder of its own. }
    if (Watch^.Flags and WatchSubtree) = 0 then
      Exit(False);
    CopyText(RelativeName, @Volume^.Name[0], RelativeNameCapacity);
    AppendText(RelativeName, RelativeNameCapacity, @Trail^.Text[0]);
    AppendText(RelativeName, RelativeNameCapacity, '/');
    AppendText(RelativeName, RelativeNameCapacity, Name);
    Exit(True);
  end;
  if Watch^.Volume <> Volume then
    Exit(False);
  Index := FindInTrail(Trail, Watch^.NodeNumber);
  if Index < 0 then
    Exit(False);
  if Index < Trail^.Depth - 1 then
  begin
    if (Watch^.Flags and WatchSubtree) = 0 then
      Exit(False);
    CopyTrailPathBelow(Trail, Index, RelativeName, RelativeNameCapacity);
    AppendText(RelativeName, RelativeNameCapacity, '/');
  end;
  AppendText(RelativeName, RelativeNameCapacity, Name);
  Result := True;
end;

{ A change to the watched node itself. True if it was one. }
function DeliverChangeToItself(Watch: PWatch; const Report: TChangeReport): Boolean;
begin
  Result := (Watch^.Volume = Report.Volume) and (Watch^.NodeNumber = Report.NodeNumber);
  if not Result then
    Exit;
  case Report.Kind of
    WatchChangeRemoved:
      QueueEnding(Watch, WatchChangeWatchedItemRemoved);
    WatchChangeRenamed:
      begin
        Watch^.NodeNumber := Report.NewNodeNumber;
        QueueRecord(Watch, WatchChangeWatchedItemMoved, Watch^.IsDirectory, Report.TargetName, nil);
      end;
    WatchChangeWritten, WatchChangeAttributes:
      if (Watch^.Flags and FlagForKind(Report.Kind)) <> 0 then
        QueueRecord(Watch, Report.Kind, Watch^.IsDirectory, '', nil);
  else
    Result := False;
  end;
end;

procedure DeliverRename(Watch: PWatch; const Report: TChangeReport; SourceName, TargetName: PChar);
var
  SourceInside: Boolean;
  TargetInside: Boolean;
begin
  SourceInside := NameForWatch(Watch, Report.Volume, Report.ParentTrail, Report.Name, SourceName);
  TargetInside := NameForWatch(Watch, Report.Volume, Report.TargetTrail, Report.TargetName, TargetName);
  if SourceInside and TargetInside then
    QueueRecord(Watch, WatchChangeRenamed, Report.IsDirectory, TargetName, SourceName)
  else if SourceInside then
    QueueRecord(Watch, WatchChangeRemoved, Report.IsDirectory, SourceName, nil)
  else if TargetInside then
    QueueRecord(Watch, WatchChangeCreated, Report.IsDirectory, TargetName, nil);
end;

procedure DeliverChange(Watch: PWatch; const Report: TChangeReport; SourceName, TargetName: PChar);
begin
  if Watch^.HasEnded then
    Exit;
  if DeliverChangeToItself(Watch, Report) then
    Exit;
  if (Watch^.Volume <> nil) and not Watch^.IsDirectory then
    Exit;
  if (Watch^.Flags and FlagForKind(Report.Kind)) = 0 then
    Exit;
  if Report.Kind = WatchChangeRenamed then
    DeliverRename(Watch, Report, SourceName, TargetName)
  else if NameForWatch(Watch, Report.Volume, Report.ParentTrail, Report.Name, SourceName) then
    QueueRecord(Watch, Report.Kind, Report.IsDirectory, SourceName, nil);
end;

procedure ReportChange(const Report: TChangeReport);
var
  Entry: PListEntry;
  SourceName: PChar;
  TargetName: PChar;
begin
  if not WatchesExist then
    Exit;
  SourceName := PChar(AllocateKernelMemory(RelativeNameCapacity));
  TargetName := PChar(AllocateKernelMemory(RelativeNameCapacity));
  if (SourceName <> nil) and (TargetName <> nil) then
  begin
    AcquireMutex(WatchLock);
    Entry := AllWatches.Next;
    while Entry <> @AllWatches do
    begin
      DeliverChange(WatchFromLink(Entry), Report, SourceName, TargetName);
      Entry := Entry^.Next;
    end;
    ReleaseMutex(WatchLock);
  end;
  FreeKernelMemory(SourceName);
  FreeKernelMemory(TargetName);
end;

{ --- Volumes ---------------------------------------------------------------- }

function WatchesTheVolumeList(Watch: PWatch): Boolean;
begin
  Result := (Watch^.Volume = nil) and ((Watch^.Flags and WatchNames) <> 0);
end;

procedure ReportVolumeArrival(Volume: PVolume);
var
  Entry: PListEntry;
  Watch: PWatch;
begin
  AcquireMutex(WatchLock);
  Entry := AllWatches.Next;
  while Entry <> @AllWatches do
  begin
    Watch := WatchFromLink(Entry);
    if WatchesTheVolumeList(Watch) then
      QueueRecord(Watch, WatchChangeCreated, True, @Volume^.Name[0], nil);
    Entry := Entry^.Next;
  end;
  ReleaseMutex(WatchLock);
end;

procedure ReportVolumeDeparture(Volume: PVolume);
var
  Entry: PListEntry;
  Watch: PWatch;
begin
  AcquireMutex(WatchLock);
  Entry := AllWatches.Next;
  while Entry <> @AllWatches do
  begin
    Watch := WatchFromLink(Entry);
    if Watch^.Volume = Volume then
      QueueEnding(Watch, WatchChangeVolumeGone)
    else if WatchesTheVolumeList(Watch) then
      QueueRecord(Watch, WatchChangeRemoved, True, @Volume^.Name[0], nil);
    Entry := Entry^.Next;
  end;
  ReleaseMutex(WatchLock);
end;

{ --- Reading ---------------------------------------------------------------- }

function NameLengthOf(Name: PChar): QWord;
begin
  if Name = nil then
    Exit(0);
  Result := TextLength(Name);
end;

{ The bytes a record takes as an Abi record: header, both names with
  their zeros, rounded up to a multiple of 8. }
function AbiRecordSize(Entry: PWatchRecord): QWord;
begin
  Result := SizeOf(TAbiWatchRecord) + NameLengthOf(Entry^.Name) + 1 + NameLengthOf(Entry^.OldName) + 1;
  Result := (Result + 7) and not QWord(7);
end;

procedure WriteAbiRecord(Entry: PWatchRecord; Destination: PByte);
var
  Header: PAbiWatchRecord;
  Text: PChar;
begin
  ZeroMemory(Destination, AbiRecordSize(Entry));
  Header := PAbiWatchRecord(Destination);
  Header^.Size := LongWord(AbiRecordSize(Entry));
  Header^.Kind := Entry^.Kind;
  Header^.Flags := Entry^.Flags;
  Header^.NameLength := LongWord(NameLengthOf(Entry^.Name));
  Header^.OldNameLength := LongWord(NameLengthOf(Entry^.OldName));
  Text := PChar(Destination + SizeOf(TAbiWatchRecord));
  if Entry^.Name <> nil then
    CopyMemory(Text, Entry^.Name, Header^.NameLength);
  Text := Text + Header^.NameLength + 1;
  if Entry^.OldName <> nil then
    CopyMemory(Text, Entry^.OldName, Header^.OldNameLength);
end;

procedure DropOldestRecord(Watch: PWatch);
var
  Oldest: PWatchRecord;
begin
  Oldest := RecordAt(Watch, 0);
  if Oldest^.Kind = WatchChangeOverflow then
    Watch^.HasOverflowed := False;
  FreeRecordNames(Oldest);
  Watch^.FirstRecord := (Watch^.FirstRecord + 1) mod RecordCapacity;
  Dec(Watch^.RecordCount);
end;

function ReadWatchRecords(Watch: PWatch; Buffer: PByte; Capacity: QWord; out Used: QWord): TWatchReadResult;
var
  Oldest: PWatchRecord;
begin
  Used := 0;
  AcquireMutex(WatchLock);
  if Watch^.RecordCount = 0 then
    Result := WatchReadEmpty
  else if AbiRecordSize(RecordAt(Watch, 0)) > Capacity then
    Result := WatchReadTooSmall
  else
  begin
    Result := WatchReadDone;
    while Watch^.RecordCount > 0 do
    begin
      Oldest := RecordAt(Watch, 0);
      if Used + AbiRecordSize(Oldest) > Capacity then
        Break;
      WriteAbiRecord(Oldest, Buffer + Used);
      Used := Used + AbiRecordSize(Oldest);
      DropOldestRecord(Watch);
    end;
    if Watch^.RecordCount = 0 then
      ResetEvent(Watch^.Ready);
  end;
  ReleaseMutex(WatchLock);
end;

end.
