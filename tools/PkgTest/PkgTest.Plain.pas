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
  pkg's plain parts against the ports tool's answers: versions ordered
  as portstool.versions orders them (versions.txt), dependencies, a
  manifest as the ports tool writes it, a repository index, the
  database install-to-image writes, and packages read and checked.
}
unit PkgTest.Plain;

{$mode objfpc}
{$H+}

interface

procedure TestVersions;
procedure TestDependencies;
procedure TestManifests;
procedure TestIndex;
procedure TestImageDatabase;
procedure TestArchives;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Pkg.Archives,
  Pkg.Context,
  Pkg.Database,
  Pkg.Index,
  Pkg.Manifests,
  Pkg.Verification,
  Pkg.Versions,
  PkgTest.Support;

procedure TestVersions;
var
  Lines: TStringArray;
  Words: TStringArray;
  Index, Expected, Mismatches, Count: Integer;
begin
  Lines := TextOf(FixtureFolder + '/versions.txt').Split([#10]);
  Mismatches := 0;
  Count := 0;
  for Index := 0 to High(Lines) do
  begin
    if Lines[Index] = '' then
      Continue;
    Words := Lines[Index].Split([' ']);
    Expected := StrToInt(Words[2]);
    Inc(Count);
    if CompareVersions(Words[0], Words[1]) <> Expected then
    begin
      Inc(Mismatches);
      WriteLn('  versions: ', Words[0], ' vs ', Words[1], ' gave ', CompareVersions(Words[0], Words[1]),
        ', the ports tool ', Expected);
    end;
  end;
  Check((Count > 30) and (Mismatches = 0), Format('versions: %d pairs ordered as the ports tool orders them', [Count]));
  Check(FullVersion('1.3', 0) = '1.3', 'versions: no revision');
  Check(FullVersion('1.3', 2) = '1.3_2', 'versions: revision 2');
end;

procedure TestDependencies;
var
  Dependency: TDependency;
begin
  Check(ParseDependency('zlib>=1.3', Dependency) and (Dependency.Name = 'zlib') and (Dependency.Operation = '>=') and
    (Dependency.Version = '1.3'), 'dependencies: zlib>=1.3');
  Check(ParseDependency(' lua = 5.4.9 ', Dependency) and (DependencyText(Dependency) = 'lua = 5.4.9'),
    'dependencies: spaces around');
  Check(ParseDependency('hello', Dependency) and (Dependency.Operation = ''), 'dependencies: a name alone');
  Check(not ParseDependency('', Dependency) and not ParseDependency('>=1', Dependency) and
    not ParseDependency('zlib >=', Dependency) and not ParseDependency('zlib ~ 1', Dependency) and
    not ParseDependency('Zlib', Dependency) and not ParseDependency('zlib >= 1 2', Dependency),
    'dependencies: broken ones refused');
  ParseDependency('zlib>=1.3', Dependency);
  Check(DependencySatisfied(Dependency, '1.4') and not DependencySatisfied(Dependency, '1.2.13'),
    'dependencies: >= checked');
  ParseDependency('zlib<2', Dependency);
  Check(DependencySatisfied(Dependency, '1.9') and not DependencySatisfied(Dependency, '2.0'), 'dependencies: <');
  ParseDependency('zlib=1.3_1', Dependency);
  Check(DependencySatisfied(Dependency, '1.3_1') and not DependencySatisfied(Dependency, '1.3'), 'dependencies: =');
end;

procedure TestManifests;
var
  Archive: TPackageArchive;
  Manifest: TPackageManifest;
  Index: Integer;
  Broken: Boolean;
const
  Good = 'format 1'#10'name x'#10'version 1'#10'architecture x86_64'#10;
  BrokenTexts: array[0..6] of string = (
    'name x'#10'version 1'#10'architecture x86_64'#10,
    'format 2'#10'name x'#10'version 1'#10'architecture x86_64'#10,
    Good + 'file 0644 3 abc usr/x'#10,
    Good + 'bogus line'#10,
    Good + 'file 0644 3 ' + '0000000000000000000000000000000000000000000000000000000000000000' + ' /abs'#10,
    Good + 'link a/../b c'#10,
    Good + 'dir 0999 usr/x'#10);
begin
  Archive := TPackageArchive.Create(PackageFile('alpha-1.0-x86_64.pkg.tar.zst'));
  try
    Manifest := Archive.Manifest;
    Check((Manifest.Name = 'alpha') and (Manifest.Version = '1.0') and (Manifest.Revision = 0) and
      (Manifest.Architecture = 'x86_64') and (Manifest.Origin = 'misc/alpha') and (Manifest.Prefix = '/usr/local'),
      'manifest: the header fields');
    Check(Manifest.Summary = 'The alpha test package', 'manifest: the summary, spaces kept');
    Check((Length(Manifest.Scripts) = 3) and Manifest.HasScript('post-install') and Manifest.HasScript('pre-remove'),
      'manifest: the scripts');
    Check((Length(Manifest.Provides) = 1) and Manifest.ProvidesName('alpha-provided') and Manifest.ProvidesName('alpha'),
      'manifest: provides');
    Check((Manifest.FindPath('usr/local/bin/alpha') >= 0) and
      (Manifest.Entries[Manifest.FindPath('usr/local/bin/alpha')].Mode = &755) and
      (Length(Manifest.Entries[Manifest.FindPath('usr/local/bin/alpha')].Sha256) = 64),
      'manifest: a file entry');
    Check(Manifest.Entries[Manifest.FindPath('usr/local/share/alpha/current')].Target = 'data.txt',
      'manifest: a link entry');
    Check(Archive.Description = 'The alpha package, for the tests.'#10, 'manifest: the description');
    Check(Archive.ScriptText('pre-remove') = 'echo removing'#10, 'manifest: a script''s text');
  finally
    Archive.Free;
  end;
  Manifest := TPackageManifest.Create(Good);
  Check((Manifest.Name = 'x') and (Length(Manifest.Entries) = 0), 'manifest: the smallest');
  Manifest.Free;
  Broken := True;
  for Index := Low(BrokenTexts) to High(BrokenTexts) do
    try
      TPackageManifest.Create(BrokenTexts[Index]).Free;
      Broken := False;
      WriteLn('  manifest accepted: ', BrokenTexts[Index]);
    except
      on EManifestError do
        ;
    end;
  Check(Broken, 'manifest: damaged ones refused');
  Check(IsSafePackagePath('usr/local/bin/x') and not IsSafePackagePath('/usr') and not IsSafePackagePath('a/../b') and
    not IsSafePackagePath('a b') and not IsSafePackagePath('a//b') and not IsSafePackagePath(''),
    'manifest: safe paths');
end;

procedure TestIndex;
var
  Index: TRepositoryIndex;
  Found: Integer;
begin
  Index := TRepositoryIndex.Create(TextOf(FixtureFolder + '/repository/INDEX'), 'test');
  try
    Check(Length(Index.Entries) = 2, 'index: two packages');
    Found := Index.FindNewest('alpha', 'x86_64');
    Check((Found >= 0) and (Index.Entries[Found].Version = '1.1') and (Index.Entries[Found].Size > 0) and
      (Length(Index.Entries[Found].Sha256) = 64) and (Index.Entries[Found].FileName = 'alpha-1.1-x86_64.pkg.tar.zst') and
      (Index.Entries[Found].Repository = 'test'), 'index: alpha''s entry');
    Found := Index.FindNewest('beta', 'x86_64');
    Check((Found >= 0) and (Length(Index.Entries[Found].Depends) = 1) and
      (Index.Entries[Found].Depends[0] = 'alpha >= 1.0'), 'index: beta needs alpha');
    Check(Index.FindNewest('beta', 'aarch64') < 0, 'index: not for another architecture');
    Found := Index.FindNewest('beta-provided', 'x86_64');
    Check((Found >= 0) and (Index.Entries[Found].Name = 'beta'), 'index: found by what it provides');
  finally
    Index.Free;
  end;
  try
    TRepositoryIndex.Create('format 1'#10'package x'#10'version 1'#10, 'test').Free;
    Check(False, 'index: one cut short refused');
  except
    on EIndexError do
      Check(True, 'index: one cut short refused');
  end;
  try
    TRepositoryIndex.Create('format 1'#10'package x'#10'version 1'#10'file ../x'#10'size 1'#10'sha256 ' +
      StringOfChar('0', 64) + #10'end'#10, 'test').Free;
    Check(False, 'index: an unsafe file name refused');
  except
    on EIndexError do
      Check(True, 'index: an unsafe file name refused');
  end;
end;

procedure TestImageDatabase;
var
  Services: TTestServices;
  Context: TPackageContext;
  Package: TInstalledPackage;
begin
  Services := TTestServices.Create;
  Context := NewContext(FixtureFolder + '/image-root', Services);
  try
    Check(Context.Database.Count = 1, 'image database: one package installed by install-to-image');
    Package := Context.Database.Find('alpha');
    Check((Package <> nil) and (Package.InstalledTime = 1700000000) and not Package.Automatic and
      (Package.Description = 'The alpha package, for the tests.'#10), 'image database: its entry');
    Check((Package <> nil) and (Length(VerifyPackage(Context, Package)) = 0), 'image database: it verifies');
    Check(Context.Database.Owner('usr/local/bin/alpha') = Package, 'image database: which');
    Check(Context.Database.FindProvider('alpha-provided') = Package, 'image database: a provider');
  finally
    Context.Free;
    Services.Free;
  end;
end;

procedure TestArchives;
var
  Archive: TPackageArchive;
  Problems: TStringArray;
begin
  Archive := TPackageArchive.Create(PackageFile('alpha-1.1-x86_64.pkg.tar.zst'));
  try
    Check(Length(Archive.Verify) = 0, 'archive: a good package verifies');
  finally
    Archive.Free;
  end;
  Archive := TPackageArchive.Create(PackageFile('corrupt-1.0-x86_64.pkg.tar.zst'));
  try
    Problems := Archive.Verify;
    Check((Length(Problems) = 1) and (Pos('b.txt', Problems[0]) > 0), 'archive: the damaged file is found');
  finally
    Archive.Free;
  end;
  WriteText(WorkFolder + '/not-a-package.pkg.tar.zst', 'nonsense');
  try
    TPackageArchive.Create(WorkFolder + '/not-a-package.pkg.tar.zst').Free;
    Check(False, 'archive: not a package refused');
  except
    on EPackageError do
      Check(True, 'archive: not a package refused');
  end;
end;

end.
