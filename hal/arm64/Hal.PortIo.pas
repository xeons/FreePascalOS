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
  at 3EFF0000h; the window comes from the root bridge's _CRS). Until the
  PCI code hands that window over (SetPortIoWindow), there are no ports:
  reads return all ones, as an absent device does on x86-64, and writes
  go nowhere - so the drivers of legacy x86 devices (PS/2, the ACPI
  fixed hardware's ports, ISA debug exit) find nothing.
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

{ Maps the 64 KiB of I/O space to the memory mapped window Window (a
  virtual address, mapped as device memory). }
procedure SetPortIoWindow(Window: PByte);

implementation

var
  PortWindow: PByte = nil;

procedure SetPortIoWindow(Window: PByte);
begin
  PortWindow := Window;
end;

function ReadPortByte(Port: Word): Byte;
begin
  if PortWindow = nil then
    Exit($FF);
  Result := PByte(PortWindow + Port)^;
end;

function ReadPortWord(Port: Word): Word;
begin
  if PortWindow = nil then
    Exit($FFFF);
  Result := PWord(PortWindow + Port)^;
end;

function ReadPortLongWord(Port: Word): LongWord;
begin
  if PortWindow = nil then
    Exit($FFFFFFFF);
  Result := PLongWord(PortWindow + Port)^;
end;

procedure WritePortByte(Port: Word; Value: Byte);
begin
  if PortWindow <> nil then
    PByte(PortWindow + Port)^ := Value;
end;

procedure WritePortWord(Port: Word; Value: Word);
begin
  if PortWindow <> nil then
    PWord(PortWindow + Port)^ := Value;
end;

procedure WritePortLongWord(Port: Word; Value: LongWord);
begin
  if PortWindow <> nil then
    PLongWord(PortWindow + Port)^ := Value;
end;

procedure WaitForPortIo;
begin
end;

end.
