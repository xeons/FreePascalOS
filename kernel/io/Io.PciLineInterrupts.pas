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
  PCI interrupt lines (INTA to INTD), routed by the ACPI namespace.

  A device's configuration space says which line it uses (its interrupt
  pin). Where the line arrives comes from the _PRT routing tables
  (Firmware.AcpiPciRouting) of the bridge it is on. A bridge without a
  table passes its devices' lines on to its own slot, turned by the
  device number (the PCI-to-PCI bridge "swizzle": line + device, modulo
  four), and so on up until a bridge with a table.

  Lines are level triggered and may be shared, so a handler must check
  that its device raised the interrupt and quiet it before returning.
}
unit Io.PciLineInterrupts;

{$mode objfpc}

interface

uses
  Kernel.Interrupts,
  Io.Pci;

{ Connects Handler to Device's interrupt line and lets the device assert
  it. False if the device has no line, the line is not in the routing
  tables (or there are none), or it cannot be connected. }
function ConnectPciLineInterrupt(Device: PPciDevice; Handler: TInterruptHandler; Context: Pointer): Boolean;

implementation

uses
  Firmware.AcpiPciRouting,
  Io.InterruptRouting,
  Debug.Output;

const
  PciConfigurationCommand = $04;
  PciConfigurationInterruptPin = $3D;
  PciConfigurationSecondaryBus = $19;
  PciHeaderTypeBridge = 1;
  MaximumBridgeHops = 8;

{ The bridge whose secondary bus is Bus, or nil. }
function BridgeTo(Segment: Word; Bus: Byte): PPciDevice;
var
  Index: Integer;
  Candidate: PPciDevice;
begin
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Candidate := PciDeviceAt(Index);
    if (Candidate^.Segment = Segment) and (Candidate^.HeaderType = PciHeaderTypeBridge) and
       (PciRead8(Candidate, PciConfigurationSecondaryBus) = Bus) then
      Exit(Candidate);
  end;
  Result := nil;
end;

{ The route of Device's line Pin (0-3), swizzled up through bridges
  without tables. }
function RouteOf(Device: PPciDevice; Pin: Byte): PPciRoute;
var
  Bus: Byte;
  Slot: Byte;
  Hops: Integer;
  Bridge: PPciDevice;
begin
  Bus := Device^.Bus;
  Slot := Device^.Device;
  for Hops := 0 to MaximumBridgeHops do
  begin
    Result := FindPciRoute(Device^.Segment, Bus, Slot, Pin);
    if Result <> nil then
      Exit;
    Bridge := BridgeTo(Device^.Segment, Bus);
    if Bridge = nil then
      Exit(nil);
    Pin := (Pin + Slot) mod 4;
    Bus := Bridge^.Bus;
    Slot := Bridge^.Device;
  end;
  Result := nil;
end;

procedure ReportLine(Device: PPciDevice; Pin: Byte; Gsi: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('pci');
  DebugWriteHex(Device^.Bus, 2);
  DebugWrite(':');
  DebugWriteHex(Device^.Device, 2);
  DebugWrite('.');
  DebugWriteDecimal(Device^.FunctionNumber);
  DebugWrite(' INT');
  DebugWriteCharacter(Char(Ord('A') + Pin));
  DebugWrite(' -> GSI ');
  DebugWriteDecimal(Gsi);
  DebugWriteLine('');
  DebugEndMessage;
end;

function ConnectPciLineInterrupt(Device: PPciDevice; Handler: TInterruptHandler; Context: Pointer): Boolean;
var
  Pin: Byte;
  Route: PPciRoute;
  Gsi: LongWord;
begin
  Result := False;
  Pin := PciRead8(Device, PciConfigurationInterruptPin);
  if (Pin < 1) or (Pin > 4) then
    Exit;
  Route := RouteOf(Device, Pin - 1);
  if Route = nil then
    Exit;
  Gsi := Route^.GlobalInterrupt;
  if Route^.IsaInterrupt then
    Gsi := GlobalInterruptOfIsaIrq(Byte(Gsi));
  if not ConnectGlobalInterrupt(Gsi, Route^.LevelTriggered, Route^.ActiveLow, Handler, Context) then
    Exit;
  { Let the device assert its line. }
  PciWrite16(Device, PciConfigurationCommand,
    PciRead16(Device, PciConfigurationCommand) and not PciCommandInterruptDisable);
  ReportLine(Device, Pin - 1, Gsi);
  Result := True;
end;

end.
