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
  The arithmetic of the HPET, apart from its registers.

  - The general capabilities register: the counter's period in
    femtoseconds (bits 32-63, at most 100 ns and never 0), the number
    of comparators (bits 8-12, less one), a 64-bit counter (bit 13) and
    legacy replacement (bit 15).
  - Ticks and nanoseconds: a tick lasts Period femtoseconds, 10^6 to the
    nanosecond, worked out in two parts so that nothing overflows for
    any period up to 100 ns and any time below centuries.
  - A 32-bit counter's wrap: it is extended to 64 bits from the last
    extended value read (the high half counts the wraps): a reading
    below the last one's low half has wrapped once. Reading at least
    once per wrap (42.9 s at 100 MHz, 5 minutes at 14.318 MHz) keeps it
    right; the clock does, every few seconds at most.
  - A 32-bit comparator: whether the counter has already passed the
    value just written (the difference, taken as a signed 32-bit number,
    is not ahead by at least the margin), so the interrupt would not
    come until the counter wrapped.

  Plain Pascal: tools/HpetTest checks it on the host.
}
unit Hal.HpetMath;

{$mode objfpc}

interface

const
  FemtosecondsPerNanosecond = 1000000;
  FemtosecondsPerSecond = QWord(1000000000000000);
  { The specification's limit: the counter runs at 10 MHz at least. }
  MaximumHpetPeriodFemtoseconds = 100000000;

{ The capabilities register's fields. }
function HpetPeriodOf(Capabilities: QWord): LongWord;
function HpetComparatorCountOf(Capabilities: QWord): LongWord;
function HpetCounterIs64BitOf(Capabilities: QWord): Boolean;
function HpetLegacyCapableOf(Capabilities: QWord): Boolean;
function HpetVendorOf(Capabilities: QWord): Word;
{ A period the counter may have (not 0, not above 100 ns). }
function HpetPeriodIsValid(PeriodFemtoseconds: LongWord): Boolean;

{ Counter ticks to nanoseconds and back, for a counter whose tick lasts
  PeriodFemtoseconds (valid). Nanoseconds to ticks rounds up. }
function HpetTicksToNanoseconds(Ticks: QWord; PeriodFemtoseconds: LongWord): QWord;
function HpetNanosecondsToTicks(Nanoseconds: QWord; PeriodFemtoseconds: LongWord): QWord;
{ The counter's rate, rounded to the hertz. }
function HpetFrequencyOf(PeriodFemtoseconds: LongWord): QWord;

{ The 64-bit value of a 32-bit counter that now reads Low, given the
  extended value read last (Previous). }
function ExtendCounterReading(Previous: QWord; Low: LongWord): QWord;

{ A 32-bit comparator was written with Target and the counter then read
  Counter: True if the counter is not at least Margin ticks short of
  it, so the match may have been missed. }
function ComparatorWasMissed(Target, Counter: LongWord; Margin: LongWord): Boolean;

implementation

function HpetPeriodOf(Capabilities: QWord): LongWord;
begin
  Result := LongWord(Capabilities shr 32);
end;

function HpetComparatorCountOf(Capabilities: QWord): LongWord;
begin
  Result := LongWord((Capabilities shr 8) and $1F) + 1;
end;

function HpetCounterIs64BitOf(Capabilities: QWord): Boolean;
begin
  Result := (Capabilities and (QWord(1) shl 13)) <> 0;
end;

function HpetLegacyCapableOf(Capabilities: QWord): Boolean;
begin
  Result := (Capabilities and (QWord(1) shl 15)) <> 0;
end;

function HpetVendorOf(Capabilities: QWord): Word;
begin
  Result := Word((Capabilities shr 16) and $FFFF);
end;

function HpetPeriodIsValid(PeriodFemtoseconds: LongWord): Boolean;
begin
  Result := (PeriodFemtoseconds <> 0) and (PeriodFemtoseconds <= MaximumHpetPeriodFemtoseconds);
end;

function HpetTicksToNanoseconds(Ticks: QWord; PeriodFemtoseconds: LongWord): QWord;
begin
  { Whole millions of ticks, then the rest (below 10^6 times a period of
    at most 10^8: within 64 bits). }
  Result := (Ticks div FemtosecondsPerNanosecond) * PeriodFemtoseconds +
    ((Ticks mod FemtosecondsPerNanosecond) * PeriodFemtoseconds) div FemtosecondsPerNanosecond;
end;

function HpetNanosecondsToTicks(Nanoseconds: QWord; PeriodFemtoseconds: LongWord): QWord;
var
  Whole: QWord;
  Rest: QWord;
begin
  if PeriodFemtoseconds = 0 then
    Exit(0);
  Whole := Nanoseconds div PeriodFemtoseconds;
  Rest := Nanoseconds mod PeriodFemtoseconds;
  Result := Whole * FemtosecondsPerNanosecond +
    (Rest * FemtosecondsPerNanosecond + PeriodFemtoseconds - 1) div PeriodFemtoseconds;
end;

function HpetFrequencyOf(PeriodFemtoseconds: LongWord): QWord;
begin
  if PeriodFemtoseconds = 0 then
    Exit(0);
  Result := (FemtosecondsPerSecond + PeriodFemtoseconds div 2) div PeriodFemtoseconds;
end;

function ExtendCounterReading(Previous: QWord; Low: LongWord): QWord;
var
  Wraps: QWord;
begin
  Wraps := Previous shr 32;
  if Low < LongWord(Previous and $FFFFFFFF) then
    Inc(Wraps);
  Result := (Wraps shl 32) or Low;
end;

function ComparatorWasMissed(Target, Counter: LongWord; Margin: LongWord): Boolean;
var
  Ahead: LongInt;
begin
  { In 64 bits and masked: no overflow check trips on the wrap. }
  Ahead := LongInt(LongWord((QWord(Target) + $100000000 - QWord(Counter)) and $FFFFFFFF));
  Result := Ahead < LongInt(Margin);
end;

end.
