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
  The clock page's arithmetic (TAbiClockPage, Abi.SystemCalls.inc),
  shared by the kernel, the user runtime (the System unit) and the host
  test, so that the time a program reads from the page is to the
  nanosecond what the kernel's own clock says.

  Plain functions without a mode of their own: the System unit includes
  this file too. Needs TAbiClockPage in scope.
}

const
  ClockPageNanosecondsPerSecond = 1000000000;
  ClockPageMicrosecondsPerSecond = 1000000;

{ The uptime at counter value Counter, in nanoseconds: the origin's time
  plus the counts since then, whole seconds and the rest apart so that
  nothing overflows (the rest, under one second's counts, times 10^9
  fits in 64 bits for any counter below 18 GHz). A counter at or behind
  the origin (another processor's, a few counts behind) gives the
  origin's time. }
function ClockPageUptimeAt(const Page: TAbiClockPage; Counter: QWord): QWord;
var
  Elapsed: QWord;
  Frequency: QWord;
begin
  Frequency := Page.CounterFrequency;
  if (Frequency = 0) or (Counter <= Page.CounterOrigin) then
  begin
    ClockPageUptimeAt := Page.OriginNanoseconds;
    Exit;
  end;
  Elapsed := Counter - Page.CounterOrigin;
  ClockPageUptimeAt := Page.OriginNanoseconds +
    (Elapsed div Frequency) * ClockPageNanosecondsPerSecond +
    ((Elapsed mod Frequency) * ClockPageNanosecondsPerSecond) div Frequency;
end;

{ How far a gradual adjustment of Total nanoseconds begun at uptime
  Start has moved the wall clock by uptime Now, at PartsPerMillion of
  the time passing: always towards Total, never past it. }
function ClockSlewProgress(Total: Int64; Start, Now: QWord; PartsPerMillion: QWord): Int64;
var
  Elapsed: QWord;
  Moved: QWord;
  Magnitude: QWord;
begin
  if (Total = 0) or (Now <= Start) then
  begin
    ClockSlewProgress := 0;
    Exit;
  end;
  Elapsed := Now - Start;
  Moved := (Elapsed div ClockPageMicrosecondsPerSecond) * PartsPerMillion +
    ((Elapsed mod ClockPageMicrosecondsPerSecond) * PartsPerMillion) div ClockPageMicrosecondsPerSecond;
  if Total < 0 then
    Magnitude := QWord(-Total)
  else
    Magnitude := QWord(Total);
  if Moved > Magnitude then
    Moved := Magnitude;
  if Total < 0 then
    ClockSlewProgress := -Int64(Moved)
  else
    ClockSlewProgress := Int64(Moved);
end;

{ The wall clock (nanoseconds since 1970) at uptime Uptime, from the
  page's offset and gradual adjustment. }
function ClockPageWallClockAt(const Page: TAbiClockPage; Uptime: QWord): Int64;
begin
  ClockPageWallClockAt := Int64(Uptime) + Page.WallBaseOffset +
    ClockSlewProgress(Page.SlewTotal, Page.SlewStart, Uptime, Page.SlewPartsPerMillion);
end;
