{
  Program and shared library loader.

  Programs and libraries are ELF files produced by an ordinary toolchain:
  position independent executables and shared objects with a dynamic
  section listing the libraries they need (DT_NEEDED), their symbols and
  their relocations. Loading a program means:

    1. Map the program's loadable segments into the process.
    2. For every needed library not loaded yet, find it in /lib of the
       system volume and map it at the next free library address; repeat
       for its own needs.
    3. Apply every relocation of every newly loaded module. Symbols are
       looked up in load order (the program first, then libraries in the
       order they were loaded), the same "global scope" rule a Unix
       dynamic linker uses. All symbols are bound immediately.

  LoadLibraryImage does steps 2 and 3 for a library requested at run time
  (dlopen), and FindExportedSymbol looks a symbol up in it (dlsym).

  Thread-local storage (PT_TLS) uses the static model of x86-64 variant
  II: the TLS blocks of the program and of the libraries loaded with it
  sit at fixed negative offsets from each thread's thread pointer, in
  load order (the program's block nearest to it, as the linker expects).
  The layout is fixed once the program is loaded; a library with a TLS
  segment (or with initializers, which only the startup code runs) can
  then no longer be loaded and LoadLibraryImage returns ErrorUnsupported.
  Processes.ThreadStorage builds each thread's copy of the blocks.

  The "module id" of a TLS relocation (DTPMOD64) is the module's offset
  from the thread pointer, so __tls_get_addr in libsystem simply adds the
  thread pointer, that offset and the variable's offset.

  Each module keeps kernel copies of its symbol, string and hash tables
  so symbols can be found later without touching user memory.
}
unit Processes.ImageLoader;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.Process;

const
  MaximumModules = 32;
  ModuleNameLength = 64;
  MaximumNeededLibraries = 16;

type
  PLoadedModule = ^TLoadedModule;
  TLoadedModule = record
    Name: array[0..ModuleNameLength - 1] of Char;
    Base: QWord;
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

    { Initializers and finalizers (user addresses; 0 if absent). }
    InitFunction: QWord;
    InitArray: QWord;
    InitArrayCount: QWord;
    FiniFunction: QWord;
    FiniArray: QWord;
    FiniArrayCount: QWord;
  end;

  PModuleList = ^TModuleList;
  TModuleList = record
    Modules: array[0..MaximumModules - 1] of PLoadedModule;
    Count: Integer;
    { The static TLS area every thread gets below its thread pointer. }
    StaticTlsSize: QWord;
    StaticTlsAlignment: QWord;
    { Set once the program is loaded: the layout can no longer change. }
    StartupComplete: Boolean;
  end;

{ All routines return 0 on success or an Abi error code. }

function LoadProgramImage(Process: PProcess; KernelPath: PChar; out MainModule: PLoadedModule): LongInt;
function LoadLibraryImage(Process: PProcess; KernelPath: PChar; out ModuleHandle: Integer): LongInt;
function FindExportedSymbol(Process: PProcess; ModuleHandle: Integer; Name: PChar;
  out Address: QWord): LongInt;
procedure ReleaseModules(Process: PProcess);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Elf64,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.KernelHeap,
  FileSystem.Types,
  FileSystem.Files,
  Processes.AddressSpace,
  Processes.Paths;

const
  MaximumImageSize = 64 * 1024 * 1024;
  MaximumStaticTlsSize = 1024 * 1024;
  MaximumInitializers = 4096;
  LibraryDirectory = '/lib/';

type
  { An ELF file read into kernel memory while it is being loaded. }
  TImageFile = record
    Contents: PByte;
    Size: QWord;
    Header: PElf64FileHeader;
  end;

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
    NeededOffsets: array[0..MaximumNeededLibraries - 1] of QWord;
    NeededCount: Integer;
  end;

{ --- Files ----------------------------------------------------------- }

function ReadWholeFile(KernelPath: PChar; out Image: TImageFile): LongInt;
var
  OpenedFile: POpenFile;
  Information: TNodeInformation;
  Status: TFileSystemStatus;
  BytesRead: QWord;
begin
  Image.Contents := nil;
  Image.Size := 0;
  Status := OpenPath(KernelPath, OpenedFile);
  if Status <> StatusSuccess then
    Exit(ErrorNotFound);

  GetFileInformation(OpenedFile, Information);
  if (Information.Kind <> NodeKindFile) or (Information.SizeInBytes < SizeOf(TElf64FileHeader)) or
     (Information.SizeInBytes > MaximumImageSize) then
  begin
    CloseFile(OpenedFile);
    Exit(ErrorBadExecutable);
  end;

  Image.Contents := PByte(AllocateKernelMemory(Information.SizeInBytes));
  if Image.Contents = nil then
  begin
    CloseFile(OpenedFile);
    Exit(ErrorOutOfMemory);
  end;
  Status := ReadFromFile(OpenedFile, Image.Contents, Information.SizeInBytes, BytesRead);
  CloseFile(OpenedFile);
  if (Status <> StatusSuccess) or (BytesRead <> Information.SizeInBytes) then
  begin
    FreeKernelMemory(Image.Contents);
    Image.Contents := nil;
    Exit(ErrorIo);
  end;

  Image.Size := Information.SizeInBytes;
  Image.Header := PElf64FileHeader(Image.Contents);
  Result := ErrorNone;
end;

function HeaderIsValid(const Image: TImageFile): Boolean;
var
  Header: PElf64FileHeader;
begin
  Header := Image.Header;
  Result := (Header^.Magic = ElfMagic) and (Header^.FileClass = ElfClass64) and
    (Header^.DataEncoding = ElfDataLittleEndian) and (Header^.Machine = ElfMachineAmd64) and
    ((Header^.FileType = ElfTypeExecutable) or (Header^.FileType = ElfTypeSharedObject)) and
    (Header^.ProgramHeaderEntrySize = SizeOf(TElf64ProgramHeader)) and
    (Header^.ProgramHeaderOffset + QWord(Header^.ProgramHeaderCount) * SizeOf(TElf64ProgramHeader) <= Image.Size);
end;

function ProgramHeaderAt(const Image: TImageFile; Index: Integer): PElf64ProgramHeader;
begin
  Result := PElf64ProgramHeader(Image.Contents + Image.Header^.ProgramHeaderOffset +
    QWord(Index) * SizeOf(TElf64ProgramHeader));
end;

{ Finds the file data behind a virtual address (relative to the image's
  link address). Returns nil if it is not backed by the file. }
function FileDataAt(const Image: TImageFile; VirtualAddress: QWord; Length: QWord): PByte;
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
      Exit(Image.Contents + ProgramHeader^.FileOffset + OffsetInSegment);
  end;
  Result := nil;
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

function SegmentAttributes(Flags: LongWord): LongWord;
begin
  Result := RegionReadable;
  if (Flags and SegmentFlagWrite) <> 0 then
    Result := Result or RegionWritable;
  if (Flags and SegmentFlagExecute) <> 0 then
    Result := Result or RegionExecutable;
end;

{ Maps every page of the image with exactly the attributes of the
  segments covering it, creating one region per run of equal pages, and
  copies the file contents in. }
function MapSegments(Space: PAddressSpace; const Image: TImageFile; Bias: QWord;
  LowestPage, HighestPageEnd: QWord): LongInt;
var
  PageCount: QWord;
  PageAttributes: PLongWord;
  PageIndex: QWord;
  Index: Integer;
  ProgramHeader: PElf64ProgramHeader;
  FirstPage: QWord;
  LastPage: QWord;
  RunStart: QWord;
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

  { Regions for runs of pages with the same attributes; gaps between
    segments stay unmapped. }
  Result := ErrorNone;
  PageIndex := 0;
  while (PageIndex < PageCount) and (Result = ErrorNone) do
  begin
    if PageAttributes[PageIndex] = 0 then
    begin
      Inc(PageIndex);
      Continue;
    end;
    RunStart := PageIndex;
    while (PageIndex < PageCount) and (PageAttributes[PageIndex] = PageAttributes[RunStart]) do
    begin
      Result := CommitPage(Space, Bias + LowestPage + PageIndex * PageSize, PageAttributes[PageIndex]);
      if Result <> ErrorNone then
        Break;
      Inc(PageIndex);
    end;
    if Result = ErrorNone then
      Result := AddRegion(Space, Bias + LowestPage + RunStart * PageSize, (PageIndex - RunStart) * PageSize,
        PageAttributes[RunStart], RegionKindImage, False);
  end;
  FreeKernelMemory(PageAttributes);
  if Result <> ErrorNone then
    Exit;

  for Index := 0 to Image.Header^.ProgramHeaderCount - 1 do
  begin
    ProgramHeader := ProgramHeaderAt(Image, Index);
    if (ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad) or (ProgramHeader^.FileSize = 0) then
      Continue;
    if ProgramHeader^.FileOffset + ProgramHeader^.FileSize > Image.Size then
      Exit(ErrorBadExecutable);
    Result := WriteIntoAddressSpace(Space, Bias + ProgramHeader^.VirtualAddress,
      Image.Contents + ProgramHeader^.FileOffset, ProgramHeader^.FileSize);
    if Result <> ErrorNone then
      Exit;
  end;
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

{ Gives the module a place in the static TLS area, below the blocks
  placed before it. }
function PlaceThreadLocalStorage(List: PModuleList; Module: PLoadedModule;
  Segment: PElf64ProgramHeader; Bias: QWord): LongInt;
var
  Alignment: QWord;
  Offset: QWord;
begin
  Alignment := Segment^.Alignment;
  if Alignment = 0 then
    Alignment := 1;
  if ((Alignment and (Alignment - 1)) <> 0) or (Alignment > PageSize) or
     (Segment^.FileSize > Segment^.MemorySize) or (Segment^.MemorySize > MaximumStaticTlsSize) then
    Exit(ErrorBadExecutable);

  Offset := (List^.StaticTlsSize + Segment^.MemorySize + Alignment - 1) and not (Alignment - 1);
  if Offset > MaximumStaticTlsSize then
    Exit(ErrorOutOfMemory);
  Module^.HasThreadLocalStorage := True;
  Module^.TlsImageAddress := Bias + Segment^.VirtualAddress;
  Module^.TlsImageSize := Segment^.FileSize;
  Module^.TlsSize := Segment^.MemorySize;
  Module^.TlsAlignment := Alignment;
  Module^.TlsOffset := Offset;
  List^.StaticTlsSize := Offset;
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
    if ProgramHeader^.FileOffset + ProgramHeader^.FileSize > Image.Size then
      Exit(ErrorBadExecutable);

    Entry := PElf64Dynamic(Image.Contents + ProgramHeader^.FileOffset);
    EntryCount := ProgramHeader^.FileSize div SizeOf(TElf64Dynamic);
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
      end;
      Inc(EntryIndex);
    end;
    Exit(ErrorNone);
  end;
  Result := ErrorNone; { a static program without a dynamic section }
end;

{ Copies a table from the file into a new kernel buffer. }
function CopyTable(const Image: TImageFile; VirtualAddress, Length: QWord; out Copy: Pointer): Boolean;
var
  Source: PByte;
begin
  Copy := nil;
  if Length = 0 then
    Exit(True);
  Source := FileDataAt(Image, VirtualAddress, Length);
  if Source = nil then
    Exit(False);
  Copy := AllocateKernelMemory(Length);
  if Copy = nil then
    Exit(False);
  CopyMemory(Copy, Source, Length);
  Result := True;
end;

function CopyDynamicTables(Module: PLoadedModule; const Image: TImageFile;
  const Dynamic: TDynamicInformation): LongInt;
var
  HashHeader: PLongWord;
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

  HashHeader := PLongWord(FileDataAt(Image, Dynamic.Hash, 8));
  if HashHeader = nil then
    Exit(ErrorBadExecutable);
  Module^.BucketCount := HashHeader[0];
  Module^.SymbolCount := HashHeader[1];

  if not CopyTable(Image, Dynamic.Hash, 8 + 4 * (QWord(Module^.BucketCount) + Module^.SymbolCount), HashTable) then
    Exit(ErrorBadExecutable);
  Module^.Buckets := PLongWord(HashTable) + 2;
  Module^.Chains := Module^.Buckets + Module^.BucketCount;

  if not CopyTable(Image, Dynamic.SymbolTable, QWord(Module^.SymbolCount) * SizeOf(TElf64Symbol), Module^.Symbols) then
    Exit(ErrorBadExecutable);
  Module^.StringsSize := Dynamic.StringTableSize;
  if not CopyTable(Image, Dynamic.StringTable, Dynamic.StringTableSize, Pointer(Module^.Strings)) then
    Exit(ErrorBadExecutable);

  { The ordinary and the procedure linkage relocations are processed the
    same way, so they are kept in one array. }
  RelaCount := Dynamic.RelaSize div SizeOf(TElf64Rela);
  JumpCount := Dynamic.JumpRelocationsSize div SizeOf(TElf64Rela);
  Module^.RelocationCount := RelaCount + JumpCount;
  if Module^.RelocationCount > 0 then
  begin
    Module^.Relocations := AllocateKernelMemory(Module^.RelocationCount * SizeOf(TElf64Rela));
    if Module^.Relocations = nil then
      Exit(ErrorOutOfMemory);
    if not CopyTable(Image, Dynamic.Rela, Dynamic.RelaSize, RelaCopy) or
       not CopyTable(Image, Dynamic.JumpRelocations, Dynamic.JumpRelocationsSize, JumpCopy) then
      Exit(ErrorBadExecutable);
    if RelaCount > 0 then
      CopyMemory(Module^.Relocations, RelaCopy, Dynamic.RelaSize);
    if JumpCount > 0 then
      CopyMemory(PElf64Rela(Module^.Relocations) + RelaCount, JumpCopy, Dynamic.JumpRelocationsSize);
    FreeKernelMemory(RelaCopy);
    FreeKernelMemory(JumpCopy);
  end;
  Result := ErrorNone;
end;

{ --- Modules --------------------------------------------------------- }

function ModuleList(Process: PProcess): PModuleList;
begin
  if Process^.Modules = nil then
    Process^.Modules := AllocateZeroedKernelMemory(SizeOf(TModuleList));
  Result := PModuleList(Process^.Modules);
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
  if Module^.Buckets <> nil then
    FreeKernelMemory(Module^.Buckets - 2);
  FreeKernelMemory(Module^.Symbols);
  FreeKernelMemory(Module^.Strings);
  FreeKernelMemory(Module^.Relocations);
  FreeKernelMemory(Module);
end;

function LoadModule(Process: PProcess; KernelPath: PChar; IsProgram: Boolean;
  out ModuleIndex: Integer): LongInt; forward;

{ Once the program runs, the static TLS layout is fixed and nobody would
  call a new library's initializers. }
function CheckLateLoadable(List: PModuleList; const Image: TImageFile;
  const Dynamic: TDynamicInformation): LongInt;
begin
  Result := ErrorNone;
  if not List^.StartupComplete then
    Exit;
  if (FindThreadLocalSegment(Image) <> nil) or (Dynamic.InitFunction <> 0) or
     (Dynamic.InitArraySize <> 0) or (Dynamic.FiniFunction <> 0) or
     (Dynamic.FiniArraySize <> 0) or Dynamic.HasPreinitArray then
    Result := ErrorUnsupported;
end;

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
  Result := ErrorNone;
end;

{ Loads the libraries a module needs, from /lib of the system volume. }
function LoadNeededLibraries(Process: PProcess; Module: PLoadedModule;
  const Dynamic: TDynamicInformation): LongInt;
var
  NeededIndex: Integer;
  LibraryName: PChar;
  LibraryPath: array[0..ProcessPathCapacity - 1] of Char;
  Existing: Integer;
begin
  Result := ErrorNone;
  for NeededIndex := 0 to Dynamic.NeededCount - 1 do
  begin
    if Dynamic.NeededOffsets[NeededIndex] >= Module^.StringsSize then
      Exit(ErrorBadExecutable);
    LibraryName := Module^.Strings + Dynamic.NeededOffsets[NeededIndex];

    Existing := FindModuleByName(ModuleList(Process), LibraryName);
    if Existing < 0 then
    begin
      SystemVolumePath(LibraryDirectory, @LibraryPath[0], ProcessPathCapacity);
      CopyText(@LibraryPath[TextLength(@LibraryPath[0])], LibraryName,
        ProcessPathCapacity - TextLength(@LibraryPath[0]));
      Result := LoadModule(Process, @LibraryPath[0], False, Existing);
      if Result <> ErrorNone then
        Exit;
    end;
    Module^.Needed[Module^.NeededCount] := Existing;
    Inc(Module^.NeededCount);
  end;
end;

function LoadModule(Process: PProcess; KernelPath: PChar; IsProgram: Boolean;
  out ModuleIndex: Integer): LongInt;
var
  List: PModuleList;
  Image: TImageFile;
  Dynamic: TDynamicInformation;
  Module: PLoadedModule;
  LowestPage: QWord;
  HighestPageEnd: QWord;
  Bias: QWord;
  Space: PAddressSpace;
begin
  ModuleIndex := -1;
  List := ModuleList(Process);
  Space := Process^.AddressSpace;
  if List = nil then
    Exit(ErrorOutOfMemory);
  if List^.Count >= MaximumModules then
    Exit(ErrorOutOfMemory);

  Result := ReadWholeFile(KernelPath, Image);
  if Result <> ErrorNone then
    Exit;
  Module := nil;

  if not HeaderIsValid(Image) or not MeasureSpan(Image, LowestPage, HighestPageEnd) then
    Result := ErrorBadExecutable;
  if Result = ErrorNone then
    Result := ReadDynamicSection(Image, Dynamic);
  if Result = ErrorNone then
    Result := CheckLateLoadable(List, Image, Dynamic);

  { Choose where the module goes. }
  if Result = ErrorNone then
  begin
    if Image.Header^.FileType = ElfTypeExecutable then
      Bias := 0 { linked for a fixed address }
    else if IsProgram then
      Bias := UserImageBase - LowestPage
    else
    begin
      if not FindFreeRange(Space, HighestPageEnd - LowestPage, Space^.NextLibraryAddress,
        UserStackTop - UserStackReserve, Bias) then
        Result := ErrorOutOfMemory
      else
      begin
        Space^.NextLibraryAddress := Bias + (HighestPageEnd - LowestPage) + PageSize;
        Bias := Bias - LowestPage;
      end;
    end;
  end;

  if Result = ErrorNone then
    Result := MapSegments(Space, Image, Bias, LowestPage, HighestPageEnd);

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
    Module^.EntryPoint := Bias + Image.Header^.EntryPoint;
    Module^.ProgramHeaderAddress := Bias + LowestPage + Image.Header^.ProgramHeaderOffset;
    Module^.ProgramHeaderCount := Image.Header^.ProgramHeaderCount;
    Result := CopyDynamicTables(Module, Image, Dynamic);
  end;
  if Result = ErrorNone then
    Result := NoteInitializers(Module, Dynamic, Bias);
  if (Result = ErrorNone) and (FindThreadLocalSegment(Image) <> nil) then
    Result := PlaceThreadLocalStorage(List, Module, FindThreadLocalSegment(Image), Bias);

  FreeKernelMemory(Image.Contents);

  if Result <> ErrorNone then
  begin
    FreeModule(Module);
    Exit;
  end;

  { Register the module before loading its needs, so a dependency cycle
    finds it already loaded. }
  ModuleIndex := List^.Count;
  List^.Modules[List^.Count] := Module;
  Inc(List^.Count);

  Result := LoadNeededLibraries(Process, Module, Dynamic);
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

{ The TLS relocations: Offset is the variable's offset in the TLS block
  of DefiningModule. }
function ThreadLocalRelocationValue(Kind: LongWord; DefiningModule: PLoadedModule; Offset: QWord;
  out Value: QWord): LongInt;
begin
  Value := 0;
  if (DefiningModule = nil) or not DefiningModule^.HasThreadLocalStorage then
    Exit(ErrorBadExecutable);
  case Kind of
    RelocationTlsModule64:
      Value := QWord(-Int64(DefiningModule^.TlsOffset));
    RelocationTlsOffset64:
      Value := Offset;
    RelocationThreadPointerOffset64, RelocationThreadPointerOffset32:
      Value := Offset - DefiningModule^.TlsOffset;
  end;
  Result := ErrorNone;
end;

function ApplyRelocation(Process: PProcess; Module: PLoadedModule; const Relocation: TElf64Rela): LongInt;
var
  List: PModuleList;
  Kind: LongWord;
  SymbolIndex: LongWord;
  Symbol: PElf64Symbol;
  SymbolAddress: QWord;
  SymbolSize: QWord;
  Value: QWord;
  Target: QWord;
  CopyBuffer: Pointer;
  DefiningModule: PLoadedModule;
  Value32: LongWord;
begin
  List := ModuleList(Process);
  { Without a symbol, a TLS relocation refers to the module's own block. }
  DefiningModule := Module;
  Kind := RelocationType(Relocation);
  SymbolIndex := RelocationSymbolIndex(Relocation);
  Target := Module^.Base + Relocation.Offset;
  SymbolAddress := 0;
  SymbolSize := 0;

  if SymbolIndex <> 0 then
  begin
    if SymbolIndex >= Module^.SymbolCount then
      Exit(ErrorBadExecutable);
    Symbol := SymbolAt(Module, SymbolIndex);
    { A copy relocation must take the data from another module. }
    if Kind = RelocationCopy then
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

  case Kind of
    RelocationNone:
      Exit(ErrorNone);
    RelocationRelative:
      Value := Module^.Base + QWord(Relocation.Addend);
    Relocation64:
      Value := SymbolAddress + QWord(Relocation.Addend);
    RelocationGlobalData, RelocationJumpSlot:
      Value := SymbolAddress;
    RelocationTlsModule64, RelocationTlsOffset64, RelocationThreadPointerOffset64:
      begin
        Result := ThreadLocalRelocationValue(Kind, DefiningModule,
          SymbolAddress + QWord(Relocation.Addend), Value);
        if Result <> ErrorNone then
          Exit;
      end;
    RelocationThreadPointerOffset32:
      begin
        Result := ThreadLocalRelocationValue(Kind, DefiningModule,
          SymbolAddress + QWord(Relocation.Addend), Value);
        if Result <> ErrorNone then
          Exit;
        Value32 := LongWord(Value);
        Exit(WriteIntoAddressSpace(Process^.AddressSpace, Target, @Value32, SizeOf(Value32)));
      end;
    RelocationCopy:
      begin
        CopyBuffer := AllocateKernelMemory(SymbolSize);
        if (SymbolSize > 0) and (CopyBuffer = nil) then
          Exit(ErrorOutOfMemory);
        Result := ReadFromAddressSpace(Process^.AddressSpace, SymbolAddress, CopyBuffer, SymbolSize);
        if Result = ErrorNone then
          Result := WriteIntoAddressSpace(Process^.AddressSpace, Target, CopyBuffer, SymbolSize);
        FreeKernelMemory(CopyBuffer);
        Exit;
      end;
  else
    Exit(ErrorBadExecutable);
  end;

  Result := WriteIntoAddressSpace(Process^.AddressSpace, Target, @Value, SizeOf(Value));
end;

function RelocatePendingModules(Process: PProcess): LongInt;
var
  List: PModuleList;
  ModuleIndex: Integer;
  Module: PLoadedModule;
  RelocationIndex: QWord;
begin
  List := ModuleList(Process);
  for ModuleIndex := 0 to List^.Count - 1 do
  begin
    Module := List^.Modules[ModuleIndex];
    if Module^.IsRelocated then
      Continue;
    RelocationIndex := 0;
    while RelocationIndex < Module^.RelocationCount do
    begin
      Result := ApplyRelocation(Process, Module, PElf64Rela(Module^.Relocations)[RelocationIndex]);
      if Result <> ErrorNone then
        Exit;
      Inc(RelocationIndex);
    end;
    FreeKernelMemory(Module^.Relocations);
    Module^.Relocations := nil;
    Module^.RelocationCount := 0;
    Module^.IsRelocated := True;
  end;
  Result := ErrorNone;
end;

{ --- Public routines ------------------------------------------------- }

function LoadProgramImage(Process: PProcess; KernelPath: PChar; out MainModule: PLoadedModule): LongInt;
var
  ModuleIndex: Integer;
begin
  MainModule := nil;
  Result := LoadModule(Process, KernelPath, True, ModuleIndex);
  if Result = ErrorNone then
    Result := RelocatePendingModules(Process);
  if Result = ErrorNone then
  begin
    MainModule := ModuleList(Process)^.Modules[ModuleIndex];
    ModuleList(Process)^.StartupComplete := True;
  end;
end;

function LoadLibraryImage(Process: PProcess; KernelPath: PChar; out ModuleHandle: Integer): LongInt;
var
  Existing: Integer;
begin
  ModuleHandle := -1;
  Existing := FindModuleByName(ModuleList(Process), FileNameOf(KernelPath));
  if Existing >= 0 then
  begin
    ModuleHandle := Existing;
    Exit(ErrorNone);
  end;
  Result := LoadModule(Process, KernelPath, False, ModuleHandle);
  if Result = ErrorNone then
    Result := RelocatePendingModules(Process);
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
  List := ModuleList(Process);
  if (ModuleHandle < 0) or (ModuleHandle >= List^.Count) then
    Exit(ErrorBadHandle);
  if FindSymbolInModuleTree(List, ModuleHandle, Name, 0, Address) then
    Result := ErrorNone
  else
    Result := ErrorNotFound;
end;

procedure ReleaseModules(Process: PProcess);
var
  List: PModuleList;
  Index: Integer;
begin
  List := PModuleList(Process^.Modules);
  if List = nil then
    Exit;
  for Index := 0 to List^.Count - 1 do
    FreeModule(List^.Modules[Index]);
  FreeKernelMemory(List);
  Process^.Modules := nil;
end;

end.
