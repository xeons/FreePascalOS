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
  Image sections: program and library images shared between processes.

  Loading the same program or library in every process used to mean
  reading its file and copying all its pages each time. An image section
  is the file read once - its bytes, for the loader's headers and tables,
  and its memory image laid out in physical pages - and kept here, keyed
  by path. A process maps the section's pages instead of copies: read-only
  pages are shared outright, writable ones copy on write
  (Processes.AddressSpace), so relocations and program writes give each
  process its own copies of only the pages they touch.

  A section stays valid while its file does not change: the file system
  reports every write to a file (SetFileChangedHook), which drops the
  file's sections, and the identity (volume, node number, size,
  modification time) is also compared on every lookup. A section still
  being loaded from when its file changes is marked stale and goes when
  that load is done. Up to MaximumSections are
  kept; when the table is full, the least recently used one that is not
  being loaded right now goes. Pages mapped in processes hold references
  of their own, so dropping a section never takes pages from under a
  process.

  The cache knows nothing about ELF: the loader (Processes.ImageLoader)
  creates a section with the page span it measured and fills the pages.
}
unit Processes.ImageSections;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.Time,
  Memory.Layout;

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
    { The whole file. }
    Contents: PByte;
    Size: QWord;
    { The memory image: PageCount pages from virtual address LowestPage
      (as linked), each holding a reference. }
    LowestPage: QWord;
    PageCount: QWord;
    Pages: PQWord;
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
{ Makes a section for KernelPath taking over Contents (kernel memory of
  Size bytes), with PageCount zeroed pages for its memory image, and
  counts a use. Returns nil if memory is short (Contents is then freed).
  Nobody else finds it until it is published, once its pages are filled. }
function CreateImageSection(KernelPath: PChar; const Identity: TImageIdentity; Contents: PByte;
  Size: QWord; LowestPage, PageCount: QWord): PImageSection;
{ Makes a filled section available to later loads. }
procedure PublishImageSection(Section: PImageSection);
{ A kernel pointer to page Index of the section's memory image. }
function SectionPage(Section: PImageSection; Index: QWord): PByte;
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

procedure InitializeImageSections;
begin
  InitializeMutex(SectionsLock);
  AddFileChangedHook(@FileChanged);
end;

procedure DestroySection(Section: PImageSection);
var
  Index: QWord;
begin
  if Section^.Pages <> nil then
  begin
    for Index := 1 to Section^.PageCount do
      if Section^.Pages[Index - 1] <> 0 then
        FreePhysicalPage(Section^.Pages[Index - 1]);
    FreeKernelMemory(Section^.Pages);
  end;
  FreeKernelMemory(Section^.Contents);
  FreeKernelMemory(Section);
end;

function IdentitiesMatch(const Left, Right: TImageIdentity): Boolean;
begin
  Result := (Left.Volume = Right.Volume) and (Left.NodeNumber = Right.NodeNumber) and
    (Left.SizeInBytes = Right.SizeInBytes) and (Left.ModificationTime = Right.ModificationTime);
end;

{ Takes the section in slot Index out of the table: destroyed now if
  nobody uses it, else marked stale and destroyed by its last release. }
procedure DropSlotLocked(Index: Integer);
begin
  if Sections[Index] = nil then
    Exit;
  if Sections[Index]^.Users > 0 then
    Sections[Index]^.IsStale := True
  else
    DestroySection(Sections[Index]);
  Sections[Index] := nil;
end;

procedure FileChanged(Volume: PVolume; NodeNumber: QWord; Offset, Length: QWord);
var
  Index: Integer;
begin
  AcquireMutex(SectionsLock);
  for Index := 0 to MaximumSections - 1 do
    if (Sections[Index] <> nil) and (Sections[Index]^.Identity.Volume = Pointer(Volume)) and
       (Sections[Index]^.Identity.NodeNumber = NodeNumber) then
      DropSlotLocked(Index);
  ReleaseMutex(SectionsLock);
end;

function FindImageSection(KernelPath: PChar; const Identity: TImageIdentity): PImageSection;
var
  Index: Integer;
begin
  Result := nil;
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
      DropSlotLocked(Index);
    Break;
  end;
  ReleaseMutex(SectionsLock);
end;

{ A free slot, making one by dropping the least recently used section
  nobody uses; -1 if every section is in use. }
function FreeSlotLocked: Integer;
var
  Index: Integer;
  Oldest: Integer;
begin
  Oldest := -1;
  for Index := 0 to MaximumSections - 1 do
  begin
    if Sections[Index] = nil then
      Exit(Index);
    if (Sections[Index]^.Users = 0) and
       ((Oldest < 0) or (Sections[Index]^.LastUse < Sections[Oldest]^.LastUse)) then
      Oldest := Index;
  end;
  if Oldest >= 0 then
    DropSlotLocked(Oldest); { unused, so destroyed }
  Result := Oldest;
end;

function CreateImageSection(KernelPath: PChar; const Identity: TImageIdentity; Contents: PByte;
  Size: QWord; LowestPage, PageCount: QWord): PImageSection;
var
  Index: QWord;
begin
  Result := PImageSection(AllocateZeroedKernelMemory(SizeOf(TImageSection)));
  if Result = nil then
  begin
    FreeKernelMemory(Contents);
    Exit;
  end;
  CopyText(@Result^.Path[0], KernelPath, SectionPathLength);
  Result^.Identity := Identity;
  Result^.Contents := Contents;
  Result^.Size := Size;
  Result^.LowestPage := LowestPage;
  Result^.PageCount := PageCount;
  Result^.Users := 1;
  Result^.LastUse := ClockTickCount;
  Result^.Pages := PQWord(AllocateZeroedKernelMemory(PageCount * SizeOf(QWord)));
  if Result^.Pages = nil then
  begin
    DestroySection(Result);
    Exit(nil);
  end;
  for Index := 1 to PageCount do
  begin
    Result^.Pages[Index - 1] := AllocateZeroedPhysicalPage(PageUsageProgramImage);
    if Result^.Pages[Index - 1] = 0 then
    begin
      DestroySection(Result);
      Exit(nil);
    end;
  end;

end;

procedure PublishImageSection(Section: PImageSection);
var
  Slot: Integer;
begin
  { Kept if there is room; otherwise it serves this load only and goes
    when the load releases it. }
  AcquireMutex(SectionsLock);
  Slot := FreeSlotLocked;
  if Slot >= 0 then
    Sections[Slot] := Section;
  ReleaseMutex(SectionsLock);
end;

function SectionPage(Section: PImageSection; Index: QWord): PByte;
begin
  Result := PByte(PhysicalToVirtual(Section^.Pages[Index]));
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
