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
  Host test of the Cadence GEM's descriptors (make gem-descriptor-test,
  Drivers.CadenceGem.Descriptors): the 16-byte layout of the 64-bit
  form, receive words for buffers above 4 GiB (RP1 sees RAM at
  10_0000_0000), the wrap bit on the last descriptor, the used bit both
  ways, frame lengths and whole frames, transmit control words with
  their length, last-buffer and wrap bits, completion and errors, and a
  small ring as the GEM and the driver would pass it back and forth.

  Prints every failed check and exits with 1 if there was one.
}
program GemDescriptorTest;

{$mode objfpc}

uses
  SysUtils,
  Drivers.CadenceGem.Descriptors;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('GEM DESCRIPTOR TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: QWord; const What: string);
begin
  Check(Actual = Expected, What + ' is $' + IntToHex(Actual, 1) + ', expected $' + IntToHex(Expected, 1));
end;

procedure TestLayout;
var
  Descriptor: TGemDescriptor;
begin
  CheckNumber(SizeOf(TGemDescriptor), GemDescriptorBytes, 'the descriptor size');
  CheckNumber(PtrUInt(@Descriptor.Control) - PtrUInt(@Descriptor), 4, 'the control word''s offset');
  CheckNumber(PtrUInt(@Descriptor.AddressHigh) - PtrUInt(@Descriptor), 8, 'the high address word''s offset');
end;

procedure TestReceive;
const
  Buffer = QWord($1012345800);
var
  Word0: LongWord;
begin
  Word0 := ReceiveAddressWord(Buffer, False);
  CheckNumber(Word0, $12345800, 'a receive buffer''s low word');
  CheckNumber(AddressHighWord(Buffer), $10, 'a receive buffer''s high word');
  Check(not ReceiveIsFilled(Word0), 'a buffer handed over is the GEM''s');
  CheckNumber(ReceiveAddressWord(Buffer, True), $12345802, 'the last descriptor wraps');
  CheckNumber(ReceiveAddressWord(QWord($1000000803), False), $800, 'the low two bits are flags, not address');
  { The GEM fills it: used set. }
  Check(ReceiveIsFilled($12345803), 'a filled descriptor');
  CheckNumber(ReceiveReturnedWord($12345803), $12345802, 'given back: used cleared, wrap kept');
  CheckNumber(ReceivedFrameLength($0000C05E), $5E, 'a 94-byte frame');
  Check(ReceivedWholeFrame($0000C05E), 'start and end of frame in one buffer');
  Check(not ReceivedWholeFrame($0000405E), 'a frame without its end');
  Check(not ReceivedWholeFrame($0000805E), 'a frame without its start');
  CheckNumber(ReceivedFrameLength($8000C5EA), $5EA, 'a 1514-byte broadcast frame');
end;

procedure TestTransmit;
var
  Control: LongWord;
begin
  Control := TransmitControlWord(60, False);
  CheckNumber(Control, $803C, 'a 60-byte frame in one buffer');
  Check(not TransmitIsDone(Control), 'a frame handed over is the GEM''s');
  CheckNumber(TransmitControlWord(1514, True), $400085EA, 'the last descriptor wraps');
  CheckNumber(TransmitControlWord($14000, False) and TransmitLengthMask, 0, 'the length is 14 bits');
  CheckNumber(TransmitIdleWord(False), $80000000, 'a descriptor software keeps');
  CheckNumber(TransmitIdleWord(True), $C0000000, 'the last one software keeps');
  Check(TransmitIsDone($8000803C), 'the GEM sets used when done');
  Check(not TransmitFailed($8000803C), 'a frame sent');
  Check(TransmitFailed($A000803C), 'a frame with a transmit error');
  Check(TransmitFailed($9000803C), 'a frame with an underrun');
end;

procedure TestRing;
const
  Size = 4;
var
  Ring: array[0..Size - 1] of TGemDescriptor;
  Index: Integer;
  Consumer: Integer;
  Taken: Integer;
begin
  for Index := 0 to Size - 1 do
  begin
    Ring[Index].AddressHigh := AddressHighWord(QWord($1000000000) + QWord(Index) * 2048);
    Ring[Index].AddressLow := ReceiveAddressWord(QWord($1000000000) + QWord(Index) * 2048, Index = Size - 1);
    Ring[Index].Control := 0;
  end;
  { The GEM fills the first three. }
  for Index := 0 to 2 do
  begin
    Ring[Index].Control := ReceiveStartOfFrame or ReceiveEndOfFrame or LongWord(64 + Index);
    Ring[Index].AddressLow := Ring[Index].AddressLow or ReceiveUsed;
  end;
  Consumer := 0;
  Taken := 0;
  while ReceiveIsFilled(Ring[Consumer].AddressLow) and (Taken < Size) do
  begin
    CheckNumber(ReceivedFrameLength(Ring[Consumer].Control), 64 + Consumer, 'frame ' + IntToStr(Consumer));
    Ring[Consumer].Control := 0;
    Ring[Consumer].AddressLow := ReceiveReturnedWord(Ring[Consumer].AddressLow);
    Consumer := (Consumer + 1) mod Size;
    Inc(Taken);
  end;
  CheckNumber(Taken, 3, 'frames taken from the ring');
  CheckNumber(Consumer, 3, 'where the driver waits');
  CheckNumber(Ring[3].AddressLow and ReceiveWrap, ReceiveWrap, 'the last descriptor still wraps');
  CheckNumber(Ring[1].AddressLow, $800, 'descriptor 1 given back with its address');
  CheckNumber(Ring[1].AddressHigh, $10, 'descriptor 1''s high word');
end;

begin
  TestLayout;
  TestReceive;
  TestTransmit;
  TestRing;
  if Failures > 0 then
  begin
    WriteLn('GEM DESCRIPTOR TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('GEM DESCRIPTOR TEST PASSED');
end.
