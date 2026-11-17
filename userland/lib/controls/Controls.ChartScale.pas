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
  A chart's scales: the range an axis shows and where its ticks go.

  Ticks are "nice": a step of 1, 2 or 5 times a power of ten, the
  smallest that keeps the ticks to the number that fit. For sizes in
  bytes the steps are nice in their unit instead (1, 2, 5, 10, 20, 50,
  100, 200 or 500 B, KiB, MiB, GiB...), so the labels read "256 MiB"
  rather than "268.4 MB"; for durations in seconds they are steps of a
  clock (1, 2, 5, 10, 15, 30 s; 1, 2, 5, 10, 15, 30 min; 1, 2, 3, 6,
  12 h; then whole days). An automatic range runs from the tick at or
  below the smallest value to the one at or above the largest; a fixed
  one keeps its ends and only picks the step.

  Plain arithmetic, so it is checked on the host (tools/ChartTest).
}
unit Controls.ChartScale;

{$mode objfpc}
{$H+}

interface

type
  TTickBase = (TickBaseDecimal, TickBaseBinary, TickBaseTime);

  TAxisRange = record
    Minimum: Double;
    Maximum: Double;
    { Between ticks; the ticks are Origin and every multiple of Step
      from it, in the range (Origin is 0 unless the ticks are counted
      from one end). }
    Step: Double;
    Origin: Double;
  end;

{ The smallest 1, 2 or 5 times a power of ten at least RoughStep. }
function NiceStep(RoughStep: Double): Double;
{ The same in units of 1024 (see above). }
function BinaryNiceStep(RoughStep: Double): Double;
{ The same in seconds, a clock's steps (see above). }
function TimeNiceStep(RoughStep: Double): Double;
{ A nice step that cuts Span into at most MaximumTicks pieces. }
function StepFor(Span: Double; MaximumTicks: LongInt; Base: TTickBase): Double;
{ From a tick at or below DataMinimum to one at or above DataMaximum
  (with 0 inside if IncludeZero); a single value gets a range around
  it. }
function AutoRange(DataMinimum, DataMaximum: Double; MaximumTicks: LongInt; IncludeZero: Boolean;
  Base: TTickBase): TAxisRange;
{ Minimum to Maximum, with a nice step for at most MaximumTicks. }
function FixedRange(Minimum, Maximum: Double; MaximumTicks: LongInt; Base: TTickBase): TAxisRange;
function MakeRange(Minimum, Maximum, Step: Double): TAxisRange;
{ The ticks: Origin and the multiples of the step from it, from Minimum
  to Maximum. }
function TickCount(const Range: TAxisRange): LongInt;
function TickAt(const Range: TAxisRange; Index: LongInt): Double;
{ Value's place between PixelStart (at Minimum) and PixelEnd (at
  Maximum); either way round. }
function MapToPixels(Value, Minimum, Maximum, PixelStart, PixelEnd: Double): Double;
{ The value at Pixel, the other way. }
function MapFromPixels(Pixel, Minimum, Maximum, PixelStart, PixelEnd: Double): Double;
{ How many decimals the labels of ticks Step apart need (0 to 6). }
function DecimalsForStep(Step: Double): LongInt;

implementation

uses
  Math;

const
  { Rounding slack in comparisons of steps and multiples. }
  Slack = 1E-9;
  Kibi = 1024.0;

function NiceStep(RoughStep: Double): Double;
var
  Power: Double;
  Fraction: Double;
begin
  if not (RoughStep > 0) then
    Exit(1);
  Power := IntPower(10, Floor(Log10(RoughStep)));
  Fraction := RoughStep / Power;
  if Fraction <= 1 + Slack then
    Result := Power
  else if Fraction <= 2 + Slack then
    Result := 2 * Power
  else if Fraction <= 5 + Slack then
    Result := 5 * Power
  else
    Result := 10 * Power;
end;

function BinaryNiceStep(RoughStep: Double): Double;
var
  UnitSize: Double;
  InUnits: Double;
begin
  if RoughStep < Kibi then
    Exit(NiceStep(RoughStep));
  UnitSize := Kibi;
  while RoughStep >= UnitSize * Kibi do
    UnitSize := UnitSize * Kibi;
  InUnits := NiceStep(RoughStep / UnitSize);
  { Past 500 the next unit reads better than "1000 KiB". }
  if InUnits > 500 then
    InUnits := Kibi;
  Result := InUnits * UnitSize;
end;

function TimeNiceStep(RoughStep: Double): Double;
const
  ClockSteps: array[0..17] of Double = (1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800,
    21600, 43200, 86400);
  Day = 86400.0;
var
  Index: LongInt;
begin
  if RoughStep < 1 then
    Exit(NiceStep(RoughStep));
  for Index := 0 to High(ClockSteps) do
    if RoughStep <= ClockSteps[Index] * (1 + Slack) then
      Exit(ClockSteps[Index]);
  Result := NiceStep(RoughStep / Day) * Day;
end;

function StepFor(Span: Double; MaximumTicks: LongInt; Base: TTickBase): Double;
begin
  if MaximumTicks < 1 then
    MaximumTicks := 1;
  if not (Span > 0) then
    Span := 1;
  if Base = TickBaseBinary then
    Result := BinaryNiceStep(Span / MaximumTicks)
  else if Base = TickBaseTime then
    Result := TimeNiceStep(Span / MaximumTicks)
  else
    Result := NiceStep(Span / MaximumTicks);
end;

function MakeRange(Minimum, Maximum, Step: Double): TAxisRange;
begin
  Result.Minimum := Minimum;
  Result.Maximum := Maximum;
  Result.Step := Step;
  Result.Origin := 0;
end;

function AutoRange(DataMinimum, DataMaximum: Double; MaximumTicks: LongInt; IncludeZero: Boolean;
  Base: TTickBase): TAxisRange;
var
  Step: Double;
  Low: Double;
  High: Double;
begin
  if DataMinimum > DataMaximum then
  begin
    Low := DataMinimum;
    DataMinimum := DataMaximum;
    DataMaximum := Low;
  end;
  if IncludeZero then
  begin
    if DataMinimum > 0 then
      DataMinimum := 0;
    if DataMaximum < 0 then
      DataMaximum := 0;
  end;
  if DataMaximum - DataMinimum <= Abs(DataMaximum) * Slack then
  begin
    { One value (or none): a range around it. }
    if DataMaximum = 0 then
    begin
      DataMinimum := 0;
      DataMaximum := 1;
    end
    else if IncludeZero then
    begin
      if DataMaximum > 0 then
        DataMinimum := 0
      else
        DataMaximum := 0;
    end
    else
    begin
      DataMinimum := DataMinimum - Abs(DataMinimum) / 2;
      DataMaximum := DataMaximum + Abs(DataMaximum) / 2;
    end;
  end;
  Step := StepFor(DataMaximum - DataMinimum, MaximumTicks, Base);
  Low := Floor(DataMinimum / Step + Slack) * Step;
  High := Ceil(DataMaximum / Step - Slack) * Step;
  { Rounding out may need one tick more than asked: a step up then. }
  if (High - Low) / Step > MaximumTicks + Slack then
  begin
    Step := StepFor(Step * (MaximumTicks + 1), MaximumTicks, Base);
    Low := Floor(DataMinimum / Step + Slack) * Step;
    High := Ceil(DataMaximum / Step - Slack) * Step;
  end;
  Result := MakeRange(Low, High, Step);
end;

function FixedRange(Minimum, Maximum: Double; MaximumTicks: LongInt; Base: TTickBase): TAxisRange;
begin
  if Maximum <= Minimum then
    Maximum := Minimum + 1;
  Result := MakeRange(Minimum, Maximum, StepFor(Maximum - Minimum, MaximumTicks, Base));
end;

function FirstTickIndex(const Range: TAxisRange): Int64;
begin
  Result := Ceil((Range.Minimum - Range.Origin) / Range.Step - Slack);
end;

function TickCount(const Range: TAxisRange): LongInt;
var
  Last: Int64;
begin
  if not (Range.Step > 0) or (Range.Maximum < Range.Minimum) then
    Exit(0);
  Last := Floor((Range.Maximum - Range.Origin) / Range.Step + Slack);
  Result := Last - FirstTickIndex(Range) + 1;
  if Result < 0 then
    Result := 0;
end;

function TickAt(const Range: TAxisRange; Index: LongInt): Double;
begin
  Result := Range.Origin + (FirstTickIndex(Range) + Index) * Range.Step;
  { No "-0" or "1E-17" for the zero tick. }
  if Abs(Result) < Range.Step * Slack then
    Result := 0;
end;

function MapToPixels(Value, Minimum, Maximum, PixelStart, PixelEnd: Double): Double;
begin
  if Maximum = Minimum then
    Exit(PixelStart);
  Result := PixelStart + (Value - Minimum) * (PixelEnd - PixelStart) / (Maximum - Minimum);
end;

function MapFromPixels(Pixel, Minimum, Maximum, PixelStart, PixelEnd: Double): Double;
begin
  if PixelEnd = PixelStart then
    Exit(Minimum);
  Result := Minimum + (Pixel - PixelStart) * (Maximum - Minimum) / (PixelEnd - PixelStart);
end;

function DecimalsForStep(Step: Double): LongInt;
var
  Scaled: Double;
begin
  Result := 0;
  Step := Abs(Step);
  if Step = 0 then
    Exit;
  Scaled := Step;
  while (Result < 6) and (Abs(Scaled - Round(Scaled)) > Scaled * 1E-6) do
  begin
    Inc(Result);
    Scaled := Scaled * 10;
  end;
end;

end.
