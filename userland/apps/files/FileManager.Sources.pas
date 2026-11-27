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
  What each page shows, read into entries (FileManager.Entries):

  * a folder: its items;
  * Home: the pinned folders, the favourite files and the recent files
    (those still there), each in its section;
  * Gallery: the pictures in the Pictures folder and those pinned below
    it, every level down (at most MostGalleryPictures), grouped by month;
  * Computer: the standard folders, then every volume ("Devices and
    drives": its label, file system, size and free space; where it is
    mounted on a folder, that is where it opens);
  * Network: nothing yet (a page saying so);
  * the recycle bin: what is in every trash folder (Util.Trash);
  * an archive's folder: its entries (libarchive), the archive kept open
    while it is shown (OpenArchiveCached).

  Search results come from FileManager.Searcher instead.
}
unit FileManager.Sources;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Archive.Readers,
  Archive.Folders,
  FileManager.Entries,
  FileManager.Locations;

const
  MostGalleryPictures = 4000;
  SectionPinned = 'Pinned';
  SectionFavorites = 'Favorites';
  SectionRecent = 'Recent';
  SectionFolders = 'Folders';
  SectionDrives = 'Devices and drives';

{ Reads what Location shows into Entries (a list of TFolderEntry the
  caller frees); ErrorNone or why it could not be read. }
function ReadLocationEntries(const Location: TLocation; ShowHidden: Boolean; ShowRecent, ShowFavorites: Boolean;
  Entries: TList): LongInt;
{ An entry for the item at Path (nil if it is not there). }
function EntryForPath(const Path: string): TFolderEntry;
{ The archive at Path, opened once and kept until another is asked for
  (nil and Error if it cannot be read). }
function OpenArchiveCached(const Path: string; out Error: string): TArchiveReader;
procedure ForgetCachedArchive;
{ An entry for an item of the archive at ArchivePath (Reader has it
  open); ArchiveTime is the archive file's own modification time, for
  folders only names below them make. }
function ArchivedEntry(Reader: TArchiveReader; const ArchivePath: string; const Item: TArchiveFolderItem;
  ArchiveTime: Int64): TFolderEntry;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Volumes,
  Sys.Mounts,
  Util.Trash,
  Archive.Entries,
  Controls.FileNames,
  FileManager.Items,
  FileManager.Paths,
  FileManager.FileKinds,
  FileManager.FolderReading,
  FileManager.UserLists;

var
  CachedArchive: TArchiveReader = nil;
  CachedArchivePath: string = '';
  { What the archive file was when it was opened: a file deleted,
    replaced or changed since is opened again (or not found). }
  CachedArchiveFile: TFileInformation;

function EntryForPath(const Path: string): TFolderEntry;
var
  Item: TFolderItem;
begin
  if DescribeItem(Path, Item) <> ErrorNone then
    Exit(nil);
  Result := TFolderEntry.Create;
  Result.Kind := EntryFile;
  Result.Item := Item;
  Result.FullPath := Path;
  Result.Folder := ParentFolderOf(Path);
end;

function ReadFolder(const Folder: string; ShowHidden: Boolean; Entries: TList): LongInt;
var
  Items: TFolderItems;
  Index: LongInt;
  Entry: TFolderEntry;
begin
  Result := ReadFolderItems(Folder, ShowHidden, Items);
  for Index := 0 to High(Items) do
  begin
    Entry := TFolderEntry.Create;
    Entry.Kind := EntryFile;
    Entry.Item := Items[Index];
    Entry.FullPath := CombinePath(Folder, Items[Index].Name);
    Entry.Folder := Folder;
    Entries.Add(Entry);
  end;
end;

procedure AddListEntries(List: TUserList; const Section: string; Entries: TList);
var
  Path: string;
  Entry: TFolderEntry;
begin
  for Path in ReadUserList(List) do
  begin
    Entry := EntryForPath(Path);
    if Entry = nil then
      Continue;
    Entry.Section := Section;
    Entry.Favorite := (List = ListFavorites) or IsInUserList(ListFavorites, Path);
    Entries.Add(Entry);
  end;
end;

function ReadHome(ShowRecent, ShowFavorites: Boolean; Entries: TList): LongInt;
begin
  AddListEntries(ListPinned, SectionPinned, Entries);
  if ShowFavorites then
    AddListEntries(ListFavorites, SectionFavorites, Entries);
  if ShowRecent then
    AddListEntries(ListRecent, SectionRecent, Entries);
  Result := ErrorNone;
end;

procedure GatherPictures(const Folder: string; Depth: LongInt; Entries: TList);
var
  Items: TFolderItems;
  Index: LongInt;
  Entry: TFolderEntry;
begin
  if (Depth > 8) or (Entries.Count >= MostGalleryPictures) then
    Exit;
  if ReadFolderItems(Folder, False, Items) <> ErrorNone then
    Exit;
  for Index := 0 to High(Items) do
  begin
    if Entries.Count >= MostGalleryPictures then
      Exit;
    if (Items[Index].Kind = ItemFolder) and not Items[Index].IsLink then
      GatherPictures(CombinePath(Folder, Items[Index].Name), Depth + 1, Entries)
    else if (Items[Index].Kind = ItemFile) and (FileKindOfName(Items[Index].Name) = FileKindPicture) then
    begin
      Entry := TFolderEntry.Create;
      Entry.Kind := EntryFile;
      Entry.Item := Items[Index];
      Entry.FullPath := CombinePath(Folder, Items[Index].Name);
      Entry.Folder := Folder;
      Entries.Add(Entry);
    end;
  end;
end;

function ReadGallery(Entries: TList): LongInt;
begin
  GatherPictures(StandardFolderPath(FolderPictures), 0, Entries);
  Result := ErrorNone;
end;

function ReadComputer(Entries: TList): LongInt;
var
  Folder: TStandardFolder;
  Entry: TFolderEntry;
  Index: Integer;
  MountIndex: Integer;
  Description: TVolumeDescription;
  Mount: TMountDescription;
  Name: string;
  VolumeLabel: string;
begin
  for Folder := Low(TStandardFolder) to High(TStandardFolder) do
  begin
    Entry := EntryForPath(StandardFolderPath(Folder));
    if Entry = nil then
      Continue;
    Entry.Kind := EntryPlace;
    Entry.Address := StandardFolderPath(Folder);
    Entry.IconName := StandardFolderIcons[Folder];
    Entry.Section := SectionFolders;
    Entries.Add(Entry);
  end;
  Index := 0;
  while GetVolumeDescription(Index, Description) do
  begin
    Inc(Index);
    Entry := TFolderEntry.Create;
    Entry.Kind := EntryVolume;
    Name := StrPas(@Description.Name[0]);
    VolumeLabel := StrPas(@Description.VolumeLabel[0]);
    Entry.VolumeName := Name;
    if Description.IsSystemVolume then
      Entry.Item.Name := 'System (' + Name + ')'
    else if VolumeLabel <> '' then
      Entry.Item.Name := VolumeLabel + ' (' + Name + ')'
    else
      Entry.Item.Name := Name;
    Entry.Item.Kind := ItemFolder;
    Entry.FileSystemType := StrPas(@Description.FileSystemType[0]);
    Entry.TotalBytes := Description.TotalBytes;
    if Description.HasFreeSpace then
      Entry.FreeBytes := Description.FreeBytes;
    Entry.IsRemovable := Description.IsRemovable;
    Entry.FullPath := StrPas(@Description.MountPoint[0]);
    { Mounted on a folder too: it opens there. }
    MountIndex := 0;
    while GetMountDescription(MountIndex, Mount) do
    begin
      if (Mount.Name = Name) and Mount.IsAtDirectory then
        Entry.FullPath := Mount.MountPoint;
      Inc(MountIndex);
    end;
    Entry.Address := Entry.FullPath;
    if Entry.IsRemovable then
      Entry.IconName := 'drive-usb'
    else
      Entry.IconName := 'drive';
    Entry.Section := SectionDrives;
    Entries.Add(Entry);
  end;
  Result := ErrorNone;
end;

function ReadTrash(Entries: TList): LongInt;
var
  Trashed: TTrashItem;
  Entry: TFolderEntry;
  Item: TFolderItem;
begin
  for Trashed in ListTrash do
  begin
    if DescribeItem(TrashItemPath(Trashed), Item) <> ErrorNone then
      Continue;
    Entry := TFolderEntry.Create;
    Entry.Kind := EntryTrashed;
    Entry.Item := Item;
    Entry.Item.Name := LastPartOf(Trashed.OriginalPath);
    Entry.Trashed := Trashed;
    Entry.FullPath := TrashItemPath(Trashed);
    Entry.Folder := ParentFolderOf(Trashed.OriginalPath);
    Entries.Add(Entry);
  end;
  Result := ErrorNone;
end;

procedure ForgetCachedArchive;
begin
  FreeAndNil(CachedArchive);
  CachedArchivePath := '';
end;

function SameArchiveFile(constref Was, Now: TFileInformation): Boolean;
begin
  Result := (Was.NodeNumber = Now.NodeNumber) and (Was.VolumeNumber = Now.VolumeNumber) and
    (Was.SizeInBytes = Now.SizeInBytes) and (Was.ModificationTime = Now.ModificationTime);
end;

function OpenArchiveCached(const Path: string; out Error: string): TArchiveReader;
var
  ArchiveFile: TFileInformation;
begin
  Error := '';
  if GetFileInformation(PChar(Path), ArchiveFile) <> ErrorNone then
  begin
    ForgetCachedArchive;
    Error := 'The compressed folder is not there any more';
    Exit(nil);
  end;
  if (CachedArchive <> nil) and (CachedArchivePath = Path) and SameArchiveFile(CachedArchiveFile, ArchiveFile) then
    Exit(CachedArchive);
  ForgetCachedArchive;
  try
    CachedArchive := OpenArchive(Path);
    CachedArchivePath := Path;
    CachedArchiveFile := ArchiveFile;
  except
    on Problem: Exception do
    begin
      Error := Problem.Message;
      CachedArchive := nil;
    end;
  end;
  Result := CachedArchive;
end;

function ArchivedEntry(Reader: TArchiveReader; const ArchivePath: string; const Item: TArchiveFolderItem;
  ArchiveTime: Int64): TFolderEntry;
var
  Information: TArchiveEntry;
  Slash: LongInt;
begin
  Result := TFolderEntry.Create;
  Result.Kind := EntryArchived;
  Result.ArchivePath := ArchivePath;
  Result.Item.Name := Item.Name;
  Result.ArchiveIndex := Item.EntryIndex;
  Result.InnerPath := Item.Path;
  while (Result.InnerPath <> '') and (Result.InnerPath[Length(Result.InnerPath)] = '/') do
    Delete(Result.InnerPath, Length(Result.InnerPath), 1);
  Result.FullPath := ArchivePath + '/' + Result.InnerPath;
  { The folder it is in: the archive itself or a folder inside it. }
  Slash := Length(Result.InnerPath);
  while (Slash > 0) and (Result.InnerPath[Slash] <> '/') do
    Dec(Slash);
  if Slash = 0 then
    Result.Folder := ArchivePath
  else
    Result.Folder := ArchivePath + '/' + Copy(Result.InnerPath, 1, Slash - 1);
  if Item.IsFolder then
    Result.Item.Kind := ItemFolder
  else
    Result.Item.Kind := ItemFile;
  Result.Item.ModificationTime := ArchiveTime;
  if Result.ArchiveIndex >= 0 then
  begin
    Information := Reader.Entries[Result.ArchiveIndex];
    Result.Item.SizeInBytes := Information.Size;
    Result.Item.ModificationTime := Information.ModificationTime;
    Result.Item.Mode := Information.Mode;
    Result.Item.IsLink := Information.IsLink;
    Result.Item.LinkTarget := Information.LinkTarget;
  end;
end;

function ReadArchive(const Location: TLocation; Entries: TList): LongInt;
var
  Reader: TArchiveReader;
  Problem: string;
  Items: TArchiveFolderItems;
  Index: LongInt;
  ArchiveFile: TFileInformation;
begin
  Reader := OpenArchiveCached(Location.Path, Problem);
  if Reader = nil then
    Exit(ErrorInvalidArgument);
  GetFileInformation(PChar(Location.Path), ArchiveFile);
  Items := ListArchiveFolder(Reader, Location.InnerPath);
  for Index := 0 to High(Items) do
    Entries.Add(ArchivedEntry(Reader, Location.Path, Items[Index], ArchiveFile.ModificationTime));
  Result := ErrorNone;
end;

function ReadLocationEntries(const Location: TLocation; ShowHidden: Boolean; ShowRecent, ShowFavorites: Boolean;
  Entries: TList): LongInt;
begin
  case Location.Kind of
    LocationFolder: Result := ReadFolder(Location.Path, ShowHidden, Entries);
    LocationHome: Result := ReadHome(ShowRecent, ShowFavorites, Entries);
    LocationGallery: Result := ReadGallery(Entries);
    LocationComputer: Result := ReadComputer(Entries);
    LocationTrash: Result := ReadTrash(Entries);
    LocationArchive: Result := ReadArchive(Location, Entries);
  else
    Result := ErrorNone;
  end;
end;

finalization
  ForgetCachedArchive;
end.
