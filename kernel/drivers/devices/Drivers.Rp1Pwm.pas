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
  RP1's second PWM block, channel 3: the Raspberry Pi 5's fan at speeds
  between off and full (untested on the board: built, never run).

  The PWM block ("raspberrypi,rp1-pwm", the second one in RP1's tree,
  at 9C000h) counts its clock: each channel has a range (the period in
  clock cycles) and a duty (the cycles it is active), a control word
  (trailing-edge mark/space mode, the FIFO's pop mask, the polarity
  bit) and an enable bit in the global control word, whose update bit
  latches the new settings (as Linux's pwm-rp1 does).

  Its clock is CLK_PWM1 of RP1's clock generator ("raspberrypi,rp1-
  clocks"), which nothing sets up unless asked: here it is taken from
  RP1's crystal (50 MHz) undivided, enabled, and read back; the
  register offsets and fields are those of Linux's clk-rp1. The fan's
  period is the device tree's 41566 ns (about 24 kHz), its signal
  inverted (the pin high stops the fan).

  Safety: anything that does not read back as written, or a tree that
  lacks a node, leaves the PWM unused, and Drivers.Rp1Fan keeps
  switching the pin as a plain output (off or full). Were the clock
  wrong after all, the PWM output would stay at one level; the pin low
  runs the fan at full speed, which errs on the cool side.
}
unit Drivers.Rp1Pwm;

{$mode objfpc}
{$pointermath on}

interface

{ Finds and sets up the PWM block and its clock; True if channel 3 can
  be driven. }
function InitializeRp1Pwm: Boolean;
function Rp1PwmIsAvailable: Boolean;
{ Drives channel 3 active for Percent of each period (inverted at the
  pin: 100 runs the fan at full speed). }
procedure SetRp1PwmDuty(Percent: LongWord);

implementation

uses
  Runtime.Atomic,
  Io.PlatformDevices,
  Debug.Output;

const
  FanChannel = 3;
  { The PWM block. }
  GlobalControl = $000;
  GlobalUpdate = LongWord(1) shl 31;
  ChannelControlBase = $014;
  ChannelRangeBase = $018;
  ChannelDutyBase = $020;
  ChannelStride = $10;
  { Trailing-edge mark/space modulation, the FIFO pop mask. }
  ChannelDefault = (LongWord(1) shl 8) or 1;
  ChannelInverted = LongWord(1) shl 3;
  PwmBlockOffset = $9C000;
  { RP1's clock generator: CLK_PWM1's control, integer divider and source
    select. }
  ClockPwm1Control = $00084;
  ClockPwm1DivideInteger = $00088;
  ClockPwm1DivideFraction = $0008C;
  ClockPwm1Select = $00090;
  ClockControlEnable = LongWord(1) shl 11;
  ClockControlAuxiliarySourceShift = 5;
  ClockControlAuxiliarySourceMask = LongWord($1F) shl 5;
  { The auxiliary source that is RP1's crystal. }
  ClockSourceCrystal = 0;
  CrystalHertz = 50000000;
  { The fan's period (the device tree's pwms cell). }
  FanPeriodNanoseconds = 41566;

var
  PwmRegisters: PByte = nil;
  ClockRegisters: PByte = nil;
  Available: Boolean = False;
  RangeCycles: LongWord = 0;

procedure WriteRegister(Base: PByte; Offset, Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Base + Offset)^ := Value;
end;

function ReadRegister(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
  FullMemoryBarrier;
end;

{ CLK_PWM1 from the crystal, divided by one, enabled; False if it does
  not read back so. }
function StartPwmClock: Boolean;
var
  Control: LongWord;
begin
  Control := ReadRegister(ClockRegisters, ClockPwm1Control);
  Control := (Control and not (ClockControlAuxiliarySourceMask or ClockControlEnable)) or
    (ClockSourceCrystal shl ClockControlAuxiliarySourceShift);
  WriteRegister(ClockRegisters, ClockPwm1Control, Control);
  WriteRegister(ClockRegisters, ClockPwm1DivideInteger, 1);
  WriteRegister(ClockRegisters, ClockPwm1DivideFraction, 0);
  WriteRegister(ClockRegisters, ClockPwm1Control, Control or ClockControlEnable);
  Result := ((ReadRegister(ClockRegisters, ClockPwm1Control) and ClockControlEnable) <> 0) and
    (ReadRegister(ClockRegisters, ClockPwm1DivideInteger) = 1);
  if Result then
    { The select register mirrors the source chosen (Linux waits on it). }
    Result := ReadRegister(ClockRegisters, ClockPwm1Select) <> High(LongWord);
end;

{ The channel's range and polarity; False if they do not read back. }
function SetUpChannel: Boolean;
var
  Base: LongWord;
begin
  RangeCycles := LongWord(QWord(FanPeriodNanoseconds) * CrystalHertz div 1000000000);
  Base := FanChannel * ChannelStride;
  WriteRegister(PwmRegisters, ChannelControlBase + Base, ChannelDefault or ChannelInverted);
  WriteRegister(PwmRegisters, ChannelRangeBase + Base, RangeCycles);
  WriteRegister(PwmRegisters, ChannelDutyBase + Base, 0);
  Result := (ReadRegister(PwmRegisters, ChannelRangeBase + Base) = RangeCycles) and
    ((ReadRegister(PwmRegisters, ChannelControlBase + Base) and ChannelInverted) <> 0);
end;

procedure SetRp1PwmDuty(Percent: LongWord);
var
  Base: LongWord;
  Global: LongWord;
begin
  if not Available then
    Exit;
  if Percent > 100 then
    Percent := 100;
  Base := FanChannel * ChannelStride;
  WriteRegister(PwmRegisters, ChannelDutyBase + Base, LongWord(QWord(RangeCycles) * Percent div 100));
  Global := ReadRegister(PwmRegisters, GlobalControl) or (LongWord(1) shl FanChannel);
  WriteRegister(PwmRegisters, GlobalControl, Global);
  WriteRegister(PwmRegisters, GlobalControl, Global or GlobalUpdate);
end;

function ProbePwm(Device: PPlatformDevice): Boolean;
var
  Length: QWord;
  Start: QWord;
begin
  Result := False;
  if PwmRegisters <> nil then
    Exit;
  { The fan's block is the one at 9C000h of RP1 (PWM1). }
  if not PlatformMemoryRange(Device, 0, Start, Length) or ((Start and $FFFFF) <> PwmBlockOffset) then
    Exit;
  PwmRegisters := PByte(MapPlatformMemory(Device, 0, Length));
  Result := PwmRegisters <> nil;
end;

function ProbeClocks(Device: PPlatformDevice): Boolean;
var
  Length: QWord;
begin
  Result := False;
  if ClockRegisters <> nil then
    Exit;
  ClockRegisters := PByte(MapPlatformMemory(Device, 0, Length));
  if (ClockRegisters <> nil) and (Length < ClockPwm1Select + 4) then
    ClockRegisters := nil;
  Result := ClockRegisters <> nil;
end;

const
  PwmIds: array[0..1] of PChar = ('raspberrypi,rp1-pwm', nil);
  ClockIds: array[0..1] of PChar = ('raspberrypi,rp1-clocks', nil);
  PwmDriver: TPlatformDriver = (
    Name: 'rp1-pwm';
    Ids: @PwmIds[0];
    Probe: @ProbePwm);
  ClockDriver: TPlatformDriver = (
    Name: 'rp1-clocks';
    Ids: @ClockIds[0];
    Probe: @ProbeClocks);

function InitializeRp1Pwm: Boolean;
begin
  Result := False;
  if Available then
    Exit(True);
  BindPlatformDriver(PwmDriver);
  BindPlatformDriver(ClockDriver);
  if (PwmRegisters = nil) or (ClockRegisters = nil) then
    Exit;
  if not StartPwmClock or not SetUpChannel then
  begin
    DebugWriteLine('[fan] RP1 PWM1 or its clock did not read back as set: the fan stays switched on and off');
    Exit;
  end;
  Available := True;
  Result := True;
end;

function Rp1PwmIsAvailable: Boolean;
begin
  Result := Available;
end;

end.
