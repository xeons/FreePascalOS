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
  ClockPageTest

  The clock page's arithmetic (shared/ClockPageMath.inc, what the kernel
  and every program's runtime compute) on the host:
  - the uptime from a counter value is exactly floor(elapsed * 10^9 /
    frequency) past the origin's time (checked against 128-bit
    arithmetic) for counters from 1 MHz to 5 GHz and spans up to ten
    years, and never goes back as the counter grows;
  - a counter behind the origin gives the origin's time;
  - a new origin published where the old one stood (suspend to RAM)
    continues the time without a step back;
  - the gradual adjustment: nothing before it starts, 500 parts per
    million of the time passing, never past its total, either sign, and
    a wall clock slewed back still never goes back.

  Prints every failed check and exits with 1 if there was one.
}
program ClockPageTest;

{$mode objfpc}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.ClockPage;

const
  NanosecondsPerSecond = 1000000000;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

{ A * B as a 128-bit number (High, Low). }
procedure Multiply128(A, B: QWord; out High, Low: QWord);
var
  ALow, AHigh, BLow, BHigh: QWord;
  LowLow, LowHigh, HighLow, HighHigh: QWord;
  Middle: QWord;
begin
  ALow := A and $FFFFFFFF;
  AHigh := A shr 32;
  BLow := B and $FFFFFFFF;
  BHigh := B shr 32;
  LowLow := ALow * BLow;
  LowHigh := ALow * BHigh;
  HighLow := AHigh * BLow;
  HighHigh := AHigh * BHigh;
  Middle := (LowLow shr 32) + (LowHigh and $FFFFFFFF) + (HighLow and $FFFFFFFF);
  Low := (LowLow and $FFFFFFFF) or (Middle shl 32);
  High := HighHigh + (LowHigh shr 32) + (HighLow shr 32) + (Middle shr 32);
end;

{ (High, Low) div Divisor, for a quotient that fits in 64 bits: bit by
  bit, slow but plainly right. }
function Divide128(High, Low, Divisor: QWord): QWord;
var
  Remainder: QWord;
  Bit: Integer;
  Carry: Boolean;
begin
  Result := 0;
  Remainder := 0;
  for Bit := 127 downto 0 do
  begin
    Carry := (Remainder shr 63) <> 0;
    Remainder := Remainder shl 1;
    if Bit >= 64 then
      Remainder := Remainder or ((High shr (Bit - 64)) and 1)
    else
      Remainder := Remainder or ((Low shr Bit) and 1);
    if Carry or (Remainder >= Divisor) then
    begin
      Remainder := Remainder - Divisor;
      if Bit < 64 then
        Result := Result or (QWord(1) shl Bit);
    end;
  end;
end;

function ExactUptime(OriginNanoseconds, Elapsed, Frequency: QWord): QWord;
var
  High, Low: QWord;
begin
  Multiply128(Elapsed, NanosecondsPerSecond, High, Low);
  Result := OriginNanoseconds + Divide128(High, Low, Frequency);
end;

function MakePage(Origin, OriginNanoseconds, Frequency: QWord): TAbiClockPage;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Mode := ClockPageModeCounter;
  Result.CounterOrigin := Origin;
  Result.OriginNanoseconds := OriginNanoseconds;
  Result.CounterFrequency := Frequency;
  Result.SlewPartsPerMillion := 500;
end;

function RandomQWord: QWord;
begin
  Result := (QWord(Random($10000)) shl 48) or (QWord(Random($10000)) shl 32) or
    (QWord(Random($10000)) shl 16) or QWord(Random($10000));
end;

procedure TestExactness;
const
  Frequencies: array[0..5] of QWord = (1000000, 19200000, 54000000, 1000000000, 2999999999, 5000000000);
  TenYears = QWord(10) * 365 * 86400;
var
  FrequencyIndex: Integer;
  Round: Integer;
  Page: TAbiClockPage;
  Elapsed: QWord;
  Wrong: Integer;
begin
  for FrequencyIndex := Low(Frequencies) to High(Frequencies) do
  begin
    Page := MakePage(RandomQWord shr 8, RandomQWord shr 16, Frequencies[FrequencyIndex]);
    Wrong := 0;
    for Round := 1 to 20000 do
    begin
      Elapsed := RandomQWord mod (TenYears * Frequencies[FrequencyIndex]);
      if ClockPageUptimeAt(Page, Page.CounterOrigin + Elapsed) <>
         ExactUptime(Page.OriginNanoseconds, Elapsed, Page.CounterFrequency) then
        Inc(Wrong);
    end;
    Check(Wrong = 0, Format('the uptime is exact at %d Hz (%d wrong)', [Frequencies[FrequencyIndex], Wrong]));
  end;
end;

procedure TestMonotonic;
var
  Page: TAbiClockPage;
  Counter: QWord;
  Previous: QWord;
  Now: QWord;
  Round: Integer;
  BackSteps: Integer;
begin
  Page := MakePage(1000, 5 * NanosecondsPerSecond, 2999999999);
  Counter := Page.CounterOrigin;
  Previous := ClockPageUptimeAt(Page, Counter);
  BackSteps := 0;
  for Round := 1 to 200000 do
  begin
    Counter := Counter + QWord(Random(5000000));
    Now := ClockPageUptimeAt(Page, Counter);
    if Now < Previous then
      Inc(BackSteps);
    Previous := Now;
  end;
  Check(BackSteps = 0, 'the uptime never goes back as the counter grows');
  Check(ClockPageUptimeAt(Page, Page.CounterOrigin - 5) = Page.OriginNanoseconds,
    'a counter behind the origin gives the origin''s time');
  Check(ClockPageUptimeAt(Page, Page.CounterOrigin) = Page.OriginNanoseconds, 'the origin gives its time');
  Page.CounterFrequency := 0;
  Check(ClockPageUptimeAt(Page, 123456) = Page.OriginNanoseconds, 'a page without a rate gives its origin');
end;

{ Suspend to RAM: the counter starts again from about zero, and the page
  gets the new counter value with the time it paused at. }
procedure TestNewOrigin;
var
  Before: TAbiClockPage;
  After: TAbiClockPage;
  PausedAt: QWord;
begin
  Before := MakePage(500000, 0, 24000000);
  PausedAt := ClockPageUptimeAt(Before, 500000 + 24000000 * QWord(3600) + 12345);
  After := MakePage(17, PausedAt, 24000000);
  Check(ClockPageUptimeAt(After, 17) = PausedAt, 'the new origin continues where the clock paused');
  Check(ClockPageUptimeAt(After, 18) >= PausedAt, 'and goes on from there');
end;

procedure TestSlew;
var
  Page: TAbiClockPage;
  Uptime: QWord;
  Previous: Int64;
  Wall: Int64;
  BackSteps: Integer;
begin
  Check(ClockSlewProgress(1000000, 100, 50, 500) = 0, 'nothing before the adjustment starts');
  Check(ClockSlewProgress(0, 0, NanosecondsPerSecond, 500) = 0, 'no adjustment moves nothing');
  Check(ClockSlewProgress(10000000, 0, NanosecondsPerSecond, 500) = 500000,
    'a second of a gradual adjustment moves 500 us');
  Check(ClockSlewProgress(-10000000, 0, NanosecondsPerSecond, 500) = -500000, 'either way');
  Check(ClockSlewProgress(1000, 0, NanosecondsPerSecond, 500) = 1000, 'never past its total');
  Check(ClockSlewProgress(-1000, 0, NanosecondsPerSecond, 500) = -1000, 'never past its total backwards');
  Check(ClockSlewProgress(Int64(3600) * NanosecondsPerSecond, 0, QWord(86400) * 100 * NanosecondsPerSecond, 500) =
    Int64(3600) * NanosecondsPerSecond, 'an hour long adjustment ends at its hour');

  Page := MakePage(0, 0, NanosecondsPerSecond);
  Page.WallBaseOffset := Int64(1700000000) * NanosecondsPerSecond;
  Page.SlewTotal := -NanosecondsPerSecond;
  Page.SlewStart := 10 * NanosecondsPerSecond;
  Check(ClockPageWallClockAt(Page, 5 * NanosecondsPerSecond) = Page.WallBaseOffset + 5 * NanosecondsPerSecond,
    'the wall clock is the uptime plus the offset before an adjustment');
  Uptime := 0;
  Previous := ClockPageWallClockAt(Page, Uptime);
  BackSteps := 0;
  while Uptime < QWord(3000) * NanosecondsPerSecond do
  begin
    Uptime := Uptime + 999983;
    Wall := ClockPageWallClockAt(Page, Uptime);
    if Wall < Previous then
      Inc(BackSteps);
    Previous := Wall;
  end;
  Check(BackSteps = 0, 'a wall clock slewed back never goes back');
  Check(ClockPageWallClockAt(Page, QWord(3000) * NanosecondsPerSecond) =
    Page.WallBaseOffset + Int64(3000) * NanosecondsPerSecond - NanosecondsPerSecond,
    'and ends exactly one second behind');
end;

begin
  RandSeed := 20261125;
  TestExactness;
  TestMonotonic;
  TestNewOrigin;
  TestSlew;
  if Failures > 0 then
  begin
    WriteLn(Format('ClockPageTest: %d of %d checks failed', [Failures, Checks]));
    Halt(1);
  end;
  WriteLn(Format('ClockPageTest: %d checks passed', [Checks]));
end.
