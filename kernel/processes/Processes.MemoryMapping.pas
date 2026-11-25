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
  POSIX mappings: mmap and munmap over the region tree (the work behind
  CallMapMemory and CallUnmapMemory, Processes.PosixMemoryCalls).

  A mapping is anonymous memory (zero filled when touched, or address
  space alone with PROT_NONE: a reservation) or a file's pages
  (Processes.MappedFiles: shared read-only, or private copy on write).
  Without MAP_FIXED it goes where the run time allocation area has room
  (at the hint if the hint is free). With MAP_FIXED it goes exactly at
  the address: into free address space, or over pieces of run time
  allocations and mappings, which it replaces - what a dynamic linker
  does when it reserves a library's span and maps each segment into
  it. A mapping placed inside an allocation becomes a piece of that
  allocation (the same AllocationBase), so CallFreeMemory of the
  allocation's start still frees all of it. Program images, stacks,
  thread data and device memory are never replaced or unmapped this way
  (ErrorInvalidArgument).

  munmap takes the pages of [Address, Address + Length) away from the
  allocations and mappings there, splitting them; pieces after the range
  whose allocation started inside it become an allocation of their own.

  User memory is never writable and executable at once, and anonymous
  memory is executable only in a process that asked for it
  (Processes.VirtualMemory); a file may be mapped executable when it is
  not writable.
}
unit Processes.MemoryMapping;

{$mode objfpc}

interface

uses
  Processes.AddressSpace,
  Processes.MappedFiles;

const
  { The Linux values, which the C library passes through. }
  PosixProtectionRead = $1;
  PosixProtectionWrite = $2;
  PosixProtectionExecute = $4;
  PosixMapShared = $01;
  PosixMapPrivate = $02;
  PosixMapFixed = $10;
  PosixMapAnonymous = $20;
  PosixMapFixedNoReplace = $100000;

{ Maps Length bytes; MappedFile nil for anonymous memory, else the file
  (whose reference the mapping takes over on success) from the page
  aligned Offset. Returns ErrorNone and the mapping's address. }
function MapMemory(Space: PAddressSpace; Address, Length, Protection, Flags: QWord;
  MappedFile: PMappedFile; Offset: QWord; out Start: QWord): LongInt;

{ Unmaps [Address, Address + Length); nothing mapped there is no error. }
function UnmapMemory(Space: PAddressSpace; Address, Length: QWord): LongInt;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.Arch.PageTables,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Processes.UserRegions;

function AttributesForProtection(Protection: QWord; out Attributes: LongWord): LongInt;
begin
  Attributes := 0;
  if (Protection and not QWord(PosixProtectionRead or PosixProtectionWrite or PosixProtectionExecute)) <> 0 then
    Exit(ErrorInvalidArgument);
  if Protection <> 0 then
    Attributes := RegionReadable;
  if (Protection and PosixProtectionWrite) <> 0 then
    Attributes := Attributes or RegionWritable;
  if (Protection and PosixProtectionExecute) <> 0 then
    Attributes := Attributes or RegionExecutable;
  if (Attributes and (RegionWritable or RegionExecutable)) = (RegionWritable or RegionExecutable) then
    Exit(ErrorAccessDenied);
  Result := ErrorNone;
end;

{ Allocations and file mappings may be replaced and unmapped. }
function IsReplaceable(Region: PUserRegion): Boolean;
begin
  Result := (Region^.Kind = RegionKindAllocation) or (Region^.Kind = RegionKindFileMapping);
end;

function RangeIsFree(Space: PAddressSpace; Address, Length: QWord): Boolean;
var
  Region: PUserRegion;
begin
  Region := FindRegionLocked(Space, Address);
  if Region <> nil then
    Exit(False);
  Region := FindRegionAtOrAboveLocked(Space, Address);
  Result := (Region = nil) or (Region^.Start >= Address + Length);
end;

{ Checks [Address, Address + Length): every region there may be
  replaced. Covered is True if regions cover all of it without gaps,
  and Base the AllocationBase they share (0 if they share none). }
function SurveyRange(Space: PAddressSpace; Address, Length: QWord; out Covered: Boolean;
  out Base: QWord): Boolean;
var
  Position: QWord;
  Region: PUserRegion;
  First: Boolean;
begin
  Result := True;
  Covered := True;
  Base := 0;
  First := True;
  Position := Address;
  while Position < Address + Length do
  begin
    Region := FindRegionLocked(Space, Position);
    if Region = nil then
    begin
      Covered := False;
      Region := FindRegionAtOrAboveLocked(Space, Position);
      if (Region = nil) or (Region^.Start >= Address + Length) then
        Break;
      Position := Region^.Start;
      Continue;
    end;
    if not IsReplaceable(Region) then
      Exit(False);
    if First then
      Base := Region^.AllocationBase
    else if Region^.AllocationBase <> Base then
      Base := 0;
    First := False;
    Position := Region^.Start + Region^.Length;
  end;
  if not Covered then
    Base := 0;
end;

{ After [Address, Finish) was emptied: pieces of an allocation that
  started inside it become an allocation of their own. }
procedure RebaseOrphanedPieces(Space: PAddressSpace; Address, Finish: QWord);
var
  Region: PUserRegion;
  OldBase: QWord;
  Position: QWord;
begin
  Region := FindRegionLocked(Space, Finish);
  if (Region = nil) or (Region^.Start <> Finish) then
    Exit;
  OldBase := Region^.AllocationBase;
  if (OldBase = 0) or (OldBase < Address) or (OldBase >= Finish) then
    Exit;
  Position := Finish;
  repeat
    Region := FindRegionLocked(Space, Position);
    if (Region = nil) or (Region^.Start <> Position) or (Region^.AllocationBase <> OldBase) then
      Break;
    Region^.AllocationBase := Finish;
    Position := Region^.Start + Region^.Length;
  until False;
end;

{ Removes every region piece inside [Address, Address + Length), which
  must hold only replaceable ones. Caller holds the lock. }
function EmptyRangeLocked(Space: PAddressSpace; Address, Length: QWord): LongInt;
var
  Position: QWord;
  Region: PUserRegion;
begin
  Result := SplitRegionLocked(Space, Address);
  if Result = ErrorNone then
    Result := SplitRegionLocked(Space, Address + Length);
  if Result <> ErrorNone then
    Exit;
  Position := Address;
  while Position < Address + Length do
  begin
    Region := FindRegionAtOrAboveLocked(Space, Position);
    if (Region = nil) or (Region^.Start >= Address + Length) then
      Break;
    Position := Region^.Start + Region^.Length;
    RemoveAllocationPieceLocked(Space, Region^.Start);
  end;
  RebaseOrphanedPieces(Space, Address, Address + Length);
end;

procedure FillTemplate(out Template: TUserRegion; Start, Length: QWord; Attributes: LongWord;
  MappedFile: PMappedFile; Offset: QWord; IsPrivate: Boolean);
begin
  FillMemory(@Template, SizeOf(Template), 0);
  Template.Start := Start;
  Template.Length := Length;
  Template.Attributes := Attributes;
  Template.AllocationBase := Start;
  if MappedFile = nil then
  begin
    Template.Kind := RegionKindAllocation;
    { PROT_NONE: address space alone, as CallReserveMemory makes. }
    Template.CommitsOnDemand := Attributes <> 0;
  end
  else
  begin
    Template.Kind := RegionKindFileMapping;
    Template.CommitsOnDemand := True;
    Template.Backing := MappedFile;
    Template.BackingOffset := Offset;
    Template.BackingIsPrivate := IsPrivate;
  end;
end;

function MapMemory(Space: PAddressSpace; Address, Length, Protection, Flags: QWord;
  MappedFile: PMappedFile; Offset: QWord; out Start: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Attributes: LongWord;
  IsPrivate: Boolean;
  IsFixed: Boolean;
  Covered: Boolean;
  Base: QWord;
  Template: TUserRegion;
begin
  Start := 0;
  if (Length = 0) or (Length > UserAllocationLimit - UserAllocationBase) then
    Exit(ErrorInvalidArgument);
  Length := RoundUpToPage(Length);
  Result := AttributesForProtection(Protection, Attributes);
  if Result <> ErrorNone then
    Exit;
  IsPrivate := (Flags and PosixMapPrivate) <> 0;
  if IsPrivate = ((Flags and PosixMapShared) <> 0) then
    Exit(ErrorInvalidArgument);
  IsFixed := (Flags and (PosixMapFixed or PosixMapFixedNoReplace)) <> 0;
  if IsFixed and (((Address and PageOffsetMask) <> 0) or (Address = 0) or
     (Address >= UserSpaceLimit) or (Length > UserSpaceLimit - Address)) then
    Exit(ErrorInvalidArgument);
  if MappedFile <> nil then
  begin
    if (Offset and PageOffsetMask) <> 0 then
      Exit(ErrorInvalidArgument);
    { Nothing writes a shared mapping's pages back to the file yet. }
    if not IsPrivate and ((Attributes and RegionWritable) <> 0) then
      Exit(ErrorUnsupported);
    if Offset >= MappedFile^.PageCount * PageSize then
      Exit(ErrorInvalidArgument);
    if Length > MappedFile^.PageCount * PageSize - Offset then
      Length := MappedFile^.PageCount * PageSize - Offset;
  end;

  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if (MappedFile = nil) and ((Attributes and RegionExecutable) <> 0) and not Space^.AllowsDynamicCode then
    Result := ErrorAccessDenied
  else if IsFixed then
  begin
    Base := 0;
    if not RangeIsFree(Space, Address, Length) then
    begin
      if (Flags and PosixMapFixedNoReplace) <> 0 then
        Result := ErrorExists
      else if not SurveyRange(Space, Address, Length, Covered, Base) then
        Result := ErrorInvalidArgument
      else
        Result := EmptyRangeLocked(Space, Address, Length);
    end;
    if Result = ErrorNone then
    begin
      FillTemplate(Template, Address, Length, Attributes, MappedFile, Offset, IsPrivate);
      if Base <> 0 then
        Template.AllocationBase := Base;
      Result := AddRegionRecordLocked(Space, Template);
      if Result = ErrorNone then
        Start := Address;
    end;
  end
  else
  begin
    if (Address <> 0) and ((Address and PageOffsetMask) = 0) and (Address >= UserAllocationBase) and
       (Address < UserSpaceLimit) and (Length <= UserSpaceLimit - Address) and
       RangeIsFree(Space, Address, Length) then
      Start := Address
    else if not FindAllocationRangeLocked(Space, Length, Space^.Layout.AllocationBase, Start) then
      Result := ErrorOutOfMemory;
    if Result = ErrorNone then
    begin
      FillTemplate(Template, Start, Length, Attributes, MappedFile, Offset, IsPrivate);
      Result := AddRegionRecordLocked(Space, Template);
    end;
    if Result <> ErrorNone then
      Start := 0;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function UnmapMemory(Space: PAddressSpace; Address, Length: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Covered: Boolean;
  Base: QWord;
begin
  if ((Address and PageOffsetMask) <> 0) or (Length = 0) or (Address >= UserSpaceLimit) or
     (Length > UserSpaceLimit - Address) then
    Exit(ErrorInvalidArgument);
  Length := RoundUpToPage(Length);
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  if RangeIsFree(Space, Address, Length) then
    Result := ErrorNone
  else if not SurveyRange(Space, Address, Length, Covered, Base) then
    Result := ErrorInvalidArgument
  else
    Result := EmptyRangeLocked(Space, Address, Length);
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

end.
