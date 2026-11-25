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
  Host stand-in for the kernel's block devices (FileSystemImageTest): a
  device is a disk image held in memory. Only what the file system
  drivers use is here.
}
unit Io.BlockDevice;

{$mode objfpc}

interface

const
  BlockDeviceNameLength = 32;
  BlockDeviceModelLength = 41;

type
  PBlockDevice = ^TBlockDevice;

  TBlockDevice = record
    Name: array[0..BlockDeviceNameLength - 1] of Char;
    Model: array[0..BlockDeviceModelLength - 1] of Char;
    BlockSize: LongWord;
    BlockCount: QWord;
    WriteProtected: Boolean;
    IsRemovable: Boolean;
    IsRemoved: Boolean;
    SupportsDiscard: Boolean;
    MaximumDiscardBlocks: QWord;
    Parent: PBlockDevice;
    FirstBlockOnParent: QWord;
    PartitionNumber: LongWord;
    { The image: BlockSize * BlockCount bytes. }
    Image: PByte;
  end;

function BlockDeviceSizeInBytes(Device: PBlockDevice): QWord;
function BlockDeviceIsReadOnly(Device: PBlockDevice): Boolean;

implementation

function BlockDeviceSizeInBytes(Device: PBlockDevice): QWord;
begin
  Result := QWord(Device^.BlockSize) * Device^.BlockCount;
end;

function BlockDeviceIsReadOnly(Device: PBlockDevice): Boolean;
begin
  Result := Device^.WriteProtected;
end;

end.
