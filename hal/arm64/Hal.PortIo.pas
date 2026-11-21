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
  Port I/O on AArch64.

  AArch64 has no I/O instructions. A PCIe host bridge offers the I/O
  space of its devices as a window of memory instead (QEMU's virt machine
  at 3EFF0000h; the window comes from the root bridge's _CRS or the
  device tree host's "ranges", Io.PciPortWindow). Until the PCI code
  hands that window over (UsePortIoWindow), and for ports beyond it,
  there are no ports: reads return all ones, as an absent device does on
  x86-64, and writes go nowhere - so the drivers of legacy x86 devices
  (PS/2, the ACPI fixed hardware's ports, ISA debug exit) find nothing.
}
unit Hal.PortIo;

{$mode objfpc}

interface

function ReadPortByte(Port: Word): Byte;
function ReadPortWord(Port: Word): Word;
function ReadPortLongWord(Port: Word): LongWord;
procedure WritePortByte(Port: Word; Value: Byte);
procedure WritePortWord(Port: Word; Value: Word);
procedure WritePortLongWord(Port: Word; Value: LongWord);
{ Nothing to wait for on AArch64. }
procedure WaitForPortIo;

{ True: ports need a window of memory here. }
function PortIoNeedsWindow: Boolean;
{ Maps the first Length bytes of I/O space (up to 64 KiB) to the memory
  mapped window at physical address PhysicalBase (port 0's address).
  False if it could not be mapped. }
function UsePortIoWindow(PhysicalBase, Length: QWord): Boolean;
{ Uses the window Window (a virtual address, already mapped as device
  memory) for all 64 KiB of I/O space. }
procedure SetPortIoWindow(Window: PByte);

implementation

uses
  Memory.DeviceMapping;

const
  PortSpaceSize = $10000;

var
  PortWindow: PByte = nil;
  PortWindowLength: LongWord = 0;

function PortIoNeedsWindow: Boolean;
begin
  Result := True;
end;

function UsePortIoWindow(PhysicalBase, Length: QWord): Boolean;
var
  Window: PByte;
begin
  if (Length = 0) or (Length > PortSpaceSize) then
    Length := PortSpaceSize;
  Window := PByte(MapDeviceMemory(PhysicalBase, Length));
  if Window = nil then
    Exit(False);
  PortWindowLength := LongWord(Length);
  PortWindow := Window;
  Result := True;
end;

procedure SetPortIoWindow(Window: PByte);
begin
  PortWindowLength := PortSpaceSize;
  PortWindow := Window;
end;

{ True if Size bytes at Port lie in the window. }
function PortIsMapped(Port: Word; Size: LongWord): Boolean;
begin
  Result := (PortWindow <> nil) and (LongWord(Port) + Size <= PortWindowLength);
end;

function ReadPortByte(Port: Word): Byte;
begin
  if not PortIsMapped(Port, 1) then
    Exit($FF);
  Result := PByte(PortWindow + Port)^;
end;

function ReadPortWord(Port: Word): Word;
begin
  if not PortIsMapped(Port, 2) then
    Exit($FFFF);
  Result := PWord(PortWindow + Port)^;
end;

function ReadPortLongWord(Port: Word): LongWord;
begin
  if not PortIsMapped(Port, 4) then
    Exit($FFFFFFFF);
  Result := PLongWord(PortWindow + Port)^;
end;

procedure WritePortByte(Port: Word; Value: Byte);
begin
  if PortIsMapped(Port, 1) then
    PByte(PortWindow + Port)^ := Value;
end;

procedure WritePortWord(Port: Word; Value: Word);
begin
  if PortIsMapped(Port, 2) then
    PWord(PortWindow + Port)^ := Value;
end;

procedure WritePortLongWord(Port: Word; Value: LongWord);
begin
  if PortIsMapped(Port, 4) then
    PLongWord(PortWindow + Port)^ := Value;
end;

procedure WaitForPortIo;
begin
end;

end.
