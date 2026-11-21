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
  The file manager test's checks of searching inside an archive
  (FileManager.ArchiveSearch, over Archive.Folders' ListArchiveTree): a
  ZIP file written here, with folders that have members and folders
  only deeper names make, searched from its top and from a folder in
  it, with the search syntax.
}
unit FilesTest.ArchiveSearch;

{$mode objfpc}
{$H+}

interface

uses
  FilesTest.Explorer;

procedure TestArchiveSearch(Check: TCheckProcedure);

implementation

uses
  Classes,
  SysUtils,
  Archive.Readers,
  Archive.Folders,
  Archive.ZipWriter,
  FileManager.SearchQuery,
  FileManager.ArchiveSearch;

const
  { 2026-11-21 12:00 UTC. }
  Noon = 1795262400;

procedure AddText(Writer: TZipWriter; const Name, Text: string);
var
  Stream: TStringStream;
begin
  Stream := TStringStream.Create(Text);
  try
    Writer.AddStream(Stream, Name, Noon, 0);
  finally
    Stream.Free;
  end;
end;

function WriteSampleArchive: string;
var
  Writer: TZipWriter;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'files-test-search-' + IntToStr(GetProcessID) + '.zip';
  Writer := TZipWriter.Create(Result);
  try
    Writer.AddFolder('tree', Noon, 0);
    { No members for tree/a and tree/a/b: only this name makes them. }
    AddText(Writer, 'tree/a/b/deep.txt', 'deep');
    AddText(Writer, 'tree/big.bin', 'a long enough text');
    AddText(Writer, 'tree/.hidden/deep.cfg', 'hidden');
    AddText(Writer, 'other/deep-two.txt', 'two');
    AddText(Writer, 'notes.txt', 'notes');
    Writer.Finish;
  finally
    Writer.Free;
  end;
end;

function Query(const Text: string): TSearchQuery;
begin
  Result := ParseSearchQuery(Text, Noon, 0);
end;

function HasPath(const Items: TArchiveFolderItems; const Path: string): Boolean;
var
  Item: TArchiveFolderItem;
begin
  for Item in Items do
    if Item.Path = Path then
      Exit(True);
  Result := False;
end;

function IndexOfPath(const Items: TArchiveFolderItems; const Path: string): Integer;
begin
  Result := 0;
  while Result < Length(Items) do
  begin
    if Items[Result].Path = Path then
      Exit;
    Inc(Result);
  end;
  Result := -1;
end;

procedure TestArchiveSearch(Check: TCheckProcedure);
var
  Path: string;
  Reader: TArchiveReader;
  Found: TArchiveFolderItems;
  Tree: TArchiveFolderItems;
begin
  Path := WriteSampleArchive;
  Reader := OpenArchive(Path);
  try
    Tree := ListArchiveTree(Reader, 'tree');
    Check('archive search: the tree below a folder, made-up folders before what is in them',
      (Length(Tree) = 6) and (IndexOfPath(Tree, 'tree/a/') >= 0) and
      (IndexOfPath(Tree, 'tree/a/') < IndexOfPath(Tree, 'tree/a/b/')) and
      (IndexOfPath(Tree, 'tree/a/b/') < IndexOfPath(Tree, 'tree/a/b/deep.txt')) and
      not HasPath(Tree, 'notes.txt'));
    Found := FindInArchive(Reader, '', Query('deep'), False);
    Check('archive search: a word found at any depth, hidden parts left out',
      (Length(Found) = 2) and HasPath(Found, 'tree/a/b/deep.txt') and HasPath(Found, 'other/deep-two.txt'));
    Check('archive search: a found member knows its index and name',
      (Found[0].EntryIndex >= 0) and (Found[0].Name = 'deep.txt') and not Found[0].IsFolder);
    Found := FindInArchive(Reader, '', Query('deep'), True);
    Check('archive search: hidden items on request', (Length(Found) = 3) and HasPath(Found, 'tree/.hidden/deep.cfg'));
    Found := FindInArchive(Reader, 'tree', Query('deep'), False);
    Check('archive search: scoped to a folder inside the archive',
      (Length(Found) = 1) and (Found[0].Path = 'tree/a/b/deep.txt'));
    Found := FindInArchive(Reader, 'tree/.hidden/', Query('deep'), False);
    Check('archive search: inside a hidden folder its items are not hidden',
      (Length(Found) = 1) and (Found[0].Path = 'tree/.hidden/deep.cfg'));
    Found := FindInArchive(Reader, '', Query('kind:folder b'), False);
    Check('archive search: a folder only deeper names make is found',
      (Length(Found) = 1) and (Found[0].Path = 'tree/a/b/') and Found[0].IsFolder and (Found[0].EntryIndex < 0));
    Found := FindInArchive(Reader, '', Query('deep*.txt'), False);
    Check('archive search: wildcards', (Length(Found) = 2));
    Found := FindInArchive(Reader, '', Query('ext:bin size:>10'), False);
    Check('archive search: extension and size filters',
      (Length(Found) = 1) and (Found[0].Path = 'tree/big.bin'));
    Found := FindInArchive(Reader, '', Query('ext:bin size:>100'), False);
    Check('archive search: too small', Length(Found) = 0);
    Found := FindInArchive(Reader, '', Query('modified:today notes'), False);
    Check('archive search: the members'' times', (Length(Found) = 1) and (Found[0].Path = 'notes.txt'));
  finally
    Reader.Free;
    DeleteFile(Path);
  end;
end;

end.
