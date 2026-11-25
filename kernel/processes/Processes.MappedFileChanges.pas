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
  Mapped files and the file system (Processes.MappedFiles): what keeps
  their pages and the file agreeing.

    * Before a change (TFileChangingHook, volume lock held, with the
      range about to change): a private mapped file with users becomes
      a snapshot, and every snapshot of the file reads the pages of the
      range it does not hold yet and marks them preserved - only those
      pages, so writing a few bytes of a large file costs a page or two,
      not the file.
    * After a change (TFileWrittenHook, the lock still held): the
      resident pages of the mapped files that are not snapshots get the
      changed bytes read into them, only those bytes, so what a shared
      writable mapping wrote elsewhere in the page stays. A mapped
      file's own write-back is not read back into it (its pages may
      have been written again meanwhile).
    * read() (TResidentFileReader): copies what lies in resident pages
      of the file's shared mapped file (or a private one that is not a
      snapshot) instead of reading it through the file system: the
      pages may hold what a mapping wrote and nobody wrote back yet,
      and a page in memory twice is read from neither disk nor cache.
    * Writing back: before a volume is written back (sync, TVolumeSync
      hook), after a writable mapping went (FlushPendingMappedFileWrite
      Backs) and, on the block cache's background writer, once pages
      have been dirty for DirtyPageLifetimeMilliseconds. Mapped files
      whose last reference went where they could not be destroyed are
      destroyed there too.
}
unit Processes.MappedFileChanges;

{$mode objfpc}
{$pointermath on}

interface

const
  DirtyPageLifetimeMilliseconds = 5000;

procedure InitializeMappedFileChanges;
{ Writes back the dirty pages of the mapped files a writable mapping of
  which went. Passive level. }
procedure FlushPendingMappedFileWriteBacks;
{ Writes back every dirty page of the mapped files of Volume (nil:
  every volume). Passive level. }
procedure WriteBackMappedFilesOf(Volume: Pointer);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Scheduler,
  Kernel.Clock,
  Memory.Pressure,
  Io.BlockCache,
  FileSystem.Types,
  FileSystem.Files,
  Processes.MappedFiles,
  Processes.MappedFileRanges;

{ --- Before a change: snapshots keep the range ----------------------------- }

{ Reads and keeps the pages of the range a snapshot does not hold yet. }
procedure PreserveRange(MappedFile: PMappedFile; Offset, Length: QWord);
var
  FirstPage: QWord;
  EndPage: QWord;
  PageIndex: QWord;
  Physical: TPhysicalAddress;
  WasResident: Boolean;
  PreviousLevel: TPriorityLevel;
begin
  if not ChangedPageSpan(Offset, Length, MappedFile^.PageCount, FirstPage, EndPage) then
    Exit;
  PageIndex := FirstPage;
  while PageIndex < EndPage do
  begin
    WasResident := ResidentMappedFilePage(MappedFile, PageIndex, Physical);
    if not WasResident and (LoadMappedFilePage(MappedFile, PageIndex) <> ErrorNone) then
    begin
      { The page's old contents are lost for good. }
      PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
      MappedFile^.IsDamaged := True;
      ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
      Exit;
    end;
    if not WasResident then
      Inc(MappedSnapshotPagesRead);
    MarkMappedFilePagePreserved(MappedFile, PageIndex);
    Inc(PageIndex);
  end;
end;

procedure FileChanging(Volume: PVolume; NodeNumber: QWord; Offset, Length: QWord);
var
  Files: PPMappedFile;
  Count: Integer;
  Index: Integer;
  MappedFile: PMappedFile;
  PreviousLevel: TPriorityLevel;
  IsSnapshot: Boolean;
begin
  if not ListMappedFiles(Volume, NodeNumber, False, Files, Count) then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    MappedFile := Files[Index];
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Inc(MappedFile^.ChangeCount);
    if MappedFile^.HoldsPrivate and not MappedFile^.IsStale and (MappedFile^.PrivateUsers > 0) then
      MappedFile^.IsStale := True;
    IsSnapshot := MappedFile^.IsStale;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    if IsSnapshot then
      PreserveRange(MappedFile, Offset, Length);
  end;
  FreeMappedFileList(Files, Count);
end;

{ --- After a change: resident pages get the new bytes ------------------------ }

{ Reads bytes [Start, Finish) of page PageIndex from the file into the
  page Physical (zeros past the file's end). }
procedure RefreshPageBytes(MappedFile: PMappedFile; PageIndex: QWord; Physical: TPhysicalAddress;
  Start, Finish: QWord);
var
  Window: PByte;
  BytesRead: QWord;
  Offset: QWord;
begin
  Window := PByte(PhysicalToVirtual(Physical)) + Start;
  Offset := PageIndex * PageSize + Start;
  BytesRead := 0;
  if Offset < MappedFile^.SizeInBytes then
    ReadFromFileAt(MappedFile^.OpenedFile, Offset, Window, Finish - Start, BytesRead);
  if BytesRead < Finish - Start then
    ZeroMemory(Window + BytesRead, Finish - Start - BytesRead);
end;

procedure FileWritten(Volume: PVolume; NodeNumber: QWord; Offset, Length: QWord);
var
  Files: PPMappedFile;
  Count: Integer;
  Index: Integer;
  MappedFile: PMappedFile;
  PreviousLevel: TPriorityLevel;
  Skip: Boolean;
  FirstPage: QWord;
  EndPage: QWord;
  PageIndex: QWord;
  Start: QWord;
  Finish: QWord;
  Physical: TPhysicalAddress;
begin
  if not ListMappedFiles(Volume, NodeNumber, False, Files, Count) then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    MappedFile := Files[Index];
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Skip := MappedFile^.IsStale;
    if not Skip then
    begin
      Inc(MappedFile^.ChangeCount);
      { The volume's lock is held: the node's size is current. }
      MappedFile^.SizeInBytes := MappedFile^.OpenedFile^.Node^.Information.SizeInBytes;
      Skip := MappedFile^.WriteBackThread = Pointer(CurrentThread);
    end;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    if Skip or not ChangedPageSpan(Offset, Length, MappedFile^.PageCount, FirstPage, EndPage) then
      Continue;
    PageIndex := FirstPage;
    while PageIndex < EndPage do
    begin
      if AcquireResidentMappedFilePage(MappedFile, PageIndex, Physical) then
      begin
        ChangedBytesInPage(PageIndex, Offset, Length, Start, Finish);
        if Finish > Start then
          RefreshPageBytes(MappedFile, PageIndex, Physical, Start, Finish);
        FreePhysicalPage(Physical);
      end;
      Inc(PageIndex);
    end;
  end;
  FreeMappedFileList(Files, Count);
end;

{ --- read() from resident pages ---------------------------------------------- }

procedure ReadResidentBytes(Volume: PVolume; Node: PNode; Offset: QWord; Buffer: Pointer;
  ByteCount: QWord; out Copied, Gap: QWord);
var
  MappedFile: PMappedFile;
  Size: QWord;
  Target: PByte;
  PageIndex: QWord;
  InPage: QWord;
  Piece: QWord;
  Physical: TPhysicalAddress;
begin
  Copied := 0;
  Gap := ByteCount;
  Size := Node^.Information.SizeInBytes;
  if Offset >= Size then
    Exit;
  if ByteCount > Size - Offset then
    ByteCount := Size - Offset;
  MappedFile := FindMappedFileForReading(Volume, Node^.Information.NodeNumber);
  if MappedFile = nil then
    Exit;
  Target := PByte(Buffer);
  { The resident pages from Offset on. }
  while Copied < ByteCount do
  begin
    PageIndex := (Offset + Copied) div PageSize;
    InPage := (Offset + Copied) mod PageSize;
    Piece := PageSize - InPage;
    if Piece > ByteCount - Copied then
      Piece := ByteCount - Copied;
    if not AcquireResidentMappedFilePage(MappedFile, PageIndex, Physical) then
      Break;
    CopyMemory(Target + Copied, PByte(PhysicalToVirtual(Physical)) + InPage, Piece);
    FreePhysicalPage(Physical);
    Copied := Copied + Piece;
  end;
  { Then the pages not in memory, up to the next one that is. }
  Gap := 0;
  while Copied + Gap < ByteCount do
  begin
    PageIndex := (Offset + Copied + Gap) div PageSize;
    if ResidentMappedFilePage(MappedFile, PageIndex, Physical) then
      Break;
    Piece := PageSize - (Offset + Copied + Gap) mod PageSize;
    if Piece > ByteCount - Copied - Gap then
      Piece := ByteCount - Copied - Gap;
    Gap := Gap + Piece;
  end;
  MappedBytesReadFromPages := MappedBytesReadFromPages + Copied;
  ReleaseMappedFile(MappedFile, False);
end;

{ --- Writing back ------------------------------------------------------------- }

type
  TWriteBackChoice = (WriteBackAll, WriteBackPending, WriteBackAged);

procedure WriteBackChosen(Volume: Pointer; Choice: TWriteBackChoice);
var
  Files: PPMappedFile;
  Count: Integer;
  Index: Integer;
  MappedFile: PMappedFile;
  PreviousLevel: TPriorityLevel;
  Wanted: Boolean;
  Now: QWord;
begin
  if not ListMappedFiles(Volume, 0, True, Files, Count) then
    Exit;
  Now := UptimeMilliseconds;
  for Index := 0 to Count - 1 do
  begin
    MappedFile := Files[Index];
    PreviousLevel := AcquireSpinLock(MappedFile^.Lock);
    Wanted := MappedFile^.DirtyPages > 0;
    case Choice of
      WriteBackPending:
        Wanted := Wanted and MappedFile^.WriteBackPending;
      WriteBackAged:
        Wanted := Wanted and (MappedFile^.WriteBackPending or
          (Now - MappedFile^.DirtySince >= DirtyPageLifetimeMilliseconds));
    end;
    if Wanted then
      MappedFile^.WriteBackPending := False;
    ReleaseSpinLock(MappedFile^.Lock, PreviousLevel);
    if Wanted then
      WriteBackMappedFile(MappedFile, 0, MappedFile^.PageCount);
  end;
  FreeMappedFileList(Files, Count);
end;

procedure FlushPendingMappedFileWriteBacks;
begin
  { Not at dispatch level, not on the thread reclaiming memory. }
  if not CanReclaimMemoryHere then
    Exit;
  DrainMappedFileReleases;
  if not MappedFileWriteBackRequested then
    Exit;
  MappedFileWriteBackRequested := False;
  WriteBackChosen(nil, WriteBackPending);
end;

procedure WriteBackMappedFilesOf(Volume: Pointer);
begin
  WriteBackChosen(Volume, WriteBackAll);
end;

procedure VolumeSyncing(Volume: PVolume);
begin
  WriteBackMappedFilesOf(Volume);
end;

{ Each round of the block cache's background writer. }
procedure BackgroundRound;
begin
  DrainMappedFileReleases;
  WriteBackChosen(nil, WriteBackAged);
end;

procedure InitializeMappedFileChanges;
begin
  AddFileChangingHook(@FileChanging);
  AddFileWrittenHook(@FileWritten);
  AddVolumeSyncHook(@VolumeSyncing);
  SetResidentFileReader(@ReadResidentBytes);
  RegisterCacheWriterTask(@BackgroundRound);
end;

end.
