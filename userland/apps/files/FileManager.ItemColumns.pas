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
  The columns the details view can show, and how entries sort by each:
  name (natural order: "2" before "10"), date modified, type, size, and
  on request (the header's context menu) date created, date accessed,
  owner, group, permissions, dimensions (pictures), length (sounds), the
  folder an item is in (search results, recent files), where a deleted
  item was and when it was deleted (the recycle bin), and a volume's
  free space and file system (the Computer page).

  Folders come first either way round; equal entries keep name order.
  The texts are for the cells; the comparisons use the values.
}
unit FileManager.ItemColumns;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Entries;

type
  TColumnKind = (ColumnName, ColumnModified, ColumnType, ColumnSize, ColumnCreated, ColumnAccessed, ColumnOwner,
    ColumnGroup, ColumnPermissions, ColumnDimensions, ColumnDuration, ColumnFolder, ColumnOriginalLocation,
    ColumnDeleted, ColumnFreeSpace, ColumnFileSystem);
  TColumnKinds = set of TColumnKind;

const
  ColumnCaptions: array[TColumnKind] of string = ('Name', 'Date modified', 'Type', 'Size', 'Date created',
    'Date accessed', 'Owner', 'Group', 'Permissions', 'Dimensions', 'Length', 'Folder', 'Original location',
    'Date deleted', 'Free space', 'File system');
  ColumnKeys: array[TColumnKind] of string = ('name', 'modified', 'type', 'size', 'created', 'accessed', 'owner',
    'group', 'permissions', 'dimensions', 'length', 'folder', 'original', 'deleted', 'free', 'filesystem');
  ColumnWidths: array[TColumnKind] of LongInt = (220, 130, 120, 80, 130, 130, 80, 80, 90, 90, 70, 220, 220, 130, 160,
    90);
  { Right-aligned (numbers). }
  NumericColumns: TColumnKinds = [ColumnSize, ColumnDimensions, ColumnDuration, ColumnFreeSpace];
  { What a folder shows unless chosen otherwise. }
  DefaultColumns: TColumnKinds = [ColumnName, ColumnModified, ColumnType, ColumnSize];

function ColumnText(Entry: TFolderEntry; Column: TColumnKind): string;
{ Negative if First goes before Second (ascending); folders first. }
function CompareEntries(First, Second: TFolderEntry; Column: TColumnKind; Ascending: Boolean): LongInt;
function ColumnNamed(const Key: string; out Column: TColumnKind): Boolean;
function OwnerName(OwnerId: LongWord): string;
function GroupName(GroupId: LongWord): string;
function DurationText(Seconds: LongInt): string;
function EntryTypeText(Entry: TFolderEntry): string;

implementation

uses
  SysUtils,
  Util.Accounts,
  Util.Trash,
  Controls.NaturalOrder,
  Controls.FolderListing,
  Controls.FileNames,
  FileManager.Items,
  FileManager.FileTypes,
  FileManager.TimeTexts,
  FileManager.Permissions,
  FileManager.Paths;

type
  { Controls.FolderListing has a TFolderEntry of its own. }
  TFolderEntry = FileManager.Entries.TFolderEntry;

function OwnerName(OwnerId: LongWord): string;
begin
  if not FindUserName(OwnerId, Result) or (Result = '') then
    Result := IntToStr(OwnerId);
end;

function GroupName(GroupId: LongWord): string;
begin
  if not FindGroupName(GroupId, Result) or (Result = '') then
    Result := IntToStr(GroupId);
end;

function DurationText(Seconds: LongInt): string;
begin
  if Seconds < 0 then
    Exit('');
  if Seconds >= 3600 then
    Result := Format('%d:%.2d:%.2d', [Seconds div 3600, (Seconds div 60) mod 60, Seconds mod 60])
  else
    Result := Format('%d:%.2d', [Seconds div 60, Seconds mod 60]);
end;

function EntryTypeText(Entry: TFolderEntry): string;
begin
  case Entry.Kind of
    EntryVolume:
      if Entry.IsRemovable then
        Result := 'Removable disk'
      else
        Result := 'Local disk';
    EntryPlace: Result := 'Folder';
  else
    Result := TypeTextOf(Entry.Item);
  end;
end;

function DeletedTime(Entry: TFolderEntry): Int64;
begin
  Result := Entry.Trashed.DeletionLocalTime;
end;

function ColumnText(Entry: TFolderEntry; Column: TColumnKind): string;
begin
  Result := '';
  case Column of
    ColumnName: Result := Entry.Item.Name;
    ColumnModified:
      if (Entry.Kind <> EntryVolume) and (Entry.Item.ModificationTime <> 0) then
        Result := TimeText(Entry.Item.ModificationTime);
    ColumnType: Result := EntryTypeText(Entry);
    ColumnSize:
      if Entry.Kind = EntryVolume then
        Result := SizeText(Entry.TotalBytes)
      else if Entry.Item.Kind = ItemFile then
        Result := SizeText(Entry.Item.SizeInBytes);
    ColumnCreated:
      if Entry.Item.BirthTime <> 0 then
        Result := TimeText(Entry.Item.BirthTime);
    ColumnAccessed:
      if Entry.Item.AccessTime <> 0 then
        Result := TimeText(Entry.Item.AccessTime);
    ColumnOwner:
      if Entry.Kind in [EntryFile, EntryTrashed] then
        Result := OwnerName(Entry.Item.OwnerId);
    ColumnGroup:
      if Entry.Kind in [EntryFile, EntryTrashed] then
        Result := GroupName(Entry.Item.GroupId);
    ColumnPermissions:
      if Entry.Kind in [EntryFile, EntryTrashed, EntryArchived] then
        Result := PermissionText(Entry.Item.Mode);
    ColumnDimensions:
      if (Entry.PictureWidth > 0) and (Entry.PictureHeight > 0) then
        Result := IntToStr(Entry.PictureWidth) + ' x ' + IntToStr(Entry.PictureHeight);
    ColumnDuration: Result := DurationText(Entry.DurationSeconds);
    ColumnFolder: Result := Entry.Folder;
    ColumnOriginalLocation:
      if Entry.Kind = EntryTrashed then
        Result := ParentFolderOf(Entry.Trashed.OriginalPath);
    ColumnDeleted:
      if Entry.Kind = EntryTrashed then
        { The trash keeps local times: shown as they are. }
        Result := FormatDateTime('yyyy-mm-dd hh:nn', DeletedTime(Entry) / 86400 + 25569);
    ColumnFreeSpace:
      if Entry.Kind = EntryVolume then
        Result := SizeText(Entry.FreeBytes) + ' free of ' + SizeText(Entry.TotalBytes);
    ColumnFileSystem: Result := Entry.FileSystemType;
  end;
end;

function CompareNumbers(First, Second: Int64): LongInt;
begin
  if First < Second then
    Result := -1
  else if First > Second then
    Result := 1
  else
    Result := 0;
end;

function EntrySize(Entry: TFolderEntry): Int64;
begin
  if Entry.Kind = EntryVolume then
    Result := Entry.TotalBytes
  else if Entry.IsFolder then
    Result := -1
  else
    Result := Entry.Item.SizeInBytes;
end;

function CompareEntries(First, Second: TFolderEntry; Column: TColumnKind; Ascending: Boolean): LongInt;
begin
  if First.IsFolder <> Second.IsFolder then
  begin
    if First.IsFolder then
      Exit(-1);
    Exit(1);
  end;
  case Column of
    ColumnModified: Result := CompareNumbers(First.Item.ModificationTime, Second.Item.ModificationTime);
    ColumnType: Result := CompareText(EntryTypeText(First), EntryTypeText(Second));
    ColumnSize: Result := CompareNumbers(EntrySize(First), EntrySize(Second));
    ColumnCreated: Result := CompareNumbers(First.Item.BirthTime, Second.Item.BirthTime);
    ColumnAccessed: Result := CompareNumbers(First.Item.AccessTime, Second.Item.AccessTime);
    ColumnPermissions: Result := CompareNumbers(First.Item.Mode and $FFF, Second.Item.Mode and $FFF);
    ColumnDimensions: Result := CompareNumbers(Int64(First.PictureWidth) * First.PictureHeight,
      Int64(Second.PictureWidth) * Second.PictureHeight);
    ColumnDuration: Result := CompareNumbers(First.DurationSeconds, Second.DurationSeconds);
    ColumnDeleted: Result := CompareNumbers(DeletedTime(First), DeletedTime(Second));
    ColumnFreeSpace: Result := CompareNumbers(First.FreeBytes, Second.FreeBytes);
    ColumnName: Result := 0;
  else
    Result := NaturalCompare(ColumnText(First, Column), ColumnText(Second, Column));
  end;
  if Result = 0 then
    Result := NaturalCompare(First.Item.Name, Second.Item.Name);
  if not Ascending then
    Result := -Result;
end;

function ColumnNamed(const Key: string; out Column: TColumnKind): Boolean;
var
  Each: TColumnKind;
begin
  for Each := Low(TColumnKind) to High(TColumnKind) do
    if ColumnKeys[Each] = Key then
    begin
      Column := Each;
      Exit(True);
    end;
  Column := ColumnName;
  Result := False;
end;

end.
