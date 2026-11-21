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
  Reading back what the AArch64 translation tables allow, for the self
  tests that check W^X (Kernel.ProtectionSelfTest).

  A page is writable unless its AP[2] bit (DescriptorReadOnly) is set,
  executable in the kernel unless PXN is, and reachable by user mode if
  AP[1] (DescriptorUserAccess) is set. Table descriptors can take rights
  away for everything below them (APTable[1], PXNTable); the kernel does
  not use those, but they are honoured. Blocks count as the 4 KiB pages
  they cover.
}
unit Memory.Arch.MappingAudit;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout;

const
  { A return instruction (RET (to X30)), written as a LongWord, for the tests
    that try to run code from pages that must not allow it. }
  ReturnInstruction = LongWord($D65F03C0);

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
    { User pages the kernel could execute (PXN clear), and the first. }
    KernelExecutableUserPages: QWord;
    FirstKernelExecutableUser: QWord;
  end;

{ The rights of the page at VirtualAddress in the kernel's tables. }
procedure QueryKernelPageRights(VirtualAddress: QWord; out Rights: TPageRights);

{ Walks every mapping of the kernel half (TTBR1_EL1). }
procedure AuditKernelMappings(out Audit: TMappingAudit);

{ Walks the user half of an address space (Root from
  CreateAddressSpaceRoot). }
procedure AuditUserMappings(Root: TPhysicalAddress; out Audit: TMappingAudit);

implementation

uses
  Runtime.Memory,
  Boot.TranslationTableFormat,
  Memory.Arch.PageTables;

const
  TablePrivilegedExecuteNever = QWord(1) shl 59;
  TableReadOnly = QWord(1) shl 62;
  { The user root's last entry holds the address space's ASID context,
    not a translation (Memory.Arch.PageTables). }
  AddressSpaceIdEntry = EntriesPerTable - 1;

type
  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

function TableFromEntry(Entry: QWord): PPageTable;
begin
  Result := PPageTable(PhysicalToVirtual(Entry and DescriptorAddressMask));
end;

function TableIndex(VirtualAddress: QWord; Level: Integer): Integer;
begin
  Result := Integer((VirtualAddress shr (PageShift + 9 * (Level - 1))) and (EntriesPerTable - 1));
end;

function IsLeaf(Entry: QWord; Level: Integer): Boolean;
begin
  Result := (Level = 1) or ((Entry and DescriptorTableOrPage) = 0);
end;

procedure StartRights(out Rights: TPageRights);
begin
  Rights.Present := True;
  Rights.Writable := True;
  Rights.Executable := True;
  Rights.User := True;
end;

procedure CombineTableRights(var Rights: TPageRights; Entry: QWord);
begin
  if (Entry and TableReadOnly) <> 0 then
    Rights.Writable := False;
  if (Entry and TablePrivilegedExecuteNever) <> 0 then
    Rights.Executable := False;
end;

procedure CombineLeafRights(var Rights: TPageRights; Entry: QWord);
begin
  if (Entry and DescriptorReadOnly) <> 0 then
    Rights.Writable := False;
  if (Entry and DescriptorPrivilegedExecuteNever) <> 0 then
    Rights.Executable := False;
  Rights.User := (Entry and DescriptorUserAccess) <> 0;
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
    if (Entry and DescriptorValid) = 0 then
    begin
      Rights.Present := False;
      Exit;
    end;
    if IsLeaf(Entry, Level) then
    begin
      CombineLeafRights(Rights, Entry);
      Exit;
    end;
    CombineTableRights(Rights, Entry);
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
  if Rights.User and Rights.Executable then
  begin
    if Audit.KernelExecutableUserPages = 0 then
      Audit.FirstKernelExecutableUser := VirtualAddress;
    Audit.KernelExecutableUserPages := Audit.KernelExecutableUserPages + PageCount;
  end;
end;

procedure WalkTable(var Audit: TMappingAudit; Table: PPageTable; Level: Integer; BaseAddress: QWord;
  const ParentRights: TPageRights; LastIndex: Integer);
var
  Index: Integer;
  Entry: QWord;
  Rights: TPageRights;
  EntryAddress: QWord;
  EntrySpan: QWord;
begin
  EntrySpan := QWord(1) shl (PageShift + 9 * (Level - 1));
  for Index := 0 to LastIndex do
  begin
    Entry := Table^[Index];
    if (Entry and DescriptorValid) = 0 then
      Continue;
    EntryAddress := BaseAddress + QWord(Index) * EntrySpan;
    Rights := ParentRights;
    if IsLeaf(Entry, Level) then
    begin
      CombineLeafRights(Rights, Entry);
      CountLeaf(Audit, Rights, EntryAddress, EntrySpan div PageSize);
    end
    else
    begin
      CombineTableRights(Rights, Entry);
      WalkTable(Audit, TableFromEntry(Entry), Level - 1, EntryAddress, Rights, EntriesPerTable - 1);
    end;
  end;
end;

procedure AuditKernelMappings(out Audit: TMappingAudit);
var
  Rights: TPageRights;
begin
  ZeroMemory(@Audit, SizeOf(Audit));
  StartRights(Rights);
  WalkTable(Audit, PPageTable(PhysicalToVirtual(KernelPageTableRoot)), 4, UpperHalfBase, Rights,
    EntriesPerTable - 1);
end;

procedure AuditUserMappings(Root: TPhysicalAddress; out Audit: TMappingAudit);
var
  Rights: TPageRights;
begin
  ZeroMemory(@Audit, SizeOf(Audit));
  StartRights(Rights);
  WalkTable(Audit, PPageTable(PhysicalToVirtual(Root)), 4, 0, Rights, AddressSpaceIdEntry - 1);
end;

end.
