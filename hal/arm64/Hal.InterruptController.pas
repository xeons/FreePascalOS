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
  Routing device interrupts on AArch64: a global system interrupt is a
  GIC shared peripheral interrupt (INTID 32 and up; ACPI numbers them
  the same), sent to one processor by the distributor (Hal.Gic). There
  are no ISA interrupts.

  Message signalled interrupts need a GICv2m frame (QEMU's virt machine
  has one): a device writes an SPI's number into the frame, which raises
  that SPI. The Raspberry Pi 4's GIC-400 has none; its PCIe bridge
  (BCM2711) has a message controller of its own, for a later driver, so
  PCIe devices there use their INTx lines.
}
unit Hal.InterruptController;

{$mode objfpc}

interface

{ The GIC was set up by the HAL already; this reads the message frame.
  False if device interrupts cannot be routed. }
function InitializeDeviceInterruptRouting(MadtWasParsed: Boolean): Boolean;

{ Describes the routing for the boot log. }
procedure WriteDeviceInterruptRouting;

{ Sends SPI Gsi to processor TargetProcessorId as Vector, triggered as
  given, and enables it. The GIC has no polarity: active low lines are
  inverted before they reach it. }
function RouteDeviceInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;

{ What a device writes, and where, to raise Vector on processor
  TargetProcessorId: a GICv2m SPI. False without a frame, or once its
  SPIs are used up. }
function ComposeMessageInterrupt(Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;

implementation

uses
  Firmware.Madt,
  Hal.Gic,
  Debug.Output;

const
  { Writing an SPI number here raises it. }
  MessageFrameSetSpi = $40;

var
  Available: Boolean = False;
  MessageFrameAddress: QWord = 0;
  NextMessageSpi: LongWord = 0;
  LastMessageSpi: LongWord = 0;

function InitializeDeviceInterruptRouting(MadtWasParsed: Boolean): Boolean;
var
  Description: TGicDescription;
begin
  Available := GicIsAvailable;
  if MadtWasParsed then
  begin
    Description := GicDescription;
    if (Description.MessageFrameAddress <> 0) and (Description.MessageFrameSpiCount > 0) then
    begin
      MessageFrameAddress := Description.MessageFrameAddress;
      NextMessageSpi := Description.MessageFrameFirstSpi;
      LastMessageSpi := Description.MessageFrameFirstSpi + Description.MessageFrameSpiCount - 1;
    end;
  end;
  Result := Available;
end;

procedure WriteDeviceInterruptRouting;
begin
  DebugBeginMessage;
  DebugWriteTag('interrupts');
  if Available then
  begin
    DebugWrite('GIC routing, ');
    DebugWriteDecimal(GicInterruptCount);
    DebugWrite(' interrupts');
    if MessageFrameAddress <> 0 then
    begin
      DebugWrite(', message interrupts through GICv2m (SPIs ');
      DebugWriteDecimal(NextMessageSpi);
      DebugWrite('-');
      DebugWriteDecimal(LastMessageSpi);
      DebugWrite(')');
    end;
    DebugWriteLine('');
  end
  else
    DebugWriteLine('No GIC; device interrupts unavailable');
  DebugEndMessage;
end;

function RouteDeviceInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;
begin
  if Gsi < FirstSharedInterrupt then
    Exit(False);
  Result := ConnectGicInterrupt(Gsi, Vector, LevelTriggered, TargetProcessorId);
end;

function ComposeMessageInterrupt(Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;
begin
  Address := 0;
  Data := 0;
  if (MessageFrameAddress = 0) or (NextMessageSpi > LastMessageSpi) then
    Exit(False);
  if not ConnectGicInterrupt(NextMessageSpi, Vector, False, TargetProcessorId) then
    Exit(False);
  Address := MessageFrameAddress + MessageFrameSetSpi;
  Data := NextMessageSpi;
  Inc(NextMessageSpi);
  Result := True;
end;

end.
