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
  Self tests of the kernel's memory protection, run at every start:

    * W^X: the page tables are walked, and no kernel page may be both
      writable and executable;
    * the kernel image: its code is read-only and executable, its
      read-only data read-only and not executable, its data not
      executable, and the physical memory window's view of the code and
      read-only data read-only and not executable;
    * user pages: never executable by the kernel (PXN, or SMEP), and a
      writable user page not executable;
    * the user copy routines with SMAP or PAN on: copies to and from a
      mapped user page work, copies from a missing one fail safely, and
      the protection is on again afterwards;
    * with "heapchecks": freed physical pages are filled, held back and
      checked (Memory.PageQuarantine);
    * object reference counts saturate instead of wrapping.

  Deliberate violations, which stop the system, are in
  Kernel.ProtectionFaultTest.
}
unit Kernel.ProtectionSelfTest;

{$mode objfpc}
{$pointermath on}

interface

procedure RunProtectionSelfTests;

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.HeapChecks,
  Memory.PageQuarantine,
  Memory.Arch.PageTables,
  Memory.Arch.MappingAudit,
  Kernel.Arch.UserCopy,
  Kernel.Scheduler,
  Kernel.SelfTest,
  Kernel.TestUserSpace,
  Objects.Manager,
  Debug.Output;

var
  KernelTextStart: Byte; external name 'KernelTextStart';
  KernelTextEnd: Byte; external name 'KernelTextEnd';
  KernelReadOnlyDataStart: Byte; external name 'KernelReadOnlyDataStart';
  KernelReadOnlyDataEnd: Byte; external name 'KernelReadOnlyDataEnd';
  KernelDataStart: Byte; external name 'KernelDataStart';
  KernelImageEnd: Byte; external name 'KernelImageEnd';

procedure WriteSkipped(TestName: PChar; Reason: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite(TestName);
  DebugWrite(': skipped (');
  DebugWrite(Reason);
  DebugWriteLine(')');
  DebugEndMessage;
end;

{ --- W^X ---------------------------------------------------------------- }

procedure TestNoWritableExecutablePages;
var
  Audit: TMappingAudit;
begin
  if not NoExecuteIsSupported then
  begin
    WriteSkipped('W^X over the kernel''s page tables', 'the processor has no no-execute bit');
    Exit;
  end;
  AuditKernelMappings(Audit);
  Check(Audit.PagesChecked > 0, 'the page table walk found no mappings');
  if Audit.WritableExecutablePages <> 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('selftest');
    DebugWriteDecimal(Audit.WritableExecutablePages);
    DebugWrite(' kernel pages writable and executable, the first at ');
    DebugWriteAddress(Audit.FirstWritableExecutable);
    DebugWriteLine('');
    DebugEndMessage;
  end;
  Check(Audit.WritableExecutablePages = 0, 'a kernel page is both writable and executable');
  ReportPassed('W^X: no kernel page is both writable and executable');
end;

{ Checks the rights of every page in [First, Limit) of the kernel image,
  and of the window's view of it. }
procedure CheckImageRange(First, Limit: QWord; MustWrite, MustExecute: Boolean; WindowMustWrite: Boolean;
  Description: PChar);
var
  Page: QWord;
  Rights: TPageRights;
  Physical: TPhysicalAddress;
begin
  Page := RoundDownToPage(First);
  while Page < Limit do
  begin
    QueryKernelPageRights(Page, Rights);
    Check(Rights.Present, Description);
    Check(Rights.Writable = MustWrite, Description);
    if NoExecuteIsSupported then
      Check(Rights.Executable = MustExecute, Description);
    Check(TranslateVirtualAddress(Page, Physical), Description);
    QueryKernelPageRights(QWord(PhysicalToVirtual(Physical)), Rights);
    Check(Rights.Present and (Rights.Writable = WindowMustWrite), Description);
    if NoExecuteIsSupported then
      Check(not Rights.Executable, Description);
    Page := Page + PageSize;
  end;
end;

procedure TestKernelImageProtection;
begin
  CheckImageRange(QWord(@KernelTextStart), QWord(@KernelTextEnd), False, True, False,
    'the kernel''s code is writable, not executable, or writable through the window');
  CheckImageRange(QWord(@KernelReadOnlyDataStart), QWord(@KernelReadOnlyDataEnd), False, False, False,
    'the kernel''s read-only data is writable or executable (or writable through the window)');
  CheckImageRange(QWord(@KernelDataStart), QWord(@KernelImageEnd), True, False, True,
    'the kernel''s data is executable or not writable');
  ReportPassed('kernel image: code read-only, data not executable');
end;

{ --- User pages ---------------------------------------------------------- }

procedure TestUserPagesNotKernelExecutable;
var
  Space: TTestUserSpace;
  Audit: TMappingAudit;
begin
  Check(CreateTestUserSpace(Space), 'no memory for a test address space');
  AuditUserMappings(Space.Root, Audit);
  DestroyTestUserSpace(Space);
  Check(Audit.PagesChecked = 2, 'the test address space does not hold its two pages');
  if NoExecuteIsSupported then
    Check(Audit.WritableExecutablePages = 0, 'a writable user page is executable');
  if Audit.KernelExecutableUserPages <> 0 then
  begin
    WriteSkipped('user pages never run by the kernel', 'the processor has no SMEP');
    Exit;
  end;
  ReportPassed('user pages are never executable by the kernel');
end;

procedure TestUserCopyWithProtection;
var
  Space: TTestUserSpace;
  Value: QWord;
  Buffer: array[0..15] of Byte;
begin
  Check(CreateTestUserSpace(Space), 'no memory for a test address space');
  EnterTestUserSpace(Space);
  Value := 0;
  Check(ArchCopyUserMemory(@Value, Pointer(TestUserDataAddress), SizeOf(Value)) = 0,
    'a copy from a mapped user page failed');
  Check(Value = TestUserDataValue, 'a copy from a user page read the wrong value');
  Value := not TestUserDataValue;
  Check(ArchCopyUserMemory(Pointer(TestUserDataAddress), @Value, SizeOf(Value)) = 0,
    'a copy to a mapped user page failed');
  Check(ArchCopyUserMemory(@Buffer[0], Pointer(TestUserUnmappedAddress), SizeOf(Buffer)) = UserCopyFaulted,
    'a copy from missing user memory did not fail');
  Check(ArchCopyUserString(PChar(@Buffer[0]), PChar(TestUserUnmappedAddress), SizeOf(Buffer)) = UserCopyFaulted,
    'a string copy from missing user memory did not fail');
  Check(not CurrentThread^.UserCopyActive, 'the copy mark was left set');
  Check(UserMemoryProtectionIsOnHere, 'the user memory protection was left open after a copy');
  LeaveTestUserSpace(Space);
  Check(PQWord(PhysicalToVirtual(Space.DataPage))^ = not TestUserDataValue,
    'a copy to a user page did not arrive');
  DestroyTestUserSpace(Space);
  if UserMemoryIsProtected then
    ReportPassed('user copies with SMAP/PAN on')
  else
    ReportPassed('user copies (the processor has no SMAP/PAN)');
end;

{ --- Physical page quarantine -------------------------------------------- }

procedure TestPhysicalPageQuarantine;
const
  DamagedOffset = 100;
var
  Page: TPhysicalAddress;
  Filler: TPhysicalAddress;
  Count: QWord;
begin
  if KernelHeapCheckLevel <> HeapChecksQuarantine then
  begin
    WriteSkipped('freed physical pages filled and held back', 'no "heapchecks"');
    Exit;
  end;
  Page := AllocatePhysicalPage(PageUsageGeneral);
  Check(Page <> 0, 'no physical page for the quarantine test');
  FreePhysicalPage(Page);
  Check(PageUsageOf(Page) = PageUsageQuarantined, 'a freed physical page was not held back');
  Check(QuarantinedPageDamage(Page) = NoDamage, 'a freed physical page was not filled');
  PByte(PhysicalToVirtual(Page))[DamagedOffset] := 0;
  Check(QuarantinedPageDamage(Page) = DamagedOffset, 'a write into a freed physical page was not found');
  PByte(PhysicalToVirtual(Page))[DamagedOffset] := PageFreeFill;
  { As many frees again push it out of the ring, checked, to the free
    list. }
  Count := 0;
  while Count < PageQuarantineCapacity do
  begin
    Filler := AllocatePhysicalPage(PageUsageGeneral);
    Check(Filler <> 0, 'no physical page for the quarantine test');
    FreePhysicalPage(Filler);
    Inc(Count);
  end;
  Check(PageUsageOf(Page) <> PageUsageQuarantined, 'a physical page stayed in the quarantine');
  ReportPassed('freed physical pages filled, held back and checked');
end;

{ --- Reference counts ---------------------------------------------------- }

var
  SaturationTestType: TObjectType;
  SaturationObjectDeleted: Boolean;

procedure NoteSaturationObjectDeleted(ObjectBody: Pointer);
begin
  SaturationObjectDeleted := True;
end;

procedure TestReferenceCountSaturation;
var
  Body: Pointer;
begin
  RegisterObjectType(SaturationTestType, 'SaturationTest', 8, @NoteSaturationObjectDeleted);
  SaturationObjectDeleted := False;
  Body := CreateObject(SaturationTestType, nil);
  Check(Body <> nil, 'no memory for the reference count test');
  SetObjectReferenceCountForTest(Body, ObjectReferenceCountLimit - 2);
  ReferenceObject(Body);
  ReferenceObject(Body);
  Check(ObjectReferenceCount(Body) = ObjectReferenceCountLimit, 'a reference count did not reach the limit');
  ReferenceObject(Body);
  Check(ObjectReferenceCount(Body) = ObjectReferenceCountLimit, 'a reference count went past the limit');
  DereferenceObject(Body);
  Check(ObjectReferenceCount(Body) = ObjectReferenceCountLimit, 'a saturated reference count dropped');
  Check(not SaturationObjectDeleted, 'an object with a saturated count was deleted');
  { Back to an ordinary count, so the test object goes away. }
  SetObjectReferenceCountForTest(Body, 1);
  DereferenceObject(Body);
  Check(SaturationObjectDeleted, 'the reference count test object was not deleted');
  ReportPassed('object reference counts saturate');
end;

procedure RunProtectionSelfTests;
begin
  TestNoWritableExecutablePages;
  TestKernelImageProtection;
  TestUserPagesNotKernelExecutable;
  TestUserCopyWithProtection;
  TestPhysicalPageQuarantine;
  TestReferenceCountSaturation;
end;

end.
