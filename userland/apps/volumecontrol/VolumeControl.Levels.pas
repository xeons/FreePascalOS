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
  Peak levels for the volume control's meters: the loudest sample of
  each channel in a block of 16-bit samples, shown on a decibel scale
  (-60 dB to 0 dB across the meter, as mixing desks do, so quiet sound
  still moves it), falling back slowly after a peak (a fixed number of
  decibels a second) rather than jumping down.

  Plain logic: the host checks it (make apps-test).
}
unit VolumeControl.Levels;

{$mode objfpc}
{$H+}

interface

const
  { The meter's range, in decibels below full scale. }
  MeterFloorDecibels = 60;
  { How fast a meter falls after a peak, decibels a second. }
  MeterFallDecibelsPerSecond = 24;
  FullScale = 32767;

type
  TStereoPeak = record
    Left: LongInt;
    Right: LongInt;
  end;

{ The largest magnitude of each channel among FrameCount frames of
  Channels interleaved 16-bit samples (mono counts for both sides; past
  the second channel the rest are left out). }
function PeakOfSamples(const Samples: array of SmallInt; FrameCount, Channels: LongInt): TStereoPeak;
{ A peak (0 to FullScale) as a share of the meter, 0 to 100. }
function MeterPercent(Peak: LongInt): LongInt;
{ The meter after Milliseconds: the new reading if higher, else the old
  one fallen by the fall rate (not below the new reading). }
function FallenMeter(Previous, Reading: LongInt; Milliseconds: LongInt): LongInt;

implementation

uses
  Math;

function PeakOfSamples(const Samples: array of SmallInt; FrameCount, Channels: LongInt): TStereoPeak;
var
  Frame: LongInt;
  Left: LongInt;
  Right: LongInt;
begin
  Result.Left := 0;
  Result.Right := 0;
  if Channels < 1 then
    Exit;
  if FrameCount * Channels > Length(Samples) then
    FrameCount := Length(Samples) div Channels;
  for Frame := 0 to FrameCount - 1 do
  begin
    Left := Abs(LongInt(Samples[Frame * Channels]));
    if Channels > 1 then
      Right := Abs(LongInt(Samples[Frame * Channels + 1]))
    else
      Right := Left;
    if Left > Result.Left then
      Result.Left := Left;
    if Right > Result.Right then
      Result.Right := Right;
  end;
  Result.Left := Min(Result.Left, FullScale);
  Result.Right := Min(Result.Right, FullScale);
end;

function MeterPercent(Peak: LongInt): LongInt;
var
  Decibels: Double;
begin
  if Peak <= 0 then
    Exit(0);
  Decibels := 20 * Log10(Min(Peak, FullScale) / FullScale);
  if Decibels <= -MeterFloorDecibels then
    Exit(0);
  Result := Round(100 * (Decibels + MeterFloorDecibels) / MeterFloorDecibels);
  Result := Max(0, Min(100, Result));
end;

function FallenMeter(Previous, Reading: LongInt; Milliseconds: LongInt): LongInt;
var
  Fall: LongInt;
begin
  if Reading >= Previous then
    Exit(Reading);
  { Percent of the meter is MeterFloorDecibels / 100 decibels. }
  Fall := Round(MeterFallDecibelsPerSecond * Milliseconds / 1000 * 100 / MeterFloorDecibels);
  Result := Max(Reading, Previous - Fall);
end;

end.
