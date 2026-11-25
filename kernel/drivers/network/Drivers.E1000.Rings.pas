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
  The receive and transmit descriptor rings of the e1000 driver.

  Each ring is one page of shared DMA memory holding 128 legacy
  descriptors, each descriptor with its own 2 KiB streaming buffer
  (Drivers.NetworkBuffers); the card is given device addresses (Io.Dma).

  Receiving: the card owns the descriptors from the head it keeps to the
  tail the driver writes; it fills a buffer and sets the descriptor's
  "done" bit. The driver hands each finished frame to the network layer
  (which copies it), clears the descriptor and gives it back by moving
  the tail onto it. Frames are never bigger than one buffer (long
  packets are off and the card strips the check sequence); a frame that
  still came in pieces is dropped whole.

  Transmitting: a frame is copied into the next descriptor's buffer,
  padded to the minimum length, and the tail moved past it. Each
  descriptor asks for its status to be reported; finished ones are
  reclaimed from the oldest on. When the ring is full the frame is
  refused, and the network layer told once there is room again.

  The receive lock serialises the receive side (the deferred routine
  can run on two processors at once); the transmit lock the transmit
  side, which the network layer enters from any processor.
}
unit Drivers.E1000.Rings;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Io.Dma,
  Drivers.E1000.Registers,
  Drivers.NetworkBuffers,
  Drivers.NetworkCards;

const
  E1000ReceiveDescriptors = 128;
  E1000TransmitDescriptors = 128;

type
  TE1000Rings = record
    Registers: PByte;
    Card: PNetworkCard;
    Dma: TDmaAttributes;

    ReceiveRing: TDmaBuffer;
    ReceiveDescriptors: PReceiveDescriptor;
    ReceiveBuffers: array[0..E1000ReceiveDescriptors - 1] of TNetworkBuffer;
    { The next descriptor the card will finish. }
    ReceiveNext: LongWord;
    { Inside a frame that came in several buffers: dropped up to its end. }
    DroppingPieces: Boolean;
    ReceiveLock: TSpinLock;

    TransmitRing: TDmaBuffer;
    TransmitDescriptors: PTransmitDescriptor;
    TransmitBuffers: array[0..E1000TransmitDescriptors - 1] of TNetworkBuffer;
    { The next free descriptor (the tail the card was given). }
    TransmitTail: LongWord;
    { The oldest descriptor not yet reclaimed. }
    TransmitOldest: LongWord;
    { A frame was refused: tell the network layer when there is room. }
    WaitingForRoom: Boolean;
    TransmitLock: TSpinLock;

    { Between StopE1000Rings and ProgramE1000Rings (suspend to RAM):
      nothing is sent or received. }
    IsStopped: Boolean;
  end;

{ Takes the rings' memory, memory the card can reach (Dma). False if
  memory is short. }
function AllocateE1000Rings(var Rings: TE1000Rings; Registers: PByte; Card: PNetworkCard;
  constref Dma: TDmaAttributes): Boolean;
{ Empties both rings and gives the card their addresses (receiving and
  transmitting themselves are enabled by the caller). }
procedure ProgramE1000Rings(var Rings: TE1000Rings);
{ Nothing more is sent or received until ProgramE1000Rings. }
procedure StopE1000Rings(var Rings: TE1000Rings);

{ Hands every finished frame to the network layer. True if the ring had
  more than one pass takes (call again). Dispatch level or below. }
function ReceiveE1000Frames(var Rings: TE1000Rings): Boolean;
{ Reclaims finished transmit descriptors; if a frame was refused and
  there is room now, tells the network layer. }
procedure ReclaimE1000Transmits(var Rings: TE1000Rings);
{ The adapter's Transmit routine, for one card's rings. }
function TransmitE1000Frame(var Rings: TE1000Rings; Frame: PByte; Length: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.PriorityLevel,
  Io.NetworkAdapters;

const
  EthernetHeaderBytes = 14;

function AllocateE1000Rings(var Rings: TE1000Rings; Registers: PByte; Card: PNetworkCard;
  constref Dma: TDmaAttributes): Boolean;
begin
  Result := False;
  Rings.Registers := Registers;
  Rings.Card := Card;
  Rings.Dma := Dma;
  InitializeSpinLock(Rings.ReceiveLock);
  InitializeSpinLock(Rings.TransmitLock);
  Rings.IsStopped := True;
  if not AllocateDescriptorRing(Dma, E1000ReceiveDescriptors * SizeOf(TReceiveDescriptor), Rings.ReceiveRing) or
     not AllocateDescriptorRing(Dma, E1000TransmitDescriptors * SizeOf(TTransmitDescriptor), Rings.TransmitRing) then
    Exit;
  Rings.ReceiveDescriptors := PReceiveDescriptor(Rings.ReceiveRing.Address);
  Rings.TransmitDescriptors := PTransmitDescriptor(Rings.TransmitRing.Address);
  if not AllocateNetworkBuffers(Dma, @Rings.ReceiveBuffers[0], E1000ReceiveDescriptors) or
     not AllocateNetworkBuffers(Dma, @Rings.TransmitBuffers[0], E1000TransmitDescriptors) then
    Exit;
  Result := True;
end;

procedure ProgramE1000Rings(var Rings: TE1000Rings);
var
  PreviousLevel: TPriorityLevel;
  TransmitLevel: TPriorityLevel;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(Rings.ReceiveLock);
  TransmitLevel := AcquireSpinLock(Rings.TransmitLock);
  for Index := 0 to E1000ReceiveDescriptors - 1 do
  begin
    ZeroMemory(@Rings.ReceiveDescriptors[Index], SizeOf(TReceiveDescriptor));
    Rings.ReceiveDescriptors[Index].BufferAddress := Rings.ReceiveBuffers[Index].DeviceAddress;
    PrepareReceiveBuffer(Rings.Dma, Rings.ReceiveBuffers[Index]);
  end;
  for Index := 0 to E1000TransmitDescriptors - 1 do
    ZeroMemory(@Rings.TransmitDescriptors[Index], SizeOf(TTransmitDescriptor));
  Rings.ReceiveNext := 0;
  Rings.DroppingPieces := False;
  Rings.TransmitTail := 0;
  Rings.TransmitOldest := 0;

  WriteRegister(Rings.Registers, RegisterReceiveDescriptorBaseLow, LongWord(Rings.ReceiveRing.DeviceAddress));
  WriteRegister(Rings.Registers, RegisterReceiveDescriptorBaseHigh, LongWord(Rings.ReceiveRing.DeviceAddress shr 32));
  WriteRegister(Rings.Registers, RegisterReceiveDescriptorLength, E1000ReceiveDescriptors * SizeOf(TReceiveDescriptor));
  WriteRegister(Rings.Registers, RegisterReceiveDescriptorHead, 0);
  { Every descriptor but one is the card's: head and tail equal would
    mean none. }
  WriteRegister(Rings.Registers, RegisterReceiveDescriptorTail, E1000ReceiveDescriptors - 1);

  WriteRegister(Rings.Registers, RegisterTransmitDescriptorBaseLow, LongWord(Rings.TransmitRing.DeviceAddress));
  WriteRegister(Rings.Registers, RegisterTransmitDescriptorBaseHigh, LongWord(Rings.TransmitRing.DeviceAddress shr 32));
  WriteRegister(Rings.Registers, RegisterTransmitDescriptorLength, E1000TransmitDescriptors * SizeOf(TTransmitDescriptor));
  WriteRegister(Rings.Registers, RegisterTransmitDescriptorHead, 0);
  WriteRegister(Rings.Registers, RegisterTransmitDescriptorTail, 0);
  Rings.IsStopped := False;
  ReleaseSpinLock(Rings.TransmitLock, TransmitLevel);
  ReleaseSpinLock(Rings.ReceiveLock, PreviousLevel);
end;

procedure StopE1000Rings(var Rings: TE1000Rings);
var
  PreviousLevel: TPriorityLevel;
  TransmitLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Rings.ReceiveLock);
  TransmitLevel := AcquireSpinLock(Rings.TransmitLock);
  Rings.IsStopped := True;
  ReleaseSpinLock(Rings.TransmitLock, TransmitLevel);
  ReleaseSpinLock(Rings.ReceiveLock, PreviousLevel);
end;

{ One finished descriptor: its frame to the network layer, or counted as
  damaged. }
procedure DeliverDescriptor(var Rings: TE1000Rings; Index: LongWord);
var
  Descriptor: PReceiveDescriptor;
  Length: LongWord;
begin
  Descriptor := @Rings.ReceiveDescriptors[Index];
  if (Descriptor^.Status and ReceiveStatusEndOfPacket) = 0 then
  begin
    if not Rings.DroppingPieces then
      Inc(Rings.Card^.Statistics.ReceiveErrors);
    Rings.DroppingPieces := True;
    Exit;
  end;
  if Rings.DroppingPieces then
  begin
    Rings.DroppingPieces := False;
    Exit;
  end;
  Length := Descriptor^.Length;
  if ((Descriptor^.Errors and ReceiveErrorsFrame) <> 0) or (Length < EthernetHeaderBytes) or
     (Length > MaximumFrameBytes) then
  begin
    Inc(Rings.Card^.Statistics.ReceiveErrors);
    Exit;
  end;
  Inc(Rings.Card^.Statistics.FramesReceived);
  Inc(Rings.Card^.Statistics.BytesReceived, Length);
  FinishReceiveBuffer(Rings.Dma, Rings.ReceiveBuffers[Index], Length);
  NetworkFrameReceived(Rings.Card^.Adapter, Rings.ReceiveBuffers[Index].Data, Length);
end;

function ReceiveE1000Frames(var Rings: TE1000Rings): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Descriptor: PReceiveDescriptor;
  Handled: Integer;
  LastHandled: LongWord;
begin
  Result := False;
  PreviousLevel := AcquireSpinLock(Rings.ReceiveLock);
  if Rings.IsStopped then
  begin
    ReleaseSpinLock(Rings.ReceiveLock, PreviousLevel);
    Exit;
  end;
  Handled := 0;
  LastHandled := 0;
  while Handled < E1000ReceiveDescriptors do
  begin
    Descriptor := @Rings.ReceiveDescriptors[Rings.ReceiveNext];
    if (Descriptor^.Status and ReceiveStatusDone) = 0 then
      Break;
    { The status is read before the rest of what the card wrote. }
    FullMemoryBarrier;
    DeliverDescriptor(Rings, Rings.ReceiveNext);
    PrepareReceiveBuffer(Rings.Dma, Rings.ReceiveBuffers[Rings.ReceiveNext]);
    Descriptor^.Status := 0;
    Descriptor^.Errors := 0;
    Descriptor^.Length := 0;
    LastHandled := Rings.ReceiveNext;
    Rings.ReceiveNext := (Rings.ReceiveNext + 1) mod E1000ReceiveDescriptors;
    Inc(Handled);
  end;
  if Handled > 0 then
    WriteRegister(Rings.Registers, RegisterReceiveDescriptorTail, LastHandled);
  Result := Handled = E1000ReceiveDescriptors;
  ReleaseSpinLock(Rings.ReceiveLock, PreviousLevel);
end;

{ Transmit lock held. }
procedure ReclaimFinished(var Rings: TE1000Rings);
var
  Descriptor: PTransmitDescriptor;
begin
  while Rings.TransmitOldest <> Rings.TransmitTail do
  begin
    Descriptor := @Rings.TransmitDescriptors[Rings.TransmitOldest];
    if (Descriptor^.Status and TransmitStatusDone) = 0 then
      Break;
    { Failures are counted from the card's statistics registers. }
    Descriptor^.Status := 0;
    Rings.TransmitOldest := (Rings.TransmitOldest + 1) mod E1000TransmitDescriptors;
  end;
end;

function RingIsFull(var Rings: TE1000Rings): Boolean;
begin
  Result := (Rings.TransmitTail + 1) mod E1000TransmitDescriptors = Rings.TransmitOldest;
end;

procedure ReclaimE1000Transmits(var Rings: TE1000Rings);
var
  PreviousLevel: TPriorityLevel;
  TellNetworkLayer: Boolean;
begin
  TellNetworkLayer := False;
  PreviousLevel := AcquireSpinLock(Rings.TransmitLock);
  if not Rings.IsStopped then
  begin
    ReclaimFinished(Rings);
    if Rings.WaitingForRoom and not RingIsFull(Rings) then
    begin
      Rings.WaitingForRoom := False;
      TellNetworkLayer := True;
    end;
  end;
  ReleaseSpinLock(Rings.TransmitLock, PreviousLevel);
  if TellNetworkLayer then
    NetworkTransmitReady(Rings.Card^.Adapter);
end;

function TransmitE1000Frame(var Rings: TE1000Rings; Frame: PByte; Length: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Descriptor: PTransmitDescriptor;
  Buffer: PByte;
  SentLength: LongWord;
begin
  Result := False;
  PreviousLevel := AcquireSpinLock(Rings.TransmitLock);
  if (Length = 0) or (Length > MaximumFrameBytes) then
  begin
    { Not something to wait for room for: dropped. }
    Inc(Rings.Card^.Statistics.TransmitErrors);
    Result := True;
  end
  else if not Rings.IsStopped then
  begin
    if RingIsFull(Rings) then
      ReclaimFinished(Rings);
    if not RingIsFull(Rings) then
    begin
      Buffer := Rings.TransmitBuffers[Rings.TransmitTail].Data;
      CopyMemory(Buffer, Frame, Length);
      SentLength := Length;
      if SentLength < MinimumFrameBytes then
      begin
        ZeroMemory(Buffer + SentLength, MinimumFrameBytes - SentLength);
        SentLength := MinimumFrameBytes;
      end;
      PrepareTransmitBuffer(Rings.Dma, Rings.TransmitBuffers[Rings.TransmitTail], SentLength);
      Descriptor := @Rings.TransmitDescriptors[Rings.TransmitTail];
      Descriptor^.BufferAddress := Rings.TransmitBuffers[Rings.TransmitTail].DeviceAddress;
      Descriptor^.Length := Word(SentLength);
      Descriptor^.ChecksumOffset := 0;
      Descriptor^.ChecksumStart := 0;
      Descriptor^.Special := 0;
      Descriptor^.Status := 0;
      Descriptor^.Command := TransmitCommandEndOfPacket or TransmitCommandInsertCrc or TransmitCommandReportStatus;
      Rings.TransmitTail := (Rings.TransmitTail + 1) mod E1000TransmitDescriptors;
      { The register write is ordered after the descriptor's. }
      WriteRegister(Rings.Registers, RegisterTransmitDescriptorTail, Rings.TransmitTail);
      Inc(Rings.Card^.Statistics.FramesTransmitted);
      Inc(Rings.Card^.Statistics.BytesTransmitted, SentLength);
      Result := True;
    end;
  end;
  if not Result then
    Rings.WaitingForRoom := True;
  ReleaseSpinLock(Rings.TransmitLock, PreviousLevel);
end;

end.
