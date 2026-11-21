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
  The ARM PrimeCell real-time clock (PL031): a 32-bit count of seconds
  since 1970 that runs on its own (RTCDR, read), loaded with a new time
  by writing RTCLR.

  A device tree names it ("arm,pl031": QEMU's virt machine after a
  native boot). QEMU's ACPI tables do not list it, so on a machine whose
  tables QEMU made (OEM id "BOCHS ") the virt machine's fixed address is
  tried. Either way the PrimeCell identification registers must read as
  a PL031 before it is used.
}
unit Hal.Pl031;

{$mode objfpc}

interface

{ Finds and maps the clock; False if there is none. Needs device
  mapping (called at the first reading or setting). }
function FindPl031: Boolean;
function ReadPl031Seconds: QWord;
procedure WritePl031Seconds(Seconds: QWord);

implementation

uses
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.Acpi,
  Firmware.DeviceTree,
  Memory.DeviceMapping,
  Hal.FirmwareTables;

const
  RegisterBytes = $1000;
  DataRegister = $000;
  LoadRegister = $008;
  ControlRegister = $00C;
  ControlStart = 1;
  PeripheralIdRegister = $FE0;
  CellIdRegister = $FF0;
  { Part number 031, designer ARM (41h): the low 12 bits of the
    peripheral id and the first byte of the designer. }
  PeripheralIdPart = $031;
  PrimeCellId: array[0..3] of Byte = ($0D, $F0, $05, $B1);
  QemuOemId = 'BOCHS ';
  QemuVirtAddress = $09010000;

var
  Registers: PByte = nil;
  Searched: Boolean = False;

function ReadRegister(Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
end;

function IdentifiesAsPl031: Boolean;
var
  Index: LongWord;
  Part: LongWord;
begin
  for Index := 0 to 3 do
    if (ReadRegister(CellIdRegister + Index * 4) and $FF) <> PrimeCellId[Index] then
      Exit(False);
  Part := (ReadRegister(PeripheralIdRegister) and $FF) or ((ReadRegister(PeripheralIdRegister + 4) and $F) shl 8);
  Result := Part = PeripheralIdPart;
end;

function TryAddress(PhysicalAddress: QWord): Boolean;
begin
  Registers := PByte(MapDeviceMemory(PhysicalAddress, RegisterBytes));
  if Registers = nil then
    Exit(False);
  if not IdentifiesAsPl031 then
  begin
    UnmapDeviceMemory(Registers, RegisterBytes);
    Registers := nil;
    Exit(False);
  end;
  if (ReadRegister(ControlRegister) and ControlStart) = 0 then
    PLongWord(Registers + ControlRegister)^ := ControlStart;
  Result := True;
end;

function DeviceTreeAddress(out PhysicalAddress: QWord): Boolean;
var
  Node: LongInt;
  Size: QWord;
begin
  Result := False;
  PhysicalAddress := 0;
  if not FirmwareDeviceTreeIsPresent then
    Exit;
  Node := FindCompatibleNode(SystemDeviceTree^, NoNode, 'arm,pl031');
  Result := (Node <> NoNode) and NodeRegisterPhysical(SystemDeviceTree^, Node, 0, PhysicalAddress, Size);
end;

function TablesAreQemus: Boolean;
var
  Table: PAcpiTableHeader;
  Index: Integer;
begin
  Table := FindFirmwareTable('APIC', 0);
  if Table = nil then
    Exit(False);
  for Index := 0 to 5 do
    if Table^.OemId[Index] <> QemuOemId[Index + 1] then
      Exit(False);
  Result := True;
end;

function FindPl031: Boolean;
var
  Address: QWord;
begin
  if Searched then
    Exit(Registers <> nil);
  Searched := True;
  if DeviceTreeAddress(Address) then
    Exit(TryAddress(Address));
  Result := TablesAreQemus and TryAddress(QemuVirtAddress);
end;

function ReadPl031Seconds: QWord;
begin
  Result := ReadRegister(DataRegister);
end;

procedure WritePl031Seconds(Seconds: QWord);
begin
  PLongWord(Registers + LoadRegister)^ := LongWord(Seconds);
end;

end.
