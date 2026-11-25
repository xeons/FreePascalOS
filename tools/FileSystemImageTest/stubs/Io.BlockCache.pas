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
  Host stand-in for the kernel's block cache (FileSystemImageTest): reads
  and writes go straight to the image in memory, refusing anything past
  its end as the real cache does.

  Every call counts towards OperationLimit: a driver that loops on a
  damaged disk (a cluster chain that comes back on itself, an orphan list
  in a ring) runs out of it, and EOperationLimit is raised, which the test
  reports as a hang.
}
unit Io.BlockCache;

{$mode objfpc}

interface

uses
  Io.BlockDevice;

type
  EOperationLimit = class(TObject)
  end;

var
  { 0: no limit. }
  OperationLimit: QWord = 0;
  OperationCount: QWord = 0;

function CachedRead(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord; Buffer: Pointer): Boolean;
function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord; Buffer: Pointer): Boolean;
function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;
function FlushCachedDevice(Device: PBlockDevice): Boolean;

implementation

procedure CountOperation;
begin
  Inc(OperationCount);
  if (OperationLimit <> 0) and (OperationCount > OperationLimit) then
    raise EOperationLimit.Create;
end;

function RangeIsValid(Device: PBlockDevice; ByteOffset, ByteCount: QWord): Boolean;
var
  Size: QWord;
begin
  Size := BlockDeviceSizeInBytes(Device);
  Result := (ByteOffset <= Size) and (ByteCount <= Size - ByteOffset);
end;

function CachedRead(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord; Buffer: Pointer): Boolean;
begin
  CountOperation;
  Result := RangeIsValid(Device, ByteOffset, ByteCount);
  if Result and (ByteCount > 0) then
    Move(Device^.Image[ByteOffset], Buffer^, ByteCount);
end;

function CachedWrite(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord; Buffer: Pointer): Boolean;
begin
  CountOperation;
  Result := RangeIsValid(Device, ByteOffset, ByteCount) and not Device^.WriteProtected;
  if Result and (ByteCount > 0) then
    Move(Buffer^, Device^.Image[ByteOffset], ByteCount);
end;

function CachedWriteZeros(Device: PBlockDevice; ByteOffset: QWord; ByteCount: QWord): Boolean;
begin
  CountOperation;
  Result := RangeIsValid(Device, ByteOffset, ByteCount) and not Device^.WriteProtected;
  if Result and (ByteCount > 0) then
    FillChar(Device^.Image[ByteOffset], ByteCount, 0);
end;

function FlushCachedDevice(Device: PBlockDevice): Boolean;
begin
  CountOperation;
  Result := True;
end;

end.
