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
  frames are received into and sent from.

  Every card here takes 32-bit addresses or is given them, so all of it
  is kept below 4 GiB. A frame buffer is 2 KiB (an Ethernet frame and its
  check sequence fit), two to a page, so no buffer crosses a page and
  none needs contiguous pages. The pages stay the driver's for as long
  as the system runs (a card is never taken away).
}
unit Drivers.NetworkBuffers;

{$mode objfpc}
{$pointermath on}

interface

const
  NetworkBufferBytes = 2048;
  { Device addresses must end below this. }
  NetworkDmaLimit = QWord($FFFFFFFF);

type
  PNetworkBuffer = ^TNetworkBuffer;
  TNetworkBuffer = record
    Data: PByte;
    Physical: QWord;
  end;

{ Fills Count buffers of NetworkBufferBytes. False if memory is short
  (whatever was taken stays taken: the card is not started). }
function AllocateNetworkBuffers(Buffers: PNetworkBuffer; Count: Integer): Boolean;

{ One zeroed page below 4 GiB for a descriptor ring; its physical address
  in Physical, or nil. }
function AllocateDescriptorPage(out Physical: QWord): Pointer;

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages;

function AllocateNetworkBuffers(Buffers: PNetworkBuffer; Count: Integer): Boolean;
var
  Index: Integer;
  PagePhysical: QWord;
  BuffersPerPage: Integer;
  Slot: Integer;
begin
  Result := False;
  BuffersPerPage := PageSize div NetworkBufferBytes;
  Index := 0;
  while Index < Count do
  begin
    PagePhysical := AllocateZeroedPhysicalPageBelow(NetworkDmaLimit, PageUsageGeneral);
    if PagePhysical = 0 then
      Exit;
    Slot := 0;
    while (Slot < BuffersPerPage) and (Index < Count) do
    begin
      Buffers[Index].Physical := PagePhysical + QWord(Slot) * NetworkBufferBytes;
      Buffers[Index].Data := PByte(PhysicalToVirtual(Buffers[Index].Physical));
      Inc(Slot);
      Inc(Index);
    end;
  end;
  Result := True;
end;

function AllocateDescriptorPage(out Physical: QWord): Pointer;
begin
  Physical := AllocateZeroedPhysicalPageBelow(NetworkDmaLimit, PageUsageGeneral);
  if Physical = 0 then
    Exit(nil);
  Result := PhysicalToVirtual(Physical);
end;

end.
