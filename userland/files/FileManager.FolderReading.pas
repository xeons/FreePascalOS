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
  Reading a folder's items (FileManager.Items) from the file system:
  every name but "." and "..", hidden ones (starting with a dot) only
  if asked, each described as the file manager shows it. The items come
  in the order the folder lists them; showing them sorted is the
  folder view's.
}
unit FileManager.FolderReading;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Items;

{ Folder's items; ErrorNone or why it could not be read. }
function ReadFolderItems(const Folder: string; IncludeHidden: Boolean; out Items: TFolderItems): LongInt;
{ Describes the item at Path; ErrorNone or why not. }
function DescribeItem(const Path: string; out Item: TFolderItem): LongInt;
{ The volume Path is on (TAbiFileInformation.VolumeNumber; 0 if it
  cannot be told). }
function VolumeNumberOf(const Path: string): LongWord;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Mounts,
  Util.Paths,
  Controls.FileNames,
  FileManager.Paths;

function KindOf(NodeKind: LongWord): TItemKind;
begin
  case NodeKind of
    KindDirectory: Result := ItemFolder;
    KindFile: Result := ItemFile;
    KindFifo: Result := ItemPipe;
    KindCharacterDevice, KindBlockDevice: Result := ItemDevice;
  else
    Result := ItemOther;
  end;
end;

procedure TakeInformation(var Item: TFolderItem; const Information: TFileInformation);
begin
  Item.Kind := KindOf(Information.Kind);
  Item.SizeInBytes := Information.SizeInBytes;
  Item.Mode := Information.Mode;
  Item.OwnerId := Information.OwnerId;
  Item.GroupId := Information.GroupId;
  Item.ModificationTime := Information.ModificationTime;
  Item.AccessTime := Information.AccessTime;
  Item.ChangeTime := Information.ChangeTime;
  Item.VolumeNumber := Information.VolumeNumber;
end;

function BirthTimeOf(const Path: string): Int64;
var
  Times: TFileTimes;
begin
  Result := 0;
  if (GetFileTimes(Path, False, Times) = ErrorNone) and ((Times.Flags and FileTimesHasBirthTime) <> 0) then
    Result := Times.Birth.Seconds;
end;

function DescribeItem(const Path: string; out Item: TFolderItem): LongInt;
var
  Information: TFileInformation;
  Target: string;
begin
  Item := Default(TFolderItem);
  Item.Name := LastPartOf(Path);
  Result := GetLinkInformation(PChar(Path), Information);
  if Result <> ErrorNone then
    Exit;
  TakeInformation(Item, Information);
  Item.BirthTime := BirthTimeOf(Path);
  if Information.Kind <> KindSymbolicLink then
    Exit;
  Item.IsLink := True;
  if ReadLinkTarget(Path, Target) = ErrorNone then
    Item.LinkTarget := Target;
  { Described by what it points to; if it leads nowhere, as itself. }
  if GetFileInformation(PChar(Path), Information) = ErrorNone then
    TakeInformation(Item, Information)
  else
  begin
    Item.IsBrokenLink := True;
    Item.Kind := ItemOther;
  end;
end;

function VolumeNumberOf(const Path: string): LongWord;
var
  Information: TFileInformation;
begin
  if GetLinkInformation(PChar(Path), Information) = ErrorNone then
    Result := Information.VolumeNumber
  else
    Result := 0;
end;

function ReadFolderItems(const Folder: string; IncludeHidden: Boolean; out Items: TFolderItems): LongInt;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Name: string;
  Count: LongInt;
begin
  Items := nil;
  Handle := OpenFile(PChar(Folder), OpenRead);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  Count := 0;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    Name := StrPas(@Entry.Name[0]);
    if (Name = '.') or (Name = '..') then
      Continue;
    if IsHiddenName(Name) and not IncludeHidden then
      Continue;
    if Count = Length(Items) then
      SetLength(Items, Count * 2 + 16);
    { A name that went away between the listing and now is left out. }
    if DescribeItem(CombinePath(Folder, Name), Items[Count]) = ErrorNone then
      Inc(Count);
  end;
  CloseFile(Handle);
  SetLength(Items, Count);
  Result := ErrorNone;
end;

end.
