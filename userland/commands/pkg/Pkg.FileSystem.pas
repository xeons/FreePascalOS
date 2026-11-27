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
  What pkg needs from the file system beyond SysUtils and libarchive's
  Archive.FileSystem: whether a path is a symbolic link, a link's
  target, a path's permission bits without following a link, folders
  made with their parents, a whole tree removed, and an exclusive lock
  on the database. On the system they go to libsystem (Sys.Files); built
  for the host (the host test, where UNIX is defined) to the host's
  Unix calls, so the installer runs there too.
}
unit Pkg.FileSystem;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

function IsSymbolicLink(const Path: string): Boolean;
function ReadLink(const Path: string; out Target: string): Boolean;
{ The permission bits of Path (not following a final link). }
function PathPermissions(const Path: string; out Mode: LongWord): Boolean;
function IsRegularFile(const Path: string): Boolean;
function IsFolder(const Path: string): Boolean;
{ Makes Path and every missing parent; Made gets each folder made, the
  outermost first. }
function MakeFolders(const Path: string; var Made: TStringArray): Boolean;
{ Renames, replacing a file (not a folder) at NewPath. }
function RenamePathOver(const OldPath, NewPath: string): Boolean;
function RemoveFileOrLink(const Path: string): Boolean;
function RemoveEmptyFolder(const Path: string): Boolean;
function RemoveTree(const Path: string): Boolean;
{ An exclusive lock held while the handle is open; -1 when another
  holds it or the file cannot be made. }
function AcquireLock(const Path: string): Int64;
procedure ReleaseLock(Handle: Int64);

implementation

uses
{$ifdef UNIX}
  BaseUnix,
  Unix;
{$else}
  Abi.SystemCalls,
  Sys.Files;
{$endif}

{$ifdef UNIX}

function IsSymbolicLink(const Path: string): Boolean;
var
  Status: Stat;
begin
  Result := (FpLstat(Path, Status) = 0) and FpS_ISLNK(Status.st_mode);
end;

function ReadLink(const Path: string; out Target: string): Boolean;
begin
  Target := FpReadLink(Path);
  Result := IsSymbolicLink(Path);
end;

function PathPermissions(const Path: string; out Mode: LongWord): Boolean;
var
  Status: Stat;
begin
  Mode := 0;
  Result := FpLstat(Path, Status) = 0;
  if Result then
    Mode := Status.st_mode and &7777;
end;

function IsRegularFile(const Path: string): Boolean;
var
  Status: Stat;
begin
  Result := (FpLstat(Path, Status) = 0) and FpS_ISREG(Status.st_mode);
end;

function IsFolder(const Path: string): Boolean;
var
  Status: Stat;
begin
  Result := (FpLstat(Path, Status) = 0) and FpS_ISDIR(Status.st_mode);
end;

function RenamePathOver(const OldPath, NewPath: string): Boolean;
begin
  Result := FpRename(OldPath, NewPath) = 0;
end;

function RemoveFileOrLink(const Path: string): Boolean;
begin
  Result := FpUnlink(Path) = 0;
end;

function RemoveEmptyFolder(const Path: string): Boolean;
begin
  Result := FpRmdir(Path) = 0;
end;

function AcquireLock(const Path: string): Int64;
var
  Handle: LongInt;
begin
  Handle := FpOpen(Path, O_RDWR or O_CREAT, &644);
  if Handle < 0 then
    Exit(-1);
  if FpFlock(Handle, LOCK_EX or LOCK_NB) <> 0 then
  begin
    FpClose(Handle);
    Exit(-1);
  end;
  Result := Handle;
end;

procedure ReleaseLock(Handle: Int64);
begin
  if Handle >= 0 then
    FpClose(LongInt(Handle));
end;

{$else}

function IsSymbolicLink(const Path: string): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetLinkInformation(PChar(Path), Information) = ErrorNone) and (Information.Kind = KindSymbolicLink);
end;

function ReadLink(const Path: string; out Target: string): Boolean;
begin
  Result := ReadLinkTarget(Path, Target) = ErrorNone;
end;

function PathPermissions(const Path: string; out Mode: LongWord): Boolean;
var
  Information: TFileInformation;
begin
  Mode := 0;
  Result := GetLinkInformation(PChar(Path), Information) = ErrorNone;
  if Result then
    Mode := Information.Mode and &7777;
end;

function IsRegularFile(const Path: string): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetLinkInformation(PChar(Path), Information) = ErrorNone) and (Information.Kind = KindFile);
end;

function IsFolder(const Path: string): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetLinkInformation(PChar(Path), Information) = ErrorNone) and (Information.Kind = KindDirectory);
end;

function RenamePathOver(const OldPath, NewPath: string): Boolean;
begin
  Result := RenamePath(PChar(OldPath), PChar(NewPath)) = ErrorNone;
end;

function RemoveFileOrLink(const Path: string): Boolean;
begin
  Result := RemovePath(PChar(Path)) = ErrorNone;
end;

function RemoveEmptyFolder(const Path: string): Boolean;
begin
  Result := RemovePath(PChar(Path)) = ErrorNone;
end;

function AcquireLock(const Path: string): Int64;
begin
  Result := OpenFile(PChar(Path), OpenRead or OpenWrite or OpenCreate);
  if Result < 0 then
    Exit(-1);
  if LockFile(Result, FileLockExclusive or FileLockNoWait) <> ErrorNone then
  begin
    CloseFile(Result);
    Exit(-1);
  end;
end;

procedure ReleaseLock(Handle: Int64);
begin
  if Handle >= 0 then
    CloseFile(Handle);
end;

{$endif}

function MakeFolders(const Path: string; var Made: TStringArray): Boolean;
var
  Parent: string;
begin
  if (Path = '') or IsFolder(Path) then
    Exit(True);
  Parent := ExtractFileDir(ExcludeTrailingPathDelimiter(Path));
  if (Parent <> '') and (Parent <> Path) and not MakeFolders(Parent, Made) then
    Exit(False);
  Result := CreateDir(Path);
  if Result then
  begin
    SetLength(Made, Length(Made) + 1);
    Made[High(Made)] := Path;
  end
  else
    Result := IsFolder(Path);
end;

{ Symbolic links too: the host's FindFirst leaves them out unless asked. }
{$push}
{$warn SYMBOL_PLATFORM off}
const
  SearchEverything = faAnyFile or faSymLink;
{$pop}

function RemoveTree(const Path: string): Boolean;
var
  Search: TSearchRec;
  Child: string;
begin
  if IsSymbolicLink(Path) or IsRegularFile(Path) then
    Exit(RemoveFileOrLink(Path));
  if not IsFolder(Path) then
    Exit(True);
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', SearchEverything, Search) = 0 then
  begin
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      Child := IncludeTrailingPathDelimiter(Path) + Search.Name;
      RemoveTree(Child);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  Result := RemoveEmptyFolder(Path);
end;

end.
