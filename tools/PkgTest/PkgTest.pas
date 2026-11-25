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
  Checks pkg (userland/pkg) on the host: everything but running scripts
  with /bin/sh and fetching over HTTP, against packages, an index and a
  database the ports tool made (make-fixtures.py).

    PkgTest FIXTURE-DIRECTORY WORK-DIRECTORY

  Prints one line per check and the totals; exits with 1 if any failed.
}
program PkgTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  Pkg.FileSystem,
  PkgTest.Support,
  PkgTest.Plain,
  PkgTest.Transactions;

begin
  if ParamCount <> 2 then
  begin
    WriteLn('Usage: PkgTest FIXTURE-DIRECTORY WORK-DIRECTORY');
    Halt(2);
  end;
  FixtureFolder := ExpandFileName(ParamStr(1));
  WorkFolder := ExpandFileName(ParamStr(2));
  RemoveTree(WorkFolder);
  ForceDirectories(WorkFolder);
  TestVersions;
  TestDependencies;
  TestManifests;
  TestIndex;
  TestImageDatabase;
  TestArchives;
  TestTransactions;
  TestRepositories;
  FinishChecks('pkg test');
end.
