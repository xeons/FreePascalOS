{
  ELF64 file format structures.

  Only the parts needed to load a statically linked executable are
  described here: the file header and program headers.
}
unit Elf64;

{$mode objfpc}

interface

const
  ElfMagic = LongWord($464C457F); { #$7F 'E' 'L' 'F' read as little endian }

  ElfClass64 = 2;
  ElfDataLittleEndian = 1;
  ElfTypeExecutable = 2;

  ElfMachineAmd64 = 62;
  ElfMachineAarch64 = 183;

  ProgramHeaderTypeLoad = 1;

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

implementation

end.
