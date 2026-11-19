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
  Host test of what the Raspberry Pi 5's HDMI audio computes without
  the hardware (make hdmi-audio-test):

  - N and CTS against the HDMI specification's table for every clock it
    lists (25.2 to 594 MHz, each also divided by 1.001) at 32, 44.1 and
    48 kHz, the multiples of 44.1 and 48 kHz, a measured clock a little
    off a table clock, and clocks the table does not list;
  - the MAI's sample rate codes and sample clock fractions of 108 MHz;
  - IEC 60958 subframes: preambles, parity, the channel status bits,
    blocks continuing across a slot, and the driver's 48 slots being a
    whole number of blocks;
  - the audio InfoFrame, its checksum and its packet RAM words;
  - the BCM2712 DMA's 40-bit control blocks and the "dmas" cells of the
    Pi 5's HDMI nodes (Drivers.Bcm2712Dma.Blocks).

  Prints every failed check and exits with 1 if there was one.
}
program HdmiAudioTest;

{$mode objfpc}

uses
  SysUtils,
  Drivers.HdmiAudio.Format,
  Drivers.Bcm2712Dma.Blocks;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('HDMI AUDIO TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: QWord; const What: string);
begin
  Check(Actual = Expected, What + ' is ' + IntToStr(Actual) + ' ($' + IntToHex(Actual, 1) + '), expected ' +
    IntToStr(Expected) + ' ($' + IntToHex(Expected, 1) + ')');
end;

{ --- N and CTS ------------------------------------------------------------ }

type
  TSpecificationRow = record
    ClockHertz: QWord;
    N32, Cts32: LongWord;
    N44, Cts44: LongWord;
    N48, Cts48: LongWord;
  end;

const
  { The HDMI specification's recommended N and CTS (the clocks divided
    by 1.001 to the hertz). Where the specification alternates two CTS
    values (32 kHz at 74.176 MHz: 210937/210938) the rounded average is
    expected. }
  SpecificationRows: array[0..13] of TSpecificationRow = (
    (ClockHertz: 25174825; N32: 4576; Cts32: 28125; N44: 7007; Cts44: 31250; N48: 6864; Cts48: 28125),
    (ClockHertz: 25200000; N32: 4096; Cts32: 25200; N44: 6272; Cts44: 28000; N48: 6144; Cts48: 25200),
    (ClockHertz: 27000000; N32: 4096; Cts32: 27000; N44: 6272; Cts44: 30000; N48: 6144; Cts48: 27000),
    (ClockHertz: 27027000; N32: 4096; Cts32: 27027; N44: 6272; Cts44: 30030; N48: 6144; Cts48: 27027),
    (ClockHertz: 54000000; N32: 4096; Cts32: 54000; N44: 6272; Cts44: 60000; N48: 6144; Cts48: 54000),
    (ClockHertz: 54054000; N32: 4096; Cts32: 54054; N44: 6272; Cts44: 60060; N48: 6144; Cts48: 54054),
    (ClockHertz: 74175824; N32: 11648; Cts32: 210938; N44: 17836; Cts44: 234375; N48: 11648; Cts48: 140625),
    (ClockHertz: 74250000; N32: 4096; Cts32: 74250; N44: 6272; Cts44: 82500; N48: 6144; Cts48: 74250),
    (ClockHertz: 148351648; N32: 11648; Cts32: 421875; N44: 8918; Cts44: 234375; N48: 5824; Cts48: 140625),
    (ClockHertz: 148500000; N32: 4096; Cts32: 148500; N44: 6272; Cts44: 165000; N48: 6144; Cts48: 148500),
    (ClockHertz: 296703297; N32: 5824; Cts32: 421875; N44: 4459; Cts44: 234375; N48: 5824; Cts48: 281250),
    (ClockHertz: 297000000; N32: 3072; Cts32: 222750; N44: 4704; Cts44: 247500; N48: 5120; Cts48: 247500),
    (ClockHertz: 593406593; N32: 5824; Cts32: 843750; N44: 8918; Cts44: 937500; N48: 5824; Cts48: 562500),
    (ClockHertz: 594000000; N32: 3072; Cts32: 445500; N44: 9408; Cts44: 990000; N48: 6144; Cts48: 594000));

procedure CheckRegeneration(ClockHertz: QWord; Rate: LongWord; ExpectedN, ExpectedCts: LongWord;
  ExpectTable: Boolean);
var
  Values: TAudioClockRegeneration;
  Name: string;
begin
  Name := IntToStr(ClockHertz) + ' Hz at ' + IntToStr(Rate) + ' Hz';
  Check(ComputeAudioClockRegeneration(ClockHertz, Rate, Values), 'N/CTS for ' + Name);
  CheckNumber(Values.N, ExpectedN, 'N for ' + Name);
  CheckNumber(Values.Cts, ExpectedCts, 'CTS for ' + Name);
  Check(Values.FromTable = ExpectTable, 'table use for ' + Name);
  { What the sink rebuilds: 128 x fs = f x N / CTS, to 0.01%. }
  Check(Abs(Double(ClockHertz) * Values.N / Values.Cts - 128.0 * Rate) < 128.0 * Rate / 10000,
    'the rebuilt sample clock for ' + Name);
end;

procedure TestClockRegeneration;
var
  Index: Integer;
  Values: TAudioClockRegeneration;
begin
  for Index := Low(SpecificationRows) to High(SpecificationRows) do
    with SpecificationRows[Index] do
    begin
      CheckRegeneration(ClockHertz, 32000, N32, Cts32, True);
      CheckRegeneration(ClockHertz, 44100, N44, Cts44, True);
      CheckRegeneration(ClockHertz, 48000, N48, Cts48, True);
      { Twice and four times the rate: twice and four times N, same CTS. }
      CheckRegeneration(ClockHertz, 88200, N44 * 2, Cts44, True);
      CheckRegeneration(ClockHertz, 96000, N48 * 2, Cts48, True);
      CheckRegeneration(ClockHertz, 176400, N44 * 4, Cts44, True);
      CheckRegeneration(ClockHertz, 192000, N48 * 4, Cts48, True);
    end;
  { 1080p60 as the driver measures it: a few ppm off. }
  CheckRegeneration(148500450, 48000, 6144, 148500, True);
  CheckRegeneration(148499100, 44100, 6272, 165000, True);
  { 59.94 Hz, measured. }
  CheckRegeneration(148351700, 48000, 5824, 140625, True);
  { Clocks the table does not list: N = 128 x fs / 1000. }
  CheckRegeneration(65000000, 48000, 6144, 65000, False);
  CheckRegeneration(108000000, 48000, 6144, 108000, False);
  CheckRegeneration(108000000, 44100, 6272, 120000, False);
  CheckRegeneration(154000000, 32000, 4096, 154000, False);
  CheckRegeneration(241500000, 48000, 6144, 241500, False);
  { Rates HDMI does not carry, and no clock. }
  Check(not ComputeAudioClockRegeneration(148500000, 22050, Values), 'no N/CTS at 22.05 kHz');
  Check(not ComputeAudioClockRegeneration(0, 48000, Values), 'no N/CTS without a clock');
end;

{ --- The MAI ---------------------------------------------------------------- }

procedure CheckSampleClock(AudioHertz, Rate, ExpectedN, ExpectedM: LongWord);
var
  N, M: LongWord;
  Name: string;
begin
  Name := IntToStr(AudioHertz) + ' / ' + IntToStr(Rate);
  Check(ComputeMaiSampleClock(AudioHertz, Rate, N, M), 'a sample clock for ' + Name);
  CheckNumber(N, ExpectedN, 'the sample clock N of ' + Name);
  CheckNumber(M, ExpectedM, 'the sample clock M of ' + Name);
end;

procedure TestMai;
var
  N, M: LongWord;
begin
  CheckNumber(MaiSampleRateCode(48000), 9, 'the MAI code of 48 kHz');
  CheckNumber(MaiSampleRateCode(44100), 8, 'the MAI code of 44.1 kHz');
  CheckNumber(MaiSampleRateCode(32000), 7, 'the MAI code of 32 kHz');
  CheckNumber(MaiSampleRateCode(192000), 15, 'the MAI code of 192 kHz');
  CheckNumber(MaiSampleRateCode(12345), 0, 'the MAI code of an odd rate');
  CheckSampleClock(108000000, 48000, 2250, 1);
  CheckSampleClock(108000000, 44100, 120000, 49);
  CheckSampleClock(108000000, 32000, 3375, 1);
  CheckSampleClock(108000000, 96000, 1125, 1);
  CheckSampleClock(108000000, 88200, 60000, 49);
  { A clock with no exact fraction: the best within the register's
    limits, close to the true ratio. }
  Check(ComputeMaiSampleClock(108000001, 44100, N, M), 'a sample clock for 108000001 / 44100');
  Check((N <= MaiSampleClockMaximumN) and (M >= 1) and (M <= MaiSampleClockMaximumM),
    'the approximate sample clock fits the register');
  Check(Abs(Double(N) / M - 108000001.0 / 44100) < 0.001, 'the approximate sample clock is close');
  CheckNumber(MaiChannelMap($3), $10, 'the stereo channel map');
  CheckNumber(MaiChannelMap($FF), $76543210, 'the eight-channel map');
end;

{ --- IEC 60958 -------------------------------------------------------------- }

procedure TestSubframes;
var
  Status: TChannelStatus;
  Samples: array[0..7] of SmallInt;
  Words: array[0..7] of LongWord;
  Frame: LongWord;
  Ones: LongWord;
  Bit: LongWord;
  Index: Integer;
begin
  BuildChannelStatus(48000, Status);
  CheckNumber(Status[0], $04, 'channel status byte 0 (consumer, PCM, copying permitted)');
  CheckNumber(Status[1], $82, 'channel status byte 1 (PCM encoder, original)');
  CheckNumber(Status[3], $02, 'channel status byte 3 at 48 kHz');
  CheckNumber(Status[4], $02, 'channel status byte 4 (16-bit words)');
  BuildChannelStatus(44100, Status);
  CheckNumber(Status[3], $00, 'channel status byte 3 at 44.1 kHz');
  BuildChannelStatus(48000, Status);
  Check(not ChannelStatusBit(Status, 0), 'status bit 0 (professional) clear');
  Check(ChannelStatusBit(Status, 2), 'status bit 2 (copying permitted) set');
  Check(ChannelStatusBit(Status, 25), 'status bit 25 (48 kHz) set');
  Check(ChannelStatusBit(Status, 192 + 2), 'status bits repeat every block');

  CheckNumber(MakeSubframe(0, 0, 0, Status), $00000008, 'a block''s first left subframe (Z)');
  CheckNumber(MakeSubframe(0, 1, 0, Status), $00000004, 'a right subframe (Y)');
  CheckNumber(MakeSubframe(0, 0, 1, Status), $00000002, 'a left subframe (X)');
  CheckNumber(MakeSubframe(0, 0, 2, Status), $C0000002, 'the channel status bit with its parity');
  CheckNumber(MakeSubframe($7FFF, 0, 1, Status), $87FFF002, 'the largest sample (odd parity)');
  CheckNumber(MakeSubframe(-1, 1, 1, Status), $0FFFF004, 'sample -1 (even parity)');
  CheckNumber(MakeSubframe(-32768, 0, 1, Status), $88000002, 'the smallest sample');
  { Parity: bits 4-31 always hold an even number of ones. }
  for Index := -40 to 40 do
  begin
    Words[0] := MakeSubframe(SmallInt(Index * 811), Index and 1, LongWord(Index + 40), Status);
    Ones := 0;
    for Bit := 4 to 31 do
      if (Words[0] and (LongWord(1) shl Bit)) <> 0 then
        Inc(Ones);
    Check(not Odd(Ones), 'even parity for sample ' + IntToStr(Index * 811));
  end;

  { Four frames across the end of a block: the third starts the next. }
  for Index := 0 to 7 do
    Samples[Index] := SmallInt(Index * 1000);
  PackSubframes(@Samples[0], @Words[0], 4, 190, Status);
  for Frame := 0 to 3 do
  begin
    CheckNumber(Words[Frame * 2] shr 12 and $FFFF, Word(Samples[Frame * 2]), 'packed left sample ' + IntToStr(Frame));
    CheckNumber(Words[Frame * 2 + 1] shr 12 and $FFFF, Word(Samples[Frame * 2 + 1]),
      'packed right sample ' + IntToStr(Frame));
    CheckNumber(Words[Frame * 2 + 1] and $F, SubframePreambleY, 'the right preamble of frame ' + IntToStr(Frame));
  end;
  CheckNumber(Words[0] and $F, SubframePreambleX, 'frame 190''s preamble');
  CheckNumber(Words[4] and $F, SubframePreambleZ, 'the next block''s first preamble');
  CheckNumber(Words[6] and $F, SubframePreambleX, 'frame 1''s preamble');
  { Silence still carries the status bits. }
  PackSubframes(nil, @Words[0], 4, 0, Status);
  CheckNumber(Words[0], $00000008, 'silence, frame 0');
  CheckNumber(Words[4], $C0000002, 'silence, frame 2 (status bit)');
  { The driver's 48 slots of 1024 frames are 256 whole blocks, so the
    DMA going round keeps the blocks' rhythm. }
  CheckNumber((48 * 1024) mod FramesPerBlock, 0, 'the slots as whole blocks');
end;

{ --- The audio InfoFrame -------------------------------------------------- }

procedure TestInfoFrame;
var
  Frame: TAudioInfoFrame;
  Words: TPacketRamWords;
  Sum: LongWord;
  Index: Integer;
begin
  BuildAudioInfoFrame(2, Frame);
  CheckNumber(Frame[0], $84, 'the InfoFrame type');
  CheckNumber(Frame[1], 1, 'the InfoFrame version');
  CheckNumber(Frame[2], 10, 'the InfoFrame length');
  CheckNumber(Frame[4], 1, 'the channel count (2 channels: CC = 1)');
  CheckNumber(Frame[7], 0, 'the speaker allocation (front left and right)');
  CheckNumber(Frame[3], $70, 'the checksum');
  Sum := 0;
  for Index := 0 to AudioInfoFrameBytes - 1 do
    Sum := Sum + Frame[Index];
  CheckNumber(Sum and $FF, 0, 'the InfoFrame''s bytes summed');
  InfoFrameToPacketWords(Frame, Words);
  CheckNumber(Words[0], $000A0184, 'packet word 0 (the header)');
  CheckNumber(Words[1], $00000170, 'packet word 1 (checksum, CC)');
  for Index := 2 to PacketRamWords - 1 do
    CheckNumber(Words[Index], 0, 'packet word ' + IntToStr(Index));
  BuildAudioInfoFrame(8, Frame);
  CheckNumber(Frame[4], 7, 'the channel count of 8 channels');
end;

{ --- DMA control blocks ---------------------------------------------------- }

procedure TestDmaBlocks;
var
  Request: TDmaRequest;
  Block: TDma40ControlBlock;
  AddressWord: LongWord;
begin
  CheckNumber(SizeOf(TDma40ControlBlock), Dma40ControlBlockBytes, 'the control block size');
  CheckNumber(PtrUInt(@Block.NextControlBlock) - PtrUInt(@Block), $18, 'the next block''s offset');

  { hdmi0's cell in the Pi 5 (C1) tree: DREQ 10, QoS 10, panic 15, wide
    source, bursts. }
  Request := DecodeDmaRequestCell($41FA000A);
  CheckNumber(Request.Dreq, 10, 'hdmi0''s DREQ');
  CheckNumber(Request.Priority, 10, 'hdmi0''s priority');
  CheckNumber(Request.PanicPriority, 15, 'hdmi0''s panic priority');
  Check(Request.WideSource, 'hdmi0 reads wide');
  Check(not Request.WideDestination, 'hdmi0 writes 32 bits');
  Check(Request.Burst, 'hdmi0 bursts');
  Check(not Request.NoWaitResponse, 'hdmi0 waits for write responses');
  CheckNumber(DecodeDmaRequestCell($41FA0011).Dreq, 17, 'hdmi1''s DREQ (C1)');
  CheckNumber(DecodeDmaRequestCell($41FA000C).Dreq, 12, 'hdmi0''s DREQ (D0)');

  Check(FillMemoryToDeviceBlock(Block, QWord($123456000), QWord($107C72001C), 8192, $20000020, Request, False),
    'a block to the MAI');
  CheckNumber(Block.TransferInformation, $9404, 'TI (writes paced by DREQ 10, wait for responses)');
  CheckNumber(Block.SourceAddress, $23456000, 'SRC');
  CheckNumber(Block.SourceInformation, $5301, 'SRCI (high byte 1, burst 3, increment, 128-bit)');
  CheckNumber(Block.DestinationAddress, $7C72001C, 'DEST');
  CheckNumber(Block.DestinationInformation, $310, 'DESTI (high byte 10h, burst 3, fixed, 32-bit)');
  CheckNumber(Block.TransferLength, 8192, 'LEN');
  CheckNumber(Block.NextControlBlock, $01000001, 'NEXT_CB (bus address / 32)');
  CheckNumber(Block.Reserved, 0, 'the reserved word');
  Check(FillMemoryToDeviceBlock(Block, 0, $107C72001C, 4096, $20000020, Request, True), 'a block that interrupts');
  CheckNumber(Block.TransferInformation and Dma40InterruptEnable, Dma40InterruptEnable, 'TI interrupt enable');
  Check(not FillMemoryToDeviceBlock(Block, 0, $107C72001C, 4096, $20000010, Request, False),
    'a next block off 32 bytes refused');
  Check(not FillMemoryToDeviceBlock(Block, QWord(1) shl 40, $107C72001C, 4096, $20000020, Request, False),
    'a source beyond 40 bits refused');
  Check(ControlBlockAddressWord($1FFFFFFFE0, AddressWord), 'the highest block address');
  CheckNumber(AddressWord, $FFFFFFFF, 'the highest block address word');
  Check(not ControlBlockAddressWord($2000000000, AddressWord), 'a block at 128 GiB refused');
  CheckNumber(ChannelStartControl(Request), $00FA0301, 'CS to start (active, protection, QoS 10, panic 15)');
  CheckNumber(Dma40Address($7C72001C, $5310), $107C72001C, 'a 40-bit address from SRC and SRCI');
end;

begin
  TestClockRegeneration;
  TestMai;
  TestSubframes;
  TestInfoFrame;
  TestDmaBlocks;
  if Failures > 0 then
  begin
    WriteLn('HDMI AUDIO TEST: ', Failures, ' failed');
    Halt(1);
  end;
  WriteLn('HDMI AUDIO TEST: all passed');
end.
