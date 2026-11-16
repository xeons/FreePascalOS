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
  Settings changes in a window program's message loop.

  SubscribeToSettings is what a program usually wants: its handler is
  called, from the message loop, whenever a group of the current user's
  settings (over the system's) changes, with the keys that changed
  (Configuration.Changes). However many groups and handlers a program
  has, they share one watcher (Configuration.Watcher), which takes at
  most three of the loop's handle watches (Windowing.HandleWatches):
  the system's folder, the user's (or their home until it exists) and a
  timer that waits a burst of changes out.

  TLoopSettingsWatcher puts any other watcher into the loop (the session
  manager watches the settings of the user who logged in): it keeps the
  watcher's handles watched as they come and go. Its watcher's handlers
  must not free it (they run inside it); a program switches watchers
  elsewhere.

  A program's own writes are heard too (its settings file changed); a
  handler that applies what the settings say finds nothing to do.
}
unit Windowing.SettingsChanges;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.Changes,
  Configuration.ChangeTracker,
  Configuration.Watcher;

type
  TLoopSettingsWatcher = class
  private
    FWatcher: TSettingsWatcher;
    FOwnsWatcher: Boolean;
    FWatched: TWatcherHandles;
    procedure HandleIsReady(Handle: Int64);
    procedure SyncHandles;
    procedure StopWatchingAll;
  public
    { Watches Watcher's handles from now on; frees it if OwnsWatcher. }
    constructor Create(Watcher: TSettingsWatcher; OwnsWatcher: Boolean);
    destructor Destroy; override;
    property Watcher: TSettingsWatcher read FWatcher;
  end;

{ Calls Handler whenever Group of the current user's settings changes.
  A handler may subscribe to several groups. }
procedure SubscribeToSettings(const Group: string; Handler: TSettingsGroupChangedEvent);
{ Stops calling Handler, for every group (an object going away). }
procedure UnsubscribeFromSettings(Handler: TSettingsGroupChangedEvent);

implementation

uses
  Windowing.HandleWatches;

{ --- TLoopSettingsWatcher ---------------------------------------------------------------------- }

constructor TLoopSettingsWatcher.Create(Watcher: TSettingsWatcher; OwnsWatcher: Boolean);
begin
  inherited Create;
  FWatcher := Watcher;
  FOwnsWatcher := OwnsWatcher;
  SyncHandles;
end;

destructor TLoopSettingsWatcher.Destroy;
begin
  StopWatchingAll;
  if FOwnsWatcher then
    FWatcher.Free;
  inherited Destroy;
end;

procedure TLoopSettingsWatcher.StopWatchingAll;
var
  Index: Integer;
begin
  for Index := 0 to High(FWatched) do
    StopWatchingHandle(FWatched[Index]);
  FWatched := nil;
end;

procedure TLoopSettingsWatcher.SyncHandles;
var
  Wanted: TWatcherHandles;
  Index: Integer;
begin
  Wanted := FWatcher.Handles(True);
  StopWatchingAll;
  for Index := 0 to High(Wanted) do
    { A handle the loop has no room for is left out: the watcher then
      hears of changes later (its timer or the next change), or not. }
    if WatchHandle(Wanted[Index], @HandleIsReady) then
    begin
      SetLength(FWatched, Length(FWatched) + 1);
      FWatched[High(FWatched)] := Wanted[Index];
    end;
end;

procedure TLoopSettingsWatcher.HandleIsReady(Handle: Int64);
begin
  FWatcher.HandleReady(Handle);
  { A folder's watch may have been replaced (the folder made or
    removed). }
  SyncHandles;
end;

{ --- The program's subscriptions -------------------------------------------------------------- }

type
  TSubscription = record
    Group: string;
    Handler: TSettingsGroupChangedEvent;
  end;

  TSubscriptions = class
  public
    Items: array of TSubscription;
    procedure GroupChanged(const Group: string; const Changes: TSettingChanges);
  end;

var
  Subscriptions: TSubscriptions;
  SharedWatcher: TLoopSettingsWatcher;

function SameHandler(First, Second: TSettingsGroupChangedEvent): Boolean;
begin
  Result := (TMethod(First).Code = TMethod(Second).Code) and (TMethod(First).Data = TMethod(Second).Data);
end;

function IsSubscribed(const Group: string; Handler: TSettingsGroupChangedEvent): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Subscriptions.Items) do
    if (Subscriptions.Items[Index].Group = Group) and SameHandler(Subscriptions.Items[Index].Handler, Handler) then
      Exit(True);
  Result := False;
end;

procedure TSubscriptions.GroupChanged(const Group: string; const Changes: TSettingChanges);
var
  Called: array of TSettingsGroupChangedEvent;
  Index: Integer;
begin
  { A handler may subscribe or unsubscribe: the list is copied first. }
  Called := nil;
  for Index := 0 to High(Items) do
    if Items[Index].Group = Group then
    begin
      SetLength(Called, Length(Called) + 1);
      Called[High(Called)] := Items[Index].Handler;
    end;
  for Index := 0 to High(Called) do
    { An earlier handler may have unsubscribed a later one (freed its
      object). }
    if IsSubscribed(Group, Called[Index]) then
      Called[Index](Group, Changes);
end;

function AnyoneWants(const Group: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Subscriptions.Items) do
    if Subscriptions.Items[Index].Group = Group then
      Exit(True);
  Result := False;
end;

procedure SubscribeToSettings(const Group: string; Handler: TSettingsGroupChangedEvent);
var
  Watcher: TSettingsWatcher;
begin
  if Subscriptions = nil then
    Subscriptions := TSubscriptions.Create;
  if IsSubscribed(Group, Handler) then
    Exit;
  SetLength(Subscriptions.Items, Length(Subscriptions.Items) + 1);
  Subscriptions.Items[High(Subscriptions.Items)].Group := Group;
  Subscriptions.Items[High(Subscriptions.Items)].Handler := Handler;
  if SharedWatcher = nil then
  begin
    Watcher := OpenSettingsWatcher;
    Watcher.OnChanged := @Subscriptions.GroupChanged;
    SharedWatcher := TLoopSettingsWatcher.Create(Watcher, True);
  end;
  SharedWatcher.Watcher.Watch(Group);
end;

procedure UnsubscribeFromSettings(Handler: TSettingsGroupChangedEvent);
var
  Index: Integer;
  Group: string;
begin
  if Subscriptions = nil then
    Exit;
  Index := 0;
  while Index < Length(Subscriptions.Items) do
    if SameHandler(Subscriptions.Items[Index].Handler, Handler) then
    begin
      Group := Subscriptions.Items[Index].Group;
      Delete(Subscriptions.Items, Index, 1);
      if (SharedWatcher <> nil) and not AnyoneWants(Group) then
        SharedWatcher.Watcher.Unwatch(Group);
    end
    else
      Inc(Index);
  { The watcher stays for the program's life: subscribing again is
    common (a page shown again), and it costs nothing while idle. }
end;

finalization
  SharedWatcher.Free;
  Subscriptions.Free;
end.
