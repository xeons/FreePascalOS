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
  Copying and removing files and whole directory trees.

  Used by cp, and by mv when it has to move between volumes (a rename
  cannot cross volumes, so mv copies and then removes). Errors are
  reported as they happen; the functions return False if anything
  failed but carry on with the rest of the tree.
}
unit Util.FileTree;

{$mode objfpc}
{$pointermath on}

interface

type
  TCopyOptions = record
    Recursive: Boolean;
    { Copy symbolic links as links instead of what they point to. }
    KeepLinks: Boolean;
    { Do not replace existing targets. }
    NoClobber: Boolean;
    Verbose: Boolean;
    { Give copies the source's mode, owner, group and times. }
    PreserveAttributes: Boolean;
  end;

{ Copies Source to Target (a file, link or, with Recursive, a tree). }
function CopyPath(Source, Target: PChar; const Options: TCopyOptions): Boolean;
{ Removes Path and everything below it. }
function RemoveTree(Path: PChar): Boolean;

type
  { Called for every path of a walk; returns False if it failed (the
    walk continues, but reports failure). }
  TVisitPath = function(Path: PChar; IsDirectory: Boolean; Context: Pointer): Boolean;

{ Visits Path and, when it is a directory, everything below it (a
  directory before its contents). Symbolic links are visited but not
  followed. Returns False if any visit failed. }
function WalkTree(Path: PChar; Visit: TVisitPath; Context: Pointer): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.FileCopies,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Paths;

function CopyFileContents(Source, Target: PChar): Boolean;
var
  Failure: TCopyFailure;
begin
  Failure := CopyFileData(Source, Target, CopyReplace, nil, nil);
  Result := Failure.Error = ErrorNone;
  if Result then
    Exit;
  if not Failure.AtTarget then
    ReportError(Failure.Error, 'error reading ''%s''', [ArgumentText(Source)])
  else
    ReportError(Failure.Error, 'error writing ''%s''', [ArgumentText(Target)]);
end;

function CopyLink(Source, Target: PChar): Boolean;
var
  Failure: TCopyFailure;
begin
  Failure := CopySymbolicLink(Source, Target, CopyReplace);
  if Failure.Error <> ErrorNone then
    ReportError(Failure.Error, 'cannot create symbolic link ''%s''', [ArgumentText(Target)]);
  Result := Failure.Error = ErrorNone;
end;

function CopyDirectory(Source, Target: PChar; const Options: TCopyOptions): Boolean;
var
  Names: TLineList;
  Index: Integer;
  ChildSource: PChar;
  ChildTarget: PChar;
  Error: LongInt;
begin
  if not IsDirectory(Target) then
  begin
    Error := CreateDirectory(Target);
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'cannot create directory ''%s''', [ArgumentText(Target)]);
      Exit(False);
    end;
  end;
  BeginLineList(Names);
  Error := ListDirectory(Source, Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot access ''%s''', [ArgumentText(Source)]);
    FreeLineList(Names);
    Exit(False);
  end;
  Result := True;
  for Index := 0 to Names.Count - 1 do
  begin
    ChildSource := JoinPath(Source, Names.Items[Index]);
    ChildTarget := JoinPath(Target, Names.Items[Index]);
    if not CopyPath(ChildSource, ChildTarget, Options) then
      Result := False;
    FreeMemory(ChildSource);
    FreeMemory(ChildTarget);
  end;
  FreeLineList(Names);
end;

function CopyPath(Source, Target: PChar; const Options: TCopyOptions): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  if Options.KeepLinks then
    Error := GetLinkInformation(Source, Information)
  else
    Error := GetFileInformation(Source, Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot stat ''%s''', [ArgumentText(Source)]);
    Exit(False);
  end;
  if Options.NoClobber and PathExists(Target) and (Information.Kind <> KindDirectory) then
    Exit(True);
  if Options.Verbose then
    WriteFormatted(StandardOutput, '''%s'' -> ''%s'''#10, [ArgumentText(Source), ArgumentText(Target)]);

  case Information.Kind of
    KindDirectory:
      begin
        if not Options.Recursive then
        begin
          Report('-r not specified; omitting directory ''%s''', [ArgumentText(Source)]);
          Exit(False);
        end;
        Result := CopyDirectory(Source, Target, Options);
      end;
    KindSymbolicLink:
      Result := CopyLink(Source, Target);
  else
    begin
      { (A new copy gets the source's permissions, less the umask.) }
      Result := CopyFileContents(Source, Target);
    end;
  end;
  if Result and Options.PreserveAttributes then
    CopyAttributes(Target, Information);
end;

function WalkTree(Path: PChar; Visit: TVisitPath; Context: Pointer): Boolean;
var
  Information: TFileInformation;
  Names: TLineList;
  Index: Integer;
  ChildPath: PChar;
  Error: LongInt;
  IsDirectoryPath: Boolean;
begin
  Error := GetLinkInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot access ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;
  IsDirectoryPath := Information.Kind = KindDirectory;
  Result := Visit(Path, IsDirectoryPath, Context);
  if not IsDirectoryPath then
    Exit;
  BeginLineList(Names);
  Error := ListDirectory(Path, Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot read directory ''%s''', [ArgumentText(Path)]);
    FreeLineList(Names);
    Exit(False);
  end;
  for Index := 0 to Names.Count - 1 do
  begin
    ChildPath := JoinPath(Path, Names.Items[Index]);
    if not WalkTree(ChildPath, Visit, Context) then
      Result := False;
    FreeMemory(ChildPath);
  end;
  FreeLineList(Names);
end;

function RemoveTree(Path: PChar): Boolean;
var
  Information: TFileInformation;
  Names: TLineList;
  Index: Integer;
  ChildPath: PChar;
  Error: LongInt;
begin
  Result := True;
  Error := GetLinkInformation(Path, Information);
  if (Error = ErrorNone) and (Information.Kind = KindDirectory) then
  begin
    BeginLineList(Names);
    ListDirectory(Path, Names);
    for Index := 0 to Names.Count - 1 do
    begin
      ChildPath := JoinPath(Path, Names.Items[Index]);
      if not RemoveTree(ChildPath) then
        Result := False;
      FreeMemory(ChildPath);
    end;
    FreeLineList(Names);
  end;
  if Error = ErrorNone then
    Error := RemovePath(Path);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(Path)]);
    Result := False;
  end;
end;

end.
