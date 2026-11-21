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
  Mounting and unmounting volumes, the list of mounts, and file times
  to the nanosecond (system calls 172-175).

  MountVolume mounts a device ("/dev/disk1p2"), a volume of /volumes
  ("/volumes/disk1p2") or a new memory volume (FileSystemType "tmpfs")
  at a directory, with options such as "ro,noexec,uid=1000,umask=022"
  or "size=64m,mode=1777"; root only. UnmountVolume takes it away again
  (ErrorBusy while it is in use, unless forced). GetMountDescription
  lists every mounted volume and where it is.
}
unit Sys.Mounts;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls;

type
  TMountDescription = record
    Name: string;
    Source: string;
    FileSystemType: string;
    MountPoint: string;
    Options: string;
    VolumeNumber: LongWord;
    IsAtDirectory: Boolean;
  end;

  TFileTimes = TAbiFileTimes;

{ Returns ErrorNone or an Abi error code. }
function MountVolume(const Source, Target, FileSystemType, Options: string): LongInt;
function UnmountVolume(const Path: string; Force: Boolean): LongInt;
{ The Index-th mounted volume (from 0); False after the last. }
function GetMountDescription(Index: Integer; out Description: TMountDescription): Boolean;
{ The four times of a file; FollowLinks describes what a final link
  points at. }
function GetFileTimes(const Path: string; FollowLinks: Boolean; out Times: TFileTimes): LongInt;
function GetHandleFileTimes(Handle: Int64; out Times: TFileTimes): LongInt;

implementation

uses
  Sys.Errors;

procedure CopyField(const Text: string; Destination: PChar; Capacity: Integer);
var
  Count: Integer;
begin
  Count := Length(Text);
  if Count > Capacity - 1 then
    Count := Capacity - 1;
  if Count > 0 then
    Move(Text[1], Destination^, Count);
  Destination[Count] := #0;
end;

function MountVolume(const Source, Target, FileSystemType, Options: string): LongInt;
var
  Request: TAbiMountRequest;
begin
  FillChar(Request, SizeOf(Request), 0);
  CopyField(Source, @Request.Source[0], AbiMountTextCapacity);
  CopyField(Target, @Request.Target[0], AbiMountTextCapacity);
  CopyField(FileSystemType, @Request.FileSystemType[0], AbiTextCapacity);
  CopyField(Options, @Request.Options[0], AbiMountTextCapacity);
  Result := ErrorCodeOf(SystemCall(CallMountVolume, QWord(@Request), 0, 0, 0, 0, 0));
end;

function UnmountVolume(const Path: string; Force: Boolean): LongInt;
var
  Flags: QWord;
begin
  Flags := 0;
  if Force then
    Flags := UnmountForce;
  Result := ErrorCodeOf(SystemCall(CallUnmountVolume, QWord(PChar(Path)), Flags, 0, 0, 0, 0));
end;

function GetMountDescription(Index: Integer; out Description: TMountDescription): Boolean;
var
  Information: TAbiMountInformation;
begin
  Description := Default(TMountDescription);
  FillChar(Information, SizeOf(Information), 0);
  Result := SystemCall(CallListMounts, QWord(Index), QWord(@Information), 0, 0, 0, 0) = 1;
  if not Result then
    Exit;
  Description.Name := PChar(@Information.Name[0]);
  Description.Source := PChar(@Information.Source[0]);
  Description.FileSystemType := PChar(@Information.FileSystemType[0]);
  Description.MountPoint := PChar(@Information.MountPoint[0]);
  Description.Options := PChar(@Information.Options[0]);
  Description.VolumeNumber := Information.VolumeNumber;
  Description.IsAtDirectory := Information.IsAtDirectory <> 0;
end;

function GetFileTimes(const Path: string; FollowLinks: Boolean; out Times: TFileTimes): LongInt;
var
  Flags: QWord;
begin
  FillChar(Times, SizeOf(Times), 0);
  Flags := 0;
  if FollowLinks then
    Flags := FileTimesFollowLinks;
  Result := ErrorCodeOf(SystemCall(CallGetFileTimes, QWord(PChar(Path)), 0, Flags, QWord(@Times), 0, 0));
end;

function GetHandleFileTimes(Handle: Int64; out Times: TFileTimes): LongInt;
begin
  FillChar(Times, SizeOf(Times), 0);
  Result := ErrorCodeOf(SystemCall(CallGetFileTimes, 0, QWord(Handle), 0, QWord(@Times), 0, 0));
end;

end.
