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
  What the timesync service does with its samples.

  Each poll asks a server a few times; the sample with the shortest
  round trip is the one believed (its offset is least disturbed by the
  network). Then:
  - an offset under the dead band (1 ms) is left alone;
  - the first correction after start, or one beyond the step threshold
    (TimeSync/StepThresholdMilliseconds, 128 ms), steps the clock at
    once - at boot the battery backed clock may be off by minutes, which
    slewing at 0.05 % would take days to make up;
  - anything else is slewed: the kernel runs the clock a little fast or
    slow until the offset is gone, never jumping or going back.
  The poll interval starts at the shortest (64 s) and doubles after each
  poll that needed no step, up to the longest (1024 s); a failed poll
  halves it again.

  Plain Pascal: built into the service and the host test.
}
unit TimeSync.Corrections;

{$mode objfpc}{$H+}

interface

uses
  TimeSync.Packets;

const
  DeadBandNanoseconds = Int64(1000000);
  DefaultStepThresholdMilliseconds = 128;
  ShortestPollSeconds = 64;
  LongestPollSeconds = 1024;

type
  TCorrectionKind = (CorrectionNone, CorrectionStep, CorrectionSlew);

  TSampleArray = array of TSntpSample;

{ The index of the sample with the shortest round trip (-1 for none). }
function BestSample(const Samples: TSampleArray): Integer;
{ What to do about Offset. }
function DecideCorrection(OffsetNanoseconds: Int64; FirstCorrection: Boolean;
  StepThresholdMilliseconds: Int64): TCorrectionKind;
{ The next poll interval after one of Seconds that went as Succeeded
  (and whether it had to step). }
function NextPollSeconds(Seconds: LongInt; Succeeded, Stepped: Boolean;
  Shortest, Longest: LongInt): LongInt;

implementation

function BestSample(const Samples: TSampleArray): Integer;
var
  Index: Integer;
begin
  Result := -1;
  for Index := 0 to High(Samples) do
    if (Result < 0) or (Samples[Index].DelayNanoseconds < Samples[Result].DelayNanoseconds) then
      Result := Index;
end;

function DecideCorrection(OffsetNanoseconds: Int64; FirstCorrection: Boolean;
  StepThresholdMilliseconds: Int64): TCorrectionKind;
var
  Magnitude: Int64;
begin
  Magnitude := OffsetNanoseconds;
  if Magnitude < 0 then
    Magnitude := -Magnitude;
  if Magnitude < DeadBandNanoseconds then
    Exit(CorrectionNone);
  if FirstCorrection or (Magnitude > StepThresholdMilliseconds * 1000000) then
    Result := CorrectionStep
  else
    Result := CorrectionSlew;
end;

function NextPollSeconds(Seconds: LongInt; Succeeded, Stepped: Boolean;
  Shortest, Longest: LongInt): LongInt;
begin
  if not Succeeded then
    Result := Seconds div 2
  else if Stepped then
    Result := Shortest
  else
    Result := Seconds * 2;
  if Result < Shortest then
    Result := Shortest;
  if Result > Longest then
    Result := Longest;
end;

end.
