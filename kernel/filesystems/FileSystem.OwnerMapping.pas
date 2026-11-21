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
  Owners and permissions for formats that have none (FAT, exFAT).

  Every node gets the owner and group of the mount options (uid=, gid=;
  root without them) and rwxrwxrwx less the file or folder mask (fmask=,
  dmask=, or umask= for both). The format's read-only attribute takes
  every write permission away from a file, so a file marked read-only
  elsewhere stays read-only here, and chmod a-w sets the attribute (the
  driver).

  Plain Pascal, so the host tests build it too.
}
unit FileSystem.OwnerMapping;

{$mode objfpc}

interface

uses
  FileSystem.MountOptions;

const
  AllPermissions = $1FF;        { rwxrwxrwx }
  AllWritePermissions = $92;    { -w--w--w- }

{ The permission bits a node without owners shows. }
function OwnerlessMode(IsDirectory, HasReadOnlyAttribute: Boolean; const Options: TMountOptions): LongWord;

{ Whether a mode the driver reports means the read-only attribute is
  set (FAT and exFAT report no write permission then). }
function ModeMeansReadOnly(DriverMode: LongWord): Boolean;

implementation

function OwnerlessMode(IsDirectory, HasReadOnlyAttribute: Boolean; const Options: TMountOptions): LongWord;
begin
  if IsDirectory then
    Result := AllPermissions and not Options.DirectoryMask
  else
    Result := AllPermissions and not Options.FileMask;
  { Windows marks customized folders read-only; as on Linux, the
    attribute only counts for files. }
  if HasReadOnlyAttribute and not IsDirectory then
    Result := Result and not AllWritePermissions;
end;

function ModeMeansReadOnly(DriverMode: LongWord): Boolean;
begin
  Result := (DriverMode and AllWritePermissions) = 0;
end;

end.
