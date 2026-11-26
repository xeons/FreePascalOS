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
  The arithmetic of measuring the time stamp counter against a
  reference counter (Hal.ClockCalibration), kept apart so the host test
  (tools/HpetTest) can check it.

  A reference read (an HPET or PM timer register, a PIT status port) is
  slow, and the processor can be held up around it: an interrupt, an
  SMI, or - in a virtual machine - the virtual processor not running at
  all for milliseconds. Read one after the other, the reference and the
  counter can then be far apart, and a rate measured from them is off
  by that much. So each reference read is bracketed: the counter is
  read just before and just after it, the reference's moment is taken
  as the middle of the two, and half the bracket's width is how wrong
  that can be. Of a few attempts the narrowest bracket is kept.

  A sample is the counter's cycles between two such moments over the
  reference's nanoseconds between them; its uncertainty is the sum of
  the two half widths. A sample whose uncertainty is a large part of
  its cycles is not steady and is not used, and the rate is the median
  of the steady samples, so one that went wrong in some other way does
  not move it either.
}
unit Hal.CalibrationSamples;

{$mode objfpc}

interface

type
  { A reference read with the counter read on both sides of it. }
  TBracketedRead = record
    CounterBefore: QWord;
    CounterAfter: QWord;
    ReferenceTicks: QWord;
  end;

  TCalibrationSample = record
    { The counter's cycles between the two bracket middles. }
    Cycles: QWord;
    { How far those cycles can be off: half of each bracket's width. }
    UncertaintyCycles: QWord;
    { The reference's measure of the same interval. }
    ReferenceNanoseconds: QWord;
  end;

const
  { The most samples a measurement takes the median of. }
  MaximumCalibrationSamples = 16;

type
  TSampleRates = array[0..MaximumCalibrationSamples - 1] of QWord;

function BracketWidth(constref Read: TBracketedRead): QWord;
function BracketMiddle(constref Read: TBracketedRead): QWord;
{ Candidate replaces Best if its bracket is narrower (or Best is not
  set yet, HaveBest False). }
procedure KeepNarrowerBracket(var Best: TBracketedRead; var HaveBest: Boolean;
  constref Candidate: TBracketedRead);
procedure MakeCalibrationSample(constref Start, Finish: TBracketedRead; ReferenceNanoseconds: QWord;
  out Sample: TCalibrationSample);
{ The counter's rate by the sample; 0 if it measured no time. }
function SampleHertz(constref Sample: TCalibrationSample): QWord;
{ UncertaintyCycles is at most LimitPartsPerMillion of Cycles (and
  Cycles is not 0). }
function UncertaintyIsWithin(Cycles, UncertaintyCycles, LimitPartsPerMillion: QWord): Boolean;
{ The sample's uncertainty is at most LimitPartsPerMillion of its
  cycles (and it measured something). }
function SampleIsSteady(constref Sample: TCalibrationSample; LimitPartsPerMillion: QWord): Boolean;
{ True if A is steadier than B: a smaller uncertainty for its cycles. }
function SampleIsSteadier(constref A, B: TCalibrationSample): Boolean;
{ The median of the first Count rates (sorted in place); the mean of
  the two middle ones for an even count; 0 for none. }
function MedianRate(var Rates: TSampleRates; Count: LongInt): QWord;

implementation

const
  NanosecondsPerSecond = 1000000000;
  PartsPerMillion = 1000000;

function BracketWidth(constref Read: TBracketedRead): QWord;
begin
  Result := Read.CounterAfter - Read.CounterBefore;
end;

function BracketMiddle(constref Read: TBracketedRead): QWord;
begin
  Result := Read.CounterBefore + BracketWidth(Read) div 2;
end;

procedure KeepNarrowerBracket(var Best: TBracketedRead; var HaveBest: Boolean;
  constref Candidate: TBracketedRead);
begin
  if HaveBest and (BracketWidth(Candidate) >= BracketWidth(Best)) then
    Exit;
  Best := Candidate;
  HaveBest := True;
end;

procedure MakeCalibrationSample(constref Start, Finish: TBracketedRead; ReferenceNanoseconds: QWord;
  out Sample: TCalibrationSample);
begin
  Sample.Cycles := BracketMiddle(Finish) - BracketMiddle(Start);
  Sample.UncertaintyCycles := BracketWidth(Start) div 2 + BracketWidth(Finish) div 2 + 1;
  Sample.ReferenceNanoseconds := ReferenceNanoseconds;
end;

function SampleHertz(constref Sample: TCalibrationSample): QWord;
begin
  if Sample.ReferenceNanoseconds = 0 then
    Exit(0);
  { Whole seconds first, so long samples do not overflow. }
  Result := Sample.Cycles div Sample.ReferenceNanoseconds * NanosecondsPerSecond +
    (Sample.Cycles mod Sample.ReferenceNanoseconds) * NanosecondsPerSecond div Sample.ReferenceNanoseconds;
end;

function UncertaintyIsWithin(Cycles, UncertaintyCycles, LimitPartsPerMillion: QWord): Boolean;
begin
  Result := (Cycles > 0) and
    (UncertaintyCycles <= Cycles div PartsPerMillion * LimitPartsPerMillion +
      (Cycles mod PartsPerMillion) * LimitPartsPerMillion div PartsPerMillion);
end;

function SampleIsSteady(constref Sample: TCalibrationSample; LimitPartsPerMillion: QWord): Boolean;
begin
  Result := (Sample.ReferenceNanoseconds > 0) and
    UncertaintyIsWithin(Sample.Cycles, Sample.UncertaintyCycles, LimitPartsPerMillion);
end;

function SampleIsSteadier(constref A, B: TCalibrationSample): Boolean;
const
  Below32Bits = QWord($FFFFFFFF);
var
  UncertaintyA: QWord;
  CyclesA: QWord;
  UncertaintyB: QWord;
  CyclesB: QWord;
begin
  if A.Cycles = 0 then
    Exit(False);
  if B.Cycles = 0 then
    Exit(True);
  { A.Uncertainty / A.Cycles < B.Uncertainty / B.Cycles, cross
    multiplied: all four are scaled below 32 bits first, so the products
    fit (no floating point in the kernel). }
  UncertaintyA := A.UncertaintyCycles;
  CyclesA := A.Cycles;
  UncertaintyB := B.UncertaintyCycles;
  CyclesB := B.Cycles;
  while (UncertaintyA or CyclesA or UncertaintyB or CyclesB) > Below32Bits do
  begin
    UncertaintyA := UncertaintyA shr 1;
    CyclesA := CyclesA shr 1;
    UncertaintyB := UncertaintyB shr 1;
    CyclesB := CyclesB shr 1;
  end;
  Result := UncertaintyA * CyclesB < UncertaintyB * CyclesA;
end;

function MedianRate(var Rates: TSampleRates; Count: LongInt): QWord;
var
  Outer: LongInt;
  Inner: LongInt;
  Value: QWord;
begin
  if Count <= 0 then
    Exit(0);
  if Count > MaximumCalibrationSamples then
    Count := MaximumCalibrationSamples;
  { Insertion sort: a handful of values. }
  Outer := 1;
  while Outer < Count do
  begin
    Value := Rates[Outer];
    Inner := Outer - 1;
    while (Inner >= 0) and (Rates[Inner] > Value) do
    begin
      Rates[Inner + 1] := Rates[Inner];
      Dec(Inner);
    end;
    Rates[Inner + 1] := Value;
    Inc(Outer);
  end;
  if (Count and 1) <> 0 then
    Result := Rates[Count div 2]
  else
    Result := Rates[Count div 2 - 1] div 2 + Rates[Count div 2] div 2 +
      (Rates[Count div 2 - 1] mod 2 + Rates[Count div 2] mod 2) div 2;
end;

end.
