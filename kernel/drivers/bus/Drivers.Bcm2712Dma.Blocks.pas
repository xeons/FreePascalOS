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
  The control blocks of the BCM2711/2712 DMA's 40-bit channels (the
  "DMA4" kind: channels 6-11 of the BCM2712's controller), and what a
  client's "dmas" cell asks for. Plain Pascal, checked on the host
  (make hdmi-audio-test).

  A control block is 32 bytes, 32-byte aligned:

    00h  TI     transfer information: bit 0 interrupt when done, 1 2D
                mode, 2 wait for write responses, 3 wait for read
                responses, 9-13 the peripheral (DREQ) that paces it, 14
                reads paced by it, 15 writes paced by it, 16-23 and
                24-31 wait cycles after each read and write
    04h  SRC    the source address, low 32 bits
    08h  SRCI   source information: bits 0-7 address bits 32-39, 8-11
                burst length, 12 increment, 13-14 width (0: 32, 1: 64,
                2: 128, 3: 256 bits), 15 ignore reads, 16-31 2D stride
    0Ch  DEST   the destination address, low 32 bits
    10h  DESTI  as SRCI, for the destination
    14h  LEN    bytes to move
    18h  NEXT   the next block's bus address / 32 (0: stop after this;
                so blocks lie below 128 GiB)
    1Ch  -      reserved

  The "dmas" cell of the Raspberry Pi device trees (one cell after the
  controller's phandle) carries more than the DREQ: bits 0-4 the DREQ,
  16-19 the priority and 20-23 the panic priority (the channel's QoS),
  24 and 25 wide source and destination (128-bit accesses), 27 no wait
  for write responses, 28 wait for outstanding writes, 29 do not pause
  for the debugger, 30 bursts (length 3). The HDMI audio cell 41FA000Ah
  is DREQ 10, priority 10, panic priority 15, wide source, bursts.

  Channel registers (100h apart from the controller's base): 00h CS,
  04h CB (the current block's address / 32), 0Ch DEBUG, 10h TI, 14h SRC,
  18h SRCI, 1Ch DEST, 20h DESTI, 24h LEN, 28h NEXT_CB, 2Ch DEBUG2. CS:
  bit 0 active, 1 end, 2 interrupt (write 1 to clear), 3 DREQ, 4-7
  paused states, 8-9 protection (both: secure/supervisor), 10 error,
  16-19 QoS, 20-23 panic QoS, 25 transactions outstanding, 28 wait for
  outstanding writes, 29 disable debug pause, 30 abort, 31 halt. DEBUG:
  bits 0-2 write, FIFO and read errors, 3 control block read error, 23
  reset the channel.
}
unit Drivers.Bcm2712Dma.Blocks;

{$mode objfpc}

interface

const
  Dma40ControlBlockBytes = 32;
  Dma40ChannelStride = $100;

  { Channel registers. }
  Dma40Control = $00;
  Dma40ControlBlock = $04;
  Dma40Debug = $0C;
  Dma40TransferInformation = $10;
  Dma40Source = $14;
  Dma40SourceInformation = $18;
  Dma40Destination = $1C;
  Dma40DestinationInformation = $20;
  Dma40Length = $24;
  Dma40NextControlBlock = $28;
  Dma40Debug2 = $2C;
  { Of the controller: which channels interrupt, which are enabled. }
  DmaInterruptStatus = $FE0;
  DmaEnable = $FF0;

  { CS. }
  Dma40Active = LongWord(1) shl 0;
  Dma40End = LongWord(1) shl 1;
  Dma40Interrupt = LongWord(1) shl 2;
  Dma40DreqState = LongWord(1) shl 3;
  Dma40Protection = LongWord(3) shl 8;
  Dma40Error = LongWord(1) shl 10;
  Dma40QosShift = 16;
  Dma40PanicQosShift = 20;
  Dma40TransactionsOutstanding = LongWord(1) shl 25;
  Dma40WaitForWrites = LongWord(1) shl 28;
  Dma40DisableDebug = LongWord(1) shl 29;
  Dma40Abort = LongWord(1) shl 30;
  Dma40Halt = LongWord(1) shl 31;

  { TI. }
  Dma40InterruptEnable = LongWord(1) shl 0;
  Dma40WaitResponse = LongWord(1) shl 2;
  Dma40WaitReadResponse = LongWord(1) shl 3;
  Dma40PeripheralShift = 9;
  Dma40PeripheralMask = LongWord($1F) shl 9;
  Dma40SourceDreq = LongWord(1) shl 14;
  Dma40DestinationDreq = LongWord(1) shl 15;

  { SRCI and DESTI. }
  Dma40HighAddressMask = $FF;
  Dma40BurstShift = 8;
  Dma40Increment = LongWord(1) shl 12;
  Dma40Width32 = LongWord(0) shl 13;
  Dma40Width128 = LongWord(2) shl 13;

  { DEBUG. }
  Dma40DebugReset = LongWord(1) shl 23;

  { The burst a cell's bit 30 asks for. }
  RequestedBurstLength = 3;

  { The largest bus address a 40-bit channel puts out, plus one. }
  Dma40AddressLimit = QWord(1) shl 40;
  { Control blocks are named by 32-bit words of their address / 32:
    they must lie below 128 GiB. }
  ControlBlockAddressLimit = QWord(1) shl 37;

type
  TDma40ControlBlock = packed record
    TransferInformation: LongWord;
    SourceAddress: LongWord;
    SourceInformation: LongWord;
    DestinationAddress: LongWord;
    DestinationInformation: LongWord;
    TransferLength: LongWord;
    NextControlBlock: LongWord;
    Reserved: LongWord;
  end;
  PDma40ControlBlock = ^TDma40ControlBlock;

  { What a client's "dmas" cell asks for. }
  TDmaRequest = record
    Dreq: LongWord;
    Priority: LongWord;
    PanicPriority: LongWord;
    WideSource: Boolean;
    WideDestination: Boolean;
    NoWaitResponse: Boolean;
    WaitForWrites: Boolean;
    DisableDebug: Boolean;
    Burst: Boolean;
  end;

function DecodeDmaRequestCell(Cell: LongWord): TDmaRequest;

{ A block's address as CB and NEXT take it (bus address / 32); False if
  it is not 32-byte aligned or not below 128 GiB. }
function ControlBlockAddressWord(BusAddress: QWord; out Word: LongWord): Boolean;

{ A block that moves Length bytes from memory at SourceBus (going up) to
  a device register at DeviceBus (always the same address), each write
  paced by the request's DREQ, then goes on to NextBlockBus. }
function FillMemoryToDeviceBlock(out Block: TDma40ControlBlock; SourceBus, DeviceBus: QWord;
  Length: LongWord; NextBlockBus: QWord; constref Request: TDmaRequest; InterruptWhenDone: Boolean): Boolean;

{ What CS is written with to start the channel. }
function ChannelStartControl(constref Request: TDmaRequest): LongWord;

{ The 40-bit address of a SRC/SRCI (or DEST/DESTI) pair. }
function Dma40Address(Low, Information: LongWord): QWord;

implementation

function DecodeDmaRequestCell(Cell: LongWord): TDmaRequest;
begin
  Result.Dreq := Cell and $1F;
  Result.Priority := (Cell shr 16) and $F;
  Result.PanicPriority := (Cell shr 20) and $F;
  Result.WideSource := (Cell and (LongWord(1) shl 24)) <> 0;
  Result.WideDestination := (Cell and (LongWord(1) shl 25)) <> 0;
  Result.NoWaitResponse := (Cell and (LongWord(1) shl 27)) <> 0;
  Result.WaitForWrites := (Cell and (LongWord(1) shl 28)) <> 0;
  Result.DisableDebug := (Cell and (LongWord(1) shl 29)) <> 0;
  Result.Burst := (Cell and (LongWord(1) shl 30)) <> 0;
end;

function ControlBlockAddressWord(BusAddress: QWord; out Word: LongWord): Boolean;
begin
  Word := 0;
  Result := ((BusAddress and (Dma40ControlBlockBytes - 1)) = 0) and (BusAddress < ControlBlockAddressLimit);
  if Result then
    Word := LongWord(BusAddress shr 5);
end;

function FillMemoryToDeviceBlock(out Block: TDma40ControlBlock; SourceBus, DeviceBus: QWord;
  Length: LongWord; NextBlockBus: QWord; constref Request: TDmaRequest; InterruptWhenDone: Boolean): Boolean;
var
  Information: LongWord;
  NextWord: LongWord;
begin
  Block.TransferInformation := 0;
  Block.SourceAddress := 0;
  Block.SourceInformation := 0;
  Block.DestinationAddress := 0;
  Block.DestinationInformation := 0;
  Block.TransferLength := 0;
  Block.NextControlBlock := 0;
  Block.Reserved := 0;
  Result := False;
  if (SourceBus + Length > Dma40AddressLimit) or (DeviceBus >= Dma40AddressLimit) then
    Exit;
  if not ControlBlockAddressWord(NextBlockBus, NextWord) then
    Exit;
  Information := Dma40DestinationDreq or ((Request.Dreq shl Dma40PeripheralShift) and Dma40PeripheralMask);
  if not Request.NoWaitResponse then
    Information := Information or Dma40WaitResponse;
  if InterruptWhenDone then
    Information := Information or Dma40InterruptEnable;
  Block.TransferInformation := Information;

  Block.SourceAddress := LongWord(SourceBus and $FFFFFFFF);
  Information := LongWord(SourceBus shr 32) and Dma40HighAddressMask;
  Information := Information or Dma40Increment;
  if Request.WideSource then
    Information := Information or Dma40Width128;
  if Request.Burst then
    Information := Information or (RequestedBurstLength shl Dma40BurstShift);
  Block.SourceInformation := Information;

  Block.DestinationAddress := LongWord(DeviceBus and $FFFFFFFF);
  Information := LongWord(DeviceBus shr 32) and Dma40HighAddressMask;
  if Request.WideDestination then
    Information := Information or Dma40Width128;
  if Request.Burst then
    Information := Information or (RequestedBurstLength shl Dma40BurstShift);
  Block.DestinationInformation := Information;

  Block.TransferLength := Length;
  Block.NextControlBlock := NextWord;
  Result := True;
end;

function ChannelStartControl(constref Request: TDmaRequest): LongWord;
begin
  Result := Dma40Active or Dma40Protection or (Request.Priority shl Dma40QosShift) or
    (Request.PanicPriority shl Dma40PanicQosShift);
  if Request.WaitForWrites then
    Result := Result or Dma40WaitForWrites;
  if Request.DisableDebug then
    Result := Result or Dma40DisableDebug;
end;

function Dma40Address(Low, Information: LongWord): QWord;
begin
  Result := QWord(Low) or (QWord(Information and Dma40HighAddressMask) shl 32);
end;

end.
