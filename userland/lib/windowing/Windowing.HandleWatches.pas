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
  Handles of the program's own that the message loop waits on along
  with the display server: a pipe, a pseudo-terminal's master side, a
  process. Whenever one is ready (as CallWaitForHandles means it) the
  loop calls its handler, before it waits again; so a handler must take
  what made the handle ready (read what is there), or stop watching it,
  or it is called again at once.

  The loop serves the display server first each time, so a handle that
  stays ready (a program writing without pause) does not shut the
  windows out.
}
unit Windowing.HandleWatches;

{$mode objfpc}

interface

const
  MaximumHandleWatches = 16;

type
  THandleReadyEvent = procedure(Handle: Int64) of object;

{ Starts calling OnReady whenever Handle is ready. False if too many
  handles are watched. Watching a handle again changes its handler. }
function WatchHandle(Handle: Int64; OnReady: THandleReadyEvent): Boolean;
procedure StopWatchingHandle(Handle: Int64);

{ For the message loop (Windowing.Windows). }
function WatchedHandleCount: LongInt;
function WatchedHandle(Index: LongInt): Int64;
{ Calls the handler of the handle at Index of the list the loop waited
  on (it may stop watching it, or others). }
procedure ReportHandleReady(Index: LongInt);

implementation

type
  THandleWatch = record
    Handle: Int64;
    OnReady: THandleReadyEvent;
  end;

var
  Watches: array[0..MaximumHandleWatches - 1] of THandleWatch;
  WatchCount: LongInt;

function IndexOfHandle(Handle: Int64): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to WatchCount - 1 do
    if Watches[Index].Handle = Handle then
      Exit(Index);
  Result := -1;
end;

function WatchHandle(Handle: Int64; OnReady: THandleReadyEvent): Boolean;
var
  Index: LongInt;
begin
  Index := IndexOfHandle(Handle);
  if Index < 0 then
  begin
    if WatchCount = MaximumHandleWatches then
      Exit(False);
    Index := WatchCount;
    Inc(WatchCount);
  end;
  Watches[Index].Handle := Handle;
  Watches[Index].OnReady := OnReady;
  Result := True;
end;

procedure StopWatchingHandle(Handle: Int64);
var
  Index: LongInt;
begin
  Index := IndexOfHandle(Handle);
  if Index < 0 then
    Exit;
  while Index < WatchCount - 1 do
  begin
    Watches[Index] := Watches[Index + 1];
    Inc(Index);
  end;
  Dec(WatchCount);
end;

function WatchedHandleCount: LongInt;
begin
  Result := WatchCount;
end;

function WatchedHandle(Index: LongInt): Int64;
begin
  Result := Watches[Index].Handle;
end;

procedure ReportHandleReady(Index: LongInt);
var
  Watch: THandleWatch;
begin
  if (Index < 0) or (Index >= WatchCount) then
    Exit;
  { A copy: the handler may change the list. }
  Watch := Watches[Index];
  if Assigned(Watch.OnReady) then
    Watch.OnReady(Watch.Handle);
end;

end.
