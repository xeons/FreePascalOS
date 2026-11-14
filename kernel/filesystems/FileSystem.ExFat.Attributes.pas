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
  Attributes and free space for exFAT.

  As with FAT, permissions map onto the read-only attribute and owners
  are not supported. Times are written in UTC with a valid UTC offset of
  zero.
}
unit FileSystem.ExFat.Attributes;

{$mode objfpc}

interface

uses
  FileSystem.Types;

function ExFatSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
function ExFatGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;

implementation

uses
  Runtime.Time,
  FileSystem.ExFat.Structures,
  FileSystem.ExFat.Volume,
  FileSystem.ExFat.Write;

const
  AnyWritePermission = $92;
  ModeReadOnly = $124;
  ModeWritable = $1A4;

function ToTimestamp(Time: TUnixTime): LongWord;
var
  DateWord: Word;
  TimeWord: Word;
begin
  UnixTimeToDosDateTime(Time, DateWord, TimeWord);
  Result := (LongWord(DateWord) shl 16) or TimeWord;
end;

function ExFatSetAttributes(Node: PNode; const Changes: TAttributeChanges): TFileSystemStatus;
var
  ExFatNode: PExFatNode;
  EntrySet: TEntrySet;
  EntryIndex: Integer;
  FileEntry: PFileEntry;
begin
  ExFatNode := PExFatNode(Node);
  if ExFatNode^.IsRoot then
    Exit(StatusUnsupported);
  if (((Changes.Fields and AttributeChangeOwner) <> 0) and (Changes.OwnerId <> 0)) or
     (((Changes.Fields and AttributeChangeGroup) <> 0) and (Changes.GroupId <> 0)) then
    Exit(StatusUnsupported);

  Result := BeginModification(Node^.Volume);
  if Result <> StatusSuccess then
    Exit;
  for EntryIndex := 0 to ExFatNode^.SetEntryCount - 1 do
  begin
    if not VolumeRead(Node^.Volume, ExFatNode^.SetEntryOffsets[EntryIndex], DirectoryEntrySize,
      @EntrySet[EntryIndex][0]) then
      Exit(StatusIoError);
  end;
  FileEntry := PFileEntry(@EntrySet[0][0]);
  if FileEntry^.EntryType <> EntryTypeFile then
    Exit(StatusCorrupted);

  if (Changes.Fields and AttributeChangeMode) <> 0 then
  begin
    if (Changes.Mode and AnyWritePermission) = 0 then
    begin
      FileEntry^.FileAttributes := FileEntry^.FileAttributes or AttributeReadOnly;
      Node^.Information.Mode := ModeReadOnly;
    end
    else
    begin
      FileEntry^.FileAttributes := FileEntry^.FileAttributes and not AttributeReadOnly;
      Node^.Information.Mode := ModeWritable;
    end;
    if Node^.Information.Kind = NodeKindDirectory then
      Node^.Information.Mode := Node^.Information.Mode or $49;
  end;
  if (Changes.Fields and AttributeChangeModificationTime) <> 0 then
  begin
    FileEntry^.LastModifiedTimestamp := ToTimestamp(Changes.ModificationTime);
    FileEntry^.LastModified10ms := 0;
    FileEntry^.LastModifiedUtcOffset := UtcOffsetValid;
    Node^.Information.ModificationTime := Changes.ModificationTime and not Int64(1);
    Node^.Information.ChangeTime := Node^.Information.ModificationTime;
  end;
  if (Changes.Fields and AttributeChangeAccessTime) <> 0 then
  begin
    FileEntry^.LastAccessedTimestamp := ToTimestamp(Changes.AccessTime);
    FileEntry^.LastAccessedUtcOffset := UtcOffsetValid;
    Node^.Information.AccessTime := Changes.AccessTime and not Int64(1);
  end;

  FileEntry^.SetChecksum := ComputeSetChecksum(EntrySet, ExFatNode^.SetEntryCount);
  for EntryIndex := 0 to ExFatNode^.SetEntryCount - 1 do
  begin
    if not VolumeWrite(Node^.Volume, ExFatNode^.SetEntryOffsets[EntryIndex], DirectoryEntrySize,
      @EntrySet[EntryIndex][0]) then
      Exit(StatusIoError);
  end;
  Result := StatusSuccess;
end;

function ExFatGetFreeSpace(Volume: PVolume; out FreeBytes: QWord): TFileSystemStatus;
var
  ExFat: PExFatVolume;
begin
  FreeBytes := 0;
  ExFat := PExFatVolume(Volume^.DriverData);
  if Volume^.IsReadOnly then
  begin
    Result := CountFreeClusters(Volume);
    if Result <> StatusSuccess then
      Exit;
  end;
  FreeBytes := QWord(ExFat^.FreeClusterCount) * ExFat^.BytesPerCluster;
  Result := StatusSuccess;
end;

end.
