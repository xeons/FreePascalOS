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
  An item of a folder as the file manager shows it: its name, what it
  is, its size, permissions, owner and times.

  A symbolic link is described by what it points to (so a link to a
  folder opens like a folder), with IsLink set and its target's text
  kept; a link that leads nowhere is a broken link, shown as itself.
  FileManager.FolderReading fills these in from the file system; the
  rest of the program (and the host's checks) only reads them.
}
unit FileManager.Items;

{$mode objfpc}
{$H+}

interface

type
  { What an item is, a link followed. }
  TItemKind = (ItemFolder, ItemFile, ItemPipe, ItemDevice, ItemOther);

  TFolderItem = record
    Name: string;
    Kind: TItemKind;
    IsLink: Boolean;
    IsBrokenLink: Boolean;
    { A link's target as written in it. }
    LinkTarget: string;
    SizeInBytes: QWord;
    Mode: LongWord;
    OwnerId: LongWord;
    GroupId: LongWord;
    { Seconds since 1970 (UTC). }
    ModificationTime: Int64;
    AccessTime: Int64;
    ChangeTime: Int64;
    { The volume it is on (TAbiFileInformation.VolumeNumber). }
    VolumeNumber: LongWord;
  end;

  TFolderItems = array of TFolderItem;

const
  { Any execute permission bit makes a file a program. }
  ExecutePermissionBits = $49;
  PermissionBits = $1FF;

function IsFolderItem(const Item: TFolderItem): Boolean;

implementation

function IsFolderItem(const Item: TFolderItem): Boolean;
begin
  Result := Item.Kind = ItemFolder;
end;

end.
