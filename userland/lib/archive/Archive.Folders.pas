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
  Browsing an archive like a folder: what is directly in one of its
  folders. Many archives have no members for their folders, only
  "a/b/file" names, so folders are also made up from the names below
  them. Names are taken as SafeEntryPath gives them; members it refuses
  are not shown.
}
unit Archive.Folders;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Entries,
  Archive.Readers;

type
  TArchiveFolderItem = record
    { The item's own name (no '/'). }
    Name: string;
    { Its path in the archive: "a/b/name", with a final '/' for a folder. }
    Path: string;
    IsFolder: Boolean;
    { The member, or -1 for a folder that only names below it make. }
    EntryIndex: Integer;
  end;

  TArchiveFolderItems = array of TArchiveFolderItem;

{ The items directly in FolderPath ('' for the top; with or without a
  final '/'), in archive order. }
function ListArchiveFolder(Reader: TArchiveReader; const FolderPath: string): TArchiveFolderItems;

implementation

function ListArchiveFolder(Reader: TArchiveReader; const FolderPath: string): TArchiveFolderItems;
var
  Prefix, Path, Rest, ChildName: string;
  SlashPosition, Index, Found, ItemCount: Integer;
  Seen: TStringList;
  Entry: TArchiveEntry;
  ChildIsFolder: Boolean;
  Item: TArchiveFolderItem;
begin
  Result := nil;
  ItemCount := 0;
  Prefix := SafeEntryPath(FolderPath);
  if Prefix <> '' then
    Prefix := Prefix + '/';
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    for Index := 0 to Reader.Count - 1 do
    begin
      Entry := Reader.Entries[Index];
      Path := SafeEntryPath(Entry.Name);
      if (Path = '') or (Copy(Path, 1, Length(Prefix)) <> Prefix) or (Length(Path) = Length(Prefix)) then
        Continue;
      Rest := Copy(Path, Length(Prefix) + 1, Length(Path));
      SlashPosition := Pos('/', Rest);
      if SlashPosition > 0 then
      begin
        ChildName := Copy(Rest, 1, SlashPosition - 1);
        ChildIsFolder := True;
      end
      else
      begin
        ChildName := Rest;
        ChildIsFolder := Entry.IsFolder;
      end;
      if Seen.Find(ChildName, Found) then
      begin
        Found := PtrInt(Seen.Objects[Found]);
        if (SlashPosition = 0) and (Result[Found].EntryIndex < 0) and ChildIsFolder then
          Result[Found].EntryIndex := Index;
        Continue;
      end;
      Item.Name := ChildName;
      Item.Path := Prefix + ChildName;
      if ChildIsFolder then
        Item.Path := Item.Path + '/';
      Item.IsFolder := ChildIsFolder;
      if SlashPosition = 0 then
        Item.EntryIndex := Index
      else
        Item.EntryIndex := -1;
      if ItemCount >= Length(Result) then
        SetLength(Result, 2 * ItemCount + 16);
      Result[ItemCount] := Item;
      Seen.AddObject(ChildName, TObject(PtrInt(ItemCount)));
      Inc(ItemCount);
    end;
  finally
    Seen.Free;
  end;
  SetLength(Result, ItemCount);
end;

end.
