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
  ELF64 file format structures.

  Describes what is needed to load executables and shared objects: the
  file header, program headers, and the dynamic section with its symbol
  and relocation tables.
}
unit Elf64;

{$mode objfpc}

interface

const
  ElfMagic = LongWord($464C457F); { #$7F 'E' 'L' 'F' read as little endian }

  ElfClass64 = 2;
  ElfDataLittleEndian = 1;
  ElfTypeExecutable = 2;
  ElfTypeSharedObject = 3; { also position independent executables }

  ElfMachineAmd64 = 62;
  ElfMachineAarch64 = 183;

  ProgramHeaderTypeLoad = 1;
  ProgramHeaderTypeDynamic = 2;
  ProgramHeaderTypeInterpreter = 3;
  ProgramHeaderTypeThreadLocal = 7;

  { Dynamic section tags. }
  DynamicNull = 0;
  DynamicNeeded = 1;
  DynamicPltRelocationSize = 2;
  DynamicHash = 4;
  DynamicStringTable = 5;
  DynamicSymbolTable = 6;
  DynamicRela = 7;
  DynamicRelaSize = 8;
  DynamicRelaEntrySize = 9;
  DynamicStringTableSize = 10;
  DynamicSymbolEntrySize = 11;
  DynamicInitFunction = 12;
  DynamicFiniFunction = 13;
  DynamicSharedObjectName = 14;
  DynamicPltRelocationType = 20;
  DynamicJumpRelocations = 23;
  DynamicInitArray = 25;
  DynamicFiniArray = 26;
  DynamicInitArraySize = 27;
  DynamicFiniArraySize = 28;
  DynamicPreinitArray = 32;
  DynamicPreinitArraySize = 33;

  SymbolUndefinedSection = 0;
  SymbolBindingWeak = 2;
  SymbolTypeThreadLocal = 6;

  { x86-64 relocation types. }
  RelocationNone = 0;
  Relocation64 = 1;
  RelocationCopy = 5;
  RelocationGlobalData = 6;
  RelocationJumpSlot = 7;
  RelocationRelative = 8;
  { Thread-local storage (x86-64). }
  RelocationTlsModule64 = 16;   { R_X86_64_DTPMOD64 }
  RelocationTlsOffset64 = 17;   { R_X86_64_DTPOFF64 }
  RelocationThreadPointerOffset64 = 18; { R_X86_64_TPOFF64 }
  RelocationThreadPointerOffset32 = 23; { R_X86_64_TPOFF32 }

  { AArch64 relocation types (the dynamic ones). }
  RelocationAarch64None = 0;
  RelocationAarch64NoneWithdrawn = 256;
  RelocationAarch64Absolute64 = 257;     { R_AARCH64_ABS64 }
  RelocationAarch64Copy = 1024;
  RelocationAarch64GlobalData = 1025;    { R_AARCH64_GLOB_DAT }
  RelocationAarch64JumpSlot = 1026;
  RelocationAarch64Relative = 1027;
  RelocationAarch64TlsModule64 = 1028;   { R_AARCH64_TLS_DTPMOD64 }
  RelocationAarch64TlsOffset64 = 1029;   { R_AARCH64_TLS_DTPREL64 }
  RelocationAarch64ThreadPointerOffset64 = 1030; { R_AARCH64_TLS_TPREL64 }
  RelocationAarch64TlsDescriptor = 1031; { R_AARCH64_TLSDESC }

  SegmentFlagExecute = 1;
  SegmentFlagWrite = 2;
  SegmentFlagRead = 4;

type
  TElf64FileHeader = record
    Magic: LongWord;
    FileClass: Byte;
    DataEncoding: Byte;
    IdentVersion: Byte;
    OsAbi: Byte;
    AbiVersion: Byte;
    IdentPadding: array[0..6] of Byte;
    FileType: Word;
    Machine: Word;
    Version: LongWord;
    EntryPoint: QWord;
    ProgramHeaderOffset: QWord;
    SectionHeaderOffset: QWord;
    Flags: LongWord;
    HeaderSize: Word;
    ProgramHeaderEntrySize: Word;
    ProgramHeaderCount: Word;
    SectionHeaderEntrySize: Word;
    SectionHeaderCount: Word;
    SectionNameTableIndex: Word;
  end;
  PElf64FileHeader = ^TElf64FileHeader;

  TElf64ProgramHeader = record
    SegmentType: LongWord;
    Flags: LongWord;
    FileOffset: QWord;
    VirtualAddress: QWord;
    PhysicalAddress: QWord;
    FileSize: QWord;
    MemorySize: QWord;
    Alignment: QWord;
  end;
  PElf64ProgramHeader = ^TElf64ProgramHeader;

type
  TElf64Dynamic = record
    Tag: Int64;
    Value: QWord;
  end;
  PElf64Dynamic = ^TElf64Dynamic;

  TElf64Symbol = packed record
    NameOffset: LongWord;
    Information: Byte;
    Other: Byte;
    SectionIndex: Word;
    Value: QWord;
    Size: QWord;
  end;
  PElf64Symbol = ^TElf64Symbol;

  TElf64Rela = record
    Offset: QWord;
    Information: QWord;
    Addend: Int64;
  end;
  PElf64Rela = ^TElf64Rela;

function RelocationSymbolIndex(const Relocation: TElf64Rela): LongWord;
function RelocationType(const Relocation: TElf64Rela): LongWord;
function SymbolBinding(const Symbol: TElf64Symbol): Byte;
function SymbolType(const Symbol: TElf64Symbol): Byte;

{ The classic System V ELF hash of a symbol name. }
function ElfHash(Name: PChar): LongWord;

implementation

function RelocationSymbolIndex(const Relocation: TElf64Rela): LongWord;
begin
  Result := LongWord(Relocation.Information shr 32);
end;

function RelocationType(const Relocation: TElf64Rela): LongWord;
begin
  Result := LongWord(Relocation.Information and $FFFFFFFF);
end;

function SymbolBinding(const Symbol: TElf64Symbol): Byte;
begin
  Result := Symbol.Information shr 4;
end;

function SymbolType(const Symbol: TElf64Symbol): Byte;
begin
  Result := Symbol.Information and $0F;
end;

function ElfHash(Name: PChar): LongWord;
var
  HighBits: LongWord;
begin
  Result := 0;
  while Name^ <> #0 do
  begin
    Result := (Result shl 4) + Byte(Name^);
    HighBits := Result and $F0000000;
    if HighBits <> 0 then
      Result := Result xor (HighBits shr 24);
    Result := Result and not HighBits;
    Inc(Name);
  end;
end;


end.
