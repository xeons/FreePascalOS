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
  The order a folder's items are shown in: by name, size, type, time
  modified, permissions or owner, either way round, folders always
  before files (whichever way the rest goes), and items equal in the
  chosen column by name. Names compare without regard to case first
  (A to Z), then with it, so "Notes" and "notes" keep a fixed order.

  Plain logic: owners' names come through a routine, so the host checks
  it (make files-test).
}
unit FileManager.ItemOrder;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Items;

type
  TSortColumn = (SortByName, SortBySize, SortByType, SortByModified, SortByPermissions, SortByOwner);
  TOwnerNameFunction = function(OwnerId: LongWord): string of object;

{ Negative if First goes before Second. OwnerName may be nil (owners
  then compare by number). }
function CompareFolderItems(const First, Second: TFolderItem; Column: TSortColumn; Ascending: Boolean;
  OwnerName: TOwnerNameFunction): LongInt;
function CompareNames(const First, Second: string): LongInt;

implementation

uses
  SysUtils,
  FileManager.FileTypes;

function CompareNumbers(First, Second: Int64): LongInt;
begin
  if First < Second then
    Result := -1
  else if First > Second then
    Result := 1
  else
    Result := 0;
end;

function CompareNames(const First, Second: string): LongInt;
begin
  Result := CompareText(First, Second);
  if Result = 0 then
    Result := CompareStr(First, Second);
end;

function CompareOwners(const First, Second: TFolderItem; OwnerName: TOwnerNameFunction): LongInt;
begin
  if Assigned(OwnerName) then
    Result := CompareText(OwnerName(First.OwnerId), OwnerName(Second.OwnerId))
  else
    Result := CompareNumbers(First.OwnerId, Second.OwnerId);
end;

function CompareFolderItems(const First, Second: TFolderItem; Column: TSortColumn; Ascending: Boolean;
  OwnerName: TOwnerNameFunction): LongInt;
begin
  { Folders first, either way round. }
  if IsFolderItem(First) <> IsFolderItem(Second) then
  begin
    if IsFolderItem(First) then
      Exit(-1);
    Exit(1);
  end;
  case Column of
    SortBySize:
      if IsFolderItem(First) then
        Result := 0
      else
        Result := CompareNumbers(First.SizeInBytes, Second.SizeInBytes);
    SortByType: Result := CompareText(TypeTextOf(First), TypeTextOf(Second));
    SortByModified: Result := CompareNumbers(First.ModificationTime, Second.ModificationTime);
    SortByPermissions: Result := CompareNumbers(First.Mode and $FFF, Second.Mode and $FFF);
    SortByOwner: Result := CompareOwners(First, Second, OwnerName);
  else
    Result := 0;
  end;
  if Result = 0 then
    Result := CompareNames(First.Name, Second.Name);
  if not Ascending then
    Result := -Result;
end;

end.
