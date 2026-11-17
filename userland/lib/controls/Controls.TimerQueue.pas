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
  Timer queues: the times (milliseconds on some clock) at which each
  of many clients is due, so that one real timer, set for the earliest,
  serves them all (Controls.Timers). Nothing here knows of a clock or
  of windows, so it can be tried on its own.

  A client is any object; it is in the queue at most once. TakeDue
  hands out the clients that are due, earliest first, taking each out
  (a periodic client puts itself back for its next time:
  NextPeriodicDue).
}
unit Controls.TimerQueue;

{$mode objfpc}

interface

type
  TTimerQueueEntry = record
    Client: TObject;
    Due: QWord;
  end;

  TTimerQueue = class
  private
    FEntries: array of TTimerQueueEntry;
    FCount: LongInt;
    function IndexOf(Client: TObject): LongInt;
    procedure RemoveAt(Index: LongInt);
  public
    { Client is due at Due (in place of any time it had). }
    procedure Schedule(Client: TObject; Due: QWord);
    procedure Cancel(Client: TObject);
    function Contains(Client: TObject): Boolean;
    { The earliest time anything is due; False when nothing is. }
    function NextDue(out Due: QWord): Boolean;
    { The earliest client due at Now or before, taken out of the queue;
      False when none is. }
    function TakeDue(Now: QWord; out Client: TObject): Boolean;
    property Count: LongInt read FCount;
  end;

{ When a client due every Interval milliseconds, last due at
  PreviousDue, is due next: one interval on, keeping its rhythm, unless
  that is past already (the program was busy), when it is one interval
  from Now: ticks missed are skipped rather than run in a burst. }
function NextPeriodicDue(PreviousDue: QWord; Interval: LongWord; Now: QWord): QWord;

implementation

function TTimerQueue.IndexOf(Client: TObject): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FCount - 1 do
    if FEntries[Index].Client = Client then
      Exit(Index);
  Result := -1;
end;

procedure TTimerQueue.RemoveAt(Index: LongInt);
begin
  while Index < FCount - 1 do
  begin
    FEntries[Index] := FEntries[Index + 1];
    Inc(Index);
  end;
  Dec(FCount);
end;

procedure TTimerQueue.Schedule(Client: TObject; Due: QWord);
var
  Index: LongInt;
begin
  Index := IndexOf(Client);
  if Index < 0 then
  begin
    if FCount = Length(FEntries) then
      SetLength(FEntries, 2 * FCount + 4);
    Index := FCount;
    Inc(FCount);
    FEntries[Index].Client := Client;
  end;
  FEntries[Index].Due := Due;
end;

procedure TTimerQueue.Cancel(Client: TObject);
var
  Index: LongInt;
begin
  Index := IndexOf(Client);
  if Index >= 0 then
    RemoveAt(Index);
end;

function TTimerQueue.Contains(Client: TObject): Boolean;
begin
  Result := IndexOf(Client) >= 0;
end;

function TTimerQueue.NextDue(out Due: QWord): Boolean;
var
  Index: LongInt;
begin
  Due := 0;
  Result := FCount > 0;
  for Index := 0 to FCount - 1 do
    if (Index = 0) or (FEntries[Index].Due < Due) then
      Due := FEntries[Index].Due;
end;

function TTimerQueue.TakeDue(Now: QWord; out Client: TObject): Boolean;
var
  Index: LongInt;
  Earliest: LongInt;
begin
  Client := nil;
  Earliest := -1;
  for Index := 0 to FCount - 1 do
    if (FEntries[Index].Due <= Now) and
       ((Earliest < 0) or (FEntries[Index].Due < FEntries[Earliest].Due)) then
      Earliest := Index;
  Result := Earliest >= 0;
  if not Result then
    Exit;
  Client := FEntries[Earliest].Client;
  RemoveAt(Earliest);
end;

function NextPeriodicDue(PreviousDue: QWord; Interval: LongWord; Now: QWord): QWord;
begin
  Result := PreviousDue + Interval;
  if Result < Now then
    Result := Now + Interval;
end;

end.
