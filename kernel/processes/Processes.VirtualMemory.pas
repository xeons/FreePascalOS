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
  Reserving, committing, decommitting and protecting user memory, and
  mapping files (the work behind CallReserveMemory and its group,
  Processes.VirtualMemoryCalls, and CallMapHandle on files).

  A reservation is address space without memory: a region of the run
  time allocation area with no access that is not committed. Committing
  part of it splits it (Processes.RegionEditing) and makes that part an
  ordinary on-demand region with the protection asked for, counted
  against the commit charge; decommitting gives the pages back and makes
  the part reserved again. Pieces that end up alike are joined again.
  Run time allocations (CallAllocateMemory) are reservations committed
  whole, so they may be decommitted and protected in parts too.

  Protection is per region: changing it maps the pages already there
  again (a page the program may not touch stays, for the kernel only:
  MappingNoAccess). User memory is never writable and executable at
  once; and memory becomes executable only in a process that asked for
  it (AllowsDynamicCode, CallSetMemoryPolicy) - a compiler at run time
  writes code into read-write pages and then protects them read-execute.
  Program images and files mapped executable from the start are code
  from files, which needs no such permission.

  A guard (MemoryGuard) is a one-shot trap: the first touch raises
  ExceptionGuardPage and leaves an ordinary page behind
  (Processes.AddressSpace's fault resolver).
}
unit Processes.VirtualMemory;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Processes.AddressSpace,
  Processes.MappedFiles;

{ Reserves Length bytes (rounded up to pages). }
function ReserveAddressRange(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
{ Commits [Address, Address + Length) of one reservation or allocation
  with a Memory* protection. }
function CommitAddressRange(Space: PAddressSpace; Address, Length: QWord; Protection: LongWord): LongInt;
function DecommitAddressRange(Space: PAddressSpace; Address, Length: QWord): LongInt;
{ Changes the protection of committed pages; Previous is the first
  page's. }
function ProtectAddressRange(Space: PAddressSpace; Address, Length: QWord; Protection: LongWord;
  out Previous: LongWord): LongInt;
procedure QueryAddress(Space: PAddressSpace; Address: QWord; out Information: TAbiMemoryInformation);
{ Maps Length bytes of MappedFile from Offset (page aligned; Length 0:
  to the file's end) with Map* Flags. On success the mapping holds the
  caller's reference to MappedFile (taken private if Flags has
  MapPrivate). }
function MapFileIntoAddressSpace(Space: PAddressSpace; MappedFile: PMappedFile; Offset, Length: QWord;
  Flags: LongWord; out Start: QWord): LongInt;

{ Gives the out-of-memory policy (Processes.MemoryCharges) the commit
  charge: a process's commitment beyond its resident private pages, and
  the system's total. }
procedure InitializeVirtualMemory;

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.Arch.PageTables,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Memory.CommitCharge,
  Processes.Process,
  Processes.MemoryCharges,
  Processes.UserRegions;

const
  ProtectionAccessMask = MemoryRead or MemoryWrite or MemoryExecute;

{ The region attributes for Protection. }
function AttributesFor(Protection: LongWord; out Attributes: LongWord; out IsGuard: Boolean): LongInt;
var
  Access: LongWord;
begin
  Attributes := 0;
  IsGuard := (Protection and MemoryGuard) <> 0;
  if (Protection and not (ProtectionAccessMask or MemoryGuard)) <> 0 then
    Exit(ErrorInvalidArgument);
  Access := Protection and ProtectionAccessMask;
  { Writing or running implies reading. }
  if Access <> 0 then
    Attributes := RegionReadable;
  if (Access and MemoryWrite) <> 0 then
    Attributes := Attributes or RegionWritable;
  if (Access and MemoryExecute) <> 0 then
    Attributes := Attributes or RegionExecutable;
  if (Attributes and (RegionWritable or RegionExecutable)) = (RegionWritable or RegionExecutable) then
    Exit(ErrorAccessDenied);
  Result := ErrorNone;
end;

function ProtectionOf(Region: PUserRegion): LongWord;
begin
  Result := MemoryNoAccess;
  if (Region^.Attributes and RegionReadable) <> 0 then
    Result := Result or MemoryRead;
  if (Region^.Attributes and RegionWritable) <> 0 then
    Result := Result or MemoryWrite;
  if (Region^.Attributes and RegionExecutable) <> 0 then
    Result := Result or MemoryExecute;
  if Region^.IsGuard then
    Result := Result or MemoryGuard;
end;

function IsCommitted(Region: PUserRegion): Boolean;
begin
  Result := (Region^.Kind <> RegionKindAllocation) or Region^.CommitsOnDemand;
end;

{ Checks that [Address, Address + Length) is covered by pieces of one
  allocation of the given kinds, without gaps. Caller holds the lock. }
function RangeIsOneAllocation(Space: PAddressSpace; Address, Length: QWord; AllowFileMappings: Boolean): Boolean;
var
  Position: QWord;
  Region: PUserRegion;
  AllocationBase: QWord;
begin
  Result := False;
  Position := Address;
  AllocationBase := 0;
  while Position < Address + Length do
  begin
    Region := FindRegionLocked(Space, Position);
    if (Region = nil) or (Region^.AllocationBase = 0) then
      Exit;
    if not ((Region^.Kind = RegionKindAllocation) or
            (AllowFileMappings and (Region^.Kind = RegionKindFileMapping))) then
      Exit;
    if AllocationBase = 0 then
      AllocationBase := Region^.AllocationBase
    else if Region^.AllocationBase <> AllocationBase then
      Exit;
    Position := Region^.Start + Region^.Length;
  end;
  Result := True;
end;

{ Page aligned, not empty, inside user space; Length rounded up. }
function NormalizeRange(Address: QWord; var Length: QWord): Boolean;
begin
  Result := False;
  if ((Address and PageOffsetMask) <> 0) or (Length = 0) or (Address = 0) then
    Exit;
  if (Address >= UserSpaceLimit) or (Length > UserSpaceLimit - Address) then
    Exit;
  Length := RoundUpToPage(Length);
  Result := True;
end;

{ The bytes of Region inside [Address, Finish). }
function OverlapBytes(Region: PUserRegion; Address, Finish: QWord): QWord;
var
  First: QWord;
  Last: QWord;
begin
  First := Region^.Start;
  if First < Address then
    First := Address;
  Last := Region^.Start + Region^.Length;
  if Last > Finish then
    Last := Finish;
  if Last > First then
    Result := Last - First
  else
    Result := 0;
end;

{ Splits at both ends of the range. }
function IsolateRange(Space: PAddressSpace; Address, Length: QWord): LongInt;
begin
  Result := SplitRegionLocked(Space, Address);
  if Result = ErrorNone then
    Result := SplitRegionLocked(Space, Address + Length);
end;

function ReserveAddressRange(Space: PAddressSpace; Length: QWord; out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Template: TUserRegion;
begin
  Start := 0;
  if (Length = 0) or (Length > UserAllocationLimit - UserAllocationBase) then
    Exit(ErrorInvalidArgument);
  Length := RoundUpToPage(Length);
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not FindAllocationRangeLocked(Space, Length, Space^.Layout.AllocationBase, Start) then
    Result := ErrorOutOfMemory
  else
  begin
    FillMemory(@Template, SizeOf(Template), 0);
    Template.Start := Start;
    Template.Length := Length;
    Template.Kind := RegionKindAllocation;
    Template.AllocationBase := Start;
    Result := AddRegionRecordLocked(Space, Template);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Result <> ErrorNone then
    Start := 0;
end;

function CommitAddressRange(Space: PAddressSpace; Address, Length: QWord; Protection: LongWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Attributes: LongWord;
  IsGuard: Boolean;
  Position: QWord;
  Finish: QWord;
  Region: PUserRegion;
  AddedPages: QWord;
begin
  if not NormalizeRange(Address, Length) then
    Exit(ErrorInvalidArgument);
  Result := AttributesFor(Protection, Attributes, IsGuard);
  if Result <> ErrorNone then
    Exit;
  Finish := Address + Length;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if ((Attributes and RegionExecutable) <> 0) and not Space^.AllowsDynamicCode then
    Result := ErrorAccessDenied
  else if not RangeIsOneAllocation(Space, Address, Length, False) then
    Result := ErrorInvalidArgument;
  if Result = ErrorNone then
  begin
    { The pages not committed yet are counted first, all or nothing. }
    AddedPages := 0;
    Position := Address;
    while Position < Finish do
    begin
      Region := FindRegionLocked(Space, Position);
      if not Region^.CommitsOnDemand then
        AddedPages := AddedPages + OverlapBytes(Region, Address, Finish) div PageSize;
      Position := Region^.Start + Region^.Length;
    end;
    Result := ChargeCommitLocked(Space, AddedPages);
    if Result = ErrorNone then
    begin
      Result := IsolateRange(Space, Address, Length);
      if Result <> ErrorNone then
        UnchargeCommitLocked(Space, AddedPages);
    end;
  end;
  if Result = ErrorNone then
  begin
    Position := Address;
    while Position < Finish do
    begin
      Region := FindRegionLocked(Space, Position);
      Region^.CommitsOnDemand := True;
      Region^.Attributes := Attributes;
      Region^.IsGuard := IsGuard;
      ApplyRegionProtectionLocked(Space, Region^.Start, Region^.Length);
      Position := Region^.Start + Region^.Length;
    end;
    MergeRegionsLocked(Space, Address, Finish);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function DecommitAddressRange(Space: PAddressSpace; Address, Length: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Position: QWord;
  Finish: QWord;
  Region: PUserRegion;
begin
  if not NormalizeRange(Address, Length) then
    Exit(ErrorInvalidArgument);
  Finish := Address + Length;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not RangeIsOneAllocation(Space, Address, Length, False) then
    Result := ErrorInvalidArgument
  else
    Result := IsolateRange(Space, Address, Length);
  if Result = ErrorNone then
  begin
    Position := Address;
    while Position < Finish do
    begin
      Region := FindRegionLocked(Space, Position);
      ReleaseRegionPagesLocked(Space, Region^.Start, Region^.Length);
      UnchargeCommitLocked(Space, RegionChargePages(Region^));
      Region^.CommitsOnDemand := False;
      Region^.Attributes := 0;
      Region^.IsGuard := False;
      Position := Region^.Start + Region^.Length;
    end;
    MergeRegionsLocked(Space, Address, Finish);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

{ The change in commit charge if Region's part in [Address, Finish) got
  Attributes. }
function ChargeChange(Region: PUserRegion; Address, Finish: QWord; Attributes: LongWord): Int64;
var
  Changed: TUserRegion;
  Pages: QWord;
begin
  Pages := OverlapBytes(Region, Address, Finish) div PageSize;
  Changed := Region^;
  Changed.Length := Pages * PageSize;
  Result := -Int64(RegionChargePages(Changed));
  Changed.Attributes := Attributes;
  Result := Result + Int64(RegionChargePages(Changed));
end;

function ProtectAddressRange(Space: PAddressSpace; Address, Length: QWord; Protection: LongWord;
  out Previous: LongWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Attributes: LongWord;
  IsGuard: Boolean;
  Position: QWord;
  Finish: QWord;
  Region: PUserRegion;
  Delta: Int64;
begin
  Previous := 0;
  if not NormalizeRange(Address, Length) then
    Exit(ErrorInvalidArgument);
  Result := AttributesFor(Protection, Attributes, IsGuard);
  if Result <> ErrorNone then
    Exit;
  Finish := Address + Length;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not RangeIsOneAllocation(Space, Address, Length, True) then
    Result := ErrorInvalidArgument;
  Delta := 0;
  Position := Address;
  while (Result = ErrorNone) and (Position < Finish) do
  begin
    Region := FindRegionLocked(Space, Position);
    if Position = Address then
      Previous := ProtectionOf(Region);
    if not IsCommitted(Region) then
      Result := ErrorInvalidArgument
    { A shared file mapping is never written (nothing writes it back). }
    else if (Region^.Kind = RegionKindFileMapping) and not Region^.BackingIsPrivate and
       ((Attributes and RegionWritable) <> 0) then
      Result := ErrorAccessDenied
    { Code from a file shared read-only needs no permission; anything
      else made executable does. }
    else if ((Attributes and RegionExecutable) <> 0) and not Space^.AllowsDynamicCode and
       not ((Region^.Kind = RegionKindFileMapping) and not Region^.BackingIsPrivate) then
      Result := ErrorAccessDenied
    else
      Delta := Delta + ChargeChange(Region, Address, Finish, Attributes);
    Position := Region^.Start + Region^.Length;
  end;
  if (Result = ErrorNone) and (Delta > 0) then
    Result := ChargeCommitLocked(Space, QWord(Delta));
  if Result = ErrorNone then
  begin
    Result := IsolateRange(Space, Address, Length);
    if (Result <> ErrorNone) and (Delta > 0) then
      UnchargeCommitLocked(Space, QWord(Delta));
  end;
  if Result = ErrorNone then
  begin
    if Delta < 0 then
      UnchargeCommitLocked(Space, QWord(-Delta));
    Position := Address;
    while Position < Finish do
    begin
      Region := FindRegionLocked(Space, Position);
      Region^.Attributes := Attributes;
      Region^.IsGuard := IsGuard;
      ApplyRegionProtectionLocked(Space, Region^.Start, Region^.Length);
      Position := Region^.Start + Region^.Length;
    end;
    MergeRegionsLocked(Space, Address, Finish);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function KindOf(Region: PUserRegion): LongWord;
begin
  case Region^.Kind of
    RegionKindImage: Result := MemoryKindImage;
    RegionKindStack: Result := MemoryKindStack;
    RegionKindAllocation: Result := MemoryKindPrivate;
    RegionKindThreadData: Result := MemoryKindThreadData;
    RegionKindStackGuard: Result := MemoryKindStackGuard;
    RegionKindDevice: Result := MemoryKindDevice;
    RegionKindSection: Result := MemoryKindSection;
    RegionKindFileMapping: Result := MemoryKindFileMapping;
  else
    Result := MemoryKindNone;
  end;
end;

procedure QueryAddress(Space: PAddressSpace; Address: QWord; out Information: TAbiMemoryInformation);
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
  Page: QWord;
begin
  FillMemory(@Information, SizeOf(Information), 0);
  Page := RoundDownToPage(Address);
  if Page >= UserSpaceLimit then
    Exit;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionAtOrAboveLocked(Space, Page);
  if (Region = nil) or (Region^.Start > Page) then
  begin
    Information.BaseAddress := Page;
    if Region = nil then
      Information.Length := UserSpaceLimit - Page
    else
      Information.Length := Region^.Start - Page;
    Information.State := MemoryStateFree;
  end
  else
  begin
    Information.BaseAddress := Region^.Start;
    Information.Length := Region^.Length;
    if Region^.AllocationBase <> 0 then
      Information.AllocationBase := Region^.AllocationBase
    else
      Information.AllocationBase := Region^.Start;
    if (Region^.Kind = RegionKindStackGuard) or not IsCommitted(Region) then
      Information.State := MemoryStateReserved
    else
    begin
      Information.State := MemoryStateCommitted;
      Information.Protection := ProtectionOf(Region);
    end;
    Information.Kind := KindOf(Region);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function MapFileIntoAddressSpace(Space: PAddressSpace; MappedFile: PMappedFile; Offset, Length: QWord;
  Flags: LongWord; out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Template: TUserRegion;
  FileBytes: QWord;
begin
  Start := 0;
  if (Flags and not (MapPrivate or MapWritable or MapExecutable)) <> 0 then
    Exit(ErrorInvalidArgument);
  { Nothing writes a shared mapping's pages back to the file yet. }
  if ((Flags and MapWritable) <> 0) and ((Flags and MapPrivate) = 0) then
    Exit(ErrorUnsupported);
  if (Flags and (MapWritable or MapExecutable)) = (MapWritable or MapExecutable) then
    Exit(ErrorAccessDenied);
  FileBytes := MappedFile^.PageCount * PageSize;
  if ((Offset and PageOffsetMask) <> 0) or (Offset >= FileBytes) then
    Exit(ErrorInvalidArgument);
  if Length = 0 then
    Length := FileBytes - Offset;
  Length := RoundUpToPage(Length);
  if Length > FileBytes - Offset then
    Exit(ErrorInvalidArgument);

  FillMemory(@Template, SizeOf(Template), 0);
  Template.Length := Length;
  Template.Kind := RegionKindFileMapping;
  Template.Attributes := RegionReadable;
  if (Flags and MapWritable) <> 0 then
    Template.Attributes := Template.Attributes or RegionWritable;
  if (Flags and MapExecutable) <> 0 then
    Template.Attributes := Template.Attributes or RegionExecutable;
  Template.CommitsOnDemand := True;
  Template.Backing := MappedFile;
  Template.BackingOffset := Offset;
  Template.BackingIsPrivate := (Flags and MapPrivate) <> 0;

  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if not FindAllocationRangeLocked(Space, Length, Space^.Layout.AllocationBase, Start) then
    Result := ErrorOutOfMemory
  else
  begin
    Template.Start := Start;
    Template.AllocationBase := Start;
    Result := AddRegionRecordLocked(Space, Template);
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
  if Result <> ErrorNone then
    Start := 0;
end;

{ Called with the process registry lock held; the figures are read
  under the slot's lock (an exec or exit may replace the space). }
function CommitBeyondResident(Process: PProcess): QWord;
var
  Usage: TAddressSpaceUsage;
  PrivateResident: QWord;
begin
  Result := 0;
  if not ReadPublishedSpaceUsage(Process^.AddressSpace, Usage) then
    Exit;
  PrivateResident := 0;
  if Usage.ResidentPages > Usage.SharedPages then
    PrivateResident := Usage.ResidentPages - Usage.SharedPages;
  if Usage.CommitChargePages > PrivateResident then
    Result := Usage.CommitChargePages - PrivateResident;
end;

function SystemCommitTotal: QWord;
begin
  Result := Memory.CommitCharge.SystemCommittedPages;
end;

procedure InitializeVirtualMemory;
begin
  SetCommitCounters(@CommitBeyondResident, @SystemCommitTotal);
end;

end.
