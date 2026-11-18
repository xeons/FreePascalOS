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
  The firmware's description of the machine, for the AArch64 HAL.

  On x86-64 the HAL's devices sit at fixed addresses. On AArch64 nothing
  does: where the GIC, the timer interrupts and the serial port are, and
  how to call PSCI, differ between QEMU's virt machine, a Raspberry Pi 4
  and every other board, and the UEFI firmware says so in its ACPI tables
  (MADT, GTDT, SPCR, FADT). The HAL reads them from its very first
  moments - the serial port before anything else - through the boot
  information the kernel entry remembered (KernelEntry.s); the tables lie
  in memory the loader mapped into the physical memory window.

  After a native boot (boot/native) there are no ACPI tables but a
  device tree, which the boot stub copied into boot data in the window:
  it is made the kernel's here too (Firmware.DeviceTree), and the HAL
  units fall back to it (Firmware.DeviceTreeMachine, DeviceTree.Chosen)
  where a table is missing.
}
unit Hal.FirmwareTables;

{$mode objfpc}

interface

uses
  Firmware.Acpi;

{ The Instance'th table with Signature, or nil (also without ACPI). }
function FindFirmwareTable(Signature: PChar; Instance: Integer): PAcpiTableHeader;
{ True if the firmware gave a device tree (Firmware.DeviceTree has it). }
function FirmwareDeviceTreeIsPresent: Boolean;

implementation

uses
  Boot.Information,
  Memory.Layout,
  Firmware.DeviceTree;

var
  ArchBootInformation: PBootInformation; external name 'ArchBootInformation';
  TablesFound: Boolean = False;

procedure FindTablesOnce;
begin
  if TablesFound then
    Exit;
  TablesFound := True;
  if ArchBootInformation = nil then
    Exit;
  InitializeAcpi(ArchBootInformation^.AcpiRootPointer);
  if ArchBootInformation^.DeviceTreePhysicalBase <> 0 then
    UseDeviceTree(Pointer(PhysicalToVirtual(ArchBootInformation^.DeviceTreePhysicalBase)));
end;

function FirmwareDeviceTreeIsPresent: Boolean;
begin
  FindTablesOnce;
  Result := DeviceTreeIsAvailable;
end;

function FindFirmwareTable(Signature: PChar; Instance: Integer): PAcpiTableHeader;
begin
  FindTablesOnce;
  Result := FindAcpiTable(Signature, Instance);
end;

end.
