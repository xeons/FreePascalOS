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
  Giving PCI devices their addresses where no firmware did.

  UEFI firmware assigns every BAR before the loader runs; after a native
  boot (QEMU -kernel) nobody has, and the BARs read zero. For the device
  tree's ECAM host bridges (Firmware.DeviceTreePci) each unassigned
  memory BAR of each function on the bridge's buses gets an address,
  aligned to its size, from the host's windows: a 64-bit BAR from the
  64-bit window if there is one (else the 32-bit one), a 32-bit BAR from
  the 32-bit window, an I/O BAR from the I/O window; then the function
  decodes memory (and I/O). Bridges below the root bus would need their
  own windows programmed and are left alone (QEMU's virt machine puts
  its devices on the root bus).
}
unit Io.PciResources;

{$mode objfpc}

interface

{ Assigns the BARs of the device tree's host bridges' functions. Returns
  how many BARs got an address. }
function AssignPciResources: Integer;

implementation

uses
  Runtime.Memory,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Firmware.DeviceTreePci,
  Io.Pci,
  Debug.Output;

const
  BarCount = 6;
  HeaderTypeNormal = 0;
  MinimumIoAlignment = 4;

type
  TWindowCursor = record
    Present: Boolean;
    Next: QWord;
    Limit: QWord;
  end;

  TCursors = record
    Io: TWindowCursor;
    Memory32: TWindowCursor;
    Memory64: TWindowCursor;
  end;

procedure OpenCursor(out Cursor: TWindowCursor; constref Window: TPciHostWindow);
begin
  Cursor.Present := True;
  Cursor.Next := Window.BusAddress;
  Cursor.Limit := Window.BusAddress + Window.Size;
  { Bus address 0 reads as "unassigned": start a little above it. }
  if Cursor.Next = 0 then
    Cursor.Next := $1000;
end;

procedure OpenCursors(constref Host: TDeviceTreePciHost; out Cursors: TCursors);
var
  Index: Integer;
begin
  Cursors.Io.Present := False;
  Cursors.Memory32.Present := False;
  Cursors.Memory64.Present := False;
  for Index := 0 to Host.WindowCount - 1 do
    case Host.Windows[Index].Space of
      PciSpaceIo:
        if not Cursors.Io.Present then
          OpenCursor(Cursors.Io, Host.Windows[Index]);
      PciSpaceMemory32:
        if not Cursors.Memory32.Present then
          OpenCursor(Cursors.Memory32, Host.Windows[Index]);
      PciSpaceMemory64:
        if not Cursors.Memory64.Present then
          OpenCursor(Cursors.Memory64, Host.Windows[Index]);
    end;
end;

function TakeFrom(var Cursor: TWindowCursor; Size: QWord; out BusAddress: QWord): Boolean;
var
  Aligned: QWord;
begin
  BusAddress := 0;
  Result := False;
  if not Cursor.Present or (Size = 0) then
    Exit;
  Aligned := (Cursor.Next + Size - 1) and not (Size - 1);
  if (Aligned < Cursor.Next) or (Aligned + Size > Cursor.Limit) then
    Exit;
  BusAddress := Aligned;
  Cursor.Next := Aligned + Size;
  Result := True;
end;

function BarIsUnassigned(Device: PPciDevice; Offset: Word; Is64Bit, IsIoPort: Boolean): Boolean;
var
  Low: LongWord;
begin
  Low := PciRead32(Device, Offset);
  if IsIoPort then
    Exit((Low and $FFFFFFFC) = 0);
  Result := (Low and $FFFFFFF0) = 0;
  if Result and Is64Bit then
    Result := PciRead32(Device, Offset + 4) = 0;
end;

procedure ReportUnplacedBar(Device: PPciDevice);
begin
  DebugBeginMessage;
  DebugWriteTag('pci');
  DebugWriteHex(Device^.Bus, 2);
  DebugWrite(':');
  DebugWriteHex(Device^.Device, 2);
  DebugWrite('.');
  DebugWriteDecimal(Device^.FunctionNumber);
  DebugWriteLine(': a BAR found no room in the host bridge windows; its space is not decoded');
  DebugEndMessage;
end;

function AssignFunction(Device: PPciDevice; var Cursors: TCursors): Integer;
var
  BarIndex: Integer;
  Bar: TPciBar;
  Offset: Word;
  Size: QWord;
  BusAddress: QWord;
  Taken: Boolean;
  Command: Word;
  MemoryComplete: Boolean;
  IoComplete: Boolean;
begin
  Result := 0;
  MemoryComplete := True;
  IoComplete := True;
  Command := PciRead16(Device, PciConfigurationCommand);
  PciWrite16(Device, PciConfigurationCommand,
    Command and not (PciCommandIoSpace or PciCommandMemorySpace));
  BarIndex := 0;
  while BarIndex < BarCount do
  begin
    Offset := PciConfigurationBar0 + Word(BarIndex) * 4;
    ZeroMemory(@Bar, SizeOf(Bar));
    if PciReadBar(Device, BarIndex, Bar) and BarIsUnassigned(Device, Offset, Bar.Is64Bit, Bar.IsIoPort) then
    begin
      Size := Bar.SizeInBytes;
      if Bar.IsIoPort then
      begin
        if Size < MinimumIoAlignment then
          Size := MinimumIoAlignment;
        Taken := TakeFrom(Cursors.Io, Size, BusAddress);
      end
      else if Bar.Is64Bit then
      begin
        Taken := TakeFrom(Cursors.Memory64, Size, BusAddress);
        if not Taken then
          Taken := TakeFrom(Cursors.Memory32, Size, BusAddress);
      end
      else
        Taken := TakeFrom(Cursors.Memory32, Size, BusAddress);
      if Taken then
      begin
        PciWrite32(Device, Offset, (PciRead32(Device, Offset) and $F) or LongWord(BusAddress));
        if Bar.Is64Bit then
          PciWrite32(Device, Offset + 4, LongWord(BusAddress shr 32));
        Inc(Result);
      end
      else if Bar.IsIoPort then
        { Left at 0: decoding it would answer at port 0. }
        IoComplete := False
      else
        MemoryComplete := False;
    end;
    if Bar.Is64Bit then
      Inc(BarIndex);
    Inc(BarIndex);
  end;
  { Only the kinds of space whose every BAR has an address are decoded:
    a BAR left at 0 would claim bus address 0 over whatever is there. }
  if MemoryComplete then
    Command := Command or PciCommandMemorySpace;
  if IoComplete then
    Command := Command or PciCommandIoSpace;
  PciWrite16(Device, PciConfigurationCommand, Command);
  if not (MemoryComplete and IoComplete) then
    ReportUnplacedBar(Device);
end;

function AssignHost(constref Host: TDeviceTreePciHost): Integer;
var
  Cursors: TCursors;
  Index: Integer;
  Device: PPciDevice;
begin
  Result := 0;
  OpenCursors(Host, Cursors);
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Device := PciDeviceAt(Index);
    if (Device^.Segment = Host.Segment) and (Device^.Bus = Host.StartBus) and
       (Device^.HeaderType = HeaderTypeNormal) then
      Result := Result + AssignFunction(Device, Cursors);
  end;
end;

function AssignPciResources: Integer;
var
  Index: Integer;
  Host: TDeviceTreePciHost;
begin
  Result := 0;
  if not DeviceTreeIsAvailable then
    Exit;
  for Index := 0 to DeviceTreePciHostCount - 1 do
    if GetDeviceTreePciHost(Index, Host) then
      Result := Result + AssignHost(Host);
  if Result > 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('pci');
    DebugWriteDecimal(Result);
    DebugWriteLine(' BARs assigned from the device tree''s host bridge windows');
    DebugEndMessage;
  end;
end;

end.
