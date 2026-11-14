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
  Legacy 8254 programmable interval timer.

  Its input clock runs at a fixed, known frequency, which makes it a good
  reference for measuring the speed of the local APIC timer. Only channel 2
  is used, because its output can be read back through port 0x61 without
  involving interrupts.
}
unit Hal.IntervalTimer;

{$mode objfpc}

interface

const
  IntervalTimerFrequency = 1193182;

{ Busy-waits for the given number of microseconds (at most about 54 ms)
  using timer channel 2. }
procedure IntervalTimerBusyWait(Microseconds: LongWord);

implementation

uses
  Hal.PortIo;

const
  Channel2DataPort = $42;
  ModeCommandPort = $43;
  SpeakerControlPort = $61;

  { Channel 2, write low byte then high byte, mode 0 (interrupt on
    terminal count), binary counting. }
  Channel2OneShotCommand = $B0;

  SpeakerGateEnable = $01;
  SpeakerDataEnable = $02;
  Channel2OutputHigh = $20;

  MaximumCount = $FFFF;

procedure IntervalTimerBusyWait(Microseconds: LongWord);
var
  Count: QWord;
  Control: Byte;
begin
  Count := (QWord(IntervalTimerFrequency) * Microseconds) div 1000000;
  if Count > MaximumCount then
    Count := MaximumCount;
  if Count = 0 then
    Count := 1;

  { Gate low while programming, and keep the speaker disconnected. }
  Control := ReadPortByte(SpeakerControlPort);
  Control := Control and not (SpeakerGateEnable or SpeakerDataEnable);
  WritePortByte(SpeakerControlPort, Control);

  WritePortByte(ModeCommandPort, Channel2OneShotCommand);
  WritePortByte(Channel2DataPort, Byte(Count and $FF));
  WritePortByte(Channel2DataPort, Byte((Count shr 8) and $FF));

  { Raising the gate starts the countdown. }
  WritePortByte(SpeakerControlPort, Control or SpeakerGateEnable);

  while (ReadPortByte(SpeakerControlPort) and Channel2OutputHigh) = 0 do
  begin
  end;

  WritePortByte(SpeakerControlPort, Control);
end;

end.
