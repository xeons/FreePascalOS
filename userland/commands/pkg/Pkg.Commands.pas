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
  pkg's commands over a context (Pkg.Context): each says what it does
  through the context and returns the exit status (0 done, 1 something
  failed or was refused). pkg.pas parses the command line and gives the
  system's context; the host test calls these with its own.
}
unit Pkg.Commands;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Pkg.Context;

function InstallCommand(Context: TPackageContext; const Targets: TStringArray; Automatic: Boolean): Integer;
function RemoveCommand(Context: TPackageContext; const Names: TStringArray): Integer;
function InfoCommand(Context: TPackageContext; const Targets: TStringArray; ListFiles: Boolean): Integer;
function ListCommand(Context: TPackageContext; Quiet: Boolean): Integer;
function WhichCommand(Context: TPackageContext; const Paths: TStringArray): Integer;
function VerifyCommand(Context: TPackageContext; const Names: TStringArray): Integer;
function SearchCommand(Context: TPackageContext; const Words: TStringArray): Integer;
function UpdateCommand(Context: TPackageContext): Integer;
function UpgradeCommand(Context: TPackageContext; const Names: TStringArray): Integer;
function TestCommand(Context: TPackageContext; const Names: TStringArray): Integer;

{ Whether a target names a package file rather than a package. }
function IsPackageFileTarget(const Target: string): Boolean;

implementation

uses
  Pkg.Archives,
  Pkg.Database,
  Pkg.Index,
  Pkg.Installer,
  Pkg.Manifests,
  Pkg.Remover,
  Pkg.Repositories,
  Pkg.Verification,
  Pkg.Versions;

const
  PackageFileSuffix = '.pkg.tar.zst';

function IsPackageFileTarget(const Target: string): Boolean;
begin
  Result := (Pos('/', Target) > 0) or FileExists(Target) or
    ((Length(Target) > Length(PackageFileSuffix)) and
    (Copy(Target, Length(Target) - Length(PackageFileSuffix) + 1, MaxInt) = PackageFileSuffix));
end;

procedure Report(Context: TPackageContext; Error: Exception);
begin
  Context.Warn('pkg: ' + Error.Message);
end;

function DependencyName(const Text: string): string;
var
  Dependency: TDependency;
begin
  if ParseDependency(Text, Dependency) then
    Result := Dependency.Name
  else
    Result := Text;
end;

procedure InstallByName(Context: TPackageContext; const Indexes: TRepositoryIndexes; const Name: string;
  Automatic: Boolean; Depth: Integer); forward;

{ Installs the dependencies of a package that are not installed, from
  the repositories (as automatic installs). }
procedure InstallMissingDependencies(Context: TPackageContext; const Indexes: TRepositoryIndexes;
  const Depends: TStringArray; Depth: Integer);
var
  Index: Integer;
begin
  for Index := 0 to High(Depends) do
    if not DependencyInstalled(Context, Depends[Index]) then
    begin
      if Length(Indexes) = 0 then
        Exit;
      InstallByName(Context, Indexes, DependencyName(Depends[Index]), True, Depth + 1);
    end;
end;

procedure InstallFile(Context: TPackageContext; const Indexes: TRepositoryIndexes; const Path: string;
  Automatic: Boolean; Depth: Integer);
var
  Archive: TPackageArchive;
  Installer: TPackageInstaller;
begin
  Archive := TPackageArchive.Create(Path);
  try
    InstallMissingDependencies(Context, Indexes, Archive.Manifest.Depends, Depth);
    Installer := TPackageInstaller.Create(Context, Archive, Automatic);
    try
      Installer.Install;
    finally
      Installer.Free;
    end;
  finally
    Archive.Free;
  end;
end;

procedure InstallByName(Context: TPackageContext; const Indexes: TRepositoryIndexes; const Name: string;
  Automatic: Boolean; Depth: Integer);
var
  Entry: TIndexEntry;
  Installed: TInstalledPackage;
begin
  if Depth > 32 then
    raise EPackageRefused.CreateFmt('the dependencies of %s go round in a circle', [Name]);
  if not FindInIndexes(Indexes, Name, Context.Architecture, Entry) then
    raise EPackageRefused.CreateFmt('no repository has %s (pkg update, pkg search)', [Name]);
  Installed := Context.Database.Find(Entry.Name);
  if (Installed <> nil) and (CompareVersions(Installed.Manifest.FullVersion, IndexEntryFullVersion(Entry)) >= 0) and
    not Context.Force then
  begin
    Context.Say(Format('%s %s is installed already', [Entry.Name, Installed.Manifest.FullVersion]));
    Exit;
  end;
  InstallMissingDependencies(Context, Indexes, Entry.Depends, Depth);
  InstallFile(Context, Indexes, FetchPackage(Context, Entry), Automatic, Depth);
end;

function InstallCommand(Context: TPackageContext; const Targets: TStringArray; Automatic: Boolean): Integer;
var
  Index: Integer;
  Indexes: TRepositoryIndexes;
begin
  Result := 0;
  Indexes := LoadCachedIndexes(Context);
  try
    for Index := 0 to High(Targets) do
      try
        if IsPackageFileTarget(Targets[Index]) then
          InstallFile(Context, Indexes, Targets[Index], Automatic, 0)
        else
          InstallByName(Context, Indexes, Targets[Index], Automatic, 0);
      except
        on Error: Exception do
        begin
          Report(Context, Error);
          Result := 1;
        end;
      end;
  finally
    FreeIndexes(Indexes);
  end;
end;

function RemoveCommand(Context: TPackageContext; const Names: TStringArray): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Names) do
    try
      RemovePackage(Context, Names[Index], Names);
    except
      on Error: Exception do
      begin
        Report(Context, Error);
        Result := 1;
      end;
    end;
end;

procedure SayList(Context: TPackageContext; const Caption: string; const Items: TStringArray);
var
  Index: Integer;
  Text: string;
begin
  if Length(Items) = 0 then
    Exit;
  Text := Items[0];
  for Index := 1 to High(Items) do
    Text := Text + ', ' + Items[Index];
  Context.Say(Format('%-13s%s', [Caption, Text]));
end;

procedure DescribeManifest(Context: TPackageContext; Manifest: TPackageManifest; const Description: string;
  const State: string; ListFiles: Boolean);
var
  Index: Integer;
  Entry: TManifestEntry;
begin
  Context.Say(Format('%-13s%s', ['Name:', Manifest.Name]));
  Context.Say(Format('%-13s%s', ['Version:', Manifest.FullVersion]));
  if Manifest.Origin <> '' then
    Context.Say(Format('%-13s%s', ['Origin:', Manifest.Origin]));
  Context.Say(Format('%-13s%s', ['Summary:', Manifest.Summary]));
  Context.Say(Format('%-13s%s', ['Licence:', Manifest.License]));
  if Manifest.Homepage <> '' then
    Context.Say(Format('%-13s%s', ['Homepage:', Manifest.Homepage]));
  Context.Say(Format('%-13s%s', ['Arch:', Manifest.Architecture]));
  Context.Say(Format('%-13s%s', ['State:', State]));
  SayList(Context, 'Depends:', Manifest.Depends);
  SayList(Context, 'Provides:', Manifest.Provides);
  SayList(Context, 'Conflicts:', Manifest.Conflicts);
  SayList(Context, 'Licences:', Manifest.LicenseFiles);
  if Description <> '' then
  begin
    Context.Say('');
    Context.Say(TrimRight(Description));
  end;
  if ListFiles then
  begin
    Context.Say('');
    for Index := 0 to High(Manifest.Entries) do
    begin
      Entry := Manifest.Entries[Index];
      if Entry.Kind = EntryFile then
        Context.Say('/' + Entry.Path)
      else if Entry.Kind = EntryLink then
        Context.Say('/' + Entry.Path + ' -> ' + Entry.Target);
    end;
  end;
end;

function InfoCommand(Context: TPackageContext; const Targets: TStringArray; ListFiles: Boolean): Integer;
var
  Index: Integer;
  Package: TInstalledPackage;
  Archive: TPackageArchive;
  State: string;
begin
  Result := 0;
  if Length(Targets) = 0 then
    Exit(ListCommand(Context, False));
  for Index := 0 to High(Targets) do
  begin
    if Index > 0 then
      Context.Say('');
    try
      if IsPackageFileTarget(Targets[Index]) and FileExists(Targets[Index]) then
      begin
        Archive := TPackageArchive.Create(Targets[Index]);
        try
          if Context.Database.Find(Archive.Manifest.Name) <> nil then
            State := 'a package file; installed: ' + Context.Database.Find(Archive.Manifest.Name).Manifest.FullVersion
          else
            State := 'a package file; not installed';
          DescribeManifest(Context, Archive.Manifest, Archive.Description, State, ListFiles);
        finally
          Archive.Free;
        end;
        Continue;
      end;
      Package := Context.Database.FindProvider(Targets[Index]);
      if Package = nil then
        raise EPackageRefused.CreateFmt('%s is not installed', [Targets[Index]]);
      if Package.Automatic then
        State := 'installed (as a dependency)'
      else
        State := 'installed';
      DescribeManifest(Context, Package.Manifest, Package.Description, State, ListFiles);
    except
      on Error: Exception do
      begin
        Report(Context, Error);
        Result := 1;
      end;
    end;
  end;
end;

function ListCommand(Context: TPackageContext; Quiet: Boolean): Integer;
var
  Index: Integer;
  Manifest: TPackageManifest;
begin
  for Index := 0 to Context.Database.Count - 1 do
  begin
    Manifest := Context.Database[Index].Manifest;
    if Quiet then
      Context.Say(Manifest.Name)
    else
      Context.Say(Format('%-20s %-12s %s', [Manifest.Name, Manifest.FullVersion, Manifest.Summary]));
  end;
  Result := 0;
end;

function WhichCommand(Context: TPackageContext; const Paths: TStringArray): Integer;
var
  Index: Integer;
  Relative: string;
  Owner: TInstalledPackage;
begin
  Result := 0;
  for Index := 0 to High(Paths) do
  begin
    Relative := Paths[Index];
    if (Relative <> '') and (Relative[1] <> '/') then
      Relative := ExpandFileName(Relative);
    while (Relative <> '') and (Relative[1] = '/') do
      Delete(Relative, 1, 1);
    Owner := Context.Database.Owner(Relative);
    if Owner = nil then
    begin
      Context.Warn(Format('/%s was not installed by a package', [Relative]));
      Result := 1;
    end
    else
      Context.Say(Format('/%s was installed by %s %s', [Relative, Owner.Manifest.Name, Owner.Manifest.FullVersion]));
  end;
end;

{ True when the package is as it was installed; says what is not. }
function VerifyOne(Context: TPackageContext; Target: TInstalledPackage): Boolean;
var
  Problems: TStringArray;
  ProblemIndex: Integer;
begin
  Problems := VerifyPackage(Context, Target);
  for ProblemIndex := 0 to High(Problems) do
    Context.Warn(Format('%s: %s', [Target.Manifest.Name, Problems[ProblemIndex]]));
  Result := Length(Problems) = 0;
  if Result then
    Context.Say(Format('%s %s: ok', [Target.Manifest.Name, Target.Manifest.FullVersion]));
end;

function VerifyCommand(Context: TPackageContext; const Names: TStringArray): Integer;
var
  Index: Integer;
  Package: TInstalledPackage;
begin
  Result := 0;
  if Length(Names) = 0 then
  begin
    for Index := 0 to Context.Database.Count - 1 do
      if not VerifyOne(Context, Context.Database[Index]) then
        Result := 1;
    Exit;
  end;
  for Index := 0 to High(Names) do
  begin
    Package := Context.Database.Find(Names[Index]);
    if Package = nil then
    begin
      Context.Warn(Format('pkg: %s is not installed', [Names[Index]]));
      Result := 1;
    end
    else if not VerifyOne(Context, Package) then
      Result := 1;
  end;
end;

function SearchCommand(Context: TPackageContext; const Words: TStringArray): Integer;
var
  Indexes: TRepositoryIndexes;
  RepositoryIndex, EntryIndex, WordIndex: Integer;
  Entry: TIndexEntry;
  Text, Mark: string;
  Matches: Boolean;
begin
  Result := 1;
  Indexes := LoadCachedIndexes(Context);
  try
    for RepositoryIndex := 0 to High(Indexes) do
      for EntryIndex := 0 to High(Indexes[RepositoryIndex].Entries) do
      begin
        Entry := Indexes[RepositoryIndex].Entries[EntryIndex];
        if Entry.Architecture <> Context.Architecture then
          Continue;
        Text := LowerCase(Entry.Name + ' ' + Entry.Summary);
        Matches := True;
        for WordIndex := 0 to High(Words) do
          if Pos(LowerCase(Words[WordIndex]), Text) = 0 then
            Matches := False;
        if not Matches then
          Continue;
        if Context.Database.Find(Entry.Name) <> nil then
          Mark := ' (installed)'
        else
          Mark := '';
        Context.Say(Format('%-20s %-12s %s%s', [Entry.Name, IndexEntryFullVersion(Entry), Entry.Summary, Mark]));
        Result := 0;
      end;
  finally
    FreeIndexes(Indexes);
  end;
end;

function UpdateCommand(Context: TPackageContext): Integer;
var
  Repositories: TRepositoryList;
  Index: Integer;
begin
  Result := 0;
  Repositories := ReadRepositories(Context);
  if Length(Repositories) = 0 then
  begin
    Context.Warn(Format('pkg: no repositories (/%s)', ['etc/pkg/repositories']));
    Exit(1);
  end;
  for Index := 0 to High(Repositories) do
    try
      UpdateRepository(Context, Repositories[Index]);
    except
      on Error: Exception do
      begin
        Report(Context, Error);
        Result := 1;
      end;
    end;
end;

function UpgradeCommand(Context: TPackageContext; const Names: TStringArray): Integer;
var
  Indexes: TRepositoryIndexes;
  Candidates: TStringArray;
  Index: Integer;
  Entry: TIndexEntry;
  Installed: TInstalledPackage;
  Upgraded: Integer;
begin
  Result := 0;
  Upgraded := 0;
  Candidates := nil;
  if Length(Names) > 0 then
    Candidates := Names
  else
  begin
    SetLength(Candidates, Context.Database.Count);
    for Index := 0 to Context.Database.Count - 1 do
      Candidates[Index] := Context.Database[Index].Manifest.Name;
  end;
  Indexes := LoadCachedIndexes(Context);
  try
    for Index := 0 to High(Candidates) do
      try
        Installed := Context.Database.Find(Candidates[Index]);
        if Installed = nil then
          raise EPackageRefused.CreateFmt('%s is not installed', [Candidates[Index]]);
        if not FindInIndexes(Indexes, Candidates[Index], Context.Architecture, Entry) or
          (Entry.Name <> Candidates[Index]) then
          Continue;
        if CompareVersions(IndexEntryFullVersion(Entry), Installed.Manifest.FullVersion) <= 0 then
          Continue;
        InstallMissingDependencies(Context, Indexes, Entry.Depends, 0);
        InstallFile(Context, Indexes, FetchPackage(Context, Entry), False, 0);
        Inc(Upgraded);
      except
        on Error: Exception do
        begin
          Report(Context, Error);
          Result := 1;
        end;
      end;
  finally
    FreeIndexes(Indexes);
  end;
  if (Upgraded = 0) and (Result = 0) then
    Context.Say('everything is up to date');
end;

function TestCommand(Context: TPackageContext; const Names: TStringArray): Integer;
var
  Index, TestIndex, Status: Integer;
  Package: TInstalledPackage;
begin
  Result := 0;
  for Index := 0 to High(Names) do
  begin
    Package := Context.Database.Find(Names[Index]);
    if Package = nil then
    begin
      Context.Warn(Format('pkg: %s is not installed', [Names[Index]]));
      Result := 1;
      Continue;
    end;
    if not Assigned(Context.RunScript) then
      Exit(1);
    for TestIndex := 0 to High(Package.Manifest.Tests) do
    begin
      Status := Context.RunScript('test', Package.Manifest.Tests[TestIndex], Package.Manifest, Context.Root);
      if Status = 0 then
        Context.Say(Format('%s: passed: %s', [Package.Manifest.Name, Package.Manifest.Tests[TestIndex]]))
      else
      begin
        Context.Warn(Format('%s: FAILED (%d): %s', [Package.Manifest.Name, Status, Package.Manifest.Tests[TestIndex]]));
        Result := 1;
      end;
    end;
  end;
end;

end.
