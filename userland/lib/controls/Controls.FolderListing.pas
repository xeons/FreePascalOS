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
  What is in a folder, ready to show: each entry's name, whether it is
  a folder, its size and what kind of thing it is, in the order a user
  expects (folders first, then files, each by name whatever the case).

  The entries "." and ".." are left out: a dialog adds its own way up.
  A symbolic link is shown as what it points to, so a link to a folder
  can be opened like one; a broken link is shown as a link.
}
unit Controls.FolderListing;

{$mode objfpc}
{$H+}

interface

type
  TFolderEntry = record
    Name: string;
    IsFolder: Boolean;
    SizeInBytes: QWord;
    { A word for the Kind column: Folder, File, Program, Link, Device... }
    KindText: string;
  end;

  TFolderEntries = array of TFolderEntry;

{ The entries of Folder, sorted; False if it cannot be read. }
function ReadFolder(const Folder: string; out Entries: TFolderEntries): Boolean;
{ A size as people read it: "512 bytes", "12 KiB", "3.4 MiB". }
function SizeText(SizeInBytes: QWord): string;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Controls.FileNames;

const
  { Any of the execute permission bits makes a file a program. }
  ExecutableBits = $49;

function KindTextFor(const Information: TFileInformation): string;
begin
  case Information.Kind of
    KindDirectory: Result := 'Folder';
    KindSymbolicLink: Result := 'Link';
    KindFifo: Result := 'Pipe';
    KindCharacterDevice, KindBlockDevice: Result := 'Device';
    KindFile:
      if (Information.Mode and ExecutableBits) <> 0 then
        Result := 'Program'
      else
        Result := 'File';
  else
    Result := 'Other';
  end;
end;

{ Describes Name in Folder; a link that leads nowhere is described as
  the link itself. }
function DescribeEntry(const Folder, Name: string): TFolderEntry;
var
  Information: TFileInformation;
  Path: string;
begin
  Result.Name := Name;
  Path := CombinePath(Folder, Name);
  if (GetFileInformation(PChar(Path), Information) <> 0) and
     (GetLinkInformation(PChar(Path), Information) <> 0) then
  begin
    Result.IsFolder := False;
    Result.SizeInBytes := 0;
    Result.KindText := 'Other';
    Exit;
  end;
  Result.IsFolder := Information.Kind = KindDirectory;
  Result.SizeInBytes := Information.SizeInBytes;
  Result.KindText := KindTextFor(Information);
end;

{ True if First goes before Second: folders first, then by name. }
function ComesBefore(const First, Second: TFolderEntry): Boolean;
var
  Comparison: LongInt;
begin
  if First.IsFolder <> Second.IsFolder then
    Exit(First.IsFolder);
  Comparison := CompareText(First.Name, Second.Name);
  if Comparison = 0 then
    Comparison := CompareStr(First.Name, Second.Name);
  Result := Comparison < 0;
end;

{ Insertion sort: folders hold tens or hundreds of entries, and it keeps
  equal entries in the order they came. }
procedure SortEntries(var Entries: TFolderEntries);
var
  Index: LongInt;
  Place: LongInt;
  Moving: TFolderEntry;
begin
  for Index := 1 to High(Entries) do
  begin
    Moving := Entries[Index];
    Place := Index;
    while (Place > 0) and ComesBefore(Moving, Entries[Place - 1]) do
    begin
      Entries[Place] := Entries[Place - 1];
      Dec(Place);
    end;
    Entries[Place] := Moving;
  end;
end;

function ReadFolder(const Folder: string; out Entries: TFolderEntries): Boolean;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Name: string;
  Count: LongInt;
begin
  Entries := nil;
  Handle := OpenFile(PChar(Folder), OpenRead);
  if Handle < 0 then
    Exit(False);
  Count := 0;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    Name := StrPas(@Entry.Name[0]);
    if (Name = '.') or (Name = '..') then
      Continue;
    if Count = Length(Entries) then
      SetLength(Entries, Count * 2 + 16);
    Entries[Count] := DescribeEntry(Folder, Name);
    Inc(Count);
  end;
  CloseFile(Handle);
  SetLength(Entries, Count);
  SortEntries(Entries);
  Result := True;
end;

{ Size in Units, with one decimal: "3.4". }
function WithOneDecimal(SizeInBytes, UnitSize: QWord): string;
var
  Tenths: QWord;
begin
  Tenths := SizeInBytes * 10 div UnitSize;
  Result := IntToStr(Tenths div 10) + '.' + IntToStr(Tenths mod 10);
end;

function SizeText(SizeInBytes: QWord): string;
const
  Kibibyte = QWord(1024);
  Mebibyte = QWord(1024 * 1024);
  Gibibyte = QWord(1024 * 1024 * 1024);
begin
  if SizeInBytes = 1 then
    Result := '1 byte'
  else if SizeInBytes < Kibibyte then
    Result := IntToStr(SizeInBytes) + ' bytes'
  else if SizeInBytes < 10 * Kibibyte then
    Result := WithOneDecimal(SizeInBytes, Kibibyte) + ' KiB'
  else if SizeInBytes < Mebibyte then
    Result := IntToStr(SizeInBytes div Kibibyte) + ' KiB'
  else if SizeInBytes < 10 * Mebibyte then
    Result := WithOneDecimal(SizeInBytes, Mebibyte) + ' MiB'
  else if SizeInBytes < Gibibyte then
    Result := IntToStr(SizeInBytes div Mebibyte) + ' MiB'
  else
    Result := WithOneDecimal(SizeInBytes, Gibibyte) + ' GiB';
end;

end.
