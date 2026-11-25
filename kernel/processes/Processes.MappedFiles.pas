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
  Mapped files: the pages of a file that processes map.

  A mapped file stands for one file (volume and node number) and holds
  the pages of it that have been read, each read once - through the file
  system and its block cache - the first time some process touched it
  (Processes.AddressSpace's fault resolver asks for it). Every mapping of
  the file, in every process, maps those same physical pages. Each
  mapper takes a reference to every page it maps, so the pages stay
  while any process maps them. The page table's entries carry flags
  (Processes.MappedPageEntries): dirty, preserved.

  There are two kinds, each found in the registry by later mappings of
  the same file, so they share its pages:

    * shared ones (HoldsPrivate False) for shared mappings, read-only
      or writable. They always show the file: a write() to it is copied
      into their resident pages (Processes.MappedFileChanges), and a
      shared writable mapping writes into the pages themselves, which
      are then marked dirty and written back to the file (msync, unmap,
      sync, a background round, the mapped file's end). read() of the
      file copies from their resident pages (TResidentFileReader), so
      it sees what a mapping wrote before it reached the file.
    * private ones for copy on write mappings and program images,
      which keep what the file held when they were mapped: before the
      file changes for the first time while they have users, they
      become snapshots (IsStale: out of the registry, later mappings
      get a new mapped file), and before each change from then on they
      read the pages the change touches - only those - and keep them
      (marked preserved). Pages never touched by a change are still
      read from the file when first needed. Writing a running program's
      file does not change the program. Before a private mapped file is
      found or made, the dirty pages of the shared one are written
      back, so a copy on write mapping starts from what shared mappings
      wrote.

  The regions mapping a mapped file are on its list of mappers (the
  region nodes, AttachMappedFileMapper), so the pages can be taken from
  every mapping: write access before a page is written back (so a later
  write marks it dirty again), the page itself when memory runs short
  (Processes.MappedFileEviction drops clean pages, unmapping them where
  they are mapped; the next touch reads them again).

  A new user joins a mapped file (AcquireMappedFile) under the file's
  volume lock, which a change holds from the first hook to the last:
  so a private user never joins between "no private users, nothing to
  keep" and the write.

  Destroying a mapped file writes its dirty pages back and closes its
  open files, which needs passive level and a thread that may wait for
  the file system; the last reference may go at dispatch level (a
  region removed under the address space's spin lock) or on the thread
  reclaiming memory, so such a mapped file waits on a list until the
  next DrainMappedFileReleases.
}
unit Processes.MappedFiles;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.Mutex,
  Memory.Layout,
  FileSystem.Files,
  Processes.RegionTree;

const
  { Entries in one chunk of a mapped file's page table (a page of it). }
  MappedFileChunkPages = 512;
  { The largest file that may be mapped. }
  MaximumMappedFileBytes = QWord(16) * 1024 * 1024 * 1024;

type
  PMappedFile = ^TMappedFile;
  PPMappedFile = ^PMappedFile;
  TMappedFile = record
    { On the registry's list (snapshots too) until destroyed. }
    Next: PMappedFile;
    IsListed: Boolean;
    Volume: Pointer;
    NodeNumber: QWord;
    { A duplicate for reading, and one for writing once a shared
      writable mapping was made (nil before). }
    OpenedFile: POpenFile;
    WriterFile: POpenFile;
    { For copy on write mappings and images (see above). }
    HoldsPrivate: Boolean;
    SizeInBytes: QWord;
    PageCount: QWord;
    { The page table: ChunkCount chunks of MappedFileChunkPages entries
      each (nil until a page in it is read). }
    Chunks: ^PQWord;
    ChunkCount: QWord;
    ResidentPages: QWord;
    DirtyPages: QWord;
    { When the first of the dirty pages became dirty (uptime, ms). }
    DirtySince: QWord;
    { Holders: regions mapping it, image sections, loads under way. }
    References: LongInt;
    { Those of them that must keep the contents they first saw. }
    PrivateUsers: LongInt;
    { Counts the changes of the file, so a page read across one is read
      again. }
    ChangeCount: QWord;
    { A snapshot (see above). }
    IsStale: Boolean;
    { A snapshot that could not keep a page a change touched: pages not
      in memory are lost. }
    IsDamaged: Boolean;
    { A writable mapping of it went: its dirty pages are written back
      soon (FlushPendingMappedFileWriteBacks). }
    WriteBackPending: Boolean;
    { The thread writing its pages back (its own writes are not copied
      into the pages again). }
    WriteBackThread: Pointer;
    { One write-back at a time. }
    WriteBackLock: TMutex;
    { Where the eviction looks next. }
    EvictionCursor: QWord;
    { The region nodes mapping it (TRegionNode.Mapper*). }
    Mappers: PRegionNode;
    MapperCount: LongInt;
    { On the list of mapped files waiting to be destroyed. }
    PendingNext: PMappedFile;
    Lock: TSpinLock;
  end;

  TMappedFileStatistics = record
    MappedFiles: QWord;
    SnapshotFiles: QWord;
    ResidentPages: QWord;
    DirtyPages: QWord;
    PagesWrittenBack: QWord;
    PagesEvicted: QWord;
    MappingsDropped: QWord;
    SnapshotPagesRead: QWord;
    BytesReadFromPages: QWord;
  end;

  { Takes write access to the pages [FirstPage, EndPage) of MappedFile
    away from every mapping (Processes.MappedFileMappings). Passive
    level, no lock held. }
  TMappedPageProtector = procedure(MappedFile: PMappedFile; FirstPage, EndPage: QWord);

  TMappedPageReference = record
    PageIndex: QWord;
    Physical: TPhysicalAddress;
  end;
  PMappedPageReference = ^TMappedPageReference;

var
  { Counters kept by this unit and Processes.MappedFileChanges /
    Processes.MappedFileEviction. }
  MappedPagesWrittenBack: QWord = 0;
  MappedPagesEvicted: QWord = 0;
  MappedMappingsDropped: QWord = 0;
  MappedSnapshotPagesRead: QWord = 0;
  MappedBytesReadFromPages: QWord = 0;
  { Some mapped file waits for a write-back (WriteBackPending). }
  MappedFileWriteBackRequested: Boolean = False;

procedure InitializeMappedFiles;
procedure SetMappedPageProtector(Protector: TMappedPageProtector);

{ The mapped file of the file OpenedFile is open on (which must be open
  for reading), found in the registry or made, with a reference (a
  private one if IsPrivate). Returns 0 or an Abi error. Passive level. }
function AcquireMappedFile(OpenedFile: POpenFile; IsPrivate: Boolean; out MappedFile: PMappedFile): LongInt;
{ Lets shared writable mappings of MappedFile be made from OpenedFile
  (open for writing): the mapped file keeps a duplicate to write back
  through. ErrorAccessDenied if OpenedFile is not open for writing. }
function PrepareMappedFileForWriting(MappedFile: PMappedFile; OpenedFile: POpenFile): LongInt;
{ One more reference. Any level. }
procedure ReferenceMappedFile(MappedFile: PMappedFile; IsPrivate: Boolean);
{ Gives a reference back; the last one destroys it (at once where that
  may be done, else at the next DrainMappedFileReleases). Any level. }
procedure ReleaseMappedFile(MappedFile: PMappedFile; IsPrivate: Boolean);
{ Destroys the mapped files whose last reference went where they could
  not be destroyed. Passive level. }
procedure DrainMappedFileReleases;

{ The page PageIndex if it is in memory (no reference is taken: for
  looking only). Any level. }
function ResidentMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord;
  out Physical: TPhysicalAddress): Boolean;
{ The same, with a reference to the page for the caller (which keeps it
  from being evicted). Any level. }
function AcquireResidentMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord;
  out Physical: TPhysicalAddress): Boolean;
{ True if page PageIndex waits to be written back. Any level. }
function MappedFilePageIsDirty(MappedFile: PMappedFile; PageIndex: QWord): Boolean;
{ Reads page PageIndex if it is not in memory. Passive level. }
function LoadMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord): LongInt;
{ Copies Length bytes at Offset of the file, through its pages (beyond
  its end: zeros). Passive level. }
function ReadMappedFileBytes(MappedFile: PMappedFile; Offset: QWord; Destination: Pointer;
  Length: QWord): LongInt;
{ Reads the file's page PageIndex into the page Physical (the part
  beyond the end of the file zeroed). Passive level. }
function ReadMappedPageContents(MappedFile: PMappedFile; PageIndex: QWord; Physical: TPhysicalAddress): LongInt;

{ Marks page PageIndex dirty if it is Physical (a shared writable
  mapping is about to write it). False if the page is not Physical.
  Any level. }
function MarkMappedFilePageDirty(MappedFile: PMappedFile; PageIndex: QWord; Physical: TPhysicalAddress): Boolean;
{ Marks page PageIndex preserved (a snapshot's page a change touched). }
procedure MarkMappedFilePagePreserved(MappedFile: PMappedFile; PageIndex: QWord);
{ Takes up to Capacity dirty pages from Position on, below EndPage:
  their dirty marks are cleared and each comes with a reference.
  Position moves past the last page looked at. Any level. }
function TakeDirtyMappedPages(MappedFile: PMappedFile; var Position: QWord; EndPage: QWord;
  Pages: PMappedPageReference; Capacity: Integer): Integer;
{ Writes the dirty pages of [FirstPage, EndPage) back to the file (write
  access to each is taken from the mappings first). 0 or ErrorIo.
  Passive level. }
function WriteBackMappedFile(MappedFile: PMappedFile; FirstPage, EndPage: QWord): LongInt;
{ Asks for MappedFile's dirty pages to be written back soon. Any level. }
procedure MarkMappedFileWriteBackPending(MappedFile: PMappedFile);

{ Puts the region node Node of the address space Space on MappedFile's
  list of mappers, and takes it off again. Any level. }
procedure AttachMappedFileMapper(MappedFile: PMappedFile; Node: PRegionNode; Space: Pointer);
procedure DetachMappedFileMapper(MappedFile: PMappedFile; Node: PRegionNode);

{ Every listed mapped file (Volume nil) or those of one file
  (NodeNumber on Volume), each with a reference, in a block of kernel
  memory (FreeMappedFileList gives both back). False if memory ran out.
  Passive level. }
function ListMappedFiles(Volume: Pointer; NodeNumber: QWord; AllOfVolume: Boolean;
  out Files: PPMappedFile; out Count: Integer): Boolean;
procedure FreeMappedFileList(Files: PPMappedFile; Count: Integer);
{ The mapped file whose pages read() of the file may copy (the shared
  one, else a private one that is not a snapshot), with a reference;
  nil if there is none. Any level. }
function FindMappedFileForReading(Volume: Pointer; NodeNumber: QWord): PMappedFile;

{ Up to Capacity pages that could be dropped (in memory, clean, not
  preserved), from the eviction cursor on, each with a reference. Any
  level. }
function TakeEvictionCandidates(MappedFile: PMappedFile; Pages: PMappedPageReference;
  Capacity: Integer): Integer;
{ Drops the candidate if nothing but the mapped file and the caller
  holds it any more and it is still clean; gives the caller's reference
  back either way. True if the page was freed. Any level. }
function DropEvictionCandidate(MappedFile: PMappedFile; const Page: TMappedPageReference): Boolean;

procedure GetMappedFileStatistics(out Statistics: TMappedFileStatistics);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  FileSystem.Types,
  Kernel.PriorityLevel,
  Kernel.Scheduler,
  Kernel.Clock,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.Pressure,
  Processes.MappedPageEntries,
  Processes.MappedFileRanges;

const
  { Pages written back at a time (write access taken from them
    together). }
  WriteBackBatch = 32;
  { Entries the eviction looks at under one hold of the lock. }
  EvictionScanLimit = 4096;

var
  RegistryLock: TSpinLock;
  Registry: PMappedFile;
  RegistryCount: LongInt;
  PendingLock: TSpinLock;
  PendingReleases: PMappedFile;
  PageProtector: TMappedPageProtector = nil;

procedure SetMappedPageProtector(Protector: TMappedPageProtector);
begin
  PageProtector := Protector;
end;

{ --- Page table -------------------------------------------------------- }

{ Caller holds the lock. }
function EntryOf(MappedFile: PMappedFile; PageIndex: QWord): PQWord;
var
  Chunk: PQWord;
begin
  Chunk := MappedFile^.Chunks[PageIndex div MappedFileChunkPages];
  if Chunk = nil then
    Exit(nil);
  Result := @Chunk[PageIndex mod MappedFileChunkPages];
end;

{ Makes sure the chunk holding PageIndex exists (allocated outside the
  lock). False if memory ran out. }
function EnsureChunk(MappedFile: PMappedFile; PageIndex: QWord): Boolean;
var
  ChunkIndex: QWord;
  Fresh: PQWord;
  PreviousLevel: TPriorityLevel;
  Present: Boolean;
begin
  ChunkIndex := PageIndex div MappedFileChunkPages;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Present := MappedFile^.Chunks[ChunkIndex] <> nil;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  if Present then
    Exit(True);
  Fresh := PQWord(AllocateZeroedKernelMemory(MappedFileChunkPages * SizeOf(QWord)));
  if Fresh = nil then
    Exit(False);
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  if MappedFile^.Chunks[ChunkIndex] = nil then
  begin
    MappedFile^.Chunks[ChunkIndex] := Fresh;
    Fresh := nil;
  end;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  if Fresh <> nil then
    FreeKernelMemory(Fresh);
  Result := True;
end;

function ReadMappedPageContents(MappedFile: PMappedFile; PageIndex: QWord; Physical: TPhysicalAddress): LongInt;
var
  Wanted: QWord;
  BytesRead: QWord;
  Window: PByte;
begin
  Window := PByte(PhysicalToVirtual(Physical));
  Wanted := BytesBeforeEnd(PageIndex, MappedFile^.SizeInBytes);
  BytesRead := 0;
  if (Wanted > 0) and (ReadFromFileAt(MappedFile^.OpenedFile, PageIndex * PageSize, Window, Wanted,
     BytesRead) <> StatusSuccess) then
    Exit(ErrorIo);
  if BytesRead < PageSize then
    ZeroMemory(Window + BytesRead, PageSize - BytesRead);
  Result := ErrorNone;
end;

function ResidentMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord;
  out Physical: TPhysicalAddress): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
begin
  Physical := 0;
  if PageIndex >= MappedFile^.PageCount then
    Exit(False);
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Entry := EntryOf(MappedFile, PageIndex);
  if Entry <> nil then
    Physical := MappedPagePhysical(Entry^);
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  Result := Physical <> 0;
end;

function AcquireResidentMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord;
  out Physical: TPhysicalAddress): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
begin
  Physical := 0;
  if PageIndex >= MappedFile^.PageCount then
    Exit(False);
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Entry := EntryOf(MappedFile, PageIndex);
  if Entry <> nil then
    Physical := MappedPagePhysical(Entry^);
  if Physical <> 0 then
    ReferencePhysicalPage(Physical);
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  Result := Physical <> 0;
end;

function MappedFilePageIsDirty(MappedFile: PMappedFile; PageIndex: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
begin
  Result := False;
  if PageIndex >= MappedFile^.PageCount then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Entry := EntryOf(MappedFile, PageIndex);
  Result := (Entry <> nil) and MappedPageIsDirty(Entry^);
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

function LoadMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
  Seen: QWord;
  Fresh: TPhysicalAddress;
  Existing: TPhysicalAddress;
  Kept: Boolean;
begin
  if PageIndex >= MappedFile^.PageCount then
    Exit(ErrorBadAddress);
  if not EnsureChunk(MappedFile, PageIndex) then
    Exit(ErrorOutOfMemory);
  repeat
    if ResidentMappedFilePage(MappedFile, PageIndex, Existing) then
      Exit(ErrorNone);
    { A snapshot that lost pages: what is not here is gone. }
    if MappedFile^.IsDamaged then
      Exit(ErrorIo);
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Seen := MappedFile^.ChangeCount;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);

    Fresh := AllocatePhysicalPage(PageUsageProgramImage);
    if Fresh = 0 then
      Exit(ErrorOutOfMemory);
    Result := ReadMappedPageContents(MappedFile, PageIndex, Fresh);
    if Result <> ErrorNone then
    begin
      FreePhysicalPage(Fresh);
      Exit;
    end;

    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Entry := EntryOf(MappedFile, PageIndex);
    { Read across a change of the file: maybe old contents; read again. }
    Kept := (Entry^ = 0) and (MappedFile^.ChangeCount = Seen);
    if Kept then
    begin
      Entry^ := MakeMappedPageEntry(Fresh, 0);
      Inc(MappedFile^.ResidentPages);
    end;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    if not Kept then
      FreePhysicalPage(Fresh);
  until Kept or ResidentMappedFilePage(MappedFile, PageIndex, Existing);
  Result := ErrorNone;
end;

function ReadMappedFileBytes(MappedFile: PMappedFile; Offset: QWord; Destination: Pointer;
  Length: QWord): LongInt;
var
  Target: PByte;
  PageIndex: QWord;
  InPage: QWord;
  Piece: QWord;
  Physical: TPhysicalAddress;
begin
  Target := PByte(Destination);
  while Length > 0 do
  begin
    PageIndex := Offset div PageSize;
    InPage := Offset mod PageSize;
    Piece := PageSize - InPage;
    if Piece > Length then
      Piece := Length;
    if PageIndex >= MappedFile^.PageCount then
      ZeroMemory(Target, Piece)
    else
    begin
      { The page may be evicted between reading and taking it. }
      repeat
        Result := LoadMappedFilePage(MappedFile, PageIndex);
        if Result <> ErrorNone then
          Exit;
      until AcquireResidentMappedFilePage(MappedFile, PageIndex, Physical);
      CopyMemory(Target, PByte(PhysicalToVirtual(Physical)) + InPage, Piece);
      FreePhysicalPage(Physical);
    end;
    Target := Target + Piece;
    Offset := Offset + Piece;
    Length := Length - Piece;
  end;
  Result := ErrorNone;
end;

{ --- Dirty pages and writing back ------------------------------------------ }

function MarkMappedFilePageDirty(MappedFile: PMappedFile; PageIndex: QWord; Physical: TPhysicalAddress): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
begin
  Result := False;
  if PageIndex >= MappedFile^.PageCount then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Entry := EntryOf(MappedFile, PageIndex);
  if (Entry <> nil) and (MappedPagePhysical(Entry^) = Physical) and (Physical <> 0) then
  begin
    if not MappedPageIsDirty(Entry^) then
    begin
      Entry^ := Entry^ or MappedPageDirty;
      if MappedFile^.DirtyPages = 0 then
        MappedFile^.DirtySince := UptimeMilliseconds;
      Inc(MappedFile^.DirtyPages);
    end;
    Result := True;
  end;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

procedure MarkMappedFilePagePreserved(MappedFile: PMappedFile; PageIndex: QWord);
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
begin
  if PageIndex >= MappedFile^.PageCount then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Entry := EntryOf(MappedFile, PageIndex);
  if (Entry <> nil) and (Entry^ <> 0) then
    Entry^ := Entry^ or MappedPagePreserved;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

function TakeDirtyMappedPages(MappedFile: PMappedFile; var Position: QWord; EndPage: QWord;
  Pages: PMappedPageReference; Capacity: Integer): Integer;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
  Chunk: PQWord;
begin
  Result := 0;
  if EndPage > MappedFile^.PageCount then
    EndPage := MappedFile^.PageCount;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  while (Position < EndPage) and (Result < Capacity) and (MappedFile^.DirtyPages > 0) do
  begin
    Chunk := MappedFile^.Chunks[Position div MappedFileChunkPages];
    if Chunk = nil then
    begin
      { A whole chunk never read. }
      Position := (Position div MappedFileChunkPages + 1) * MappedFileChunkPages;
      Continue;
    end;
    Entry := @Chunk[Position mod MappedFileChunkPages];
    if MappedPageIsDirty(Entry^) then
    begin
      Entry^ := Entry^ and not MappedPageDirty;
      Dec(MappedFile^.DirtyPages);
      Pages[Result].PageIndex := Position;
      Pages[Result].Physical := MappedPagePhysical(Entry^);
      ReferencePhysicalPage(Pages[Result].Physical);
      Inc(Result);
    end;
    Inc(Position);
  end;
  if MappedFile^.DirtyPages = 0 then
    Position := EndPage;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

function WriteBackMappedFile(MappedFile: PMappedFile; FirstPage, EndPage: QWord): LongInt;
var
  Pages: array[0..WriteBackBatch - 1] of TMappedPageReference;
  Count: Integer;
  Index: Integer;
  Position: QWord;
  Written: QWord;
  Status: TFileSystemStatus;
begin
  Result := ErrorNone;
  { Nothing was ever written through it. }
  if (MappedFile^.WriterFile = nil) or (MappedFile^.DirtyPages = 0) then
    Exit;
  if EndPage > MappedFile^.PageCount then
    EndPage := MappedFile^.PageCount;
  AcquireMutex(MappedFile^.WriteBackLock);
  MappedFile^.WriteBackThread := CurrentThread;
  Position := FirstPage;
  while Position < EndPage do
  begin
    Count := TakeDirtyMappedPages(MappedFile, Position, EndPage, @Pages[0], WriteBackBatch);
    if Count = 0 then
      Break;
    { A write after this marks the page dirty again (and is in what is
      written now, or written next time). }
    if Assigned(PageProtector) then
      PageProtector(MappedFile, Pages[0].PageIndex, Pages[Count - 1].PageIndex + 1);
    for Index := 0 to Count - 1 do
    begin
      Status := WriteToFileWithinSize(MappedFile^.WriterFile, Pages[Index].PageIndex * PageSize,
        PhysicalToVirtual(Pages[Index].Physical), PageSize, Written);
      if Status = StatusSuccess then
        Inc(MappedPagesWrittenBack)
      else
      begin
        { Kept for another try (a later sync). }
        MarkMappedFilePageDirty(MappedFile, Pages[Index].PageIndex, Pages[Index].Physical);
        Result := ErrorIo;
      end;
      FreePhysicalPage(Pages[Index].Physical);
    end;
  end;
  MappedFile^.WriteBackThread := nil;
  ReleaseMutex(MappedFile^.WriteBackLock);
end;

procedure MarkMappedFileWriteBackPending(MappedFile: PMappedFile);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  if MappedFile^.DirtyPages > 0 then
  begin
    MappedFile^.WriteBackPending := True;
    MappedFileWriteBackRequested := True;
  end;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

{ --- Mappers ------------------------------------------------------------- }

procedure AttachMappedFileMapper(MappedFile: PMappedFile; Node: PRegionNode; Space: Pointer);
var
  PreviousLevel: TPriorityLevel;
begin
  if (MappedFile = nil) or (Node^.MapperSpace <> nil) then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Node^.MapperSpace := Space;
  Node^.MapperPrevious := nil;
  Node^.MapperNext := MappedFile^.Mappers;
  if MappedFile^.Mappers <> nil then
    MappedFile^.Mappers^.MapperPrevious := Node;
  MappedFile^.Mappers := Node;
  Inc(MappedFile^.MapperCount);
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

procedure DetachMappedFileMapper(MappedFile: PMappedFile; Node: PRegionNode);
var
  PreviousLevel: TPriorityLevel;
begin
  if (MappedFile = nil) or (Node^.MapperSpace = nil) then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  if Node^.MapperPrevious <> nil then
    Node^.MapperPrevious^.MapperNext := Node^.MapperNext
  else
    MappedFile^.Mappers := Node^.MapperNext;
  if Node^.MapperNext <> nil then
    Node^.MapperNext^.MapperPrevious := Node^.MapperPrevious;
  Node^.MapperNext := nil;
  Node^.MapperPrevious := nil;
  Node^.MapperSpace := nil;
  Dec(MappedFile^.MapperCount);
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

{ --- Lifetime ------------------------------------------------------------ }

procedure UnlistLocked(MappedFile: PMappedFile);
var
  Link: ^PMappedFile;
begin
  if not MappedFile^.IsListed then
    Exit;
  Link := @Registry;
  while (Link^ <> nil) and (Link^ <> MappedFile) do
    Link := @Link^^.Next;
  if Link^ = MappedFile then
    Link^ := MappedFile^.Next;
  MappedFile^.Next := nil;
  MappedFile^.IsListed := False;
  Dec(RegistryCount);
end;

procedure Destroy(MappedFile: PMappedFile);
var
  PreviousLevel: TPriorityLevel;
  ChunkIndex: QWord;
  Index: QWord;
  Chunk: PQWord;
begin
  { Nothing maps it any more: what was written reaches the file. }
  WriteBackMappedFile(MappedFile, 0, MappedFile^.PageCount);

  PreviousLevel := AcquireSpinLock(RegistryLock);
  UnlistLocked(MappedFile);
  ReleaseSpinLock(RegistryLock, PreviousLevel);

  for ChunkIndex := 1 to MappedFile^.ChunkCount do
  begin
    Chunk := MappedFile^.Chunks[ChunkIndex - 1];
    if Chunk = nil then
      Continue;
    for Index := 1 to MappedFileChunkPages do
      if MappedPagePhysical(Chunk[Index - 1]) <> 0 then
        FreePhysicalPage(MappedPagePhysical(Chunk[Index - 1]));
    FreeKernelMemory(Chunk);
  end;
  FreeKernelMemory(MappedFile^.Chunks);
  ChangeMappedFileCount(MappedFile^.OpenedFile, -1);
  CloseFile(MappedFile^.OpenedFile);
  if MappedFile^.WriterFile <> nil then
    CloseFile(MappedFile^.WriterFile);
  FreeKernelMemory(MappedFile);
end;

procedure ReferenceMappedFile(MappedFile: PMappedFile; IsPrivate: Boolean);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Inc(MappedFile^.References);
  if IsPrivate then
    Inc(MappedFile^.PrivateUsers);
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

{ Destroying writes to the file system: not at dispatch level, not on
  the thread reclaiming memory. }
function MayDestroyHere: Boolean;
begin
  Result := CanReclaimMemoryHere;
end;

procedure ReleaseMappedFile(MappedFile: PMappedFile; IsPrivate: Boolean);
var
  PreviousLevel: TPriorityLevel;
  IsLast: Boolean;
begin
  if MappedFile = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Dec(MappedFile^.References);
  if IsPrivate then
    Dec(MappedFile^.PrivateUsers);
  IsLast := MappedFile^.References = 0;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  if not IsLast then
    Exit;
  if MayDestroyHere then
    Destroy(MappedFile)
  else
  begin
    PreviousLevel := AcquireSpinLock(PendingLock);
    MappedFile^.PendingNext := PendingReleases;
    PendingReleases := MappedFile;
    ReleaseSpinLock(PendingLock, PreviousLevel);
  end;
end;

procedure DrainMappedFileReleases;
var
  PreviousLevel: TPriorityLevel;
  Taken: PMappedFile;
  Next: PMappedFile;
begin
  if (PendingReleases = nil) or not MayDestroyHere then
    Exit;
  PreviousLevel := AcquireSpinLock(PendingLock);
  Taken := PendingReleases;
  PendingReleases := nil;
  ReleaseSpinLock(PendingLock, PreviousLevel);
  while Taken <> nil do
  begin
    Next := Taken^.PendingNext;
    Destroy(Taken);
    Taken := Next;
  end;
end;

{ --- The registry ------------------------------------------------------------ }

{ Takes a reference if the mapped file is still alive (one whose last
  reference went is being destroyed and is not brought back). }
function TryReference(MappedFile: PMappedFile; IsPrivate: Boolean): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Result := MappedFile^.References > 0;
  if Result then
  begin
    Inc(MappedFile^.References);
    if IsPrivate then
      Inc(MappedFile^.PrivateUsers);
  end;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

{ A live mapped file of the kind asked for (HoldsPrivate) that is not a
  snapshot, with a reference taken (a private one if PrivateReference),
  or nil. Caller holds RegistryLock. }
function FindKindLocked(Volume: Pointer; NodeNumber: QWord; HoldsPrivate, PrivateReference: Boolean): PMappedFile;
begin
  Result := Registry;
  while Result <> nil do
  begin
    if (Result^.Volume = Volume) and (Result^.NodeNumber = NodeNumber) and
       (Result^.HoldsPrivate = HoldsPrivate) and not Result^.IsStale and
       TryReference(Result, PrivateReference) then
        Exit;
    Result := Result^.Next;
  end;
end;

{ The one a new mapping of that kind joins. }
function FindSharableLocked(Volume: Pointer; NodeNumber: QWord; IsPrivate: Boolean): PMappedFile;
begin
  Result := FindKindLocked(Volume, NodeNumber, IsPrivate, IsPrivate);
end;

function FindMappedFileForReading(Volume: Pointer; NodeNumber: QWord): PMappedFile;
var
  PreviousLevel: TPriorityLevel;
begin
  if Registry = nil then
    Exit(nil);
  PreviousLevel := AcquireSpinLock(RegistryLock);
  Result := FindKindLocked(Volume, NodeNumber, False, False);
  if Result = nil then
    Result := FindKindLocked(Volume, NodeNumber, True, False);
  ReleaseSpinLock(RegistryLock, PreviousLevel);
end;

function ListMappedFiles(Volume: Pointer; NodeNumber: QWord; AllOfVolume: Boolean;
  out Files: PPMappedFile; out Count: Integer): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Capacity: Integer;
  MappedFile: PMappedFile;
  Fits: Boolean;
begin
  Files := nil;
  Count := 0;
  repeat
    Capacity := RegistryCount + 8;
    Files := PPMappedFile(AllocateKernelMemory(QWord(Capacity) * SizeOf(PMappedFile)));
    if Files = nil then
      Exit(False);
    Count := 0;
    Fits := True;
    PreviousLevel := AcquireSpinLock(RegistryLock);
    if RegistryCount > Capacity then
      Fits := False
    else
    begin
      MappedFile := Registry;
      while MappedFile <> nil do
      begin
        if ((Volume = nil) or ((MappedFile^.Volume = Volume) and
           (AllOfVolume or (MappedFile^.NodeNumber = NodeNumber)))) and
           TryReference(MappedFile, False) then
        begin
          Files[Count] := MappedFile;
          Inc(Count);
        end;
        MappedFile := MappedFile^.Next;
      end;
    end;
    ReleaseSpinLock(RegistryLock, PreviousLevel);
    if not Fits then
    begin
      FreeKernelMemory(Files);
      Files := nil;
    end;
  until Fits;
  Result := True;
end;

procedure FreeMappedFileList(Files: PPMappedFile; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    ReleaseMappedFile(Files[Index], False);
  if Files <> nil then
    FreeKernelMemory(Files);
end;

function CreateMappedFile(Duplicate: POpenFile; const Information: TNodeInformation; IsPrivate: Boolean;
  out MappedFile: PMappedFile): LongInt;
begin
  MappedFile := PMappedFile(AllocateZeroedKernelMemory(SizeOf(TMappedFile)));
  if MappedFile = nil then
    Exit(ErrorOutOfMemory);
  MappedFile^.Volume := Duplicate^.Volume;
  MappedFile^.NodeNumber := Information.NodeNumber;
  MappedFile^.OpenedFile := Duplicate;
  MappedFile^.HoldsPrivate := IsPrivate;
  MappedFile^.SizeInBytes := Information.SizeInBytes;
  MappedFile^.PageCount := (Information.SizeInBytes + PageSize - 1) div PageSize;
  MappedFile^.ChunkCount := (MappedFile^.PageCount + MappedFileChunkPages - 1) div MappedFileChunkPages;
  if MappedFile^.ChunkCount = 0 then
    MappedFile^.ChunkCount := 1;
  MappedFile^.Chunks := AllocateZeroedKernelMemory(MappedFile^.ChunkCount * SizeOf(PQWord));
  if MappedFile^.Chunks = nil then
  begin
    FreeKernelMemory(MappedFile);
    MappedFile := nil;
    Exit(ErrorOutOfMemory);
  end;
  InitializeSpinLock(MappedFile^.Lock);
  InitializeMutex(MappedFile^.WriteBackLock);
  ChangeMappedFileCount(Duplicate, 1);
  Result := ErrorNone;
end;

{ Before a copy on write mapping starts: what shared mappings wrote
  reaches the file. }
procedure WriteBackSharedPagesOf(Volume: Pointer; NodeNumber: QWord);
var
  PreviousLevel: TPriorityLevel;
  Shared: PMappedFile;
begin
  if Registry = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(RegistryLock);
  Shared := FindSharableLocked(Volume, NodeNumber, False);
  ReleaseSpinLock(RegistryLock, PreviousLevel);
  if Shared = nil then
    Exit;
  WriteBackMappedFile(Shared, 0, Shared^.PageCount);
  ReleaseMappedFile(Shared, False);
end;

function AcquireMappedFile(OpenedFile: POpenFile; IsPrivate: Boolean; out MappedFile: PMappedFile): LongInt;
var
  Volume: PVolume;
  Information: TNodeInformation;
  Duplicate: POpenFile;
  Existing: PMappedFile;
  PreviousLevel: TPriorityLevel;
begin
  MappedFile := nil;
  DrainMappedFileReleases;
  if (OpenedFile^.Volume = nil) or ((OpenedFile^.Flags and OpenForReading) = 0) then
    Exit(ErrorAccessDenied);
  GetFileInformation(OpenedFile, Information);
  if Information.Kind <> NodeKindFile then
    Exit(ErrorUnsupported);
  if Information.SizeInBytes > MaximumMappedFileBytes then
    Exit(ErrorInvalidArgument);

  Volume := PVolume(OpenedFile^.Volume);
  if IsPrivate then
    WriteBackSharedPagesOf(Volume, Information.NodeNumber);
  AcquireMutex(Volume^.Lock);
  PreviousLevel := AcquireSpinLock(RegistryLock);
  MappedFile := FindSharableLocked(Volume, Information.NodeNumber, IsPrivate);
  ReleaseSpinLock(RegistryLock, PreviousLevel);
  ReleaseMutex(Volume^.Lock);
  if MappedFile <> nil then
    Exit(ErrorNone);

  if DuplicateOpenFileForReading(OpenedFile, Duplicate) <> StatusSuccess then
    Exit(ErrorOutOfMemory);
  Result := CreateMappedFile(Duplicate, Information, IsPrivate, MappedFile);
  if Result <> ErrorNone then
  begin
    CloseFile(Duplicate);
    Exit;
  end;
  MappedFile^.References := 1;
  if IsPrivate then
    MappedFile^.PrivateUsers := 1;

  { Under the volume's lock, as a change of the file holds it (see
    above). }
  AcquireMutex(Volume^.Lock);
  PreviousLevel := AcquireSpinLock(RegistryLock);
  Existing := FindSharableLocked(Volume, Information.NodeNumber, IsPrivate);
  if Existing = nil then
  begin
    MappedFile^.Next := Registry;
    Registry := MappedFile;
    MappedFile^.IsListed := True;
    Inc(RegistryCount);
  end;
  ReleaseSpinLock(RegistryLock, PreviousLevel);
  ReleaseMutex(Volume^.Lock);
  if Existing <> nil then
  begin
    { Made by someone else meanwhile. }
    Destroy(MappedFile);
    MappedFile := Existing;
  end;
  Result := ErrorNone;
end;

function PrepareMappedFileForWriting(MappedFile: PMappedFile; OpenedFile: POpenFile): LongInt;
var
  Duplicate: POpenFile;
  PreviousLevel: TPriorityLevel;
begin
  if (OpenedFile^.Flags and OpenForWriting) = 0 then
    Exit(ErrorAccessDenied);
  if MappedFile^.WriterFile <> nil then
    Exit(ErrorNone);
  if DuplicateOpenFileForWriting(OpenedFile, Duplicate) <> StatusSuccess then
    Exit(ErrorOutOfMemory);
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  if MappedFile^.WriterFile = nil then
  begin
    MappedFile^.WriterFile := Duplicate;
    Duplicate := nil;
  end;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  if Duplicate <> nil then
    CloseFile(Duplicate);
  Result := ErrorNone;
end;

{ --- Eviction ------------------------------------------------------------------ }

function TakeEvictionCandidates(MappedFile: PMappedFile; Pages: PMappedPageReference;
  Capacity: Integer): Integer;
var
  PreviousLevel: TPriorityLevel;
  Looked: QWord;
  Position: QWord;
  Entry: PQWord;
begin
  Result := 0;
  if MappedFile^.IsDamaged or (MappedFile^.PageCount = 0) or (MappedFile^.ResidentPages = 0) then
    Exit;
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Position := MappedFile^.EvictionCursor;
  Looked := 0;
  while (Result < Capacity) and (Looked < MappedFile^.PageCount) and (Looked < EvictionScanLimit) do
  begin
    if Position >= MappedFile^.PageCount then
      Position := 0;
    Entry := EntryOf(MappedFile, Position);
    if (Entry <> nil) and MappedPageIsEvictable(Entry^) then
    begin
      Pages[Result].PageIndex := Position;
      Pages[Result].Physical := MappedPagePhysical(Entry^);
      ReferencePhysicalPage(Pages[Result].Physical);
      Inc(Result);
    end;
    Inc(Position);
    Inc(Looked);
  end;
  MappedFile^.EvictionCursor := Position;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
end;

function DropEvictionCandidate(MappedFile: PMappedFile; const Page: TMappedPageReference): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Entry: PQWord;
begin
  PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
  Entry := EntryOf(MappedFile, Page.PageIndex);
  { The mapped file's reference and the caller's: nobody maps it. A
    mapper takes its reference under this lock (AcquireResident...). }
  Result := (Entry <> nil) and (Entry^ = MakeMappedPageEntry(Page.Physical, 0)) and
    (PhysicalPageHolderCount(Page.Physical) = 2);
  if Result then
  begin
    Entry^ := 0;
    Dec(MappedFile^.ResidentPages);
  end;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  FreePhysicalPage(Page.Physical);
  if Result then
  begin
    FreePhysicalPage(Page.Physical);
    Inc(MappedPagesEvicted);
  end;
end;

{ --- Statistics --------------------------------------------------------------- }

procedure GetMappedFileStatistics(out Statistics: TMappedFileStatistics);
var
  PreviousLevel: TPriorityLevel;
  MappedFile: PMappedFile;
begin
  FillMemory(@Statistics, SizeOf(Statistics), 0);
  PreviousLevel := AcquireSpinLock(RegistryLock);
  MappedFile := Registry;
  while MappedFile <> nil do
  begin
    if MappedFile^.IsStale then
      Inc(Statistics.SnapshotFiles)
    else
      Inc(Statistics.MappedFiles);
    Statistics.ResidentPages := Statistics.ResidentPages + MappedFile^.ResidentPages;
    Statistics.DirtyPages := Statistics.DirtyPages + MappedFile^.DirtyPages;
    MappedFile := MappedFile^.Next;
  end;
  ReleaseSpinLock(RegistryLock, PreviousLevel);
  Statistics.PagesWrittenBack := MappedPagesWrittenBack;
  Statistics.PagesEvicted := MappedPagesEvicted;
  Statistics.MappingsDropped := MappedMappingsDropped;
  Statistics.SnapshotPagesRead := MappedSnapshotPagesRead;
  Statistics.BytesReadFromPages := MappedBytesReadFromPages;
end;

procedure InitializeMappedFiles;
begin
  InitializeSpinLock(RegistryLock);
  InitializeSpinLock(PendingLock);
  Registry := nil;
  RegistryCount := 0;
  PendingReleases := nil;
end;

end.
