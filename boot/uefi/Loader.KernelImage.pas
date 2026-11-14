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
  Loads the kernel ELF executable into physical memory.

  The kernel is linked to run at a high virtual address. The loader copies
  all loadable segments into one physically contiguous block, preserving
  their relative layout, and remembers each segment's permissions so the
  page table builder can map them correctly.
}
unit Loader.KernelImage;

{$mode objfpc}
{$pointermath on}

interface

uses
  Uefi.Base,
  Loader.FileLoading;

const
  MaximumKernelSegments = 16;

type
  TKernelSegment = record
    VirtualStart: QWord;
    PhysicalStart: QWord;
    PageCount: QWord;
    IsWritable: Boolean;
    IsExecutable: Boolean;
  end;

  TLoadedKernelImage = record
    PhysicalBase: QWord;
    VirtualBase: QWord;
    SizeInBytes: QWord;
    EntryPoint: QWord;
    SegmentCount: LongWord;
    Segments: array[0..MaximumKernelSegments - 1] of TKernelSegment;
  end;

function LoadKernelImage(const KernelFile: TLoadedFile; ExpectedMachine: Word;
  out Image: TLoadedKernelImage): TEfiStatus;

implementation

uses
  Elf64,
  Runtime.Memory,
  Loader.Console,
  Loader.Memory;

function RoundDownToPage(Address: QWord): QWord;
begin
  Result := Address and not QWord(LoaderPageSize - 1);
end;

function RoundUpToPage(Address: QWord): QWord;
begin
  Result := RoundDownToPage(Address + LoaderPageSize - 1);
end;

function ValidateFileHeader(const KernelFile: TLoadedFile; ExpectedMachine: Word): Boolean;
var
  Header: PElf64FileHeader;
  ProgramHeaderTableEnd: QWord;
begin
  Result := False;

  if KernelFile.SizeInBytes < SizeOf(TElf64FileHeader) then
  begin
    PrintLine('Kernel file is too small to be an ELF image.');
    Exit;
  end;

  Header := PElf64FileHeader(KernelFile.Contents);

  if Header^.Magic <> ElfMagic then
  begin
    PrintLine('Kernel file is not an ELF image.');
    Exit;
  end;

  if (Header^.FileClass <> ElfClass64) or (Header^.DataEncoding <> ElfDataLittleEndian) then
  begin
    PrintLine('Kernel is not a 64-bit little endian ELF image.');
    Exit;
  end;

  if Header^.FileType <> ElfTypeExecutable then
  begin
    PrintLine('Kernel is not an ELF executable.');
    Exit;
  end;

  if Header^.Machine <> ExpectedMachine then
  begin
    PrintLine('Kernel was built for a different processor architecture.');
    Exit;
  end;

  ProgramHeaderTableEnd := Header^.ProgramHeaderOffset +
    QWord(Header^.ProgramHeaderCount) * Header^.ProgramHeaderEntrySize;
  if ProgramHeaderTableEnd > KernelFile.SizeInBytes then
  begin
    PrintLine('Kernel program header table is truncated.');
    Exit;
  end;

  Result := True;
end;

function GetProgramHeader(const KernelFile: TLoadedFile; Index: Word): PElf64ProgramHeader;
var
  Header: PElf64FileHeader;
  Offset: QWord;
begin
  Header := PElf64FileHeader(KernelFile.Contents);
  Offset := Header^.ProgramHeaderOffset + QWord(Index) * Header^.ProgramHeaderEntrySize;
  Result := PElf64ProgramHeader(PByte(KernelFile.Contents) + Offset);
end;

{ Finds the virtual address range covered by all loadable segments. }
function MeasureImageSpan(const KernelFile: TLoadedFile;
  out LowestAddress, HighestAddress: QWord): Boolean;
var
  Header: PElf64FileHeader;
  ProgramHeader: PElf64ProgramHeader;
  HeaderIndex: Word;
  SegmentEnd: QWord;
begin
  Header := PElf64FileHeader(KernelFile.Contents);
  LowestAddress := High(QWord);
  HighestAddress := 0;

  for HeaderIndex := 1 to Header^.ProgramHeaderCount do
  begin
    ProgramHeader := GetProgramHeader(KernelFile, HeaderIndex - 1);
    if ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad then
      Continue;

    if ProgramHeader^.FileOffset + ProgramHeader^.FileSize > KernelFile.SizeInBytes then
    begin
      PrintLine('Kernel segment extends past the end of the file.');
      Exit(False);
    end;

    if ProgramHeader^.VirtualAddress < LowestAddress then
      LowestAddress := ProgramHeader^.VirtualAddress;

    SegmentEnd := ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize;
    if SegmentEnd > HighestAddress then
      HighestAddress := SegmentEnd;
  end;

  Result := HighestAddress > LowestAddress;
  if not Result then
    PrintLine('Kernel image has no loadable segments.');
end;

function CopySegments(const KernelFile: TLoadedFile; var Image: TLoadedKernelImage): Boolean;
var
  Header: PElf64FileHeader;
  ProgramHeader: PElf64ProgramHeader;
  HeaderIndex: Word;
  Segment: ^TKernelSegment;
  OffsetInImage: QWord;
  SegmentPageStart: QWord;
  SegmentPageEnd: QWord;
begin
  Header := PElf64FileHeader(KernelFile.Contents);
  Image.SegmentCount := 0;

  for HeaderIndex := 1 to Header^.ProgramHeaderCount do
  begin
    ProgramHeader := GetProgramHeader(KernelFile, HeaderIndex - 1);
    if ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad then
      Continue;

    if Image.SegmentCount >= MaximumKernelSegments then
    begin
      PrintLine('Kernel image has too many loadable segments.');
      Exit(False);
    end;

    { The block was zeroed when allocated, which takes care of the part of
      each segment that is not backed by file contents (.bss). }
    OffsetInImage := ProgramHeader^.VirtualAddress - Image.VirtualBase;
    CopyMemory(Pointer(Image.PhysicalBase + OffsetInImage),
      PByte(KernelFile.Contents) + ProgramHeader^.FileOffset,
      ProgramHeader^.FileSize);

    SegmentPageStart := RoundDownToPage(ProgramHeader^.VirtualAddress);
    SegmentPageEnd := RoundUpToPage(ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize);

    Segment := @Image.Segments[Image.SegmentCount];
    Segment^.VirtualStart := SegmentPageStart;
    Segment^.PhysicalStart := Image.PhysicalBase + (SegmentPageStart - Image.VirtualBase);
    Segment^.PageCount := (SegmentPageEnd - SegmentPageStart) div LoaderPageSize;
    Segment^.IsWritable := (ProgramHeader^.Flags and SegmentFlagWrite) <> 0;
    Segment^.IsExecutable := (ProgramHeader^.Flags and SegmentFlagExecute) <> 0;
    Inc(Image.SegmentCount);
  end;

  Result := True;
end;

function LoadKernelImage(const KernelFile: TLoadedFile; ExpectedMachine: Word;
  out Image: TLoadedKernelImage): TEfiStatus;
var
  LowestAddress: QWord;
  HighestAddress: QWord;
  ImagePageCount: QWord;
begin
  ZeroMemory(@Image, SizeOf(Image));

  if not ValidateFileHeader(KernelFile, ExpectedMachine) then
    Exit(EfiLoadError);

  if not MeasureImageSpan(KernelFile, LowestAddress, HighestAddress) then
    Exit(EfiLoadError);

  Image.VirtualBase := RoundDownToPage(LowestAddress);
  Image.SizeInBytes := RoundUpToPage(HighestAddress) - Image.VirtualBase;
  Image.EntryPoint := PElf64FileHeader(KernelFile.Contents)^.EntryPoint;

  ImagePageCount := Image.SizeInBytes div LoaderPageSize;
  Image.PhysicalBase := AllocateLoaderPages(ImagePageCount, LoaderMemoryTypeKernelImage);
  if Image.PhysicalBase = 0 then
    Exit(EfiOutOfResources);

  if not CopySegments(KernelFile, Image) then
    Exit(EfiLoadError);

  Result := EfiSuccess;
end;

end.
