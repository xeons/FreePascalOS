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
  Searching inside an archive (a ZIP or tar file browsed like a folder):
  every item below one of its folders, at any depth, whose name and
  properties match the query (FileManager.SearchQuery), as the folder
  search does on disk. Hidden items (a part of the path below that
  folder starting with a dot) only on request. The contents are not
  looked at here: the searcher reads the members it finds for content
  terms. Plain logic over an archive reader, checked on the host (make
  files-test).
}
unit FileManager.ArchiveSearch;

{$mode objfpc}
{$H+}

interface

uses
  Archive.Readers,
  Archive.Folders,
  FileManager.SearchQuery;

{ The items below FolderPath ('' for the top) that match Query (but for
  its content terms), in archive order. }
function FindInArchive(Reader: TArchiveReader; const FolderPath: string; const Query: TSearchQuery;
  IncludeHidden: Boolean): TArchiveFolderItems;
{ Whether some part of an archive path ("a/.b/c") is hidden. }
function IsHiddenArchivePath(const Path: string): Boolean;

implementation

uses
  Archive.Entries;

function IsHiddenArchivePath(const Path: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Path) do
    if (Path[Index] = '.') and ((Index = 1) or (Path[Index - 1] = '/')) then
      Exit(True);
  Result := False;
end;

function FindInArchive(Reader: TArchiveReader; const FolderPath: string; const Query: TSearchQuery;
  IncludeHidden: Boolean): TArchiveFolderItems;
var
  Items: TArchiveFolderItems;
  Index, Count: Integer;
  Size: QWord;
  ModificationTime: Int64;
  Entry: TArchiveEntry;
  PrefixLength: Integer;
  Below: string;
begin
  Result := nil;
  { (Hidden counts below the folder searched, as on disk.) }
  PrefixLength := Length(SafeEntryPath(FolderPath));
  if PrefixLength > 0 then
    Inc(PrefixLength);
  Items := ListArchiveTree(Reader, FolderPath);
  SetLength(Result, Length(Items));
  Count := 0;
  for Index := 0 to High(Items) do
  begin
    Below := Copy(Items[Index].Path, PrefixLength + 1, Length(Items[Index].Path));
    if not IncludeHidden and IsHiddenArchivePath(Below) then
      Continue;
    Size := 0;
    ModificationTime := 0;
    if Items[Index].EntryIndex >= 0 then
    begin
      Entry := Reader.Entries[Items[Index].EntryIndex];
      Size := Entry.Size;
      ModificationTime := Entry.ModificationTime;
    end;
    if MatchesQuery(Query, Items[Index].Name, Items[Index].IsFolder, Size, ModificationTime) then
    begin
      Result[Count] := Items[Index];
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
end;

end.
