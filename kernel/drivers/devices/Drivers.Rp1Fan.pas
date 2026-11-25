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
  The Raspberry Pi 5's fan connector (untested on the board).

  The fan's PWM input is RP1's GPIO 45 ("FAN_PWM"). Linux drives it with
  RP1's PWM1 channel 3, inverted (the device tree's cooling_fan node:
  pwms = <&rp1_pwm1 3 41566 PWM_POLARITY_INVERTED>, cooling level 0 is
  duty 0): the pin high stops the fan, low runs it at full speed. The
  firmware does not run the fan for the operating system; without a
  driver it stands still.

  Speeds between off and full go through the PWM block (Drivers.Rp1Pwm,
  which sets up RP1's clock generator for it): the pin then takes its
  first function, PWM1 channel 3 (as Linux's pinctrl-rp1 lists GPIO 45).
  Where the PWM cannot be set up (it does not read back as set), the
  pin is a plain output instead (function SYS_RIO): the fan is either
  off or at full speed (any speed above 0), as before.

  RP1's GPIO node ("raspberrypi,rp1-gpio") has three register ranges:
  the IO banks (each pin's STATUS and CTRL, 8 bytes per pin), the RIO
  blocks (OUT, OE, IN, with atomic XOR/SET/CLR aliases at +1000h,
  +2000h, +3000h) and the pads (one word per pin after a voltage
  word). GPIO 45 is pin 11 of bank 2, whose IO, RIO and pads start at
  8000h, 8000h and 8004h in their ranges.
}
unit Drivers.Rp1Fan;

{$mode objfpc}
{$pointermath on}

interface

{ Finds RP1's GPIO block; True if the fan pin can be driven. }
function InitializeRp1Fan: Boolean;
function Rp1FanIsAvailable: Boolean;
{ Runs the fan at full speed or stops it. }
procedure SetRp1FanRunning(Running: Boolean);
{ Runs the fan at Percent of full speed (0 stops it); without the PWM,
  anything above 0 is full speed. Returns the speed it runs at. }
function SetRp1FanSpeed(Percent: LongWord): LongWord;
{ True if speeds between off and full can be had. }
function Rp1FanHasSpeeds: Boolean;

implementation

uses
  Runtime.Atomic,
  Io.PlatformDevices,
  Drivers.Rp1Pwm,
  Debug.Output;

const
  FanPinInBank = 11;
  BankTwoInputOutput = $8000;
  BankTwoRegisteredInputOutput = $8000;
  BankTwoPads = $8004;
  ControlRegister = 4;
  FunctionSelectMask = $1F;
  FunctionRegisteredInputOutput = 5;
  { Function 0 of GPIO 45: PWM1 channel 3. }
  FunctionPwm = 0;
  RegisteredOutput = $0;
  RegisteredOutputEnable = $4;
  AliasSet = $2000;
  AliasClear = $3000;
  PadOutputDisable = $80;
  PadInputEnable = $40;
  PadPullUp = $08;
  PadPullDown = $04;

var
  InputOutput: PByte = nil;
  RegisteredInputOutput: PByte = nil;
  Pads: PByte = nil;
  Available: Boolean = False;
  PinConfigured: Boolean = False;
  PinOnPwm: Boolean = False;

procedure WriteWord(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Base + Offset)^ := Value;
end;

function ReadWord(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
  FullMemoryBarrier;
end;

{ The pin as an output of the RIO block, its pad driving, no pulls. }
procedure ConfigurePin;
var
  Pad: LongWord;
  Control: LongWord;
  Mask: LongWord;
begin
  Mask := LongWord(1) shl FanPinInBank;
  Pad := ReadWord(Pads, BankTwoPads + FanPinInBank * 4);
  Pad := (Pad and not (PadOutputDisable or PadPullUp or PadPullDown)) or PadInputEnable;
  WriteWord(Pads, BankTwoPads + FanPinInBank * 4, Pad);
  WriteWord(RegisteredInputOutput, BankTwoRegisteredInputOutput + AliasSet + RegisteredOutputEnable, Mask);
  Control := ReadWord(InputOutput, BankTwoInputOutput + FanPinInBank * 8 + ControlRegister);
  Control := (Control and not FunctionSelectMask) or FunctionRegisteredInputOutput;
  WriteWord(InputOutput, BankTwoInputOutput + FanPinInBank * 8 + ControlRegister, Control);
  PinConfigured := True;
end;

{ The pin given to the PWM (its pad driving, no pulls). }
procedure ConfigurePinForPwm;
var
  Pad: LongWord;
  Control: LongWord;
begin
  Pad := ReadWord(Pads, BankTwoPads + FanPinInBank * 4);
  Pad := (Pad and not (PadOutputDisable or PadPullUp or PadPullDown)) or PadInputEnable;
  WriteWord(Pads, BankTwoPads + FanPinInBank * 4, Pad);
  Control := ReadWord(InputOutput, BankTwoInputOutput + FanPinInBank * 8 + ControlRegister);
  Control := (Control and not FunctionSelectMask) or FunctionPwm;
  WriteWord(InputOutput, BankTwoInputOutput + FanPinInBank * 8 + ControlRegister, Control);
  PinOnPwm := True;
  PinConfigured := False;
end;

function Rp1FanHasSpeeds: Boolean;
begin
  Result := Available and Rp1PwmIsAvailable;
end;

function SetRp1FanSpeed(Percent: LongWord): LongWord;
begin
  Result := 0;
  if not Available then
    Exit;
  if Percent > 100 then
    Percent := 100;
  if Rp1PwmIsAvailable then
  begin
    SetRp1PwmDuty(Percent);
    if not PinOnPwm then
      ConfigurePinForPwm;
    Exit(Percent);
  end;
  SetRp1FanRunning(Percent > 0);
  if Percent > 0 then
    Result := 100;
end;

procedure SetRp1FanRunning(Running: Boolean);
var
  Mask: LongWord;
begin
  if not Available then
    Exit;
  if Rp1PwmIsAvailable then
  begin
    if Running then
      SetRp1FanSpeed(100)
    else
      SetRp1FanSpeed(0);
    Exit;
  end;
  Mask := LongWord(1) shl FanPinInBank;
  { Low runs the fan (the line is inverted on the board). }
  if Running then
    WriteWord(RegisteredInputOutput, BankTwoRegisteredInputOutput + AliasClear + RegisteredOutput, Mask)
  else
    WriteWord(RegisteredInputOutput, BankTwoRegisteredInputOutput + AliasSet + RegisteredOutput, Mask);
  if not PinConfigured then
    ConfigurePin;
end;

function ProbeGpio(Device: PPlatformDevice): Boolean;
var
  Length: QWord;
begin
  Result := False;
  if Available then
    Exit;
  InputOutput := PByte(MapPlatformMemory(Device, 0, Length));
  if (InputOutput = nil) or (Length < BankTwoInputOutput + $1000) then
    Exit;
  RegisteredInputOutput := PByte(MapPlatformMemory(Device, 1, Length));
  if (RegisteredInputOutput = nil) or (Length < BankTwoRegisteredInputOutput + AliasClear + $10) then
    Exit;
  Pads := PByte(MapPlatformMemory(Device, 2, Length));
  if (Pads = nil) or (Length < BankTwoPads + $100) then
    Exit;
  Available := True;
  Result := True;
end;

const
  GpioIds: array[0..1] of PChar = ('raspberrypi,rp1-gpio', nil);
  GpioDriver: TPlatformDriver = (
    Name: 'rp1-fan';
    Ids: @GpioIds[0];
    Probe: @ProbeGpio);

function InitializeRp1Fan: Boolean;
begin
  Result := BindPlatformDriver(GpioDriver) > 0;
  if not Result then
    Exit;
  InitializeRp1Pwm;
  DebugBeginMessage;
  DebugWriteTag('fan');
  if Rp1PwmIsAvailable then
    DebugWriteLine('fan connector on RP1 GPIO 45 (PWM1 channel 3: speeds between off and full)')
  else
    DebugWriteLine('fan connector on RP1 GPIO 45 (switched on and off)');
  DebugEndMessage;
end;

function Rp1FanIsAvailable: Boolean;
begin
  Result := Available;
end;

end.
