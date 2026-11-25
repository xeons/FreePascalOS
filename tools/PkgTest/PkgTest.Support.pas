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
  What pkg's host test gives a package context in place of the system:
  messages kept in a list (and printed, indented, among the checks), scripts recorded instead of run (a
  pre-install script of the package "failing" fails, as do the scripts
  named in FailingKinds), URLs copied from the fixture folders
  (file:// only).
}
unit PkgTest.Support;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Pkg.Context,
  Pkg.Manifests;

type
  TTestServices = class
  public
    Messages: TStringList;
    Scripts: TStringList;
    FailingKinds: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Message(const Text: string);
    function RunScript(const Kind, Text: string; Manifest: TPackageManifest; const Root: string): Integer;
    function FetchUrl(const Url, TargetPath: string; out Problem: string): Boolean;
    function Said(const Fragment: string): Boolean;
    procedure Clear;
  end;

var
  FixtureFolder: string;
  WorkFolder: string;

function NewContext(const Root: string; Services: TTestServices): TPackageContext;
function PackageFile(const Name: string): string;
function Exists(const Root, Relative: string): Boolean;
function TextOf(const Path: string): string;
procedure WriteText(const Path, Text: string);
{ Every file and link under Root, relative, sorted (folders left out). }
function FilesUnder(const Root: string): TStringArray;
function Joined(const Items: TStringArray): string;

implementation

uses
  Pkg.Database,
  Pkg.FileSystem;

constructor TTestServices.Create;
begin
  inherited Create;
  Messages := TStringList.Create;
  Scripts := TStringList.Create;
  FailingKinds := TStringList.Create;
end;

destructor TTestServices.Destroy;
begin
  Messages.Free;
  Scripts.Free;
  FailingKinds.Free;
  inherited Destroy;
end;

procedure TTestServices.Message(const Text: string);
begin
  Messages.Add(Text);
  WriteLn('     > ', Text);
end;

function TTestServices.RunScript(const Kind, Text: string; Manifest: TPackageManifest; const Root: string): Integer;
begin
  Scripts.Add(Manifest.Name + ' ' + Kind);
  if ((Manifest.Name = 'failing') and (Kind = 'pre-install')) or (FailingKinds.IndexOf(Kind) >= 0) then
    Result := 1
  else
    Result := 0;
end;

function TTestServices.FetchUrl(const Url, TargetPath: string; out Problem: string): Boolean;
var
  Source: string;
begin
  Problem := '';
  if Copy(Url, 1, 7) <> 'file://' then
  begin
    Problem := 'only file:// here';
    Exit(False);
  end;
  Source := Copy(Url, 8, MaxInt);
  if not FileExists(Source) then
  begin
    Problem := 'no ' + Source;
    Exit(False);
  end;
  WriteText(TargetPath, TextOf(Source));
  Result := True;
end;

function TTestServices.Said(const Fragment: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Messages.Count - 1 do
    if Pos(Fragment, Messages[Index]) > 0 then
      Exit(True);
  Result := False;
end;

procedure TTestServices.Clear;
begin
  Messages.Clear;
  Scripts.Clear;
end;

function NewContext(const Root: string; Services: TTestServices): TPackageContext;
begin
  Result := TPackageContext.Create(Root);
  Result.Architecture := 'x86_64';
  Result.OnMessage := @Services.Message;
  Result.OnWarning := @Services.Message;
  Result.RunScript := @Services.RunScript;
  Result.FetchUrl := @Services.FetchUrl;
end;

function PackageFile(const Name: string): string;
begin
  Result := FixtureFolder + '/packages/' + Name;
end;

function Exists(const Root, Relative: string): Boolean;
begin
  Result := FileExists(Root + '/' + Relative) or IsSymbolicLink(Root + '/' + Relative) or
    DirectoryExists(Root + '/' + Relative);
end;

function TextOf(const Path: string): string;
begin
  Result := ReadTextFile(Path);
end;

procedure WriteText(const Path, Text: string);
begin
  WriteTextFile(Path, Text);
end;

{ Symbolic links too: the host's FindFirst leaves them out unless asked. }
{$push}
{$warn SYMBOL_PLATFORM off}
const
  SearchEverything = faAnyFile or faSymLink;
{$pop}

procedure CollectFiles(const Root, Relative: string; List: TStringList);
var
  Search: TSearchRec;
  Path, Child: string;
begin
  Path := Root;
  if Relative <> '' then
    Path := Root + '/' + Relative;
  if FindFirst(Path + '/*', SearchEverything, Search) <> 0 then
    Exit;
  repeat
    if (Search.Name = '.') or (Search.Name = '..') then
      Continue;
    if Relative = '' then
      Child := Search.Name
    else
      Child := Relative + '/' + Search.Name;
    if IsFolder(Root + '/' + Child) then
      CollectFiles(Root, Child, List)
    else
      List.Add(Child);
  until FindNext(Search) <> 0;
  FindClose(Search);
end;

function FilesUnder(const Root: string): TStringArray;
var
  List: TStringList;
  Index: Integer;
begin
  List := TStringList.Create;
  try
    List.Sorted := True;
    CollectFiles(Root, '', List);
    Result := nil;
    SetLength(Result, List.Count);
    for Index := 0 to List.Count - 1 do
      Result[Index] := List[Index];
  finally
    List.Free;
  end;
end;

function Joined(const Items: TStringArray): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Items) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + Items[Index];
  end;
end;

end.
