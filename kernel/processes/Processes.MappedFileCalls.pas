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
  System calls of file mappings (214-219): CallSyncMemory (msync: the
  dirty pages of the shared file mappings in a range written back, the
  volume flushed with SyncMemoryWait), CallQueryMemoryResidency
  (mincore, with what this kernel can tell besides: mapped here, dirty),
  CallGetMappedFileStatistics and CallTrimMappedFiles (the eviction of
  Processes.MappedFileEviction on demand, for tests and tools).
}
unit Processes.MappedFileCalls;

{$mode objfpc}

interface

function PerformSyncMemory(Address, Length, Flags: QWord): Int64;
function PerformQueryMemoryResidency(Address, Length, VectorAddress: QWord): Int64;
function PerformGetMappedFileStatistics(StatisticsAddress: QWord): Int64;
function PerformTrimMappedFiles(PagesWanted, Flags: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.Pressure,
  Memory.Arch.PageTables,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  FileSystem.Types,
  FileSystem.Files,
  Processes.Process,
  Processes.Thread,
  Processes.Security,
  Processes.UserAccess,
  Processes.UserRegions,
  Processes.AddressSpace,
  Processes.MappedFiles,
  Processes.MappedFileEviction;

const
  { Bytes of the residency vector copied out at a time. }
  ResidencyChunk = 256;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ Page aligned start, a length rounded up to pages, all in user space. }
function NormalizeUserRange(Address: QWord; var Length: QWord): Boolean;
begin
  Result := False;
  if ((Address and PageOffsetMask) <> 0) or (Address >= UserSpaceLimit) or (Length > UserSpaceLimit - Address) then
    Exit;
  Length := RoundUpToPage(Length);
  Result := Length <= UserSpaceLimit - Address;
end;

{ --- msync ------------------------------------------------------------------ }

{ The shared file mapping holding Position (with a reference) and the
  file pages [FirstPage, EndPage) of it inside [Position, Finish); Next
  is where its region ends. False if no region holds Position. }
function SharedMappingAt(Space: PAddressSpace; Position, Finish: QWord; out MappedFile: PMappedFile;
  out FirstPage, EndPage, Next: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Region: PUserRegion;
  Stop: QWord;
begin
  MappedFile := nil;
  FirstPage := 0;
  EndPage := 0;
  Next := Finish;
  PreviousLevel := AcquireSpinLock(Space^.Lock);
  Region := FindRegionLocked(Space, Position);
  Result := Region <> nil;
  if Result then
  begin
    Next := Region^.Start + Region^.Length;
    if (Region^.Backing <> nil) and not Region^.BackingIsPrivate then
    begin
      Stop := Next;
      if Stop > Finish then
        Stop := Finish;
      MappedFile := PMappedFile(Region^.Backing);
      ReferenceMappedFile(MappedFile, False);
      FirstPage := (Region^.BackingOffset + (Position - Region^.Start)) div PageSize;
      EndPage := FirstPage + (Stop - Position) div PageSize;
    end;
  end;
  ReleaseSpinLock(Space^.Lock, PreviousLevel);
end;

function PerformSyncMemory(Address, Length, Flags: QWord): Int64;
var
  Space: PAddressSpace;
  Position: QWord;
  Finish: QWord;
  Next: QWord;
  FirstPage: QWord;
  EndPage: QWord;
  MappedFile: PMappedFile;
  Error: LongInt;
begin
  if ((Flags and not QWord(SyncMemoryAsync or SyncMemoryInvalidate or SyncMemoryWait)) <> 0) or
     ((Flags and (SyncMemoryAsync or SyncMemoryWait)) = (SyncMemoryAsync or SyncMemoryWait)) then
    Exit(Failure(ErrorInvalidArgument));
  if not NormalizeUserRange(Address, Length) then
    Exit(Failure(ErrorInvalidArgument));
  Space := CurrentProcess^.AddressSpace;
  Error := ErrorNone;
  Position := Address;
  Finish := Address + Length;
  while Position < Finish do
  begin
    if not SharedMappingAt(Space, Position, Finish, MappedFile, FirstPage, EndPage, Next) then
      Exit(Failure(ErrorBadAddress));
    if MappedFile <> nil then
    begin
      if WriteBackMappedFile(MappedFile, FirstPage, EndPage) <> ErrorNone then
        Error := ErrorIo;
      if ((Flags and SyncMemoryWait) <> 0) and
         (SyncVolume(PVolume(MappedFile^.Volume)) <> StatusSuccess) then
        Error := ErrorIo;
      ReleaseMappedFile(MappedFile, False);
    end;
    Position := Next;
  end;
  Result := Failure(Error);
end;

{ --- mincore ------------------------------------------------------------------ }

{ The residency bits of the page at PageAddress; False if no region
  holds it. Caller holds the space's lock. }
function PageResidencyLocked(Space: PAddressSpace; PageAddress: QWord; out Bits: Byte): Boolean;
var
  Region: PUserRegion;
  Physical: TPhysicalAddress;
  FilePhysical: TPhysicalAddress;
  PageIndex: QWord;
begin
  Bits := 0;
  Region := FindRegionLocked(Space, PageAddress);
  if Region = nil then
    Exit(False);
  Result := True;
  if TranslateInAddressSpace(Space^.Root, PageAddress, Physical) then
    Bits := PageResidencyResident or PageResidencyMapped;
  if Region^.Backing = nil then
    Exit;
  PageIndex := (Region^.BackingOffset + (PageAddress - Region^.Start)) div PageSize;
  if ResidentMappedFilePage(PMappedFile(Region^.Backing), PageIndex, FilePhysical) then
  begin
    Bits := Bits or PageResidencyResident;
    if not Region^.BackingIsPrivate and MappedFilePageIsDirty(PMappedFile(Region^.Backing), PageIndex) then
      Bits := Bits or PageResidencyDirty;
  end;
end;

function PerformQueryMemoryResidency(Address, Length, VectorAddress: QWord): Int64;
var
  Space: PAddressSpace;
  Vector: array[0..ResidencyChunk - 1] of Byte;
  PageCount: QWord;
  Done: QWord;
  Count: QWord;
  Index: QWord;
  PreviousLevel: TPriorityLevel;
  Found: Boolean;
begin
  if not NormalizeUserRange(Address, Length) then
    Exit(Failure(ErrorInvalidArgument));
  Space := CurrentProcess^.AddressSpace;
  PageCount := Length div PageSize;
  Done := 0;
  while Done < PageCount do
  begin
    Count := PageCount - Done;
    if Count > ResidencyChunk then
      Count := ResidencyChunk;
    Found := True;
    PreviousLevel := AcquireSpinLock(Space^.Lock);
    Index := 0;
    while Found and (Index < Count) do
    begin
      Found := PageResidencyLocked(Space, Address + (Done + Index) * PageSize, Vector[Index]);
      Inc(Index);
    end;
    ReleaseSpinLock(Space^.Lock, PreviousLevel);
    if not Found then
      Exit(Failure(ErrorBadAddress));
    if CopyToUser(VectorAddress + Done, @Vector[0], Count) <> ErrorNone then
      Exit(Failure(ErrorBadAddress));
    Done := Done + Count;
  end;
  Result := 0;
end;

{ --- Statistics and trimming --------------------------------------------------- }

function PerformGetMappedFileStatistics(StatisticsAddress: QWord): Int64;
var
  Figures: TMappedFileStatistics;
  Statistics: TAbiMappedFileStatistics;
begin
  GetMappedFileStatistics(Figures);
  FillMemory(@Statistics, SizeOf(Statistics), 0);
  Statistics.MappedFiles := Figures.MappedFiles;
  Statistics.SnapshotFiles := Figures.SnapshotFiles;
  Statistics.ResidentPages := Figures.ResidentPages;
  Statistics.DirtyPages := Figures.DirtyPages;
  Statistics.PagesWrittenBack := Figures.PagesWrittenBack;
  Statistics.PagesEvicted := Figures.PagesEvicted;
  Statistics.MappingsDropped := Figures.MappingsDropped;
  Statistics.SnapshotPagesRead := Figures.SnapshotPagesRead;
  Statistics.BytesReadFromPages := Figures.BytesReadFromPages;
  Result := -Int64(CopyToUser(StatisticsAddress, @Statistics, SizeOf(Statistics)));
end;

function PerformTrimMappedFiles(PagesWanted, Flags: QWord): Int64;
var
  Urgency: TShrinkUrgency;
begin
  if CurrentProcess^.Credentials.EffectiveUserId <> RootUserId then
    Exit(Failure(ErrorNotPermitted));
  if (Flags and not QWord(TrimMappedPagesToo)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Urgency := ShrinkGently;
  if (Flags and TrimMappedPagesToo) <> 0 then
    Urgency := ShrinkHard;
  Result := Int64(EvictMappedFilePages(PagesWanted, Urgency));
  DrainMappedFileReleases;
end;

end.
