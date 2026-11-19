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
  The network service's main loop. It waits, all at once, for:
    - its notifications (a request to end: the service stopped, the
      system shutting down), which end the loop;
    - the system's settings, group Network (Configuration.Watcher, on
      /etc/settings): when a value in Network.settings changes - however
      it is written, the settings library's safe write included - it is
      read again and applied; a rewrite that changes nothing is not;
    - the kernel's network changes (CallWatchNetworkChanges): adapters
      that appear, links that come or go;
    - the DHCP clients' sockets;
  and wakes at the clients' next deadline (at least every few seconds,
  so a state that changes with time alone, "failed", is written).
}
unit NetworkService.Supervisor;

{$mode objfpc}
{$H+}

interface

{ Applies the settings, tells the service manager it is ready, and
  serves until asked to end; then gives the leases back. }
procedure RunNetworkService;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Objects,
  Sys.Notifications,
  Sys.Information,
  Sys.NetworkInterfaces,
  Sys.ServiceControl,
  Configuration.Changes,
  Configuration.Watcher,
  NetworkService.Log,
  NetworkService.Settings,
  NetworkService.DhcpLeases,
  NetworkService.StableSecret,
  NetworkService.Interfaces;

const
  SettingsGroup = 'Network';
  SettingsFileName = 'Network.settings';
  { The longest wait without looking at the time. }
  LongestWaitMilliseconds = 5000;

type
  TSettingsFollower = class
  public
    Changed: Boolean;
    procedure GroupChanged(const Group: string; const Changes: TSettingChanges);
  end;

var
  Manager: TInterfaceManager;
  SettingsWatcher: TSettingsWatcher;
  Follower: TSettingsFollower;
  ChangeWatch: Int64 = -1;
  AppliedHostName: string;

procedure TSettingsFollower.GroupChanged(const Group: string; const Changes: TSettingChanges);
begin
  Changed := True;
end;

procedure ApplyHostName(const HostName: string);
var
  Error: LongInt;
begin
  if (HostName = '') or (HostName = AppliedHostName) then
    Exit;
  Error := SetNodeName(PChar(HostName));
  if Error <> ErrorNone then
    Say('host name "' + HostName + '": ' + ErrorText(Error))
  else
    Say('host name ' + HostName);
  AppliedHostName := HostName;
end;

procedure ReadAndApplySettings;
var
  Settings: TNetworkSettings;
begin
  Settings := ReadNetworkSettings;
  ApplyHostName(Settings.HostName);
  Manager.ApplySettings(Settings);
end;

procedure OpenSettingsWatcher;
begin
  Follower := TSettingsFollower.Create;
  SettingsWatcher := OpenSystemSettingsWatcher;
  SettingsWatcher.OnChanged := @Follower.GroupChanged;
  SettingsWatcher.Watch(SettingsGroup);
  if Length(SettingsWatcher.Handles(False)) = 0 then
    Say('cannot watch the settings (they are read again every few seconds)');
end;

{ Applies the settings if a burst of changes to them is over. }
procedure ApplyChangedSettings;
begin
  Follower.Changed := False;
  SettingsWatcher.DeliverChanges;
  if not Follower.Changed then
    Exit;
  Say(SettingsFileName + ' changed');
  ReadAndApplySettings;
end;

function EndWasRequested: Boolean;
var
  Notification: TAbiNotification;
begin
  Result := False;
  while ReceiveNotification(Notification) do
    if Notification.Kind = NotificationEndRequested then
    begin
      Say('asked to end (' + string(EndReasonName(Notification.Reason)) + ')');
      Result := True;
    end;
end;

function WaitTime: Int64;
var
  Deadline: QWord;
  Now: QWord;
  SettingsWait: Int64;
begin
  Deadline := Manager.NextDeadline;
  Now := QWord(KernelGetTime(TimeUptimeMilliseconds));
  if Deadline <= Now then
    Exit(0);
  if Deadline - Now > LongestWaitMilliseconds then
    Result := LongestWaitMilliseconds
  else
    Result := Int64(Deadline - Now);
  SettingsWait := SettingsWatcher.WaitTime;
  if (SettingsWait <> InfiniteWait) and (SettingsWait < Result) then
    Result := SettingsWait;
end;

procedure ServeUntilAskedToEnd;
var
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Count: Integer;
  SettingsHandles: TWatcherHandles;
  FirstSettings: Integer;
  Index: Integer;
  ChangePosition: Integer;
  Ready: Int64;
begin
  repeat
    Count := 0;
    Handles[Count] := NotificationsHandle;
    Inc(Count);
    FirstSettings := Count;
    SettingsHandles := SettingsWatcher.Handles(False);
    for Index := 0 to High(SettingsHandles) do
    begin
      Handles[Count] := SettingsHandles[Index];
      Inc(Count);
    end;
    ChangePosition := -1;
    if ChangeWatch >= 0 then
    begin
      ChangePosition := Count;
      Handles[Count] := ChangeWatch;
      Inc(Count);
    end;
    Manager.CollectSockets(Handles, Count);
    Ready := WaitForHandles(Slice(Handles, Count), WaitTime);
    if Ready = 0 then
    begin
      if EndWasRequested then
        Exit;
    end
    else if (Ready >= FirstSettings) and (Ready < FirstSettings + Length(SettingsHandles)) then
      SettingsWatcher.HandleReady(Handles[Ready])
    else if (Ready > 0) and (Ready = ChangePosition) then
      Manager.RefreshInterfaces
    else if (Ready > 0) and (Ready < Count) then
      Manager.HandleReadable(Handles[Ready]);
    { Without watches the watcher looks at the settings now and then by
      itself. }
    ApplyChangedSettings;
    Manager.HandleDeadlines;
  until False;
end;

procedure RunNetworkService;
begin
  TakeNotifications(NotifyEndRequests);
  Manager := TInterfaceManager.Create;
  try
    ChangeWatch := WatchNetworkChanges;
    if ChangeWatch < 0 then
    begin
      Say('cannot watch the network for changes: ' + ErrorText(LongInt(-ChangeWatch)));
      ChangeWatch := -1;
    end;
    OpenSettingsWatcher;
    { Before any interface is set up: its IPv6 addresses depend on it. }
    ApplyStableSecret;
    { The settings first, so each interface is set up once as they say. }
    ReadAndApplySettings;
    Manager.RefreshInterfaces;
    Say('ready');
    NotifyServiceReady;
    ServeUntilAskedToEnd;
    Manager.StopAll;
  finally
    Manager.Free;
  end;
  SettingsWatcher.Free;
  Follower.Free;
  if ChangeWatch >= 0 then
    CloseHandle(ChangeWatch);
  Say('stopped');
end;

end.
