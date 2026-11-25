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
  Memory network cards reach by DMA: descriptor rings and the buffers
  frames are received into and sent from (Io.Dma).

  The rings are shared DMA memory (mapped uncached for a card that does
  not snoop the caches). The frame buffers are streaming DMA memory: a
  frame buffer is 2 KiB (an Ethernet frame and its check sequence fit),
  two to a page, so no buffer crosses a page and none needs contiguous
  pages; the driver brackets each transfer (PrepareReceiveBuffer before
  the card may write a buffer, FinishReceiveBuffer before reading what
  it wrote, PrepareTransmitBuffer after filling one). The card is given
  each buffer's device address, not its physical one (they differ
  behind a bridge with inbound windows, such as the Raspberry Pi 5's
  PCIe). A card limited to 32-bit addresses has its attributes limited
  with LimitNetworkCardDma first, so everything lands below 4 GiB of bus
  addresses. The pages stay the driver's for as long as the system runs
  (a card is never taken away).
}
unit Drivers.NetworkBuffers;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma;

const
  NetworkBufferBytes = 2048;
  { The first bus address a card with 32-bit DMA cannot put out. }
  Network32BitDmaLimit = QWord($100000000);

type
  PNetworkBuffer = ^TNetworkBuffer;
  TNetworkBuffer = record
    Data: PByte;
    { What the card is given for Data. }
    DeviceAddress: QWord;
  end;

{ The card only puts out 32-bit bus addresses. }
procedure LimitNetworkCardDma(var Dma: TDmaAttributes);

{ Fills Count buffers of NetworkBufferBytes, streaming DMA memory the
  card can reach. False if memory is short (whatever was taken stays
  taken: the card is not started). }
function AllocateNetworkBuffers(constref Dma: TDmaAttributes; Buffers: PNetworkBuffer; Count: Integer): Boolean;

{ Zeroed shared DMA memory of SizeInBytes for a descriptor ring (CPU
  address in Ring.Address, the card's in Ring.DeviceAddress). }
function AllocateDescriptorRing(constref Dma: TDmaAttributes; SizeInBytes: QWord; out Ring: TDmaBuffer): Boolean;

{ Before the card may write into Buffer. }
procedure PrepareReceiveBuffer(constref Dma: TDmaAttributes; constref Buffer: TNetworkBuffer);
{ After the card wrote Length bytes into Buffer, before they are read. }
procedure FinishReceiveBuffer(constref Dma: TDmaAttributes; constref Buffer: TNetworkBuffer; Length: LongWord);
{ After Length bytes were put into Buffer, before the card reads them. }
procedure PrepareTransmitBuffer(constref Dma: TDmaAttributes; constref Buffer: TNetworkBuffer; Length: LongWord);

implementation

uses
  Memory.Layout;

procedure LimitNetworkCardDma(var Dma: TDmaAttributes);
begin
  LimitDmaBusAddresses(Dma, Network32BitDmaLimit);
end;

function AllocateNetworkBuffers(constref Dma: TDmaAttributes; Buffers: PNetworkBuffer; Count: Integer): Boolean;
var
  Index: Integer;
  Page: TDmaBuffer;
  BuffersPerPage: Integer;
  Slot: Integer;
begin
  Result := False;
  BuffersPerPage := PageSize div NetworkBufferBytes;
  Index := 0;
  while Index < Count do
  begin
    if not AllocateDmaBuffer(Dma, PageSize, DmaStreaming, Page) then
      Exit;
    Slot := 0;
    while (Slot < BuffersPerPage) and (Index < Count) do
    begin
      Buffers[Index].Data := Page.Address + Slot * NetworkBufferBytes;
      Buffers[Index].DeviceAddress := Page.DeviceAddress + QWord(Slot) * NetworkBufferBytes;
      Inc(Slot);
      Inc(Index);
    end;
  end;
  Result := True;
end;

function AllocateDescriptorRing(constref Dma: TDmaAttributes; SizeInBytes: QWord; out Ring: TDmaBuffer): Boolean;
begin
  Result := AllocateDmaBuffer(Dma, SizeInBytes, DmaShared, Ring);
end;

function ClampedLength(Length: LongWord): LongWord;
begin
  Result := Length;
  if Result > NetworkBufferBytes then
    Result := NetworkBufferBytes;
end;

procedure PrepareReceiveBuffer(constref Dma: TDmaAttributes; constref Buffer: TNetworkBuffer);
begin
  PrepareDmaFromDevice(Dma, Buffer.Data, NetworkBufferBytes);
end;

procedure FinishReceiveBuffer(constref Dma: TDmaAttributes; constref Buffer: TNetworkBuffer; Length: LongWord);
begin
  if Length > 0 then
    FinishDmaFromDevice(Dma, Buffer.Data, ClampedLength(Length));
end;

procedure PrepareTransmitBuffer(constref Dma: TDmaAttributes; constref Buffer: TNetworkBuffer; Length: LongWord);
begin
  if Length > 0 then
    PrepareDmaToDevice(Dma, Buffer.Data, ClampedLength(Length));
end;

end.
