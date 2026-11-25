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

{ Host stand-in for discards (FileSystemImageTest): nothing is discarded. }
unit FileSystem.Discards;

{$mode objfpc}

interface

uses
  FileSystem.Types;

procedure QueueVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord; AfterCommit: Boolean);
procedure CancelVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord);
procedure ReleaseCommittedDiscards(Volume: PVolume);
procedure DropUncommittedDiscards(Volume: PVolume);
function TrimFreeRange(Volume: PVolume; ByteOffset, ByteCount: QWord; var Discarded: QWord): Boolean;

implementation

procedure QueueVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord; AfterCommit: Boolean);
begin
end;

procedure CancelVolumeDiscard(Volume: PVolume; ByteOffset, ByteCount: QWord);
begin
end;

procedure ReleaseCommittedDiscards(Volume: PVolume);
begin
end;

procedure DropUncommittedDiscards(Volume: PVolume);
begin
end;

function TrimFreeRange(Volume: PVolume; ByteOffset, ByteCount: QWord; var Discarded: QWord): Boolean;
begin
  Result := True;
end;

end.
