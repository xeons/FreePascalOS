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
  Files and directories.

  Thin, typed layer over the file system calls. Functions returning Int64
  give a handle (or count) on success and a negative error code on
  failure; functions returning LongInt give 0 or an error code.
}
unit Sys.Files;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

type
  TFileInformation = TAbiFileInformation;
  TDirectoryEntry = TAbiDirectoryEntry;

const
  PathCapacity = 1024;

function OpenFile(Path: PChar; Flags: LongWord): Int64;
procedure CloseFile(Handle: Int64);
function ReadFile(Handle: Int64; Buffer: Pointer; Count: QWord): Int64;
function WriteFile(Handle: Int64; Buffer: Pointer; Count: QWord): Int64;
{ Writes everything (retrying partial writes); 0 or an error code. }
function WriteAll(Handle: Int64; Buffer: Pointer; Count: QWord): LongInt;
function SeekFile(Handle: Int64; Offset: Int64; Origin: LongWord): Int64;
function SetFileSize(Handle: Int64; Size: QWord): LongInt;

function GetFileInformation(Path: PChar; out Information: TFileInformation): LongInt;
{ Describes a symbolic link itself rather than what it points to. }
function GetLinkInformation(Path: PChar; out Information: TFileInformation): LongInt;
function GetHandleInformation(Handle: Int64; out Information: TFileInformation): LongInt;
function PathExists(Path: PChar): Boolean;
function IsDirectory(Path: PChar): Boolean;

{ Reads the next entry; returns False at the end (or on an error). }
function ReadDirectoryEntry(Handle: Int64; out Entry: TDirectoryEntry): Boolean;

function CreateDirectory(Path: PChar): LongInt;
function RemovePath(Path: PChar): LongInt;
function RenamePath(SourcePath, TargetPath: PChar): LongInt;
function CreateSymbolicLink(Target, Path: PChar): LongInt;
function ReadSymbolicLink(Path: PChar; Buffer: PChar; Capacity: QWord): LongInt;

function GetCurrentDirectory(Buffer: PChar; Capacity: QWord): LongInt;
function ChangeDirectory(Path: PChar): LongInt;

function SyncFileSystems: LongInt;

type
  TAttributeChanges = TAbiAttributeChanges;

{ Applies Changes (see the Change* flags). FollowLinks decides whether a
  final symbolic link or what it points to is changed. }
function SetPathAttributes(Path: PChar; const Changes: TAttributeChanges;
  FollowLinks: Boolean): LongInt;
function ChangeMode(Path: PChar; Mode: LongWord): LongInt;
function ChangeOwner(Path: PChar; OwnerId, GroupId: Int64; FollowLinks: Boolean): LongInt;
{ Times in seconds since 1970; a negative value leaves that time alone. }
function SetFileTimes(Path: PChar; ModificationTime, AccessTime: Int64;
  FollowLinks: Boolean): LongInt;
{ Sets the chosen times to the current time; this is allowed to anyone
  who may write the file, not just its owner. }
function SetFileTimesToNow(Path: PChar; ChangeModification, ChangeAccess: Boolean;
  FollowLinks: Boolean): LongInt;
{ Creates a named pipe. }
function CreateFifo(Path: PChar): LongInt;
{ The permission bits taken away from files this program creates. }
function CurrentUmask: LongWord;
function CreateHardLink(ExistingPath, NewPath: PChar): LongInt;

implementation

uses
  Runtime.Memory,
  Sys.Kernel,
  Sys.Errors;

function OpenFile(Path: PChar; Flags: LongWord): Int64;
begin
  Result := KernelOpen(Path, Flags);
end;

procedure CloseFile(Handle: Int64);
begin
  KernelClose(Handle);
end;

function ReadFile(Handle: Int64; Buffer: Pointer; Count: QWord): Int64;
begin
  Result := KernelRead(Handle, Buffer, Count);
end;

function WriteFile(Handle: Int64; Buffer: Pointer; Count: QWord): Int64;
begin
  Result := KernelWrite(Handle, Buffer, Count);
end;

function WriteAll(Handle: Int64; Buffer: Pointer; Count: QWord): LongInt;
var
  Written: QWord;
  WriteResult: Int64;
begin
  Written := 0;
  while Written < Count do
  begin
    WriteResult := KernelWrite(Handle, PByte(Buffer) + Written, Count - Written);
    if WriteResult < 0 then
      Exit(ErrorCodeOf(WriteResult));
    if WriteResult = 0 then
      Exit(ErrorIo);
    Written := Written + QWord(WriteResult);
  end;
  Result := ErrorNone;
end;

function SeekFile(Handle: Int64; Offset: Int64; Origin: LongWord): Int64;
begin
  Result := KernelSeek(Handle, Offset, Origin);
end;

function SetFileSize(Handle: Int64; Size: QWord): LongInt;
begin
  Result := ErrorCodeOf(KernelSetFileSize(Handle, Size));
end;

function GetFileInformation(Path: PChar; out Information: TFileInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelGetPathInformation(Path, Information, True));
end;

function GetLinkInformation(Path: PChar; out Information: TFileInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelGetPathInformation(Path, Information, False));
end;

function GetHandleInformation(Handle: Int64; out Information: TFileInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelGetHandleInformation(Handle, Information));
end;

function PathExists(Path: PChar): Boolean;
var
  Information: TFileInformation;
begin
  Result := GetLinkInformation(Path, Information) = ErrorNone;
end;

function IsDirectory(Path: PChar): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetFileInformation(Path, Information) = ErrorNone) and (Information.Kind = KindDirectory);
end;

function ReadDirectoryEntry(Handle: Int64; out Entry: TDirectoryEntry): Boolean;
begin
  Result := KernelReadDirectory(Handle, Entry) > 0;
end;

function CreateDirectory(Path: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelCreateDirectory(Path));
end;

function RemovePath(Path: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelRemove(Path));
end;

function RenamePath(SourcePath, TargetPath: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelRename(SourcePath, TargetPath));
end;

function CreateSymbolicLink(Target, Path: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelCreateSymbolicLink(Target, Path));
end;

function ReadSymbolicLink(Path: PChar; Buffer: PChar; Capacity: QWord): LongInt;
begin
  Result := ErrorCodeOf(KernelReadSymbolicLink(Path, Buffer, Capacity));
end;

function GetCurrentDirectory(Buffer: PChar; Capacity: QWord): LongInt;
begin
  Result := ErrorCodeOf(KernelGetCurrentDirectory(Buffer, Capacity));
end;

function ChangeDirectory(Path: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelSetCurrentDirectory(Path));
end;

function SyncFileSystems: LongInt;
begin
  Result := ErrorCodeOf(KernelSync);
end;

function SetPathAttributes(Path: PChar; const Changes: TAttributeChanges;
  FollowLinks: Boolean): LongInt;
begin
  Result := ErrorCodeOf(KernelSetPathAttributes(Path, Changes, FollowLinks));
end;

function ChangeMode(Path: PChar; Mode: LongWord): LongInt;
var
  Changes: TAttributeChanges;
begin
  ZeroMemory(@Changes, SizeOf(Changes));
  Changes.Fields := ChangeFieldMode;
  Changes.Mode := Mode;
  Result := SetPathAttributes(Path, Changes, True);
end;

{ A negative id leaves that one alone. }
function ChangeOwner(Path: PChar; OwnerId, GroupId: Int64; FollowLinks: Boolean): LongInt;
var
  Changes: TAttributeChanges;
begin
  ZeroMemory(@Changes, SizeOf(Changes));
  if OwnerId >= 0 then
  begin
    Changes.Fields := Changes.Fields or ChangeFieldOwner;
    Changes.OwnerId := LongWord(OwnerId);
  end;
  if GroupId >= 0 then
  begin
    Changes.Fields := Changes.Fields or ChangeFieldGroup;
    Changes.GroupId := LongWord(GroupId);
  end;
  if Changes.Fields = 0 then
    Exit(ErrorNone);
  Result := SetPathAttributes(Path, Changes, FollowLinks);
end;

function SetFileTimesToNow(Path: PChar; ChangeModification, ChangeAccess: Boolean;
  FollowLinks: Boolean): LongInt;
var
  Changes: TAttributeChanges;
begin
  ZeroMemory(@Changes, SizeOf(Changes));
  Changes.Fields := ChangeFieldTimesAreNow;
  if ChangeModification then
    Changes.Fields := Changes.Fields or ChangeFieldModificationTime;
  if ChangeAccess then
    Changes.Fields := Changes.Fields or ChangeFieldAccessTime;
  Result := ErrorCodeOf(KernelSetPathAttributes(Path, Changes, FollowLinks));
end;

function CurrentUmask: LongWord;
begin
  { The only way to read the mask is to set it and put it back. }
  Result := LongWord(KernelSetUmask(0));
  KernelSetUmask(Result);
end;

function CreateFifo(Path: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelCreateFifo(Path));
end;

function SetFileTimes(Path: PChar; ModificationTime, AccessTime: Int64;
  FollowLinks: Boolean): LongInt;
var
  Changes: TAttributeChanges;
begin
  ZeroMemory(@Changes, SizeOf(Changes));
  if ModificationTime >= 0 then
  begin
    Changes.Fields := Changes.Fields or ChangeFieldModificationTime;
    Changes.ModificationTime := ModificationTime;
  end;
  if AccessTime >= 0 then
  begin
    Changes.Fields := Changes.Fields or ChangeFieldAccessTime;
    Changes.AccessTime := AccessTime;
  end;
  if Changes.Fields = 0 then
    Exit(ErrorNone);
  Result := SetPathAttributes(Path, Changes, FollowLinks);
end;

function CreateHardLink(ExistingPath, NewPath: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelCreateHardLink(ExistingPath, NewPath));
end;

end.
