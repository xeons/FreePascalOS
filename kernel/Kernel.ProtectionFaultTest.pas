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
  Deliberate violations of the kernel's memory protection, one per boot,
  chosen with the kernel option "selftest=KIND". Each must stop the
  system with the right fault report (scripts/test-protection-faults.sh
  boots each and checks the report):

    nx          runs code placed in the kernel's data
                ("Instruction fetch from ... (protection violation")
    textwrite   writes into the kernel's code
                ("Write to ... (protection violation")
    userexec    runs code from a user page (SMEP, PXN)
                ("Instruction fetch from ... (protection violation")
    useraccess  reads a user page directly, not through a copy routine
                (SMAP, PAN: "Read from ... (protection violation")
    pagepoison  writes into a freed physical page held back by the
                quarantine (with "heapchecks": "physical page written
                after it was freed")

  When the processor lacks the protection, the test says so and stops
  the system with an assertion instead, so the report shows what was
  missing rather than passing.
}
unit Kernel.ProtectionFaultTest;

{$mode objfpc}
{$pointermath on}

interface

const
  OptionProtectionFaultTest = 'selftest';

{ Runs the violation the option asks for, if any (it does not return
  then). }
procedure RunProtectionFaultTest;

implementation

uses
  Runtime.Text,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.HeapChecks,
  Memory.PageQuarantine,
  Memory.Arch.PageTables,
  Memory.Arch.MappingAudit,
  Kernel.Arch.UserCopy,
  Kernel.Options,
  Kernel.Panic,
  Kernel.SelfTest,
  Kernel.TestUserSpace,
  Debug.Output;

type
  TCodeRoutine = procedure;

var
  { Code placed in the kernel's (writable, no-execute) data. }
  CodeInData: array[0..3] of LongWord;
  KernelTextStart: Byte; external name 'KernelTextStart';

procedure AnnounceViolation(Kind: PChar; Description: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite('Deliberate protection violation "');
  DebugWrite(Kind);
  DebugWrite('": ');
  DebugWrite(Description);
  DebugWriteLine('; the system must stop with a fault report');
  DebugEndMessage;
end;

procedure StopUnprotected(Description: PChar);
begin
  KernelPanicWithCode(PanicAssertionFailed, Description, 0, 0, 0, 0);
end;

procedure RunCodeInData;
var
  Routine: TCodeRoutine;
begin
  AnnounceViolation('nx', 'running code in the kernel''s data');
  CodeInData[0] := ReturnInstruction;
  if not NoExecuteIsSupported then
    StopUnprotected('selftest=nx: the processor has no no-execute bit');
  Routine := TCodeRoutine(Pointer(@CodeInData[0]));
  Routine();
  StopUnprotected('selftest=nx: code in the kernel''s data ran');
end;

procedure WriteIntoKernelText;
var
  Target: PByte;
begin
  AnnounceViolation('textwrite', 'writing into the kernel''s code');
  Target := PByte(@KernelTextStart);
  Target^ := Target^ + 1;
  StopUnprotected('selftest=textwrite: the kernel''s code was written');
end;

procedure RunUserCode;
var
  Space: TTestUserSpace;
  Routine: TCodeRoutine;
begin
  AnnounceViolation('userexec', 'running code from a user page');
  Check(CreateTestUserSpace(Space), 'no memory for a test address space');
  EnterTestUserSpace(Space);
  Routine := TCodeRoutine(Pointer(TestUserCodeAddress));
  Routine();
  LeaveTestUserSpace(Space);
  StopUnprotected('selftest=userexec: the kernel ran code from a user page (no SMEP)');
end;

procedure ReadUserMemoryDirectly;
var
  Space: TTestUserSpace;
  Value: QWord;
begin
  AnnounceViolation('useraccess', 'reading user memory without a copy routine');
  Check(CreateTestUserSpace(Space), 'no memory for a test address space');
  EnterTestUserSpace(Space);
  Value := PQWord(TestUserDataAddress)^;
  LeaveTestUserSpace(Space);
  if Value <> TestUserDataValue then
    StopUnprotected('selftest=useraccess: the read returned the wrong value');
  if UserMemoryIsProtected then
    StopUnprotected('selftest=useraccess: a direct read of user memory was not stopped')
  else
    StopUnprotected('selftest=useraccess: the processor has no SMAP/PAN');
end;

procedure WriteIntoFreedPage;
var
  Page: TPhysicalAddress;
  Filler: TPhysicalAddress;
  Count: QWord;
begin
  AnnounceViolation('pagepoison', 'writing into a freed physical page');
  if KernelHeapCheckLevel <> HeapChecksQuarantine then
    StopUnprotected('selftest=pagepoison: needs "heapchecks"');
  Page := AllocatePhysicalPage(PageUsageGeneral);
  Check(Page <> 0, 'no physical page for the test');
  FreePhysicalPage(Page);
  PByte(PhysicalToVirtual(Page))[123] := $42;
  Count := 0;
  while Count < PageQuarantineCapacity do
  begin
    Filler := AllocatePhysicalPage(PageUsageGeneral);
    Check(Filler <> 0, 'no physical page for the test');
    FreePhysicalPage(Filler);
    Inc(Count);
  end;
  StopUnprotected('selftest=pagepoison: the write into a freed page was not found');
end;

procedure RunProtectionFaultTest;
const
  KindCapacity = 32;
var
  Kind: array[0..KindCapacity - 1] of Char;
begin
  if not GetKernelOptionValue(OptionProtectionFaultTest, @Kind[0], KindCapacity) then
    Exit;
  if TextIsEqual(@Kind[0], 'nx') then
    RunCodeInData
  else if TextIsEqual(@Kind[0], 'textwrite') then
    WriteIntoKernelText
  else if TextIsEqual(@Kind[0], 'userexec') then
    RunUserCode
  else if TextIsEqual(@Kind[0], 'useraccess') then
    ReadUserMemoryDirectly
  else if TextIsEqual(@Kind[0], 'pagepoison') then
    WriteIntoFreedPage;
end;

end.
