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
  filemaptest - shared writable file mappings, snapshots and eviction

    * a shared writable mapping needs a handle open for writing (also
      when made writable later with ProtectMemory); what is written to
      it shows at once in a second mapping and in read(), the page is
      dirty until SyncMemory, and after unmapping and closing, a fresh
      open reads it from the file;
    * a write() into a page a mapping wrote keeps the mapping's bytes,
      and both reach the file;
    * mmap(MAP_SHARED, PROT_WRITE) writes reach the file once munmap'd;
    * a private mapping of a large file another write changes keeps
      what it saw, and the change made it read one page only;
    * TrimMappedFiles (root) unmaps and drops clean mapped pages, which
      read the same again when touched, but leaves a dirty page alone.

  Each check prints a line; the exit status is 1 if any failed.
}
program filemaptest;

{$mode objfpc}{$H+}
{$pointermath on}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Memory;

const
  PageBytes = 4096;
  SmallName = 'filemaptest.dat';
  LargeName = 'filemaptest-large.dat';
  SmallBytes = 3 * PageBytes + 100;
  LargePages = 256;
  LargeBytes = LargePages * PageBytes;
  { mmap's Linux values. }
  PosixRead = $1;
  PosixWrite = $2;
  PosixShared = $01;
  PosixPrivate = $02;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('filemaptest: pass: ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('filemaptest: FAIL: ', Name);
  end;
end;

function PatternByte(Offset: QWord): Byte;
begin
  Result := Byte((Offset * 11 + Offset div PageBytes) and $FF);
end;

function CreatePatternFile(const Name: string; Bytes: QWord): Boolean;
var
  Handle: Int64;
  Data: TBytes;
  Index: QWord;
begin
  SetLength(Data, Bytes);
  for Index := 0 to Bytes - 1 do
    Data[Index] := PatternByte(Index);
  Handle := KernelOpen(PChar(Name), OpenRead or OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(False);
  Result := KernelWrite(Handle, @Data[0], Bytes) = Int64(Bytes);
  KernelClose(Handle);
end;

function ReadByteOf(const Name: string; Offset: QWord): Byte;
var
  Handle: Int64;
begin
  Result := 0;
  Handle := KernelOpen(PChar(Name), OpenRead);
  KernelSeek(Handle, Int64(Offset), SeekFromStart);
  KernelRead(Handle, @Result, 1);
  KernelClose(Handle);
end;

procedure WriteByteOf(const Name: string; Offset: QWord; Value: Byte);
var
  Handle: Int64;
begin
  Handle := KernelOpen(PChar(Name), OpenRead or OpenWrite);
  KernelSeek(Handle, Int64(Offset), SeekFromStart);
  KernelWrite(Handle, @Value, 1);
  KernelClose(Handle);
end;

function ResidencyOf(Address: PByte): Byte;
begin
  Result := 0;
  if QueryMemoryResidency(Address, PageBytes, @Result) <> 0 then
    Result := $FF;
end;

function Statistics: TAbiMappedFileStatistics;
begin
  GetMappedFileStatistics(Result);
end;

{ --- Shared writable mappings ------------------------------------------- }

procedure TestSharedWritable;
var
  ReadOnly: Int64;
  Writable: Int64;
  First: PByte;
  Second: PByte;
  Viewer: PByte;
  Previous: LongWord;
  WrittenBefore: QWord;
begin
  ReadOnly := KernelOpen(SmallName, OpenRead);
  Check('a writable shared mapping through a read-only handle is refused',
    MapFile(ReadOnly, 0, 0, MapFileWritable, Pointer(First)) = ErrorAccessDenied);
  Check('a read-only shared mapping through it is not', MapFile(ReadOnly, 0, 0, 0, Pointer(Viewer)) = 0);
  if Viewer <> nil then
    Check('which may not be made writable', ProtectMemory(Viewer, PageBytes, ProtectReadWrite, Previous) <> 0);
  KernelClose(ReadOnly);

  Writable := KernelOpen(SmallName, OpenRead or OpenWrite);
  Check('a writable shared mapping through a writable handle',
    MapFile(Writable, 0, 0, MapFileWritable, Pointer(First)) = 0);
  Check('a second one', MapFile(Writable, 0, 0, MapFileWritable, Pointer(Second)) = 0);
  KernelClose(Writable);
  if (First = nil) or (Second = nil) or (Viewer = nil) then
    Exit;
  Check('it shows the file', (First[5] = PatternByte(5)) and (First[SmallBytes - 1] = PatternByte(SmallBytes - 1)));

  First[PageBytes + 9] := $E1;
  Check('a write shows in the second mapping at once', Second[PageBytes + 9] = $E1);
  Check('and in the read-only one', Viewer[PageBytes + 9] = $E1);
  Check('and in read()', ReadByteOf(SmallName, PageBytes + 9) = $E1);
  Check('the page is dirty', (ResidencyOf(First + PageBytes) and PageResidencyDirty) <> 0);
  Check('a page not written is not', (ResidencyOf(First) and PageResidencyDirty) = 0);
  WrittenBefore := Statistics.PagesWrittenBack;
  Check('SyncMemory', SyncMemory(First, 4 * PageBytes, SyncMemoryWait) = 0);
  Check('wrote the page back', Statistics.PagesWrittenBack >= WrittenBefore + 1);
  Check('which is clean now', (ResidencyOf(First + PageBytes) and PageResidencyDirty) = 0);
  First[PageBytes + 9] := $E2;
  Check('a write after it makes it dirty again', (ResidencyOf(Second + PageBytes) and PageResidencyDirty) <> 0);

  { A write() of other bytes of the dirty page. }
  First[2 * PageBytes + 300] := $B7;
  WriteByteOf(SmallName, 2 * PageBytes + 10, $4C);
  Check('a write() shows in the mapping', Second[2 * PageBytes + 10] = $4C);
  Check('and keeps the mapping''s byte in that page', Second[2 * PageBytes + 300] = $B7);

  Check('the mappings are unmapped', (ReleaseMemory(First) = 0) and (ReleaseMemory(Second) = 0) and
    (ReleaseMemory(Viewer) = 0));
  Check('the file holds what the mappings wrote', (ReadByteOf(SmallName, PageBytes + 9) = $E2) and
    (ReadByteOf(SmallName, 2 * PageBytes + 300) = $B7) and (ReadByteOf(SmallName, 2 * PageBytes + 10) = $4C));
end;

procedure TestProtectToWritable;
var
  Handle: Int64;
  Mapping: PByte;
  Previous: LongWord;
begin
  Handle := KernelOpen(SmallName, OpenRead or OpenWrite);
  Check('a read-only shared mapping through a writable handle', MapFile(Handle, 0, 0, 0, Pointer(Mapping)) = 0);
  KernelClose(Handle);
  if Mapping = nil then
    Exit;
  Check('may be made writable', ProtectMemory(Mapping, PageBytes, ProtectReadWrite, Previous) = 0);
  Mapping[17] := $3D;
  ReleaseMemory(Mapping);
  Check('and its write reaches the file', ReadByteOf(SmallName, 17) = $3D);
end;

procedure TestPosixShared;
var
  Handle: Int64;
  Mapped: Int64;
begin
  Handle := KernelOpen(SmallName, OpenRead or OpenWrite);
  Mapped := SystemCall(CallMapMemory, 0, SmallBytes, PosixRead or PosixWrite, PosixShared, QWord(Handle), 0);
  KernelClose(Handle);
  Check('mmap(MAP_SHARED, PROT_WRITE)', Mapped > 0);
  if Mapped <= 0 then
    Exit;
  PByte(Mapped)[3 * PageBytes + 1] := $9A;
  Check('munmap', SystemCall(CallUnmapMemory, QWord(Mapped), SmallBytes, 0, 0, 0, 0) = 0);
  Check('its write reaches the file', ReadByteOf(SmallName, 3 * PageBytes + 1) = $9A);
  Handle := KernelOpen(SmallName, OpenRead);
  Mapped := SystemCall(CallMapMemory, 0, SmallBytes, PosixRead or PosixWrite, PosixShared, QWord(Handle), 0);
  KernelClose(Handle);
  Check('mmap(MAP_SHARED, PROT_WRITE) of a read-only handle is refused', Mapped = -ErrorAccessDenied);
end;

{ --- Snapshots ------------------------------------------------------------ }

procedure TestSnapshot;
var
  Handle: Int64;
  Private_: PByte;
  ReadBefore: QWord;
  ReadAfter: QWord;
  Middle: QWord;
begin
  Handle := KernelOpen(LargeName, OpenRead);
  Check('a large file is mapped private', MapFile(Handle, 0, 0, MapFilePrivate, Pointer(Private_)) = 0);
  KernelClose(Handle);
  if Private_ = nil then
    Exit;
  Check('it shows the file', Private_[100] = PatternByte(100));
  Middle := (LargePages div 2) * PageBytes + 5;
  ReadBefore := Statistics.SnapshotPagesRead;
  WriteByteOf(LargeName, Middle, not PatternByte(Middle));
  ReadAfter := Statistics.SnapshotPagesRead;
  WriteLn('filemaptest: the write made the snapshot read ', ReadAfter - ReadBefore, ' pages');
  Check('the write made it read the page written, not the file', ReadAfter - ReadBefore = 1);
  Check('the private mapping keeps the old byte', Private_[Middle] = PatternByte(Middle));
  Check('and shows the rest of the file', Private_[LargeBytes - 1] = PatternByte(LargeBytes - 1));
  Check('the file has the new byte', ReadByteOf(LargeName, Middle) = Byte(not PatternByte(Middle)));
  ReleaseMemory(Private_);
  WriteByteOf(LargeName, Middle, PatternByte(Middle));
end;

{ --- Eviction --------------------------------------------------------------- }

function IsRoot: Boolean;
var
  Credentials: TAbiCredentials;
begin
  Result := (KernelGetCredentials(Credentials) >= 0) and (Credentials.EffectiveUserId = 0);
end;

procedure TestEviction;
var
  Handle: Int64;
  Mapping: PByte;
  Index: QWord;
  Sum: QWord;
  Matches: Boolean;
  Freed: Int64;
begin
  if not IsRoot then
  begin
    WriteLn('filemaptest: not root: eviction not tested');
    Exit;
  end;
  Handle := KernelOpen(LargeName, OpenRead or OpenWrite);
  Check('the large file is mapped shared writable', MapFile(Handle, 0, 0, MapFileWritable, Pointer(Mapping)) = 0);
  KernelClose(Handle);
  if Mapping = nil then
    Exit;
  Sum := 0;
  for Index := 0 to LargePages - 1 do
    Sum := Sum + Mapping[Index * PageBytes];
  Mapping[7 * PageBytes] := $66;
  Check('every page is mapped', (ResidencyOf(Mapping + 3 * PageBytes) and PageResidencyMapped) <> 0);
  Freed := TrimMappedFiles(1000000, TrimMappedPagesToo);
  WriteLn('filemaptest: trimming freed ', Freed, ' pages (sum ', Sum, ')');
  Check('trimming freed pages', Freed > 0);
  Check('a clean page is no longer mapped', (ResidencyOf(Mapping + 3 * PageBytes) and PageResidencyMapped) = 0);
  Check('the dirty page stays', (ResidencyOf(Mapping + 7 * PageBytes) and
    (PageResidencyMapped or PageResidencyDirty)) = (PageResidencyMapped or PageResidencyDirty));
  Matches := True;
  for Index := 0 to LargePages - 1 do
    if (Index <> 7) and (Mapping[Index * PageBytes + 1] <> PatternByte(Index * PageBytes + 1)) then
      Matches := False;
  Check('dropped pages read the same again', Matches and (Mapping[7 * PageBytes] = $66));
  ReleaseMemory(Mapping);
  WriteByteOf(LargeName, 7 * PageBytes, PatternByte(7 * PageBytes));
end;

begin
  if CreatePatternFile(SmallName, SmallBytes) and CreatePatternFile(LargeName, LargeBytes) then
  begin
    TestSharedWritable;
    TestProtectToWritable;
    TestPosixShared;
    TestSnapshot;
    TestEviction;
  end
  else
    Check('the files to map are written', False);
  DeleteFile(SmallName);
  DeleteFile(LargeName);
  WriteLn('filemaptest: ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
