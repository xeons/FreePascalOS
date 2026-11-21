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
  the file, in every process, maps those same physical pages: read-only
  shared, or copy on write for private mappings, program data and
  library data (Processes.ImageLoader maps programs and libraries this
  way). Each mapper takes a reference to every page it maps, so the
  pages stay while any process maps them.

  The registry finds the mapped file of a file that is mapped already,
  so a second mapping, or a second process running the same program,
  shares its pages. A mapped file keeps an open file of its own (a
  duplicate for reading): the program may close its handle, and the file
  may lose its name, without the mapping losing its contents.

  When the file changes:

    * Before the change lands (TFileChangingHook, under the volume's
      lock), a mapped file with private users - copy on write mappings,
      program images - reads every page it has not read yet, so they
      all keep the contents they were mapped with, and leaves the
      registry (it is stale: later mappings get a new mapped file).
      Writing a running program's file does not change the program.
    * After a change (TFileChangedHook), the pages a mapped file with
      only shared read-only mappings holds are read again where the
      change touched them, in place, so those mappings show what read()
      shows. A page being read while the change happened is read again
      (ChangeCount), never kept with the old contents.

  Destroying a mapped file closes its open file, which needs passive
  level; the last reference may go at dispatch level (a region removed
  under the address space's spin lock), so such a mapped file waits on a
  list until the next DrainMappedFileReleases.
}
unit Processes.MappedFiles;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Memory.Layout,
  FileSystem.Files;

const
  { Entries in one chunk of a mapped file's page table (a page of it). }
  MappedFileChunkPages = 512;
  { The largest file that may be mapped. }
  MaximumMappedFileBytes = QWord(16) * 1024 * 1024 * 1024;

type
  PMappedFile = ^TMappedFile;
  TMappedFile = record
    { In the registry, while it is not stale. }
    Next: PMappedFile;
    IsRegistered: Boolean;
    Volume: Pointer;
    NodeNumber: QWord;
    OpenedFile: POpenFile;
    SizeInBytes: QWord;
    PageCount: QWord;
    { The page table: ChunkCount chunks of MappedFileChunkPages physical
      addresses each (nil until a page in it is read; 0 where a page is
      not read yet). }
    Chunks: ^PQWord;
    ChunkCount: QWord;
    ResidentPages: QWord;
    { Holders: regions mapping it, image sections, loads under way. }
    References: LongInt;
    { Those of them that must keep the contents they first saw. }
    PrivateUsers: LongInt;
    { Counts the changes of the file, so a page read across one is read
      again. }
    ChangeCount: QWord;
    { Its file changed while it had private users: its pages are the
      old contents, all of them read; it never reads again. }
    IsStale: Boolean;
    { On the list of mapped files waiting to be destroyed. }
    PendingNext: PMappedFile;
    Lock: TSpinLock;
  end;

  TMappedFileStatistics = record
    MappedFiles: QWord;
    ResidentPages: QWord;
  end;

procedure InitializeMappedFiles;

{ The mapped file of the file OpenedFile is open on (which must be open
  for reading), found in the registry or made, with a reference (a
  private one if IsPrivate). Returns 0 or an Abi error. Passive level. }
function AcquireMappedFile(OpenedFile: POpenFile; IsPrivate: Boolean; out MappedFile: PMappedFile): LongInt;
{ One more reference. Any level. }
procedure ReferenceMappedFile(MappedFile: PMappedFile; IsPrivate: Boolean);
{ Gives a reference back; the last one destroys it (at once at passive
  level, else at the next DrainMappedFileReleases). Any level. }
procedure ReleaseMappedFile(MappedFile: PMappedFile; IsPrivate: Boolean);
{ Destroys the mapped files whose last reference went at dispatch
  level. Passive level. }
procedure DrainMappedFileReleases;

{ The page PageIndex if it has been read (no reference is taken: it
  stays while the caller's reference to the mapped file does). Any
  level. }
function ResidentMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord;
  out Physical: TPhysicalAddress): Boolean;
{ Reads page PageIndex if it has not been read yet. Passive level. }
function LoadMappedFilePage(MappedFile: PMappedFile; PageIndex: QWord): LongInt;
{ Copies Length bytes at Offset of the file, through its pages (beyond
  its end: zeros). Passive level. }
function ReadMappedFileBytes(MappedFile: PMappedFile; Offset: QWord; Destination: Pointer;
  Length: QWord): LongInt;

procedure GetMappedFileStatistics(out Statistics: TMappedFileStatistics);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  FileSystem.Types,
  Kernel.Mutex,
  Kernel.PriorityLevel,
  Memory.PhysicalPages,
  Memory.KernelHeap;

var
  RegistryLock: TMutex;
  Registry: PMappedFile;
  PendingLock: TSpinLock;
  PendingReleases: PMappedFile;

{ --- Page table -------------------------------------------------------- }

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
begin
  ChunkIndex := PageIndex div MappedFileChunkPages;
  if MappedFile^.Chunks[ChunkIndex] <> nil then
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

{ Reads the file's page PageIndex into the page Physical (the part
  beyond the end of the file zeroed). }
function ReadPageContents(MappedFile: PMappedFile; PageIndex: QWord; Physical: TPhysicalAddress): LongInt;
var
  Offset: QWord;
  Wanted: QWord;
  BytesRead: QWord;
  Window: PByte;
begin
  Window := PByte(PhysicalToVirtual(Physical));
  Offset := PageIndex * PageSize;
  Wanted := 0;
  if Offset < MappedFile^.SizeInBytes then
  begin
    Wanted := MappedFile^.SizeInBytes - Offset;
    if Wanted > PageSize then
      Wanted := PageSize;
  end;
  BytesRead := 0;
  if (Wanted > 0) and (ReadFromFileAt(MappedFile^.OpenedFile, Offset, Window, Wanted, BytesRead) <> StatusSuccess) then
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
    Physical := Entry^;
  ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
  Result := Physical <> 0;
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
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Seen := MappedFile^.ChangeCount;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);

    Fresh := AllocatePhysicalPage(PageUsageProgramImage);
    if Fresh = 0 then
      Exit(ErrorOutOfMemory);
    Result := ReadPageContents(MappedFile, PageIndex, Fresh);
    if Result <> ErrorNone then
    begin
      FreePhysicalPage(Fresh);
      Exit;
    end;

    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Entry := EntryOf(MappedFile, PageIndex);
    { Read across a change of the file: maybe old contents; read again
      (a stale mapped file has all its pages and never changes). }
    Kept := (Entry^ = 0) and (MappedFile^.ChangeCount = Seen);
    if Kept then
    begin
      Entry^ := Fresh;
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
      Result := LoadMappedFilePage(MappedFile, PageIndex);
      if Result <> ErrorNone then
        Exit;
      ResidentMappedFilePage(MappedFile, PageIndex, Physical);
      CopyMemory(Target, PByte(PhysicalToVirtual(Physical)) + InPage, Piece);
    end;
    Target := Target + Piece;
    Offset := Offset + Piece;
    Length := Length - Piece;
  end;
  Result := ErrorNone;
end;

{ --- Lifetime ------------------------------------------------------------ }

procedure UnregisterLocked(MappedFile: PMappedFile); forward;

procedure Destroy(MappedFile: PMappedFile);
var
  ChunkIndex: QWord;
  Index: QWord;
  Chunk: PQWord;
begin
  AcquireMutex(RegistryLock);
  UnregisterLocked(MappedFile);
  ReleaseMutex(RegistryLock);

  for ChunkIndex := 1 to MappedFile^.ChunkCount do
  begin
    Chunk := MappedFile^.Chunks[ChunkIndex - 1];
    if Chunk = nil then
      Continue;
    for Index := 1 to MappedFileChunkPages do
      if Chunk[Index - 1] <> 0 then
        FreePhysicalPage(Chunk[Index - 1]);
    FreeKernelMemory(Chunk);
  end;
  FreeKernelMemory(MappedFile^.Chunks);
  CloseFile(MappedFile^.OpenedFile);
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
  if CurrentPriorityLevel = PassiveLevel then
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
  if PendingReleases = nil then
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

{ A live mapped file of (Volume, NodeNumber) with a reference taken, or
  nil. One whose last reference went (it is being destroyed) is not
  brought back. Caller holds RegistryLock. }
function FindRegisteredLocked(Volume: Pointer; NodeNumber: QWord; IsPrivate: Boolean): PMappedFile;
var
  PreviousLevel: TPriorityLevel;
  Alive: Boolean;
begin
  Result := Registry;
  while Result <> nil do
  begin
    if (Result^.Volume = Volume) and (Result^.NodeNumber = NodeNumber) then
    begin
      PreviousLevel := AcquireSpinLock(Result^.Lock);
      Alive := Result^.References > 0;
      if Alive then
      begin
        Inc(Result^.References);
        if IsPrivate then
          Inc(Result^.PrivateUsers);
      end;
      ReleaseSpinLock(Result^.Lock, PreviousLevel);
      if Alive then
        Exit;
    end;
    Result := Result^.Next;
  end;
end;

procedure UnregisterLocked(MappedFile: PMappedFile);
var
  Link: ^PMappedFile;
begin
  if not MappedFile^.IsRegistered then
    Exit;
  Link := @Registry;
  while (Link^ <> nil) and (Link^ <> MappedFile) do
    Link := @Link^^.Next;
  if Link^ = MappedFile then
    Link^ := MappedFile^.Next;
  MappedFile^.Next := nil;
  MappedFile^.IsRegistered := False;
end;

function CreateMappedFile(Duplicate: POpenFile; const Information: TNodeInformation;
  out MappedFile: PMappedFile): LongInt;
begin
  MappedFile := PMappedFile(AllocateZeroedKernelMemory(SizeOf(TMappedFile)));
  if MappedFile = nil then
    Exit(ErrorOutOfMemory);
  MappedFile^.Volume := Duplicate^.Volume;
  MappedFile^.NodeNumber := Information.NodeNumber;
  MappedFile^.OpenedFile := Duplicate;
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
  Result := ErrorNone;
end;

function AcquireMappedFile(OpenedFile: POpenFile; IsPrivate: Boolean; out MappedFile: PMappedFile): LongInt;
var
  Information: TNodeInformation;
  Duplicate: POpenFile;
  Existing: PMappedFile;
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

  AcquireMutex(RegistryLock);
  MappedFile := FindRegisteredLocked(OpenedFile^.Volume, Information.NodeNumber, IsPrivate);
  ReleaseMutex(RegistryLock);
  if MappedFile <> nil then
    Exit(ErrorNone);

  { The file system is not called with the registry's lock held (a file
    change takes them the other way round). }
  if DuplicateOpenFileForReading(OpenedFile, Duplicate) <> StatusSuccess then
    Exit(ErrorOutOfMemory);
  Result := CreateMappedFile(Duplicate, Information, MappedFile);
  if Result <> ErrorNone then
  begin
    CloseFile(Duplicate);
    Exit;
  end;
  MappedFile^.References := 1;
  if IsPrivate then
    MappedFile^.PrivateUsers := 1;

  AcquireMutex(RegistryLock);
  Existing := FindRegisteredLocked(OpenedFile^.Volume, Information.NodeNumber, IsPrivate);
  if Existing = nil then
  begin
    MappedFile^.Next := Registry;
    Registry := MappedFile;
    MappedFile^.IsRegistered := True;
  end;
  ReleaseMutex(RegistryLock);
  if Existing <> nil then
  begin
    { Made by someone else meanwhile. }
    Destroy(MappedFile);
    MappedFile := Existing;
  end;
  Result := ErrorNone;
end;

{ --- Changes of files ------------------------------------------------------- }

const
  ChangeBatch = 16;

type
  TChangeBatch = record
    Files: array[0..ChangeBatch - 1] of PMappedFile;
    Count: Integer;
  end;

{ The registered mapped files of a file, each with a reference. }
procedure CollectMappedFiles(Volume: Pointer; NodeNumber: QWord; out Batch: TChangeBatch);
var
  MappedFile: PMappedFile;
  PreviousLevel: TPriorityLevel;
begin
  Batch.Count := 0;
  AcquireMutex(RegistryLock);
  MappedFile := Registry;
  while (MappedFile <> nil) and (Batch.Count < ChangeBatch) do
  begin
    if (MappedFile^.Volume = Volume) and (MappedFile^.NodeNumber = NodeNumber) then
    begin
      PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
      if MappedFile^.References > 0 then
      begin
        Inc(MappedFile^.References);
        Batch.Files[Batch.Count] := MappedFile;
        Inc(Batch.Count);
      end;
      ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    end;
    MappedFile := MappedFile^.Next;
  end;
  ReleaseMutex(RegistryLock);
end;

procedure ReleaseBatch(const Batch: TChangeBatch);
var
  Index: Integer;
begin
  for Index := 0 to Batch.Count - 1 do
    ReleaseMappedFile(Batch.Files[Index], False);
end;

{ Before the file changes: private users keep the old contents. }
procedure FileChanging(Volume: PVolume; NodeNumber: QWord);
var
  Batch: TChangeBatch;
  Index: Integer;
  MappedFile: PMappedFile;
  PreviousLevel: TPriorityLevel;
  HasPrivateUsers: Boolean;
  PageIndex: QWord;
begin
  CollectMappedFiles(Volume, NodeNumber, Batch);
  for Index := 0 to Batch.Count - 1 do
  begin
    MappedFile := Batch.Files[Index];
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    HasPrivateUsers := MappedFile^.PrivateUsers > 0;
    if HasPrivateUsers then
      Inc(MappedFile^.ChangeCount);
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    if not HasPrivateUsers then
      Continue;
    { Every page now, before the change (the volume's lock is held, and
      taken again by the reads). }
    PageIndex := 0;
    while PageIndex < MappedFile^.PageCount do
    begin
      LoadMappedFilePage(MappedFile, PageIndex);
      Inc(PageIndex);
    end;
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    MappedFile^.IsStale := True;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    AcquireMutex(RegistryLock);
    UnregisterLocked(MappedFile);
    ReleaseMutex(RegistryLock);
  end;
  ReleaseBatch(Batch);
end;

{ After the change: shared mappings see the new contents. }
procedure FileChanged(Volume: PVolume; NodeNumber: QWord; Offset, Length: QWord);
var
  Batch: TChangeBatch;
  Index: Integer;
  MappedFile: PMappedFile;
  PreviousLevel: TPriorityLevel;
  Information: TNodeInformation;
  FirstPage: QWord;
  LastPage: QWord;
  PageIndex: QWord;
  Physical: TPhysicalAddress;
begin
  CollectMappedFiles(Volume, NodeNumber, Batch);
  for Index := 0 to Batch.Count - 1 do
  begin
    MappedFile := Batch.Files[Index];
    GetFileInformation(MappedFile^.OpenedFile, Information);
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Inc(MappedFile^.ChangeCount);
    MappedFile^.SizeInBytes := Information.SizeInBytes;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);

    FirstPage := Offset div PageSize;
    if (Length = FileChangeToEnd) or (Offset + Length < Offset) then
      LastPage := MappedFile^.PageCount
    else
      LastPage := (Offset + Length + PageSize - 1) div PageSize;
    if LastPage > MappedFile^.PageCount then
      LastPage := MappedFile^.PageCount;
    PageIndex := FirstPage;
    while PageIndex < LastPage do
    begin
      if ResidentMappedFilePage(MappedFile, PageIndex, Physical) then
        ReadPageContents(MappedFile, PageIndex, Physical);
      Inc(PageIndex);
    end;
  end;
  ReleaseBatch(Batch);
end;

procedure GetMappedFileStatistics(out Statistics: TMappedFileStatistics);
var
  MappedFile: PMappedFile;
begin
  Statistics.MappedFiles := 0;
  Statistics.ResidentPages := 0;
  AcquireMutex(RegistryLock);
  MappedFile := Registry;
  while MappedFile <> nil do
  begin
    Inc(Statistics.MappedFiles);
    Statistics.ResidentPages := Statistics.ResidentPages + MappedFile^.ResidentPages;
    MappedFile := MappedFile^.Next;
  end;
  ReleaseMutex(RegistryLock);
end;

procedure InitializeMappedFiles;
begin
  InitializeMutex(RegistryLock);
  InitializeSpinLock(PendingLock);
  Registry := nil;
  PendingReleases := nil;
  AddFileChangingHook(@FileChanging);
  AddFileChangedHook(@FileChanged);
end;

end.
