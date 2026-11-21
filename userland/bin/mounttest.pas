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
  mounttest - checks mounting volumes at directories and memory volumes

  Run by coretest as root. Works in /tmp/mounttest (on the memory volume
  /etc/fstab mounts on /tmp, so the mounts here are nested) and checks:

    * a memory volume (tmpfs) mounted at a directory with size= and
      mode=: another volume number, the root's mode, its free space;
    * its pages: written files take the RAM the kernel counts for
      drivers, a write past size= fails with "no space", and removing
      the files gives every page back, unmounting too;
    * crossing mount points: a rename or a hard link from it to the
      volume below fails with ErrorCrossVolume, the mount point cannot
      be renamed or removed (ErrorBusy), a symbolic link with ".." or
      an absolute target leads out of the mounted volume;
    * the /volumes/system alias names the system volume;
    * unmounting: refused while a file is open (ErrorBusy), done once it
      is closed (the directory below shows again); forced while open,
      after which the open file fails with ErrorNoDevice;
    * an unknown option is refused (ErrorInvalidArgument);
    * file times to the nanosecond: a birth time on a memory volume,
      the access time set alone.

  Prints a line per check and "mounttest: N of N checks passed"; the
  exit status is 1 if any check failed.
}
program mounttest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Mounts,
  Sys.Streams,
  Sys.SystemUsage,
  Util.FileTree;

const
  WorkDirectory = '/tmp/mounttest';
  MountPoint = '/tmp/mounttest/mem';
  MegaByte = 1024 * 1024;
  { Other drivers may take or give back pages meanwhile. }
  MemorySlack = 512 * 1024;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    PrintStringLine('mounttest: pass: ' + Name)
  else
  begin
    PrintStringLine('mounttest: FAIL: ' + Name);
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

function DriverMemory: QWord;
var
  Usage: TSystemUsage;
begin
  Result := 0;
  if GetSystemUsage(Usage) = ErrorNone then
    Result := Usage.DriverMemory;
end;

function VolumeNumberOf(const Path: string): LongWord;
var
  Information: TFileInformation;
begin
  Result := 0;
  if GetFileInformation(PChar(Path), Information) = ErrorNone then
    Result := Information.VolumeNumber;
end;

function ModeOf(const Path: string): LongWord;
var
  Information: TFileInformation;
begin
  Result := $FFFF;
  if GetFileInformation(PChar(Path), Information) = ErrorNone then
    Result := Information.Mode and $FFF;
end;

function FreeBytesAt(const Path: string): QWord;
var
  Information: TAbiVolumeInformation;
begin
  Result := 0;
  if SystemCall(CallGetVolumeInformation, QWord(PChar(Path)), QWord(@Information), 0, 0, 0, 0) = 0 then
    Result := Information.FreeBytes;
end;

{ Writes Count bytes of Value; the first error, or ErrorNone. }
function WriteFilled(const Path: string; Count: QWord): LongInt;
var
  Handle: Int64;
  Buffer: array[0..65535] of Byte;
  Piece: QWord;
begin
  FillChar(Buffer, SizeOf(Buffer), $A5);
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  Result := ErrorNone;
  while (Count > 0) and (Result = ErrorNone) do
  begin
    Piece := SizeOf(Buffer);
    if Piece > Count then
      Piece := Count;
    Result := WriteAll(Handle, @Buffer[0], Piece);
    Count := Count - Piece;
  end;
  CloseFile(Handle);
end;

function WriteText(const Path, Text: string): Boolean;
var
  Handle: Int64;
begin
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(False);
  Result := (Text = '') or (WriteAll(Handle, PChar(Text), Length(Text)) = ErrorNone);
  CloseFile(Handle);
end;

function ReadText(const Path: string): string;
var
  Handle: Int64;
  Buffer: array[0..255] of Char;
  Count: Int64;
begin
  Result := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit;
  Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
  if Count > 0 then
    SetString(Result, PChar(@Buffer[0]), Count);
  CloseFile(Handle);
end;

function IsMounted(const Path: string): Boolean;
var
  Index: Integer;
  Description: TMountDescription;
begin
  Index := 0;
  while GetMountDescription(Index, Description) do
  begin
    if Description.IsAtDirectory and (Description.MountPoint = Path) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

procedure TestMemoryVolume;
var
  BeforeMount: QWord;
  BeforeWrite: QWord;
  Error: LongInt;
begin
  BeforeMount := DriverMemory;
  Check('mounting tmpfs with size=4m,mode=0750',
    MountVolume('tmpfs', MountPoint, 'tmpfs', 'size=4m,mode=0750') = ErrorNone);
  Check('it is listed at its directory', IsMounted(MountPoint));
  Check('it is another volume', VolumeNumberOf(MountPoint) <> VolumeNumberOf(WorkDirectory));
  Check('its root has the mode asked for', ModeOf(MountPoint) = $1E8);
  Check('its free space is the size asked for', FreeBytesAt(MountPoint) = 4 * MegaByte);

  BeforeWrite := DriverMemory;
  Check('writing 2 MiB', WriteFilled(MountPoint + '/big', 2 * MegaByte) = ErrorNone);
  Check('the pages are taken from the RAM', DriverMemory + MemorySlack >= BeforeWrite + 2 * MegaByte);
  Check('the free space shrinks', FreeBytesAt(MountPoint) = 2 * MegaByte);
  Error := WriteFilled(MountPoint + '/more', 3 * MegaByte);
  Check('a write past size= fails with no space', Error = ErrorNoSpace);
  RemovePath(PChar(MountPoint + '/more'));
  RemovePath(PChar(MountPoint + '/big'));
  Check('removing gives the pages back', DriverMemory <= BeforeWrite + MemorySlack);
  Check('the free space is whole again', FreeBytesAt(MountPoint) = 4 * MegaByte);

  Check('unmounting the idle volume', UnmountVolume(MountPoint, False) = ErrorNone);
  Check('it is no longer listed', not IsMounted(MountPoint));
  Check('the memory is back after unmounting', DriverMemory <= BeforeMount + MemorySlack);
end;

procedure TestCrossing;
var
  Outside: string;
begin
  Check('mounting tmpfs again', MountVolume('tmpfs', MountPoint, 'tmpfs', '') = ErrorNone);
  Outside := WorkDirectory + '/outside.txt';
  WriteText(Outside, 'outside');
  WriteText(MountPoint + '/inside.txt', 'inside');
  Check('a rename out of the mounted volume is refused',
    RenamePath(PChar(MountPoint + '/inside.txt'), PChar(WorkDirectory + '/moved.txt')) = ErrorCrossVolume);
  Check('a rename into it is refused',
    RenamePath(PChar(Outside), PChar(MountPoint + '/outside.txt')) = ErrorCrossVolume);
  Check('a hard link across is refused',
    CreateHardLink(PChar(Outside), PChar(MountPoint + '/link.txt')) = ErrorCrossVolume);
  Check('the mount point cannot be renamed',
    RenamePath(PChar(MountPoint), PChar(WorkDirectory + '/renamed')) = ErrorBusy);
  Check('the mount point cannot be removed', RemovePath(PChar(MountPoint)) = ErrorBusy);
  Check('".." of a path leads back out', ReadText(MountPoint + '/../outside.txt') = 'outside');
  CreateSymbolicLink('../outside.txt', PChar(MountPoint + '/up'));
  Check('a link with ".." leads out of the mounted volume', ReadText(MountPoint + '/up') = 'outside');
  CreateSymbolicLink(PChar(Outside), PChar(MountPoint + '/absolute'));
  Check('an absolute link starts at the system root', ReadText(MountPoint + '/absolute') = 'outside');
  CreateSymbolicLink(PChar(MountPoint + '/inside.txt'), PChar(WorkDirectory + '/down'));
  Check('a link into the mounted volume', ReadText(WorkDirectory + '/down') = 'inside');
  Check('/volumes/system is the system volume',
    (VolumeNumberOf('/volumes/system/bin') <> 0) and (VolumeNumberOf('/volumes/system/bin') = VolumeNumberOf('/bin')));
end;

procedure TestUnmounting;
var
  Handle: Int64;
  Buffer: array[0..15] of Char;
begin
  Handle := OpenFile(PChar(MountPoint + '/inside.txt'), OpenRead);
  Check('unmounting is refused while a file is open', UnmountVolume(MountPoint, False) = ErrorBusy);
  CloseFile(Handle);
  Check('unmounting once it is closed', UnmountVolume(MountPoint, False) = ErrorNone);
  Check('the directory below shows again', not PathExists(PChar(MountPoint + '/inside.txt')));

  Check('mounting for a forced unmount', MountVolume('tmpfs', MountPoint, 'tmpfs', '') = ErrorNone);
  WriteText(MountPoint + '/open.txt', 'open');
  Handle := OpenFile(PChar(MountPoint + '/open.txt'), OpenRead);
  Check('a forced unmount while a file is open', UnmountVolume(MountPoint, True) = ErrorNone);
  Check('the open file fails afterwards', ErrorCodeOf(ReadFile(Handle, @Buffer[0], SizeOf(Buffer))) = ErrorNoDevice);
  CloseFile(Handle);

  Check('an unknown option is refused',
    MountVolume('tmpfs', MountPoint, 'tmpfs', 'nonsense') = ErrorInvalidArgument);
  Check('unmounting a folder that is no mount point is refused',
    UnmountVolume(WorkDirectory, False) = ErrorInvalidArgument);
  Check('the system volume is never unmounted', UnmountVolume('/', False) = ErrorBusy);
end;

procedure TestTimes;
var
  Path: string;
  Before: TFileTimes;
  After: TFileTimes;
begin
  Path := WorkDirectory + '/timed.txt';
  WriteText(Path, 'time');
  Check('reading the times', GetFileTimes(Path, True, Before) = ErrorNone);
  Check('a memory volume keeps the birth time', (Before.Flags and FileTimesHasBirthTime) <> 0);
  Check('nanoseconds are in range', Before.Modification.Nanoseconds < 1000000000);
  Check('setting the access time alone',
    SetFileTimes(PChar(Path), -1, 1000000000, True) = ErrorNone);
  GetFileTimes(Path, True, After);
  Check('the access time changed', After.Access.Seconds = 1000000000);
  Check('the modification time stayed', After.Modification.Seconds = Before.Modification.Seconds);
end;

begin
  if PathExists(WorkDirectory) then
    RemoveTree(WorkDirectory);
  CreateDirectory(WorkDirectory);
  CreateDirectory(MountPoint);
  TestMemoryVolume;
  TestCrossing;
  TestUnmounting;
  TestTimes;
  if IsMounted(MountPoint) then
    UnmountVolume(MountPoint, True);
  RemoveTree(WorkDirectory);
  PrintStringLine(Format('mounttest: %d of %d checks passed', [Checks - Failures, Checks]));
  FlushStream(StandardOutput);
  if Failures > 0 then
    Halt(1);
end.
