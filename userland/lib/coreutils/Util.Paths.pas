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
  Path names. BaseName, DirectoryName and JoinPath are purely textual;
  CanonicalizePath consults the file system to resolve symbolic links.

  Every routine works on strings; the PChar forms (whose results are new
  heap strings) are kept for the tools not yet moved to strings.
}
unit Util.Paths;

{$mode objfpc}{$H+}
{$pointermath on}

interface

{ The last component: "/usr/lib/" -> "lib", "/" -> "/". }
function BaseName(const Path: string): string; overload;
function BaseName(Path: PChar): PChar; overload;
{ Everything before the last component: "/usr/lib" -> "/usr",
  "file" -> ".", "/" -> "/". }
function DirectoryName(const Path: string): string; overload;
function DirectoryName(Path: PChar): PChar; overload;
{ Directory + '/' + Name, without doubling the slash. }
function JoinPath(const Directory, Name: string): string; overload;
function JoinPath(Directory, Name: PChar): PChar; overload;
{ True for "." and "..". }
function IsDotEntry(const Name: string): Boolean; overload;
function IsDotEntry(Name: PChar): Boolean; overload;

type
  TCanonicalMode = (
    { Every component but the last must exist (readlink -f). }
    CanonicalAllButLast,
    { Every component must exist (readlink -e, realpath -e). }
    CanonicalExisting,
    { Nothing needs to exist (readlink -m). }
    CanonicalMissingAllowed);

{ The absolute path with "." and ".." resolved and, if FollowLinks, every
  symbolic link replaced by its target. Returns 0, or an error code (and
  an empty Canonical). }
function CanonicalizePath(const Path: string; Mode: TCanonicalMode; FollowLinks: Boolean;
  out Canonical: string): LongInt; overload;
{ The same with a new heap string (nil on an error). }
function CanonicalizePath(Path: PChar; Mode: TCanonicalMode; FollowLinks: Boolean;
  out Canonical: PChar): LongInt; overload;

{ The current directory; 0 or an error code. }
function CurrentDirectoryPath(out Path: string): LongInt;
{ What the symbolic link Path points to; 0 or an error code. }
function ReadLinkTarget(const Path: string; out Target: string): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Memory;

function BaseName(const Path: string): string;
var
  Finish: Integer;
  Start: Integer;
begin
  Finish := Length(Path);
  if Finish = 0 then
    Exit('');
  while (Finish > 1) and (Path[Finish] = '/') do
    Dec(Finish);
  if (Finish = 1) and (Path[1] = '/') then
    Exit('/');
  Start := Finish;
  while (Start > 0) and (Path[Start] <> '/') do
    Dec(Start);
  Result := Copy(Path, Start + 1, Finish - Start);
end;

function DirectoryName(const Path: string): string;
var
  Finish: Integer;
begin
  Finish := Length(Path);
  { Drop trailing slashes, then the last component, then the slashes
    separating it. }
  while (Finish > 1) and (Path[Finish] = '/') do
    Dec(Finish);
  while (Finish > 0) and (Path[Finish] <> '/') do
    Dec(Finish);
  if Finish = 0 then
    Exit('.');
  while (Finish > 1) and (Path[Finish] = '/') do
    Dec(Finish);
  Result := Copy(Path, 1, Finish);
end;

function JoinPath(const Directory, Name: string): string;
begin
  if (Directory <> '') and (Directory[Length(Directory)] <> '/') then
    Result := Directory + '/' + Name
  else
    Result := Directory + Name;
end;

function IsDotEntry(const Name: string): Boolean;
begin
  Result := (Name = '.') or (Name = '..');
end;

function BaseName(Path: PChar): PChar;
begin
  Result := DuplicateText(PChar(BaseName(string(Path))));
end;

function DirectoryName(Path: PChar): PChar;
begin
  Result := DuplicateText(PChar(DirectoryName(string(Path))));
end;

function JoinPath(Directory, Name: PChar): PChar;
begin
  Result := DuplicateText(PChar(JoinPath(string(Directory), string(Name))));
end;

function IsDotEntry(Name: PChar): Boolean;
begin
  Result := IsDotEntry(string(Name));
end;

function CurrentDirectoryPath(out Path: string): LongInt;
var
  Buffer: array[0..PathCapacity - 1] of Char;
begin
  Path := '';
  Result := GetCurrentDirectory(@Buffer[0], PathCapacity);
  if Result = ErrorNone then
    Path := PChar(@Buffer[0]);
end;

function ReadLinkTarget(const Path: string; out Target: string): LongInt;
var
  Buffer: array[0..PathCapacity - 1] of Char;
begin
  Target := '';
  Result := ReadSymbolicLink(PChar(Path), @Buffer[0], PathCapacity);
  if Result = ErrorNone then
    Target := PChar(@Buffer[0]);
end;

{ --- Canonical names ------------------------------------------------- }

const
  MaximumLinkDepth = 40;

type
  TCanonicalizer = record
    Mode: TCanonicalMode;
    FollowLinks: Boolean;
    Path: string;
  end;

function AddComponents(var State: TCanonicalizer; const Text: string; Depth: Integer;
  IsLastPart: Boolean): LongInt; forward;

{ Appends one component to the absolute path being built. }
function AddComponent(var State: TCanonicalizer; const Name: string; Depth: Integer;
  IsLast: Boolean): LongInt;
var
  LastSlash: Integer;
  SavedPath: string;
  Information: TFileInformation;
  Target: string;
begin
  Result := ErrorNone;
  if Name = '.' then
    Exit;
  if Name = '..' then
  begin
    LastSlash := LastDelimiter('/', State.Path);
    if LastSlash > 0 then
      SetLength(State.Path, LastSlash - 1);
    Exit;
  end;
  SavedPath := State.Path;
  State.Path := State.Path + '/' + Name;

  if GetLinkInformation(PChar(State.Path), Information) <> ErrorNone then
  begin
    if (State.Mode = CanonicalMissingAllowed) or ((State.Mode = CanonicalAllButLast) and IsLast) then
      Exit(ErrorNone);
    Exit(ErrorNotFound);
  end;
  if (Information.Kind <> KindSymbolicLink) or not State.FollowLinks then
  begin
    if not IsLast and (Information.Kind <> KindDirectory) and (Information.Kind <> KindSymbolicLink) then
      Exit(ErrorNotDirectory);
    Exit(ErrorNone);
  end;
  if Depth >= MaximumLinkDepth then
    Exit(ErrorTooManyLinks);
  Result := ReadLinkTarget(State.Path, Target);
  if Result <> ErrorNone then
    Exit;
  { The link is replaced by its target, relative to the link's directory. }
  State.Path := SavedPath;
  if (Target <> '') and (Target[1] = '/') then
    State.Path := '';
  Result := AddComponents(State, Target, Depth + 1, IsLast);
end;

function AddComponents(var State: TCanonicalizer; const Text: string; Depth: Integer;
  IsLastPart: Boolean): LongInt;
var
  Start: Integer;
  Position: Integer;
  TextLength: Integer;
  Name: string;
  IsLast: Boolean;
begin
  Result := ErrorNone;
  TextLength := Length(Text);
  Position := 1;
  while True do
  begin
    while (Position <= TextLength) and (Text[Position] = '/') do
      Inc(Position);
    if Position > TextLength then
      Break;
    Start := Position;
    while (Position <= TextLength) and (Text[Position] <> '/') do
      Inc(Position);
    Name := Copy(Text, Start, Position - Start);
    if Position <= TextLength then
      Inc(Position);
    { The last component of the whole name (trailing slashes included),
      not of a link target inside it. }
    IsLast := IsLastPart and (Position > TextLength);
    Result := AddComponent(State, Name, Depth, IsLast);
    if Result <> ErrorNone then
      Break;
  end;
end;

function CanonicalizePath(const Path: string; Mode: TCanonicalMode; FollowLinks: Boolean;
  out Canonical: string): LongInt;
var
  State: TCanonicalizer;
  Directory: string;
begin
  Canonical := '';
  State.Mode := Mode;
  State.FollowLinks := FollowLinks;
  State.Path := '';
  if (Path = '') or (Path[1] <> '/') then
  begin
    Result := CurrentDirectoryPath(Directory);
    if Result <> ErrorNone then
      Exit;
    if Directory <> '/' then
      State.Path := Directory;
  end;
  Result := AddComponents(State, Path, 0, True);
  if Result <> ErrorNone then
    Exit;
  if State.Path = '' then
    State.Path := '/';
  Canonical := State.Path;
end;

function CanonicalizePath(Path: PChar; Mode: TCanonicalMode; FollowLinks: Boolean;
  out Canonical: PChar): LongInt;
var
  CanonicalText: string;
begin
  Canonical := nil;
  Result := CanonicalizePath(string(Path), Mode, FollowLinks, CanonicalText);
  if Result = ErrorNone then
    Canonical := DuplicateText(PChar(CanonicalText));
end;

end.
