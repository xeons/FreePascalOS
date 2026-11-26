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
  Per-process handle tables.

  User programs refer to kernel objects (open files, the console, pipe
  ends, other processes) through handles: small integers that index the
  process's handle table. Handles 0, 1 and 2 are standard input, output
  and error by convention. A table entry holds a reference to its object,
  which is dropped when the handle is closed.

  The table has two levels: a fixed directory of chunk pointers, and
  chunks of HandlesPerChunk entries allocated as handles reach them, so
  a process with a few handles costs one chunk and one with thousands
  only what it uses. Chunks never move, so an entry stays where it is.
  A new handle gets the lowest free number (at or above the one asked
  for), found quickly: a hint keeps the number below which every handle
  is open, and each chunk counts its open handles, so full chunks are
  passed over whole. The table's limit (a process limit,
  DefaultHandleLimit unless changed with CallSetProcessLimit) bounds the
  numbers handed out, up to HandleLimitCeiling.

  Locking: whoever changes a table holds its process's lock and, while
  the entries change, the table's EntryLock exclusively (taken here).
  Lookups take EntryLock shared, so they need not hold the process's
  lock: threads of one process looking up handles (every read, write
  and wait does) run side by side, and never wait behind a long
  holder of the process lock. A reference taken under the shared lock
  (ReferenceHandleEntry) keeps the object alive after it, even if the
  handle is closed at once. Objects are released after EntryLock is
  given back, so a close that ends in a long delete routine does not
  hold up lookups.
}
unit Processes.Handles;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Kernel.SharedLocks;

const
  HandlesPerChunk = 256;
  DefaultHandleLimit = DefaultProcessHandleLimit;
  HandleLimitCeiling = ProcessHandleLimitCeiling;
  HandleChunkCount = HandleLimitCeiling div HandlesPerChunk;

type
  THandleKind = (
    HandleKindFree,
    HandleKindFile,
    { An open device (Io.Manager), the console included, or /dev. }
    HandleKindDevice,
    HandleKindPipeReadEnd,
    HandleKindPipeWriteEnd,
    HandleKindProcess,
    { A thread of the same process (see Processes.ThreadCalls). }
    HandleKindThread,
    { Objects for programs that work together (Processes.ObjectCalls). }
    HandleKindEvent,
    HandleKindTimer,
    HandleKindSection,
    HandleKindPort,
    HandleKindChannel,
    { A watch on a folder or file (Processes.WatchCalls). }
    HandleKindWatch,
    { A network socket (Processes.SocketCalls). }
    HandleKindSocket,
    { A semaphore (Processes.ObjectCalls). }
    HandleKindSemaphore,
    { A mutex (Processes.ObjectCalls). }
    HandleKindMutex,
    { A local (Unix domain) socket (Processes.LocalSockets); told to
      programs as HandleKindSocket. }
    HandleKindLocalSocket,
    { Event descriptors (Processes.EventDescriptorCalls): an event
      counter (eventfd), a timer descriptor (timerfd), a signal
      descriptor (signalfd), an event poll (epoll) and a watch group
      (inotify). }
    HandleKindEventCounter,
    HandleKindTimerDescriptor,
    HandleKindSignalDescriptor,
    HandleKindEventPoll,
    HandleKindWatchGroup,
    { A job (Processes.Jobs). }
    HandleKindJob,
    { Held for an object about to be stored (ReserveHandle): taken, but
      not usable and never looked up. }
    HandleKindReserved
  );

  PHandleEntry = ^THandleEntry;
  THandleEntry = record
    Kind: THandleKind;
    ObjectBody: Pointer;
  end;

  THandleChunk = record
    OpenCount: LongWord;
    Entries: array[0..HandlesPerChunk - 1] of THandleEntry;
  end;
  PHandleChunk = ^THandleChunk;

  THandleTable = record
    Chunks: array[0..HandleChunkCount - 1] of PHandleChunk;
    { New handles stay below Limit. }
    Limit: LongWord;
    OpenCount: LongWord;
    { Every handle below this one is open. }
    LowestFree: LongWord;
    { Exclusive while entries change, shared for lookups. }
    EntryLock: TSharedLock;
  end;
  PHandleTable = ^THandleTable;

procedure InitializeHandleTable(out Table: THandleTable);
{ Changes the table's limit (at most HandleLimitCeiling); handles
  already open at or above it stay. }
procedure SetHandleLimit(var Table: THandleTable; Limit: LongWord);

{ Stores ObjectBody (taking a new reference) in the lowest free slot at or
  above FirstSlot. Returns the handle, or -1 if the table is full (or
  memory for it ran out). }
function InsertHandle(var Table: THandleTable; Kind: THandleKind; ObjectBody: Pointer;
  FirstSlot: Integer): Integer;

{ Stores into a specific slot (below the limit), closing what was there
  before. False if Handle is out of range or memory ran out. }
function SetHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer): Boolean;
{ SetHandle for a copied table (fork): any slot below the ceiling, as
  the source had it even above a limit lowered since. }
function SetInheritedHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind;
  ObjectBody: Pointer): Boolean;
{ Above every open handle: the end of the last chunk there is. }
function HandleNumberBound(const Table: THandleTable): LongWord;

{ Takes the lowest free number for an object made afterwards (one whose
  creation cannot be undone, a thread): -1 if the table is full. Fill it
  with FillReservedHandle or give it back with CancelReservedHandle. }
function ReserveHandle(var Table: THandleTable): Integer;
procedure FillReservedHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer);
procedure CancelReservedHandle(var Table: THandleTable; Handle: Integer);

{ What Handle holds (taking the table's lock shared): the object is not
  referenced, so the caller must hold the process's lock while it uses
  it, or use ReferenceHandleEntry. }
function LookupHandle(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean;
{ The object behind Handle, referenced (the caller drops the reference),
  and its kind; nil if the handle is not open. Takes only the table's
  lock, shared. }
function ReferenceHandleEntry(var Table: THandleTable; Handle: Int64; out Kind: THandleKind): Pointer;

function CloseHandle(var Table: THandleTable; Handle: Int64): Boolean;
{ Closes every handle and frees the chunks (the table stays usable). }
procedure CloseAllHandles(var Table: THandleTable);
{ How many handles are open (a snapshot: read without the process's
  lock, it may be one out while another thread opens or closes one). }
function CountOpenHandles(const Table: THandleTable): LongWord;

{ What a handle holds on its object, taken and given back outside a
  handle table: by a message carrying the handle (Processes.Channels). A
  reference, and for pipe ends an open end. }
procedure TakeHandleReference(Kind: THandleKind; ObjectBody: Pointer);
procedure DropHandleReference(Kind: THandleKind; ObjectBody: Pointer);

implementation

uses
  Memory.KernelHeap,
  Objects.Manager,
  Io.Pipes,
  Processes.LocalSockets,
  Processes.EventPolls;

procedure InitializeHandleTable(out Table: THandleTable);
var
  Index: Integer;
begin
  for Index := 0 to HandleChunkCount - 1 do
    Table.Chunks[Index] := nil;
  Table.Limit := DefaultHandleLimit;
  Table.OpenCount := 0;
  Table.LowestFree := 0;
  InitializeSharedLock(Table.EntryLock);
end;

procedure SetHandleLimit(var Table: THandleTable; Limit: LongWord);
begin
  if Limit > HandleLimitCeiling then
    Limit := HandleLimitCeiling;
  Table.Limit := Limit;
end;

{ Pipes count their open ends separately from object references, so
  readers can see end of file once every writer is gone. Every object
  counts the handles naming it: the event polls watching it let go of it
  when the last one closes (before the handle's reference goes). }
procedure NoteHandleOpened(Kind: THandleKind; ObjectBody: Pointer);
begin
  NoteObjectHandleOpened(ObjectBody);
  case Kind of
    HandleKindPipeReadEnd: OpenPipeEnd(PPipe(ObjectBody), False);
    HandleKindPipeWriteEnd: OpenPipeEnd(PPipe(ObjectBody), True);
    { Local sockets too: closing the last one disconnects the peer. }
    HandleKindLocalSocket: NoteLocalSocketOpened(PLocalSocket(ObjectBody));
  end;
end;

procedure NoteHandleClosed(Kind: THandleKind; ObjectBody: Pointer);
begin
  case Kind of
    HandleKindPipeReadEnd: ClosePipeEnd(PPipe(ObjectBody), False);
    HandleKindPipeWriteEnd: ClosePipeEnd(PPipe(ObjectBody), True);
    HandleKindLocalSocket: NoteLocalSocketClosed(PLocalSocket(ObjectBody));
  end;
  if NoteObjectHandleClosed(ObjectBody) then
    ForgetObjectInEventPolls(ObjectBody);
end;

procedure TakeHandleReference(Kind: THandleKind; ObjectBody: Pointer);
begin
  ReferenceObject(ObjectBody);
  NoteHandleOpened(Kind, ObjectBody);
end;

procedure DropHandleReference(Kind: THandleKind; ObjectBody: Pointer);
begin
  NoteHandleClosed(Kind, ObjectBody);
  DereferenceObject(ObjectBody);
end;

{ --- Chunks and entries --------------------------------------------- }

{ The chunk holding Handle (below HandleLimitCeiling), allocated if it
  is not there yet; nil if memory ran out. }
function ChunkFor(var Table: THandleTable; Handle: LongWord): PHandleChunk;
var
  ChunkIndex: LongWord;
begin
  ChunkIndex := Handle div HandlesPerChunk;
  Result := Table.Chunks[ChunkIndex];
  if Result <> nil then
    Exit;
  { Zeroed: every entry is HandleKindFree. }
  Result := PHandleChunk(AllocateZeroedKernelMemory(SizeOf(THandleChunk)));
  Table.Chunks[ChunkIndex] := Result;
end;

{ The chunk holding Handle if there is one, else nil. }
function ExistingChunk(const Table: THandleTable; Handle: Int64): PHandleChunk;
begin
  if (Handle < 0) or (Handle >= HandleLimitCeiling) then
    Exit(nil);
  Result := Table.Chunks[Handle div HandlesPerChunk];
end;

procedure FillEntry(var Table: THandleTable; Chunk: PHandleChunk; Handle: LongWord; Kind: THandleKind;
  ObjectBody: Pointer);
begin
  if Kind <> HandleKindReserved then
  begin
    ReferenceObject(ObjectBody);
    NoteHandleOpened(Kind, ObjectBody);
  end;
  Chunk^.Entries[Handle mod HandlesPerChunk].Kind := Kind;
  Chunk^.Entries[Handle mod HandlesPerChunk].ObjectBody := ObjectBody;
  Inc(Chunk^.OpenCount);
  Inc(Table.OpenCount);
  if Handle = Table.LowestFree then
    Table.LowestFree := Handle + 1;
end;

function InsertHandleLocked(var Table: THandleTable; Kind: THandleKind; ObjectBody: Pointer;
  FirstSlot: Integer): Integer;
var
  Handle: LongWord;
  ChunkEnd: LongWord;
  Chunk: PHandleChunk;
begin
  if FirstSlot < 0 then
    FirstSlot := 0;
  Handle := LongWord(FirstSlot);
  if Handle < Table.LowestFree then
    Handle := Table.LowestFree;
  while Handle < Table.Limit do
  begin
    Chunk := ChunkFor(Table, Handle);
    if Chunk = nil then
      Exit(-1);
    ChunkEnd := (Handle div HandlesPerChunk + 1) * HandlesPerChunk;
    if ChunkEnd > Table.Limit then
      ChunkEnd := Table.Limit;
    if Chunk^.OpenCount < HandlesPerChunk then
    begin
      while Handle < ChunkEnd do
      begin
        if Chunk^.Entries[Handle mod HandlesPerChunk].Kind = HandleKindFree then
        begin
          FillEntry(Table, Chunk, Handle, Kind, ObjectBody);
          Exit(Integer(Handle));
        end;
        Inc(Handle);
      end;
    end;
    Handle := ChunkEnd;
  end;
  Result := -1;
end;

function InsertHandle(var Table: THandleTable; Kind: THandleKind; ObjectBody: Pointer;
  FirstSlot: Integer): Integer;
begin
  AcquireSharedLockExclusive(Table.EntryLock);
  Result := InsertHandleLocked(Table, Kind, ObjectBody, FirstSlot);
  ReleaseSharedLock(Table.EntryLock);
end;

{ Takes what Handle holds out of the table (EntryLock held exclusively):
  False if it held nothing; else its kind and object, whose release
  (ReleaseTakenEntry) is the caller's once the lock is given back. }
function TakeEntryLocked(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean; forward;
procedure ReleaseTakenEntry(Kind: THandleKind; ObjectBody: Pointer); forward;

{ SetHandle below Bound. }
function StoreHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer;
  Bound: LongWord): Boolean;
var
  Chunk: PHandleChunk;
  OldKind: THandleKind;
  OldBody: Pointer;
  HadEntry: Boolean;
begin
  if (Handle < 0) or (LongWord(Handle) >= Bound) then
    Exit(False);
  AcquireSharedLockExclusive(Table.EntryLock);
  HadEntry := False;
  Chunk := ChunkFor(Table, LongWord(Handle));
  Result := Chunk <> nil;
  if Result then
  begin
    HadEntry := TakeEntryLocked(Table, Handle, OldKind, OldBody);
    FillEntry(Table, Chunk, LongWord(Handle), Kind, ObjectBody);
  end;
  ReleaseSharedLock(Table.EntryLock);
  if HadEntry then
    ReleaseTakenEntry(OldKind, OldBody);
end;

function SetHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer): Boolean;
begin
  Result := StoreHandle(Table, Handle, Kind, ObjectBody, Table.Limit);
end;

function SetInheritedHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind;
  ObjectBody: Pointer): Boolean;
begin
  Result := StoreHandle(Table, Handle, Kind, ObjectBody, HandleLimitCeiling);
end;

function HandleNumberBound(const Table: THandleTable): LongWord;
var
  ChunkIndex: LongWord;
begin
  Result := 0;
  ChunkIndex := HandleChunkCount;
  while ChunkIndex > 0 do
  begin
    if Table.Chunks[ChunkIndex - 1] <> nil then
      Exit(ChunkIndex * HandlesPerChunk);
    Dec(ChunkIndex);
  end;
end;

function ReserveHandle(var Table: THandleTable): Integer;
begin
  Result := InsertHandle(Table, HandleKindReserved, nil, 0);
end;

function ReservedEntry(var Table: THandleTable; Handle: Integer): PHandleEntry;
var
  Chunk: PHandleChunk;
begin
  Result := nil;
  Chunk := ExistingChunk(Table, Handle);
  if (Chunk <> nil) and (Chunk^.Entries[Handle mod HandlesPerChunk].Kind = HandleKindReserved) then
    Result := @Chunk^.Entries[Handle mod HandlesPerChunk];
end;

procedure FillReservedHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer);
var
  Entry: PHandleEntry;
begin
  AcquireSharedLockExclusive(Table.EntryLock);
  Entry := ReservedEntry(Table, Handle);
  if Entry <> nil then
  begin
    ReferenceObject(ObjectBody);
    NoteHandleOpened(Kind, ObjectBody);
    Entry^.ObjectBody := ObjectBody;
    Entry^.Kind := Kind;
  end;
  ReleaseSharedLock(Table.EntryLock);
end;

procedure CancelReservedHandle(var Table: THandleTable; Handle: Integer);
var
  Entry: PHandleEntry;
  Chunk: PHandleChunk;
begin
  AcquireSharedLockExclusive(Table.EntryLock);
  Entry := ReservedEntry(Table, Handle);
  if Entry <> nil then
  begin
    Chunk := Table.Chunks[Handle div HandlesPerChunk];
    Entry^.Kind := HandleKindFree;
    Entry^.ObjectBody := nil;
    Dec(Chunk^.OpenCount);
    Dec(Table.OpenCount);
    if LongWord(Handle) < Table.LowestFree then
      Table.LowestFree := LongWord(Handle);
  end;
  ReleaseSharedLock(Table.EntryLock);
end;

{ LookupHandle with EntryLock held (either way). }
function LookupHandleLocked(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean;
var
  Chunk: PHandleChunk;
begin
  Kind := HandleKindFree;
  ObjectBody := nil;
  Chunk := ExistingChunk(Table, Handle);
  if Chunk = nil then
    Exit(False);
  Kind := Chunk^.Entries[Handle mod HandlesPerChunk].Kind;
  ObjectBody := Chunk^.Entries[Handle mod HandlesPerChunk].ObjectBody;
  { A reserved slot holds nothing yet. }
  if Kind = HandleKindReserved then
  begin
    Kind := HandleKindFree;
    ObjectBody := nil;
  end;
  Result := Kind <> HandleKindFree;
end;

function LookupHandle(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean;
begin
  AcquireSharedLockShared(Table.EntryLock);
  Result := LookupHandleLocked(Table, Handle, Kind, ObjectBody);
  ReleaseSharedLock(Table.EntryLock);
end;

function ReferenceHandleEntry(var Table: THandleTable; Handle: Int64; out Kind: THandleKind): Pointer;
begin
  AcquireSharedLockShared(Table.EntryLock);
  if LookupHandleLocked(Table, Handle, Kind, Result) then
    ReferenceObject(Result)
  else
    Result := nil;
  ReleaseSharedLock(Table.EntryLock);
end;

function TakeEntryLocked(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean;
var
  Chunk: PHandleChunk;
begin
  if not LookupHandleLocked(Table, Handle, Kind, ObjectBody) then
    Exit(False);
  Chunk := Table.Chunks[Handle div HandlesPerChunk];
  Chunk^.Entries[Handle mod HandlesPerChunk].Kind := HandleKindFree;
  Chunk^.Entries[Handle mod HandlesPerChunk].ObjectBody := nil;
  Dec(Chunk^.OpenCount);
  Dec(Table.OpenCount);
  if Handle < Table.LowestFree then
    Table.LowestFree := LongWord(Handle);
  Result := True;
end;

procedure ReleaseTakenEntry(Kind: THandleKind; ObjectBody: Pointer);
begin
  NoteHandleClosed(Kind, ObjectBody);
  DereferenceObject(ObjectBody);
end;

function CloseHandle(var Table: THandleTable; Handle: Int64): Boolean;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  AcquireSharedLockExclusive(Table.EntryLock);
  Result := TakeEntryLocked(Table, Handle, Kind, ObjectBody);
  ReleaseSharedLock(Table.EntryLock);
  if Result then
    ReleaseTakenEntry(Kind, ObjectBody);
end;

procedure CloseAllHandles(var Table: THandleTable);
var
  ChunkIndex: Integer;
  EntryIndex: Integer;
  Chunk: PHandleChunk;
begin
  for ChunkIndex := 0 to HandleChunkCount - 1 do
  begin
    Chunk := Table.Chunks[ChunkIndex];
    if Chunk = nil then
      Continue;
    EntryIndex := 0;
    while (Chunk^.OpenCount > 0) and (EntryIndex < HandlesPerChunk) do
    begin
      if Chunk^.Entries[EntryIndex].Kind <> HandleKindFree then
        CloseHandle(Table, Int64(ChunkIndex) * HandlesPerChunk + EntryIndex);
      Inc(EntryIndex);
    end;
  end;
  AcquireSharedLockExclusive(Table.EntryLock);
  for ChunkIndex := 0 to HandleChunkCount - 1 do
  begin
    FreeKernelMemory(Table.Chunks[ChunkIndex]);
    Table.Chunks[ChunkIndex] := nil;
  end;
  Table.OpenCount := 0;
  Table.LowestFree := 0;
  ReleaseSharedLock(Table.EntryLock);
end;

function CountOpenHandles(const Table: THandleTable): LongWord;
begin
  Result := Table.OpenCount;
end;

end.
