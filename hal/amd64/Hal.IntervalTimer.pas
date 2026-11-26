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

  Its input clock runs at a fixed, known frequency, which makes it a
  reference for measuring the speed of the time stamp counter and the
  local APIC timer where nothing better is known (Hal.ClockCalibration).
  Only channel 2 is used, because its output can be read back through
  port 0x61 without involving interrupts.

  Many recent PCs gate the PIT off (or the chipset no longer has one),
  and QEMU can leave it out (-machine pit=off): reads of its ports then
  return all ones. IntervalTimerIsPresent looks first (channel 2's
  latched count must go down), and a busy wait gives up after a bound
  of reads rather than hang.

  Channel 0 drives IRQ 0, which the HPET's comparator may be routed to
  (input 2, Hal.HpetInterrupts): SilenceIntervalTimerOutput stops it
  (mode 0 without a count: its output stays low), so firmware's 18.2 Hz
  tick does not reach that input.
}
unit Hal.IntervalTimer;

{$mode objfpc}

interface

const
  IntervalTimerFrequency = 1193182;

{ Busy-waits for the given number of microseconds (at most about 54 ms)
  using timer channel 2. False if the timer never got there (it is not
  there). }
function IntervalTimerBusyWait(Microseconds: LongWord): Boolean;
{ Whether the timer counts (checked once, then remembered). }
function IntervalTimerIsPresent: Boolean;
{ Stops channel 0, so it raises IRQ 0 no more. }
procedure SilenceIntervalTimerOutput;

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
  { Channel 2, latch the count. }
  Channel2LatchCommand = $80;
  { Channel 0, low then high byte, mode 0: output low until a count is
    written. }
  Channel0StopCommand = $30;
  { A 54 ms wait takes far fewer port reads than this on any machine. }
  MaximumWaitReads = 50000000;
  { Reads of the latched count until it must have moved. }
  PresenceReads = 100000;

type
  TPresence = (PresenceUnknown, PresenceYes, PresenceNo);

var
  Presence: TPresence = PresenceUnknown;

function IntervalTimerBusyWait(Microseconds: LongWord): Boolean;
var
  Count: QWord;
  Control: Byte;
  Reads: LongWord;
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

  Reads := 0;
  while ((ReadPortByte(SpeakerControlPort) and Channel2OutputHigh) = 0) and (Reads < MaximumWaitReads) do
    Inc(Reads);
  Result := Reads < MaximumWaitReads;

  WritePortByte(SpeakerControlPort, Control);
end;

function ReadChannel2Count: LongWord;
var
  Low: Byte;
  High: Byte;
begin
  WritePortByte(ModeCommandPort, Channel2LatchCommand);
  Low := ReadPortByte(Channel2DataPort);
  High := ReadPortByte(Channel2DataPort);
  Result := LongWord(Low) or (LongWord(High) shl 8);
end;

function ProbeTimer: Boolean;
var
  Control: Byte;
  First: LongWord;
  Later: LongWord;
  Reads: LongWord;
begin
  Control := ReadPortByte(SpeakerControlPort);
  Control := Control and not (SpeakerGateEnable or SpeakerDataEnable);
  WritePortByte(SpeakerControlPort, Control);
  WritePortByte(ModeCommandPort, Channel2OneShotCommand);
  WritePortByte(Channel2DataPort, Byte(MaximumCount and $FF));
  WritePortByte(Channel2DataPort, Byte(MaximumCount shr 8));
  WritePortByte(SpeakerControlPort, Control or SpeakerGateEnable);
  First := ReadChannel2Count;
  Result := False;
  Reads := 0;
  while Reads < PresenceReads do
  begin
    Later := ReadChannel2Count;
    if Later <> First then
    begin
      { Counting down (an absent timer reads all ones throughout). }
      Result := Later < First;
      Break;
    end;
    Inc(Reads);
  end;
  WritePortByte(SpeakerControlPort, Control);
end;

function IntervalTimerIsPresent: Boolean;
begin
  if Presence = PresenceUnknown then
  begin
    if ProbeTimer then
      Presence := PresenceYes
    else
      Presence := PresenceNo;
  end;
  Result := Presence = PresenceYes;
end;

procedure SilenceIntervalTimerOutput;
begin
  WritePortByte(ModeCommandPort, Channel0StopCommand);
end;

end.
