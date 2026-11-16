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
    - a watch on /etc/settings: Network.settings written, created or
      renamed into place (as the system settings service and the
      settings library write it) is read again and applied;
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
  Sys.FileWatches,
  Sys.Information,
  Sys.NetworkInterfaces,
  Sys.ServiceControl,
  NetworkService.Log,
  NetworkService.Settings,
  NetworkService.DhcpLeases,
  NetworkService.Interfaces;

const
  SettingsFolder = '/etc/settings';
  SettingsFileName = 'Network.settings';
  { The longest wait without looking at the time. }
  LongestWaitMilliseconds = 5000;

var
  Manager: TInterfaceManager;
  SettingsWatch: Int64 = -1;
  ChangeWatch: Int64 = -1;
  AppliedHostName: string;

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

procedure OpenSettingsWatch;
begin
  SettingsWatch := WatchPath(SettingsFolder, WatchNames or WatchContents);
  if SettingsWatch < 0 then
  begin
    Say('cannot watch ' + SettingsFolder + ': ' + ErrorText(LongInt(-SettingsWatch)) +
      ' (the settings are read again every few seconds)');
    SettingsWatch := -1;
  end;
end;

{ True if a change in the folder concerns Network.settings. }
function SettingsFileChanged: Boolean;
var
  Reader: TFileChangeReader;
  Change: TFileChange;
begin
  Result := False;
  while ReadFileChanges(Reader, SettingsWatch) = ErrorNone do
    while NextFileChange(Reader, Change) do
    begin
      if (Change.Kind = FileChangeOverflow) or
         (string(Change.Name) = SettingsFileName) or
         (string(Change.OldName) = SettingsFileName) then
        Result := True;
      if (Change.Kind = FileChangeWatchedItemRemoved) or (Change.Kind = FileChangeVolumeGone) then
      begin
        CloseHandle(SettingsWatch);
        SettingsWatch := -1;
        Exit(True);
      end;
    end;
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
begin
  Deadline := Manager.NextDeadline;
  Now := QWord(KernelGetTime(TimeUptimeMilliseconds));
  if Deadline <= Now then
    Exit(0);
  if Deadline - Now > LongestWaitMilliseconds then
    Exit(LongestWaitMilliseconds);
  Result := Int64(Deadline - Now);
end;

procedure ServeUntilAskedToEnd;
var
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Count: Integer;
  SettingsPosition: Integer;
  ChangePosition: Integer;
  Ready: Int64;
begin
  repeat
    Count := 0;
    Handles[Count] := NotificationsHandle;
    Inc(Count);
    SettingsPosition := -1;
    if SettingsWatch >= 0 then
    begin
      SettingsPosition := Count;
      Handles[Count] := SettingsWatch;
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
    else if (Ready > 0) and (Ready = SettingsPosition) then
    begin
      if SettingsFileChanged then
      begin
        Say(SettingsFileName + ' changed');
        ReadAndApplySettings;
      end;
      if SettingsWatch < 0 then
        OpenSettingsWatch;
    end
    else if (Ready > 0) and (Ready = ChangePosition) then
      Manager.RefreshInterfaces
    else if (Ready > 0) and (Ready < Count) then
      Manager.HandleReadable(Handles[Ready])
    else if SettingsWatch < 0 then
      { Without a watch: look again now and then. }
      ReadAndApplySettings;
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
    OpenSettingsWatch;
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
  if SettingsWatch >= 0 then
    CloseHandle(SettingsWatch);
  if ChangeWatch >= 0 then
    CloseHandle(ChangeWatch);
  Say('stopped');
end;

end.
