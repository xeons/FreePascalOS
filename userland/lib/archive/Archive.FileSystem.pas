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
  What the archive units need from the file system beyond SysUtils:
  a path's time and mode, setting them, and symbolic links. On the
  system they go to libsystem (Sys.Files); built for the host (the
  host test, where UNIX is defined; the system is built with it
  undefined) to the host's Unix calls.
}
unit Archive.FileSystem;

{$mode objfpc}
{$H+}

interface

{ A path's modification time (Unix seconds) and mode with its file type
  (following symbolic links). }
function GetPathDetails(const Path: string; out ModificationTime: Int64; out Mode: LongWord): Boolean;
{ Sets the modification (and access) time of a path, not following a
  final symbolic link where the system can. }
function SetPathModificationTime(const Path: string; ModificationTime: Int64): Boolean;
{ Sets the permission bits of Mode on a path. }
function SetPathMode(const Path: string; Mode: LongWord): Boolean;
function CreateSymbolicLink(const Target, Path: string): Boolean;
{ Whether something (a symbolic link included, even a broken one) is
  at Path. }
function PathIsTaken(const Path: string): Boolean;

implementation

uses
{$ifdef UNIX}
  BaseUnix,
{$else}
  Abi.SystemCalls,
  Sys.Files,
{$endif}
  Archive.Entries;

{$ifdef UNIX}

function GetPathDetails(const Path: string; out ModificationTime: Int64; out Mode: LongWord): Boolean;
var
  Status: Stat;
begin
  ModificationTime := 0;
  Mode := 0;
  Result := FpStat(Path, Status) = 0;
  if Result then
  begin
    ModificationTime := Status.st_mtime;
    Mode := Status.st_mode;
  end;
end;

function SetPathModificationTime(const Path: string; ModificationTime: Int64): Boolean;
var
  Times: UTimBuf;
begin
  Times.actime := ModificationTime;
  Times.modtime := ModificationTime;
  Result := FpUtime(Path, @Times) = 0;
end;

function SetPathMode(const Path: string; Mode: LongWord): Boolean;
begin
  Result := FpChmod(Path, Mode and ModePermissionMask) = 0;
end;

function CreateSymbolicLink(const Target, Path: string): Boolean;
begin
  Result := FpSymlink(PChar(Target), PChar(Path)) = 0;
end;

function PathIsTaken(const Path: string): Boolean;
var
  Status: Stat;
begin
  Result := FpLstat(Path, Status) = 0;
end;

{$else}

function GetPathDetails(const Path: string; out ModificationTime: Int64; out Mode: LongWord): Boolean;
var
  Information: TFileInformation;
begin
  ModificationTime := 0;
  Mode := 0;
  Result := GetFileInformation(PChar(Path), Information) = 0;
  if not Result then
    Exit;
  ModificationTime := Information.ModificationTime;
  Mode := Information.Mode and $FFF;
  case Information.Kind of
    KindDirectory: Mode := Mode or ModeFolder;
    KindSymbolicLink: Mode := Mode or ModeSymbolicLink;
    KindFile: Mode := Mode or ModeRegularFile;
  end;
end;

function SetPathModificationTime(const Path: string; ModificationTime: Int64): Boolean;
begin
  Result := SetFileTimes(PChar(Path), ModificationTime, ModificationTime, False) = 0;
end;

function SetPathMode(const Path: string; Mode: LongWord): Boolean;
begin
  Result := ChangeMode(PChar(Path), Mode and ModePermissionMask) = 0;
end;

function CreateSymbolicLink(const Target, Path: string): Boolean;
begin
  Result := Sys.Files.CreateSymbolicLink(PChar(Target), PChar(Path)) = 0;
end;

function PathIsTaken(const Path: string): Boolean;
var
  Information: TFileInformation;
begin
  Result := GetLinkInformation(PChar(Path), Information) = 0;
end;

{$endif}

end.
