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
  Image sections: what the loader keeps of a program or library file
  between loads, keyed by path.

  The file's contents are not copied: a section refers to the file's
  mapped file (Processes.MappedFiles, with a private reference, so a
  write to the file never changes a running program), whose pages every
  process running the program maps - read-only ones shared outright,
  writable ones copy on write - each page read from the file only when
  some process first touches it. The section keeps what the loader
  needs again: the ELF header and program headers, the span of the
  memory image, and the few pages no page of the file can stand for
  (where two segments share a page, or a segment's file data ends
  inside a page whose rest must be zero): those are built once, here,
  and mapped copy on write like the file's pages
  (Processes.ImageLoader decides which pages they are).

  A section stays valid while its file does not change: the file system
  reports every write to a file (AddFileChangedHook), which drops the
  file's sections, and the identity (volume, node number, size,
  modification time) is also compared on every lookup. A section still
  in use when its file changes is marked stale and goes when that use
  ends.

  A section keeps its file open (through the mapped file), so it must
  not outlive the file's last name: when a file is removed, or replaced
  by a rename onto its name (AddFileRemovedHook), its sections are
  dropped the same way, and a section whose file lost its name while it
  was being built is never kept. The file system then frees the file
  once the processes still mapping it (a running program whose file was
  replaced, a library still loaded) let their mappings go. Up to MaximumSections are kept; when the table is full, the
  least recently used one that is not in use goes. Processes hold
  references of their own to every page they map and to the mapped
  file, so dropping a section never takes anything from under them.

  The cache knows nothing about ELF beyond the records it keeps: the
  loader measures, checks and fills.
}
unit Processes.ImageSections;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.Time,
  Elf64,
  Memory.Layout,
  Processes.MappedFiles;

const
  MaximumSections = 32;
  SectionPathLength = 256;

type
  TImageIdentity = record
    Volume: Pointer;
    NodeNumber: QWord;
    SizeInBytes: QWord;
    ModificationTime: TUnixTime;
  end;

  PImageSection = ^TImageSection;
  TImageSection = record
    Path: array[0..SectionPathLength - 1] of Char;
    Identity: TImageIdentity;
    { The file's pages (a private reference). }
    MappedFile: PMappedFile;
    Header: TElf64FileHeader;
    { ProgramHeaderCount records (Header's count), in kernel memory. }
    ProgramHeaders: PElf64ProgramHeader;
    { The memory image: PageCount pages from virtual address LowestPage
      (as linked). }
    LowestPage: QWord;
    PageCount: QWord;
    { For each page of the memory image, the page built here (with a
      reference), or 0 where the file's page or a zero filled one does. }
    BuiltPages: PQWord;
    { Loads using it right now; it is not dropped while this is not 0. }
    Users: LongInt;
    { Its file changed while it was in use; not handed out any more. }
    IsStale: Boolean;
    LastUse: QWord;
  end;

procedure InitializeImageSections;

{ The section of KernelPath if one with the same identity exists, with
  a use counted; else nil. }
function FindImageSection(KernelPath: PChar; const Identity: TImageIdentity): PImageSection;
{ Makes a section for KernelPath taking over MappedFile's private
  reference and ProgramHeaders (kernel memory), and counts a use.
  Returns nil if memory is short (both are given back then). Nobody else
  finds it until it is published, once its built pages are made. }
function CreateImageSection(KernelPath: PChar; const Identity: TImageIdentity; MappedFile: PMappedFile;
  const Header: TElf64FileHeader; ProgramHeaders: PElf64ProgramHeader;
  LowestPage, PageCount: QWord): PImageSection;
{ Makes a filled section available to later loads. }
procedure PublishImageSection(Section: PImageSection);
{ Ends a use. }
procedure ReleaseImageSection(Section: PImageSection);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  FileSystem.Types,
  FileSystem.Files,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Clock;

var
  Sections: array[0..MaximumSections - 1] of PImageSection;
  SectionsLock: TMutex;

procedure FileChanged(Volume: PVolume; NodeNumber: QWord; Offset, Length: QWord); forward;
procedure FileRemoved(Volume: PVolume; NodeNumber: QWord); forward;

procedure InitializeImageSections;
begin
  InitializeMutex(SectionsLock);
  AddFileChangedHook(@FileChanged);
  AddFileRemovedHook(@FileRemoved);
end;

procedure DestroySection(Section: PImageSection);
var
  Index: QWord;
begin
  if Section^.BuiltPages <> nil then
  begin
    for Index := 1 to Section^.PageCount do
      if Section^.BuiltPages[Index - 1] <> 0 then
        FreePhysicalPage(Section^.BuiltPages[Index - 1]);
    FreeKernelMemory(Section^.BuiltPages);
  end;
  FreeKernelMemory(Section^.ProgramHeaders);
  ReleaseMappedFile(Section^.MappedFile, True);
  FreeKernelMemory(Section);
end;

function IdentitiesMatch(const Left, Right: TImageIdentity): Boolean;
begin
  Result := (Left.Volume = Right.Volume) and (Left.NodeNumber = Right.NodeNumber) and
    (Left.SizeInBytes = Right.SizeInBytes) and (Left.ModificationTime = Right.ModificationTime);
end;

{ Takes the section in slot Index out of the table: returned for the
  caller to destroy once it let go of the lock (that closes the file) if
  nobody uses it, else marked stale and destroyed by its last release
  (nil returned). }
function DropSlotLocked(Index: Integer): PImageSection;
begin
  Result := nil;
  if Sections[Index] = nil then
    Exit;
  if Sections[Index]^.Users > 0 then
    Sections[Index]^.IsStale := True
  else
    Result := Sections[Index];
  Sections[Index] := nil;
end;

procedure FileChanged(Volume: PVolume; NodeNumber: QWord; Offset, Length: QWord);
var
  Index: Integer;
  Unused: array[0..MaximumSections - 1] of PImageSection;
begin
  FillMemory(@Unused, SizeOf(Unused), 0);
  AcquireMutex(SectionsLock);
  for Index := 0 to MaximumSections - 1 do
    if (Sections[Index] <> nil) and (Sections[Index]^.Identity.Volume = Pointer(Volume)) and
       (Sections[Index]^.Identity.NodeNumber = NodeNumber) then
      Unused[Index] := DropSlotLocked(Index);
  ReleaseMutex(SectionsLock);
  for Index := 0 to MaximumSections - 1 do
    if Unused[Index] <> nil then
      DestroySection(Unused[Index]);
end;

{ The file of a section lost a name. Unused sections are destroyed
  after the lock is let go: that closes the file, which may free it. }
procedure FileRemoved(Volume: PVolume; NodeNumber: QWord);
var
  Index: Integer;
  Unused: array[0..MaximumSections - 1] of PImageSection;
  UnusedCount: Integer;
begin
  UnusedCount := 0;
  AcquireMutex(SectionsLock);
  for Index := 0 to MaximumSections - 1 do
    if (Sections[Index] <> nil) and (Sections[Index]^.Identity.Volume = Pointer(Volume)) and
       (Sections[Index]^.Identity.NodeNumber = NodeNumber) then
    begin
      if Sections[Index]^.Users > 0 then
        Sections[Index]^.IsStale := True
      else
      begin
        Unused[UnusedCount] := Sections[Index];
        Inc(UnusedCount);
      end;
      Sections[Index] := nil;
    end;
  ReleaseMutex(SectionsLock);
  for Index := 0 to UnusedCount - 1 do
    DestroySection(Unused[Index]);
end;

function FindImageSection(KernelPath: PChar; const Identity: TImageIdentity): PImageSection;
var
  Index: Integer;
  Dropped: PImageSection;
begin
  Result := nil;
  Dropped := nil;
  AcquireMutex(SectionsLock);
  for Index := 0 to MaximumSections - 1 do
  begin
    if (Sections[Index] = nil) or not TextIsEqual(@Sections[Index]^.Path[0], KernelPath) then
      Continue;
    if IdentitiesMatch(Sections[Index]^.Identity, Identity) then
    begin
      Result := Sections[Index];
      Inc(Result^.Users);
      Result^.LastUse := ClockTickCount;
    end
    else
      { The file changed: its old section is of no use any more. }
      Dropped := DropSlotLocked(Index);
    Break;
  end;
  ReleaseMutex(SectionsLock);
  if Dropped <> nil then
    DestroySection(Dropped);
end;

{ A free slot, making one by dropping the least recently used section
  nobody uses (Dropped, for the caller to destroy after the lock); -1 if
  every section is in use. }
function FreeSlotLocked(out Dropped: PImageSection): Integer;
var
  Index: Integer;
  Oldest: Integer;
begin
  Oldest := -1;
  Dropped := nil;
  for Index := 0 to MaximumSections - 1 do
  begin
    if Sections[Index] = nil then
      Exit(Index);
    if (Sections[Index]^.Users = 0) and
       ((Oldest < 0) or (Sections[Index]^.LastUse < Sections[Oldest]^.LastUse)) then
      Oldest := Index;
  end;
  if Oldest >= 0 then
    Dropped := DropSlotLocked(Oldest); { unused, so destroyed }
  Result := Oldest;
end;

function CreateImageSection(KernelPath: PChar; const Identity: TImageIdentity; MappedFile: PMappedFile;
  const Header: TElf64FileHeader; ProgramHeaders: PElf64ProgramHeader;
  LowestPage, PageCount: QWord): PImageSection;
begin
  Result := PImageSection(AllocateZeroedKernelMemory(SizeOf(TImageSection)));
  if Result = nil then
  begin
    FreeKernelMemory(ProgramHeaders);
    ReleaseMappedFile(MappedFile, True);
    Exit;
  end;
  CopyText(@Result^.Path[0], KernelPath, SectionPathLength);
  Result^.Identity := Identity;
  Result^.MappedFile := MappedFile;
  Result^.Header := Header;
  Result^.ProgramHeaders := ProgramHeaders;
  Result^.LowestPage := LowestPage;
  Result^.PageCount := PageCount;
  Result^.Users := 1;
  Result^.LastUse := ClockTickCount;
  Result^.BuiltPages := PQWord(AllocateZeroedKernelMemory(PageCount * SizeOf(QWord)));
  if Result^.BuiltPages = nil then
  begin
    DestroySection(Result);
    Exit(nil);
  end;
end;

procedure PublishImageSection(Section: PImageSection);
var
  Slot: Integer;
  Dropped: PImageSection;
begin
  Dropped := nil;
  { Kept if there is room; otherwise it serves this load only and goes
    when the load releases it. }
  AcquireMutex(SectionsLock);
  { A file removed while its section was built: FileRemoved came too
    early to see the section, and keeping it would keep the file. Its
    removal is recorded before FileRemoved takes the lock, so one of
    the two always sees the other. }
  if FileWasRemoved(Section^.MappedFile^.OpenedFile) then
    Slot := -1
  else
    Slot := FreeSlotLocked(Dropped);
  if Slot >= 0 then
    Sections[Slot] := Section;
  ReleaseMutex(SectionsLock);
  if Dropped <> nil then
    DestroySection(Dropped);
end;

{ True if Section is in the table. }
function IsCachedLocked(Section: PImageSection): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to MaximumSections - 1 do
    if Sections[Index] = Section then
      Exit(True);
  Result := False;
end;

procedure ReleaseImageSection(Section: PImageSection);
var
  Uncached: Boolean;
begin
  if Section = nil then
    Exit;
  AcquireMutex(SectionsLock);
  Dec(Section^.Users);
  Uncached := (Section^.Users = 0) and not IsCachedLocked(Section);
  ReleaseMutex(SectionsLock);
  if Uncached then
    DestroySection(Section);
end;

end.
