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
  File system self test.

  Runs against every mounted volume that contains a file named
  fstype.txt, which is how the test disk built by
  scripts/make-test-disk.sh marks its partitions. Each such volume must
  hold the same set of files (see that script), and the test checks that
  the driver reads all of them correctly through the normal path based
  interface: names, long names, nested directories, large and fragmented
  files, sparse files, directory listings and symbolic links.

  Volumes without fstype.txt are listed but not tested.
}
unit Kernel.FileSystemTest;

{$mode objfpc}
{$pointermath on}

interface

{ Returns the number of volumes that were tested. }
function RunFileSystemSelfTests: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Panic,
  FileSystem.Types,
  FileSystem.Volumes,
  FileSystem.Files,
  Debug.Output,
  Debug.FramebufferConsole;

const
  ExpectedHello = 'Hello from FreePascalOS!'#10;
  ExpectedLongNameContents = 'Long file names work.'#10;
  ExpectedDeepContents = 'Found the deep file.'#10;
  LongFileName = 'A long file name with spaces.txt';
  LongFileNameUpperCase = 'A LONG FILE NAME WITH SPACES.TXT';
  BigFileSize = 300 * 1024;
  BigFilePatternModulus = 251;
  SparseFileSize = 1024 * 1024;
  SparseRegionStride = 65536;
  SparseRegionLength = 4096;
  SmallFileCapacity = 256;

var
  CurrentVolume: PVolume;

{ --- Helpers --------------------------------------------------------- }

procedure Check(Condition: Boolean; Description: PChar);
begin
  if not Condition then
  begin
    BeginKernelPanic(PanicAssertionFailed, 'file system self test failed');
    DebugWrite('  Volume ');
    DebugWrite(@CurrentVolume^.Name[0]);
    DebugWrite(' (');
    DebugWrite(@CurrentVolume^.TypeName[0]);
    DebugWriteLine(')');
    DebugWrite('  ');
    DebugWriteLine(Description);
    FinishKernelPanic;
  end;
end;

procedure CheckStatus(Status: TFileSystemStatus; Description: PChar);
begin
  if Status <> StatusSuccess then
  begin
    BeginKernelPanic(PanicAssertionFailed, 'file system self test failed');
    DebugWrite('  Volume ');
    DebugWrite(@CurrentVolume^.Name[0]);
    DebugWrite(' (');
    DebugWrite(@CurrentVolume^.TypeName[0]);
    DebugWriteLine(')');
    DebugWrite('  ');
    DebugWrite(Description);
    DebugWrite(': ');
    DebugWriteLine(FileSystemStatusText(Status));
    FinishKernelPanic;
  end;
end;

{ Builds "/<volume>/<RelativePath>". }
procedure BuildPath(Volume: PVolume; RelativePath: PChar; Path: PChar);
var
  Length: PtrUInt;
begin
  Path[0] := '/';
  CopyText(Path + 1, @Volume^.Name[0], MaximumPathBytes - 1);
  Length := TextLength(Path);
  Path[Length] := '/';
  CopyText(Path + Length + 1, RelativePath, MaximumPathBytes - Length - 1);
end;

{ Reads a whole small file into Buffer (zero terminated). }
function ReadSmallFile(Volume: PVolume; RelativePath: PChar; Buffer: PChar;
  Capacity: PtrUInt): TFileSystemStatus;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  OpenedFile: POpenFile;
  BytesRead: QWord;
begin
  BuildPath(Volume, RelativePath, @Path[0]);
  Result := OpenPath(@Path[0], OpenedFile);
  if Result <> StatusSuccess then
    Exit;
  Result := ReadFromFile(OpenedFile, Buffer, Capacity - 1, BytesRead);
  if Result = StatusSuccess then
    Buffer[BytesRead] := #0;
  CloseFile(OpenedFile);
end;

procedure CheckFileContents(Volume: PVolume; RelativePath: PChar; Expected: PChar);
var
  Contents: array[0..SmallFileCapacity - 1] of Char;
begin
  CheckStatus(ReadSmallFile(Volume, RelativePath, @Contents[0], SmallFileCapacity), RelativePath);
  Check(TextIsEqual(@Contents[0], Expected), RelativePath);
end;

function VolumeTypeIsExt(Volume: PVolume): Boolean;
begin
  Result := (Volume^.TypeName[0] = 'e') and (Volume^.TypeName[1] = 'x') and
    (Volume^.TypeName[2] = 't');
end;

{ --- Individual checks ----------------------------------------------- }

procedure CheckDeclaredType(Volume: PVolume);
var
  Contents: array[0..SmallFileCapacity - 1] of Char;
  Length: PtrUInt;
begin
  CheckStatus(ReadSmallFile(Volume, 'fstype.txt', @Contents[0], SmallFileCapacity), 'fstype.txt');
  Length := TextLength(@Contents[0]);
  if (Length > 0) and (Contents[Length - 1] = #10) then
    Contents[Length - 1] := #0;
  Check(TextIsEqual(@Contents[0], @Volume^.TypeName[0]),
    'detected file system type does not match fstype.txt');
end;

procedure CheckNamesAndDirectories(Volume: PVolume);
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  Information: TNodeInformation;
begin
  CheckFileContents(Volume, 'hello.txt', ExpectedHello);
  CheckFileContents(Volume, LongFileName, ExpectedLongNameContents);
  CheckFileContents(Volume, 'docs/nested/deep.txt', ExpectedDeepContents);
  CheckFileContents(Volume, 'docs/./nested/../nested/deep.txt', ExpectedDeepContents);

  if not VolumeTypeIsExt(Volume) then
    CheckFileContents(Volume, LongFileNameUpperCase, ExpectedLongNameContents);

  BuildPath(Volume, 'does-not-exist.txt', @Path[0]);
  Check(GetPathInformation(@Path[0], Information) = StatusNotFound,
    'a missing file was not reported as not found');

  BuildPath(Volume, 'docs', @Path[0]);
  CheckStatus(GetPathInformation(@Path[0], Information), 'docs');
  Check(Information.Kind = NodeKindDirectory, 'docs is not reported as a directory');

  BuildPath(Volume, 'hello.txt/inside', @Path[0]);
  Check(GetPathInformation(@Path[0], Information) = StatusNotADirectory,
    'a file was treated as a directory');
end;

procedure CheckBigFile(Volume: PVolume);
const
  ChunkSize = 3001; { deliberately not a multiple of any block size }
  SeekTarget = 200000;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  OpenedFile: POpenFile;
  Information: TNodeInformation;
  Buffer: PByte;
  BytesRead: QWord;
  Position: QWord;
  Index: QWord;
begin
  BuildPath(Volume, 'big.bin', @Path[0]);
  CheckStatus(OpenPath(@Path[0], OpenedFile), 'big.bin');
  CheckStatus(GetFileInformation(OpenedFile, Information), 'big.bin information');
  Check(Information.SizeInBytes = BigFileSize, 'big.bin has the wrong size');

  Buffer := PByte(AllocateKernelMemory(ChunkSize));
  Check(Buffer <> nil, 'out of memory');

  Position := 0;
  repeat
    CheckStatus(ReadFromFile(OpenedFile, Buffer, ChunkSize, BytesRead), 'reading big.bin');
    Index := 0;
    while Index < BytesRead do
    begin
      Check(Buffer[Index] = Byte((Position + Index) mod BigFilePatternModulus),
        'big.bin contents are wrong');
      Inc(Index);
    end;
    Position := Position + BytesRead;
  until BytesRead = 0;
  Check(Position = BigFileSize, 'big.bin read returned the wrong number of bytes');

  SetFilePosition(OpenedFile, SeekTarget);
  CheckStatus(ReadFromFile(OpenedFile, Buffer, 16, BytesRead), 'reading big.bin after a seek');
  Check(BytesRead = 16, 'short read after a seek');
  for Index := 0 to 15 do
    Check(Buffer[Index] = Byte((SeekTarget + Index) mod BigFilePatternModulus),
      'big.bin contents after a seek are wrong');

  FreeKernelMemory(Buffer);
  CloseFile(OpenedFile);
end;

procedure AppendToListing(Listing: PChar; Text: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Listing);
  CopyText(Listing + Length, Text, MaximumPathBytes - Length);
end;

procedure CheckRootListing(Volume: PVolume);
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  Listing: array[0..MaximumPathBytes - 1] of Char;
  OpenedFile: POpenFile;
  Entry: TDirectoryEntry;
  Status: TFileSystemStatus;
  FoundHello: Boolean;
  FoundDocs: Boolean;
  FoundLongName: Boolean;
  EntryCount: Integer;
begin
  BuildPath(Volume, '', @Path[0]);
  CheckStatus(OpenPath(@Path[0], OpenedFile), 'root directory');

  FoundHello := False;
  FoundDocs := False;
  FoundLongName := False;
  EntryCount := 0;
  Listing[0] := #0;

  { The listing is collected first and printed afterwards: reading the
    directory takes mutexes, which is not allowed while holding the debug
    output lock. }
  repeat
    Status := ReadDirectoryEntry(OpenedFile, Entry);
    if Status = StatusEndOfDirectory then
      Break;
    CheckStatus(Status, 'listing the root directory');

    Inc(EntryCount);
    AppendToListing(@Listing[0], ' ');
    AppendToListing(@Listing[0], @Entry.Name[0]);
    if Entry.Kind = NodeKindDirectory then
      AppendToListing(@Listing[0], '/');

    if TextIsEqual(@Entry.Name[0], 'hello.txt') then
      FoundHello := True;
    if TextIsEqual(@Entry.Name[0], 'docs') and (Entry.Kind = NodeKindDirectory) then
      FoundDocs := True;
    if TextIsEqual(@Entry.Name[0], LongFileName) then
      FoundLongName := True;
  until False;
  CloseFile(OpenedFile);

  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite('/');
  DebugWrite(@Volume^.Name[0]);
  DebugWrite(':');
  DebugWriteLine(@Listing[0]);
  DebugEndMessage;

  Check(FoundHello, 'hello.txt missing from the root listing');
  Check(FoundDocs, 'docs missing from the root listing');
  Check(FoundLongName, 'the long file name is missing from the root listing');
  Check(EntryCount >= 5, 'root listing has too few entries');
end;

procedure CheckSparseFile(Volume: PVolume);
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  OpenedFile: POpenFile;
  Information: TNodeInformation;
  Buffer: PByte;
  BytesRead: QWord;
  Offset: QWord;
  Index: QWord;
  InDataRegion: Boolean;
begin
  BuildPath(Volume, 'sparse.bin', @Path[0]);
  CheckStatus(OpenPath(@Path[0], OpenedFile), 'sparse.bin');
  CheckStatus(GetFileInformation(OpenedFile, Information), 'sparse.bin information');
  Check(Information.SizeInBytes = SparseFileSize, 'sparse.bin has the wrong size');

  Buffer := PByte(AllocateKernelMemory(SparseFileSize));
  Check(Buffer <> nil, 'out of memory');
  CheckStatus(ReadFromFile(OpenedFile, Buffer, SparseFileSize, BytesRead), 'reading sparse.bin');
  Check(BytesRead = SparseFileSize, 'short read of sparse.bin');

  Offset := 0;
  while Offset < SparseFileSize do
  begin
    InDataRegion := (Offset mod SparseRegionStride) < SparseRegionLength;
    if InDataRegion then
      Check(Buffer[Offset] = Ord('D'), 'sparse.bin data region is wrong')
    else
      Check(Buffer[Offset] = 0, 'sparse.bin hole does not read as zero');
    Offset := Offset + 512;
  end;
  for Index := 0 to SparseRegionLength - 1 do
    Check(Buffer[15 * SparseRegionStride + Index] = Ord('D'), 'last sparse.bin region is wrong');

  FreeKernelMemory(Buffer);
  CloseFile(OpenedFile);
end;

{ ext3 and ext4 test volumes come with committed transactions in their
  journals (scripts/make-test-disk.sh), replayed when they were mounted. }
procedure CheckJournalReplay(Volume: PVolume);
const
  EscapedContents: PChar = #$C0#$3B#$39#$98'journal esc'#10;
begin
  CheckFileContents(Volume, 'journal-replay.txt', 'journal: was replayed'#10);
  CheckFileContents(Volume, 'journal-revoked.txt', 'revoked: untouched'#10);
  CheckFileContents(Volume, 'journal-escaped.txt', EscapedContents);
end;

function VolumeHasJournal(Volume: PVolume): Boolean;
begin
  Result := TextIsEqual(@Volume^.TypeName[0], 'ext3') or TextIsEqual(@Volume^.TypeName[0], 'ext4');
end;

procedure CheckSymbolicLinks(Volume: PVolume);
begin
  CheckFileContents(Volume, 'link-to-hello', ExpectedHello);
  CheckFileContents(Volume, 'docs/up-link', ExpectedHello);
  CheckFileContents(Volume, 'absolute-link', ExpectedDeepContents);
end;

{ --- Driver ---------------------------------------------------------- }

procedure ReportPassed(Volume: PVolume);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite('filesystem ');
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

function VolumeIsTestVolume(Volume: PVolume): Boolean;
var
  Path: array[0..MaximumPathBytes - 1] of Char;
  Information: TNodeInformation;
begin
  BuildPath(Volume, 'fstype.txt', @Path[0]);
  Result := GetPathInformation(@Path[0], Information) = StatusSuccess;
end;

function RunFileSystemSelfTests: Integer;
var
  VolumeIndex: Integer;
  Volume: PVolume;
begin
  Result := 0;
  for VolumeIndex := 0 to VolumeCount - 1 do
  begin
    Volume := VolumeAt(VolumeIndex);
    if not VolumeIsTestVolume(Volume) then
      Continue;

    CurrentVolume := Volume;
    CheckDeclaredType(Volume);
    CheckNamesAndDirectories(Volume);
    CheckBigFile(Volume);
    CheckRootListing(Volume);
    if VolumeTypeIsExt(Volume) then
    begin
      CheckSparseFile(Volume);
      CheckSymbolicLinks(Volume);
    end;
    if VolumeHasJournal(Volume) then
      CheckJournalReplay(Volume);
    ReportPassed(Volume);
    Inc(Result);
  end;
end;

end.
