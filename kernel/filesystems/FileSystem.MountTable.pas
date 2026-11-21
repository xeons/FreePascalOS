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
  The mount table: which volume is mounted on which directory.

  A record names the volume holding the directory (Parent), the
  directory's node and node number there, the volume mounted on it
  (Child), and where the directory is as a path: from the root of the
  volume at the top of Parent's chain of mounts (Top, a volume mounted
  nowhere, such as the system volume), so "/tmp" for a volume mounted
  on the system volume's /tmp, "/mnt/usb" for one mounted on /mnt/usb
  of a volume that is itself mounted on /mnt. Path resolution finds a
  mount point by node number (FileSystem.Files), so letter case,
  symbolic links and hard links lead into the mounted volume just as
  well; the path is what a symbolic link inside the mounted volume is
  resolved against when its target leads out of it ("..", or an
  absolute target, which starts at Top's root).

  The volumes and nodes are opaque pointers here and the table does no
  locking (FileSystem.Mounts does), so the host tests build it.
}
unit FileSystem.MountTable;

{$mode objfpc}

interface

const
  MaximumMounts = 32;
  MaximumMountPathBytes = 1024;

type
  PMountRecord = ^TMountRecord;
  TMountRecord = record
    InUse: Boolean;
    { The volume holding the mount point, and the mount point's node
      (the record holds one reference to it) and node number. }
    Parent: Pointer;
    MountPointNode: Pointer;
    MountPointNumber: QWord;
    { The volume mounted there. }
    Child: Pointer;
    { The volume at the top of Parent's chain, and the mount point's
      path from its root ("/tmp"). }
    Top: Pointer;
    Path: array[0..MaximumMountPathBytes - 1] of Char;
  end;

  TMountTable = record
    Records: array[0..MaximumMounts - 1] of TMountRecord;
  end;

procedure InitializeMountTable(out Table: TMountTable);

{ The record of the volume mounted on node NodeNumber of Parent, or nil. }
function FindMountAt(var Table: TMountTable; Parent: Pointer; NodeNumber: QWord): PMountRecord;
{ The record of Child's mount, or nil if Child is mounted nowhere. }
function FindMountOf(var Table: TMountTable; Child: Pointer): PMountRecord;

{ The volume at the top of Volume's chain of mounts: Volume itself when
  it is mounted nowhere. }
function TopVolumeOf(var Table: TMountTable; Volume: Pointer): Pointer;
{ True if Ancestor is Volume or a volume Volume is mounted below. }
function IsMountedBelow(var Table: TMountTable; Volume, Ancestor: Pointer): Boolean;

{ Enters a mount; nil if the table is full. Path is the mount point's
  path from Top's root. }
function AddMount(var Table: TMountTable; Parent, MountPointNode: Pointer; MountPointNumber: QWord;
  Child, Top: Pointer; Path: PChar): PMountRecord;
procedure RemoveMount(MountRecord: PMountRecord);

{ How many volumes are mounted on directories of Volume. }
function CountMountsOn(var Table: TMountTable; Volume: Pointer): Integer;
{ The Index-th record in use (from 0), or nil after the last. }
function MountAt(var Table: TMountTable; Index: Integer): PMountRecord;

{ Copies the path of Volume's root from the root of its top volume:
  the mount point's path, or "" for a volume mounted nowhere. }
procedure CopyVolumeRootPath(var Table: TMountTable; Volume: Pointer; Path: PChar; Capacity: Integer);

{ Destination := Base + "/" + Tail, with no doubled separator; False if
  it does not fit. }
function JoinMountPath(Base, Tail, Destination: PChar; Capacity: Integer): Boolean;

implementation

procedure CopyBounded(Destination, Source: PChar; Capacity: Integer);
var
  Index: Integer;
begin
  if Capacity <= 0 then
    Exit;
  Index := 0;
  while (Source <> nil) and (Source[Index] <> #0) and (Index < Capacity - 1) do
  begin
    Destination[Index] := Source[Index];
    Inc(Index);
  end;
  Destination[Index] := #0;
end;

function TextLengthOf(Text: PChar): Integer;
begin
  Result := 0;
  if Text = nil then
    Exit;
  while Text[Result] <> #0 do
    Inc(Result);
end;

procedure InitializeMountTable(out Table: TMountTable);
var
  Index: Integer;
begin
  for Index := 0 to MaximumMounts - 1 do
  begin
    Table.Records[Index].InUse := False;
    Table.Records[Index].Parent := nil;
    Table.Records[Index].MountPointNode := nil;
    Table.Records[Index].MountPointNumber := 0;
    Table.Records[Index].Child := nil;
    Table.Records[Index].Top := nil;
    Table.Records[Index].Path[0] := #0;
  end;
end;

function FindMountAt(var Table: TMountTable; Parent: Pointer; NodeNumber: QWord): PMountRecord;
var
  Index: Integer;
begin
  for Index := 0 to MaximumMounts - 1 do
    if Table.Records[Index].InUse and (Table.Records[Index].Parent = Parent) and
       (Table.Records[Index].MountPointNumber = NodeNumber) then
      Exit(@Table.Records[Index]);
  Result := nil;
end;

function FindMountOf(var Table: TMountTable; Child: Pointer): PMountRecord;
var
  Index: Integer;
begin
  for Index := 0 to MaximumMounts - 1 do
    if Table.Records[Index].InUse and (Table.Records[Index].Child = Child) then
      Exit(@Table.Records[Index]);
  Result := nil;
end;

function TopVolumeOf(var Table: TMountTable; Volume: Pointer): Pointer;
var
  MountRecord: PMountRecord;
begin
  MountRecord := FindMountOf(Table, Volume);
  if MountRecord = nil then
    Exit(Volume);
  Result := MountRecord^.Top;
end;

function IsMountedBelow(var Table: TMountTable; Volume, Ancestor: Pointer): Boolean;
var
  MountRecord: PMountRecord;
  Steps: Integer;
begin
  Steps := 0;
  while (Volume <> nil) and (Steps <= MaximumMounts) do
  begin
    if Volume = Ancestor then
      Exit(True);
    MountRecord := FindMountOf(Table, Volume);
    if MountRecord = nil then
      Break;
    Volume := MountRecord^.Parent;
    Inc(Steps);
  end;
  Result := False;
end;

function AddMount(var Table: TMountTable; Parent, MountPointNode: Pointer; MountPointNumber: QWord;
  Child, Top: Pointer; Path: PChar): PMountRecord;
var
  Index: Integer;
begin
  for Index := 0 to MaximumMounts - 1 do
    if not Table.Records[Index].InUse then
    begin
      Result := @Table.Records[Index];
      Result^.InUse := True;
      Result^.Parent := Parent;
      Result^.MountPointNode := MountPointNode;
      Result^.MountPointNumber := MountPointNumber;
      Result^.Child := Child;
      Result^.Top := Top;
      CopyBounded(@Result^.Path[0], Path, MaximumMountPathBytes);
      Exit;
    end;
  Result := nil;
end;

procedure RemoveMount(MountRecord: PMountRecord);
begin
  MountRecord^.InUse := False;
  MountRecord^.Parent := nil;
  MountRecord^.MountPointNode := nil;
  MountRecord^.Child := nil;
  MountRecord^.Top := nil;
  MountRecord^.Path[0] := #0;
end;

function CountMountsOn(var Table: TMountTable; Volume: Pointer): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumMounts - 1 do
    if Table.Records[Index].InUse and (Table.Records[Index].Parent = Volume) then
      Inc(Result);
end;

function MountAt(var Table: TMountTable; Index: Integer): PMountRecord;
var
  RecordIndex: Integer;
  Seen: Integer;
begin
  Seen := 0;
  for RecordIndex := 0 to MaximumMounts - 1 do
    if Table.Records[RecordIndex].InUse then
    begin
      if Seen = Index then
        Exit(@Table.Records[RecordIndex]);
      Inc(Seen);
    end;
  Result := nil;
end;

procedure CopyVolumeRootPath(var Table: TMountTable; Volume: Pointer; Path: PChar; Capacity: Integer);
var
  MountRecord: PMountRecord;
begin
  MountRecord := FindMountOf(Table, Volume);
  if MountRecord = nil then
    CopyBounded(Path, '', Capacity)
  else
    CopyBounded(Path, @MountRecord^.Path[0], Capacity);
end;

function JoinMountPath(Base, Tail, Destination: PChar; Capacity: Integer): Boolean;
var
  BaseLength: Integer;
  Position: Integer;
  Index: Integer;
begin
  Result := False;
  if Capacity <= 0 then
    Exit;
  BaseLength := TextLengthOf(Base);
  while (BaseLength > 0) and (Base[BaseLength - 1] = '/') do
    Dec(BaseLength);
  if Tail <> nil then
    while Tail^ = '/' do
      Inc(Tail);
  if BaseLength + 1 + TextLengthOf(Tail) + 1 > Capacity then
    Exit;
  Position := 0;
  for Index := 0 to BaseLength - 1 do
  begin
    Destination[Position] := Base[Index];
    Inc(Position);
  end;
  Destination[Position] := '/';
  Inc(Position);
  Index := 0;
  while (Tail <> nil) and (Tail[Index] <> #0) do
  begin
    Destination[Position] := Tail[Index];
    Inc(Position);
    Inc(Index);
  end;
  { "/" alone, not "/" plus nothing plus a separator. }
  if (Position > 1) and (Destination[Position - 1] = '/') then
    Dec(Position);
  Destination[Position] := #0;
  Result := True;
end;

end.
