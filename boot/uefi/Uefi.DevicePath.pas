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
  EFI_DEVICE_PATH_PROTOCOL (UEFI specification, section 10).

  A device path is a list of variable length nodes ending in an end
  node. The loader looks at its own device's path to see how it was
  started: a URI node means HTTP boot, an IPv4 node network boot.
}
unit Uefi.DevicePath;

{$mode objfpc}

interface

uses
  Uefi.Base;

type
  TEfiDevicePathNode = packed record
    NodeType: Byte;
    SubType: Byte;
    Length: array[0..1] of Byte;
  end;
  PEfiDevicePathNode = ^TEfiDevicePathNode;

const
  DevicePathTypeMessaging = 3;
  DevicePathTypeEnd = $7F;
  DevicePathSubTypeIpv4 = 12;
  DevicePathSubTypeUri = 24;

  DevicePathProtocolGuid: TEfiGuid = (
    Data1: $09576E91; Data2: $6D3F; Data3: $11D2;
    Data4: ($8E, $39, $00, $A0, $C9, $69, $72, $3B));

function DevicePathNodeLength(Node: PEfiDevicePathNode): QWord;

{ The first node of Path with this type and subtype, or nil. }
function FindDevicePathNode(Path: PEfiDevicePathNode; NodeType, SubType: Byte): PEfiDevicePathNode;

{ True if Prefix (up to its end node) is the start of Path. }
function DevicePathStartsWith(Path, Prefix: PEfiDevicePathNode): Boolean;

implementation

uses
  Runtime.Memory;

function DevicePathNodeLength(Node: PEfiDevicePathNode): QWord;
begin
  Result := QWord(Node^.Length[0]) or (QWord(Node^.Length[1]) shl 8);
end;

function FindDevicePathNode(Path: PEfiDevicePathNode; NodeType, SubType: Byte): PEfiDevicePathNode;
const
  MaximumNodes = 64;
var
  Node: PEfiDevicePathNode;
  NodeCount: Integer;
begin
  Result := nil;
  Node := Path;
  NodeCount := 0;
  while (Node <> nil) and (Node^.NodeType <> DevicePathTypeEnd) and (NodeCount < MaximumNodes) do
  begin
    if (Node^.NodeType = NodeType) and (Node^.SubType = SubType) then
      Exit(Node);
    if DevicePathNodeLength(Node) < SizeOf(TEfiDevicePathNode) then
      Exit;
    Node := PEfiDevicePathNode(PByte(Node) + DevicePathNodeLength(Node));
    Inc(NodeCount);
  end;
end;

{ True if Prefix (up to its end node) is the start of Path. }
function DevicePathStartsWith(Path, Prefix: PEfiDevicePathNode): Boolean;
var
  PrefixLength: QWord;
  Node: PEfiDevicePathNode;
begin
  Result := False;
  if (Path = nil) or (Prefix = nil) then
    Exit;
  PrefixLength := 0;
  Node := Prefix;
  while Node^.NodeType <> DevicePathTypeEnd do
  begin
    if DevicePathNodeLength(Node) < SizeOf(TEfiDevicePathNode) then
      Exit;
    PrefixLength := PrefixLength + DevicePathNodeLength(Node);
    Node := PEfiDevicePathNode(PByte(Node) + DevicePathNodeLength(Node));
  end;
  Result := (PrefixLength > 0) and MemoryIsEqual(Path, Prefix, PrefixLength);
end;

end.
