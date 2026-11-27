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
  One thing a page shows: a file or folder (in the folder shown, or
  anywhere: a search result, a recent file, a pinned folder, a photo of
  the gallery), an item in the recycle bin, an entry of an archive, or
  a volume (the Computer page). What the columns, the groups, the
  details pane and the commands need to know of it.

  FullPath is where it really is (for opening, copying, dragging); for
  an archive entry it is the archive's path with the entry's inside it,
  for an item in the recycle bin its place in the trash.
}
unit FileManager.Entries;

{$mode objfpc}
{$H+}

interface

uses
  Util.Trash,
  FileManager.Items;

type
  TEntryKind = (EntryFile, EntryTrashed, EntryArchived, EntryVolume, EntryPlace);

  TFolderEntry = class
  public
    Kind: TEntryKind;
    Item: TFolderItem;
    FullPath: string;
    { The folder it is in (shown in search results and recent files). }
    Folder: string;
    { Picture size in pixels (0 until known: a thumbnail tells it). }
    PictureWidth: LongInt;
    PictureHeight: LongInt;
    { A sound's length in seconds (-1 when not known). }
    DurationSeconds: LongInt;
    { EntryTrashed. }
    Trashed: TTrashItem;
    { EntryArchived: the entry's index in the archive (-1: a folder only
      implied by deeper names) and its path inside it. }
    ArchiveIndex: LongInt;
    InnerPath: string;
    { EntryArchived: the archive file it is in. }
    ArchivePath: string;
    { EntryVolume. }
    VolumeName: string;
    FileSystemType: string;
    TotalBytes: QWord;
    FreeBytes: QWord;
    IsRemovable: Boolean;
    { EntryPlace: the address it leads to (a page or a folder). }
    Address: string;
    IconName: string;
    { The section a page puts it in (Home: "Pinned", "Favorites",
      "Recent"; Computer: "Folders", "Devices and drives"); '' in a
      folder, whose groups come from Group by. }
    Section: string;
    { Marked as a favourite (a star). }
    Favorite: Boolean;
    constructor Create;
    function IsFolder: Boolean;
    { Whether the commands that change files apply to it. }
    function IsRealFile: Boolean;
  end;

implementation

constructor TFolderEntry.Create;
begin
  inherited Create;
  DurationSeconds := -1;
  ArchiveIndex := -1;
end;

function TFolderEntry.IsFolder: Boolean;
begin
  Result := (Kind in [EntryVolume, EntryPlace]) or IsFolderItem(Item);
end;

function TFolderEntry.IsRealFile: Boolean;
begin
  Result := Kind = EntryFile;
end;

end.
