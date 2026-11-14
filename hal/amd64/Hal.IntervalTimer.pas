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
