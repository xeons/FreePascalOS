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
  Results are new heap strings.
}
unit Util.Paths;

{$mode objfpc}
{$pointermath on}

interface

{ The last component: "/usr/lib/" -> "lib", "/" -> "/". }
function BaseName(Path: PChar): PChar;
{ Everything before the last component: "/usr/lib" -> "/usr",
  "file" -> ".", "/" -> "/". }
function DirectoryName(Path: PChar): PChar;
{ Directory + '/' + Name, without doubling the slash. }
function JoinPath(Directory, Name: PChar): PChar;
{ True for "." and "..". }
function IsDotEntry(Name: PChar): Boolean;

type
  TCanonicalMode = (
    { Every component but the last must exist (readlink -f). }
    CanonicalAllButLast,
    { Every component must exist (readlink -e, realpath -e). }
    CanonicalExisting,
    { Nothing needs to exist (readlink -m). }
    CanonicalMissingAllowed);

{ The absolute path with "." and ".." resolved and, if FollowLinks, every
  symbolic link replaced by its target. Returns 0 and a new heap string,
  or an error code. }
function CanonicalizePath(Path: PChar; Mode: TCanonicalMode; FollowLinks: Boolean;
  out Canonical: PChar): LongInt;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Text;

function CopyRange(Text: PChar; Start, Finish: PtrInt): PChar;
var
  Length: PtrInt;
begin
  Length := Finish - Start;
  if Length < 0 then
    Length := 0;
  Result := PChar(AllocateMemory(Length + 1));
  CopyMemory(Result, Text + Start, Length);
  Result[Length] := #0;
end;

function BaseName(Path: PChar): PChar;
var
  Finish: PtrInt;
  Start: PtrInt;
begin
  Finish := PtrInt(TextLength(Path));
  if Finish = 0 then
    Exit(DuplicateText(''));
  while (Finish > 1) and (Path[Finish - 1] = '/') do
    Dec(Finish);
  if (Finish = 1) and (Path[0] = '/') then
    Exit(DuplicateText('/'));
  Start := Finish;
  while (Start > 0) and (Path[Start - 1] <> '/') do
    Dec(Start);
  Result := CopyRange(Path, Start, Finish);
end;

function DirectoryName(Path: PChar): PChar;
var
  Finish: PtrInt;
begin
  Finish := PtrInt(TextLength(Path));
  { Drop trailing slashes, then the last component, then the slashes
    separating it. }
  while (Finish > 1) and (Path[Finish - 1] = '/') do
    Dec(Finish);
  while (Finish > 0) and (Path[Finish - 1] <> '/') do
    Dec(Finish);
  if Finish = 0 then
    Exit(DuplicateText('.'));
  while (Finish > 1) and (Path[Finish - 1] = '/') do
    Dec(Finish);
  Result := CopyRange(Path, 0, Finish);
end;

function JoinPath(Directory, Name: PChar): PChar;
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  AppendText(Builder, Directory);
  if (Builder.Length > 0) and (Builder.Text[Builder.Length - 1] <> '/') then
    AppendCharacter(Builder, '/');
  AppendText(Builder, Name);
  Result := FinishText(Builder);
end;

function IsDotEntry(Name: PChar): Boolean;
begin
  Result := TextIsEqual(Name, '.') or TextIsEqual(Name, '..');
end;

{ --- Canonical names ------------------------------------------------- }

const
  MaximumLinkDepth = 40;

type
  TCanonicalizer = record
    Mode: TCanonicalMode;
    FollowLinks: Boolean;
    Path: TTextBuilder;
  end;

function AddComponents(var State: TCanonicalizer; Text: PChar; Depth: Integer; IsLastPart: Boolean): LongInt; forward;

{ Appends one component to the absolute path being built. }
function AddComponent(var State: TCanonicalizer; Name: PChar; Depth: Integer; IsLast: Boolean): LongInt;
var
  LastSlash: PtrInt;
  SavedLength: PtrUInt;
  Information: TFileInformation;
  Target: array[0..PathCapacity - 1] of Char;
begin
  Result := ErrorNone;
  if TextIsEqual(Name, '.') then
    Exit;
  if TextIsEqual(Name, '..') then
  begin
    LastSlash := FindLastCharacter(State.Path.Text, '/');
    if LastSlash >= 0 then
    begin
      State.Path.Length := PtrUInt(LastSlash);
      State.Path.Text[State.Path.Length] := #0;
    end;
    Exit;
  end;
  SavedLength := State.Path.Length;
  AppendCharacter(State.Path, '/');
  AppendText(State.Path, Name);

  if GetLinkInformation(State.Path.Text, Information) <> ErrorNone then
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
  Result := ReadSymbolicLink(State.Path.Text, @Target[0], PathCapacity);
  if Result <> ErrorNone then
    Exit;
  { The link is replaced by its target, relative to the link's directory. }
  State.Path.Length := SavedLength;
  State.Path.Text[State.Path.Length] := #0;
  if Target[0] = '/' then
  begin
    State.Path.Length := 0;
    State.Path.Text[0] := #0;
  end;
  Result := AddComponents(State, @Target[0], Depth + 1, IsLast);
end;

function AddComponents(var State: TCanonicalizer; Text: PChar; Depth: Integer; IsLastPart: Boolean): LongInt;
var
  Copy: PChar;
  Start: PtrUInt;
  Position: PtrUInt;
  IsLast: Boolean;
begin
  Result := ErrorNone;
  Copy := DuplicateText(Text);
  Position := 0;
  while True do
  begin
    while Copy[Position] = '/' do
      Inc(Position);
    if Copy[Position] = #0 then
      Break;
    Start := Position;
    while (Copy[Position] <> '/') and (Copy[Position] <> #0) do
      Inc(Position);
    if Copy[Position] = '/' then
    begin
      Copy[Position] := #0;
      Inc(Position);
    end;
    { The last component of the whole name (trailing slashes included),
      not of a link target inside it. }
    IsLast := IsLastPart and (Copy[Position] = #0);
    Result := AddComponent(State, Copy + Start, Depth, IsLast);
    if Result <> ErrorNone then
      Break;
  end;
  FreeMemory(Copy);
end;

function CanonicalizePath(Path: PChar; Mode: TCanonicalMode; FollowLinks: Boolean;
  out Canonical: PChar): LongInt;
var
  State: TCanonicalizer;
  Directory: array[0..PathCapacity - 1] of Char;
begin
  Canonical := nil;
  State.Mode := Mode;
  State.FollowLinks := FollowLinks;
  BeginText(State.Path);
  if Path[0] <> '/' then
  begin
    Result := GetCurrentDirectory(@Directory[0], PathCapacity);
    if Result <> ErrorNone then
    begin
      DiscardText(State.Path);
      Exit;
    end;
    if not TextIsEqual(@Directory[0], '/') then
      AppendText(State.Path, @Directory[0]);
  end;
  Result := AddComponents(State, Path, 0, True);
  if Result <> ErrorNone then
  begin
    DiscardText(State.Path);
    Exit;
  end;
  if State.Path.Length = 0 then
    AppendCharacter(State.Path, '/');
  Canonical := FinishText(State.Path);
end;

end.
