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
  A small user address space for the protection self tests
  (Kernel.ProtectionSelfTest, Kernel.ProtectionFaultTest): one writable
  data page and one executable code page holding a return instruction,
  which the calling kernel thread can switch to and back from.

  The thread's own address space field changes with it, so the
  scheduler keeps the space loaded whenever the thread runs.
}
unit Kernel.TestUserSpace;

{$mode objfpc}

interface

uses
  Memory.Layout;

const
  TestUserDataAddress = QWord($0000000010000000);
  TestUserCodeAddress = QWord($0000000010001000);
  { An address in the space with nothing mapped. }
  TestUserUnmappedAddress = QWord($0000000010010000);
  TestUserDataValue = QWord($5445535455534552);

type
  TTestUserSpace = record
    Root: TPhysicalAddress;
    DataPage: TPhysicalAddress;
    CodePage: TPhysicalAddress;
    PreviousRoot: QWord;
    IsEntered: Boolean;
  end;

{ Builds the space; False if memory ran out (nothing is left behind). }
function CreateTestUserSpace(out Space: TTestUserSpace): Boolean;
{ Makes the space the calling thread's. }
procedure EnterTestUserSpace(var Space: TTestUserSpace);
procedure LeaveTestUserSpace(var Space: TTestUserSpace);
{ Leaves it if needed, and frees it. }
procedure DestroyTestUserSpace(var Space: TTestUserSpace);

implementation

uses
  Memory.PhysicalPages,
  Memory.Arch.PageTables,
  Memory.Arch.MappingAudit,
  Kernel.Scheduler;

function CreateTestUserSpace(out Space: TTestUserSpace): Boolean;
begin
  Result := False;
  Space.IsEntered := False;
  Space.PreviousRoot := 0;
  Space.DataPage := AllocateZeroedPhysicalPage(PageUsageUserMemory);
  Space.CodePage := AllocateZeroedPhysicalPage(PageUsageUserMemory);
  Space.Root := CreateAddressSpaceRoot;
  if (Space.DataPage = 0) or (Space.CodePage = 0) or (Space.Root = 0) then
  begin
    if Space.DataPage <> 0 then
      FreePhysicalPage(Space.DataPage);
    if Space.CodePage <> 0 then
      FreePhysicalPage(Space.CodePage);
    if Space.Root <> 0 then
      DestroyAddressSpaceRoot(Space.Root);
    Exit;
  end;
  PQWord(PhysicalToVirtual(Space.DataPage))^ := TestUserDataValue;
  PLongWord(PhysicalToVirtual(Space.CodePage))^ := ReturnInstruction;
  { Mapped pages belong to the root from here on: destroying it frees
    them. }
  if not MapPageInAddressSpace(Space.Root, TestUserDataAddress, Space.DataPage, MappingWritable) then
  begin
    FreePhysicalPage(Space.DataPage);
    FreePhysicalPage(Space.CodePage);
    DestroyAddressSpaceRoot(Space.Root);
    Exit;
  end;
  if not MapPageInAddressSpace(Space.Root, TestUserCodeAddress, Space.CodePage, MappingExecutable) then
  begin
    FreePhysicalPage(Space.CodePage);
    DestroyAddressSpaceRoot(Space.Root);
    Exit;
  end;
  Result := True;
end;

procedure EnterTestUserSpace(var Space: TTestUserSpace);
begin
  if Space.IsEntered then
    Exit;
  Space.PreviousRoot := CurrentThread^.AddressSpaceRoot;
  CurrentThread^.AddressSpaceRoot := Space.Root;
  ActivateAddressSpace(Space.Root);
  Space.IsEntered := True;
end;

procedure LeaveTestUserSpace(var Space: TTestUserSpace);
begin
  if not Space.IsEntered then
    Exit;
  CurrentThread^.AddressSpaceRoot := Space.PreviousRoot;
  ActivateAddressSpace(Space.PreviousRoot);
  Space.IsEntered := False;
end;

procedure DestroyTestUserSpace(var Space: TTestUserSpace);
var
  Physical: TPhysicalAddress;
begin
  LeaveTestUserSpace(Space);
  { Unmapped first, so no processor keeps a translation of the pages
    (the unmap invalidates them everywhere). }
  Physical := UnmapPageInAddressSpace(Space.Root, TestUserDataAddress);
  if Physical <> 0 then
    FreePhysicalPage(Physical);
  Physical := UnmapPageInAddressSpace(Space.Root, TestUserCodeAddress);
  if Physical <> 0 then
    FreePhysicalPage(Physical);
  DestroyAddressSpaceRoot(Space.Root);
  Space.Root := 0;
end;

end.
