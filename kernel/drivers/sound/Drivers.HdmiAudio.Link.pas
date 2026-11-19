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
  The HDMI link the firmware set up, read and never changed: audio
  rides on it, so the mode, the PHY and the clocks stay as they are.

  The TMDS character clock, which N and CTS are worked out from, is not
  a clock the firmware names (on the BCM2711/2712 the PHY's PLL makes
  it), so it is measured: the timing registers give the whole frame
  (active + front porch + sync + back porch, across and down; pixel
  repetition is already in the horizontal counts), the port's frame
  counter in the "hd" block gives the frame rate (frames counted
  between two counter changes about 400 ms apart, timed with the
  generic timer, whose crystal also drives the PHY's PLL), and the
  general control packet the colour depth (30 or 36-bit deep colour
  send 10/8 or 12/8 as many characters). The product lands within a few
  parts per million of the mode's clock, close enough to tell 148.5 MHz
  from 148.35 MHz (148.5 / 1.001); the N/CTS table then takes over
  (Drivers.HdmiAudio.Format). If the counter does not move, 60 Hz is
  assumed and said so.

  Timing fields (BCM2711/2712): HORZA active 0-13, front porch 16-28;
  HORZB sync 0-10, back porch 16-26; VERTA0 active 0-12, front porch
  16-22, sync 24-28; VERTB0 back porch 0-8.
}
unit Drivers.HdmiAudio.Link;

{$mode objfpc}

interface

uses
  Drivers.HdmiAudio.Port;

type
  THdmiLink = record
    ActiveWidth: LongWord;
    ActiveHeight: LongWord;
    TotalWidth: LongWord;
    TotalHeight: LongWord;
    { The frame rate in thousandths of a hertz; 0 if not measured. }
    RefreshMillihertz: QWord;
    RefreshMeasured: Boolean;
    { 24, 30 or 36 bits a pixel. }
    BitsPerPixel: LongWord;
    PixelHertz: QWord;
    TmdsHertz: QWord;
  end;

{ Reads the mode and measures the frame rate (sleeps about half a
  second). False if the timing registers hold no mode. }
function ReadHdmiLink(Port: PHdmiPort; out Link: THdmiLink): Boolean;

implementation

uses
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Arch.Cpu;

const
  MeasureMilliseconds = 400;
  EdgeTimeoutNanoseconds = 100000000;
  AssumedRefreshMillihertz = 60000;

  DeepColour30 = 5;
  DeepColour36 = 6;
  DeepColour48 = 7;

function Field(Value: LongWord; Shift, Bits: LongWord): LongWord;
begin
  Result := (Value shr Shift) and ((LongWord(1) shl Bits) - 1);
end;

{ Waits for the frame counter to change from what it reads now; the
  time it did, and the new count. False if it did not within 100 ms. }
function WaitForFrame(Port: PHdmiPort; out Count: LongWord; out Nanoseconds: QWord): Boolean;
var
  Start: LongWord;
  Deadline: QWord;
begin
  Start := ReadHd(Port, Port^.Mai.FrameCount);
  Deadline := ClockNanoseconds + EdgeTimeoutNanoseconds;
  repeat
    Count := ReadHd(Port, Port^.Mai.FrameCount);
    Nanoseconds := ClockNanoseconds;
    if Count <> Start then
      Exit(True);
    CpuRelax;
  until Nanoseconds > Deadline;
  Result := False;
end;

function BitsPerPixelOf(Port: PHdmiPort): LongWord;
var
  Depth: LongWord;
begin
  Result := 24;
  if (ReadCore(Port, HdmiGeneralControlPacketConfig) and GeneralControlPacketEnable) = 0 then
    Exit;
  Depth := Field(ReadCore(Port, HdmiGeneralControlPacketWord1), 8, 8);
  case Depth of
    DeepColour30: Result := 30;
    DeepColour36: Result := 36;
    DeepColour48: Result := 48;
  end;
end;

function ReadHdmiLink(Port: PHdmiPort; out Link: THdmiLink): Boolean;
var
  HorizontalA: LongWord;
  HorizontalB: LongWord;
  VerticalA: LongWord;
  VerticalB: LongWord;
  FirstCount: LongWord;
  LastCount: LongWord;
  FirstTime: QWord;
  LastTime: QWord;
  Frames: LongWord;
  Elapsed: QWord;
begin
  HorizontalA := ReadCore(Port, HdmiHorizontalA);
  HorizontalB := ReadCore(Port, HdmiHorizontalB);
  VerticalA := ReadCore(Port, HdmiVerticalA0);
  VerticalB := ReadCore(Port, HdmiVerticalB0);
  Link.ActiveWidth := Field(HorizontalA, 0, 14);
  Link.TotalWidth := Link.ActiveWidth + Field(HorizontalA, 16, 13) + Field(HorizontalB, 0, 11) +
    Field(HorizontalB, 16, 11);
  Link.ActiveHeight := Field(VerticalA, 0, 13);
  Link.TotalHeight := Link.ActiveHeight + Field(VerticalA, 16, 7) + Field(VerticalA, 24, 5) + Field(VerticalB, 0, 9);
  Link.BitsPerPixel := BitsPerPixelOf(Port);
  Link.RefreshMillihertz := 0;
  Link.RefreshMeasured := False;
  Link.PixelHertz := 0;
  Link.TmdsHertz := 0;
  Result := (Link.ActiveWidth <> 0) and (Link.ActiveHeight <> 0);
  if not Result then
    Exit;

  if WaitForFrame(Port, FirstCount, FirstTime) then
  begin
    SleepMilliseconds(MeasureMilliseconds);
    if WaitForFrame(Port, LastCount, LastTime) and (LastTime > FirstTime) then
    begin
      Frames := LastCount - FirstCount;
      Elapsed := LastTime - FirstTime;
      if (Frames > 0) and (Frames < 1000) then
      begin
        Link.RefreshMeasured := True;
        Link.RefreshMillihertz := (QWord(Frames) * 1000000000000 + Elapsed div 2) div Elapsed;
        Link.PixelHertz := (QWord(Link.TotalWidth) * Link.TotalHeight * Frames * 1000000000 + Elapsed div 2) div
          Elapsed;
      end;
    end;
  end;
  if not Link.RefreshMeasured then
  begin
    Link.RefreshMillihertz := AssumedRefreshMillihertz;
    Link.PixelHertz := QWord(Link.TotalWidth) * Link.TotalHeight * AssumedRefreshMillihertz div 1000;
  end;
  Link.TmdsHertz := Link.PixelHertz * Link.BitsPerPixel div 24;
end;

end.
