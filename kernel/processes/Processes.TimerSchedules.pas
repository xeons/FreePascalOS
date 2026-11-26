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
  The arithmetic of a periodic timer's schedule (Processes.PosixTimers):
  the next due time is counted from the last one, not from when the
  expiry was seen, and the periods that passed unseen are the overrun,
  which stops at HighestTimerOverrun (DELAYTIMER_MAX). Times that would
  pass the end of the clock never come.
}
unit Processes.TimerSchedules;

{$mode objfpc}

interface

const
  HighestTimerOverrun = High(LongInt);
  { A due time that never comes. }
  NeverDueTime = High(QWord);

{ After an expiry due at DueTime, seen at Now, of a timer with period
  Interval (not 0): the next due time after Now on its schedule, and how
  many due times passed unseen in between. }
function NextDueTime(DueTime, Interval, Now: QWord; out Missed: QWord): QWord;
{ Overrun plus Count, at most HighestTimerOverrun. }
function AddOverrun(Overrun, Count: QWord): QWord;

implementation

function NextDueTime(DueTime, Interval, Now: QWord; out Missed: QWord): QWord;
var
  Late: QWord;
begin
  Missed := 0;
  if DueTime > NeverDueTime - Interval then
    Exit(NeverDueTime);
  Result := DueTime + Interval;
  if Result > Now then
    Exit;
  Late := (Now - Result) div Interval + 1;
  Missed := Late;
  if Late > (NeverDueTime - Result) div Interval then
    Exit(NeverDueTime);
  Result := Result + Late * Interval;
end;

function AddOverrun(Overrun, Count: QWord): QWord;
begin
  Result := Overrun + Count;
  if (Result < Overrun) or (Result > HighestTimerOverrun) then
    Result := HighestTimerOverrun;
end;

end.
