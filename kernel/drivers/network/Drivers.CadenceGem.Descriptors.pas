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
  The Cadence GEM's DMA descriptors in their 64-bit address form (DMA
  configuration bit 30), 16 bytes each, rings of them in memory:

    word 0  receive: the buffer address's low 32 bits, bit 0 "used"
            (1: the GEM filled it, software owns it), bit 1 "wrap" (the
            last of the ring); transmit: the buffer address's low bits
    word 1  receive: status - the frame length (bits 0-11), start of
            frame (14), end of frame (15), ...; transmit: control - the
            length (bits 0-13), last buffer of the frame (15), no check
            sequence (16), errors (27-29), wrap (30), "used" (31: 1 when
            the GEM is done with it, or software has not given it)
    word 2  the buffer address's high 32 bits
    word 3  unused

  The driver writes them in an order the GEM can follow (a receive
  descriptor's high word before its low word, which gives it to the
  GEM; a transmit descriptor's control word last); this unit only
  composes and reads the words. Plain Pascal, checked on the host
  (make gem-descriptor-test).
}
unit Drivers.CadenceGem.Descriptors;

{$mode objfpc}

interface

const
  GemDescriptorBytes = 16;

  ReceiveUsed = LongWord(1) shl 0;
  ReceiveWrap = LongWord(1) shl 1;
  ReceiveAddressMask = LongWord($FFFFFFFC);
  ReceiveLengthMask = $FFF;
  ReceiveStartOfFrame = LongWord(1) shl 14;
  ReceiveEndOfFrame = LongWord(1) shl 15;

  TransmitLengthMask = $3FFF;
  TransmitLastBuffer = LongWord(1) shl 15;
  TransmitNoCheckSequence = LongWord(1) shl 16;
  TransmitErrorsMask = LongWord(7) shl 27;
  TransmitWrap = LongWord(1) shl 30;
  TransmitUsed = LongWord(1) shl 31;

type
  PGemDescriptor = ^TGemDescriptor;
  TGemDescriptor = packed record
    AddressLow: LongWord;
    Control: LongWord;
    AddressHigh: LongWord;
    Reserved: LongWord;
  end;

{ Receive: word 0 handing a buffer at BusAddress (4-byte aligned) to the
  GEM, IsLast for the ring's last descriptor. }
function ReceiveAddressWord(BusAddress: QWord; IsLast: Boolean): LongWord;
{ Receive: word 0 of a descriptor the GEM filled, given back as it was
  (used cleared). }
function ReceiveReturnedWord(AddressWord: LongWord): LongWord;
function ReceiveIsFilled(AddressWord: LongWord): Boolean;
{ The frame's length (without the check sequence the GEM drops) and
  whether it lies in this one buffer. }
function ReceivedFrameLength(Status: LongWord): LongWord;
function ReceivedWholeFrame(Status: LongWord): Boolean;

{ Transmit: the control word giving a frame of Length bytes in one
  buffer to the GEM, IsLast for the ring's last descriptor. }
function TransmitControlWord(Length: LongWord; IsLast: Boolean): LongWord;
{ Transmit: the control word of a descriptor software keeps. }
function TransmitIdleWord(IsLast: Boolean): LongWord;
function TransmitIsDone(Control: LongWord): Boolean;
function TransmitFailed(Control: LongWord): Boolean;

function AddressHighWord(BusAddress: QWord): LongWord;

implementation

function ReceiveAddressWord(BusAddress: QWord; IsLast: Boolean): LongWord;
begin
  Result := LongWord(BusAddress and ReceiveAddressMask);
  if IsLast then
    Result := Result or ReceiveWrap;
end;

function ReceiveReturnedWord(AddressWord: LongWord): LongWord;
begin
  Result := AddressWord and not ReceiveUsed;
end;

function ReceiveIsFilled(AddressWord: LongWord): Boolean;
begin
  Result := (AddressWord and ReceiveUsed) <> 0;
end;

function ReceivedFrameLength(Status: LongWord): LongWord;
begin
  Result := Status and ReceiveLengthMask;
end;

function ReceivedWholeFrame(Status: LongWord): Boolean;
begin
  Result := (Status and (ReceiveStartOfFrame or ReceiveEndOfFrame)) = (ReceiveStartOfFrame or ReceiveEndOfFrame);
end;

function TransmitControlWord(Length: LongWord; IsLast: Boolean): LongWord;
begin
  Result := (Length and TransmitLengthMask) or TransmitLastBuffer;
  if IsLast then
    Result := Result or TransmitWrap;
end;

function TransmitIdleWord(IsLast: Boolean): LongWord;
begin
  Result := TransmitUsed;
  if IsLast then
    Result := Result or TransmitWrap;
end;

function TransmitIsDone(Control: LongWord): Boolean;
begin
  Result := (Control and TransmitUsed) <> 0;
end;

function TransmitFailed(Control: LongWord): Boolean;
begin
  Result := (Control and TransmitErrorsMask) <> 0;
end;

function AddressHighWord(BusAddress: QWord): LongWord;
begin
  Result := LongWord(BusAddress shr 32);
end;

end.
