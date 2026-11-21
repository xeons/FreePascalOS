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
  Reading back what the x86-64 page tables allow, for the self tests
  that check W^X (Kernel.ProtectionSelfTest).

  A page's rights are what every level of the walk allows together:
  writable only if every entry on the way says writable, user only if
  every entry says user, and no-execute if any entry says so (and
  EFER.NXE is on). Large pages count as the 4 KiB pages they cover.
}
unit Memory.Arch.MappingAudit;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout;

const
  { A return instruction (RET), written as a LongWord, for the tests
    that try to run code from pages that must not allow it. }
  ReturnInstruction = LongWord($000000C3);

type
  TPageRights = record
    Present: Boolean;
    Writable: Boolean;
    { Executable in kernel mode. }
    Executable: Boolean;
    User: Boolean;
  end;

  TMappingAudit = record
    { Mapped 4 KiB pages looked at. }
    PagesChecked: QWord;
    { Pages the kernel may both write and execute, and the first one. }
    WritableExecutablePages: QWord;
    FirstWritableExecutable: QWord;
    { User pages the kernel could execute (none where the processor
      refuses that: SMEP, PXN). }
    KernelExecutableUserPages: QWord;
    FirstKernelExecutableUser: QWord;
  end;

{ The rights of the page at VirtualAddress in the kernel's tables. }
procedure QueryKernelPageRights(VirtualAddress: QWord; out Rights: TPageRights);

{ Walks every mapping of the kernel half. }
procedure AuditKernelMappings(out Audit: TMappingAudit);

{ Walks the user half of an address space (Root from
  CreateAddressSpaceRoot). }
procedure AuditUserMappings(Root: TPhysicalAddress; out Audit: TMappingAudit);

implementation

uses
  Runtime.Memory,
  Memory.Arch.PageTables,
  Kernel.Arch.ProcessorProtection;

const
  EntryPresent = QWord(1) shl 0;
  EntryWritable = QWord(1) shl 1;
  EntryUser = QWord(1) shl 2;
  EntryLargePage = QWord(1) shl 7;
  EntryNoExecute = QWord(1) shl 63;
  EntryAddressMask = QWord($000FFFFFFFFFF000);
  EntriesPerTable = 512;
  FirstKernelTopLevelEntry = 256;
  { Sign extension of the upper half's addresses. }
  UpperHalfSignExtension = QWord($FFFF000000000000);

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

function TableFromEntry(Entry: QWord): PPageTable;
begin
  Result := PPageTable(PhysicalToVirtual(Entry and EntryAddressMask));
end;

function TableIndex(VirtualAddress: QWord; Level: Integer): Integer;
begin
  Result := Integer((VirtualAddress shr (PageShift + 9 * (Level - 1))) and (EntriesPerTable - 1));
end;

{ Rights after one more level of the walk. }
procedure CombineRights(var Rights: TPageRights; Entry: QWord);
begin
  Rights.Writable := Rights.Writable and ((Entry and EntryWritable) <> 0);
  Rights.User := Rights.User and ((Entry and EntryUser) <> 0);
  if NoExecuteIsSupported and ((Entry and EntryNoExecute) <> 0) then
    Rights.Executable := False;
end;

procedure StartRights(out Rights: TPageRights);
begin
  Rights.Present := True;
  Rights.Writable := True;
  Rights.Executable := True;
  Rights.User := True;
end;

procedure QueryInTable(TopLevel: PPageTable; VirtualAddress: QWord; out Rights: TPageRights);
var
  Table: PPageTable;
  Level: Integer;
  Entry: QWord;
begin
  StartRights(Rights);
  Table := TopLevel;
  for Level := 4 downto 1 do
  begin
    Entry := Table^[TableIndex(VirtualAddress, Level)];
    if (Entry and EntryPresent) = 0 then
    begin
      Rights.Present := False;
      Exit;
    end;
    CombineRights(Rights, Entry);
    if (Level = 1) or ((Entry and EntryLargePage) <> 0) then
      Exit;
    Table := TableFromEntry(Entry);
  end;
end;

procedure QueryKernelPageRights(VirtualAddress: QWord; out Rights: TPageRights);
begin
  QueryInTable(PPageTable(PhysicalToVirtual(KernelPageTableRoot)), VirtualAddress, Rights);
end;

procedure CountLeaf(var Audit: TMappingAudit; const Rights: TPageRights; VirtualAddress: QWord;
  PageCount: QWord);
begin
  Audit.PagesChecked := Audit.PagesChecked + PageCount;
  if Rights.Writable and Rights.Executable then
  begin
    if Audit.WritableExecutablePages = 0 then
      Audit.FirstWritableExecutable := VirtualAddress;
    Audit.WritableExecutablePages := Audit.WritableExecutablePages + PageCount;
  end;
  if Rights.User and Rights.Executable and not SupervisorExecutionProtectionIsOn then
  begin
    if Audit.KernelExecutableUserPages = 0 then
      Audit.FirstKernelExecutableUser := VirtualAddress;
    Audit.KernelExecutableUserPages := Audit.KernelExecutableUserPages + PageCount;
  end;
end;

procedure WalkTable(var Audit: TMappingAudit; Table: PPageTable; Level: Integer; BaseAddress: QWord;
  const ParentRights: TPageRights);
var
  Index: Integer;
  Entry: QWord;
  Rights: TPageRights;
  EntryAddress: QWord;
  EntrySpan: QWord;
begin
  EntrySpan := QWord(1) shl (PageShift + 9 * (Level - 1));
  for Index := 0 to EntriesPerTable - 1 do
  begin
    Entry := Table^[Index];
    if (Entry and EntryPresent) = 0 then
      Continue;
    EntryAddress := BaseAddress + QWord(Index) * EntrySpan;
    Rights := ParentRights;
    CombineRights(Rights, Entry);
    if (Level = 1) or ((Entry and EntryLargePage) <> 0) then
      CountLeaf(Audit, Rights, EntryAddress, EntrySpan div PageSize)
    else
      WalkTable(Audit, TableFromEntry(Entry), Level - 1, EntryAddress, Rights);
  end;
end;

procedure WalkTopLevel(var Audit: TMappingAudit; TopLevel: PPageTable; FirstEntry, LastEntry: Integer);
var
  Index: Integer;
  Entry: QWord;
  Rights: TPageRights;
  EntryAddress: QWord;
begin
  for Index := FirstEntry to LastEntry do
  begin
    Entry := TopLevel^[Index];
    if (Entry and EntryPresent) = 0 then
      Continue;
    EntryAddress := QWord(Index) shl (PageShift + 27);
    if Index >= FirstKernelTopLevelEntry then
      EntryAddress := EntryAddress or UpperHalfSignExtension;
    StartRights(Rights);
    CombineRights(Rights, Entry);
    WalkTable(Audit, TableFromEntry(Entry), 3, EntryAddress, Rights);
  end;
end;

procedure AuditKernelMappings(out Audit: TMappingAudit);
begin
  ZeroMemory(@Audit, SizeOf(Audit));
  WalkTopLevel(Audit, PPageTable(PhysicalToVirtual(KernelPageTableRoot)), FirstKernelTopLevelEntry,
    EntriesPerTable - 1);
end;

procedure AuditUserMappings(Root: TPhysicalAddress; out Audit: TMappingAudit);
begin
  ZeroMemory(@Audit, SizeOf(Audit));
  WalkTopLevel(Audit, PPageTable(PhysicalToVirtual(Root)), 0, FirstKernelTopLevelEntry - 1);
end;

end.
