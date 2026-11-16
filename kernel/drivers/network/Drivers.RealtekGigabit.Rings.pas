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
  The descriptor rings of the Realtek gigabit and multi-gigabit
  controllers (one receive and one transmit queue; the RTL8125/8126's
  other queues stay unused).

  Unlike Intel's, these rings have no head and tail registers: each
  descriptor carries an "owned by the card" bit, and the last one an
  "end of ring" bit that sends the card back to the first. Receiving,
  the driver gives a descriptor to the card with its buffer's size; the
  card fills it, writes the frame's length (with the check sequence)
  and clears the bit. Transmitting, the driver fills a descriptor, sets
  the bit, and rings the chip's transmit poll register (the chip unit
  says how); the card clears it when sent.

  Each ring is 128 descriptors in one page below 4 GiB (the card wants
  256-byte alignment), each with its own 2 KiB buffer.
}
unit Drivers.RealtekGigabit.Rings;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Drivers.RealtekGigabit.Registers,
  Drivers.NetworkBuffers,
  Drivers.NetworkCards;

const
  RealtekReceiveDescriptors = 128;
  RealtekTransmitDescriptors = 128;

type
  TRealtekTransmitPoll = procedure(Registers: PByte);

  TRealtekRings = record
    Registers: PByte;
    Card: PNetworkCard;
    TransmitPoll: TRealtekTransmitPoll;

    ReceiveDescriptors: PRealtekDescriptor;
    ReceiveDescriptorsPhysical: QWord;
    ReceiveBuffers: array[0..RealtekReceiveDescriptors - 1] of TNetworkBuffer;
    ReceiveNext: LongWord;
    DroppingPieces: Boolean;
    ReceiveLock: TSpinLock;

    TransmitDescriptors: PRealtekDescriptor;
    TransmitDescriptorsPhysical: QWord;
    TransmitBuffers: array[0..RealtekTransmitDescriptors - 1] of TNetworkBuffer;
    TransmitTail: LongWord;
    TransmitOldest: LongWord;
    WaitingForRoom: Boolean;
    TransmitLock: TSpinLock;

    IsStopped: Boolean;
  end;

function AllocateRealtekRings(var Rings: TRealtekRings; Registers: PByte; Card: PNetworkCard;
  TransmitPoll: TRealtekTransmitPoll): Boolean;
{ Empties both rings and writes their addresses (the configuration
  registers must be unlocked). }
procedure ProgramRealtekRings(var Rings: TRealtekRings);
procedure StopRealtekRings(var Rings: TRealtekRings);
{ True if a pass did not take everything (call again). }
function ReceiveRealtekFrames(var Rings: TRealtekRings): Boolean;
procedure ReclaimRealtekTransmits(var Rings: TRealtekRings);
function TransmitRealtekFrame(var Rings: TRealtekRings; Frame: PByte; Length: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.PriorityLevel,
  Io.NetworkAdapters;

const
  EthernetHeaderBytes = 14;
  CheckSequenceBytes = 4;

function AllocateRealtekRings(var Rings: TRealtekRings; Registers: PByte; Card: PNetworkCard;
  TransmitPoll: TRealtekTransmitPoll): Boolean;
begin
  Result := False;
  Rings.Registers := Registers;
  Rings.Card := Card;
  Rings.TransmitPoll := TransmitPoll;
  Rings.IsStopped := True;
  InitializeSpinLock(Rings.ReceiveLock);
  InitializeSpinLock(Rings.TransmitLock);
  Rings.ReceiveDescriptors := PRealtekDescriptor(AllocateDescriptorPage(Rings.ReceiveDescriptorsPhysical));
  Rings.TransmitDescriptors := PRealtekDescriptor(AllocateDescriptorPage(Rings.TransmitDescriptorsPhysical));
  if (Rings.ReceiveDescriptors = nil) or (Rings.TransmitDescriptors = nil) then
    Exit;
  Result := AllocateNetworkBuffers(@Rings.ReceiveBuffers[0], RealtekReceiveDescriptors) and
    AllocateNetworkBuffers(@Rings.TransmitBuffers[0], RealtekTransmitDescriptors);
end;

{ Gives receive descriptor Index (back) to the card. }
procedure GiveReceiveDescriptor(var Rings: TRealtekRings; Index: LongWord);
var
  Descriptor: PRealtekDescriptor;
  Options: LongWord;
begin
  Descriptor := @Rings.ReceiveDescriptors[Index];
  Descriptor^.AddressLow := LongWord(Rings.ReceiveBuffers[Index].Physical);
  Descriptor^.AddressHigh := LongWord(Rings.ReceiveBuffers[Index].Physical shr 32);
  Descriptor^.Options2 := 0;
  Options := DescriptorOwnedByCard or NetworkBufferBytes;
  if Index = RealtekReceiveDescriptors - 1 then
    Options := Options or DescriptorEndOfRing;
  { The address before the ownership. }
  FullMemoryBarrier;
  Descriptor^.Options1 := Options;
end;

procedure ProgramRealtekRings(var Rings: TRealtekRings);
var
  ReceiveLevel: TPriorityLevel;
  TransmitLevel: TPriorityLevel;
  Index: Integer;
begin
  ReceiveLevel := AcquireSpinLock(Rings.ReceiveLock);
  TransmitLevel := AcquireSpinLock(Rings.TransmitLock);
  for Index := 0 to RealtekReceiveDescriptors - 1 do
    GiveReceiveDescriptor(Rings, LongWord(Index));
  for Index := 0 to RealtekTransmitDescriptors - 1 do
    ZeroMemory(@Rings.TransmitDescriptors[Index], SizeOf(TRealtekDescriptor));
  Rings.TransmitDescriptors[RealtekTransmitDescriptors - 1].Options1 := DescriptorEndOfRing;
  Rings.ReceiveNext := 0;
  Rings.DroppingPieces := False;
  Rings.TransmitTail := 0;
  Rings.TransmitOldest := 0;
  { The high half first: the low write makes the address take effect on
    some chips. }
  Write32(Rings.Registers, RegisterTransmitDescriptorsHigh, LongWord(Rings.TransmitDescriptorsPhysical shr 32));
  Write32(Rings.Registers, RegisterTransmitDescriptorsLow, LongWord(Rings.TransmitDescriptorsPhysical));
  Write32(Rings.Registers, RegisterReceiveDescriptorsHigh, LongWord(Rings.ReceiveDescriptorsPhysical shr 32));
  Write32(Rings.Registers, RegisterReceiveDescriptorsLow, LongWord(Rings.ReceiveDescriptorsPhysical));
  Rings.IsStopped := False;
  ReleaseSpinLock(Rings.TransmitLock, TransmitLevel);
  ReleaseSpinLock(Rings.ReceiveLock, ReceiveLevel);
end;

procedure StopRealtekRings(var Rings: TRealtekRings);
var
  ReceiveLevel: TPriorityLevel;
  TransmitLevel: TPriorityLevel;
begin
  ReceiveLevel := AcquireSpinLock(Rings.ReceiveLock);
  TransmitLevel := AcquireSpinLock(Rings.TransmitLock);
  Rings.IsStopped := True;
  ReleaseSpinLock(Rings.TransmitLock, TransmitLevel);
  ReleaseSpinLock(Rings.ReceiveLock, ReceiveLevel);
end;

procedure DeliverDescriptor(var Rings: TRealtekRings; Index: LongWord; Options: LongWord);
var
  Length: LongWord;
begin
  if (Options and DescriptorLastSegment) = 0 then
  begin
    { A frame bigger than a buffer: dropped to its last piece. }
    if not Rings.DroppingPieces then
      Inc(Rings.Card^.Statistics.ReceiveErrors);
    Rings.DroppingPieces := True;
    Exit;
  end;
  if Rings.DroppingPieces or ((Options and DescriptorFirstSegment) = 0) then
  begin
    Rings.DroppingPieces := False;
    Exit;
  end;
  Length := Options and DescriptorLengthMask;
  if ((Options and ReceiveDescriptorErrorSummary) <> 0) or (Length < EthernetHeaderBytes + CheckSequenceBytes) or
     (Length > MaximumFrameBytes + CheckSequenceBytes) then
  begin
    Inc(Rings.Card^.Statistics.ReceiveErrors);
    Exit;
  end;
  Length := Length - CheckSequenceBytes;
  Inc(Rings.Card^.Statistics.FramesReceived);
  Inc(Rings.Card^.Statistics.BytesReceived, Length);
  NetworkFrameReceived(Rings.Card^.Adapter, Rings.ReceiveBuffers[Index].Data, Length);
end;

function ReceiveRealtekFrames(var Rings: TRealtekRings): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Options: LongWord;
  Handled: Integer;
begin
  PreviousLevel := AcquireSpinLock(Rings.ReceiveLock);
  Handled := 0;
  while not Rings.IsStopped and (Handled < RealtekReceiveDescriptors) do
  begin
    Options := Rings.ReceiveDescriptors[Rings.ReceiveNext].Options1;
    if (Options and DescriptorOwnedByCard) <> 0 then
      Break;
    FullMemoryBarrier;
    DeliverDescriptor(Rings, Rings.ReceiveNext, Options);
    GiveReceiveDescriptor(Rings, Rings.ReceiveNext);
    Rings.ReceiveNext := (Rings.ReceiveNext + 1) mod RealtekReceiveDescriptors;
    Inc(Handled);
  end;
  Result := Handled = RealtekReceiveDescriptors;
  ReleaseSpinLock(Rings.ReceiveLock, PreviousLevel);
end;

function RingIsFull(var Rings: TRealtekRings): Boolean;
begin
  Result := (Rings.TransmitTail + 1) mod RealtekTransmitDescriptors = Rings.TransmitOldest;
end;

{ Transmit lock held. }
procedure ReclaimFinished(var Rings: TRealtekRings);
begin
  while (Rings.TransmitOldest <> Rings.TransmitTail) and
        ((Rings.TransmitDescriptors[Rings.TransmitOldest].Options1 and DescriptorOwnedByCard) = 0) do
    Rings.TransmitOldest := (Rings.TransmitOldest + 1) mod RealtekTransmitDescriptors;
end;

procedure ReclaimRealtekTransmits(var Rings: TRealtekRings);
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

function TransmitRealtekFrame(var Rings: TRealtekRings; Frame: PByte; Length: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Descriptor: PRealtekDescriptor;
  Buffer: PByte;
  SentLength: LongWord;
  Options: LongWord;
begin
  Result := False;
  PreviousLevel := AcquireSpinLock(Rings.TransmitLock);
  if (Length = 0) or (Length > MaximumFrameBytes) then
  begin
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
      Descriptor := @Rings.TransmitDescriptors[Rings.TransmitTail];
      Descriptor^.AddressLow := LongWord(Rings.TransmitBuffers[Rings.TransmitTail].Physical);
      Descriptor^.AddressHigh := LongWord(Rings.TransmitBuffers[Rings.TransmitTail].Physical shr 32);
      Descriptor^.Options2 := 0;
      Options := DescriptorOwnedByCard or DescriptorFirstSegment or DescriptorLastSegment or SentLength;
      if Rings.TransmitTail = RealtekTransmitDescriptors - 1 then
        Options := Options or DescriptorEndOfRing;
      FullMemoryBarrier;
      Descriptor^.Options1 := Options;
      Rings.TransmitTail := (Rings.TransmitTail + 1) mod RealtekTransmitDescriptors;
      FullMemoryBarrier;
      Rings.TransmitPoll(Rings.Registers);
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
