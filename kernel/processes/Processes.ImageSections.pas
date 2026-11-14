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

  A section stays valid while its file does not change: the identity
  (node number, size, modification time) is compared on every lookup,
  and a changed file gets a fresh section. Up to MaximumSections are
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
    LastUse: QWord;
  end;

procedure InitializeImageSections;

{ The section of KernelPath if one with the same identity exists, with
  a use counted; else nil. }
function FindImageSection(KernelPath: PChar; const Identity: TImageIdentity): PImageSection;
{ Makes a section for KernelPath taking over Contents (kernel memory of
  Size bytes), with PageCount zeroed pages for its memory image, and
  counts a use. Returns nil if memory is short (Contents is then freed). }
function CreateImageSection(KernelPath: PChar; const Identity: TImageIdentity; Contents: PByte;
  Size: QWord; LowestPage, PageCount: QWord): PImageSection;
{ A kernel pointer to page Index of the section's memory image. }
function SectionPage(Section: PImageSection; Index: QWord): PByte;
{ Ends a use. }
procedure ReleaseImageSection(Section: PImageSection);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Clock;

var
  Sections: array[0..MaximumSections - 1] of PImageSection;
  SectionsLock: TMutex;

procedure InitializeImageSections;
begin
  InitializeMutex(SectionsLock);
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
  Result := (Left.NodeNumber = Right.NodeNumber) and (Left.SizeInBytes = Right.SizeInBytes) and
    (Left.ModificationTime = Right.ModificationTime);
end;

{ Drops the section in slot Index if nobody uses it. }
procedure DropSlotLocked(Index: Integer);
begin
  if (Sections[Index] = nil) or (Sections[Index]^.Users > 0) then
    Exit;
  DestroySection(Sections[Index]);
  Sections[Index] := nil;
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
    DropSlotLocked(Oldest);
  Result := Oldest;
end;

function CreateImageSection(KernelPath: PChar; const Identity: TImageIdentity; Contents: PByte;
  Size: QWord; LowestPage, PageCount: QWord): PImageSection;
var
  Index: QWord;
  Slot: Integer;
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
    Result^.Pages[Index - 1] := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if Result^.Pages[Index - 1] = 0 then
    begin
      DestroySection(Result);
      Exit(nil);
    end;
  end;

  { Kept if there is room; otherwise it serves this load only and goes
    when the load releases it. }
  AcquireMutex(SectionsLock);
  Slot := FreeSlotLocked;
  if Slot >= 0 then
    Sections[Slot] := Result;
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
