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
  Installing (and upgrading to) a package, as one transaction:

  1. Checks, before anything is touched: the architecture, the version
     against what is installed, every dependency installed, no
     conflicting package, no path that belongs to another package or
     (without --force) to none.
  2. The pre-install script.
  3. Staging: every file is unpacked beside its place as NAME.pkg-new
     and checked against the manifest's size and SHA-256 (links made
     the same way). Any failure removes what was staged and the folders
     made for it: nothing changed.
  4. Committing: each file that is there already is moved aside to
     NAME.pkg-old, then the staged one renamed into place. A rename that
     fails puts back everything committed so far.
  5. The previous version's files that the new one does not have are
     removed; the .pkg-old copies go; the database entry is written
     (renamed into place whole); the post-install script runs (its
     failure is only reported).
}
unit Pkg.Installer;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Pkg.Archives,
  Pkg.Context,
  Pkg.Manifests;

type
  TPackageInstaller = class
  private
    FContext: TPackageContext;
    FArchive: TPackageArchive;
    FAutomatic: Boolean;
    FStaged: array of string;
    FCommitted: array of string;
    FReplaced: array of Boolean;
    FMadeFolders: TStringArray;
    FPreviousManifestText: string;
    procedure CheckArchitecture;
    procedure CheckVersion;
    procedure CheckDependencies;
    procedure CheckConflicts;
    procedure CheckPaths;
    procedure MakeListedFolders;
    procedure Stage;
    procedure Commit;
    procedure RollBackStaging;
    procedure RollBackCommit(Count: Integer);
    procedure RemoveLeftovers;
    procedure RunScript(const Kind: string; Fatal: Boolean);
  public
    constructor Create(Context: TPackageContext; Archive: TPackageArchive; Automatic: Boolean);
    { Raises EPackageRefused when a check refuses it, another exception
      when installing failed (and was undone). }
    procedure Install;
  end;

{ Whether dependency Text is met by what is installed. }
function DependencyInstalled(Context: TPackageContext; const Text: string): Boolean;

implementation

uses
  Archive.FileSystem,
  Pkg.Database,
  Pkg.FileSystem,
  Pkg.Paths,
  Pkg.Versions;

function DependencyInstalled(Context: TPackageContext; const Text: string): Boolean;
var
  Dependency: TDependency;
  Provider: TInstalledPackage;
begin
  if not ParseDependency(Text, Dependency) then
    Exit(False);
  Provider := Context.Database.FindProvider(Dependency.Name);
  if Provider = nil then
    Exit(False);
  { A version is a promise of the package of that name, not of others
    that provide the name. }
  if Provider.Manifest.Name <> Dependency.Name then
    Exit(True);
  Result := DependencySatisfied(Dependency, Provider.Manifest.FullVersion);
end;

constructor TPackageInstaller.Create(Context: TPackageContext; Archive: TPackageArchive; Automatic: Boolean);
begin
  inherited Create;
  FContext := Context;
  FArchive := Archive;
  FAutomatic := Automatic;
end;

procedure TPackageInstaller.CheckArchitecture;
var
  Manifest: TPackageManifest;
begin
  Manifest := FArchive.Manifest;
  if (Manifest.Architecture <> FContext.Architecture) and (Manifest.Architecture <> 'any') then
    raise EPackageRefused.CreateFmt('%s is for %s, this system is %s',
      [Manifest.Name, Manifest.Architecture, FContext.Architecture]);
end;

procedure TPackageInstaller.CheckVersion;
var
  Existing: TInstalledPackage;
  Order: Integer;
begin
  Existing := FContext.Database.Find(FArchive.Manifest.Name);
  if Existing = nil then
    Exit;
  FPreviousManifestText := Existing.Manifest.Text;
  { Upgrading keeps how it came to be installed. }
  FAutomatic := FAutomatic and Existing.Automatic;
  Order := CompareVersions(FArchive.Manifest.FullVersion, Existing.Manifest.FullVersion);
  if FContext.Force then
    Exit;
  if Order = 0 then
    raise EPackageRefused.CreateFmt('%s %s is installed already', [Existing.Manifest.Name,
      Existing.Manifest.FullVersion]);
  if Order < 0 then
    raise EPackageRefused.CreateFmt('%s %s is installed, newer than %s (--force to go back)',
      [Existing.Manifest.Name, Existing.Manifest.FullVersion, FArchive.Manifest.FullVersion]);
end;

procedure TPackageInstaller.CheckDependencies;
var
  Index: Integer;
  Missing: string;
begin
  Missing := '';
  for Index := 0 to High(FArchive.Manifest.Depends) do
    if not DependencyInstalled(FContext, FArchive.Manifest.Depends[Index]) then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + FArchive.Manifest.Depends[Index];
    end;
  if Missing <> '' then
    raise EPackageRefused.CreateFmt('%s needs %s, which is not installed', [FArchive.Manifest.Name, Missing]);
end;

procedure TPackageInstaller.CheckConflicts;
var
  Index, ConflictIndex: Integer;
  Other: TInstalledPackage;
  Name: string;
begin
  Name := FArchive.Manifest.Name;
  for Index := 0 to High(FArchive.Manifest.Conflicts) do
  begin
    Other := FContext.Database.FindProvider(FArchive.Manifest.Conflicts[Index]);
    if (Other <> nil) and (Other.Manifest.Name <> Name) then
      raise EPackageRefused.CreateFmt('%s conflicts with %s, which is installed', [Name, Other.Manifest.Name]);
  end;
  for Index := 0 to FContext.Database.Count - 1 do
  begin
    Other := FContext.Database[Index];
    if Other.Manifest.Name = Name then
      Continue;
    for ConflictIndex := 0 to High(Other.Manifest.Conflicts) do
      if FArchive.Manifest.ProvidesName(Other.Manifest.Conflicts[ConflictIndex]) then
        raise EPackageRefused.CreateFmt('%s, which is installed, conflicts with %s', [Other.Manifest.Name, Name]);
  end;
end;

procedure TPackageInstaller.CheckPaths;
var
  Index: Integer;
  Entry: TManifestEntry;
  Owner: TInstalledPackage;
  Target: string;
begin
  for Index := 0 to High(FArchive.Manifest.Entries) do
  begin
    Entry := FArchive.Manifest.Entries[Index];
    Target := FContext.Path(Entry.Path);
    if Entry.Kind = EntryDirectory then
    begin
      if PathIsTaken(Target) and not IsFolder(Target) then
        raise EPackageRefused.CreateFmt('/%s is in the way of a folder of %s', [Entry.Path, FArchive.Manifest.Name]);
      Continue;
    end;
    Owner := FContext.Database.Owner(Entry.Path);
    if (Owner <> nil) and (Owner.Manifest.Name <> FArchive.Manifest.Name) then
      raise EPackageRefused.CreateFmt('/%s belongs to %s', [Entry.Path, Owner.Manifest.Name]);
    if IsFolder(Target) then
      raise EPackageRefused.CreateFmt('/%s is a folder', [Entry.Path]);
    if (Owner = nil) and PathIsTaken(Target) and not FContext.Force then
      raise EPackageRefused.CreateFmt('/%s is there already and belongs to no package (--force to replace it)',
        [Entry.Path]);
  end;
end;

procedure TPackageInstaller.RunScript(const Kind: string; Fatal: Boolean);
var
  Status: Integer;
begin
  if not FArchive.Manifest.HasScript(Kind) or not Assigned(FContext.RunScript) then
    Exit;
  FContext.Say(Format('running the %s script of %s', [Kind, FArchive.Manifest.Name]));
  Status := FContext.RunScript(Kind, FArchive.ScriptText(Kind), FArchive.Manifest, FContext.Root);
  if Status = 0 then
    Exit;
  if Fatal then
    raise Exception.CreateFmt('the %s script of %s failed (status %d)', [Kind, FArchive.Manifest.Name, Status]);
  FContext.Warn(Format('the %s script of %s failed (status %d)', [Kind, FArchive.Manifest.Name, Status]));
end;

procedure TPackageInstaller.MakeListedFolders;
var
  Index: Integer;
  Entry: TManifestEntry;
begin
  for Index := 0 to High(FArchive.Manifest.Entries) do
  begin
    Entry := FArchive.Manifest.Entries[Index];
    if Entry.Kind <> EntryDirectory then
      Continue;
    if not MakeFolders(FContext.Path(Entry.Path), FMadeFolders) then
      raise Exception.CreateFmt('cannot make the folder /%s', [Entry.Path]);
    SetPathMode(FContext.Path(Entry.Path), Entry.Mode);
  end;
end;

procedure TPackageInstaller.Stage;
var
  Index: Integer;
  Entry: TManifestEntry;
  Target, Staged, Problem: string;
begin
  FStaged := nil;
  for Index := 0 to High(FArchive.Manifest.Entries) do
  begin
    Entry := FArchive.Manifest.Entries[Index];
    if Entry.Kind = EntryDirectory then
      Continue;
    Target := FContext.Path(Entry.Path);
    Staged := Target + StagedSuffix;
    if not MakeFolders(ExtractFileDir(Target), FMadeFolders) then
      raise Exception.CreateFmt('cannot make the folder of /%s', [Entry.Path]);
    if PathIsTaken(Staged) then
      RemoveFileOrLink(Staged);
    SetLength(FStaged, Length(FStaged) + 1);
    FStaged[High(FStaged)] := Target;
    if Entry.Kind = EntryLink then
    begin
      if not CreateSymbolicLink(Entry.Target, Staged) then
        raise Exception.CreateFmt('cannot make the link /%s', [Entry.Path]);
    end
    else
    begin
      if not FArchive.ExtractCheckedFile(Entry, Staged, Problem) then
        raise Exception.Create(Problem);
      SetPathMode(Staged, Entry.Mode);
    end;
  end;
end;

procedure TPackageInstaller.RollBackStaging;
var
  Index: Integer;
begin
  for Index := 0 to High(FStaged) do
    if PathIsTaken(FStaged[Index] + StagedSuffix) then
      RemoveFileOrLink(FStaged[Index] + StagedSuffix);
  for Index := High(FMadeFolders) downto 0 do
    RemoveEmptyFolder(FMadeFolders[Index]);
end;

procedure TPackageInstaller.Commit;
var
  Index: Integer;
  Target: string;
begin
  SetLength(FReplaced, Length(FStaged));
  for Index := 0 to High(FStaged) do
  begin
    Target := FStaged[Index];
    FReplaced[Index] := False;
    if PathIsTaken(Target) then
    begin
      if PathIsTaken(Target + ReplacedSuffix) then
        RemoveFileOrLink(Target + ReplacedSuffix);
      if not RenamePathOver(Target, Target + ReplacedSuffix) then
      begin
        RollBackCommit(Index);
        raise Exception.CreateFmt('cannot move %s aside', [Target]);
      end;
      FReplaced[Index] := True;
    end;
    if not RenamePathOver(Target + StagedSuffix, Target) then
    begin
      if FReplaced[Index] then
        RenamePathOver(Target + ReplacedSuffix, Target);
      RollBackCommit(Index);
      raise Exception.CreateFmt('cannot put %s in place', [Target]);
    end;
  end;
end;

{ Undoes the first Count commits, newest first, then the staging. }
procedure TPackageInstaller.RollBackCommit(Count: Integer);
var
  Index: Integer;
  Target: string;
begin
  for Index := Count - 1 downto 0 do
  begin
    Target := FStaged[Index];
    RemoveFileOrLink(Target);
    if FReplaced[Index] then
      RenamePathOver(Target + ReplacedSuffix, Target);
  end;
  RollBackStaging;
end;

{ After the commit: what the previous version had and this one has
  not, and the copies moved aside. }
procedure TPackageInstaller.RemoveLeftovers;
var
  Index: Integer;
  Previous: TPackageManifest;
  Entry: TManifestEntry;
begin
  for Index := 0 to High(FStaged) do
    if FReplaced[Index] then
      RemoveFileOrLink(FStaged[Index] + ReplacedSuffix);
  if FPreviousManifestText = '' then
    Exit;
  Previous := TPackageManifest.Create(FPreviousManifestText);
  try
    for Index := 0 to High(Previous.Entries) do
    begin
      Entry := Previous.Entries[Index];
      if (Entry.Kind <> EntryDirectory) and (FArchive.Manifest.FindPath(Entry.Path) < 0) then
        RemoveFileOrLink(FContext.Path(Entry.Path));
    end;
    for Index := High(Previous.Entries) downto 0 do
    begin
      Entry := Previous.Entries[Index];
      if (Entry.Kind = EntryDirectory) and not IsStandardFolder(Entry.Path) then
        RemoveEmptyFolder(FContext.Path(Entry.Path));
    end;
  finally
    Previous.Free;
  end;
end;

procedure TPackageInstaller.Install;
var
  Manifest: TPackageManifest;
  Upgrading: Boolean;
begin
  Manifest := FArchive.Manifest;
  CheckArchitecture;
  CheckVersion;
  Upgrading := FPreviousManifestText <> '';
  CheckDependencies;
  CheckConflicts;
  CheckPaths;
  RunScript('pre-install', True);
  FMadeFolders := nil;
  try
    MakeListedFolders;
    Stage;
  except
    RollBackStaging;
    raise;
  end;
  Commit;
  RemoveLeftovers;
  FContext.Database.Store(Manifest, FArchive.Description, FArchive.Scripts, FAutomatic);
  if Upgrading then
    FContext.Say(Format('upgraded %s to %s', [Manifest.Name, Manifest.FullVersion]))
  else
    FContext.Say(Format('installed %s %s', [Manifest.Name, Manifest.FullVersion]));
  RunScript('post-install', False);
end;

end.
