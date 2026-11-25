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
  Watching the network's configuration for changes: an adapter that
  appears, a link that comes or goes, an interface turned on or off or
  given an address, a route, the DNS servers. A program that has to
  follow them (the network service, a status icon) gets an event that
  is signaled after each change and looks again; it never polls.

  Each watcher is an automatic reset event object in a small table that
  holds a reference to it; the handle the program got holds another.
  When the program closes its handle (or ends), only the table's
  reference is left, and the entry is dropped the next time the table
  is looked at. A user other than root holds at most
  MaximumWatchersPerUser of them, and all such users together leave
  WatchersKeptForRoot entries free, so that nobody can fill the table
  and keep the network service from watching. Under its own spin lock;
  objects are let go of after it is released, at passive level, as
  every caller runs.
}
unit Network.ChangeWatchers;

{$mode objfpc}

interface

uses
  Objects.Events;

const
  MaximumNetworkChangeWatchers = 32;
  MaximumWatchersPerUser = 8;
  WatchersKeptForRoot = 8;
  WatcherRootUserId = 0;

{ A new watcher for UserId: an event object (one reference, the
  caller's) that is signaled after every change from now on; nil when
  the table (or the user's share of it) is full or memory ran out. The
  table keeps a reference of its own. }
function CreateNetworkChangeWatcher(UserId: LongWord): PEventObject;
{ Something in the network's configuration changed: every watcher is
  signaled. At passive level (under the network lock or not). }
procedure NoteNetworkChange;

implementation

uses
  Kernel.Events,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Objects.Manager;

type
  TWatcherList = array[0..MaximumNetworkChangeWatchers - 1] of PEventObject;

var
  { A zeroed spin lock is free. }
  WatcherLock: TSpinLock;
  Watchers: TWatcherList;
  WatcherOwners: array[0..MaximumNetworkChangeWatchers - 1] of LongWord;

{ Under the lock: whether UserId may have another watcher. }
function UserHasRoom(UserId: LongWord): Boolean;
var
  Index: Integer;
  OwnCount: Integer;
  UnprivilegedCount: Integer;
begin
  if UserId = WatcherRootUserId then
    Exit(True);
  OwnCount := 0;
  UnprivilegedCount := 0;
  for Index := 0 to MaximumNetworkChangeWatchers - 1 do
    if (Watchers[Index] <> nil) and (WatcherOwners[Index] <> WatcherRootUserId) then
    begin
      Inc(UnprivilegedCount);
      if WatcherOwners[Index] = UserId then
        Inc(OwnCount);
    end;
  Result := (OwnCount < MaximumWatchersPerUser) and
    (UnprivilegedCount < MaximumNetworkChangeWatchers - WatchersKeptForRoot);
end;

{ Under the lock: takes the watchers nobody else holds out of the table
  into Abandoned; returns how many. }
function TakeAbandonedWatchers(out Abandoned: TWatcherList): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumNetworkChangeWatchers - 1 do
    if (Watchers[Index] <> nil) and (ObjectReferenceCount(Watchers[Index]) <= 1) then
    begin
      Abandoned[Result] := Watchers[Index];
      Watchers[Index] := nil;
      Inc(Result);
    end;
end;

procedure ReleaseAbandonedWatchers(const Abandoned: TWatcherList; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    DereferenceObject(Abandoned[Index]);
end;

function CreateNetworkChangeWatcher(UserId: LongWord): PEventObject;
var
  Abandoned: TWatcherList;
  AbandonedCount: Integer;
  PreviousLevel: TPriorityLevel;
  Index: Integer;
  Placed: Boolean;
begin
  Result := CreateEventObject(False, False);
  if Result = nil then
    Exit;
  { The table's reference. }
  ReferenceObject(Result);
  Placed := False;
  PreviousLevel := AcquireSpinLock(WatcherLock);
  AbandonedCount := TakeAbandonedWatchers(Abandoned);
  if UserHasRoom(UserId) then
    for Index := 0 to MaximumNetworkChangeWatchers - 1 do
      if Watchers[Index] = nil then
      begin
        Watchers[Index] := Result;
        WatcherOwners[Index] := UserId;
        Placed := True;
        Break;
      end;
  ReleaseSpinLock(WatcherLock, PreviousLevel);
  ReleaseAbandonedWatchers(Abandoned, AbandonedCount);
  if not Placed then
  begin
    { Both references go: the table's and the caller's. }
    DereferenceObject(Result);
    DereferenceObject(Result);
    Result := nil;
  end;
end;

procedure NoteNetworkChange;
var
  Abandoned: TWatcherList;
  AbandonedCount: Integer;
  PreviousLevel: TPriorityLevel;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(WatcherLock);
  AbandonedCount := TakeAbandonedWatchers(Abandoned);
  for Index := 0 to MaximumNetworkChangeWatchers - 1 do
    if Watchers[Index] <> nil then
      SignalEvent(Watchers[Index]^.Event);
  ReleaseSpinLock(WatcherLock, PreviousLevel);
  ReleaseAbandonedWatchers(Abandoned, AbandonedCount);
end;

end.
