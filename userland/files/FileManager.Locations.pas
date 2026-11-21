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
  Where a tab can be: a folder, or one of the pages that are not a
  folder (Home, Gallery, Computer, Network, the recycle bin), a folder
  inside a ZIP or tar archive, or search results.

  Each has an address, what the address bar shows when edited and what
  can be typed there ("Home", "Recycle bin", "/home/alice", "~/notes",
  "/home/alice/src.zip/docs"), a title (the tab's and the window's), a
  theme icon, and the segments of its breadcrumb (a caption and the
  address each leads to). A typed path through an archive file becomes
  an archive location. The user's standard folders (Desktop, Documents,
  Downloads, Pictures, Music, Videos) live in the home folder.
}
unit FileManager.Locations;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TLocationKind = (LocationFolder, LocationHome, LocationGallery, LocationComputer, LocationNetwork, LocationTrash,
    LocationArchive, LocationSearch);

  TLocation = record
    Kind: TLocationKind;
    { The folder (LocationFolder, the scope of LocationSearch) or the
      archive file (LocationArchive). }
    Path: string;
    { The folder inside the archive ('' its top, no slashes at the
      ends). }
    InnerPath: string;
    { What was searched for (LocationSearch). }
    Query: string;
  end;

  TBreadcrumbSegment = record
    Caption: string;
    Address: string;
  end;
  TBreadcrumbSegments = array of TBreadcrumbSegment;

  TStandardFolder = (FolderDesktop, FolderDocuments, FolderDownloads, FolderPictures, FolderMusic, FolderVideos);

const
  StandardFolderNames: array[TStandardFolder] of string = ('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music',
    'Videos');
  StandardFolderIcons: array[TStandardFolder] of string = ('folder-desktop', 'folder-documents', 'folder-downloads',
    'folder-pictures', 'folder-music', 'folder-videos');
  HomeAddress = 'Home';
  GalleryAddress = 'Gallery';
  ComputerAddress = 'Computer';
  NetworkAddress = 'Network';
  TrashAddress = 'Recycle bin';

function FolderLocation(const Path: string): TLocation;
function PageLocation(Kind: TLocationKind): TLocation;
function SearchLocation(const Scope, Query: string): TLocation;
function SameLocation(const First, Second: TLocation): Boolean;
function LocationAddress(const Location: TLocation): string;
function LocationTitle(const Location: TLocation): string;
function LocationIcon(const Location: TLocation): string;
function LocationSegments(const Location: TLocation): TBreadcrumbSegments;
{ Reads what was typed (relative to Current, a folder); False if it
  leads nowhere that exists. }
function ParseAddress(const Text, Current: string; out Location: TLocation): Boolean;
{ The location above (a folder's parent, an archive folder's parent or
  the folder the archive is in); False at the top. }
function ParentLocation(const Location: TLocation; out Parent: TLocation): Boolean;
{ Whether the location is a real folder (one can make things in it). }
function IsFileSystemLocation(const Location: TLocation): Boolean;

function HomeFolder: string;
function StandardFolderPath(Folder: TStandardFolder): string;
{ Makes the standard folders that are missing in the home folder. }
procedure EnsureStandardFolders;
{ The standard folder at Path, if it is one. }
function StandardFolderAt(const Path: string; out Folder: TStandardFolder): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Environment,
  Controls.FileNames,
  FileManager.Paths,
  FileManager.FileKinds;

function HomeFolder: string;
var
  Home: string;
begin
  Home := GetVariable('HOME');
  if Home = '' then
    Exit('/');
  Result := CleanPath(Home);
end;

function StandardFolderPath(Folder: TStandardFolder): string;
begin
  Result := CombinePath(HomeFolder, StandardFolderNames[Folder]);
end;

procedure EnsureStandardFolders;
var
  Folder: TStandardFolder;
begin
  if HomeFolder = '/' then
    Exit;
  for Folder := Low(TStandardFolder) to High(TStandardFolder) do
    if not PathExists(PChar(StandardFolderPath(Folder))) then
      CreateDirectory(PChar(StandardFolderPath(Folder)));
end;

function StandardFolderAt(const Path: string; out Folder: TStandardFolder): Boolean;
var
  Each: TStandardFolder;
begin
  for Each := Low(TStandardFolder) to High(TStandardFolder) do
    if StandardFolderPath(Each) = Path then
    begin
      Folder := Each;
      Exit(True);
    end;
  Folder := FolderDesktop;
  Result := False;
end;

function FolderLocation(const Path: string): TLocation;
begin
  Result := Default(TLocation);
  Result.Kind := LocationFolder;
  Result.Path := Path;
end;

function PageLocation(Kind: TLocationKind): TLocation;
begin
  Result := Default(TLocation);
  Result.Kind := Kind;
end;

function SearchLocation(const Scope, Query: string): TLocation;
begin
  Result := Default(TLocation);
  Result.Kind := LocationSearch;
  Result.Path := Scope;
  Result.Query := Query;
end;

function SameLocation(const First, Second: TLocation): Boolean;
begin
  Result := (First.Kind = Second.Kind) and (First.Path = Second.Path) and (First.InnerPath = Second.InnerPath) and
    (First.Query = Second.Query);
end;

function LocationAddress(const Location: TLocation): string;
begin
  case Location.Kind of
    LocationHome: Result := HomeAddress;
    LocationGallery: Result := GalleryAddress;
    LocationComputer: Result := ComputerAddress;
    LocationNetwork: Result := NetworkAddress;
    LocationTrash: Result := TrashAddress;
    LocationArchive:
      if Location.InnerPath = '' then
        Result := Location.Path
      else
        Result := Location.Path + '/' + Location.InnerPath;
  else
    Result := Location.Path;
  end;
end;

function LocationTitle(const Location: TLocation): string;
begin
  case Location.Kind of
    LocationFolder:
      begin
        Result := LastPartOf(Location.Path);
        if Result = '' then
          Result := 'File system';
      end;
    LocationArchive:
      if Location.InnerPath = '' then
        Result := LastPartOf(Location.Path)
      else
        Result := LastPartOf('/' + Location.InnerPath);
    LocationSearch: Result := 'Search results in ' + LocationTitle(FolderLocation(Location.Path));
  else
    Result := LocationAddress(Location);
  end;
end;

function LocationIcon(const Location: TLocation): string;
var
  Folder: TStandardFolder;
begin
  case Location.Kind of
    LocationHome: Result := 'home';
    LocationGallery: Result := 'gallery';
    LocationComputer: Result := 'computer';
    LocationNetwork: Result := 'network';
    LocationTrash: Result := 'trash-empty';
    LocationArchive: Result := 'folder-compressed';
    LocationSearch: Result := 'action-search';
  else
    if Location.Path = HomeFolder then
      Result := 'home'
    else if StandardFolderAt(Location.Path, Folder) then
      Result := StandardFolderIcons[Folder]
    else if Location.Path = '/' then
      Result := 'drive'
    else
      Result := 'folder';
  end;
end;

procedure AddSegment(var Segments: TBreadcrumbSegments; const Caption, Address: string);
begin
  SetLength(Segments, Length(Segments) + 1);
  Segments[High(Segments)].Caption := Caption;
  Segments[High(Segments)].Address := Address;
end;

{ The segments of a path: under the home folder from Home, else from
  the file system's root. }
procedure AddPathSegments(var Segments: TBreadcrumbSegments; const Path: string);
var
  Parts: TStringArray;
  Part: string;
  Built: string;
  Home: string;
begin
  Home := HomeFolder;
  if (Home <> '/') and IsSameOrInside(Path, Home) then
  begin
    AddSegment(Segments, HomeAddress, Home);
    Built := Home;
    Parts := Copy(Path, Length(Home) + 2, Length(Path)).Split(['/']);
  end
  else
  begin
    AddSegment(Segments, ComputerAddress, ComputerAddress);
    AddSegment(Segments, 'File system', '/');
    Built := '/';
    Parts := Copy(Path, 2, Length(Path)).Split(['/']);
  end;
  for Part in Parts do
    if Part <> '' then
    begin
      Built := CombinePath(Built, Part);
      AddSegment(Segments, Part, Built);
    end;
end;

function LocationSegments(const Location: TLocation): TBreadcrumbSegments;
var
  Parts: TStringArray;
  Part: string;
  Built: string;
begin
  Result := nil;
  case Location.Kind of
    LocationFolder: AddPathSegments(Result, Location.Path);
    LocationArchive:
      begin
        AddPathSegments(Result, Location.Path);
        Built := Location.Path;
        Parts := Location.InnerPath.Split(['/']);
        for Part in Parts do
          if Part <> '' then
          begin
            Built := Built + '/' + Part;
            AddSegment(Result, Part, Built);
          end;
      end;
    LocationSearch:
      begin
        AddPathSegments(Result, Location.Path);
        AddSegment(Result, 'Search results', '');
      end;
  else
    AddSegment(Result, LocationAddress(Location), LocationAddress(Location));
  end;
end;

{ Whether Path (or a folder above it) is an archive file; Archive and
  Inner the split. }
function SplitArchivePath(const Path: string; out Archive, Inner: string): Boolean;
var
  Current: string;
  Information: TFileInformation;
begin
  Current := Path;
  while (Current <> '/') and (Current <> '') do
  begin
    if (GetFileInformation(PChar(Current), Information) = ErrorNone) then
    begin
      if (Information.Kind = KindFile) and IsBrowsableArchiveExtension(Current) then
      begin
        Archive := Current;
        Inner := Copy(Path, Length(Current) + 2, Length(Path));
        while (Inner <> '') and (Inner[Length(Inner)] = '/') do
          Delete(Inner, Length(Inner), 1);
        Exit(True);
      end;
      Exit(False);
    end;
    Current := ParentFolderOf(Current);
  end;
  Result := False;
end;

function ParseAddress(const Text, Current: string; out Location: TLocation): Boolean;
var
  Trimmed: string;
  Path: string;
  Archive: string;
  Inner: string;
  Kind: TLocationKind;
begin
  Trimmed := Trim(Text);
  Location := Default(TLocation);
  for Kind := LocationHome to LocationTrash do
    if SameText(Trimmed, LocationAddress(PageLocation(Kind))) then
    begin
      Location := PageLocation(Kind);
      Exit(True);
    end;
  if SameText(Trimmed, 'Trash') or SameText(Trimmed, 'Recycle Bin') then
  begin
    Location := PageLocation(LocationTrash);
    Exit(True);
  end;
  if Trimmed = '' then
    Exit(False);
  if Trimmed = '~' then
    Trimmed := HomeFolder
  else if Copy(Trimmed, 1, 2) = '~/' then
    Trimmed := CombinePath(HomeFolder, Copy(Trimmed, 3, Length(Trimmed)));
  Path := CleanPath(CombinePath(Current, Trimmed));
  if IsDirectory(PChar(Path)) then
  begin
    Location := FolderLocation(Path);
    Exit(True);
  end;
  if SplitArchivePath(Path, Archive, Inner) then
  begin
    Location.Kind := LocationArchive;
    Location.Path := Archive;
    Location.InnerPath := Inner;
    Exit(True);
  end;
  Location := FolderLocation(Path);
  Result := False;
end;

function ParentLocation(const Location: TLocation; out Parent: TLocation): Boolean;
var
  Slash: LongInt;
begin
  Parent := Location;
  case Location.Kind of
    LocationFolder:
      begin
        if Location.Path = '/' then
          Exit(False);
        Parent := FolderLocation(ParentFolderOf(Location.Path));
      end;
    LocationArchive:
      if Location.InnerPath = '' then
        Parent := FolderLocation(ParentFolderOf(Location.Path))
      else
      begin
        Slash := Length(Location.InnerPath);
        while (Slash > 0) and (Location.InnerPath[Slash] <> '/') do
          Dec(Slash);
        if Slash = 0 then
          Parent.InnerPath := ''
        else
          Parent.InnerPath := Copy(Location.InnerPath, 1, Slash - 1);
      end;
    LocationSearch: Parent := FolderLocation(Location.Path);
    LocationGallery, LocationTrash, LocationNetwork: Parent := PageLocation(LocationHome);
  else
    Exit(False);
  end;
  Result := True;
end;

function IsFileSystemLocation(const Location: TLocation): Boolean;
begin
  Result := Location.Kind = LocationFolder;
end;

end.
