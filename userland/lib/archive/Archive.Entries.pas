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
  What every archive format describes its members with: the entry
  record, the errors, the progress callback, the Unix mode bits and
  SafeEntryPath, which decides whether a member's name may be
  extracted.
}
unit Archive.Entries;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  { The file type in the high bits of a Unix mode. }
  ModeTypeMask = $F000;
  ModeRegularFile = $8000;
  ModeFolder = $4000;
  ModeSymbolicLink = $A000;
  { The permission bits (without set-user-id, set-group-id and sticky). }
  ModePermissionMask = $1FF;
  ModeDefaultFile = ModeRegularFile or $1A4;   { rw-r--r-- }
  ModeDefaultFolder = ModeFolder or $1ED;      { rwxr-xr-x }
  ModeDefaultLink = ModeSymbolicLink or $1FF;  { rwxrwxrwx }

  { Methods (the zip numbers; tar members are stored). }
  MethodStored = 0;
  MethodDeflated = 8;

type
  TArchiveEntry = record
    { UTF-8, '/' between the parts; a folder's name ends with '/'. }
    Name: string;
    IsFolder: Boolean;
    IsLink: Boolean;
    { What a symbolic link points to. }
    LinkTarget: string;
    { Uncompressed. }
    Size: QWord;
    CompressedSize: QWord;
    { Unix seconds, UTC. }
    ModificationTime: Int64;
    { Unix mode bits with the file type, or 0 if the archive says none. }
    Mode: LongWord;
    Encrypted: Boolean;
    Method: Word;
    Crc32: LongWord;
  end;

  TArchiveEntryArray = array of TArchiveEntry;

  EArchiveError = class(Exception);
  { Raised when a progress callback asked to stop. }
  EArchiveCancelled = class(EArchiveError);

  { Called as data goes through: BytesDone counts the uncompressed bytes
    of the whole operation so far. Setting Cancel stops it with
    EArchiveCancelled. }
  TArchiveProgressEvent = procedure(BytesDone: QWord; var Cancel: Boolean) of object;

{ The relative path a member may be extracted to, '/' between the parts,
  without '.' parts, empty parts or a final '/'; '\' counts as '/'. ''
  when the name is empty, absolute (a leading '/' or a drive letter),
  has a '..' part or a control character. }
function SafeEntryPath(const Name: string): string;

{ Whether a name ends with '/'. }
function NameIsFolder(const Name: string): Boolean;

implementation

function NameIsFolder(const Name: string): Boolean;
begin
  Result := (Length(Name) > 0) and (Name[Length(Name)] = '/');
end;

function HasControlCharacter(const Name: string): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to Length(Name) do
    if (Ord(Name[Index]) < 32) or (Ord(Name[Index]) = 127) then
      Exit(True);
end;

function HasDriveLetter(const Name: string): Boolean;
begin
  Result := (Length(Name) >= 2) and (Name[2] = ':') and (UpCase(Name[1]) in ['A'..'Z']);
end;

function SafeEntryPath(const Name: string): string;
var
  Cleaned, Part: string;
  Index, PartStart: Integer;
begin
  Result := '';
  if (Name = '') or HasControlCharacter(Name) then
    Exit;
  Cleaned := StringReplace(Name, '\', '/', [rfReplaceAll]);
  if (Cleaned[1] = '/') or HasDriveLetter(Cleaned) then
    Exit;
  Cleaned := Cleaned + '/';
  PartStart := 1;
  for Index := 1 to Length(Cleaned) do
    if Cleaned[Index] = '/' then
    begin
      Part := Copy(Cleaned, PartStart, Index - PartStart);
      PartStart := Index + 1;
      if (Part = '') or (Part = '.') then
        Continue;
      if Part = '..' then
        Exit('');
      if Result <> '' then
        Result := Result + '/';
      Result := Result + Part;
    end;
end;

end.
