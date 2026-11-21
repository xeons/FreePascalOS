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
  fstrim: discarding all the free space of a volume.

  TrimVolumeAtPath finds the volume holding Path, takes its lock (no
  allocation can happen meanwhile), syncs it and flushes the cache, so
  that what the disk holds as metadata is what the driver sees, sends
  the discards already batched, and lets the driver walk its free space
  (TFileSystemDriver.TrimFreeSpace), each free run going to the disk
  through FileSystem.Discards.TrimFreeRange.
}
unit FileSystem.Trim;

{$mode objfpc}

interface

uses
  FileSystem.Types;

{ Discards the free space of the volume holding Path; Discarded gets the
  bytes the disk took. StatusUnsupported for a volume that is read-only,
  whose disk cannot discard or whose driver cannot walk its free space. }
function TrimVolumeAtPath(Path: PChar; out Discarded: QWord): TFileSystemStatus;
function TrimVolume(Volume: PVolume; out Discarded: QWord): TFileSystemStatus;

implementation

uses
  Kernel.Mutex,
  Io.BlockDevice,
  Io.BlockCache,
  FileSystem.Files,
  FileSystem.Discards,
  Debug.Output;

procedure ReportTrim(Volume: PVolume; Discarded: QWord; Status: TFileSystemStatus);
begin
  DebugBeginMessage;
  DebugWriteTag('fs');
  DebugWrite(@Volume^.Name[0]);
  DebugWrite(': trimmed ');
  DebugWriteSize(Discarded);
  if Status <> StatusSuccess then
  begin
    DebugWrite(' (');
    DebugWrite(FileSystemStatusText(Status));
    DebugWrite(')');
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function TrimVolume(Volume: PVolume; out Discarded: QWord): TFileSystemStatus;
begin
  Discarded := 0;
  if Volume^.IsReadOnly or not BlockDeviceSupportsDiscard(Volume^.Device) or
     not Assigned(Volume^.Driver^.TrimFreeSpace) then
    Exit(StatusUnsupported);
  { What is batched goes first (it flushes too). }
  SendVolumeDiscards(Volume);
  AcquireMutex(Volume^.Lock);
  if Volume^.IsGone then
  begin
    ReleaseMutex(Volume^.Lock);
    Exit(StatusVolumeGone);
  end;
  Result := Volume^.Driver^.Sync(Volume);
  if (Result = StatusSuccess) and not FlushCachedDevice(Volume^.Device) then
    Result := StatusIoError;
  if Result = StatusSuccess then
    Result := Volume^.Driver^.TrimFreeSpace(Volume, Discarded);
  ReleaseMutex(Volume^.Lock);
  ReportTrim(Volume, Discarded, Result);
end;

function TrimVolumeAtPath(Path: PChar; out Discarded: QWord): TFileSystemStatus;
var
  Opened: POpenFile;
  Volume: PVolume;
begin
  Discarded := 0;
  Result := OpenPath(Path, Opened);
  if Result <> StatusSuccess then
    Exit;
  Volume := Opened^.Volume;
  CloseFile(Opened);
  if Volume = nil then
    Exit(StatusInvalidPath);
  Result := TrimVolume(Volume, Discarded);
end;

end.
