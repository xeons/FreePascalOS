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
  Hearing that settings changed: a program names the groups it cares
  about and is told, per group, which keys changed and from what to
  what, as soon as anyone changes them - another program, the settings
  tool, an administrator changing the system's settings or fixing a
  value.

  The watcher has a TSettings of its own (the user's over the system's,
  or one scope) and watches each scope's folder (Sys.FileWatches): two
  handles at most, one while a user's folder does not exist yet (its
  parent, the home, is watched until it appears). What the folders
  report goes to a Configuration.ChangeTracker, which waits a burst of
  changes out (a safe write is several: GROUP.settings.new made, written
  and renamed over GROUP.settings), reads the groups touched again and
  compares their values with what they were; OnChanged hears of a group
  only if a value a program sees changed.

  Two ways to use it:

    - in a loop of the program's own (a service): wait on Handles along
      with the program's other handles, for at most WaitTime; call
      HandleReady with a watcher handle that was ready, and
      DeliverChanges after every wait (it does nothing until a burst is
      over);
    - blocking: WaitForChanges waits until a group is reported, or for a
      time.

  A window program uses Windowing.SettingsChanges, which puts the
  watcher into the message loop (Handles(True) adds a timer of the
  watcher's own that is due when DeliverChanges is).

  Without watches (too many handles, a folder that cannot be watched)
  the folders are looked at again every PollMilliseconds.
}
unit Configuration.Watcher;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Changes,
  Configuration.ChangeTracker,
  Configuration.Settings;

const
  PollMilliseconds = 5000;

type
  TWatcherHandles = array of Int64;

  TScopeWatch = record
    Folder: string;
    { -1: none. }
    Handle: Int64;
    { The folder does not exist: its parent is watched for it. }
    WatchingParent: Boolean;
  end;

  TSettingsWatcher = class
  private
    FTracker: TSettingsChangeTracker;
    FScopes: array[TSettingsScopeKind] of TScopeWatch;
    FTimer: Int64;
    FTimerDue: QWord;
    FNextPoll: QWord;
    function GetOnChanged: TSettingsGroupChangedEvent;
    procedure SetOnChanged(Value: TSettingsGroupChangedEvent);
    function GetSettings: TSettings;
    procedure OpenScopeWatch(Kind: TSettingsScopeKind);
    procedure CloseScopeWatch(Kind: TSettingsScopeKind);
    function NeedsPolling: Boolean;
    procedure ReadScopeWatch(Kind: TSettingsScopeKind);
    procedure ReadParentWatch(Kind: TSettingsScopeKind);
    procedure ArmTimer;
    procedure PollIfDue;
  public
    { Takes Settings over (frees it). }
    constructor Create(Settings: TSettings);
    destructor Destroy; override;

    procedure Watch(const Group: string);
    procedure Unwatch(const Group: string);
    function IsWatching(const Group: string): Boolean;

    { The handles to wait on: the folders' watches, and with
      IncludeTimer the watcher's timer. They change when a folder comes
      or goes, so ask again after every HandleReady. }
    function Handles(IncludeTimer: Boolean): TWatcherHandles;
    function OwnsHandle(Handle: Int64): Boolean;
    { One of Handles was ready: takes what it holds. }
    procedure HandleReady(Handle: Int64);
    { Milliseconds until DeliverChanges has something to do
      (InfiniteWait if nothing is waited for). }
    function WaitTime: Int64;
    { Reports the groups whose burst of changes is over; how many. }
    function DeliverChanges: Integer;
    { Waits until at least one group is reported (how many), or for
      Timeout milliseconds (InfiniteWait: no limit; 0 then). }
    function WaitForChanges(Timeout: Int64): Integer;

    property Settings: TSettings read GetSettings;
    property OnChanged: TSettingsGroupChangedEvent read GetOnChanged write SetOnChanged;
  end;

{ The current user's settings over the system's. }
function OpenSettingsWatcher: TSettingsWatcher;
{ The system's settings alone. }
function OpenSystemSettingsWatcher: TSettingsWatcher;
{ The settings of the user whose home is Home over the system's. }
function OpenSettingsWatcherOfHome(const Home: string): TSettingsWatcher;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Time,
  Sys.Processes,
  Sys.FileWatches,
  Configuration.Locations;

const
  NoWatch = -1;

function OpenSettingsWatcher: TSettingsWatcher;
begin
  Result := TSettingsWatcher.Create(OpenSettings);
end;

function OpenSystemSettingsWatcher: TSettingsWatcher;
begin
  Result := TSettingsWatcher.Create(OpenSystemSettings);
end;

function OpenSettingsWatcherOfHome(const Home: string): TSettingsWatcher;
begin
  Result := TSettingsWatcher.Create(OpenSettingsOfHome(Home));
end;

function ParentFolder(const Folder: string): string;
var
  Index: Integer;
begin
  Index := Length(Folder);
  while (Index > 0) and (Folder[Index] <> '/') do
    Dec(Index);
  if Index <= 1 then
    Result := '/'
  else
    Result := Copy(Folder, 1, Index - 1);
end;

function LastName(const Folder: string): string;
var
  Index: Integer;
begin
  Index := Length(Folder);
  while (Index > 0) and (Folder[Index] <> '/') do
    Dec(Index);
  Result := Copy(Folder, Index + 1, Length(Folder));
end;

constructor TSettingsWatcher.Create(Settings: TSettings);
var
  Kind: TSettingsScopeKind;
begin
  inherited Create;
  FTracker := TSettingsChangeTracker.Create(Settings, True);
  FTimer := NoWatch;
  FTimerDue := NoDeadline;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
  begin
    FScopes[Kind].Handle := NoWatch;
    FScopes[Kind].Folder := '';
    if Settings.HasScope(Kind) then
    begin
      FScopes[Kind].Folder := Settings.Scopes[Kind].Storage.Location;
      OpenScopeWatch(Kind);
    end;
  end;
  FNextPoll := UptimeMilliseconds + PollMilliseconds;
end;

destructor TSettingsWatcher.Destroy;
var
  Kind: TSettingsScopeKind;
begin
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    CloseScopeWatch(Kind);
  if FTimer >= 0 then
    CloseHandle(FTimer);
  FTracker.Free;
  inherited Destroy;
end;

function TSettingsWatcher.GetOnChanged: TSettingsGroupChangedEvent;
begin
  Result := FTracker.OnChanged;
end;

procedure TSettingsWatcher.SetOnChanged(Value: TSettingsGroupChangedEvent);
begin
  FTracker.OnChanged := Value;
end;

function TSettingsWatcher.GetSettings: TSettings;
begin
  Result := FTracker.Settings;
end;

procedure TSettingsWatcher.Watch(const Group: string);
begin
  FTracker.Watch(Group);
end;

procedure TSettingsWatcher.Unwatch(const Group: string);
begin
  FTracker.Unwatch(Group);
end;

function TSettingsWatcher.IsWatching(const Group: string): Boolean;
begin
  Result := FTracker.IsWatching(Group);
end;

procedure TSettingsWatcher.OpenScopeWatch(Kind: TSettingsScopeKind);
var
  Handle: Int64;
begin
  if FScopes[Kind].Folder = '' then
    Exit;
  Handle := WatchPath(PChar(FScopes[Kind].Folder), WatchNames or WatchContents);
  FScopes[Kind].WatchingParent := False;
  if Handle = -ErrorNotFound then
  begin
    { No settings there yet: wait for the folder to be made. }
    Handle := WatchPath(PChar(ParentFolder(FScopes[Kind].Folder)), WatchNames);
    FScopes[Kind].WatchingParent := Handle >= 0;
  end;
  if Handle < 0 then
    Handle := NoWatch;
  FScopes[Kind].Handle := Handle;
end;

procedure TSettingsWatcher.CloseScopeWatch(Kind: TSettingsScopeKind);
begin
  if FScopes[Kind].Handle >= 0 then
    CloseHandle(FScopes[Kind].Handle);
  FScopes[Kind].Handle := NoWatch;
  FScopes[Kind].WatchingParent := False;
end;

function TSettingsWatcher.NeedsPolling: Boolean;
var
  Kind: TSettingsScopeKind;
begin
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if (FScopes[Kind].Folder <> '') and (FScopes[Kind].Handle < 0) then
      Exit(True);
  Result := False;
end;

function TSettingsWatcher.Handles(IncludeTimer: Boolean): TWatcherHandles;
var
  Kind: TSettingsScopeKind;
begin
  Result := nil;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if FScopes[Kind].Handle >= 0 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FScopes[Kind].Handle;
    end;
  if IncludeTimer then
  begin
    if FTimer < 0 then
    begin
      FTimer := CreateTimer(False);
      if FTimer < 0 then
        FTimer := NoWatch;
      ArmTimer;
    end;
    if FTimer >= 0 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FTimer;
    end;
  end;
end;

function TSettingsWatcher.OwnsHandle(Handle: Int64): Boolean;
var
  Kind: TSettingsScopeKind;
begin
  if Handle < 0 then
    Exit(False);
  if Handle = FTimer then
    Exit(True);
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if FScopes[Kind].Handle = Handle then
      Exit(True);
  Result := False;
end;

procedure TSettingsWatcher.ReadScopeWatch(Kind: TSettingsScopeKind);
var
  Reader: TFileChangeReader;
  Change: TFileChange;
  Now: QWord;
  Reopen: Boolean;
begin
  Reopen := False;
  while (FScopes[Kind].Handle >= 0) and (ReadFileChanges(Reader, FScopes[Kind].Handle) = ErrorNone) do
    while NextFileChange(Reader, Change) do
    begin
      Now := UptimeMilliseconds;
      case Change.Kind of
        FileChangeOverflow:
          FTracker.NoteEverythingChanged(Now);
        FileChangeWatchedItemRemoved, FileChangeWatchedItemMoved, FileChangeVolumeGone:
          begin
            { The folder went: its settings with it. }
            FTracker.NoteEverythingChanged(Now);
            Reopen := Change.Kind <> FileChangeVolumeGone;
            CloseScopeWatch(Kind);
          end;
      else
        FTracker.NoteFileChanged(string(Change.Name), Now);
        if Change.OldName <> nil then
          FTracker.NoteFileChanged(string(Change.OldName), Now);
      end;
    end;
  if Reopen then
    OpenScopeWatch(Kind);
end;

procedure TSettingsWatcher.ReadParentWatch(Kind: TSettingsScopeKind);
var
  Reader: TFileChangeReader;
  Change: TFileChange;
  Appeared: Boolean;
  Name: string;
begin
  Appeared := False;
  Name := LastName(FScopes[Kind].Folder);
  while (FScopes[Kind].Handle >= 0) and (ReadFileChanges(Reader, FScopes[Kind].Handle) = ErrorNone) do
    while NextFileChange(Reader, Change) do
      case Change.Kind of
        FileChangeOverflow:
          Appeared := True;
        FileChangeWatchedItemRemoved, FileChangeWatchedItemMoved, FileChangeVolumeGone:
          begin
            CloseScopeWatch(Kind);
            Exit;
          end;
      else
        if string(Change.Name) = Name then
          Appeared := True;
      end;
  if not Appeared then
    Exit;
  CloseScopeWatch(Kind);
  OpenScopeWatch(Kind);
  if not FScopes[Kind].WatchingParent then
    { Settings may have been written into it before the watch began. }
    FTracker.NoteEverythingChanged(UptimeMilliseconds);
end;

procedure TSettingsWatcher.HandleReady(Handle: Int64);
var
  Kind: TSettingsScopeKind;
begin
  if (Handle >= 0) and (Handle = FTimer) then
  begin
    { Its signal is consumed by the wait; DeliverChanges does the rest. }
    FTimerDue := NoDeadline;
    DeliverChanges;
    Exit;
  end;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if (Handle >= 0) and (FScopes[Kind].Handle = Handle) then
    begin
      if FScopes[Kind].WatchingParent then
        ReadParentWatch(Kind)
      else
        ReadScopeWatch(Kind);
      Break;
    end;
  ArmTimer;
end;

procedure TSettingsWatcher.ArmTimer;
var
  Due: QWord;
  Now: QWord;
begin
  if FTimer < 0 then
    Exit;
  Due := FTracker.Deadline;
  if NeedsPolling and (FNextPoll < Due) then
    Due := FNextPoll;
  if Due = FTimerDue then
    Exit;
  FTimerDue := Due;
  if Due = NoDeadline then
  begin
    SetTimer(FTimer, 0, 0);
    Exit;
  end;
  Now := UptimeMilliseconds;
  if Due <= Now then
    SetTimer(FTimer, 1, 0)
  else
    SetTimer(FTimer, Due - Now, 0);
end;

procedure TSettingsWatcher.PollIfDue;
var
  Kind: TSettingsScopeKind;
  Now: QWord;
begin
  if not NeedsPolling then
    Exit;
  Now := UptimeMilliseconds;
  if Now < FNextPoll then
    Exit;
  FNextPoll := Now + PollMilliseconds;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if (FScopes[Kind].Folder <> '') and (FScopes[Kind].Handle < 0) then
      OpenScopeWatch(Kind);
  { Whether a watch could be made now or not, the groups are looked at:
    what changed meanwhile is not lost. }
  FTracker.NoteEverythingChanged(Now);
end;

function TSettingsWatcher.WaitTime: Int64;
var
  Due: QWord;
  Now: QWord;
begin
  Due := FTracker.Deadline;
  if NeedsPolling and (FNextPoll < Due) then
    Due := FNextPoll;
  if Due = NoDeadline then
    Exit(InfiniteWait);
  Now := UptimeMilliseconds;
  if Due <= Now then
    Result := 0
  else
    Result := Int64(Due - Now);
end;

function TSettingsWatcher.DeliverChanges: Integer;
begin
  PollIfDue;
  Result := FTracker.Collect(UptimeMilliseconds);
  ArmTimer;
end;

function TSettingsWatcher.WaitForChanges(Timeout: Int64): Integer;
var
  Start: QWord;
  Waited: QWord;
  Wait: Int64;
  Remaining: Int64;
  Waiting: TWatcherHandles;
  Ready: Int64;
begin
  Start := UptimeMilliseconds;
  repeat
    Wait := WaitTime;
    if Timeout <> InfiniteWait then
    begin
      Waited := UptimeMilliseconds - Start;
      if Waited >= QWord(Timeout) then
        Remaining := 0
      else
        Remaining := Timeout - Int64(Waited);
      if (Wait = InfiniteWait) or (Remaining < Wait) then
        Wait := Remaining;
    end;
    Waiting := Handles(False);
    if Length(Waiting) = 0 then
    begin
      if Wait = InfiniteWait then
        Wait := PollMilliseconds;
      SleepMilliseconds(QWord(Wait));
      Ready := -1;
    end
    else
      Ready := WaitForHandles(Waiting, Wait);
    if (Ready >= 0) and (Ready < Length(Waiting)) then
      HandleReady(Waiting[Ready]);
    Result := DeliverChanges;
    if Result > 0 then
      Exit;
  until (Timeout <> InfiniteWait) and (UptimeMilliseconds - Start >= QWord(Timeout));
end;

end.
