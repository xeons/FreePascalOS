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
  Checks libarchive on the host: SafeEntryPath, times, CP437 names and
  tar fields; reading the zip and tar files make-fixtures.py makes with
  Python's zipfile and tarfile (and some patched by hand); extracting
  into folders; browsing folders; writing zip files, read back here and
  then by check-written.py with Python's zipfile.

    ArchiveTest FIXTURE-DIRECTORY SAMPLE-DIRECTORY WORK-DIRECTORY

  Prints one line per check and the totals; exits with 1 if any failed.
}
program ArchiveTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  ArchiveTest.Support,
  ArchiveTest.Basics,
  ArchiveTest.Reading,
  ArchiveTest.Writing;

var
  FixtureDirectory, SampleDirectory, WorkDirectory: string;

begin
  if ParamCount < 3 then
  begin
    WriteLn('usage: ArchiveTest FIXTURE-DIRECTORY SAMPLE-DIRECTORY WORK-DIRECTORY');
    Halt(2);
  end;
  FixtureDirectory := ExpandFileName(ParamStr(1));
  SampleDirectory := ExpandFileName(ParamStr(2));
  WorkDirectory := ExpandFileName(ParamStr(3));
  RemoveTree(WorkDirectory);
  ForceDirectories(WorkDirectory);
  RemoveTree(SampleDirectory);
  ForceDirectories(SampleDirectory);

  TestSafeEntryPath;
  TestTimes;
  TestCp437;
  TestTarFields;
  TestFixtures(FixtureDirectory, WorkDirectory);
  TestExtractAll(FixtureDirectory, WorkDirectory);
  TestRandomAccess(FixtureDirectory);
  TestFolders(FixtureDirectory);
  TestCancelling(FixtureDirectory);
  TestWriting(SampleDirectory, WorkDirectory);
  FinishChecks('archive test');
end.
