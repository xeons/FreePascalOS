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
  File system write self test.

  Runs on every writable test volume (those with fstype.txt, see
  Kernel.FileSystemTest) and exercises every write operation through the
  normal path based interface, checking each result by reading it back.

  It leaves a known set of files behind so the host can check the volume
  afterwards with the format's own tools (fsck and friends), see
  scripts/verify-test-disk.sh:

    written/final.txt                 "Final contents.\n"
    written/big-written.bin           WrittenBigFileSize bytes, byte N = (N * 7) mod 253
    written/Mixed Case Long Name.txt  "mixed\n"
    written/lower.txt                 "lower\n"
    written/many/file-NN.txt          40 files, each "file NN\n"
    written/moved/inner.txt           "inner\n" (its directory was renamed)
    written/short-link                ext only: symbolic link to final.txt
    written/sparse-written.bin        SparseFinalSize bytes: 1000 bytes of 'S' at
                                      every multiple of SparseStride, zeros elsewhere
    written/replaced.txt              "replacement\n" (renamed over an older file)

  ext3 and ext4 volumes end with a simulated crash: the last change, the
  rename of written/journal-pending.txt to written/journal-committed.txt
  ("committed\n"), is committed to the journal but never written in
  place, and the volume is left needing recovery. The host checks that
  the change is only in the journal, then replays it with e2fsck.
}
unit Kernel.FileSystemWriteTest;

{$mode objfpc}
{$pointermath on}

interface

{ Returns the number of volumes that were tested. }
function RunFileSystemWriteTests: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Panic,
  FileSystem.Types,
  FileSystem.Volumes,
  FileSystem.Files,
  FileSystem.Ext,
  Debug.Output,
  Debug.FramebufferConsole;

const
  WrittenBigFileSize = 200 * 1024 + 123;
  ManyFileCount = 40;
  SparseStride = 20000;
  SparseRegionLength = 1000;
  SparseRegionCount = 12;
  SparseFinalSize = 150000;
  SmallFileCapacity = 256;

var
  CurrentVolume: PVolume;

{ --- Helpers --------------------------------------------------------- }

procedure FailTest(Description: PChar; Status: TFileSystemStatus; ShowStatus: Boolean);
begin
  BeginKernelPanic(PanicAssertionFailed, 'file system write test failed');
  DebugWrite('  Volume ');
  DebugWrite(@CurrentVolume^.Name[0]);
  DebugWrite(' (');
  DebugWrite(@CurrentVolume^.TypeName[0]);
  DebugWriteLine(')');
  DebugWrite('  ');
  DebugWrite(Description);
  if ShowStatus then
  begin
    DebugWrite(': ');
    DebugWrite(FileSystemStatusText(Status));
  end;
  DebugWriteLine('');
  FinishKernelPanic;
end;

procedure Check(Condition: Boolean; Description: PChar);
begin
  if not Condition then
    FailTest(Description, StatusSuccess, False);
end;

procedure CheckStatus(Status: TFileSystemStatus; Description: PChar);
begin
  if Status <> StatusSuccess then
    FailTest(Description, Status, True);
end;

procedure CheckExpectedStatus(Status: TFileSystemStatus; Expected: TFileSystemStatus;
  Description: PChar);
begin
  if Status <> Expected then
    FailTest(Description, Status, True);
end;

procedure BuildPath(RelativePath: PChar; Path: PChar);
var
  Length: PtrUInt;
begin
  Path[0] := '/';
  CopyText(Path + 1, @CurrentVolume^.Name[0], MaximumPathBytes - 1);
  Length := TextLength(Path);
  Path[Length] := '/';
  CopyText(Path + Length + 1, RelativePath, MaximumPathBytes - Length - 1);
end;

function OpenRelative(RelativePath: PChar; Flags: LongWord; out OpenedFile: POpenFile): TFileSystemStatus;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
begin
  BuildPath(RelativePath, @Path[0]);
  Result := OpenFile(@Path[0], Flags, OpenedFile);
end;

procedure WriteWholeFile(RelativePath: PChar; Contents: PChar);
var
  OpenedFile: POpenFile;
  Written: QWord;
begin
  CheckStatus(OpenRelative(RelativePath, OpenForWriting or OpenCreate or OpenTruncate, OpenedFile),
    RelativePath);
  CheckStatus(WriteToFile(OpenedFile, Contents, TextLength(Contents), Written), RelativePath);
  Check(Written = TextLength(Contents), 'short write');
  CloseFile(OpenedFile);
end;

procedure CheckFileContents(RelativePath: PChar; Expected: PChar);
var
  OpenedFile: POpenFile;
  Contents: array[0..SmallFileCapacity - 1] of Char;
  BytesRead: QWord;
begin
  CheckStatus(OpenRelative(RelativePath, OpenForReading, OpenedFile), RelativePath);
  CheckStatus(ReadFromFile(OpenedFile, @Contents[0], SmallFileCapacity - 1, BytesRead), RelativePath);
  Contents[BytesRead] := #0;
  CloseFile(OpenedFile);
  Check(TextIsEqual(@Contents[0], Expected), RelativePath);
end;

function PathStatus(RelativePath: PChar): TFileSystemStatus;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  Information: TNodeInformation;
begin
  BuildPath(RelativePath, @Path[0]);
  Result := GetPathInformation(@Path[0], Information);
end;

function MakeDirectory(RelativePath: PChar): TFileSystemStatus;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
begin
  BuildPath(RelativePath, @Path[0]);
  Result := CreateDirectory(@Path[0]);
end;

function RemoveRelative(RelativePath: PChar): TFileSystemStatus;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
begin
  BuildPath(RelativePath, @Path[0]);
  Result := RemovePath(@Path[0]);
end;

function RenameRelative(SourcePath, TargetPath: PChar): TFileSystemStatus;
var
  Source: array[0..MaximumPathBytes - 1] of Char;
  Target: array[0..MaximumPathBytes - 1] of Char;
begin
  BuildPath(SourcePath, @Source[0]);
  BuildPath(TargetPath, @Target[0]);
  Result := RenamePath(@Source[0], @Target[0]);
end;

{ ext compares names exactly; FAT and exFAT ignore letter case. }
function VolumeIgnoresCase: Boolean;
begin
  Result := not ((CurrentVolume^.TypeName[0] = 'e') and (CurrentVolume^.TypeName[1] = 'x') and
    (CurrentVolume^.TypeName[2] = 't'));
end;

function BigFileByte(Position: QWord): Byte;
begin
  Result := Byte((Position * 7) mod 253);
end;

{ --- Tests ----------------------------------------------------------- }

procedure TestCreateAndOverwrite;
var
  OpenedFile: POpenFile;
  Written: QWord;
begin
  CheckStatus(MakeDirectory('written'), 'creating directory "written"');
  CheckExpectedStatus(MakeDirectory('written'), StatusAlreadyExists, 'creating a directory twice');

  WriteWholeFile('written/final.txt', 'First version, long enough to be shortened.'#10);
  CheckFileContents('written/final.txt', 'First version, long enough to be shortened.'#10);
  WriteWholeFile('written/final.txt', 'Final contents.'#10);
  CheckFileContents('written/final.txt', 'Final contents.'#10);

  CheckExpectedStatus(OpenRelative('written/final.txt',
    OpenForWriting or OpenCreate or OpenExclusive, OpenedFile), StatusAlreadyExists,
    'exclusive create of an existing file');

  { Appending. }
  WriteWholeFile('written/append.txt', 'one');
  CheckStatus(OpenRelative('written/append.txt', OpenForWriting or OpenAppend, OpenedFile), 'append');
  CheckStatus(WriteToFile(OpenedFile, PChar(' two'), 4, Written), 'append write');
  CloseFile(OpenedFile);
  CheckFileContents('written/append.txt', 'one two');

  WriteWholeFile('written/Mixed Case Long Name.txt', 'mixed'#10);
  WriteWholeFile('written/lower.txt', 'lower'#10);
  if VolumeIgnoresCase then
    CheckFileContents('written/MIXED CASE LONG NAME.TXT', 'mixed'#10)
  else
    CheckExpectedStatus(PathStatus('written/MIXED CASE LONG NAME.TXT'), StatusNotFound,
      'a case sensitive volume matched a name in the wrong case');
end;

procedure TestBigFile;
const
  ChunkSize = 5000;
var
  OpenedFile: POpenFile;
  Buffer: PByte;
  Position: QWord;
  ChunkBytes: QWord;
  Index: QWord;
  Written: QWord;
  BytesRead: QWord;
  Information: TNodeInformation;
begin
  Buffer := PByte(AllocateKernelMemory(ChunkSize));
  Check(Buffer <> nil, 'out of memory');

  CheckStatus(OpenRelative('written/big-written.bin', OpenForWriting or OpenCreate, OpenedFile),
    'creating big-written.bin');
  Position := 0;
  while Position < WrittenBigFileSize do
  begin
    ChunkBytes := WrittenBigFileSize - Position;
    if ChunkBytes > ChunkSize then
      ChunkBytes := ChunkSize;
    for Index := 0 to ChunkBytes - 1 do
      Buffer[Index] := BigFileByte(Position + Index);
    CheckStatus(WriteToFile(OpenedFile, Buffer, ChunkBytes, Written), 'writing big-written.bin');
    Check(Written = ChunkBytes, 'short write to big-written.bin');
    Position := Position + Written;
  end;
  CheckStatus(GetFileInformation(OpenedFile, Information), 'big-written.bin information');
  Check(Information.SizeInBytes = WrittenBigFileSize, 'big-written.bin has the wrong size');
  CloseFile(OpenedFile);

  CheckStatus(OpenRelative('written/big-written.bin', OpenForReading, OpenedFile),
    'reopening big-written.bin');
  Position := 0;
  repeat
    CheckStatus(ReadFromFile(OpenedFile, Buffer, ChunkSize, BytesRead), 'reading big-written.bin');
    Index := 0;
    while Index < BytesRead do
    begin
      Check(Buffer[Index] = BigFileByte(Position + Index), 'big-written.bin reads back wrongly');
      Inc(Index);
    end;
    Position := Position + BytesRead;
  until BytesRead = 0;
  Check(Position = WrittenBigFileSize, 'big-written.bin read back with the wrong length');
  CloseFile(OpenedFile);

  FreeKernelMemory(Buffer);
end;

procedure TestGapsAndSizes;
const
  GapStart = 3000;
  GapEnd = 12000;
var
  OpenedFile: POpenFile;
  Buffer: array[0..15] of Byte;
  Written: QWord;
  BytesRead: QWord;
  Information: TNodeInformation;
  Index: Integer;
begin
  { Writing past the end leaves a gap that must read as zeros. }
  WriteWholeFile('written/gap.bin', 'start');
  CheckStatus(OpenRelative('written/gap.bin', OpenForReading or OpenForWriting, OpenedFile), 'gap.bin');
  SetFilePosition(OpenedFile, GapEnd);
  CheckStatus(WriteToFile(OpenedFile, PChar('end'), 3, Written), 'writing past the end');
  CheckStatus(GetFileInformation(OpenedFile, Information), 'gap.bin information');
  Check(Information.SizeInBytes = GapEnd + 3, 'gap.bin has the wrong size');

  SetFilePosition(OpenedFile, GapStart);
  CheckStatus(ReadFromFile(OpenedFile, @Buffer[0], 16, BytesRead), 'reading the gap');
  for Index := 0 to 15 do
    Check(Buffer[Index] = 0, 'the gap does not read as zeros');

  { Shrinking and growing. }
  CheckStatus(ChangeFileSize(OpenedFile, 2), 'shrinking gap.bin');
  CheckStatus(GetFileInformation(OpenedFile, Information), 'gap.bin information');
  Check(Information.SizeInBytes = 2, 'shrinking did not change the size');
  CheckStatus(ChangeFileSize(OpenedFile, 5000), 'growing gap.bin');
  SetFilePosition(OpenedFile, 0);
  CheckStatus(ReadFromFile(OpenedFile, @Buffer[0], 16, BytesRead), 'reading the grown file');
  Check((Buffer[0] = Ord('s')) and (Buffer[1] = Ord('t')) and (Buffer[2] = 0),
    'growing a file did not zero the new part');
  CloseFile(OpenedFile);

  CheckStatus(RemoveRelative('written/gap.bin'), 'removing gap.bin');
  CheckExpectedStatus(PathStatus('written/gap.bin'), StatusNotFound, 'gap.bin still exists');
end;

procedure TestRenameAndRemove;
var
  OpenedFile: POpenFile;
begin
  CheckStatus(MakeDirectory('written/sub'), 'creating written/sub');
  WriteWholeFile('written/sub/inner.txt', 'inner'#10);
  CheckExpectedStatus(RemoveRelative('written/sub'), StatusDirectoryNotEmpty,
    'removing a non-empty directory');

  { Moving a directory must keep what is inside it reachable. }
  CheckStatus(MakeDirectory('written/other'), 'creating written/other');
  CheckStatus(RenameRelative('written/sub', 'written/other/sub'), 'moving a directory');
  CheckFileContents('written/other/sub/inner.txt', 'inner'#10);
  CheckStatus(RenameRelative('written/other/sub', 'written/moved'), 'moving it back up');
  CheckFileContents('written/moved/inner.txt', 'inner'#10);
  CheckStatus(RemoveRelative('written/other'), 'removing an empty directory');

  CheckExpectedStatus(RenameRelative('written/moved', 'written/moved/inside'), StatusInvalidPath,
    'moving a directory into itself');

  { Renaming files, including onto an existing name. }
  WriteWholeFile('written/temporary.txt', 'temporary');
  WriteWholeFile('written/overwritten.txt', 'overwritten');
  CheckStatus(RenameRelative('written/temporary.txt', 'written/overwritten.txt'),
    'renaming onto an existing file');
  CheckFileContents('written/overwritten.txt', 'temporary');
  CheckStatus(RenameRelative('written/overwritten.txt', 'written/renamed with a long name.txt'),
    'renaming a file');
  CheckFileContents('written/renamed with a long name.txt', 'temporary');
  CheckExpectedStatus(PathStatus('written/temporary.txt'), StatusNotFound, 'old name still exists');

  { An open file can be removed (TestRemoveWhileOpen goes further). }
  CheckStatus(OpenRelative('written/renamed with a long name.txt', OpenForReading, OpenedFile),
    'opening the renamed file');
  CheckStatus(RemoveRelative('written/renamed with a long name.txt'), 'removing the open renamed file');
  CloseFile(OpenedFile);
  CheckExpectedStatus(PathStatus('written/renamed with a long name.txt'), StatusNotFound,
    'the removed file stays removed after closing');

  CheckExpectedStatus(RemoveRelative('written/does-not-exist'), StatusNotFound,
    'removing a missing file');
end;

procedure TestManyFiles;
var
  Index: Integer;
  RelativePath: array[0..63] of Char;
  Contents: array[0..31] of Char;
  NumberText: array[0..2] of Char;
begin
  CheckStatus(MakeDirectory('written/many'), 'creating written/many');
  { Enough entries to need more than one directory cluster or block. }
  for Index := 0 to ManyFileCount - 1 do
  begin
    NumberText[0] := Char(Ord('0') + Index div 10);
    NumberText[1] := Char(Ord('0') + Index mod 10);
    NumberText[2] := #0;

    CopyText(@RelativePath[0], 'written/many/file-', 64);
    CopyText(@RelativePath[TextLength(@RelativePath[0])], @NumberText[0], 8);
    CopyText(@RelativePath[TextLength(@RelativePath[0])], '.txt', 8);

    CopyText(@Contents[0], 'file ', 32);
    CopyText(@Contents[TextLength(@Contents[0])], @NumberText[0], 8);
    CopyText(@Contents[TextLength(@Contents[0])], #10, 8);

    WriteWholeFile(@RelativePath[0], @Contents[0]);
  end;
  CheckFileContents('written/many/file-00.txt', 'file 00'#10);
  CheckFileContents('written/many/file-39.txt', 'file 39'#10);
end;

procedure TestSymbolicLinks;
const
  LongTarget = 'this-part-makes-the-target-longer-than-sixty-bytes-on-purpose/../final.txt';
var
  Path: array[0..MaximumPathBytes - 1] of Char;
begin
  BuildPath('written/short-link', @Path[0]);
  if VolumeIgnoresCase then
  begin
    { FAT and exFAT cannot store symbolic links. }
    CheckExpectedStatus(CreateSymbolicLink(@Path[0], 'final.txt'), StatusUnsupported,
      'creating a symbolic link on a volume without them');
    Exit;
  end;

  { Short targets are stored in the inode, long ones in a data block. }
  CheckStatus(CreateSymbolicLink(@Path[0], 'final.txt'), 'creating a short symbolic link');
  CheckFileContents('written/short-link', 'Final contents.'#10);
  BuildPath('written/long-link', @Path[0]);
  CheckStatus(CreateSymbolicLink(@Path[0], LongTarget), 'creating a long symbolic link');
  CheckFileContents('written/long-link', 'Final contents.'#10);
  CheckStatus(RemoveRelative('written/long-link'), 'removing a symbolic link');
end;

{ Writes separated regions, which on ext4 gives one extent per region and
  needs an extent tree with a leaf block, then truncates through them. }
procedure TestSparseFile;
var
  OpenedFile: POpenFile;
  Region: array[0..SparseRegionLength - 1] of Byte;
  Probe: array[0..1] of Byte;
  RegionIndex: Integer;
  Written: QWord;
  BytesRead: QWord;
  Information: TNodeInformation;
begin
  FillMemory(@Region[0], SparseRegionLength, Ord('S'));
  CheckStatus(OpenRelative('written/sparse-written.bin', OpenForReading or OpenForWriting or OpenCreate,
    OpenedFile), 'creating sparse-written.bin');
  for RegionIndex := 0 to SparseRegionCount - 1 do
  begin
    SetFilePosition(OpenedFile, QWord(RegionIndex) * SparseStride);
    CheckStatus(WriteToFile(OpenedFile, @Region[0], SparseRegionLength, Written), 'writing a region');
  end;

  CheckStatus(ChangeFileSize(OpenedFile, SparseFinalSize), 'truncating sparse-written.bin');
  CheckStatus(GetFileInformation(OpenedFile, Information), 'sparse-written.bin information');
  Check(Information.SizeInBytes = SparseFinalSize, 'sparse-written.bin has the wrong size');

  for RegionIndex := 0 to SparseRegionCount - 1 do
  begin
    if QWord(RegionIndex) * SparseStride >= SparseFinalSize then
      Break;
    SetFilePosition(OpenedFile, QWord(RegionIndex) * SparseStride + SparseRegionLength - 1);
    CheckStatus(ReadFromFile(OpenedFile, @Probe[0], 2, BytesRead), 'reading around a region');
    Check((Probe[0] = Ord('S')) and (Probe[1] = 0), 'sparse-written.bin region or gap is wrong');
  end;
  CloseFile(OpenedFile);
end;

function FreeBytes: QWord;
begin
  Check(GetVolumeFreeSpace(CurrentVolume, Result), 'reading the free space');
end;

{ Writes Count bytes of Value at the current position of OpenedFile. }
procedure WriteFilled(OpenedFile: POpenFile; Value: Byte; Count: QWord);
var
  Chunk: array[0..1023] of Byte;
  Written: QWord;
  Piece: QWord;
begin
  FillMemory(@Chunk[0], SizeOf(Chunk), Value);
  while Count > 0 do
  begin
    Piece := Count;
    if Piece > SizeOf(Chunk) then
      Piece := SizeOf(Chunk);
    CheckStatus(WriteToFile(OpenedFile, @Chunk[0], Piece, Written), 'writing filler');
    Count := Count - Piece;
  end;
end;

{ A file removed while open goes on working, and gives its space back
  when it is closed. }
procedure TestRemoveWhileOpen;
const
  FillerSize = 40 * 1024;
var
  OpenedFile: POpenFile;
  Probe: array[0..3] of Byte;
  BytesRead: QWord;
  FreeBefore: QWord;
  FreeWhileOpen: QWord;
  FreeAfter: QWord;
begin
  FreeBefore := FreeBytes;
  CheckStatus(OpenRelative('written/open-removed.bin', OpenForReading or OpenForWriting or OpenCreate,
    OpenedFile), 'creating open-removed.bin');
  WriteFilled(OpenedFile, Ord('A'), FillerSize);
  CheckStatus(RemoveRelative('written/open-removed.bin'), 'removing an open file');
  CheckExpectedStatus(PathStatus('written/open-removed.bin'), StatusNotFound, 'the removed name is gone');
  { The name is free for a new file, which is not the old one. }
  WriteWholeFile('written/open-removed.bin', 'new'#10);
  CheckFileContents('written/open-removed.bin', 'new'#10);
  CheckStatus(RemoveRelative('written/open-removed.bin'), 'removing the new file');
  { The removed file still reads and grows. }
  WriteFilled(OpenedFile, Ord('B'), FillerSize);
  SetFilePosition(OpenedFile, FillerSize - 2);
  CheckStatus(ReadFromFile(OpenedFile, @Probe[0], 4, BytesRead), 'reading a removed file');
  Check((BytesRead = 4) and (Probe[0] = Ord('A')) and (Probe[1] = Ord('A')) and (Probe[2] = Ord('B')),
    'a removed file reads back what was written');
  FreeWhileOpen := FreeBytes;
  CloseFile(OpenedFile);
  FreeAfter := FreeBytes;
  Check(FreeAfter >= FreeWhileOpen + 2 * FillerSize, 'closing a removed file frees its space');
  { Directory blocks may have grown meanwhile. }
  Check(FreeAfter + 16 * 1024 >= FreeBefore, 'all of a removed file''s space comes back');
end;

{ Renaming onto an existing name replaces it, as on Unix. }
procedure TestRenameOverExisting;
var
  OpenedFile: POpenFile;
  Contents: array[0..15] of Char;
  BytesRead: QWord;
begin
  WriteWholeFile('written/replaced.txt', 'original'#10);
  WriteWholeFile('written/replacement.txt', 'replacement'#10);
  { The file being replaced is open: it goes on reading its contents. }
  CheckStatus(OpenRelative('written/replaced.txt', OpenForReading, OpenedFile), 'opening replaced.txt');
  CheckStatus(RenameRelative('written/replacement.txt', 'written/replaced.txt'),
    'renaming over an existing file');
  CheckExpectedStatus(PathStatus('written/replacement.txt'), StatusNotFound, 'the old name is gone');
  CheckFileContents('written/replaced.txt', 'replacement'#10);
  CheckStatus(ReadFromFile(OpenedFile, @Contents[0], 15, BytesRead), 'reading the replaced file');
  Contents[BytesRead] := #0;
  Check(TextIsEqual(@Contents[0], 'original'#10), 'the replaced file, still open, keeps its contents');
  CloseFile(OpenedFile);

  CheckStatus(MakeDirectory('written/directory-a'), 'mkdir directory-a');
  CheckStatus(MakeDirectory('written/directory-b'), 'mkdir directory-b');
  WriteWholeFile('written/directory-b/inside.txt', 'inside'#10);
  CheckExpectedStatus(RenameRelative('written/replaced.txt', 'written/directory-a'), StatusIsADirectory,
    'a file does not replace a directory');
  CheckExpectedStatus(RenameRelative('written/directory-a', 'written/replaced.txt'), StatusNotADirectory,
    'a directory does not replace a file');
  CheckExpectedStatus(RenameRelative('written/directory-a', 'written/directory-b'), StatusDirectoryNotEmpty,
    'a directory does not replace a directory with something in it');
  CheckStatus(RemoveRelative('written/directory-b/inside.txt'), 'emptying directory-b');
  CheckStatus(RenameRelative('written/directory-a', 'written/directory-b'),
    'a directory replaces an empty directory');
  CheckExpectedStatus(PathStatus('written/directory-a'), StatusNotFound, 'directory-a is gone');
  CheckStatus(RemoveRelative('written/directory-b'), 'removing directory-b');
end;

function VolumeHasJournal: Boolean;
begin
  Result := TextIsEqual(@CurrentVolume^.TypeName[0], 'ext3') or
    TextIsEqual(@CurrentVolume^.TypeName[0], 'ext4');
end;

{ The last test on a journaled volume: a rename committed to the journal
  and then "the machine crashes" before it is written in place. }
procedure TestCrashAfterCommit;
var
  Orphan: POpenFile;
begin
  { Left open across the crash after its removal: on the orphan list,
    which e2fsck processes after replaying the journal. }
  CheckStatus(OpenRelative('written/orphan.bin', OpenForWriting or OpenCreate, Orphan), 'creating orphan.bin');
  WriteFilled(Orphan, Ord('O'), 30 * 1024);
  CheckStatus(RemoveRelative('written/orphan.bin'), 'removing the open orphan.bin');
  WriteWholeFile('written/journal-pending.txt', 'committed'#10);
  Check(SimulateCrashAfterNextCommit(CurrentVolume), 'the volume has no journal being written');
  CheckStatus(RenameRelative('written/journal-pending.txt', 'written/journal-committed.txt'),
    'renaming in the crashed transaction');
  Check(CurrentVolume^.IsReadOnly, 'the volume still writes after the simulated crash');
  { Closed after the "crash": nothing is written, it stays an orphan. }
  CloseFile(Orphan);
end;

procedure ReportPassed(Volume: PVolume);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite('filesystem writes ');
  DebugWrite(@Volume^.TypeName[0]);
  DebugWrite(' on ');
  DebugWrite(@Volume^.Name[0]);
  DebugWrite(': ');
  DebugSetColor(ColorGreen);
  DebugWrite('passed');
  DebugResetColor;
  DebugWriteLine('');
  DebugEndMessage;
end;

function VolumeIsWritableTestVolume(Volume: PVolume): Boolean;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  Information: TNodeInformation;
begin
  Result := False;
  if Volume^.IsReadOnly then
    Exit;
  CurrentVolume := Volume;
  BuildPath('fstype.txt', @Path[0]);
  Result := GetPathInformation(@Path[0], Information) = StatusSuccess;
end;

function RunFileSystemWriteTests: Integer;
var
  VolumeIndex: Integer;
  Volume: PVolume;
begin
  Result := 0;
  for VolumeIndex := 0 to VolumeCount - 1 do
  begin
    Volume := VolumeAt(VolumeIndex);
    if not VolumeIsWritableTestVolume(Volume) then
      Continue;

    CurrentVolume := Volume;
    TestCreateAndOverwrite;
    TestBigFile;
    TestGapsAndSizes;
    TestRenameAndRemove;
    TestManyFiles;
    TestSymbolicLinks;
    TestSparseFile;
    TestRemoveWhileOpen;
    TestRenameOverExisting;
    if VolumeHasJournal then
      TestCrashAfterCommit;
    ReportPassed(Volume);
    Inc(Result);
  end;
  SyncAllVolumes;
end;

end.
