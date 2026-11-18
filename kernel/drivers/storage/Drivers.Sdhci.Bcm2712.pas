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
  The Raspberry Pi 5's SD card controller (brcm,bcm2712-sdhci, Linux's
  sdhci-brcmstb.c): a standard SDHCI block ("host", reg 0) with a
  configuration block of Broadcom's own beside it ("cfg", reg 1):

    00h   SDIO_CFG_CTRL: bit 31 card detect test enable, bit 30 its
          level (0: a card is there)
    44h   SDIO_CFG_SD_PIN_SEL: bits 0-1, 2 for SD timing (1 for eMMC)

  The slot's card detect is a GPIO of the always-on block (the tree's
  "cd-gpios"), not the controller's pin, so presence is forced on in
  the configuration block (as Linux does for a slot it polls) and the
  driver takes the card as present (QuirkBrokenCardDetect). The base
  clock is the capabilities', else the frequency of the tree's
  "clocks" (a fixed 200 MHz clock). The card runs at 3.3 V, 4 bits,
  high speed (50 MHz): no voltage switch, so the tree's UHS modes are
  not used.
}
unit Drivers.Sdhci.Bcm2712;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.PlatformDevices;

{ Points the configuration block at SD timing and forces presence; the
  base clock the tree gives (0 if none). False if the block is not
  there (the slot is used anyway). }
function PrepareBcm2712Slot(Device: PPlatformDevice; out TreeClockHertz: LongWord): Boolean;

implementation

uses
  Runtime.Atomic,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  Firmware.DeviceTree,
  Debug.Output;

const
  ConfigControl = $00;
  ControlCardDetectTestEnable = LongWord(1) shl 31;
  ControlCardDetectTestLevel = LongWord(1) shl 30;
  ConfigPinSelect = $44;
  PinSelectMask = $3;
  PinSelectSd = $2;
  ConfigBytes = $200;

{ The clock-frequency of the first clock "clocks" names. }
function TreeClock(Device: PPlatformDevice): LongWord;
var
  Tree: PDeviceTree;
  Phandle: LongWord;
  Node: LongInt;
  Hertz: LongWord;
begin
  Result := 0;
  Tree := SystemDeviceTree;
  if (Device^.DeviceTreeNode = NoDeviceTreeNode) or
     not ReadCellProperty(Tree^, Device^.DeviceTreeNode, 'clocks', Phandle) then
    Exit;
  Node := FindNodeByPhandle(Tree^, Phandle);
  if (Node <> NoNode) and ReadCellProperty(Tree^, Node, 'clock-frequency', Hertz) then
    Result := Hertz;
end;

function PrepareBcm2712Slot(Device: PPlatformDevice; out TreeClockHertz: LongWord): Boolean;
var
  Config: PByte;
  Length: QWord;
  Control: LongWord;
  Pins: LongWord;
begin
  TreeClockHertz := TreeClock(Device);
  Result := False;
  Config := PByte(MapPlatformMemory(Device, 1, Length));
  if (Config = nil) or (Length < ConfigPinSelect + 4) then
  begin
    DebugBeginMessage;
    DebugWriteTag('sdhci');
    DebugWrite(@Device^.Path[0]);
    DebugWriteLine(': no cfg block (reg 1): card detect not forced');
    DebugEndMessage;
    Exit;
  end;
  Pins := PLongWord(Config + ConfigPinSelect)^;
  PLongWord(Config + ConfigPinSelect)^ := (Pins and not LongWord(PinSelectMask)) or PinSelectSd;
  Control := PLongWord(Config + ConfigControl)^;
  PLongWord(Config + ConfigControl)^ := (Control and not ControlCardDetectTestLevel) or ControlCardDetectTestEnable;
  FullMemoryBarrier;
  DebugBeginMessage;
  DebugWriteTag('sdhci');
  DebugWrite(@Device^.Path[0]);
  DebugWrite(': BCM2712 cfg: pin select 0x');
  DebugWriteHex(Pins, 1);
  DebugWrite(' -> SD, ctrl 0x');
  DebugWriteHex(Control, 8);
  DebugWrite(' -> card forced present; tree clock ');
  DebugWriteDecimal(TreeClockHertz div 1000000);
  DebugWriteLine(' MHz');
  DebugEndMessage;
  Result := True;
end;

end.
