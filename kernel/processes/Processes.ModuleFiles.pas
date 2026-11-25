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
  The file a loaded module came from, for what the program never loads:
  its section headers, .debug_frame and .symtab (the user back trace,
  Processes.UserBackTrace).

  A module's image pages come from its file's mapped file (Processes.-
  MappedFiles, a private reference held by each region), which keeps
  the file open even after its name is gone; the first region of the
  module with a backing gives it, taken with a reference of our own
  under the address space's lock. Reads go through the file system
  (ReadFromFileAt), so they need passive level.
}
unit Processes.ModuleFiles;

{$mode objfpc}
{$pointermath on}

interface

uses
  Elf64,
  Processes.AddressSpace,
  Processes.MappedFiles;

const
  ElfSectionTypeSymbolTable = 2;
  ElfSectionNameCapacity = 32;

type
  TElf64SectionHeader = record
    NameOffset: LongWord;
    SectionType: LongWord;
    Flags: QWord;
    Address: QWord;
    FileOffset: QWord;
    Size: QWord;
    Link: LongWord;
    Information: LongWord;
    AddressAlignment: QWord;
    EntrySize: QWord;
  end;

  TModuleFile = record
    MappedFile: PMappedFile;
    Header: TElf64FileHeader;
  end;

{ The file of the module whose image spans [ImageStart, ImageEnd) in
  Space, its ELF header read; False if there is none. Passive level. }
function OpenModuleFile(Space: PAddressSpace; ImageStart, ImageEnd: QWord; out ModuleFile: TModuleFile): Boolean;
procedure CloseModuleFile(var ModuleFile: TModuleFile);
{ Exactly Count bytes at Offset. }
function ReadModuleFile(constref ModuleFile: TModuleFile; Offset: QWord; Buffer: Pointer; Count: QWord): Boolean;
function ReadSectionHeader(constref ModuleFile: TModuleFile; Index: LongWord;
  out Section: TElf64SectionHeader): Boolean;
{ The section called Name. }
function FindModuleSection(constref ModuleFile: TModuleFile; Name: PChar; out Section: TElf64SectionHeader): Boolean;
{ The first program header of SegmentType. }
function FindProgramHeader(constref ModuleFile: TModuleFile; SegmentType: LongWord;
  out ProgramHeader: TElf64ProgramHeader): Boolean;
{ The link addresses its executable segments span. }
function ExecutableRange(constref ModuleFile: TModuleFile; out CodeStart, CodeEnd: QWord): Boolean;
{ Whether Address lies in an executable region of Space (code a C
  program's dynamic linker mapped, which is in no module). }
function AddressIsExecutable(Space: PAddressSpace; Address: QWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  FileSystem.Types,
  FileSystem.Files,
  Processes.UserRegions;

{ The mapped file behind the module's first file-backed region, with a
  reference; nil if none. }
function TakeModuleMappedFile(Space: PAddressSpace; ImageStart, ImageEnd: QWord): PMappedFile;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
  Address: QWord;
begin
  Result := nil;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Address := ImageStart;
  while Address < ImageEnd do
  begin
    Region := FindRegionAtOrAboveLocked(Space, Address);
    if (Region = nil) or (Region^.Start >= ImageEnd) then
      Break;
    if (Region^.Kind = RegionKindImage) and (Region^.Backing <> nil) then
    begin
      Result := PMappedFile(Region^.Backing);
      ReferenceMappedFile(Result, False);
      Break;
    end;
    Address := Region^.Start + Region^.Length;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function AddressIsExecutable(Space: PAddressSpace; Address: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
begin
  if Space = nil then
    Exit(False);
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Address);
  Result := (Region <> nil) and ((Region^.Attributes and RegionExecutable) <> 0);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function OpenModuleFile(Space: PAddressSpace; ImageStart, ImageEnd: QWord; out ModuleFile: TModuleFile): Boolean;
begin
  FillMemory(@ModuleFile, SizeOf(ModuleFile), 0);
  if Space = nil then
    Exit(False);
  ModuleFile.MappedFile := TakeModuleMappedFile(Space, ImageStart, ImageEnd);
  if ModuleFile.MappedFile = nil then
    Exit(False);
  Result := ReadModuleFile(ModuleFile, 0, @ModuleFile.Header, SizeOf(ModuleFile.Header)) and
    (ModuleFile.Header.Magic = ElfMagic) and (ModuleFile.Header.FileClass = ElfClass64);
  if not Result then
    CloseModuleFile(ModuleFile);
end;

procedure CloseModuleFile(var ModuleFile: TModuleFile);
begin
  if ModuleFile.MappedFile <> nil then
    ReleaseMappedFile(ModuleFile.MappedFile, False);
  ModuleFile.MappedFile := nil;
end;

function ReadModuleFile(constref ModuleFile: TModuleFile; Offset: QWord; Buffer: Pointer; Count: QWord): Boolean;
var
  BytesRead: QWord;
begin
  if ModuleFile.MappedFile = nil then
    Exit(False);
  if Count = 0 then
    Exit(True);
  Result := (ReadFromFileAt(ModuleFile.MappedFile^.OpenedFile, Offset, Buffer, Count, BytesRead) = StatusSuccess) and
    (BytesRead = Count);
end;

function ReadSectionHeader(constref ModuleFile: TModuleFile; Index: LongWord;
  out Section: TElf64SectionHeader): Boolean;
begin
  FillMemory(@Section, SizeOf(Section), 0);
  if (Index >= ModuleFile.Header.SectionHeaderCount) or
     (ModuleFile.Header.SectionHeaderEntrySize < SizeOf(TElf64SectionHeader)) then
    Exit(False);
  Result := ReadModuleFile(ModuleFile, ModuleFile.Header.SectionHeaderOffset +
    QWord(Index) * ModuleFile.Header.SectionHeaderEntrySize, @Section, SizeOf(Section));
end;

function FindModuleSection(constref ModuleFile: TModuleFile; Name: PChar; out Section: TElf64SectionHeader): Boolean;
var
  Names: TElf64SectionHeader;
  Index: LongWord;
  Candidate: array[0..ElfSectionNameCapacity - 1] of Char;
  Length: QWord;
begin
  Result := False;
  FillMemory(@Section, SizeOf(Section), 0);
  if not ReadSectionHeader(ModuleFile, ModuleFile.Header.SectionNameTableIndex, Names) then
    Exit;
  Index := 1;
  while Index < ModuleFile.Header.SectionHeaderCount do
  begin
    if not ReadSectionHeader(ModuleFile, Index, Section) then
      Exit;
    if Section.NameOffset < Names.Size then
    begin
      Length := Names.Size - Section.NameOffset;
      if Length > SizeOf(Candidate) - 1 then
        Length := SizeOf(Candidate) - 1;
      FillMemory(@Candidate[0], SizeOf(Candidate), 0);
      if ReadModuleFile(ModuleFile, Names.FileOffset + Section.NameOffset, @Candidate[0], Length) and
         TextIsEqual(@Candidate[0], Name) then
        Exit(True);
    end;
    Inc(Index);
  end;
  FillMemory(@Section, SizeOf(Section), 0);
end;

function FindProgramHeader(constref ModuleFile: TModuleFile; SegmentType: LongWord;
  out ProgramHeader: TElf64ProgramHeader): Boolean;
var
  Index: LongWord;
begin
  Index := 0;
  while Index < ModuleFile.Header.ProgramHeaderCount do
  begin
    if not ReadModuleFile(ModuleFile, ModuleFile.Header.ProgramHeaderOffset + QWord(Index) *
       SizeOf(TElf64ProgramHeader), @ProgramHeader, SizeOf(ProgramHeader)) then
      Break;
    if ProgramHeader.SegmentType = SegmentType then
      Exit(True);
    Inc(Index);
  end;
  FillMemory(@ProgramHeader, SizeOf(ProgramHeader), 0);
  Result := False;
end;

function ExecutableRange(constref ModuleFile: TModuleFile; out CodeStart, CodeEnd: QWord): Boolean;
var
  Index: LongWord;
  ProgramHeader: TElf64ProgramHeader;
begin
  CodeStart := High(QWord);
  CodeEnd := 0;
  Index := 0;
  while Index < ModuleFile.Header.ProgramHeaderCount do
  begin
    if not ReadModuleFile(ModuleFile, ModuleFile.Header.ProgramHeaderOffset + QWord(Index) *
       SizeOf(TElf64ProgramHeader), @ProgramHeader, SizeOf(ProgramHeader)) then
      Break;
    if (ProgramHeader.SegmentType = ProgramHeaderTypeLoad) and
       ((ProgramHeader.Flags and SegmentFlagExecute) <> 0) and
       (ProgramHeader.MemorySize <= High(QWord) - ProgramHeader.VirtualAddress) then
    begin
      if ProgramHeader.VirtualAddress < CodeStart then
        CodeStart := ProgramHeader.VirtualAddress;
      if ProgramHeader.VirtualAddress + ProgramHeader.MemorySize > CodeEnd then
        CodeEnd := ProgramHeader.VirtualAddress + ProgramHeader.MemorySize;
    end;
    Inc(Index);
  end;
  Result := CodeEnd > CodeStart;
  if not Result then
  begin
    CodeStart := 0;
    CodeEnd := 0;
  end;
end;

end.
