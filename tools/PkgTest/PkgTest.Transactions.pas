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
  Installing, upgrading, verifying and removing packages under a root
  of the test's own, through pkg's commands: dependencies and conflicts
  checked, a file of another package refused, a damaged package and a
  failing pre-install script leaving nothing behind, an upgrade
  replacing and dropping files, a changed file found by verify, and
  removal leaving the root as it was.
}
unit PkgTest.Transactions;

{$mode objfpc}
{$H+}

interface

procedure TestTransactions;
procedure TestRepositories;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Pkg.Commands,
  Pkg.Context,
  Pkg.Database,
  Pkg.FileSystem,
  Pkg.Paths,
  PkgTest.Support;

function Targets(const A: string; const B: string = ''): TStringArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := A;
  if B <> '' then
  begin
    SetLength(Result, 2);
    Result[1] := B;
  end;
end;

function NoStagedLeft(const Root: string): Boolean;
var
  Files: TStringArray;
  Index: Integer;
begin
  Files := FilesUnder(Root);
  for Index := 0 to High(Files) do
    if (Pos(StagedSuffix, Files[Index]) > 0) or (Pos(ReplacedSuffix, Files[Index]) > 0) then
      Exit(False);
  Result := True;
end;

procedure TestTransactions;
var
  Root: string;
  Services: TTestServices;
  Context: TPackageContext;
  Mode: LongWord;
  Target: string;
  Before: string;
begin
  Root := WorkFolder + '/root';
  RemoveTree(Root);
  ForceDirectories(Root);
  Services := TTestServices.Create;
  Context := NewContext(Root, Services);
  try
    { A first package. }
    Check(InstallCommand(Context, Targets(PackageFile('alpha-1.0-x86_64.pkg.tar.zst')), False) = 0,
      'install: alpha 1.0');
    Check(Exists(Root, 'usr/local/bin/alpha') and Exists(Root, 'usr/local/share/alpha/old.txt') and
      Exists(Root, 'usr/local/share/licenses/alpha/LICENSE'), 'install: its files are there');
    Check(ReadLink(Root + '/usr/local/share/alpha/current', Target) and (Target = 'data.txt'), 'install: its link');
    Check(PathPermissions(Root + '/usr/local/bin/alpha', Mode) and ((Mode and &777) = &755),
      'install: the program''s mode');
    Check(TextOf(Root + '/usr/local/share/alpha/data.txt') = 'alpha data'#10, 'install: a file''s content');
    Check(Context.Database.Find('alpha') <> nil, 'install: recorded in the database');
    Check(FileExists(Root + '/var/db/pkg/alpha/+MANIFEST') and FileExists(Root + '/var/db/pkg/alpha/+pre-remove') and
      FileExists(Root + '/var/db/pkg/alpha/+post-remove') and not FileExists(Root + '/var/db/pkg/alpha/+post-install'),
      'install: the database entry keeps the removal scripts');
    Check(Services.Scripts.IndexOf('alpha post-install') >= 0, 'install: the post-install script ran');
    Check(NoStagedLeft(Root), 'install: nothing staged left behind');
    Check(VerifyCommand(Context, nil) = 0, 'verify: everything as installed');

    { Refusals, each leaving the root as it was. }
    Before := Joined(FilesUnder(Root));
    Services.Clear;
    Check(InstallCommand(Context, Targets(PackageFile('alpha-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'install: the same version again refused');
    Check(InstallCommand(Context, Targets(PackageFile('clash-1.0-x86_64.pkg.tar.zst')), False) = 1, 'install: clash refused');
    Check(Services.Said('/usr/local/share/alpha/data.txt belongs to alpha'), 'install: says which package owns the file');
    Check(InstallCommand(Context, Targets(PackageFile('needy-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'install: an unmet version refused');
    Check(Services.Said('needs alpha >= 2.0'), 'install: says what is missing');
    Check(InstallCommand(Context, Targets(PackageFile('rival-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'install: a conflicting package refused');
    Check(InstallCommand(Context, Targets(PackageFile('arm-1.0-aarch64.pkg.tar.zst')), False) = 1,
      'install: another architecture refused');
    Check(InstallCommand(Context, Targets(PackageFile('corrupt-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'install: a damaged package refused');
    Check(Services.Said('b.txt does not match its checksum'), 'install: says which file is damaged');
    Check(InstallCommand(Context, Targets(PackageFile('failing-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'install: a failing pre-install script stops it');
    Check(Joined(FilesUnder(Root)) = Before, 'install: refusals and failures changed nothing');
    Check(Context.Database.Count = 1, 'install: still one package');

    { A file that belongs to no package is in the way unless forced. }
    ForceDirectories(Root + '/usr/local/bin');
    WriteText(Root + '/usr/local/bin/beta', 'left by hand');
    Check(InstallCommand(Context, Targets(PackageFile('beta-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'install: a file of no package refused');
    Context.Force := True;
    Check(InstallCommand(Context, Targets(PackageFile('beta-1.0-x86_64.pkg.tar.zst')), True) = 0,
      'install: forced over it');
    Context.Force := False;
    Check(TextOf(Root + '/usr/local/bin/beta') = 'beta'#10, 'install: the package''s file replaced it');
    Check(Context.Database.Find('beta').Automatic, 'install: -A marks it automatic');

    { Removal refused while needed. }
    Services.Clear;
    Check(RemoveCommand(Context, Targets('alpha')) = 1, 'remove: alpha refused while beta needs it');
    Check(Services.Said('alpha is needed by beta'), 'remove: says who needs it');
    Check(Exists(Root, 'usr/local/bin/alpha'), 'remove: nothing removed');

    { Upgrade. }
    Services.Clear;
    Check(InstallCommand(Context, Targets(PackageFile('alpha-1.1-x86_64.pkg.tar.zst')), False) = 0, 'upgrade: to 1.1');
    Check(Services.Said('upgraded alpha to 1.1'), 'upgrade: says so');
    Check(not Exists(Root, 'usr/local/share/alpha/old.txt'), 'upgrade: a file 1.1 does not have is gone');
    Check(TextOf(Root + '/usr/local/share/alpha/new.txt') = 'only in 1.1'#10, 'upgrade: a new file');
    Check(PathPermissions(Root + '/usr/local/share/alpha/new.txt', Mode) and ((Mode and &777) = &600),
      'upgrade: the new file''s mode');
    Check(TextOf(Root + '/usr/local/share/alpha/data.txt') = 'alpha data, version 1.1'#10, 'upgrade: a changed file');
    Check(Context.Database.Find('alpha').Manifest.Version = '1.1', 'upgrade: the database says 1.1');
    Check(NoStagedLeft(Root), 'upgrade: no copies left behind');
    Check(InstallCommand(Context, Targets(PackageFile('alpha-1.0-x86_64.pkg.tar.zst')), False) = 1,
      'upgrade: going back refused without --force');

    { Verify finds changes. }
    WriteText(Root + '/usr/local/share/alpha/data.txt', 'changed by hand'#10);
    Services.Clear;
    Check(VerifyCommand(Context, Targets('alpha')) = 1, 'verify: a changed file found');
    Check(Services.Said('data.txt: the size is'), 'verify: says what changed');
    DeleteFile(Root + '/usr/local/bin/alpha');
    Services.Clear;
    VerifyCommand(Context, Targets('alpha'));
    Check(Services.Said('/usr/local/bin/alpha: the file is missing'), 'verify: a missing file found');

    { Which, info, list. }
    Services.Clear;
    WhichCommand(Context, Targets('/usr/local/bin/beta'));
    Check(Services.Said('/usr/local/bin/beta was installed by beta 1.0'), 'which: the owner');
    Check(WhichCommand(Context, Targets('/usr/local/bin/nothing')) = 1, 'which: no owner');
    Services.Clear;
    InfoCommand(Context, Targets('alpha'), True);
    Check(Services.Said('alpha') and Services.Said('/usr/local/share/alpha/current -> data.txt'), 'info: with files');
    Services.Clear;
    ListCommand(Context, True);
    Check((Services.Messages.Count = 2) and (Services.Messages[0] = 'alpha') and (Services.Messages[1] = 'beta'),
      'list: both');

    { Removal: both at once, leaving the root as before. }
    Services.Clear;
    Check(RemoveCommand(Context, Targets('alpha', 'beta')) = 0, 'remove: alpha and beta together');
    Check(Services.Scripts.IndexOf('alpha pre-remove') >= 0, 'remove: the pre-remove script ran');
    Check(Services.Scripts.IndexOf('alpha post-remove') >= 0, 'remove: the post-remove script ran');
    Check(Services.Said('/usr/local/share/alpha/data.txt was changed since it was installed'),
      'remove: a changed file is mentioned');
    Check(Context.Database.Count = 0, 'remove: the database is empty');
    Check(not DirectoryExists(Root + '/usr/local/share/alpha'), 'remove: the package''s folder is gone');
    Check(DirectoryExists(Root + '/usr/local/bin'), 'remove: the prefix''s folders stay');
    Check(Joined(FilesUnder(Root)) = '', 'remove: nothing of the packages is left');
  finally
    Context.Free;
    Services.Free;
  end;
end;

procedure TestRepositories;
var
  Root: string;
  Services: TTestServices;
  Context: TPackageContext;
begin
  Root := WorkFolder + '/repository-root';
  RemoveTree(Root);
  ForceDirectories(Root + '/etc/pkg/keys');
  WriteText(Root + '/etc/pkg/keys/test.pub', TextOf(FixtureFolder + '/keys/test.pub'));
  WriteText(Root + '/etc/pkg/repositories', '# the test''s'#10'test file://' + FixtureFolder + '/repository'#10);
  Services := TTestServices.Create;
  Context := NewContext(Root, Services);
  try
    Check(SearchCommand(Context, Targets('beta')) = 1, 'repository: nothing to search before an update');
    Check(UpdateCommand(Context) = 0, 'repository: update');
    Check(FileExists(Root + '/var/cache/pkg/repos/test/INDEX') and FileExists(Root + '/var/cache/pkg/repos/test/INDEX.sig'),
      'repository: the index is cached');
    Services.Clear;
    Check(SearchCommand(Context, Targets('BETA')) = 0, 'repository: search');
    Check(Services.Said('The beta test package'), 'repository: search shows the summary');
    Services.Clear;
    Check(InstallCommand(Context, Targets('beta'), False) = 0, 'repository: install beta by name');
    Check((Context.Database.Find('alpha') <> nil) and Context.Database.Find('alpha').Automatic,
      'repository: alpha came with it, as a dependency');
    Check((Context.Database.Find('beta') <> nil) and not Context.Database.Find('beta').Automatic,
      'repository: beta itself is not automatic');
    Check(FileExists(Root + '/var/cache/pkg/beta-1.0-x86_64.pkg.tar.zst'), 'repository: the package is cached');
    Services.Clear;
    Check(UpgradeCommand(Context, nil) = 0, 'repository: upgrade with nothing newer');
    Check(Services.Said('everything is up to date'), 'repository: says so');
    Check(InstallCommand(Context, Targets('nosuch'), False) = 1, 'repository: an unknown name refused');

    { A cached package that was changed is fetched again. }
    WriteText(Root + '/var/cache/pkg/beta-1.0-x86_64.pkg.tar.zst', 'damaged');
    RemoveCommand(Context, Targets('beta'));
    Check(InstallCommand(Context, Targets('beta'), False) = 0, 'repository: a damaged cached package fetched again');

    { A signature that does not match keeps the good index. }
    WriteText(Root + '/etc/pkg/repositories', 'test file://' + FixtureFolder + '/bad-repository'#10);
    Services.Clear;
    Check(UpdateCommand(Context) = 1, 'repository: a bad signature refused');
    Check(Services.Said('signature is bad'), 'repository: says why');
    Check(Pos('evil', TextOf(Root + '/var/cache/pkg/repos/test/INDEX')) = 0, 'repository: the good index stays');
    WriteText(Root + '/etc/pkg/repositories', 'test file://' + FixtureFolder + '/bad-repository signature=none'#10);
    Check(UpdateCommand(Context) = 0, 'repository: signature=none takes it unsigned');
    DeleteFile(Root + '/etc/pkg/keys/test.pub');
    WriteText(Root + '/etc/pkg/repositories', 'test file://' + FixtureFolder + '/repository'#10);
    Services.Clear;
    Check(UpdateCommand(Context) = 1, 'repository: no key refused');
  finally
    Context.Free;
    Services.Free;
  end;
end;

end.
