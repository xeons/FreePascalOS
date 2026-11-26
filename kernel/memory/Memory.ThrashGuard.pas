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
  The thrash guard: how fast pages that running programs map (their code
  and libraries) may be taken away under memory pressure. Pure
  arithmetic, for the host test (tools/SchedulerPolicyTest).

  With no swap, the only memory the shrinkers can take from running
  programs is the pages of the files they map, which are read again on
  the next touch. Taking them without bound when one program keeps
  asking for more turns the whole system into a disk reader: every
  program, the display server and the desktop included, faults its
  code back in turn after turn, the user cannot even close the window,
  and the program asking is ended only once nothing at all is left.

  So hard eviction of mapped pages draws from a bucket of tokens:
  ThrashGuardRate pages a second (1/64 of RAM, at least 256 pages),
  holding at most that many. While tokens remain, eviction goes on as
  before; once they run out the shrinker gives nothing more, the fault
  that wanted memory finds none and the out-of-memory policy ends a
  process (Processes.OutOfMemory) - within a second instead of minutes.
  Pages nobody maps (the gentle pass) are never limited.
}
unit Memory.ThrashGuard;

{$mode objfpc}

interface

const
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;
  MinimumThrashGuardRate = 256;

type
  TThrashGuard = record
    Tokens: QWord;
    LastRefill: QWord;
    { Pages a second, and the most the bucket holds. }
    RatePerSecond: QWord;
    Capacity: QWord;
    { Pages refused since the start. }
    Refused: QWord;
  end;

{ The rate for a machine with TotalPages of RAM. }
function ThrashGuardRate(TotalPages: QWord): QWord;
{ A full bucket at Now. }
procedure InitializeThrashGuard(out Guard: TThrashGuard; RatePerSecond, Now: QWord);
{ Adds the tokens earned since the last refill. }
procedure RefillThrashGuard(var Guard: TThrashGuard; Now: QWord);
{ How many of Wanted mapped pages may be evicted now (taken from the
  bucket); the rest are counted as refused. }
function TakeThrashGuardPages(var Guard: TThrashGuard; Wanted, Now: QWord): QWord;
{ Gives back tokens for pages granted but not evicted. }
procedure ReturnThrashGuardPages(var Guard: TThrashGuard; Unused: QWord);

implementation

function ThrashGuardRate(TotalPages: QWord): QWord;
begin
  Result := TotalPages div 64;
  if Result < MinimumThrashGuardRate then
    Result := MinimumThrashGuardRate;
end;

procedure InitializeThrashGuard(out Guard: TThrashGuard; RatePerSecond, Now: QWord);
begin
  if RatePerSecond = 0 then
    RatePerSecond := MinimumThrashGuardRate;
  Guard.RatePerSecond := RatePerSecond;
  Guard.Capacity := RatePerSecond;
  Guard.Tokens := RatePerSecond;
  Guard.LastRefill := Now;
  Guard.Refused := 0;
end;

procedure RefillThrashGuard(var Guard: TThrashGuard; Now: QWord);
var
  Elapsed: QWord;
  Earned: QWord;
begin
  if Now <= Guard.LastRefill then
    Exit;
  Elapsed := Now - Guard.LastRefill;
  if Elapsed >= NanosecondsPerSecond then
    Earned := Guard.Capacity
  else
    Earned := Guard.RatePerSecond * (Elapsed div 1000) div (NanosecondsPerSecond div 1000);
  { Too little time for a whole page: the time is kept for later. }
  if Earned = 0 then
    Exit;
  Guard.LastRefill := Now;
  if Guard.Tokens + Earned >= Guard.Capacity then
    Guard.Tokens := Guard.Capacity
  else
    Guard.Tokens := Guard.Tokens + Earned;
end;

function TakeThrashGuardPages(var Guard: TThrashGuard; Wanted, Now: QWord): QWord;
begin
  RefillThrashGuard(Guard, Now);
  Result := Wanted;
  if Result > Guard.Tokens then
    Result := Guard.Tokens;
  Guard.Tokens := Guard.Tokens - Result;
  Guard.Refused := Guard.Refused + (Wanted - Result);
end;

procedure ReturnThrashGuardPages(var Guard: TThrashGuard; Unused: QWord);
begin
  if Guard.Tokens + Unused >= Guard.Capacity then
    Guard.Tokens := Guard.Capacity
  else
    Guard.Tokens := Guard.Tokens + Unused;
end;

end.
