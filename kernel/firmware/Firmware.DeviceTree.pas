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
  The machine's device tree, the kernel's way: after a native boot
  (boot/native) the firmware described the machine with a flattened
  device tree instead of ACPI tables, and the boot stub copied it into
  boot data pages the kernel keeps (TBootInformation.DeviceTree*).

  The reading itself is in the shared units (DeviceTree.Blob: nodes,
  properties, phandles, compatible matching; DeviceTree.Addresses: reg,
  ranges, dma-ranges; DeviceTree.Chosen: bootargs, initrd, console,
  framebuffer); the kernel's units on top of them take the tree from
  here (SystemDeviceTree): Firmware.DeviceTreeInterrupts,
  Firmware.DeviceTreeMachine (GIC, timer, PSCI, processors),
  Firmware.DeviceTreePci (ECAM host bridges) and Io.DeviceTreeDevices
  (the platform devices drivers bind to).

  Plain Pascal: the host test (tools/DeviceTreeTest) builds it.
}
unit Firmware.DeviceTree;

{$mode objfpc}

interface

uses
  DeviceTree.Blob;

{ Uses the tree at Base (where the kernel reaches it); a tree that is
  not valid leaves none. Returns whether there is one. }
function UseDeviceTree(Base: Pointer): Boolean;
function DeviceTreeIsAvailable: Boolean;
{ The tree (Base = nil when there is none: every lookup then finds
  nothing). }
function SystemDeviceTree: PDeviceTree;

{ The root's "model" ("Raspberry Pi 5 Model B Rev 1.0"), or nil. }
function DeviceTreeModel: PChar;

implementation

var
  { Zero (no tree) until UseDeviceTree. }
  Tree: TDeviceTree;

function UseDeviceTree(Base: Pointer): Boolean;
begin
  Result := OpenDeviceTree(Base, Tree);
end;

function DeviceTreeIsAvailable: Boolean;
begin
  Result := Tree.Base <> nil;
end;

function SystemDeviceTree: PDeviceTree;
begin
  Result := @Tree;
end;

function DeviceTreeModel: PChar;
begin
  Result := ReadTextProperty(Tree, RootNode(Tree), 'model');
end;

end.
