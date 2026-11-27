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
  Where pkg keeps things, under a root ("/" normally; pkg -r ROOT, or
  the host test's folder):

    ROOT/var/db/pkg/NAME/        an installed package (Pkg.Database)
    ROOT/var/db/pkg/.lock        held while pkg changes anything
    ROOT/var/cache/pkg/          downloaded packages
    ROOT/var/cache/pkg/repos/R/  repository R's INDEX and INDEX.sig
    ROOT/etc/pkg/repositories    the repositories (Pkg.Repositories)
    ROOT/etc/pkg/keys/NAME.pub   the keys their indexes are signed with

  Packages install under /usr/local (ports/README.md, "Prefix").
}
unit Pkg.Paths;

{$mode objfpc}
{$H+}

interface

const
  DatabaseFolder = 'var/db/pkg';
  CacheFolder = 'var/cache/pkg';
  RepositoryCacheFolder = 'var/cache/pkg/repos';
  RepositoriesFile = 'etc/pkg/repositories';
  KeysFolder = 'etc/pkg/keys';
  LockFileName = '.lock';
  { Beside the file it will replace, until the transaction commits. }
  StagedSuffix = '.pkg-new';
  { The replaced file, kept until the transaction has committed. }
  ReplacedSuffix = '.pkg-old';

{$ifdef CPUAARCH64}
  MachineArchitecture = 'aarch64';
{$else}
  MachineArchitecture = 'x86_64';
{$endif}

{ ROOT/RELATIVE, for a root of '' or '/' too. }
function RootedPath(const Root, Relative: string): string;
{ The folders of the prefix's hierarchy, which no package owns or removes. }
function IsStandardFolder(const Relative: string): Boolean;

implementation

const
  StandardFolders: array[0..13] of string = (
    'usr', 'usr/local', 'usr/local/bin', 'usr/local/sbin', 'usr/local/lib', 'usr/local/libexec',
    'usr/local/include', 'usr/local/etc', 'usr/local/share', 'usr/local/share/doc',
    'usr/local/share/licenses', 'usr/local/share/man', 'usr/local/man', 'usr/local/lib/pkgconfig');

function RootedPath(const Root, Relative: string): string;
var
  Base: string;
begin
  Base := Root;
  while (Length(Base) > 0) and (Base[Length(Base)] = '/') do
    SetLength(Base, Length(Base) - 1);
  if (Relative <> '') and (Relative[1] = '/') then
    Result := Base + Relative
  else
    Result := Base + '/' + Relative;
end;

function IsStandardFolder(const Relative: string): Boolean;
var
  Index: Integer;
begin
  for Index := Low(StandardFolders) to High(StandardFolders) do
    if StandardFolders[Index] = Relative then
      Exit(True);
  Result := False;
end;

end.
