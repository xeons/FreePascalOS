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

{$mode objfpc}{$H+}

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
function CopyPath(const Source, Target: string; const Options: TCopyOptions): Boolean;
{ Removes Path and everything below it. }
function RemoveTree(const Path: string): Boolean;

type
  { Called for every path of a walk; returns False if it failed (the
    walk continues, but reports failure). }
  TVisitPathMethod = function(const Path: string; IsDirectory: Boolean): Boolean of object;

{ Visits Path and, when it is a directory, everything below it (a
  directory before its contents). Symbolic links are visited but not
  followed. Returns False if any visit failed. }
function WalkTree(const Path: string; Visit: TVisitPathMethod): Boolean;

implementation

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Files,
  Sys.FileCopies,
  Util.Directories,
  Util.Messages,
  Sys.Streams,
  Util.Paths;

function CopyFileContents(const Source, Target: string): Boolean;
var
  Failure: TCopyFailure;
begin
  Failure := CopyFileData(PChar(Source), PChar(Target), CopyReplace, nil, nil);
  Result := Failure.Error = ErrorNone;
  if Result then
    Exit;
  if not Failure.AtTarget then
    ReportError(Failure.Error, Format('error reading ''%s''', [Source]))
  else
    ReportError(Failure.Error, Format('error writing ''%s''', [Target]));
end;

function CopyLink(const Source, Target: string): Boolean;
var
  Failure: TCopyFailure;
begin
  Failure := CopySymbolicLink(PChar(Source), PChar(Target), CopyReplace);
  if Failure.Error <> ErrorNone then
    ReportError(Failure.Error, Format('cannot create symbolic link ''%s''', [Target]));
  Result := Failure.Error = ErrorNone;
end;

function CopyDirectory(const Source, Target: string; const Options: TCopyOptions): Boolean;
var
  Names: TStringList;
  Name: string;
  Error: LongInt;
begin
  if not IsDirectory(PChar(Target)) then
  begin
    Error := CreateDirectory(PChar(Target));
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot create directory ''%s''', [Target]));
      Exit(False);
    end;
  end;
  Names := TStringList.Create;
  try
    Error := ListDirectory(Source, Names);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot access ''%s''', [Source]));
      Exit(False);
    end;
    Result := True;
    for Name in Names do
      if not CopyPath(JoinPath(Source, Name), JoinPath(Target, Name), Options) then
        Result := False;
  finally
    Names.Free;
  end;
end;

function CopyPath(const Source, Target: string; const Options: TCopyOptions): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  if Options.KeepLinks then
    Error := GetLinkInformation(PChar(Source), Information)
  else
    Error := GetFileInformation(PChar(Source), Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot stat ''%s''', [Source]));
    Exit(False);
  end;
  if Options.NoClobber and PathExists(PChar(Target)) and (Information.Kind <> KindDirectory) then
    Exit(True);
  if Options.Verbose then
    PrintString(Format('''%s'' -> ''%s'''#10, [Source, Target]));

  case Information.Kind of
    KindDirectory:
      begin
        if not Options.Recursive then
        begin
          Report(Format('-r not specified; omitting directory ''%s''', [Source]));
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
    CopyAttributes(PChar(Target), Information);
end;

function WalkTree(const Path: string; Visit: TVisitPathMethod): Boolean;
var
  Information: TFileInformation;
  Names: TStringList;
  Name: string;
  Error: LongInt;
  IsDirectoryPath: Boolean;
begin
  Error := GetLinkInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot access ''%s''', [Path]));
    Exit(False);
  end;
  IsDirectoryPath := Information.Kind = KindDirectory;
  Result := Visit(Path, IsDirectoryPath);
  if not IsDirectoryPath then
    Exit;
  Names := TStringList.Create;
  try
    Error := ListDirectory(Path, Names);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot read directory ''%s''', [Path]));
      Exit(False);
    end;
    for Name in Names do
      if not WalkTree(JoinPath(Path, Name), Visit) then
        Result := False;
  finally
    Names.Free;
  end;
end;

function RemoveTree(const Path: string): Boolean;
var
  Information: TFileInformation;
  Names: TStringList;
  Name: string;
  Error: LongInt;
begin
  Result := True;
  Error := GetLinkInformation(PChar(Path), Information);
  if (Error = ErrorNone) and (Information.Kind = KindDirectory) then
  begin
    Names := TStringList.Create;
    try
      ListDirectory(Path, Names);
      for Name in Names do
        if not RemoveTree(JoinPath(Path, Name)) then
          Result := False;
    finally
      Names.Free;
    end;
  end;
  if Error = ErrorNone then
    Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot remove ''%s''', [Path]));
    Result := False;
  end;
end;

end.
