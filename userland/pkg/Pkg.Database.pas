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
  The installed packages, a folder each under ROOT/var/db/pkg:

    NAME/+MANIFEST     the package's manifest as it came in the package
    NAME/+DESC         its description
    NAME/+pre-remove   its removal scripts, if it has them
    NAME/+post-remove
    NAME/+INSTALLED    "installed UNIXTIME" and "automatic yes|no"
                       (installed only because something needed it)

  The ports tool writes the same folders for the packages the system
  disk carries (scripts/portstool/database.py). An entry is written
  into NAME.new and renamed into place, so it is either all there or
  not at all.
}
unit Pkg.Database;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Pkg.Manifests;

type
  EDatabaseError = class(Exception);

  TInstalledPackage = class
  public
    Manifest: TPackageManifest;
    Description: string;
    Automatic: Boolean;
    InstalledTime: Int64;
    destructor Destroy; override;
  end;

  TPackageDatabase = class
  private
    FRoot: string;
    FPackages: TStringList;
    function GetCount: Integer;
    function GetPackage(Index: Integer): TInstalledPackage;
    function LoadEntry(const Name: string): TInstalledPackage;
  public
    constructor Create(const Root: string);
    destructor Destroy; override;
    { Reads every entry again. Raises EDatabaseError on a damaged one. }
    procedure Load;
    function Folder: string;
    function EntryFolder(const Name: string): string;
    function Find(const Name: string): TInstalledPackage;
    { The package called Name, else one that provides it. }
    function FindProvider(const Name: string): TInstalledPackage;
    { The package a path (relative to the root) belongs to, or nil. }
    function Owner(const Path: string): TInstalledPackage;
    { The names of installed packages that depend on Name (or on a name
      it provides). }
    function Dependents(const Name: string): TStringArray;
    { Writes NAME's entry: the manifest text, description, removal
      scripts and whether it is automatic. Reloads the database, so
      TInstalledPackage objects found before are gone. }
    procedure Store(Manifest: TPackageManifest; const Description: string; const Scripts: TPackageScripts;
      Automatic: Boolean);
    procedure Forget(const Name: string);
    property Root: string read FRoot;
    property Count: Integer read GetCount;
    property Packages[Index: Integer]: TInstalledPackage read GetPackage; default;
  end;

function ReadTextFile(const Path: string): string;
procedure WriteTextFile(const Path, Text: string);

implementation

uses
  DateUtils,
  Pkg.FileSystem,
  Pkg.Paths,
  Pkg.Versions;

function ReadTextFile(const Path: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure WriteTextFile(const Path, Text: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Length(Text) > 0 then
      Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
end;

destructor TInstalledPackage.Destroy;
begin
  Manifest.Free;
  inherited Destroy;
end;

constructor TPackageDatabase.Create(const Root: string);
begin
  inherited Create;
  FRoot := Root;
  FPackages := TStringList.Create;
  FPackages.Sorted := True;
  FPackages.OwnsObjects := True;
end;

destructor TPackageDatabase.Destroy;
begin
  FPackages.Free;
  inherited Destroy;
end;

function TPackageDatabase.Folder: string;
begin
  Result := RootedPath(FRoot, DatabaseFolder);
end;

function TPackageDatabase.EntryFolder(const Name: string): string;
begin
  Result := Folder + '/' + Name;
end;

function TPackageDatabase.GetCount: Integer;
begin
  Result := FPackages.Count;
end;

function TPackageDatabase.GetPackage(Index: Integer): TInstalledPackage;
begin
  Result := TInstalledPackage(FPackages.Objects[Index]);
end;

function TPackageDatabase.LoadEntry(const Name: string): TInstalledPackage;
var
  Directory, InstalledText, Line: string;
  Lines: TStringArray;
  Index: Integer;
begin
  Directory := EntryFolder(Name);
  Result := TInstalledPackage.Create;
  try
    try
      Result.Manifest := TPackageManifest.Create(ReadTextFile(Directory + '/+MANIFEST'));
    except
      on Error: Exception do
        raise EDatabaseError.CreateFmt('%s: %s', [Directory, Error.Message]);
    end;
    if Result.Manifest.Name <> Name then
      raise EDatabaseError.CreateFmt('%s holds the manifest of %s', [Directory, Result.Manifest.Name]);
    if FileExists(Directory + '/+DESC') then
      Result.Description := ReadTextFile(Directory + '/+DESC');
    if FileExists(Directory + '/+INSTALLED') then
    begin
      InstalledText := ReadTextFile(Directory + '/+INSTALLED');
      Lines := InstalledText.Split([#10]);
      for Index := 0 to High(Lines) do
      begin
        Line := Lines[Index];
        if Copy(Line, 1, 10) = 'installed ' then
          Result.InstalledTime := StrToInt64Def(Copy(Line, 11, MaxInt), 0)
        else if Line = 'automatic yes' then
          Result.Automatic := True;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TPackageDatabase.Load;
var
  Search: TSearchRec;
begin
  FPackages.Clear;
  if FindFirst(Folder + '/*', faDirectory, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Name = '') or (Search.Name[1] = '.') or ((Search.Attr and faDirectory) = 0) then
        Continue;
      if not FileExists(EntryFolder(Search.Name) + '/+MANIFEST') then
        Continue;
      FPackages.AddObject(Search.Name, LoadEntry(Search.Name));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TPackageDatabase.Find(const Name: string): TInstalledPackage;
var
  Index: Integer;
begin
  if FPackages.Find(Name, Index) then
    Result := GetPackage(Index)
  else
    Result := nil;
end;

function TPackageDatabase.FindProvider(const Name: string): TInstalledPackage;
var
  Index: Integer;
begin
  Result := Find(Name);
  if Result <> nil then
    Exit;
  for Index := 0 to FPackages.Count - 1 do
    if GetPackage(Index).Manifest.ProvidesName(Name) then
      Exit(GetPackage(Index));
end;

function TPackageDatabase.Owner(const Path: string): TInstalledPackage;
var
  Index: Integer;
begin
  for Index := 0 to FPackages.Count - 1 do
    if GetPackage(Index).Manifest.FindPath(Path) >= 0 then
      Exit(GetPackage(Index));
  Result := nil;
end;

function TPackageDatabase.Dependents(const Name: string): TStringArray;
var
  Index, DependencyIndex: Integer;
  Target, Other: TInstalledPackage;
  Dependency: TDependency;
begin
  Result := nil;
  Target := Find(Name);
  for Index := 0 to FPackages.Count - 1 do
  begin
    Other := GetPackage(Index);
    if Other = Target then
      Continue;
    for DependencyIndex := 0 to High(Other.Manifest.Depends) do
    begin
      if not ParseDependency(Other.Manifest.Depends[DependencyIndex], Dependency) then
        Continue;
      if (Dependency.Name = Name) or ((Target <> nil) and Target.Manifest.ProvidesName(Dependency.Name)) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Other.Manifest.Name;
        Break;
      end;
    end;
  end;
end;

procedure TPackageDatabase.Store(Manifest: TPackageManifest; const Description: string;
  const Scripts: TPackageScripts; Automatic: Boolean);
var
  Entry, Temporary, Previous: string;
  Index: Integer;
  Made: TStringArray;
  AutomaticText: string;
begin
  Made := nil;
  if not MakeFolders(Folder, Made) then
    raise EDatabaseError.CreateFmt('cannot make %s', [Folder]);
  Entry := EntryFolder(Manifest.Name);
  Temporary := Folder + '/.' + Manifest.Name + '.new';
  Previous := Folder + '/.' + Manifest.Name + '.old';
  RemoveTree(Temporary);
  RemoveTree(Previous);
  if not CreateDir(Temporary) then
    raise EDatabaseError.CreateFmt('cannot make %s', [Temporary]);
  WriteTextFile(Temporary + '/+MANIFEST', Manifest.Text);
  WriteTextFile(Temporary + '/+DESC', Description);
  for Index := 0 to High(Scripts) do
    if (Scripts[Index].Kind = 'pre-remove') or (Scripts[Index].Kind = 'post-remove') then
      WriteTextFile(Temporary + '/+' + Scripts[Index].Kind, Scripts[Index].Text);
  if Automatic then
    AutomaticText := 'yes'
  else
    AutomaticText := 'no';
  WriteTextFile(Temporary + '/+INSTALLED', Format('installed %d'#10'automatic %s'#10,
    [DateTimeToUnix(Now, False), AutomaticText]));
  if IsFolder(Entry) and not RenamePathOver(Entry, Previous) then
    raise EDatabaseError.CreateFmt('cannot replace %s', [Entry]);
  if not RenamePathOver(Temporary, Entry) then
  begin
    if IsFolder(Previous) then
      RenamePathOver(Previous, Entry);
    raise EDatabaseError.CreateFmt('cannot write %s', [Entry]);
  end;
  RemoveTree(Previous);
  Load;
end;

procedure TPackageDatabase.Forget(const Name: string);
var
  Entry, Doomed: string;
begin
  Entry := EntryFolder(Name);
  Doomed := Folder + '/.' + Name + '.removed';
  RemoveTree(Doomed);
  if IsFolder(Entry) then
  begin
    if not RenamePathOver(Entry, Doomed) then
      raise EDatabaseError.CreateFmt('cannot remove %s', [Entry]);
    RemoveTree(Doomed);
  end;
  Load;
end;

end.
