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
  The mouse's settings: speed, acceleration and left-handed buttons.

  Only relative motion (a mouse) is changed; a tablet's absolute
  positions are where the pen is, and stay so. The speed multiplies
  every movement (NormalMouseSpeed: as far as the mouse says). With
  acceleration, a fast movement goes further still: beyond a few device
  units in one report, every further unit counts for more, the more so
  the higher the acceleration. What is left over below a pixel is kept
  for the next movement, so a slow speed still moves, smoothly.

  Left-handed swaps the left and right buttons, for every pointing
  device.

  Any program may change them (RequestSetMouseSettings), as it may the
  display's scale: they are the settings of whoever sits at the screen.
  They last until the server ends; keeping them in a file is for the
  configuration library (step 7).
}
unit Server.MouseSettings;

{$mode objfpc}

interface

var
  MouseSpeed: LongWord;
  MouseAcceleration: LongWord;
  LeftHandedButtons: Boolean;

{ Takes new settings, kept within their limits. }
procedure ChangeMouseSettings(Speed, Acceleration: LongWord; LeftHanded: Boolean);
{ A mouse's motion in device units, as far as the pointer goes. }
procedure AdjustMotion(var DeltaX, DeltaY: LongInt);
{ The button a device's button acts as. }
function ButtonActingAs(Button: LongWord): LongWord;

implementation

uses
  Abi.SystemCalls,
  Windowing.Protocol;

const
  { Movements are worked out in 1/256 of a pixel. }
  FractionBits = 8;
  FractionOne = 1 shl FractionBits;
  { Movements up to this many device units in a report are not
    accelerated. }
  AccelerationThreshold = 4;
  { Each unit beyond the threshold adds Acceleration / AccelerationDivisor
    to the gain... }
  AccelerationDivisor = 16;
  { ...up to this many times the speed. }
  MaximumGain = 4;

var
  RemainderX: LongInt;
  RemainderY: LongInt;

procedure ChangeMouseSettings(Speed, Acceleration: LongWord; LeftHanded: Boolean);
begin
  if Speed < MinimumMouseSpeed then
    Speed := MinimumMouseSpeed;
  if Speed > MaximumMouseSpeed then
    Speed := MaximumMouseSpeed;
  if Acceleration > MaximumMouseAcceleration then
    Acceleration := MaximumMouseAcceleration;
  MouseSpeed := Speed;
  MouseAcceleration := Acceleration;
  LeftHandedButtons := LeftHanded;
  RemainderX := 0;
  RemainderY := 0;
end;

{ The gain for a movement this long, in 1/256: the speed, and the
  acceleration on top for a fast one. }
function GainFor(Distance: LongInt): LongInt;
var
  Extra: LongInt;
begin
  Result := LongInt(MouseSpeed) * FractionOne div NormalMouseSpeed;
  if (MouseAcceleration = 0) or (Distance <= AccelerationThreshold) then
    Exit;
  Extra := Result * (Distance - AccelerationThreshold) * LongInt(MouseAcceleration) div AccelerationDivisor;
  if Extra > Result * (MaximumGain - 1) then
    Extra := Result * (MaximumGain - 1);
  Result := Result + Extra;
end;

{ Value times Gain (both in 1/256), with what is left below a pixel
  kept in Remainder for the next time. }
function ScaledWithRemainder(Value, Gain: LongInt; var Remainder: LongInt): LongInt;
var
  Exact: LongInt;
begin
  Exact := Value * Gain + Remainder;
  { Rounded towards zero, the rest carried, so both ways behave alike. }
  if Exact >= 0 then
    Result := Exact div FractionOne
  else
    Result := -((-Exact) div FractionOne);
  Remainder := Exact - Result * FractionOne;
end;

procedure AdjustMotion(var DeltaX, DeltaY: LongInt);
var
  Distance: LongInt;
  Gain: LongInt;
begin
  Distance := Abs(DeltaX);
  if Abs(DeltaY) > Distance then
    Distance := Abs(DeltaY);
  Gain := GainFor(Distance);
  DeltaX := ScaledWithRemainder(DeltaX, Gain, RemainderX);
  DeltaY := ScaledWithRemainder(DeltaY, Gain, RemainderY);
end;

function ButtonActingAs(Button: LongWord): LongWord;
begin
  Result := Button;
  if not LeftHandedButtons then
    Exit;
  if Button = ButtonLeft then
    Result := ButtonRight
  else if Button = ButtonRight then
    Result := ButtonLeft;
end;

initialization
  MouseSpeed := NormalMouseSpeed;
end.
