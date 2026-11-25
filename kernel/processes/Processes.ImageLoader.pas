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
  Program and shared library loader.

  Programs and libraries are ELF files produced by an ordinary toolchain:
  position independent executables and shared objects with a dynamic
  section listing the libraries they need (DT_NEEDED), their symbols and
  their relocations. Loading a program means:

    1. Map the program's loadable segments into the process, from the
       file's mapped pages (Processes.MappedFiles): read-only pages are
       shared by every process that maps the file, writable ones copy on
       write, and a page is read from the file only when some process
       first touches it. The few pages no file page stands for (two
       segments in one page, the end of a segment's file data inside a
       page whose rest is bss) are built once and kept in the image's
       section (Processes.ImageSections) with its headers; pages of bss
       alone are zero filled on demand.
    2. For every needed library not loaded yet, find it in /lib of the
       system volume and map it at a random free place of the library
       window (Processes.AddressLayout; with aslr=off, at the next free
       library address); repeat for its own needs.
    3. Apply every relocation of every newly loaded module. Symbols are
       looked up in load order (the program first, then libraries in the
       order they were loaded), the same "global scope" rule a Unix
       dynamic linker uses. All symbols are bound immediately.

  LoadLibraryImage does steps 2 and 3 for a library requested at run time
  (dlopen), and FindExportedSymbol looks a symbol up in it (dlsym).

  Thread-local storage (PT_TLS) of the program and of the libraries
  loaded with it uses the static model: their TLS blocks sit at fixed
  offsets from each thread's thread pointer, in load order (the
  program's block nearest to it, as the linker expects) - below it on
  x86-64 (variant II), above it on AArch64 (variant I);
  Processes.Arch.ImageFormat has the layout and the relocation numbers
  of the processor. Processes.ThreadStorage builds each thread's copy of
  the blocks. The "module id" of such a module (DTPMOD64) is its offset
  from the thread pointer, so __tls_get_addr in libsystem simply adds
  the thread pointer, that offset and the variable's offset; a TLS
  descriptor (AArch64) gets libsystem's static resolver and the
  variable's offset from the thread pointer.

  The static layout is fixed once the program is loaded, but it ends in
  a surplus (StaticTlsSurplusBytes, reserved when the program is
  loaded): a library loaded later whose TLS must be at a fixed distance
  from the thread pointer - one marked DF_STATIC_TLS or with initial or
  local exec accesses (TPOFF relocations) of its own - gets its block
  there, if it fits, and every thread there is gets the block's initial
  contents when the load succeeds (threads made later get them as for
  any static block). Any other library with a TLS segment loaded after
  that (LoadLibraryImage) gets dynamic TLS instead: its module id is TlsDynamicModuleTag plus its module
  handle, a TLS descriptor gets libsystem's dynamic resolver (and the
  tag, the handle and the offset as its argument), and the user runtime
  makes each thread's block the first time the thread touches it, from
  what CallGetModuleTls says (Processes.ModuleCalls). Initial and local
  exec accesses (TPOFF relocations) cannot reach such a block and fail
  the load (a library that needs the surplus when it is used up). The initializers and finalizers of libraries loaded late
  are collected for the runtime to call (CallTakeModuleInitializers).

  Each module keeps kernel copies of its symbol, string and hash tables
  so symbols can be found later without touching user memory.

  Nothing in the file is trusted: every address the dynamic section,
  the symbols, the relocations and the TLS segment name must lie in the
  module's own image (ImageStart, ImageEnd) - a relocation is written
  there and nowhere else, a copy relocation copies from the defining
  module's image, the TLS image and the initializer arrays are read
  from it - and every table is checked against the file and kept
  whole (string tables end in a zero). A segment must lie in user
  space. The window into the process (Processes.AddressSpace) refuses
  anything else again on its own, so a crafted file fails to load
  rather than reach kernel memory or pages others share.

  Exec loads into an address space the process does not have yet: the
  routines take a TLoadTarget (the space and the slot of its module
  list), so nothing half loaded is ever seen through the process. The
  program's file is opened once by the caller, which checks it (may the
  caller run it, does it run as its owner) and hands the same open file
  to the loader, so what runs is what was checked.

  Where everything went: the process's module list (Process^.Modules, a
  TModuleList) holds every loaded module in load order - the program
  first - with its file name, its Base (the load bias: an address in
  the process is the address the module was linked for plus Base,
  which is what a symbolizer subtracts) and the span its segments
  cover (ImageStart, ImageEnd). With address space randomization these
  differ from process to process, so crash reports must state them
  (scripts/symbolize.py takes them).
}
unit Processes.ImageLoader;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Files,
  Processes.Process,
  Processes.AddressSpace;

const
  MaximumModules = 32;
  ModuleNameLength = 64;
  { As many as a process may have modules: a program linking more
    libraries than this directly would lose the rest (the file manager
    names 20). }
  MaximumNeededLibraries = MaximumModules;

type
  PLoadedModule = ^TLoadedModule;
  TLoadedModule = record
    Name: array[0..ModuleNameLength - 1] of Char;
    { The load bias: link address + Base = address in the process. }
    Base: QWord;
    { The end of its mapped pages (crash reports, CallGetProcessModules). }
    Limit: QWord;
    { The pages its loadable segments cover in the process. }
    ImageStart: QWord;
    ImageEnd: QWord;
    { The tag of its regions (TUserRegion.LoadTag). }
    LoadTag: QWord;
    EntryPoint: QWord;
    ProgramHeaderAddress: QWord;
    ProgramHeaderCount: LongWord;

    Symbols: Pointer;
    SymbolCount: LongWord;
    Strings: PChar;
    StringsSize: QWord;
    BucketCount: LongWord;
    Buckets: PLongWord;
    Chains: PLongWord;

    { Relocation tables, kept only until the module is relocated. }
    Relocations: Pointer;
    RelocationCount: QWord;
    IsRelocated: Boolean;
    { Relocated into pages of the kernel's (a relocated copy kept with
      its image section, or one made now), not in the process: until it
      is relocated, its section (a PImageSection, a use held) and which
      of its ImagePageCount pages the relocations write (RelocatedPages,
      1 per such page; those are left unmapped until then). }
    UsesRelocatedCopies: Boolean;
    Section: Pointer;
    RelocatedPages: PByte;
    ImagePageCount: QWord;

    Needed: array[0..MaximumNeededLibraries - 1] of Integer;
    NeededCount: Integer;

    { The TLS segment, if HasThreadLocalStorage: the initialization image
      (TlsImageSize bytes at TlsImageAddress, the rest of TlsSize is
      zero) and where the block lies below the thread pointer. }
    HasThreadLocalStorage: Boolean;
    TlsImageAddress: QWord;
    TlsImageSize: QWord;
    TlsSize: QWord;
    TlsAlignment: QWord;
    TlsOffset: QWord;

    { Its index in the module list: the handle LoadLibraryImage gives. }
    Handle: Integer;
    { Loaded after the program started: its TLS block is made per thread
      by the user runtime (TlsOffset is unused). }
    HasDynamicTls: Boolean;
    { Loaded after the program started with its block in the static
      surplus: the threads there are get the block when the load ends. }
    HasSurplusTls: Boolean;

    { Initializers and finalizers (user addresses; 0 if absent). }
    InitFunction: QWord;
    InitArray: QWord;
    InitArrayCount: QWord;
    FiniFunction: QWord;
    FiniArray: QWord;
    FiniArrayCount: QWord;
    { Its initializers were handed out already (to the program's
      startup, or for a library loaded late to the runtime). }
    InitializersTaken: Boolean;
    { A library loaded late: the initializers and finalizers of it and
      of the libraries loaded with it, until the runtime takes them
      (kernel arrays, nil when there are none). }
    PendingInitializers: PQWord;
    PendingInitializerCount: QWord;
    PendingFinalizers: PQWord;
    PendingFinalizerCount: QWord;
    { A program that names an interpreter (PT_INTERP, a C program and
      mlibc's ld.so): the interpreter's module index, -1 for none. The
      interpreter loads the libraries, relocates and runs the
      initializers itself; the kernel only maps the two. }
    InterpreterModule: Integer;
  end;

  PModuleList = ^TModuleList;
  TModuleList = record
    Modules: array[0..MaximumModules - 1] of PLoadedModule;
    Count: Integer;
    { The static TLS area every thread gets below its thread pointer
      (from the program's load on, the surplus included). }
    StaticTlsSize: QWord;
    StaticTlsAlignment: QWord;
    { The surplus: blocks of libraries loaded late are placed from
      SurplusCursor (as PlaceStaticTlsBlock counts) up to StaticTlsSize. }
    SurplusCursor: QWord;
    { Set once the program is loaded: the layout can no longer change. }
    StartupComplete: Boolean;
  end;

  { What a program or library is loaded into: an address space and the
    slot of its module list (a PModuleList, made on first use). }
  TLoadTarget = record
    Space: PAddressSpace;
    Modules: ^Pointer;
  end;

{ All routines return 0 on success or an Abi error code. }

{ The process's own space and module list. }
function ProcessLoadTarget(Process: PProcess): TLoadTarget;
{ Loads the program whose file ProgramFile (open for reading, checked by
  the caller; still the caller's to close) is, named KernelPath. }
function LoadProgramImage(const Target: TLoadTarget; ProgramFile: POpenFile; KernelPath: PChar;
  out MainModule: PLoadedModule): LongInt;
{ The interpreter module of a program that has one (PT_INTERP), else nil. }
function InterpreterOf(const Target: TLoadTarget; MainModule: PLoadedModule): PLoadedModule;
{ Loads a library at run time from LibraryFile (open, checked by the
  caller; still the caller's), named KernelPath. }
function LoadLibraryImage(const Target: TLoadTarget; LibraryFile: POpenFile; KernelPath: PChar;
  out ModuleHandle: Integer): LongInt;
{ The kernel path of library Name in library folder FolderIndex (0: /lib,
  1: /usr/local/lib) of the system volume; False past the last folder. }
function LibraryFolderPath(FolderIndex: Integer; Name: PChar; Path: PChar; Capacity: QWord): Boolean;
function FindExportedSymbol(Process: PProcess; ModuleHandle: Integer; Name: PChar;
  out Address: QWord): LongInt;
procedure ReleaseModules(Process: PProcess);
{ Frees the module list in Modules (a load target's). }
procedure ReleaseModuleList(var Modules: Pointer);
{ The size of a thread's data region and where its thread pointer is,
  for the module list List (nil: a process without modules). }
procedure GetThreadRegionLayout(List: PModuleList; out RegionSize, ThreadPointerOffset: QWord);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Atomic,
  Elf64,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.KernelHeap,
  Memory.PhysicalPages,
  Memory.Arch.PageTables,
  FileSystem.Types,
  Processes.AddressLayout,
  Processes.UserRegions,
  Processes.ImageSections,
  Processes.MappedFiles,
  Processes.Paths,
  Processes.RelocatedCopies,
  Processes.Arch.ImageFormat,
  Kernel.Options;

const
  MaximumImageSize = 64 * 1024 * 1024;
  MaximumDynamicSectionSize = 64 * 1024;
  MaximumProgramHeaders = 64;
  MaximumStaticTlsSize = 1024 * 1024;
  { The static TLS surplus for libraries loaded late (glibc keeps about
    as much), and the alignment the thread pointer gets so blocks
    placed there may be aligned up to it. }
  StaticTlsSurplusBytes = 2048;
  StaticTlsSurplusAlignment = 64;
  MinimumThreadPointerAlignment = 16;
  MaximumInitializers = 4096;
  { Where libraries named without a folder are looked for, in order:
    the system's, then ported software's (ports/README.md, "Prefix"). }
  LibraryFolderCount = 2;
  LibraryFolders: array[0..LibraryFolderCount - 1] of PChar = ('/lib/', '/usr/local/lib/');
  MaximumInterpreterPath = 256;

var
  { The tag of the last load (TUserRegion.LoadTag). }
  LastLoadTag: Int64 = 0;

type
  { An ELF file while it is being loaded: its section, which the load
    holds a use of, and through it the file's pages. }
  TImageFile = record
    Size: QWord;
    Header: PElf64FileHeader;
    Section: PImageSection;
    MappedFile: PMappedFile;
  end;

  { Where a page of the memory image comes from. }
  TPageSource = (
    { No segment covers it. }
    PageSourceNone,
    { The file's page at an offset. }
    PageSourceFile,
    { Zeros (bss alone). }
    PageSourceZero,
    { Built in the section. }
    PageSourceBuilt,
    { Written by relocations: mapped from a relocated copy once the
      module is relocated. }
    PageSourceRelocated);

  TDynamicInformation = record
    StringTable: QWord;
    StringTableSize: QWord;
    SymbolTable: QWord;
    Hash: QWord;
    Rela: QWord;
    RelaSize: QWord;
    JumpRelocations: QWord;
    JumpRelocationsSize: QWord;
    InitFunction: QWord;
    InitArray: QWord;
    InitArraySize: QWord;
    FiniFunction: QWord;
    FiniArray: QWord;
    FiniArraySize: QWord;
    HasPreinitArray: Boolean;
    Flags: QWord;
    NeededOffsets: array[0..MaximumNeededLibraries - 1] of QWord;
    NeededCount: Integer;
  end;

{ --- Files ----------------------------------------------------------- }

{ The identity of the open file OpenedFile, if it may be an image. }
function DescribeImageFile(OpenedFile: POpenFile; out Identity: TImageIdentity): LongInt;
var
  Information: TNodeInformation;
begin
  FillMemory(@Identity, SizeOf(Identity), 0);
  if (OpenedFile = nil) or (OpenedFile^.Volume = nil) then
    Exit(ErrorBadExecutable);
  GetFileInformation(OpenedFile, Information);
  Identity.Volume := OpenedFile^.Volume;
  Identity.NodeNumber := Information.NodeNumber;
  Identity.SizeInBytes := Information.SizeInBytes;
  Identity.ModificationTime := Information.ModificationTime;
  if (Information.Kind <> NodeKindFile) or (Information.SizeInBytes < SizeOf(TElf64FileHeader)) or
     (Information.SizeInBytes > MaximumImageSize) then
    Exit(ErrorBadExecutable);
  Result := ErrorNone;
end;

{ True if [Offset, Offset + Length) lies inside a file of Size bytes
  (without overflow). }
function RangeInFile(Offset, Length, Size: QWord): Boolean;
begin
  Result := (Offset <= Size) and (Length <= Size - Offset);
end;

{ True if [Address, Address + Length) lies inside the module's image. }
function RangeInModule(Module: PLoadedModule; Address, Length: QWord): Boolean;
begin
  Result := (Address >= Module^.ImageStart) and (Address <= Module^.ImageEnd) and
    (Length <= Module^.ImageEnd - Address);
end;

{ A loadable segment must lie in user space and be no larger than an
  image may be; then no address computed from it wraps. }
function SegmentIsPlausible(ProgramHeader: PElf64ProgramHeader): Boolean;
begin
  Result := (ProgramHeader^.MemorySize <= MaximumImageSize) and
    (ProgramHeader^.VirtualAddress < UserSpaceLimit) and
    (ProgramHeader^.MemorySize <= UserSpaceLimit - ProgramHeader^.VirtualAddress);
end;

function HeaderIsValid(const Image: TImageFile): Boolean;
var
  Header: PElf64FileHeader;
begin
  Header := Image.Header;
  Result := (Header^.Magic = ElfMagic) and (Header^.FileClass = ElfClass64) and
    (Header^.DataEncoding = ElfDataLittleEndian) and (Header^.Machine = ImageMachine) and
    ((Header^.FileType = ElfTypeExecutable) or (Header^.FileType = ElfTypeSharedObject)) and
    (Header^.ProgramHeaderEntrySize = SizeOf(TElf64ProgramHeader)) and
    (Header^.ProgramHeaderOffset + QWord(Header^.ProgramHeaderCount) * SizeOf(TElf64ProgramHeader) <= Image.Size);
end;

function ProgramHeaderAt(const Image: TImageFile; Index: Integer): PElf64ProgramHeader;
begin
  Result := Image.Section^.ProgramHeaders + Index;
end;

{ Copies the file data behind a virtual address (relative to the image's
  link address) through the file's pages. False if it is not backed by
  the file (or could not be read). }
function ReadImageData(const Image: TImageFile; VirtualAddress: QWord; Length: QWord; Destination: Pointer): Boolean;
var
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  OffsetInSegment: QWord;
begin
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad then
      Continue;
    if (VirtualAddress < ProgramHeader^.VirtualAddress) then
      Continue;
    OffsetInSegment := VirtualAddress - ProgramHeader^.VirtualAddress;
    if (OffsetInSegment < ProgramHeader^.FileSize) and (Length <= ProgramHeader^.FileSize - OffsetInSegment) and
       (ProgramHeader^.FileOffset + OffsetInSegment + Length <= Image.Size) then
      Exit(ReadMappedFileBytes(Image.MappedFile, ProgramHeader^.FileOffset + OffsetInSegment, Destination,
        Length) = ErrorNone);
  end;
  Result := False;
end;

{ --- Mapping --------------------------------------------------------- }

function MeasureSpan(const Image: TImageFile; out LowestPage, HighestPageEnd: QWord): Boolean;
var
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
begin
  LowestPage := High(QWord);
  HighestPageEnd := 0;
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if (ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad) or (ProgramHeader^.MemorySize = 0) then
      Continue;
    if RoundDownToPage(ProgramHeader^.VirtualAddress) < LowestPage then
      LowestPage := RoundDownToPage(ProgramHeader^.VirtualAddress);
    if RoundUpToPage(ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize) > HighestPageEnd then
      HighestPageEnd := RoundUpToPage(ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize);
  end;
  Result := HighestPageEnd > LowestPage;
end;

procedure UseSection(Section: PImageSection; out Image: TImageFile);
begin
  Image.Section := Section;
  Image.Header := @Section^.Header;
  Image.Size := Section^.Identity.SizeInBytes;
  Image.MappedFile := Section^.MappedFile;
end;

{ Where page PageIndex of the memory image comes from, and for a file
  page the offset of the file's page. A page is the file's when exactly
  one segment covers it and the file holds what it must: the segment's
  file data to the end of the page, or the segment ends (no bss) inside
  it - the bytes outside the segment are nobody's. With bss after the
  file data inside the page, or with two segments in it, it is built. }
function ClassifyPage(const Image: TImageFile; PageIndex: QWord; out FileOffset: QWord): TPageSource;
var
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  Segment: PElf64ProgramHeader;
  PageStart: QWord;
  PageEnd: QWord;
  Covering: Integer;
  FileDataEnd: QWord;
begin
  FileOffset := 0;
  PageStart := Image.Section^.LowestPage + PageIndex * PageSize;
  PageEnd := PageStart + PageSize;
  Covering := 0;
  Segment := nil;
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if (ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad) or (ProgramHeader^.MemorySize = 0) then
      Continue;
    if (ProgramHeader^.VirtualAddress < PageEnd) and
       (ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize > PageStart) then
    begin
      Inc(Covering);
      Segment := ProgramHeader;
    end;
  end;
  if Covering = 0 then
    Exit(PageSourceNone);
  if Covering > 1 then
    Exit(PageSourceBuilt);

  FileDataEnd := Segment^.VirtualAddress + Segment^.FileSize;
  { No file data in the page: bss alone. }
  if (Segment^.FileSize = 0) or (FileDataEnd <= PageStart) then
    Exit(PageSourceZero);
  { The file's pages must line up with the memory image's. }
  if ((Segment^.FileOffset - Segment^.VirtualAddress) and PageOffsetMask) <> 0 then
    Exit(PageSourceBuilt);
  if Segment^.FileOffset + PageStart < Segment^.VirtualAddress then
    Exit(PageSourceBuilt);
  if (FileDataEnd >= PageEnd) or (Segment^.MemorySize <= Segment^.FileSize) then
  begin
    FileOffset := Segment^.FileOffset + PageStart - Segment^.VirtualAddress;
    Exit(PageSourceFile);
  end;
  Result := PageSourceBuilt;
end;

{ Builds the section's pages that no file page stands for: the file
  data of every segment in them (the rest stays zero, as bss must). }
function BuildSectionPages(const Image: TImageFile): LongInt;
var
  PageIndex: QWord;
  FileOffset: QWord;
  Page: TPhysicalAddress;
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  PageStart: QWord;
  First: QWord;
  Last: QWord;
begin
  PageIndex := 0;
  while PageIndex < Image.Section^.PageCount do
  begin
    if ClassifyPage(Image, PageIndex, FileOffset) = PageSourceBuilt then
    begin
      Page := AllocateZeroedPhysicalPage(PageUsageProgramImage);
      if Page = 0 then
        Exit(ErrorOutOfMemory);
      Image.Section^.BuiltPages[PageIndex] := Page;
      PageStart := Image.Section^.LowestPage + PageIndex * PageSize;
      for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
      begin
        ProgramHeader := ProgramHeaderAt(Image, Index);
        if (ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad) or (ProgramHeader^.FileSize = 0) then
          Continue;
        { The segment's file data inside this page. }
        First := ProgramHeader^.VirtualAddress;
        if First < PageStart then
          First := PageStart;
        Last := ProgramHeader^.VirtualAddress + ProgramHeader^.FileSize;
        if Last > PageStart + PageSize then
          Last := PageStart + PageSize;
        if Last <= First then
          Continue;
        Result := ReadMappedFileBytes(Image.MappedFile,
          ProgramHeader^.FileOffset + (First - ProgramHeader^.VirtualAddress),
          PByte(PhysicalToVirtual(Page)) + (First - PageStart), Last - First);
        if Result <> ErrorNone then
          Exit;
      end;
    end;
    Inc(PageIndex);
  end;
  Result := ErrorNone;
end;

{ Reads and checks the ELF header and program headers of a file whose
  mapped file is MappedFile, and makes its section (which takes over
  the mapped file's reference). }
function CreateSectionFromFile(KernelPath: PChar; const Identity: TImageIdentity; MappedFile: PMappedFile;
  out Section: PImageSection): LongInt;
var
  Header: TElf64FileHeader;
  ProgramHeaders: PElf64ProgramHeader;
  Image: TImageFile;
  LowestPage: QWord;
  HighestPageEnd: QWord;
  Index: Integer;
  HeaderBytes: QWord;
begin
  Section := nil;
  ProgramHeaders := nil;
  Result := ReadMappedFileBytes(MappedFile, 0, @Header, SizeOf(Header));
  if (Result = ErrorNone) and ((Header.ProgramHeaderCount = 0) or
     (Header.ProgramHeaderCount > MaximumProgramHeaders) or
     (Header.ProgramHeaderEntrySize <> SizeOf(TElf64ProgramHeader))) then
    Result := ErrorBadExecutable;
  if Result = ErrorNone then
  begin
    HeaderBytes := QWord(Header.ProgramHeaderCount) * SizeOf(TElf64ProgramHeader);
    if (Header.ProgramHeaderOffset > Identity.SizeInBytes) or
       (HeaderBytes > Identity.SizeInBytes - Header.ProgramHeaderOffset) then
      Result := ErrorBadExecutable;
  end;
  if Result = ErrorNone then
  begin
    ProgramHeaders := PElf64ProgramHeader(AllocateKernelMemory(HeaderBytes));
    if ProgramHeaders = nil then
      Result := ErrorOutOfMemory
    else
      Result := ReadMappedFileBytes(MappedFile, Header.ProgramHeaderOffset, ProgramHeaders, HeaderBytes);
  end;
  if Result <> ErrorNone then
  begin
    FreeKernelMemory(ProgramHeaders);
    ReleaseMappedFile(MappedFile, True);
    Exit;
  end;

  { Checked through a provisional image over the records just read. }
  Section := CreateImageSection(KernelPath, Identity, MappedFile, Header, ProgramHeaders, 0, 1);
  if Section = nil then
    Exit(ErrorOutOfMemory);
  UseSection(Section, Image);
  if not HeaderIsValid(Image) then
    Result := ErrorBadExecutable;
  for Index := 0 to Header.ProgramHeaderCount - 1 do
    if (Result = ErrorNone) and (ProgramHeaderAt(Image, Index)^.SegmentType = ProgramHeaderTypeLoad) and
       (not RangeInFile(ProgramHeaderAt(Image, Index)^.FileOffset, ProgramHeaderAt(Image, Index)^.FileSize,
         Image.Size) or
        (ProgramHeaderAt(Image, Index)^.FileSize > ProgramHeaderAt(Image, Index)^.MemorySize) or
        not SegmentIsPlausible(ProgramHeaderAt(Image, Index))) then
      Result := ErrorBadExecutable;
  if (Result = ErrorNone) and (not MeasureSpan(Image, LowestPage, HighestPageEnd) or
     ((HighestPageEnd - LowestPage) div PageSize > MaximumImageSize div PageSize)) then
    Result := ErrorBadExecutable;
  if Result = ErrorNone then
  begin
    Section^.LowestPage := LowestPage;
    Section^.PageCount := (HighestPageEnd - LowestPage) div PageSize;
    FreeKernelMemory(Section^.BuiltPages);
    Section^.BuiltPages := PQWord(AllocateZeroedKernelMemory(Section^.PageCount * SizeOf(QWord)));
    if Section^.BuiltPages = nil then
      Result := ErrorOutOfMemory;
  end;
  if Result = ErrorNone then
    Result := BuildSectionPages(Image);
  if Result <> ErrorNone then
  begin
    ReleaseImageSection(Section);
    Section := nil;
  end;
end;

{ Finds or builds the section of the file OpenedFile is open on (named
  KernelPath); the image then refers to it, with a use held
  (ReleaseImageSection when done). OpenedFile stays the caller's. }
function AcquireImageOfFile(OpenedFile: POpenFile; KernelPath: PChar; out Image: TImageFile): LongInt;
var
  Identity: TImageIdentity;
  Section: PImageSection;
  MappedFile: PMappedFile;
begin
  FillMemory(@Image, SizeOf(Image), 0);
  Result := DescribeImageFile(OpenedFile, Identity);
  if Result <> ErrorNone then
    Exit;
  Section := FindImageSection(KernelPath, Identity);
  if Section <> nil then
  begin
    UseSection(Section, Image);
    Exit(ErrorNone);
  end;

  Result := AcquireMappedFile(OpenedFile, True, MappedFile);
  if Result <> ErrorNone then
    Exit;
  Result := CreateSectionFromFile(KernelPath, Identity, MappedFile, Section);
  if Result <> ErrorNone then
    Exit;
  UseSection(Section, Image);
  PublishImageSection(Section);
end;

{ The same for a file of the system's own (a needed library, the
  interpreter), opened here by name. }
function AcquireImage(KernelPath: PChar; out Image: TImageFile): LongInt;
var
  OpenedFile: POpenFile;
begin
  FillMemory(@Image, SizeOf(Image), 0);
  if OpenPath(KernelPath, OpenedFile) <> StatusSuccess then
    Exit(ErrorNotFound);
  Result := AcquireImageOfFile(OpenedFile, KernelPath, Image);
  CloseFile(OpenedFile);
end;

function SegmentAttributes(Flags: LongWord): LongWord;
begin
  Result := RegionReadable;
  if (Flags and SegmentFlagWrite) <> 0 then
    Result := Result or RegionWritable;
  if (Flags and SegmentFlagExecute) <> 0 then
    Result := Result or RegionExecutable;
end;

{ Adds one region for the run of PageCount pages from page FirstPage of
  the image (at Address), all from the same source with Attributes. }
function MapPageRun(Space: PAddressSpace; const Image: TImageFile; Address: QWord; FirstPage, PageCount: QWord;
  Attributes: LongWord; Source: TPageSource; FileOffset: QWord; LoadTag: QWord): LongInt;
var
  Template: TUserRegion;
  Index: QWord;
begin
  FillMemory(@Template, SizeOf(Template), 0);
  Template.Start := Address;
  Template.Length := PageCount * PageSize;
  Template.Attributes := Attributes;
  Template.Kind := RegionKindImage;
  Template.LoadTag := LoadTag;
  case Source of
    PageSourceFile:
      begin
        { The file's pages when first touched, copy on write. }
        Template.CommitsOnDemand := True;
        Template.Backing := Image.MappedFile;
        Template.BackingOffset := FileOffset;
        Template.BackingIsPrivate := True;
        ReferenceMappedFile(Image.MappedFile, True);
        Result := AddRegionRecord(Space, Template);
        if Result <> ErrorNone then
          ReleaseMappedFile(Image.MappedFile, True);
      end;
    PageSourceZero:
      begin
        Template.CommitsOnDemand := True;
        Result := AddRegionRecord(Space, Template);
      end;
    PageSourceRelocated:
      { Its pages come once the module is relocated (InstallRelocatedPages). }
      Result := AddRegionRecord(Space, Template);
  else
    begin
      { The section's built pages, mapped now into the region (which
        must be free first: nothing else is ever replaced). }
      Result := AddRegionRecord(Space, Template);
      Index := 0;
      while (Index < PageCount) and (Result = ErrorNone) do
      begin
        Result := MapSharedPage(Space, Address + Index * PageSize,
          Image.Section^.BuiltPages[FirstPage + Index], Attributes);
        Inc(Index);
      end;
      if (Result <> ErrorNone) and (Index > 0) then
        ReleaseUserRegion(Space, Address);
    end;
  end;
end;

{ Where page PageIndex is mapped from: as ClassifyPage says, but a page
  the relocations write (RelocatedPages) waits for its relocated copy. }
function MappedPageSource(const Image: TImageFile; PageIndex: QWord; RelocatedPages: PByte;
  out FileOffset: QWord): TPageSource;
begin
  Result := ClassifyPage(Image, PageIndex, FileOffset);
  if (Result <> PageSourceNone) and (RelocatedPages <> nil) and (RelocatedPages[PageIndex] <> 0) then
    Result := PageSourceRelocated;
end;

{ The attributes of page PageIndex: those of every segment covering it. }
function PageAttributesOf(const Image: TImageFile; PageIndex: QWord): LongWord;
var
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  PageStart: QWord;
begin
  Result := 0;
  PageStart := Image.Section^.LowestPage + PageIndex * PageSize;
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if (ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad) or (ProgramHeader^.MemorySize = 0) then
      Continue;
    if (ProgramHeader^.VirtualAddress < PageStart + PageSize) and
       (ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize > PageStart) then
      Result := Result or SegmentAttributes(ProgramHeader^.Flags);
  end;
end;

{ Maps the image with exactly the attributes of the segments covering
  each page, one region per run of pages alike in attributes and source
  (and, for the file's pages, following one another in the file). }
function MapSegments(Space: PAddressSpace; const Image: TImageFile; Bias: QWord;
  LowestPage, HighestPageEnd: QWord; LoadTag: QWord; RelocatedPages: PByte): LongInt;
var
  PageCount: QWord;
  PageAttributes: PLongWord;
  PageIndex: QWord;
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  FirstPage: QWord;
  LastPage: QWord;
  RunStart: QWord;
  RunSource: TPageSource;
  RunOffset: QWord;
  Source: TPageSource;
  FileOffset: QWord;
begin
  PageCount := (HighestPageEnd - LowestPage) div PageSize;
  PageAttributes := PLongWord(AllocateZeroedKernelMemory(PageCount * SizeOf(LongWord)));
  if PageAttributes = nil then
    Exit(ErrorOutOfMemory);

  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if (ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad) or (ProgramHeader^.MemorySize = 0) then
      Continue;
    FirstPage := (RoundDownToPage(ProgramHeader^.VirtualAddress) - LowestPage) div PageSize;
    LastPage := (RoundUpToPage(ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize) - LowestPage) div PageSize;
    for PageIndex := FirstPage to LastPage - 1 do
      PageAttributes[PageIndex] := PageAttributes[PageIndex] or SegmentAttributes(ProgramHeader^.Flags);
  end;

  { Gaps between segments stay unmapped. }
  Result := ErrorNone;
  PageIndex := 0;
  while (PageIndex < PageCount) and (Result = ErrorNone) do
  begin
    RunSource := MappedPageSource(Image, PageIndex, RelocatedPages, RunOffset);
    if (PageAttributes[PageIndex] = 0) or (RunSource = PageSourceNone) then
    begin
      Inc(PageIndex);
      Continue;
    end;
    RunStart := PageIndex;
    Inc(PageIndex);
    while PageIndex < PageCount do
    begin
      Source := MappedPageSource(Image, PageIndex, RelocatedPages, FileOffset);
      if (PageAttributes[PageIndex] <> PageAttributes[RunStart]) or (Source <> RunSource) or
         ((Source = PageSourceFile) and (FileOffset <> RunOffset + (PageIndex - RunStart) * PageSize)) then
        Break;
      Inc(PageIndex);
    end;
    Result := MapPageRun(Space, Image, Bias + LowestPage + RunStart * PageSize, RunStart, PageIndex - RunStart,
      PageAttributes[RunStart], RunSource, RunOffset, LoadTag);
  end;
  FreeKernelMemory(PageAttributes);
end;

{ --- Thread-local storage -------------------------------------------- }

function FindThreadLocalSegment(const Image: TImageFile): PElf64ProgramHeader;
var
  Index: Integer;
begin
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    Result := ProgramHeaderAt(Image, Index);
    if (Result^.SegmentType = ProgramHeaderTypeThreadLocal) and (Result^.MemorySize > 0) then
      Exit;
  end;
  Result := nil;
end;

function FindInterpreterSegment(const Image: TImageFile): PElf64ProgramHeader;
var
  Index: Integer;
begin
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    Result := ProgramHeaderAt(Image, Index);
    if Result^.SegmentType = ProgramHeaderTypeInterpreter then
      Exit;
  end;
  Result := nil;
end;

{ The interpreter's path named by PT_INTERP, as a kernel path on the
  system volume. }
function ReadInterpreterPath(const Image: TImageFile; Segment: PElf64ProgramHeader; KernelPath: PChar): LongInt;
var
  UserPath: array[0..MaximumInterpreterPath - 1] of Char;
begin
  if (Segment^.FileSize < 2) or (Segment^.FileSize > MaximumInterpreterPath) or
     not RangeInFile(Segment^.FileOffset, Segment^.FileSize, Image.Size) then
    Exit(ErrorBadExecutable);
  if ReadMappedFileBytes(Image.MappedFile, Segment^.FileOffset, @UserPath[0], Segment^.FileSize) <> ErrorNone then
    Exit(ErrorBadExecutable);
  UserPath[Segment^.FileSize - 1] := #0;
  if UserPath[0] <> '/' then
    Exit(ErrorBadExecutable);
  SystemVolumePath(@UserPath[0], KernelPath, ProcessPathCapacity);
  Result := ErrorNone;
end;

{ True if one of Module's relocations is an initial or local exec
  access (a fixed offset from the thread pointer). }
function HasOwnThreadPointerRelocations(Module: PLoadedModule): Boolean;
var
  Index: QWord;
  Kind: TRelocationKind;
begin
  Result := False;
  Index := 0;
  while Index < Module^.RelocationCount do
  begin
    Kind := ClassifyRelocation(RelocationType(PElf64Rela(Module^.Relocations)[Index]));
    if (Kind = RelocationKindThreadPointerOffset64) or (Kind = RelocationKindThreadPointerOffset32) then
      Exit(True);
    Inc(Index);
  end;
end;

{ Gives the module a place in the static TLS area, after (further from
  the thread pointer than) the blocks placed before it; for a library
  loaded late, in the surplus if NeedsStaticTls (and it fits). }
function PlaceThreadLocalStorage(List: PModuleList; Module: PLoadedModule;
  Segment: PElf64ProgramHeader; Bias: QWord; NeedsStaticTls: Boolean): LongInt;
var
  Alignment: QWord;
  Offset: QWord;
  StaticTlsSize: QWord;
begin
  Alignment := Segment^.Alignment;
  if Alignment = 0 then
    Alignment := 1;
  if ((Alignment and (Alignment - 1)) <> 0) or (Alignment > PageSize) or
     (Segment^.FileSize > Segment^.MemorySize) or (Segment^.MemorySize > MaximumStaticTlsSize) then
    Exit(ErrorBadExecutable);
  { Its initialization image is copied from the module's own pages. }
  if (Segment^.VirtualAddress >= UserSpaceLimit) or
     ((Segment^.FileSize > 0) and not RangeInModule(Module, Bias + Segment^.VirtualAddress, Segment^.FileSize)) then
    Exit(ErrorBadExecutable);

  Module^.HasThreadLocalStorage := True;
  Module^.TlsImageAddress := Bias + Segment^.VirtualAddress;
  Module^.TlsImageSize := Segment^.FileSize;
  Module^.TlsSize := Segment^.MemorySize;
  Module^.TlsAlignment := Alignment;
  if List^.StartupComplete then
  begin
    { In the surplus if its accesses need a fixed place and it fits;
      otherwise the runtime makes its blocks. }
    if NeedsStaticTls and (Alignment <= List^.StaticTlsAlignment) then
    begin
      StaticTlsSize := List^.SurplusCursor;
      Offset := PlaceStaticTlsBlock(StaticTlsSize, Segment^.MemorySize, Alignment);
      if StaticTlsSize <= List^.StaticTlsSize then
      begin
        List^.SurplusCursor := StaticTlsSize;
        Module^.TlsOffset := Offset;
        Module^.HasSurplusTls := True;
        Exit(ErrorNone);
      end;
    end;
    Module^.HasDynamicTls := True;
    Exit(ErrorNone);
  end;

  StaticTlsSize := List^.StaticTlsSize;
  Offset := PlaceStaticTlsBlock(StaticTlsSize, Segment^.MemorySize, Alignment);
  if StaticTlsSize > MaximumStaticTlsSize then
    Exit(ErrorOutOfMemory);
  Module^.TlsOffset := Offset;
  List^.StaticTlsSize := StaticTlsSize;
  if Alignment > List^.StaticTlsAlignment then
    List^.StaticTlsAlignment := Alignment;
  Result := ErrorNone;
end;

{ --- Dynamic section ------------------------------------------------- }

function ReadDynamicSection(const Image: TImageFile; out Dynamic: TDynamicInformation): LongInt;
var
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  Entry: PElf64Dynamic;
  EntryCount: QWord;
  EntryIndex: QWord;
begin
  FillMemory(@Dynamic, SizeOf(Dynamic), 0);
  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if ProgramHeader^.SegmentType <> ProgramHeaderTypeDynamic then
      Continue;
    if not RangeInFile(ProgramHeader^.FileOffset, ProgramHeader^.FileSize, Image.Size) or
       (ProgramHeader^.FileSize > MaximumDynamicSectionSize) then
      Exit(ErrorBadExecutable);

    EntryCount := ProgramHeader^.FileSize div SizeOf(TElf64Dynamic);
    if EntryCount = 0 then
      Exit(ErrorNone);
    Entry := PElf64Dynamic(AllocateKernelMemory(EntryCount * SizeOf(TElf64Dynamic)));
    if Entry = nil then
      Exit(ErrorOutOfMemory);
    if ReadMappedFileBytes(Image.MappedFile, ProgramHeader^.FileOffset, Entry,
       EntryCount * SizeOf(TElf64Dynamic)) <> ErrorNone then
    begin
      FreeKernelMemory(Entry);
      Exit(ErrorIo);
    end;
    EntryIndex := 0;
    while (EntryIndex < EntryCount) and (Entry[EntryIndex].Tag <> DynamicNull) do
    begin
      case Entry[EntryIndex].Tag of
        DynamicNeeded:
          if Dynamic.NeededCount < MaximumNeededLibraries then
          begin
            Dynamic.NeededOffsets[Dynamic.NeededCount] := Entry[EntryIndex].Value;
            Inc(Dynamic.NeededCount);
          end;
        DynamicStringTable: Dynamic.StringTable := Entry[EntryIndex].Value;
        DynamicStringTableSize: Dynamic.StringTableSize := Entry[EntryIndex].Value;
        DynamicSymbolTable: Dynamic.SymbolTable := Entry[EntryIndex].Value;
        DynamicHash: Dynamic.Hash := Entry[EntryIndex].Value;
        DynamicRela: Dynamic.Rela := Entry[EntryIndex].Value;
        DynamicRelaSize: Dynamic.RelaSize := Entry[EntryIndex].Value;
        DynamicJumpRelocations: Dynamic.JumpRelocations := Entry[EntryIndex].Value;
        DynamicPltRelocationSize: Dynamic.JumpRelocationsSize := Entry[EntryIndex].Value;
        DynamicInitFunction: Dynamic.InitFunction := Entry[EntryIndex].Value;
        DynamicFiniFunction: Dynamic.FiniFunction := Entry[EntryIndex].Value;
        DynamicInitArray: Dynamic.InitArray := Entry[EntryIndex].Value;
        DynamicInitArraySize: Dynamic.InitArraySize := Entry[EntryIndex].Value;
        DynamicFiniArray: Dynamic.FiniArray := Entry[EntryIndex].Value;
        DynamicFiniArraySize: Dynamic.FiniArraySize := Entry[EntryIndex].Value;
        DynamicPreinitArray, DynamicPreinitArraySize: Dynamic.HasPreinitArray := True;
        DynamicFlags: Dynamic.Flags := Entry[EntryIndex].Value;
      end;
      Inc(EntryIndex);
    end;
    FreeKernelMemory(Entry);
    Exit(ErrorNone);
  end;
  Result := ErrorNone; { a static program without a dynamic section }
end;

{ Copies a table from the file into a new kernel buffer. }
function CopyTable(const Image: TImageFile; VirtualAddress, Length: QWord; out Copy: Pointer): Boolean;
begin
  Copy := nil;
  if Length = 0 then
    Exit(True);
  if Length > MaximumImageSize then
    Exit(False);
  Copy := AllocateKernelMemory(Length);
  if Copy = nil then
    Exit(False);
  Result := ReadImageData(Image, VirtualAddress, Length, Copy);
  if not Result then
  begin
    FreeKernelMemory(Copy);
    Copy := nil;
  end;
end;

{ Copies the string table, with a zero after it: a name at the end of a
  table that does not end in one stops there, inside the copy. }
function CopyStringTable(Module: PLoadedModule; const Image: TImageFile; VirtualAddress, Length: QWord): Boolean;
begin
  Module^.Strings := nil;
  Module^.StringsSize := 0;
  if Length > MaximumImageSize then
    Exit(False);
  Module^.Strings := PChar(AllocateZeroedKernelMemory(Length + 1));
  if Module^.Strings = nil then
    Exit(False);
  Module^.StringsSize := Length;
  Result := (Length = 0) or ReadImageData(Image, VirtualAddress, Length, Module^.Strings);
end;

function CopyDynamicTables(Module: PLoadedModule; const Image: TImageFile;
  const Dynamic: TDynamicInformation): LongInt;
var
  HashHeader: array[0..1] of LongWord;
  HashTable: Pointer;
  RelaCopy: Pointer;
  JumpCopy: Pointer;
  RelaCount: QWord;
  JumpCount: QWord;
begin
  if Dynamic.SymbolTable = 0 then
    Exit(ErrorNone);
  if (Dynamic.Hash = 0) or (Dynamic.StringTable = 0) then
    Exit(ErrorBadExecutable); { link with --hash-style=sysv }

  if not ReadImageData(Image, Dynamic.Hash, SizeOf(HashHeader), @HashHeader[0]) then
    Exit(ErrorBadExecutable);
  Module^.BucketCount := HashHeader[0];
  Module^.SymbolCount := HashHeader[1];

  if not CopyTable(Image, Dynamic.Hash, 8 + 4 * (QWord(Module^.BucketCount) + Module^.SymbolCount), HashTable) then
    Exit(ErrorBadExecutable);
  Module^.Buckets := PLongWord(HashTable) + 2;
  Module^.Chains := Module^.Buckets + Module^.BucketCount;

  if not CopyTable(Image, Dynamic.SymbolTable, QWord(Module^.SymbolCount) * SizeOf(TElf64Symbol), Module^.Symbols) then
    Exit(ErrorBadExecutable);
  if not CopyStringTable(Module, Image, Dynamic.StringTable, Dynamic.StringTableSize) then
    Exit(ErrorBadExecutable);

  { The ordinary and the procedure linkage relocations are processed the
    same way, so they are kept in one array; tables of part records are
    refused. }
  if ((Dynamic.RelaSize mod SizeOf(TElf64Rela)) <> 0) or
     ((Dynamic.JumpRelocationsSize mod SizeOf(TElf64Rela)) <> 0) then
    Exit(ErrorBadExecutable);
  RelaCount := Dynamic.RelaSize div SizeOf(TElf64Rela);
  JumpCount := Dynamic.JumpRelocationsSize div SizeOf(TElf64Rela);
  Module^.RelocationCount := RelaCount + JumpCount;
  if Module^.RelocationCount = 0 then
    Exit(ErrorNone);
  Module^.Relocations := AllocateKernelMemory(Module^.RelocationCount * SizeOf(TElf64Rela));
  if Module^.Relocations = nil then
    Exit(ErrorOutOfMemory);
  RelaCopy := nil;
  JumpCopy := nil;
  Result := ErrorNone;
  if not CopyTable(Image, Dynamic.Rela, RelaCount * SizeOf(TElf64Rela), RelaCopy) or
     not CopyTable(Image, Dynamic.JumpRelocations, JumpCount * SizeOf(TElf64Rela), JumpCopy) then
    Result := ErrorBadExecutable;
  if Result = ErrorNone then
  begin
    if RelaCount > 0 then
      CopyMemory(Module^.Relocations, RelaCopy, RelaCount * SizeOf(TElf64Rela));
    if JumpCount > 0 then
      CopyMemory(PElf64Rela(Module^.Relocations) + RelaCount, JumpCopy, JumpCount * SizeOf(TElf64Rela));
  end;
  FreeKernelMemory(RelaCopy);
  FreeKernelMemory(JumpCopy);
end;

{ --- Modules --------------------------------------------------------- }

function ProcessLoadTarget(Process: PProcess): TLoadTarget;
begin
  Result.Space := Process^.AddressSpace;
  Result.Modules := @Process^.Modules;
end;

function ModuleList(const Target: TLoadTarget): PModuleList;
begin
  if Target.Modules^ = nil then
    Target.Modules^ := AllocateZeroedKernelMemory(SizeOf(TModuleList));
  Result := PModuleList(Target.Modules^);
end;

function FindModuleByName(List: PModuleList; Name: PChar): Integer;
var
  Index: Integer;
begin
  for Index := 0 to List^.Count - 1 do
  begin
    if TextIsEqual(@List^.Modules[Index]^.Name[0], Name) then
      Exit(Index);
  end;
  Result := -1;
end;

function FileNameOf(Path: PChar): PChar;
var
  Index: PtrUInt;
begin
  Result := Path;
  Index := 0;
  while Path[Index] <> #0 do
  begin
    if Path[Index] = '/' then
      Result := @Path[Index + 1];
    Inc(Index);
  end;
end;

procedure FreeModule(Module: PLoadedModule);
begin
  if Module = nil then
    Exit;
  FreeKernelMemory(Module^.PendingInitializers);
  FreeKernelMemory(Module^.PendingFinalizers);
  if Module^.Buckets <> nil then
    FreeKernelMemory(Module^.Buckets - 2);
  FreeKernelMemory(Module^.Symbols);
  FreeKernelMemory(Module^.Strings);
  FreeKernelMemory(Module^.Relocations);
  FreeKernelMemory(Module^.RelocatedPages);
  if Module^.Section <> nil then
    ReleaseImageSection(PImageSection(Module^.Section));
  FreeKernelMemory(Module);
end;

function LoadModule(const Target: TLoadTarget; OpenedFile: POpenFile; KernelPath: PChar; IsProgram: Boolean;
  RelocatesItself: Boolean; out ModuleIndex: Integer): LongInt; forward;
{ Notes which pages of the image Module's relocations write (its
  RelocatedPages), so they are left for a relocated copy; nothing (the
  module is relocated in the process) if it has copy relocations or a
  relocation outside its image. }
function PlanRelocatedPages(Module: PLoadedModule; const Image: TImageFile): LongInt; forward;

function NoteInitializers(Module: PLoadedModule; const Dynamic: TDynamicInformation;
  Bias: QWord): LongInt;
begin
  { Only executables may have DT_PREINIT_ARRAY, and ours have none. }
  if Dynamic.HasPreinitArray then
    Exit(ErrorUnsupported);
  if Dynamic.InitFunction <> 0 then
    Module^.InitFunction := Bias + Dynamic.InitFunction;
  if Dynamic.FiniFunction <> 0 then
    Module^.FiniFunction := Bias + Dynamic.FiniFunction;
  Module^.InitArrayCount := Dynamic.InitArraySize div SizeOf(QWord);
  Module^.FiniArrayCount := Dynamic.FiniArraySize div SizeOf(QWord);
  if (Module^.InitArrayCount > MaximumInitializers) or (Module^.FiniArrayCount > MaximumInitializers) then
    Exit(ErrorBadExecutable);
  if Module^.InitArrayCount > 0 then
    Module^.InitArray := Bias + Dynamic.InitArray;
  if Module^.FiniArrayCount > 0 then
    Module^.FiniArray := Bias + Dynamic.FiniArray;
  { The arrays are read from the module's own pages. }
  if ((Module^.InitArrayCount > 0) and
      not RangeInModule(Module, Module^.InitArray, Module^.InitArrayCount * SizeOf(QWord))) or
     ((Module^.FiniArrayCount > 0) and
      not RangeInModule(Module, Module^.FiniArray, Module^.FiniArrayCount * SizeOf(QWord))) then
    Exit(ErrorBadExecutable);
  Result := ErrorNone;
end;

function LibraryFolderPath(FolderIndex: Integer; Name: PChar; Path: PChar; Capacity: QWord): Boolean;
begin
  if (FolderIndex < 0) or (FolderIndex >= LibraryFolderCount) then
    Exit(False);
  SystemVolumePath(LibraryFolders[FolderIndex], Path, Capacity);
  CopyText(@Path[TextLength(Path)], Name, Capacity - TextLength(Path));
  Result := True;
end;

function NameHasSlash(Name: PChar): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Name[Index] <> #0 do
  begin
    if Name[Index] = '/' then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

{ Loads the libraries a module needs, from /lib of the system volume,
  else from /usr/local/lib. }
function LoadNeededLibraries(const Target: TLoadTarget; Module: PLoadedModule;
  const Dynamic: TDynamicInformation): LongInt;
var
  NeededIndex: Integer;
  LibraryName: PChar;
  LibraryPath: array[0..ProcessPathCapacity - 1] of Char;
  Existing: Integer;
  FolderIndex: Integer;
begin
  Result := ErrorNone;
  for NeededIndex := 0 to Dynamic.NeededCount - 1 do
  begin
    if Dynamic.NeededOffsets[NeededIndex] >= Module^.StringsSize then
      Exit(ErrorBadExecutable);
    LibraryName := Module^.Strings + Dynamic.NeededOffsets[NeededIndex];

    { A name, not a path: needed libraries come from the library
      folders only. }
    if NameHasSlash(LibraryName) then
      Exit(ErrorBadExecutable);
    Existing := FindModuleByName(ModuleList(Target), LibraryName);
    if Existing < 0 then
    begin
      FolderIndex := 0;
      repeat
        LibraryFolderPath(FolderIndex, LibraryName, @LibraryPath[0], ProcessPathCapacity);
        Result := LoadModule(Target, nil, @LibraryPath[0], False, False, Existing);
        Inc(FolderIndex);
      until (Result <> ErrorNotFound) or (FolderIndex >= LibraryFolderCount);
      if Result <> ErrorNone then
        Exit;
    end;
    Module^.Needed[Module^.NeededCount] := Existing;
    Inc(Module^.NeededCount);
  end;
end;

type
  TLibraryPlacement = (PlacementNotRead, PlacementShared, PlacementPerProcess);

var
  LibraryPlacement: TLibraryPlacement = PlacementNotRead;

{ True unless the kernel option aslr=process asks for every library at
  a random place of its own in each process. }
function LibraryPlacementIsShared: Boolean;
var
  Value: array[0..15] of Char;
begin
  if LibraryPlacement = PlacementNotRead then
  begin
    LibraryPlacement := PlacementShared;
    if GetKernelOptionValue('aslr', @Value[0], SizeOf(Value)) and TextIsEqual(@Value[0], 'process') then
      LibraryPlacement := PlacementPerProcess;
  end;
  Result := LibraryPlacement = PlacementShared;
end;

{ Finds room for a library of Length bytes whose section is Section.
  Without randomization: after the library loaded last. With it: where
  the library was placed first since its section was made, if that is
  free here - every process then has it at the same place, and its
  relocated copy fits (unless aslr=process) - else at a random page of
  the library window (anywhere in it if nothing fits above that page),
  which becomes its place if it had none. }
function PlaceLibrary(Space: PAddressSpace; Section: PImageSection; Length: QWord; out Start: QWord): Boolean;
var
  Layout: PAddressLayout;
  Hint: QWord;
  Preferred: QWord;
begin
  Layout := @Space^.Layout;
  if not Layout^.IsRandomized then
  begin
    Result := FindFreeRange(Space, Length, Space^.NextLibraryAddress, Layout^.LibraryWindowEnd, Start);
    if Result then
      Space^.NextLibraryAddress := Start + Length + PageSize;
    Exit;
  end;
  if LibraryPlacementIsShared then
  begin
    Preferred := Section^.PreferredStart;
    if (Preferred <> 0) and (Preferred >= Layout^.LibraryWindowStart) and (Preferred < Layout^.LibraryWindowEnd) and
       (Length <= Layout^.LibraryWindowEnd - Preferred) and
       FindFreeRange(Space, Length, Preferred, Preferred + Length, Start) and (Start = Preferred) then
    begin
      AtomicIncrement(RelocatedCopyCounters.SharedPlacements);
      Exit(True);
    end;
  end;
  Hint := ChooseLibraryAddress(Layout^, Length, @LayoutRandom);
  Result := FindFreeRange(Space, Length, Hint, Layout^.LibraryWindowEnd, Start);
  if not Result then
    Result := FindFreeRange(Space, Length, Layout^.LibraryWindowStart, Layout^.LibraryWindowEnd, Start);
  if Result and (Section^.PreferredStart = 0) and LibraryPlacementIsShared then
    Section^.PreferredStart := Start;
end;

{ The kernel leaves a module to its interpreter: no relocations, no
  initializers of its own to collect. }
procedure LeaveToInterpreter(Module: PLoadedModule);
begin
  FreeKernelMemory(Module^.Relocations);
  Module^.Relocations := nil;
  Module^.RelocationCount := 0;
  Module^.IsRelocated := True;
  Module^.InitializersTaken := True;
end;

{ Maps the program's interpreter (mlibc's ld.so) as a library, which
  relocates itself. }
function LoadInterpreter(const Target: TLoadTarget; Program_: PLoadedModule; KernelPath: PChar): LongInt;
var
  InterpreterIndex: Integer;
  Interpreter: PLoadedModule;
begin
  Result := LoadModule(Target, nil, KernelPath, False, True, InterpreterIndex);
  if Result <> ErrorNone then
    Exit;
  Interpreter := ModuleList(Target)^.Modules[InterpreterIndex];
  if Interpreter^.NeededCount <> 0 then
    Exit(ErrorBadExecutable);
  LeaveToInterpreter(Program_);
  LeaveToInterpreter(Interpreter);
  Program_^.InterpreterModule := InterpreterIndex;
end;

{ Loads the module from OpenedFile, or if that is nil from the system
  file KernelPath. }
function LoadModule(const Target: TLoadTarget; OpenedFile: POpenFile; KernelPath: PChar; IsProgram: Boolean;
  RelocatesItself: Boolean; out ModuleIndex: Integer): LongInt;
var
  List: PModuleList;
  Image: TImageFile;
  Dynamic: TDynamicInformation;
  Module: PLoadedModule;
  LowestPage: QWord;
  HighestPageEnd: QWord;
  Bias: QWord;
  Space: PAddressSpace;
  InterpreterPath: array[0..ProcessPathCapacity - 1] of Char;
  HasInterpreter: Boolean;
  LoadTag: QWord;
  Mapped: Boolean;
begin
  HasInterpreter := False;
  Mapped := False;
  LowestPage := 0;
  HighestPageEnd := 0;
  Bias := 0;
  InterpreterPath[0] := #0;
  ModuleIndex := -1;
  List := ModuleList(Target);
  Space := Target.Space;
  if List = nil then
    Exit(ErrorOutOfMemory);
  if List^.Count >= MaximumModules then
    Exit(ErrorOutOfMemory);

  if OpenedFile <> nil then
    Result := AcquireImageOfFile(OpenedFile, KernelPath, Image)
  else
    Result := AcquireImage(KernelPath, Image);
  if Result <> ErrorNone then
    Exit;
  Module := nil;

  if not HeaderIsValid(Image) or not MeasureSpan(Image, LowestPage, HighestPageEnd) then
    Result := ErrorBadExecutable;
  if (Result = ErrorNone) and IsProgram and (FindInterpreterSegment(Image) <> nil) then
  begin
    HasInterpreter := True;
    Result := ReadInterpreterPath(Image, FindInterpreterSegment(Image), @InterpreterPath[0]);
  end;
  if Result = ErrorNone then
    Result := ReadDynamicSection(Image, Dynamic);

  { Choose where the module goes. }
  if Result = ErrorNone then
  begin
    if Image.Header^.FileType = ElfTypeExecutable then
      Bias := 0 { linked for a fixed address }
    else if IsProgram then
      Bias := Space^.Layout.ImageBase - LowestPage
    else if not PlaceLibrary(Space, Image.Section, HighestPageEnd - LowestPage, Bias) then
      Result := ErrorOutOfMemory
    else
      Bias := Bias - LowestPage;
  end;

  LoadTag := QWord(AtomicIncrement(LastLoadTag));
  if Result = ErrorNone then
  begin
    Module := PLoadedModule(AllocateZeroedKernelMemory(SizeOf(TLoadedModule)));
    if Module = nil then
      Result := ErrorOutOfMemory;
  end;

  if Result = ErrorNone then
  begin
    CopyText(@Module^.Name[0], FileNameOf(KernelPath), ModuleNameLength);
    Module^.Base := Bias;
    Module^.Limit := Bias + HighestPageEnd;
    Module^.ImageStart := Bias + LowestPage;
    Module^.ImageEnd := Bias + HighestPageEnd;
    Module^.LoadTag := LoadTag;
    Module^.EntryPoint := Bias + Image.Header^.EntryPoint;
    Module^.ProgramHeaderAddress := Bias + LowestPage + Image.Header^.ProgramHeaderOffset;
    Module^.ProgramHeaderCount := Image.Header^.ProgramHeaderCount;
    Result := CopyDynamicTables(Module, Image, Dynamic);
  end;
  { Which pages its relocations write: those come from a relocated copy. }
  if (Result = ErrorNone) and not HasInterpreter and not RelocatesItself then
    Result := PlanRelocatedPages(Module, Image);

  if Result = ErrorNone then
  begin
    Result := MapSegments(Space, Image, Bias, LowestPage, HighestPageEnd, LoadTag, Module^.RelocatedPages);
    Mapped := True;
  end;

  if (Result = ErrorNone) and not HasInterpreter then
    Result := NoteInitializers(Module, Dynamic, Bias);
  if (Result = ErrorNone) and not HasInterpreter and (FindThreadLocalSegment(Image) <> nil) then
    Result := PlaceThreadLocalStorage(List, Module, FindThreadLocalSegment(Image), Bias,
      ((Dynamic.Flags and DynamicFlagStaticTls) <> 0) or HasOwnThreadPointerRelocations(Module));
  if Result = ErrorNone then
    Module^.InterpreterModule := -1;

  { A module relocated from a copy keeps its section until then. }
  if (Result = ErrorNone) and Module^.UsesRelocatedCopies then
    Module^.Section := Image.Section
  else
    ReleaseImageSection(Image.Section);

  if Result <> ErrorNone then
  begin
    { What it mapped goes with it. }
    if Mapped then
      ReleaseImageRegions(Space, Bias + LowestPage, Bias + HighestPageEnd, LoadTag);
    FreeModule(Module);
    Exit;
  end;

  { Register the module before loading its needs, so a dependency cycle
    finds it already loaded. }
  ModuleIndex := List^.Count;
  Module^.Handle := ModuleIndex;
  List^.Modules[List^.Count] := Module;
  Inc(List^.Count);

  if HasInterpreter then
    Result := LoadInterpreter(Target, Module, @InterpreterPath[0])
  else
    Result := LoadNeededLibraries(Target, Module, Dynamic);
end;

{ --- Symbols and relocation ------------------------------------------ }

function SymbolAt(Module: PLoadedModule; Index: LongWord): PElf64Symbol;
begin
  Result := PElf64Symbol(Module^.Symbols) + Index;
end;

function SymbolName(Module: PLoadedModule; Symbol: PElf64Symbol): PChar;
begin
  if Symbol^.NameOffset >= Module^.StringsSize then
    Exit('');
  Result := Module^.Strings + Symbol^.NameOffset;
end;

{ Looks Name up through the module's hash table. Only defined symbols
  count. }
function FindDefinedSymbol(Module: PLoadedModule; Name: PChar; Hash: LongWord;
  out Symbol: PElf64Symbol): Boolean;
var
  Index: LongWord;
  Steps: LongWord;
begin
  Symbol := nil;
  if (Module^.BucketCount = 0) or (Module^.Symbols = nil) then
    Exit(False);
  Index := Module^.Buckets[Hash mod Module^.BucketCount];
  Steps := 0;
  while (Index <> 0) and (Index < Module^.SymbolCount) and (Steps <= Module^.SymbolCount) do
  begin
    Symbol := SymbolAt(Module, Index);
    if (Symbol^.SectionIndex <> SymbolUndefinedSection) and TextIsEqual(SymbolName(Module, Symbol), Name) then
      Exit(True);
    Index := Module^.Chains[Index];
    Inc(Steps);
  end;
  Symbol := nil;
  Result := False;
end;

{ Searches every module in load order (the global scope). Address is the
  symbol's address, or for a thread-local symbol its offset in the
  defining module's TLS block. }
function ResolveSymbol(List: PModuleList; Name: PChar; out Address: QWord;
  out Size: QWord; SkipModule: PLoadedModule; out DefiningModule: PLoadedModule): Boolean;
var
  Index: Integer;
  Hash: LongWord;
  Symbol: PElf64Symbol;
begin
  Address := 0;
  Size := 0;
  DefiningModule := nil;
  Hash := ElfHash(Name);
  for Index := 0 to List^.Count - 1 do
  begin
    if List^.Modules[Index] = SkipModule then
      Continue;
    if FindDefinedSymbol(List^.Modules[Index], Name, Hash, Symbol) then
    begin
      DefiningModule := List^.Modules[Index];
      if SymbolType(Symbol^) = SymbolTypeThreadLocal then
        Address := Symbol^.Value
      else
        Address := DefiningModule^.Base + Symbol^.Value;
      Size := Symbol^.Size;
      Exit(True);
    end;
  end;
  Result := False;
end;

{ The TLS relocations against a module with dynamic TLS: its id is the
  tag plus its handle; a descriptor's argument carries the handle and
  the offset; nothing is at a fixed distance from the thread pointer. }
function DynamicTlsRelocationValue(Kind: TRelocationKind; DefiningModule: PLoadedModule; Offset: QWord;
  out Value: QWord): LongInt;
begin
  Value := 0;
  case Kind of
    RelocationKindTlsModule:
      Value := TlsDynamicModuleTag or QWord(DefiningModule^.Handle);
    RelocationKindTlsOffset:
      Value := Offset;
    RelocationKindTlsDescriptor:
      begin
        if Offset > High(LongWord) then
          Exit(ErrorBadExecutable);
        Value := TlsDynamicModuleTag or (QWord(DefiningModule^.Handle) shl TlsDynamicHandleShift) or Offset;
      end;
  else
    Exit(ErrorUnsupported); { initial or local exec into a library loaded late }
  end;
  Result := ErrorNone;
end;

{ The TLS relocations: Offset is the variable's offset in the TLS block
  of DefiningModule. A descriptor's value is its argument, the
  variable's offset from the thread pointer. }
function ThreadLocalRelocationValue(Kind: TRelocationKind; DefiningModule: PLoadedModule; Offset: QWord;
  out Value: QWord): LongInt;
var
  Displacement: QWord;
begin
  Value := 0;
  if (DefiningModule = nil) or not DefiningModule^.HasThreadLocalStorage then
    Exit(ErrorBadExecutable);
  if DefiningModule^.HasDynamicTls then
    Exit(DynamicTlsRelocationValue(Kind, DefiningModule, Offset, Value));
  Displacement := QWord(TlsBlockDisplacement(DefiningModule^.TlsOffset));
  case Kind of
    RelocationKindTlsModule:
      Value := Displacement;
    RelocationKindTlsOffset:
      Value := Offset;
    RelocationKindThreadPointerOffset64, RelocationKindThreadPointerOffset32, RelocationKindTlsDescriptor:
      Value := Offset + Displacement;
  end;
  Result := ErrorNone;
end;

type
  { Where the relocations' values go: into the process (keeping a
    pointer to the page last written: relocations come sorted by
    address, so most land in the same page as the one before), or for a
    module relocated into a copy (CopyPages set) into kernel pages, one
    per page of the image, made from the page's own contents when first
    written. }
  TRelocationWriter = record
    Space: PAddressSpace;
    PageAddress: QWord;
    Window: PByte;
    Module: PLoadedModule;
    Image: TImageFile;
    CopyPages: PQWord;
  end;
  PRelocationWriter = ^TRelocationWriter;

procedure BeginRelocationWriting(out Writer: TRelocationWriter; Space: PAddressSpace);
begin
  FillMemory(@Writer, SizeOf(Writer), 0);
  Writer.Space := Space;
  Writer.PageAddress := High(QWord);
end;

{ The kernel page standing for page PageIndex of the module's image,
  made now (with what the page holds before relocation) if it is not
  there yet. }
function CopyPageFor(var Writer: TRelocationWriter; PageIndex: QWord; out Page: PByte): LongInt;
var
  Physical: TPhysicalAddress;
  FileOffset: QWord;
  Length: QWord;
begin
  Page := nil;
  if (PageIndex >= Writer.Module^.ImagePageCount) or (Writer.Module^.RelocatedPages[PageIndex] = 0) then
    Exit(ErrorBadExecutable);
  if Writer.CopyPages[PageIndex] = 0 then
  begin
    Physical := AllocateZeroedPhysicalPage(PageUsageProgramImage);
    if Physical = 0 then
      Exit(ErrorOutOfMemory);
    Writer.CopyPages[PageIndex] := Physical;
    case ClassifyPage(Writer.Image, PageIndex, FileOffset) of
      PageSourceFile:
        begin
          Length := PageSize;
          if Writer.Image.Size - FileOffset < Length then
            Length := Writer.Image.Size - FileOffset;
          Result := ReadMappedFileBytes(Writer.Image.MappedFile, FileOffset, PhysicalToVirtual(Physical), Length);
          if Result <> ErrorNone then
            Exit;
        end;
      PageSourceBuilt:
        CopyMemory(PhysicalToVirtual(Physical), PhysicalToVirtual(Writer.Image.Section^.BuiltPages[PageIndex]),
          PageSize);
      PageSourceZero: ;
    else
      Exit(ErrorBadExecutable);
    end;
  end;
  Page := PByte(PhysicalToVirtual(Writer.CopyPages[PageIndex]));
  Result := ErrorNone;
end;

function WriteIntoCopy(var Writer: TRelocationWriter; Target: QWord; Data: PByte; Size: QWord): LongInt;
var
  Page: PByte;
  Chunk: QWord;
begin
  Result := ErrorNone;
  while Size > 0 do
  begin
    if Target < Writer.Module^.ImageStart then
      Exit(ErrorBadExecutable);
    Result := CopyPageFor(Writer, (RoundDownToPage(Target) - Writer.Module^.ImageStart) div PageSize, Page);
    if Result <> ErrorNone then
      Exit;
    Chunk := PageSize - (Target and PageOffsetMask);
    if Chunk > Size then
      Chunk := Size;
    CopyMemory(Page + (Target and PageOffsetMask), Data, Chunk);
    Target := Target + Chunk;
    Data := Data + Chunk;
    Size := Size - Chunk;
  end;
end;

function WriteRelocatedValue(var Writer: TRelocationWriter; Target: QWord; Data: Pointer;
  Size: QWord): LongInt;
begin
  if Writer.CopyPages <> nil then
    Exit(WriteIntoCopy(Writer, Target, PByte(Data), Size));
  { A value across a page boundary takes the general path. }
  if RoundDownToPage(Target) <> RoundDownToPage(Target + Size - 1) then
    Exit(WriteIntoImage(Writer.Space, Target, Data, Size));
  if RoundDownToPage(Target) <> Writer.PageAddress then
  begin
    Result := WritablePageWindow(Writer.Space, Target, Writer.Window);
    if Result <> ErrorNone then
    begin
      Writer.PageAddress := High(QWord);
      Exit;
    end;
    Writer.PageAddress := RoundDownToPage(Target);
  end;
  CopyMemory(Writer.Window + (Target - Writer.PageAddress), Data, Size);
  Result := ErrorNone;
end;

{ A TLS descriptor: libsystem's resolver (the static one, or the dynamic
  one for a module whose blocks the runtime makes) and Argument. }
function WriteTlsDescriptor(List: PModuleList; var Writer: TRelocationWriter; Target, Argument: QWord;
  IsDynamic: Boolean): LongInt;
var
  Descriptor: array[0..1] of QWord;
  ResolverSize: QWord;
  ResolverModule: PLoadedModule;
  ResolverName: PChar;
begin
  if IsDynamic then
    ResolverName := TlsDynamicDescriptorResolverName
  else
    ResolverName := TlsDescriptorResolverName;
  if (ResolverName = nil) or (ResolverName^ = #0) or
     not ResolveSymbol(List, ResolverName, Descriptor[0], ResolverSize, nil, ResolverModule) then
    Exit(ErrorBadExecutable);
  Descriptor[1] := Argument;
  Result := WriteRelocatedValue(Writer, Target, @Descriptor[0], SizeOf(Descriptor));
end;

{ The bytes a relocation of Kind writes. }
function RelocationWriteSize(Kind: TRelocationKind; SymbolSize: QWord): QWord;
begin
  case Kind of
    RelocationKindNone: Result := 0;
    RelocationKindThreadPointerOffset32: Result := SizeOf(LongWord);
    RelocationKindTlsDescriptor: Result := 2 * SizeOf(QWord);
    RelocationKindCopy: Result := SymbolSize;
  else
    Result := SizeOf(QWord);
  end;
end;

{ --- Symbol resolutions -------------------------------------------------

  A module relocated into a copy first resolves every symbol its
  relocations name, once each. The resolutions, with the load bias and
  the thread-local storage placements, are the key its relocated copy
  is kept under: a later load with the same key would write exactly
  the same bytes, so it maps the copy instead. }

type
  { One symbol's resolution, as it goes into the key. }
  TSymbolResolution = packed record
    SymbolIndex: LongWord;
    Found: LongWord;
    { The symbol's address, or for a thread-local one its offset in the
      defining module's block. }
    Address: QWord;
    Size: QWord;
    { The defining module's TLS placement (TlsPlacementWord). }
    TlsWord: QWord;
  end;
  PSymbolResolution = ^TSymbolResolution;

  TResolutionKeyHeader = packed record
    Bias: QWord;
    OwnTlsWord: QWord;
    StaticResolver: QWord;
    DynamicResolver: QWord;
    ResolutionCount: QWord;
  end;
  PResolutionKeyHeader = ^TResolutionKeyHeader;

  TResolutionTable = record
    { Per symbol index, its entry, or -1. }
    SlotOf: PLongInt;
    { The key: a header and Count entries. }
    Key: PByte;
    KeyLength: QWord;
    Entries: PSymbolResolution;
    { Per entry, the module that defines the symbol (nil if none). }
    Definers: ^PLoadedModule;
    Count: LongWord;
  end;
  PResolutionTable = ^TResolutionTable;

const
  TlsPlacementStatic = QWord(1) shl 60;
  TlsPlacementDynamic = QWord(2) shl 60;

{ Where a module's TLS block is, as one word (0: it has none). }
function TlsPlacementWord(Module: PLoadedModule): QWord;
begin
  if (Module = nil) or not Module^.HasThreadLocalStorage then
    Exit(0);
  if Module^.HasDynamicTls then
    Result := TlsPlacementDynamic or QWord(Module^.Handle)
  else
    Result := TlsPlacementStatic or Module^.TlsOffset;
end;

procedure FreeResolutionTable(var Table: TResolutionTable);
begin
  FreeKernelMemory(Table.SlotOf);
  FreeKernelMemory(Table.Key);
  FreeKernelMemory(Table.Definers);
  FillMemory(@Table, SizeOf(Table), 0);
end;

function ResolverAddress(List: PModuleList; Name: PChar): QWord;
var
  Size: QWord;
  Defining: PLoadedModule;
begin
  Result := 0;
  if (Name = nil) or (Name^ = #0) or not ResolveSymbol(List, Name, Result, Size, nil, Defining) then
    Result := 0;
end;

{ Resolves every symbol Module's relocations name and builds the key. }
function BuildResolutionTable(List: PModuleList; Module: PLoadedModule; out Table: TResolutionTable): LongInt;
var
  Relocation: PElf64Rela;
  Index: QWord;
  SymbolIndex: LongWord;
  Count: LongWord;
  Header: PResolutionKeyHeader;
  Entry: PSymbolResolution;
  Symbol: PElf64Symbol;
  Defining: PLoadedModule;
  Found: Boolean;
begin
  FillMemory(@Table, SizeOf(Table), 0);
  Table.SlotOf := PLongInt(AllocateKernelMemory((QWord(Module^.SymbolCount) + 1) * SizeOf(LongInt)));
  if Table.SlotOf = nil then
    Exit(ErrorOutOfMemory);
  FillMemory(Table.SlotOf, (QWord(Module^.SymbolCount) + 1) * SizeOf(LongInt), $FF);
  Count := 0;
  Index := 0;
  while Index < Module^.RelocationCount do
  begin
    Relocation := PElf64Rela(Module^.Relocations) + Index;
    SymbolIndex := RelocationSymbolIndex(Relocation^);
    if (SymbolIndex <> 0) and (ClassifyRelocation(RelocationType(Relocation^)) <> RelocationKindNone) then
    begin
      if SymbolIndex >= Module^.SymbolCount then
      begin
        FreeResolutionTable(Table);
        Exit(ErrorBadExecutable);
      end;
      if Table.SlotOf[SymbolIndex] < 0 then
      begin
        Table.SlotOf[SymbolIndex] := LongInt(Count);
        Inc(Count);
      end;
    end;
    Inc(Index);
  end;

  Table.Count := Count;
  Table.KeyLength := SizeOf(TResolutionKeyHeader) + QWord(Count) * SizeOf(TSymbolResolution);
  Table.Key := PByte(AllocateZeroedKernelMemory(Table.KeyLength));
  Table.Definers := AllocateZeroedKernelMemory((QWord(Count) + 1) * SizeOf(Pointer));
  if (Table.Key = nil) or (Table.Definers = nil) then
  begin
    FreeResolutionTable(Table);
    Exit(ErrorOutOfMemory);
  end;
  Header := PResolutionKeyHeader(Table.Key);
  Header^.Bias := Module^.Base;
  Header^.OwnTlsWord := TlsPlacementWord(Module);
  Header^.StaticResolver := ResolverAddress(List, TlsDescriptorResolverName);
  Header^.DynamicResolver := ResolverAddress(List, TlsDynamicDescriptorResolverName);
  Header^.ResolutionCount := Count;
  Table.Entries := PSymbolResolution(Table.Key + SizeOf(TResolutionKeyHeader));

  SymbolIndex := 1;
  while SymbolIndex < Module^.SymbolCount do
  begin
    if Table.SlotOf[SymbolIndex] >= 0 then
    begin
      Entry := Table.Entries + Table.SlotOf[SymbolIndex];
      Symbol := SymbolAt(Module, SymbolIndex);
      Entry^.SymbolIndex := SymbolIndex;
      Found := ResolveSymbol(List, SymbolName(Module, Symbol), Entry^.Address, Entry^.Size, nil, Defining);
      if not Found then
      begin
        if SymbolBinding(Symbol^) <> SymbolBindingWeak then
        begin
          FreeResolutionTable(Table);
          Exit(ErrorBadExecutable); { an undefined symbol }
        end;
        Entry^.Address := 0;
        Entry^.Size := 0;
        Defining := nil;
      end;
      Entry^.Found := Ord(Found);
      Entry^.TlsWord := TlsPlacementWord(Defining);
      Table.Definers[Table.SlotOf[SymbolIndex]] := Defining;
    end;
    Inc(SymbolIndex);
  end;
  Result := ErrorNone;
end;

function ApplyRelocation(const LoadTarget: TLoadTarget; Module: PLoadedModule; const Relocation: TElf64Rela;
  var Writer: TRelocationWriter; Table: PResolutionTable): LongInt;
var
  List: PModuleList;
  Kind: TRelocationKind;
  SymbolIndex: LongWord;
  Symbol: PElf64Symbol;
  SymbolAddress: QWord;
  SymbolSize: QWord;
  Value: QWord;
  Target: QWord;
  CopyBuffer: Pointer;
  DefiningModule: PLoadedModule;
  Value32: LongWord;
  Slot: LongInt;
begin
  List := ModuleList(LoadTarget);
  { Without a symbol, a TLS relocation refers to the module's own block. }
  DefiningModule := Module;
  Kind := ClassifyRelocation(RelocationType(Relocation));
  SymbolIndex := RelocationSymbolIndex(Relocation);
  Target := Module^.Base + Relocation.Offset;
  SymbolAddress := 0;
  SymbolSize := 0;

  if (SymbolIndex <> 0) and (Table <> nil) and (Kind <> RelocationKindNone) and (Kind <> RelocationKindCopy) then
  begin
    { Resolved once already (BuildResolutionTable). }
    Slot := Table^.SlotOf[SymbolIndex];
    SymbolAddress := Table^.Entries[Slot].Address;
    SymbolSize := Table^.Entries[Slot].Size;
    DefiningModule := Table^.Definers[Slot];
  end
  else if SymbolIndex <> 0 then
  begin
    if SymbolIndex >= Module^.SymbolCount then
      Exit(ErrorBadExecutable);
    Symbol := SymbolAt(Module, SymbolIndex);
    { A copy relocation must take the data from another module. }
    if Kind = RelocationKindCopy then
    begin
      if not ResolveSymbol(List, SymbolName(Module, Symbol), SymbolAddress, SymbolSize, Module,
        DefiningModule) then
        Exit(ErrorBadExecutable);
    end
    else if not ResolveSymbol(List, SymbolName(Module, Symbol), SymbolAddress, SymbolSize, nil,
      DefiningModule) then
    begin
      if SymbolBinding(Symbol^) <> SymbolBindingWeak then
        Exit(ErrorBadExecutable); { an undefined symbol }
      SymbolAddress := 0;
    end;
  end;

  { What a relocation writes lies in its module's own image, and what a
    copy relocation copies in the defining module's. }
  if Kind = RelocationKindNone then
    Exit(ErrorNone);
  if not RangeInModule(Module, Target, RelocationWriteSize(Kind, SymbolSize)) then
    Exit(ErrorBadExecutable);
  if (Kind = RelocationKindCopy) and
     ((DefiningModule = nil) or not RangeInModule(DefiningModule, SymbolAddress, SymbolSize)) then
    Exit(ErrorBadExecutable);

  case Kind of
    RelocationKindRelative:
      Value := Module^.Base + QWord(Relocation.Addend);
    RelocationKindAbsolute64:
      Value := SymbolAddress + QWord(Relocation.Addend);
    RelocationKindSymbol:
      Value := SymbolAddress;
    RelocationKindTlsModule, RelocationKindTlsOffset, RelocationKindThreadPointerOffset64:
      begin
        Result := ThreadLocalRelocationValue(Kind, DefiningModule,
          SymbolAddress + QWord(Relocation.Addend), Value);
        if Result <> ErrorNone then
          Exit;
      end;
    RelocationKindTlsDescriptor:
      begin
        Result := ThreadLocalRelocationValue(Kind, DefiningModule,
          SymbolAddress + QWord(Relocation.Addend), Value);
        if Result <> ErrorNone then
          Exit;
        Exit(WriteTlsDescriptor(List, Writer, Target, Value, DefiningModule^.HasDynamicTls));
      end;
    RelocationKindThreadPointerOffset32:
      begin
        Result := ThreadLocalRelocationValue(Kind, DefiningModule,
          SymbolAddress + QWord(Relocation.Addend), Value);
        if Result <> ErrorNone then
          Exit;
        Value32 := LongWord(Value);
        Exit(WriteRelocatedValue(Writer, Target, @Value32, SizeOf(Value32)));
      end;
    RelocationKindCopy:
      begin
        CopyBuffer := AllocateKernelMemory(SymbolSize);
        if (SymbolSize > 0) and (CopyBuffer = nil) then
          Exit(ErrorOutOfMemory);
        Result := ReadFromAddressSpace(LoadTarget.Space, SymbolAddress, CopyBuffer, SymbolSize);
        if Result = ErrorNone then
          Result := WriteIntoImage(LoadTarget.Space, Target, CopyBuffer, SymbolSize);
        FreeKernelMemory(CopyBuffer);
        Exit;
      end;
  else
    Exit(ErrorBadExecutable);
  end;

  Result := WriteRelocatedValue(Writer, Target, @Value, SizeOf(Value));
end;

{ --- Relocated copies --------------------------------------------------- }

function PlanRelocatedPages(Module: PLoadedModule; const Image: TImageFile): LongInt;
var
  Index: QWord;
  Relocation: PElf64Rela;
  Kind: TRelocationKind;
  First: QWord;
  Last: QWord;
  Page: QWord;
  FileOffset: QWord;
begin
  Result := ErrorNone;
  Module^.ImagePageCount := Image.Section^.PageCount;
  if Module^.RelocationCount = 0 then
    Exit;
  Module^.RelocatedPages := PByte(AllocateZeroedKernelMemory(Module^.ImagePageCount));
  if Module^.RelocatedPages = nil then
    Exit(ErrorOutOfMemory);
  Index := 0;
  while Index < Module^.RelocationCount do
  begin
    Relocation := PElf64Rela(Module^.Relocations) + Index;
    Kind := ClassifyRelocation(RelocationType(Relocation^));
    { Copy relocations read the process's memory: such a module (a
      program linked for a fixed address) is relocated in the process.
      So is one with a value outside its image: it fails to load there. }
    if (Kind = RelocationKindCopy) or (Kind = RelocationKindUnsupported) or
       (Relocation^.Offset < Image.Section^.LowestPage) or
       (Relocation^.Offset - Image.Section^.LowestPage > Module^.ImagePageCount * PageSize) or
       (RelocationWriteSize(Kind, 0) > Module^.ImagePageCount * PageSize -
         (Relocation^.Offset - Image.Section^.LowestPage)) then
    begin
      FreeKernelMemory(Module^.RelocatedPages);
      Module^.RelocatedPages := nil;
      Exit;
    end;
    if Kind <> RelocationKindNone then
    begin
      First := (Relocation^.Offset - Image.Section^.LowestPage) div PageSize;
      Last := (Relocation^.Offset + RelocationWriteSize(Kind, 0) - 1 - Image.Section^.LowestPage) div PageSize;
      for Page := First to Last do
      begin
        if ClassifyPage(Image, Page, FileOffset) = PageSourceNone then
        begin
          FreeKernelMemory(Module^.RelocatedPages);
          Module^.RelocatedPages := nil;
          Exit;
        end;
        Module^.RelocatedPages[Page] := 1;
      end;
    end;
    Inc(Index);
  end;
  Module^.UsesRelocatedCopies := True;
end;

{ Maps the relocated pages (CopyPages[Index] for page Index, or none)
  into the process; they were left unmapped when the module was. }
function InstallRelocatedPages(Space: PAddressSpace; Module: PLoadedModule; const Image: TImageFile;
  PageCount: QWord; PageIndices, Pages: PQWord): LongInt;
var
  Index: QWord;
begin
  Result := ErrorNone;
  Index := 0;
  while (Index < PageCount) and (Result = ErrorNone) do
  begin
    Result := MapSharedPage(Space, Module^.ImageStart + PageIndices[Index] * PageSize, Pages[Index],
      PageAttributesOf(Image, PageIndices[Index]));
    Inc(Index);
  end;
end;

{ Every planned page made (relocations write each, but a page is never
  left without one) and listed: Indices and Pages, kernel arrays. }
function CollectCopyPages(var Writer: TRelocationWriter; out Count: QWord; out Indices, Pages: PQWord): LongInt;
var
  Index: QWord;
  Page: PByte;
begin
  Count := 0;
  Indices := nil;
  Pages := nil;
  Index := 0;
  while Index < Writer.Module^.ImagePageCount do
  begin
    if Writer.Module^.RelocatedPages[Index] <> 0 then
    begin
      Result := CopyPageFor(Writer, Index, Page);
      if Result <> ErrorNone then
        Exit;
      Inc(Count);
    end;
    Inc(Index);
  end;
  Indices := PQWord(AllocateKernelMemory((Count + 1) * SizeOf(QWord)));
  Pages := PQWord(AllocateKernelMemory((Count + 1) * SizeOf(QWord)));
  if (Indices = nil) or (Pages = nil) then
  begin
    FreeKernelMemory(Indices);
    FreeKernelMemory(Pages);
    Indices := nil;
    Pages := nil;
    Exit(ErrorOutOfMemory);
  end;
  Count := 0;
  Index := 0;
  while Index < Writer.Module^.ImagePageCount do
  begin
    if Writer.CopyPages[Index] <> 0 then
    begin
      Indices[Count] := Index;
      Pages[Count] := Writer.CopyPages[Index];
      Writer.CopyPages[Index] := 0;
      Inc(Count);
    end;
    Inc(Index);
  end;
  Result := ErrorNone;
end;

procedure FreeCopyPages(var Writer: TRelocationWriter);
var
  Index: QWord;
begin
  if Writer.CopyPages = nil then
    Exit;
  Index := 0;
  while Index < Writer.Module^.ImagePageCount do
  begin
    if Writer.CopyPages[Index] <> 0 then
      FreePhysicalPage(Writer.CopyPages[Index]);
    Inc(Index);
  end;
  FreeKernelMemory(Writer.CopyPages);
  Writer.CopyPages := nil;
end;

{ Relocates Module into kernel pages and maps them; keeps them as a
  relocated copy of its section unless it is a program at a random
  address (it would never be at that address again). }
function RelocateIntoCopy(const Target: TLoadTarget; Module: PLoadedModule; const Image: TImageFile;
  var Table: TResolutionTable): LongInt;
var
  Writer: TRelocationWriter;
  Index: QWord;
  Count: QWord;
  Indices: PQWord;
  Pages: PQWord;
  Copy: PRelocatedCopy;
  Keep: Boolean;
begin
  BeginRelocationWriting(Writer, Target.Space);
  Writer.Module := Module;
  Writer.Image := Image;
  Writer.CopyPages := PQWord(AllocateZeroedKernelMemory(Module^.ImagePageCount * SizeOf(QWord)));
  if Writer.CopyPages = nil then
    Exit(ErrorOutOfMemory);
  Result := ErrorNone;
  Index := 0;
  while (Index < Module^.RelocationCount) and (Result = ErrorNone) do
  begin
    Result := ApplyRelocation(Target, Module, PElf64Rela(Module^.Relocations)[Index], Writer, @Table);
    Inc(Index);
  end;
  if Result = ErrorNone then
    Result := CollectCopyPages(Writer, Count, Indices, Pages);
  FreeCopyPages(Writer);
  if Result <> ErrorNone then
    Exit;
  Result := InstallRelocatedPages(Target.Space, Module, Image, Count, Indices, Pages);
  Keep := (Result = ErrorNone) and ((Module^.Handle <> 0) or not Target.Space^.Layout.IsRandomized);
  Copy := nil;
  if Keep then
    Copy := CreateRelocatedCopy(Module^.Base, Table.Key, Table.KeyLength, Count, Indices, Pages);
  if Copy <> nil then
  begin
    { The copy took the key and the pages. }
    Table.Key := nil;
    Table.Entries := nil;
    KeepRelocatedCopy(PImageSection(Module^.Section), Copy);
    AtomicIncrement(RelocatedCopyCounters.Kept);
    Exit;
  end;
  { Not kept: the process's references are all the pages have now. }
  Index := 0;
  while Index < Count do
  begin
    FreePhysicalPage(Pages[Index]);
    Inc(Index);
  end;
  FreeKernelMemory(Indices);
  FreeKernelMemory(Pages);
  if Result = ErrorNone then
    AtomicIncrement(RelocatedCopyCounters.NotKept);
end;

{ A module whose relocated pages come from a copy: the kept one that
  matches, or one made now. }
function RelocateFromCopy(const Target: TLoadTarget; Module: PLoadedModule): LongInt;
var
  Image: TImageFile;
  Table: TResolutionTable;
  Copy: PRelocatedCopy;
begin
  UseSection(PImageSection(Module^.Section), Image);
  Result := BuildResolutionTable(ModuleList(Target), Module, Table);
  if Result <> ErrorNone then
    Exit;
  Copy := FindRelocatedCopy(PImageSection(Module^.Section), Module^.Base, Table.Key, Table.KeyLength);
  if Copy <> nil then
  begin
    Result := InstallRelocatedPages(Target.Space, Module, Image, Copy^.PageCount, Copy^.PageIndices, Copy^.Pages);
    ReleaseRelocatedCopy(Copy);
    if Result = ErrorNone then
      AtomicIncrement(RelocatedCopyCounters.Reused);
  end
  else
    Result := RelocateIntoCopy(Target, Module, Image, Table);
  FreeResolutionTable(Table);
end;

{ Relocates in the process itself (a module with copy relocations). }
function RelocateInProcess(const Target: TLoadTarget; Module: PLoadedModule): LongInt;
var
  RelocationIndex: QWord;
  Writer: TRelocationWriter;
begin
  Result := ErrorNone;
  RelocationIndex := 0;
  BeginRelocationWriting(Writer, Target.Space);
  while (RelocationIndex < Module^.RelocationCount) and (Result = ErrorNone) do
  begin
    Result := ApplyRelocation(Target, Module, PElf64Rela(Module^.Relocations)[RelocationIndex], Writer, nil);
    Inc(RelocationIndex);
  end;
end;

procedure FinishRelocation(Module: PLoadedModule);
begin
  FreeKernelMemory(Module^.Relocations);
  Module^.Relocations := nil;
  Module^.RelocationCount := 0;
  FreeKernelMemory(Module^.RelocatedPages);
  Module^.RelocatedPages := nil;
  if Module^.Section <> nil then
    ReleaseImageSection(PImageSection(Module^.Section));
  Module^.Section := nil;
  Module^.IsRelocated := True;
end;

{ Relocates the modules not relocated yet: first those relocated from
  copies, then those relocated in the process, whose copy relocations
  read the others' data (as relocated). }
function RelocatePendingModules(const Target: TLoadTarget): LongInt;
var
  List: PModuleList;
  ModuleIndex: Integer;
  Module: PLoadedModule;
  Pass: Integer;
begin
  List := ModuleList(Target);
  for Pass := 0 to 1 do
    for ModuleIndex := 0 to List^.Count - 1 do
    begin
      Module := List^.Modules[ModuleIndex];
      if Module^.IsRelocated or (Module^.UsesRelocatedCopies <> (Pass = 0)) then
        Continue;
      if Module^.UsesRelocatedCopies then
        Result := RelocateFromCopy(Target, Module)
      else
        Result := RelocateInProcess(Target, Module);
      if Result <> ErrorNone then
        Exit;
      FinishRelocation(Module);
    end;
  Result := ErrorNone;
end;

{ --- The static TLS surplus ---------------------------------------------- }

{ The program is loaded: the static area gets its surplus. }
procedure ReserveStaticTlsSurplus(List: PModuleList);
begin
  List^.SurplusCursor := List^.StaticTlsSize;
  List^.StaticTlsSize := List^.StaticTlsSize + StaticTlsSurplusBytes;
  if List^.StaticTlsAlignment < StaticTlsSurplusAlignment then
    List^.StaticTlsAlignment := StaticTlsSurplusAlignment;
end;

procedure GetThreadRegionLayout(List: PModuleList; out RegionSize, ThreadPointerOffset: QWord);
var
  Alignment: QWord;
  StaticTlsSize: QWord;
begin
  Alignment := MinimumThreadPointerAlignment;
  StaticTlsSize := 0;
  if List <> nil then
  begin
    if List^.StaticTlsAlignment > Alignment then
      Alignment := List^.StaticTlsAlignment;
    StaticTlsSize := List^.StaticTlsSize;
  end;
  LayOutThreadRegion(StaticTlsSize, Alignment, RegionSize, ThreadPointerOffset);
end;

{ Gives Module's surplus block its initial contents (Image, ImageSize
  bytes, then zeros) in every thread data region of the space: every
  thread the process has (the layout of those regions has not changed
  since the program was loaded). }
function FillSurplusBlockOfThreads(Space: PAddressSpace; List: PModuleList; Module: PLoadedModule;
  Image: Pointer): LongInt;
var
  RegionSize: QWord;
  ThreadPointerOffset: QWord;
  Address: QWord;
  Start: QWord;
  Length: QWord;
  Block: QWord;
begin
  Result := ErrorNone;
  GetThreadRegionLayout(List, RegionSize, ThreadPointerOffset);
  Address := 0;
  while FindRegionOfKind(Space, RegionKindThreadData, Address, Start, Length) do
  begin
    Address := Start + Length;
    if Length <> RoundUpToPage(RegionSize) then
      Continue;
    Block := QWord(Int64(Start + ThreadPointerOffset) + TlsBlockDisplacement(Module^.TlsOffset));
    if Module^.TlsImageSize > 0 then
      Result := WriteIntoAddressSpace(Space, Block, Image, Module^.TlsImageSize);
    if (Result = ErrorNone) and (Module^.TlsSize > Module^.TlsImageSize) then
      Result := WriteIntoAddressSpace(Space, Block + Module^.TlsImageSize, nil,
        Module^.TlsSize - Module^.TlsImageSize);
    if Result <> ErrorNone then
      Exit;
  end;
end;

{ The libraries just loaded (from FirstNew) with surplus blocks: every
  thread gets its block (the TLS image read from the relocated module). }
function FillSurplusBlocks(const Target: TLoadTarget; FirstNew: Integer): LongInt;
var
  List: PModuleList;
  Index: Integer;
  Module: PLoadedModule;
  Image: Pointer;
begin
  Result := ErrorNone;
  List := ModuleList(Target);
  for Index := FirstNew to List^.Count - 1 do
  begin
    Module := List^.Modules[Index];
    if not Module^.HasSurplusTls then
      Continue;
    Image := nil;
    if Module^.TlsImageSize > 0 then
    begin
      Image := AllocateKernelMemory(Module^.TlsImageSize);
      if Image = nil then
        Exit(ErrorOutOfMemory);
      Result := ReadFromAddressSpace(Target.Space, Module^.TlsImageAddress, Image, Module^.TlsImageSize);
    end;
    if Result = ErrorNone then
      Result := FillSurplusBlockOfThreads(Target.Space, List, Module, Image);
    FreeKernelMemory(Image);
    if Result <> ErrorNone then
      Exit;
  end;
end;

{ --- Public routines ------------------------------------------------- }

function LoadProgramImage(const Target: TLoadTarget; ProgramFile: POpenFile; KernelPath: PChar;
  out MainModule: PLoadedModule): LongInt;
var
  ModuleIndex: Integer;
begin
  MainModule := nil;
  if ProgramFile = nil then
    Exit(ErrorNotFound);
  Result := LoadModule(Target, ProgramFile, KernelPath, True, False, ModuleIndex);
  if Result = ErrorNone then
    Result := RelocatePendingModules(Target);
  if Result = ErrorNone then
  begin
    MainModule := ModuleList(Target)^.Modules[ModuleIndex];
    ReserveStaticTlsSurplus(ModuleList(Target));
    ModuleList(Target)^.StartupComplete := True;
  end;
end;

function InterpreterOf(const Target: TLoadTarget; MainModule: PLoadedModule): PLoadedModule;
begin
  if (MainModule = nil) or (MainModule^.InterpreterModule < 0) then
    Exit(nil);
  Result := ModuleList(Target)^.Modules[MainModule^.InterpreterModule];
end;

{ Takes back the modules from FirstIndex on (a library load that
  failed: a module that cannot be relocated must not stay half loaded,
  nor be tried again by the next load) with the regions they mapped. }
procedure UnloadModulesFrom(const Target: TLoadTarget; FirstIndex: Integer);
var
  List: PModuleList;
  Module: PLoadedModule;
begin
  List := ModuleList(Target);
  while List^.Count > FirstIndex do
  begin
    Module := List^.Modules[List^.Count - 1];
    ReleaseImageRegions(Target.Space, Module^.ImageStart, Module^.ImageEnd, Module^.LoadTag);
    FreeModule(Module);
    List^.Modules[List^.Count - 1] := nil;
    Dec(List^.Count);
  end;
end;

function LoadLibraryImage(const Target: TLoadTarget; LibraryFile: POpenFile; KernelPath: PChar;
  out ModuleHandle: Integer): LongInt;
var
  Existing: Integer;
  FirstNew: Integer;
  SurplusCursor: QWord;
begin
  ModuleHandle := -1;
  if LibraryFile = nil then
    Exit(ErrorNotFound);
  Existing := FindModuleByName(ModuleList(Target), FileNameOf(KernelPath));
  if Existing >= 0 then
  begin
    ModuleHandle := Existing;
    Exit(ErrorNone);
  end;
  FirstNew := ModuleList(Target)^.Count;
  SurplusCursor := ModuleList(Target)^.SurplusCursor;
  Result := LoadModule(Target, LibraryFile, KernelPath, False, False, ModuleHandle);
  if Result = ErrorNone then
    Result := RelocatePendingModules(Target);
  if Result = ErrorNone then
    Result := FillSurplusBlocks(Target, FirstNew);
  if Result <> ErrorNone then
  begin
    UnloadModulesFrom(Target, FirstNew);
    { Nothing uses the surplus they took. }
    ModuleList(Target)^.SurplusCursor := SurplusCursor;
    ModuleHandle := -1;
  end;
end;

function FindSymbolInModuleTree(List: PModuleList; ModuleHandle: Integer; Name: PChar;
  Depth: Integer; out Address: QWord): Boolean;
var
  Module: PLoadedModule;
  Symbol: PElf64Symbol;
  NeededIndex: Integer;
begin
  Address := 0;
  if (ModuleHandle < 0) or (ModuleHandle >= List^.Count) or (Depth > MaximumModules) then
    Exit(False);
  Module := List^.Modules[ModuleHandle];
  if FindDefinedSymbol(Module, Name, ElfHash(Name), Symbol) then
  begin
    Address := Module^.Base + Symbol^.Value;
    Exit(True);
  end;
  { Like dlsym, also look in the libraries the module depends on. The
    depth limit stops dependency cycles. }
  for NeededIndex := 0 to Module^.NeededCount - 1 do
  begin
    if FindSymbolInModuleTree(List, Module^.Needed[NeededIndex], Name, Depth + 1, Address) then
      Exit(True);
  end;
  Result := False;
end;

function FindExportedSymbol(Process: PProcess; ModuleHandle: Integer; Name: PChar;
  out Address: QWord): LongInt;
var
  List: PModuleList;
begin
  Address := 0;
  List := ModuleList(ProcessLoadTarget(Process));
  if (List = nil) or (ModuleHandle < 0) or (ModuleHandle >= List^.Count) then
    Exit(ErrorBadHandle);
  if FindSymbolInModuleTree(List, ModuleHandle, Name, 0, Address) then
    Result := ErrorNone
  else
    Result := ErrorNotFound;
end;

procedure ReleaseModuleList(var Modules: Pointer);
var
  List: PModuleList;
  Index: Integer;
begin
  List := PModuleList(Modules);
  if List = nil then
    Exit;
  Modules := nil;
  for Index := 0 to List^.Count - 1 do
    FreeModule(List^.Modules[Index]);
  FreeKernelMemory(List);
end;

procedure ReleaseModules(Process: PProcess);
begin
  ReleaseModuleList(Process^.Modules);
end;

end.
