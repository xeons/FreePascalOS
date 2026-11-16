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
  The registers of the Realtek RTL8139 family (10/100 Ethernet), reached
  through I/O ports (BAR 0), and the PCI IDs of the cards built on it.
}
unit Drivers.Rtl8139.Registers;

{$mode objfpc}

interface

const
  RegisterStationAddress = $00;
  RegisterMulticast = $08;
  { Four transmit slots: status/command, then buffer address. }
  RegisterTransmitStatus0 = $10;
  RegisterTransmitAddress0 = $20;
  RegisterReceiveBufferStart = $30;
  RegisterCommand = $37;
  RegisterReceiveReadPointer = $38;
  RegisterInterruptMask = $3C;
  RegisterInterruptStatus = $3E;
  RegisterTransmitConfiguration = $40;
  RegisterReceiveConfiguration = $44;
  RegisterMissedPackets = $4C;
  RegisterConfiguration1 = $52;
  RegisterMediaStatus = $58;
  RegisterBasicModeControl = $62;
  RegisterBasicModeStatus = $64;

  CommandBufferEmpty = $01;
  CommandTransmitEnable = $04;
  CommandReceiveEnable = $08;
  CommandReset = $10;

  InterruptReceiveOk = $0001;
  InterruptReceiveError = $0002;
  InterruptTransmitOk = $0004;
  InterruptTransmitError = $0008;
  InterruptReceiveBufferOverflow = $0010;
  { Packet underrun or link change. }
  InterruptLinkChange = $0020;
  InterruptReceiveFifoOverflow = $0040;
  InterruptSystemError = $8000;
  InterruptsUsed = InterruptReceiveOk or InterruptReceiveError or InterruptTransmitOk or
    InterruptTransmitError or InterruptReceiveBufferOverflow or InterruptLinkChange or
    InterruptReceiveFifoOverflow or InterruptSystemError;

  TransmitStatusOwn = LongWord($00002000);
  TransmitStatusUnderrun = LongWord($00004000);
  TransmitStatusOk = LongWord($00008000);
  { Start sending once 8 x 32 bytes are in the FIFO. }
  TransmitEarlyThreshold256 = LongWord($00080000);
  TransmitStatusCollisionCountShift = 24;
  TransmitStatusCollisionCountMask = LongWord($0F);
  TransmitStatusOutOfWindowCollision = LongWord($20000000);
  TransmitStatusAborted = LongWord($40000000);

  { Interframe gap 96 bit times, DMA bursts of 1024 bytes. }
  TransmitConfigurationValue = LongWord($03000600);

  ReceiveAcceptPhysicalMatch = $00000002;
  ReceiveAcceptMulticast = $00000004;
  ReceiveAcceptBroadcast = $00000008;
  { A frame running past the end of the ring goes on past it instead of
    wrapping (the buffer has room for one more frame there). }
  ReceiveWrap = $00000080;
  ReceiveDmaUnlimited = $00000700;
  ReceiveRing32K = $00001000;
  ReceiveNoFifoThreshold = $0000E000;

  { The header the card writes before each received frame. }
  ReceiveHeaderOk = $0001;

  MediaStatusSpeed10 = $08;
  BasicModeControlFullDuplex = $0100;
  BasicModeStatusLinkUp = $0004;

  RealtekVendorId = $10EC;

{ True for the PCI IDs of RTL8139 cards. }
function IsRtl8139(VendorId, DeviceId: Word): Boolean;

implementation

type
  TCardId = record
    VendorId: Word;
    DeviceId: Word;
  end;

const
  CardIdCount = 12;
  CardIds: array[0..CardIdCount - 1] of TCardId = (
    (VendorId: $10EC; DeviceId: $8139),  { Realtek RTL8139 }
    (VendorId: $10EC; DeviceId: $8138),  { Realtek RTL8139 (CardBus) }
    (VendorId: $1113; DeviceId: $1211),  { Accton }
    (VendorId: $1500; DeviceId: $1360),  { Delta Electronics }
    (VendorId: $4033; DeviceId: $1360),  { Addtron }
    (VendorId: $1186; DeviceId: $1300),  { D-Link DFE-538TX }
    (VendorId: $1186; DeviceId: $1340),  { D-Link DFE-690TXD }
    (VendorId: $13D1; DeviceId: $AB06),  { AboCom }
    (VendorId: $1259; DeviceId: $A117),  { Allied Telesyn }
    (VendorId: $14EA; DeviceId: $AB06),  { Planex }
    (VendorId: $14EA; DeviceId: $AB07),  { Planex }
    (VendorId: $11DB; DeviceId: $1234)   { Sega Dreamcast broadband adapter }
  );

function IsRtl8139(VendorId, DeviceId: Word): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to CardIdCount - 1 do
    if (CardIds[Index].VendorId = VendorId) and (CardIds[Index].DeviceId = DeviceId) then
      Exit(True);
  Result := False;
end;

end.
