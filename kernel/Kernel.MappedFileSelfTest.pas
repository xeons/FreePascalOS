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
  Mapped file self test, on every boot: on a memory volume of its own,
  a file's mapped files (Processes.MappedFiles) without any process.

    * a shared one: a page written as a shared writable mapping would
      (marked dirty) shows in read() before it is written back, not in
      what the file system holds; written back, the file holds it and
      nothing is dirty; a write() of other bytes of a dirty page lands
      in it without losing what the mapping wrote;
    * a private one becomes a snapshot when the file is written, and
      reads only the page the write touches: that page keeps its old
      contents, and a page it had not read yet is read afterwards with
      the (unchanged) contents of the file;
    * eviction drops the clean pages nobody maps, but not the page a
      snapshot preserved.

  A failure panics.
}
unit Kernel.MappedFileSelfTest;

{$mode objfpc}
{$pointermath on}

interface

procedure RunMappedFileSelfTest;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.Pressure,
  Memory.KernelHeap,
  Kernel.Panic,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Volumes,
  FileSystem.Mounts,
  FileSystem.MountOptions,
  Processes.MappedFiles,
  Processes.MappedFileEviction,
  Debug.Output,
  Debug.FramebufferConsole;

const
  FileBytes = 3 * PageSize + 100;
  PathCapacity = 128;

type
  TPath = array[0..PathCapacity - 1] of Char;

procedure Check(Condition: Boolean; Description: PChar);
begin
  if Condition then
    Exit;
  BeginKernelPanic(PanicAssertionFailed, 'mapped file self test failed');
  DebugWrite('  ');
  DebugWriteLine(Description);
  FinishKernelPanic;
end;

function PatternByte(Offset: QWord): Byte;
begin
  Result := Byte((Offset * 13 + Offset div PageSize) and $FF);
end;

procedure MakePath(Volume: PVolume; out Path: TPath);
begin
  Path[0] := '/';
  CopyText(@Path[1], @Volume^.Name[0], PathCapacity - 16);
  CopyText(@Path[TextLength(@Path[0])], '/mapped.dat', 16);
end;

function WritePattern(Path: PChar): POpenFile;
var
  Data: PByte;
  Index: QWord;
  Written: QWord;
begin
  Result := nil;
  Data := PByte(AllocateKernelMemory(FileBytes));
  Check(Data <> nil, 'memory for the pattern');
  for Index := 0 to FileBytes - 1 do
    Data[Index] := PatternByte(Index);
  Check(OpenFile(Path, OpenForReading or OpenForWriting or OpenCreate or OpenTruncate, Result) = StatusSuccess,
    'creating the file');
  Check((WriteToFile(Result, Data, FileBytes, Written) = StatusSuccess) and (Written = FileBytes),
    'writing the pattern');
  FreeKernelMemory(Data);
end;

{ The byte at Offset as read() gives it. }
function ReadByteAt(OpenedFile: POpenFile; Offset: QWord): Byte;
var
  BytesRead: QWord;
begin
  Result := 0;
  SetFilePosition(OpenedFile, Offset);
  ReadFromFile(OpenedFile, @Result, 1, BytesRead);
end;

{ The byte at Offset as the file system holds it. }
function StoredByteAt(OpenedFile: POpenFile; Offset: QWord): Byte;
var
  BytesRead: QWord;
begin
  Result := 0;
  ReadFromFileAt(OpenedFile, Offset, @Result, 1, BytesRead);
end;

function PageByte(MappedFile: PMappedFile; Offset: QWord): Byte;
var
  Physical: TPhysicalAddress;
begin
  Result := 0;
  Check(ResidentMappedFilePage(MappedFile, Offset div PageSize, Physical), 'the page is in memory');
  Result := PByte(PhysicalToVirtual(Physical))[Offset mod PageSize];
end;

{ Writes Value at Offset into the shared mapped file's page, as a shared
  writable mapping does. }
procedure WriteThroughMapping(MappedFile: PMappedFile; Offset: QWord; Value: Byte);
var
  Physical: TPhysicalAddress;
begin
  Check(LoadMappedFilePage(MappedFile, Offset div PageSize) = ErrorNone, 'reading the page');
  Check(ResidentMappedFilePage(MappedFile, Offset div PageSize, Physical), 'the page is resident');
  Check(MarkMappedFilePageDirty(MappedFile, Offset div PageSize, Physical), 'marking the page dirty');
  PByte(PhysicalToVirtual(Physical))[Offset mod PageSize] := Value;
end;

procedure WriteByteAt(OpenedFile: POpenFile; Offset: QWord; Value: Byte);
var
  Written: QWord;
begin
  SetFilePosition(OpenedFile, Offset);
  Check((WriteToFile(OpenedFile, @Value, 1, Written) = StatusSuccess) and (Written = 1), 'write()');
end;

procedure TestSharedWriting(OpenedFile: POpenFile; Shared: PMappedFile);
var
  Statistics: TMappedFileStatistics;
  ServedBefore: QWord;
begin
  Check(PrepareMappedFileForWriting(Shared, OpenedFile) = ErrorNone, 'preparing for writing');
  WriteThroughMapping(Shared, PageSize + 7, $A5);
  Check(Shared^.DirtyPages = 1, 'one page is dirty');
  GetMappedFileStatistics(Statistics);
  ServedBefore := Statistics.BytesReadFromPages;
  Check(ReadByteAt(OpenedFile, PageSize + 7) = $A5, 'read() sees what the mapping wrote');
  GetMappedFileStatistics(Statistics);
  Check(Statistics.BytesReadFromPages > ServedBefore, 'read() copied from the mapped page');
  Check(StoredByteAt(OpenedFile, PageSize + 7) = PatternByte(PageSize + 7), 'the file system does not have it yet');
  Check(WriteBackMappedFile(Shared, 0, Shared^.PageCount) = ErrorNone, 'writing back');
  Check(Shared^.DirtyPages = 0, 'nothing is dirty after writing back');
  Check(StoredByteAt(OpenedFile, PageSize + 7) = $A5, 'the file holds what the mapping wrote');

  { A write() of other bytes of a dirty page keeps the mapping's bytes. }
  WriteThroughMapping(Shared, PageSize + 2000, $5A);
  WriteByteAt(OpenedFile, PageSize + 10, $C3);
  Check(PageByte(Shared, PageSize + 10) = $C3, 'a write() shows in the resident page');
  Check(PageByte(Shared, PageSize + 2000) = $5A, 'and the mapping''s byte stays');
  Check(WriteBackMappedFile(Shared, 0, Shared^.PageCount) = ErrorNone, 'writing back again');
  Check((StoredByteAt(OpenedFile, PageSize + 2000) = $5A) and (StoredByteAt(OpenedFile, PageSize + 10) = $C3),
    'both reach the file');
end;

procedure TestSnapshot(OpenedFile: POpenFile; out Private_: PMappedFile);
var
  Statistics: TMappedFileStatistics;
  ReadBefore: QWord;
  Value: Byte;
begin
  Check(AcquireMappedFile(OpenedFile, True, Private_) = ErrorNone, 'a private mapped file');
  Check(not Private_^.IsStale, 'it starts as no snapshot');
  Check(LoadMappedFilePage(Private_, 0) = ErrorNone, 'reading its first page');
  GetMappedFileStatistics(Statistics);
  ReadBefore := Statistics.SnapshotPagesRead;
  WriteByteAt(OpenedFile, 2 * PageSize + 3, $77);
  Check(Private_^.IsStale, 'the write made it a snapshot');
  GetMappedFileStatistics(Statistics);
  Check(Statistics.SnapshotPagesRead = ReadBefore + 1, 'only the page written was read');
  Check(ReadMappedFileBytes(Private_, 2 * PageSize + 3, @Value, 1) = ErrorNone, 'reading the snapshot');
  Check(Value = PatternByte(2 * PageSize + 3), 'the snapshot keeps the old byte');
  Check(ReadMappedFileBytes(Private_, 3 * PageSize + 50, @Value, 1) = ErrorNone, 'a page read later');
  Check(Value = PatternByte(3 * PageSize + 50), 'shows the unchanged file');
  Check(ReadByteAt(OpenedFile, 2 * PageSize + 3) = $77, 'the file has the new byte');
end;

procedure TestEviction(Shared, Private_: PMappedFile);
var
  Physical: TPhysicalAddress;
begin
  Check(Shared^.ResidentPages > 0, 'the shared one has pages');
  EvictMappedFilePages(1024, ShrinkGently);
  Check(Shared^.ResidentPages = 0, 'clean pages nobody maps are dropped');
  Check(ResidentMappedFilePage(Private_, 2, Physical), 'a preserved page stays');
  Check(not ResidentMappedFilePage(Private_, 0, Physical), 'a snapshot''s unchanged page goes');
end;

procedure ReportPassed;
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite('mapped files: shared writing, snapshots, eviction: ');
  DebugSetColor(ColorGreen);
  DebugWrite('passed');
  DebugResetColor;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure RunMappedFileSelfTest;
var
  Options: TMountOptions;
  Volume: PVolume;
  Path: TPath;
  OpenedFile: POpenFile;
  Shared: PMappedFile;
  Private_: PMappedFile;
begin
  SetDefaultMountOptions(Options);
  Options.SizeLimitBytes := 256 * 1024;
  Options.SizePercent := 0;
  Volume := MountMemoryVolume(Options);
  Check(Volume <> nil, 'making a memory volume');
  MakePath(Volume, Path);
  OpenedFile := WritePattern(@Path[0]);
  Check(AcquireMappedFile(OpenedFile, False, Shared) = ErrorNone, 'a shared mapped file');
  TestSharedWriting(OpenedFile, Shared);
  TestSnapshot(OpenedFile, Private_);
  TestEviction(Shared, Private_);
  ReleaseMappedFile(Private_, True);
  ReleaseMappedFile(Shared, False);
  DrainMappedFileReleases;
  CloseFile(OpenedFile);
  Check(RemovePath(@Path[0]) = StatusSuccess, 'removing the file');
  Check(UnmountVolume(Volume, False) = StatusSuccess, 'unmounting the memory volume');
  ReportPassed;
end;

end.
