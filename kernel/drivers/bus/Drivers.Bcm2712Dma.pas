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
  The BCM2712's DMA controller ("brcm,bcm2712-dma"), as far as a
  device's cyclic transfers need it (written from the BCM2711 DMA4
  documentation and Linux's bcm2835-dma.c, untested on the board).

  The Raspberry Pi 5's tree has two nodes over one controller at
  10_0001_0000: dma@10000 (channels 0-5, the older 32-bit kind with
  extended addresses) and dma@10600 (channels 6-11, the 40-bit kind,
  Drivers.Bcm2712Dma.Blocks). Each node's "brcm,dma-channel-mask" says
  which channels are free for the operating system (the firmware keeps
  the others); a channel's registers are 100h * its number from the
  controller's base. Only the 40-bit channels are driven: the HDMI
  audio's "dmas" names dma@10600.

  A cyclic transfer is a ring of control blocks, the last pointing back
  at the first: each moves one period from memory to the device's FIFO
  register, paced by the device's DREQ. The channel then runs until it
  is stopped. Nothing interrupts: the client follows the channel's
  source address (DmaChannelSourceAddress), which is where in the ring
  the hardware is. Control blocks are shared (uncached, as the
  controller does not snoop); the data is the client's streaming
  buffer, which it cleans out of the caches after writing.

  Logged with the tag "dma": each controller found, each cyclic start,
  and failures with the channel's registers.
}
unit Drivers.Bcm2712Dma;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma,
  Drivers.Bcm2712Dma.Blocks;

type
  PDmaController = ^TDmaController;
  TDmaController = record
    Node: LongInt;
    Name: PChar;
    { The controller's register page (every channel and the global
      registers) and where it is. }
    Registers: PByte;
    RegistersPhysical: QWord;
    { Channels free for us, and those taken. }
    ChannelMask: LongWord;
    TakenMask: LongWord;
    Dma: TDmaAttributes;
  end;

  PDmaChannel = ^TDmaChannel;
  TDmaChannel = record
    Controller: PDmaController;
    Number: LongWord;
    Registers: PByte;
    Request: TDmaRequest;
    Blocks: TDmaBuffer;
    BlockCount: LongWord;
    IsRunning: Boolean;
  end;

{ Finds the controllers in the device tree; how many there are. }
function InitializeBcm2712DmaControllers: Integer;

{ A free 40-bit channel of the controller with phandle ControllerPhandle,
  set up for the client's "dmas" cell RequestCell. False (and logged) if
  there is no such controller or channel. ClientName names the client in
  the log. }
function RequestDmaChannel(ControllerPhandle: LongWord; RequestCell: LongWord; ClientName: PChar;
  out Channel: PDmaChannel): Boolean;

{ The controller's DMA attributes: buffers the channel reads come from
  these. }
function DmaChannelAttributes(Channel: PDmaChannel): PDmaAttributes;

{ Starts moving PeriodCount periods of PeriodBytes from BufferBus (bus
  addresses) to the register at DeviceBus, round and round. }
function StartCyclicDmaToDevice(Channel: PDmaChannel; BufferBus: QWord; PeriodBytes, PeriodCount: LongWord;
  DeviceBus: QWord): Boolean;
procedure StopDma(Channel: PDmaChannel);

{ Where the channel reads now (bus address). }
function DmaChannelSourceAddress(Channel: PDmaChannel): QWord;
{ The channel's state for a log line: CS, CB, DEBUG, TI, SRC, DEST, LEN. }
procedure WriteDmaChannelState(Channel: PDmaChannel);

implementation

uses
  Runtime.Atomic,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Io.PlatformDevices,
  Debug.Output;

const
  MaximumControllers = 4;
  ChannelCount = 16;
  { On the BCM2712 channels 6-11 are the 40-bit kind. }
  FirstWideChannel = 6;
  LastWideChannel = 11;
  ControllerPageBytes = $1000;
  StopTimeoutNanoseconds = 1000000;

var
  Controllers: array[0..MaximumControllers - 1] of PDmaController;
  ControllerCount: Integer;

function ReadChannel(Channel: PDmaChannel; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Channel^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteChannel(Channel: PDmaChannel; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Channel^.Registers + Offset)^ := Value;
end;

function ReadController(Controller: PDmaController; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Controller^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteChannelRange(Mask: LongWord);
var
  Channel: LongWord;
  First: Boolean;
begin
  First := True;
  for Channel := 0 to ChannelCount - 1 do
    if (Mask and (LongWord(1) shl Channel)) <> 0 then
    begin
      if not First then
        DebugWrite(',');
      DebugWriteDecimal(Channel);
      First := False;
    end;
  if First then
    DebugWrite('none');
end;

{ --- Finding the controllers -------------------------------------------- }

function ProbeController(Device: PPlatformDevice): Boolean;
var
  Controller: PDmaController;
  Start: QWord;
  Length: QWord;
  Mask: LongWord;
  FirstChannel: LongWord;
  WideMask: LongWord;
begin
  Result := False;
  if (ControllerCount = MaximumControllers) or (Device^.DeviceTreeNode = NoDeviceTreeNode) or
     not PlatformMemoryRange(Device, 0, Start, Length) then
    Exit;
  if not ReadCellProperty(SystemDeviceTree^, Device^.DeviceTreeNode, 'brcm,dma-channel-mask', Mask) then
    Mask := 0;
  if Mask = 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('dma');
    DebugWrite(NodeName(SystemDeviceTree^, Device^.DeviceTreeNode));
    DebugWriteLine(': no brcm,dma-channel-mask, no channels to use: left alone');
    DebugEndMessage;
    Exit;
  end;
  { The node's registers start at its first channel's. }
  FirstChannel := 0;
  while (Mask and (LongWord(1) shl FirstChannel)) = 0 do
    Inc(FirstChannel);
  Controller := PDmaController(AllocateZeroedKernelMemory(SizeOf(TDmaController)));
  if Controller = nil then
    Exit;
  Controller^.Node := Device^.DeviceTreeNode;
  Controller^.Name := NodeName(SystemDeviceTree^, Device^.DeviceTreeNode);
  Controller^.RegistersPhysical := Start - QWord(FirstChannel) * Dma40ChannelStride;
  Controller^.ChannelMask := Mask;
  Controller^.Dma := Device^.Dma;
  LimitDmaBusAddresses(Controller^.Dma, Dma40AddressLimit);
  Controller^.Registers := PByte(MapDeviceMemory(Controller^.RegistersPhysical, ControllerPageBytes));
  if Controller^.Registers = nil then
  begin
    FreeKernelMemory(Controller);
    Exit;
  end;
  Controllers[ControllerCount] := Controller;
  Inc(ControllerCount);

  WideMask := 0;
  for FirstChannel := FirstWideChannel to LastWideChannel do
    WideMask := WideMask or (LongWord(1) shl FirstChannel);
  DebugBeginMessage;
  DebugWriteTag('dma');
  DebugWrite(Controller^.Name);
  DebugWrite(': BCM2712 DMA at 0x');
  DebugWriteHex(Controller^.RegistersPhysical, 1);
  DebugWrite(', channels ');
  WriteChannelRange(Mask);
  DebugWrite(' free (40-bit: ');
  WriteChannelRange(Mask and WideMask);
  DebugWrite('), enable 0x');
  DebugWriteHex(ReadController(Controller, DmaEnable), 8);
  DebugWrite(', ');
  DebugWrite(DmaCoherenceText(Controller^.Dma));
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

const
  DmaIds: array[0..1] of PChar = ('brcm,bcm2712-dma', nil);
  DmaDriver: TPlatformDriver = (
    Name: 'bcm2712-dma';
    Ids: @DmaIds[0];
    Probe: @ProbeController);

function InitializeBcm2712DmaControllers: Integer;
begin
  BindPlatformDriver(DmaDriver);
  Result := ControllerCount;
end;

{ --- Channels ----------------------------------------------------------- }

procedure ReportRequestFailure(ClientName: PChar; What: PChar; Value: QWord);
begin
  DebugBeginMessage;
  DebugWriteTag('dma');
  DebugWrite(ClientName);
  DebugWrite(': FAILED at channel request: ');
  DebugWrite(What);
  DebugWrite(' 0x');
  DebugWriteHex(Value, 1);
  DebugWriteLine('');
  DebugEndMessage;
end;

function RequestDmaChannel(ControllerPhandle: LongWord; RequestCell: LongWord; ClientName: PChar;
  out Channel: PDmaChannel): Boolean;
var
  Node: LongInt;
  Index: Integer;
  Controller: PDmaController;
  Number: LongWord;
begin
  Result := False;
  Channel := nil;
  Node := FindNodeByPhandle(SystemDeviceTree^, ControllerPhandle);
  Controller := nil;
  for Index := 0 to ControllerCount - 1 do
    if Controllers[Index]^.Node = Node then
      Controller := Controllers[Index];
  if Controller = nil then
  begin
    ReportRequestFailure(ClientName, 'no BCM2712 DMA controller with the dmas phandle', ControllerPhandle);
    Exit;
  end;
  Number := FirstWideChannel;
  while (Number <= LastWideChannel) and
        (((Controller^.ChannelMask and (LongWord(1) shl Number)) = 0) or
         ((Controller^.TakenMask and (LongWord(1) shl Number)) <> 0)) do
    Inc(Number);
  if Number > LastWideChannel then
  begin
    ReportRequestFailure(ClientName, 'no free 40-bit channel; free mask', Controller^.ChannelMask);
    Exit;
  end;
  Channel := PDmaChannel(AllocateZeroedKernelMemory(SizeOf(TDmaChannel)));
  if Channel = nil then
    Exit;
  Controller^.TakenMask := Controller^.TakenMask or (LongWord(1) shl Number);
  Channel^.Controller := Controller;
  Channel^.Number := Number;
  Channel^.Registers := Controller^.Registers + Number * Dma40ChannelStride;
  Channel^.Request := DecodeDmaRequestCell(RequestCell);
  Result := True;
end;

function DmaChannelAttributes(Channel: PDmaChannel): PDmaAttributes;
begin
  Result := @Channel^.Controller^.Dma;
end;

{ Stops the channel the way Linux does for a 40-bit channel: clear
  "active", wait for its outstanding transactions, reset it. }
procedure HaltChannel(Channel: PDmaChannel);
var
  Deadline: QWord;
begin
  WriteChannel(Channel, Dma40Control, ReadChannel(Channel, Dma40Control) and not Dma40Active);
  Deadline := ClockNanoseconds + StopTimeoutNanoseconds;
  while ((ReadChannel(Channel, Dma40Control) and Dma40TransactionsOutstanding) <> 0) and
        (ClockNanoseconds < Deadline) do
    CpuRelax;
  WriteChannel(Channel, Dma40Control, Dma40Protection);
  WriteChannel(Channel, Dma40Debug, ReadChannel(Channel, Dma40Debug) or Dma40DebugReset);
end;

function StartCyclicDmaToDevice(Channel: PDmaChannel; BufferBus: QWord; PeriodBytes, PeriodCount: LongWord;
  DeviceBus: QWord): Boolean;
var
  Blocks: PDma40ControlBlock;
  Index: LongWord;
  NextIndex: LongWord;
  FirstWord: LongWord;
begin
  Result := False;
  if Channel^.IsRunning or (PeriodCount = 0) then
    Exit;
  if Channel^.Blocks.Address = nil then
  begin
    if not AllocateDmaBuffer(Channel^.Controller^.Dma, PeriodCount * Dma40ControlBlockBytes, DmaShared,
      Channel^.Blocks) then
    begin
      ReportRequestFailure(Channel^.Controller^.Name, 'no memory for the control blocks', PeriodCount);
      Exit;
    end;
    Channel^.BlockCount := PeriodCount;
  end;
  if Channel^.BlockCount <> PeriodCount then
    Exit;
  Blocks := PDma40ControlBlock(Channel^.Blocks.Address);
  Index := 0;
  while Index < PeriodCount do
  begin
    NextIndex := (Index + 1) mod PeriodCount;
    if not FillMemoryToDeviceBlock(Blocks[Index], BufferBus + QWord(Index) * PeriodBytes, DeviceBus, PeriodBytes,
      Channel^.Blocks.DeviceAddress + QWord(NextIndex) * Dma40ControlBlockBytes, Channel^.Request, False) then
    begin
      ReportRequestFailure(Channel^.Controller^.Name, 'a control block beyond 40 bits, source', BufferBus);
      Exit;
    end;
    Inc(Index);
  end;
  if not ControlBlockAddressWord(Channel^.Blocks.DeviceAddress, FirstWord) then
    Exit;
  { The blocks are in uncached memory; this orders the writes before
    the channel is told. }
  PrepareDmaToDevice(Channel^.Controller^.Dma, Channel^.Blocks.Address, PeriodCount * Dma40ControlBlockBytes);
  HaltChannel(Channel);
  WriteChannel(Channel, Dma40ControlBlock, FirstWord);
  WriteChannel(Channel, Dma40Control, ChannelStartControl(Channel^.Request));
  Channel^.IsRunning := True;

  DebugBeginMessage;
  DebugWriteTag('dma');
  DebugWrite(Channel^.Controller^.Name);
  DebugWrite(' channel ');
  DebugWriteDecimal(Channel^.Number);
  DebugWrite(': cyclic, ');
  DebugWriteDecimal(PeriodCount);
  DebugWrite(' periods of ');
  DebugWriteDecimal(PeriodBytes);
  DebugWrite(' bytes from 0x');
  DebugWriteHex(BufferBus, 1);
  DebugWrite(' to 0x');
  DebugWriteHex(DeviceBus, 1);
  DebugWrite(', DREQ ');
  DebugWriteDecimal(Channel^.Request.Dreq);
  DebugWrite(', CS 0x');
  DebugWriteHex(ReadChannel(Channel, Dma40Control), 8);
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

procedure StopDma(Channel: PDmaChannel);
begin
  if not Channel^.IsRunning then
    Exit;
  HaltChannel(Channel);
  Channel^.IsRunning := False;
end;

function DmaChannelSourceAddress(Channel: PDmaChannel): QWord;
begin
  Result := Dma40Address(ReadChannel(Channel, Dma40Source), ReadChannel(Channel, Dma40SourceInformation));
end;

procedure WriteDmaChannelState(Channel: PDmaChannel);
begin
  DebugWrite('DMA channel ');
  DebugWriteDecimal(Channel^.Number);
  DebugWrite(' CS 0x');
  DebugWriteHex(ReadChannel(Channel, Dma40Control), 8);
  DebugWrite(' CB 0x');
  DebugWriteHex(ReadChannel(Channel, Dma40ControlBlock), 8);
  DebugWrite(' DEBUG 0x');
  DebugWriteHex(ReadChannel(Channel, Dma40Debug), 8);
  DebugWrite(' TI 0x');
  DebugWriteHex(ReadChannel(Channel, Dma40TransferInformation), 8);
  DebugWrite(' SRC 0x');
  DebugWriteHex(DmaChannelSourceAddress(Channel), 10);
  DebugWrite(' DEST 0x');
  DebugWriteHex(Dma40Address(ReadChannel(Channel, Dma40Destination),
    ReadChannel(Channel, Dma40DestinationInformation)), 10);
  DebugWrite(' LEN 0x');
  DebugWriteHex(ReadChannel(Channel, Dma40Length), 1);
  DebugWrite(' enable 0x');
  DebugWriteHex(ReadController(Channel^.Controller, DmaEnable), 8);
end;

end.
