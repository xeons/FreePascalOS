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
  The trash: items deleted by the file manager (or anything else) are
  moved here rather than removed, and can be put back.

  A trash folder holds "files" (the items, under names of their own)
  and "info" (a NAME.trashinfo for each, Util.TrashInfo: where it was,
  when it was moved). The user's own is ~/.local/share/Trash; an item
  on another volume goes to that volume's own, ".Trash-UID" in the
  folder the volume is mounted on, so moving it there is a rename and
  never a copy. ListTrash gathers every trash folder's items (the home
  one and every mounted volume's), RestoreFromTrash moves one back (the
  caller says where, for a name taken meanwhile), ForgetTrashItem drops
  its info once the item itself is gone (deleted for good).

  Errors are the system's (Abi.SystemCalls Error*).
}
unit Util.Trash;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TTrashItem = record
    { The item's name in the trash ("notes.2.txt"). }
    Name: string;
    { The trash folder it is in (with files/ and info/). }
    TrashFolder: string;
    OriginalPath: string;
    { When it was moved there: local seconds since 1970 (not UTC). }
    DeletionLocalTime: Int64;
  end;
  TTrashItems = array of TTrashItem;

{ The user's own trash folder (~/.local/share/Trash). }
function HomeTrashFolder: string;
{ The trash folder an item at Path goes to (made if missing). }
function TrashFolderFor(const Path: string; out Folder: string): LongInt;
{ Moves the item at Path into the trash; Item says where it went. }
function MoveToTrash(const Path: string; out Item: TTrashItem): LongInt;
{ Every item in every trash folder, the newest first. }
function ListTrash: TTrashItems;
{ The item's place in the trash (files/NAME) and its info file. }
function TrashItemPath(const Item: TTrashItem): string;
function TrashInfoPath(const Item: TTrashItem): string;
{ Moves the item back to TargetPath (its original path, or another
  name if that is taken) and drops its info. }
function RestoreFromTrash(const Item: TTrashItem; const TargetPath: string): LongInt;
{ Drops the item's info (after the item itself has been deleted). }
function ForgetTrashItem(const Item: TTrashItem): LongInt;
{ Whether any trash folder holds anything. }
function TrashHasItems: Boolean;
{ The trash folders there are now (for watching them). }
function TrashFolders: TStringArray;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Environment,
  Sys.Time,
  Sys.LocalTime,
  Sys.Volumes,
  Util.Paths,
  Util.Accounts,
  Util.TrashInfo;

const
  FilesFolderName = 'files';
  InfoFolderName = 'info';

type
  { Asks whether a name is taken in one trash folder (for FreeTrashName). }
  TTrashNames = class
  public
    Folder: string;
    function IsTaken(const Name: string): Boolean;
  end;

function TTrashNames.IsTaken(const Name: string): Boolean;
begin
  Result := PathExists(PChar(Folder + '/' + FilesFolderName + '/' + Name)) or
    PathExists(PChar(Folder + '/' + InfoFolderName + '/' + Name + TrashInfoExtension));
end;

function HomeFolderPath: string;
begin
  Result := GetVariable('HOME');
  if Result = '' then
    Result := '/';
end;

function HomeTrashFolder: string;
begin
  Result := JoinPath(HomeFolderPath, '.local/share/Trash');
end;

{ Makes Path and the folders above it that are missing. }
function MakeFolders(const Path: string): LongInt;
var
  Parent: string;
begin
  if IsDirectory(PChar(Path)) then
    Exit(ErrorNone);
  Parent := ExtractFileDir(Path);
  if (Parent <> '') and (Parent <> Path) then
  begin
    Result := MakeFolders(Parent);
    if Result <> ErrorNone then
      Exit;
  end;
  Result := CreateDirectory(PChar(Path));
  if (Result <> ErrorNone) and IsDirectory(PChar(Path)) then
    Result := ErrorNone;
end;

function PrepareTrashFolder(const Folder: string): LongInt;
begin
  Result := MakeFolders(Folder + '/' + FilesFolderName);
  if Result = ErrorNone then
    Result := MakeFolders(Folder + '/' + InfoFolderName);
end;

function VolumeOf(const Path: string; out Volume: LongWord): Boolean;
var
  Information: TFileInformation;
begin
  Result := GetLinkInformation(PChar(Path), Information) = ErrorNone;
  if Result then
    Volume := Information.VolumeNumber
  else
    Volume := 0;
end;

{ The highest folder above Path that is still on Path's volume. }
function TopFolderOfVolume(const Path: string): string;
var
  Volume: LongWord;
  ParentVolume: LongWord;
  Current: string;
  Parent: string;
begin
  Current := ExtractFileDir(Path);
  if not VolumeOf(Current, Volume) then
    Exit('/');
  while Current <> '/' do
  begin
    Parent := ExtractFileDir(Current);
    if Parent = '' then
      Parent := '/';
    if not VolumeOf(Parent, ParentVolume) or (ParentVolume <> Volume) then
      Break;
    Current := Parent;
  end;
  Result := Current;
end;

function TrashFolderFor(const Path: string; out Folder: string): LongInt;
var
  PathVolume: LongWord;
  HomeVolume: LongWord;
  Top: string;
begin
  Folder := HomeTrashFolder;
  if VolumeOf(Path, PathVolume) and VolumeOf(HomeFolderPath, HomeVolume) and (PathVolume <> HomeVolume) then
  begin
    Top := TopFolderOfVolume(Path);
    Folder := JoinPath(Top, '.Trash-' + IntToStr(CurrentUserId));
  end;
  Result := PrepareTrashFolder(Folder);
end;

function WriteTextFile(const Path, Text: string): LongInt;
var
  Handle: Int64;
begin
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenExclusive);
  if Handle < 0 then
    Exit(LongInt(Handle));
  Result := ErrorNone;
  if Length(Text) > 0 then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
end;

function ReadTextFile(const Path: string; out Text: string): Boolean;
var
  Handle: Int64;
  Buffer: array[0..4095] of Char;
  Count: Int64;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  repeat
    Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
      Text := Text + Copy(Buffer, 0, Count);
  until (Count <= 0) or (Length(Text) > 65536);
  CloseFile(Handle);
  Result := True;
end;

function LocalNow: Int64;
var
  Local: TLocalTime;
  Now: Int64;
begin
  Now := CurrentTime;
  DecodeLocalTime(Now, Local);
  Result := Int64(Now) + Local.Offset;
end;

function MoveToTrash(const Path: string; out Item: TTrashItem): LongInt;
var
  Names: TTrashNames;
  InfoFile: string;
begin
  Item := Default(TTrashItem);
  Result := TrashFolderFor(Path, Item.TrashFolder);
  if Result <> ErrorNone then
    Exit;
  Names := TTrashNames.Create;
  try
    Names.Folder := Item.TrashFolder;
    Item.Name := FreeTrashName(ExtractFileName(Path), @Names.IsTaken);
  finally
    Names.Free;
  end;
  Item.OriginalPath := Path;
  Item.DeletionLocalTime := LocalNow;
  { The info first (made exclusively: it claims the name), then the
    item; the info goes again if the item cannot move. }
  InfoFile := TrashInfoPath(Item);
  Result := WriteTextFile(InfoFile, FormatTrashInfo(Path, Item.DeletionLocalTime));
  if Result <> ErrorNone then
    Exit;
  Result := RenamePath(PChar(Path), PChar(TrashItemPath(Item)));
  if Result <> ErrorNone then
    RemovePath(PChar(InfoFile));
end;

function TrashItemPath(const Item: TTrashItem): string;
begin
  Result := Item.TrashFolder + '/' + FilesFolderName + '/' + Item.Name;
end;

function TrashInfoPath(const Item: TTrashItem): string;
begin
  Result := Item.TrashFolder + '/' + InfoFolderName + '/' + Item.Name + TrashInfoExtension;
end;

function TrashFolders: TStringArray;
var
  Index: Integer;
  Description: TVolumeDescription;
  Candidate: string;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := HomeTrashFolder;
  Index := 0;
  while GetVolumeDescription(Index, Description) do
  begin
    Candidate := JoinPath(StrPas(@Description.MountPoint[0]), '.Trash-' + IntToStr(CurrentUserId));
    if IsDirectory(PChar(Candidate)) and (Candidate <> Result[0]) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Candidate;
    end;
    Inc(Index);
  end;
end;

procedure AddItemsOf(const Folder: string; var Items: TTrashItems);
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Name: string;
  Text: string;
  Item: TTrashItem;
begin
  Handle := OpenFile(PChar(Folder + '/' + InfoFolderName), OpenRead);
  if Handle < 0 then
    Exit;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    Name := StrPas(@Entry.Name[0]);
    if (Length(Name) <= Length(TrashInfoExtension)) or
       (Copy(Name, Length(Name) - Length(TrashInfoExtension) + 1, Length(TrashInfoExtension)) <> TrashInfoExtension) then
      Continue;
    Item := Default(TTrashItem);
    Item.TrashFolder := Folder;
    Item.Name := Copy(Name, 1, Length(Name) - Length(TrashInfoExtension));
    if not PathExists(PChar(TrashItemPath(Item))) then
      Continue;
    if not ReadTextFile(Folder + '/' + InfoFolderName + '/' + Name, Text) or
       not ParseTrashInfo(Text, Item.OriginalPath, Item.DeletionLocalTime) then
      Continue;
    SetLength(Items, Length(Items) + 1);
    Items[High(Items)] := Item;
  end;
  CloseFile(Handle);
end;

function ListTrash: TTrashItems;
var
  Folder: string;
  Index: LongInt;
  Other: LongInt;
  Swap: TTrashItem;
begin
  Result := nil;
  for Folder in TrashFolders do
    AddItemsOf(Folder, Result);
  for Index := 1 to High(Result) do
  begin
    Other := Index;
    while (Other > 0) and (Result[Other].DeletionLocalTime > Result[Other - 1].DeletionLocalTime) do
    begin
      Swap := Result[Other];
      Result[Other] := Result[Other - 1];
      Result[Other - 1] := Swap;
      Dec(Other);
    end;
  end;
end;

function RestoreFromTrash(const Item: TTrashItem; const TargetPath: string): LongInt;
begin
  if PathExists(PChar(TargetPath)) then
    Exit(ErrorExists);
  MakeFolders(ExtractFileDir(TargetPath));
  Result := RenamePath(PChar(TrashItemPath(Item)), PChar(TargetPath));
  if Result = ErrorNone then
    RemovePath(PChar(TrashInfoPath(Item)));
end;

function ForgetTrashItem(const Item: TTrashItem): LongInt;
begin
  Result := RemovePath(PChar(TrashInfoPath(Item)));
end;

function TrashHasItems: Boolean;
begin
  Result := Length(ListTrash) > 0;
end;

end.
