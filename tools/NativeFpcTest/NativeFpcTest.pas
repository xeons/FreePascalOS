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
  NativeFpcTest

  On the host: the native Free Pascal compiler as it goes on the system
  disk (toolchain/fpc/fpc.mk), and a program the cross compiler linked
  with its internal ELF linker.

    NativeFpcTest <cpu> <fpc-root> [<internally-linked-program>]

    cpu        x86_64 or aarch64
    fpc-root   the staged files (build/<arch>/user/fpc-root)

  Checks:
    * bin/fpc and bin/ppc<cpu> are programs the kernel's loader takes:
      64-bit little endian ELF for the processor, position independent
      (ET_DYN) with an entry point, no interpreter, needing libsystem.so,
      a System V hash table (DT_HASH), no relocations in the code
      (DT_TEXTREL) and only the relocation types the loader applies;
    * etc/fpc.cfg links against the libraries (-XD) and searches the
      units of the target;
    * the units: System and SysUtils are FreePascalOS units marked as
      living in libsystem.so (ppumove), si_prc is not (it is linked into
      every program), and its object is there;
    * the internally linked program passes the same ELF checks.

  Prints every failed check and exits with 1 if there was one.
}
program NativeFpcTest;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes;

const
  ElfClass64 = 2;
  ElfDataLittleEndian = 1;
  ElfTypeShared = 3;
  MachineX86_64 = 62;
  MachineAArch64 = 183;
  ProgramHeaderInterpreter = 3;
  ProgramHeaderDynamic = 2;
  DynamicNull = 0;
  DynamicNeeded = 1;
  DynamicHash = 4;
  DynamicStringTable = 5;
  DynamicRela = 7;
  DynamicRelaSize = 8;
  DynamicTextRelocations = 22;
  DynamicJumpRelocations = 23;
  DynamicPltRelocationSize = 2;
  DynamicFlags = 30;
  DynamicFlagTextRelocations = 4;

  { The ppu header: "PPU", the version, then the compiler, processor
    and target as words and the flags as a longword. }
  PpuTargetOffset = 10;
  PpuFlagsOffset = 12;
  PpuFlagInLibrary = $20;
  PpuFlagSharedLinked = $100;
  { tsystem: system_x86_64_freepascalos, system_aarch64_freepascalos. }
  TargetX86_64FreePascalOS = 104;
  TargetAArch64FreePascalOS = 105;

type
  TElfHeader = packed record
    Identification: array[0..15] of Byte;
    FileType: Word;
    Machine: Word;
    Version: LongWord;
    Entry: QWord;
    ProgramHeaderOffset: QWord;
    SectionHeaderOffset: QWord;
    Flags: LongWord;
    HeaderSize: Word;
    ProgramHeaderEntrySize: Word;
    ProgramHeaderCount: Word;
    SectionHeaderEntrySize: Word;
    SectionHeaderCount: Word;
    SectionNameIndex: Word;
  end;

  TElfProgramHeader = packed record
    HeaderType: LongWord;
    Flags: LongWord;
    FileOffset: QWord;
    VirtualAddress: QWord;
    PhysicalAddress: QWord;
    FileSize: QWord;
    MemorySize: QWord;
    Alignment: QWord;
  end;

  TElfDynamic = packed record
    Tag: Int64;
    Value: QWord;
  end;

  TElfRela = packed record
    Offset: QWord;
    Info: QWord;
    Addend: Int64;
  end;

var
  FailureCount: Integer = 0;
  CheckCount: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(CheckCount);
  if not Condition then
  begin
    Inc(FailureCount);
    WriteLn('FAIL: ', What);
  end;
end;

function ReadWholeFile(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

{ The file offset of virtual address Address, through the segments. }
function FileOffsetOf(const Data: TBytes; const Header: TElfHeader; Address: QWord): QWord;
var
  Index: Integer;
  Segment: TElfProgramHeader;
begin
  Result := High(QWord);
  for Index := 0 to Header.ProgramHeaderCount - 1 do
  begin
    Move(Data[Header.ProgramHeaderOffset + QWord(Index) * Header.ProgramHeaderEntrySize], Segment,
      SizeOf(Segment));
    if (Segment.HeaderType = 1) and (Address >= Segment.VirtualAddress) and
       (Address < Segment.VirtualAddress + Segment.FileSize) then
      Exit(Segment.FileOffset + (Address - Segment.VirtualAddress));
  end;
end;

function RelocationTypeIsApplied(Machine: Word; RelocationType: LongWord): Boolean;
begin
  if Machine = MachineX86_64 then
    { R_X86_64_64, COPY, GLOB_DAT, JUMP_SLOT, RELATIVE }
    Result := RelocationType in [1, 5, 6, 7, 8]
  else
    { R_AARCH64_ABS64, COPY, GLOB_DAT, JUMP_SLOT, RELATIVE }
    Result := (RelocationType = 257) or ((RelocationType >= 1024) and (RelocationType <= 1027));
end;

procedure CheckRelocations(const Data: TBytes; const Header: TElfHeader; const Name: string;
  Address, Size: QWord);
var
  Offset: QWord;
  Position: QWord;
  Relocation: TElfRela;
  AllApplied: Boolean;
begin
  if (Address = 0) or (Size = 0) then
    Exit;
  Offset := FileOffsetOf(Data, Header, Address);
  Check(Offset <> High(QWord), Name + ': relocations inside a segment');
  if Offset = High(QWord) then
    Exit;
  AllApplied := True;
  Position := 0;
  while Position + SizeOf(Relocation) <= Size do
  begin
    Move(Data[Offset + Position], Relocation, SizeOf(Relocation));
    if not RelocationTypeIsApplied(Header.Machine, LongWord(Relocation.Info and $FFFFFFFF)) then
    begin
      AllApplied := False;
      WriteLn('  relocation type ', Relocation.Info and $FFFFFFFF, ' in ', Name);
    end;
    Inc(Position, SizeOf(Relocation));
  end;
  Check(AllApplied, Name + ': only relocation types the loader applies');
end;

procedure CheckProgram(const Path: string; Machine: Word);
var
  Data: TBytes;
  Header: TElfHeader;
  Segment: TElfProgramHeader;
  Dynamic: TElfDynamic;
  Index: Integer;
  DynamicOffset, DynamicSize, Position: QWord;
  HasInterpreter, HasHash, HasTextRelocations: Boolean;
  StringTable: QWord;
  NeededOffsets: array of QWord;
  NeedsSystem: Boolean;
  RelaAddress, RelaSize, JumpAddress, JumpSize: QWord;
  NameOffset: QWord;
  Name: string;
begin
  Check(FileExists(Path), Path + ' exists');
  if not FileExists(Path) then
    Exit;
  Data := ReadWholeFile(Path);
  Check(Length(Data) > SizeOf(Header), Path + ': longer than an ELF header');
  if Length(Data) <= SizeOf(Header) then
    Exit;
  Move(Data[0], Header, SizeOf(Header));
  Check((Header.Identification[0] = $7F) and (Header.Identification[1] = Ord('E')) and
    (Header.Identification[2] = Ord('L')) and (Header.Identification[3] = Ord('F')), Path + ': ELF');
  Check(Header.Identification[4] = ElfClass64, Path + ': 64-bit');
  Check(Header.Identification[5] = ElfDataLittleEndian, Path + ': little endian');
  Check(Header.Machine = Machine, Path + ': for the processor');
  Check(Header.FileType = ElfTypeShared, Path + ': position independent (ET_DYN)');
  Check(Header.Entry <> 0, Path + ': has an entry point');

  HasInterpreter := False;
  DynamicOffset := 0;
  DynamicSize := 0;
  for Index := 0 to Header.ProgramHeaderCount - 1 do
  begin
    Move(Data[Header.ProgramHeaderOffset + QWord(Index) * Header.ProgramHeaderEntrySize], Segment,
      SizeOf(Segment));
    if Segment.HeaderType = ProgramHeaderInterpreter then
      HasInterpreter := True;
    if Segment.HeaderType = ProgramHeaderDynamic then
    begin
      DynamicOffset := Segment.FileOffset;
      DynamicSize := Segment.FileSize;
    end;
  end;
  Check(not HasInterpreter, Path + ': no interpreter');
  Check(DynamicSize > 0, Path + ': has a dynamic section');
  if DynamicSize = 0 then
    Exit;

  HasHash := False;
  HasTextRelocations := False;
  StringTable := 0;
  NeededOffsets := nil;
  RelaAddress := 0;
  RelaSize := 0;
  JumpAddress := 0;
  JumpSize := 0;
  Position := 0;
  while Position + SizeOf(Dynamic) <= DynamicSize do
  begin
    Move(Data[DynamicOffset + Position], Dynamic, SizeOf(Dynamic));
    if Dynamic.Tag = DynamicNull then
      Break;
    case Dynamic.Tag of
      DynamicNeeded:
        begin
          SetLength(NeededOffsets, Length(NeededOffsets) + 1);
          NeededOffsets[High(NeededOffsets)] := Dynamic.Value;
        end;
      DynamicHash: HasHash := True;
      DynamicStringTable: StringTable := Dynamic.Value;
      DynamicTextRelocations: HasTextRelocations := True;
      DynamicFlags:
        if (Dynamic.Value and DynamicFlagTextRelocations) <> 0 then
          HasTextRelocations := True;
      DynamicRela: RelaAddress := Dynamic.Value;
      DynamicRelaSize: RelaSize := Dynamic.Value;
      DynamicJumpRelocations: JumpAddress := Dynamic.Value;
      DynamicPltRelocationSize: JumpSize := Dynamic.Value;
    end;
    Inc(Position, SizeOf(Dynamic));
  end;
  Check(HasHash, Path + ': System V hash table (DT_HASH)');
  Check(not HasTextRelocations, Path + ': no relocations in the code');

  NeedsSystem := False;
  for Index := 0 to High(NeededOffsets) do
  begin
    NameOffset := FileOffsetOf(Data, Header, StringTable + NeededOffsets[Index]);
    if NameOffset = High(QWord) then
      Continue;
    Name := StrPas(PChar(@Data[NameOffset]));
    if Name = 'libsystem.so' then
      NeedsSystem := True;
  end;
  Check(NeedsSystem, Path + ': needs libsystem.so');

  CheckRelocations(Data, Header, Path + ' (DT_RELA)', RelaAddress, RelaSize);
  CheckRelocations(Data, Header, Path + ' (DT_JMPREL)', JumpAddress, JumpSize);
end;

procedure CheckUnit(const Path: string; Target: Word; InLibrary: Boolean);
var
  Data: TBytes;
  UnitTarget: Word;
  Flags: LongWord;
begin
  Check(FileExists(Path), Path + ' exists');
  if not FileExists(Path) then
    Exit;
  Data := ReadWholeFile(Path);
  Check((Length(Data) > 16) and (Data[0] = Ord('P')) and (Data[1] = Ord('P')) and (Data[2] = Ord('U')),
    Path + ': a ppu file');
  if Length(Data) <= 16 then
    Exit;
  Move(Data[PpuTargetOffset], UnitTarget, SizeOf(UnitTarget));
  Move(Data[PpuFlagsOffset], Flags, SizeOf(Flags));
  Check(UnitTarget = Target, Path + ': compiled for FreePascalOS');
  if InLibrary then
    Check((Flags and (PpuFlagInLibrary or PpuFlagSharedLinked)) = (PpuFlagInLibrary or PpuFlagSharedLinked),
      Path + ': marked as living in its library')
  else
    Check((Flags and PpuFlagInLibrary) = 0, Path + ': not in a library');
end;

procedure CheckConfiguration(const Path: string);
var
  Lines: TStringList;
begin
  Check(FileExists(Path), Path + ' exists');
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Check(Lines.IndexOf('-XD') >= 0, Path + ': links units against their libraries (-XD)');
    Check(Lines.IndexOf('-Fu/usr/lib/fpc/$fpcversion/units/$fpctarget/*') >= 0, Path + ': the units of the target');
  finally
    Lines.Free;
  end;
end;

var
  Cpu, Root, CompilerName, UnitDirectory: string;
  Machine, Target: Word;
begin
  if (ParamCount < 2) or (ParamCount > 3) then
  begin
    WriteLn('usage: NativeFpcTest <x86_64|aarch64> <fpc-root> [<internally-linked-program>]');
    Halt(2);
  end;
  Cpu := ParamStr(1);
  Root := IncludeTrailingPathDelimiter(ParamStr(2));
  if Cpu = 'aarch64' then
  begin
    Machine := MachineAArch64;
    Target := TargetAArch64FreePascalOS;
    CompilerName := 'ppca64';
  end
  else
  begin
    Machine := MachineX86_64;
    Target := TargetX86_64FreePascalOS;
    CompilerName := 'ppcx64';
  end;
  UnitDirectory := Root + 'usr/lib/fpc/3.2.2/units/' + Cpu + '-freepascalos/';

  CheckProgram(Root + 'bin/' + CompilerName, Machine);
  CheckProgram(Root + 'bin/fpc', Machine);
  CheckConfiguration(Root + 'etc/fpc.cfg');
  CheckUnit(UnitDirectory + 'rtl/system.ppu', Target, True);
  CheckUnit(UnitDirectory + 'rtl/sysutils.ppu', Target, True);
  CheckUnit(UnitDirectory + 'rtl/si_prc.ppu', Target, False);
  Check(FileExists(UnitDirectory + 'rtl/si_prc.o'), 'si_prc.o is installed with its unit');
  CheckUnit(UnitDirectory + 'system/Sys.Files.ppu', Target, True);
  if ParamCount = 3 then
    CheckProgram(ParamStr(3), Machine);

  WriteLn('NativeFpcTest: ', CheckCount, ' checks, ', FailureCount, ' failed');
  if FailureCount > 0 then
    Halt(1);
end.
