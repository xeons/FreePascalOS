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
  The kernel ELF executable, laid out in physical memory: shared by the
  UEFI loader (Loader.KernelImage, which reads the file from a volume or
  a server) and the native boot stub (which carries the file inside its
  own image).

  The kernel is linked to run at a high virtual address. All loadable
  segments go into one physically contiguous block, keeping their
  relative layout, and each segment's permissions are remembered so the
  translation tables can map them correctly.
}
unit Boot.KernelElf;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumKernelSegments = 16;
  KernelPageSize = 4096;

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

  TKernelElfStatus = (
    KernelElfValid,
    KernelElfTooSmall,
    KernelElfNotElf,
    KernelElfNot64BitLittleEndian,
    KernelElfNotExecutable,
    KernelElfWrongMachine,
    KernelElfHeadersTruncated,
    KernelElfSegmentTruncated,
    KernelElfNoSegments,
    KernelElfTooManySegments);

{ Checks the file and measures its image: Image.VirtualBase,
  SizeInBytes and EntryPoint are set (the block to allocate). }
function MeasureKernelElf(Contents: Pointer; FileSize: QWord; ExpectedMachine: Word;
  out Image: TLoadedKernelImage): TKernelElfStatus;
{ Copies the segments into the block at Image.PhysicalBase (zeroed by the
  caller, which takes care of .bss) and records them. Contents and the
  block are reached at their physical addresses. }
function CopyKernelElfSegments(Contents: Pointer; var Image: TLoadedKernelImage): TKernelElfStatus;
function KernelElfStatusText(Status: TKernelElfStatus): PChar;

implementation

uses
  Elf64,
  Runtime.Memory;

function RoundDownToPage(Address: QWord): QWord;
begin
  Result := Address and not QWord(KernelPageSize - 1);
end;

function RoundUpToPage(Address: QWord): QWord;
begin
  Result := RoundDownToPage(Address + KernelPageSize - 1);
end;

function GetProgramHeader(Contents: Pointer; Index: Word): PElf64ProgramHeader;
var
  Header: PElf64FileHeader;
begin
  Header := PElf64FileHeader(Contents);
  Result := PElf64ProgramHeader(PByte(Contents) + Header^.ProgramHeaderOffset +
    QWord(Index) * Header^.ProgramHeaderEntrySize);
end;

function ValidateFileHeader(Contents: Pointer; FileSize: QWord; ExpectedMachine: Word): TKernelElfStatus;
var
  Header: PElf64FileHeader;
begin
  if FileSize < SizeOf(TElf64FileHeader) then
    Exit(KernelElfTooSmall);
  Header := PElf64FileHeader(Contents);
  if Header^.Magic <> ElfMagic then
    Exit(KernelElfNotElf);
  if (Header^.FileClass <> ElfClass64) or (Header^.DataEncoding <> ElfDataLittleEndian) then
    Exit(KernelElfNot64BitLittleEndian);
  if Header^.FileType <> ElfTypeExecutable then
    Exit(KernelElfNotExecutable);
  if Header^.Machine <> ExpectedMachine then
    Exit(KernelElfWrongMachine);
  if Header^.ProgramHeaderOffset + QWord(Header^.ProgramHeaderCount) * Header^.ProgramHeaderEntrySize >
     FileSize then
    Exit(KernelElfHeadersTruncated);
  Result := KernelElfValid;
end;

function MeasureKernelElf(Contents: Pointer; FileSize: QWord; ExpectedMachine: Word;
  out Image: TLoadedKernelImage): TKernelElfStatus;
var
  Header: PElf64FileHeader;
  ProgramHeader: PElf64ProgramHeader;
  HeaderIndex: Word;
  LowestAddress: QWord;
  HighestAddress: QWord;
  SegmentEnd: QWord;
begin
  ZeroMemory(@Image, SizeOf(Image));
  Result := ValidateFileHeader(Contents, FileSize, ExpectedMachine);
  if Result <> KernelElfValid then
    Exit;

  Header := PElf64FileHeader(Contents);
  LowestAddress := High(QWord);
  HighestAddress := 0;
  for HeaderIndex := 1 to Header^.ProgramHeaderCount do
  begin
    ProgramHeader := GetProgramHeader(Contents, HeaderIndex - 1);
    if ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad then
      Continue;
    if ProgramHeader^.FileOffset + ProgramHeader^.FileSize > FileSize then
      Exit(KernelElfSegmentTruncated);
    if ProgramHeader^.VirtualAddress < LowestAddress then
      LowestAddress := ProgramHeader^.VirtualAddress;
    SegmentEnd := ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize;
    if SegmentEnd > HighestAddress then
      HighestAddress := SegmentEnd;
  end;
  if HighestAddress <= LowestAddress then
    Exit(KernelElfNoSegments);

  Image.VirtualBase := RoundDownToPage(LowestAddress);
  Image.SizeInBytes := RoundUpToPage(HighestAddress) - Image.VirtualBase;
  Image.EntryPoint := Header^.EntryPoint;
end;

function CopyKernelElfSegments(Contents: Pointer; var Image: TLoadedKernelImage): TKernelElfStatus;
var
  Header: PElf64FileHeader;
  ProgramHeader: PElf64ProgramHeader;
  HeaderIndex: Word;
  Segment: ^TKernelSegment;
  SegmentPageStart: QWord;
  SegmentPageEnd: QWord;
begin
  Header := PElf64FileHeader(Contents);
  Image.SegmentCount := 0;
  for HeaderIndex := 1 to Header^.ProgramHeaderCount do
  begin
    ProgramHeader := GetProgramHeader(Contents, HeaderIndex - 1);
    if ProgramHeader^.SegmentType <> ProgramHeaderTypeLoad then
      Continue;
    if Image.SegmentCount >= MaximumKernelSegments then
      Exit(KernelElfTooManySegments);

    CopyMemory(Pointer(Image.PhysicalBase + (ProgramHeader^.VirtualAddress - Image.VirtualBase)),
      PByte(Contents) + ProgramHeader^.FileOffset, ProgramHeader^.FileSize);

    SegmentPageStart := RoundDownToPage(ProgramHeader^.VirtualAddress);
    SegmentPageEnd := RoundUpToPage(ProgramHeader^.VirtualAddress + ProgramHeader^.MemorySize);
    Segment := @Image.Segments[Image.SegmentCount];
    Segment^.VirtualStart := SegmentPageStart;
    Segment^.PhysicalStart := Image.PhysicalBase + (SegmentPageStart - Image.VirtualBase);
    Segment^.PageCount := (SegmentPageEnd - SegmentPageStart) div KernelPageSize;
    Segment^.IsWritable := (ProgramHeader^.Flags and SegmentFlagWrite) <> 0;
    Segment^.IsExecutable := (ProgramHeader^.Flags and SegmentFlagExecute) <> 0;
    Inc(Image.SegmentCount);
  end;
  Result := KernelElfValid;
end;

function KernelElfStatusText(Status: TKernelElfStatus): PChar;
begin
  case Status of
    KernelElfValid: Result := 'Kernel image is valid.';
    KernelElfTooSmall: Result := 'Kernel file is too small to be an ELF image.';
    KernelElfNotElf: Result := 'Kernel file is not an ELF image.';
    KernelElfNot64BitLittleEndian: Result := 'Kernel is not a 64-bit little endian ELF image.';
    KernelElfNotExecutable: Result := 'Kernel is not an ELF executable.';
    KernelElfWrongMachine: Result := 'Kernel was built for a different processor architecture.';
    KernelElfHeadersTruncated: Result := 'Kernel program header table is truncated.';
    KernelElfSegmentTruncated: Result := 'Kernel segment extends past the end of the file.';
    KernelElfNoSegments: Result := 'Kernel image has no loadable segments.';
    KernelElfTooManySegments: Result := 'Kernel image has too many loadable segments.';
  else
    Result := 'Kernel image is damaged.';
  end;
end;

end.
