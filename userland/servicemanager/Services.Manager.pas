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
  The manager's loop.

  It wants the services of the boot mode, then waits in one place for
  whatever comes first: the kernel's shutdown event, a request to end
  the manager itself (its notifications), a connection or a request at
  its port, a service's program ending, or the next deadline (a restart
  due, a wait for readiness or a stop running out). After each, it
  starts what can start - or, once shutting down, stops what may stop -
  and when shutting down and nothing runs any more, it returns.
}
unit Services.Manager;

{$mode objfpc}
{$H+}

interface

{ Runs the services of BootMode until the system shuts down. ShutdownEvent
  is the kernel's (NoHandle when this manager does not watch for
  shutdowns: a second one, for tests, runs until it is ended). }
procedure RunServices(const BootMode: string; ShutdownEvent: Int64);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Notifications,
  Sys.Objects,
  Sys.Processes,
  Services.Definitions,
  Services.Catalog,
  Services.Control,
  Services.Logs,
  Services.Supervisor,
  Services.Shutdown;

type
  TWaitSource = (SourceShutdown, SourceNotifications, SourcePort, SourceClient, SourceService);

  TWaitList = record
    Handles: array[0..MaximumWaitHandles - 1] of Int64;
    Sources: array[0..MaximumWaitHandles - 1] of TWaitSource;
    { The client's position, or the service. }
    Clients: array[0..MaximumWaitHandles - 1] of LongInt;
    ProcessServices: array[0..MaximumWaitHandles - 1] of TService;
    Count: LongInt;
  end;

procedure AddToWaitList(var List: TWaitList; Handle: Int64; Source: TWaitSource; Client: LongInt;
  Service: TService);
begin
  if List.Count >= MaximumWaitHandles then
    Exit;
  List.Handles[List.Count] := Handle;
  List.Sources[List.Count] := Source;
  List.Clients[List.Count] := Client;
  List.ProcessServices[List.Count] := Service;
  Inc(List.Count);
end;

procedure BuildWaitList(var List: TWaitList; ShutdownEvent: Int64);
var
  Index: LongInt;
begin
  List.Count := 0;
  if (ShutdownEvent <> NoHandle) and not ShuttingDown then
    AddToWaitList(List, ShutdownEvent, SourceShutdown, 0, nil);
  AddToWaitList(List, NotificationsHandle, SourceNotifications, 0, nil);
  if ControlPort <> NoHandle then
    AddToWaitList(List, ControlPort, SourcePort, 0, nil);
  for Index := 0 to ClientCount - 1 do
    AddToWaitList(List, Clients[Index], SourceClient, Index, nil);
  for Index := 0 to High(ServiceTable) do
    if ServiceTable[Index].HasProcess then
      AddToWaitList(List, ServiceTable[Index].ProcessHandle, SourceService, 0, ServiceTable[Index]);
end;

procedure WantBootModeServices(const BootMode: string);
var
  Index: LongInt;
begin
  for Index := 0 to High(ServiceTable) do
  begin
    if ServiceTable[Index].Problem <> '' then
      Say(ServiceTable[Index].Definition.Name + ' cannot start: ' + ServiceTable[Index].Problem)
    else if BelongsToMode(ServiceTable[Index].Definition, BootMode) then
    begin
      ServiceTable[Index].InBootMode := True;
      WantService(ServiceTable[Index]);
    end;
  end;
end;

{ A request to end the manager stops every service in order, as a
  shutdown does; the manager then ends. }
procedure ActOnNotifications;
var
  Notification: TAbiNotification;
begin
  while ReceiveNotification(Notification) do
    if (Notification.Kind = NotificationEndRequested) and not ShuttingDown then
      BeginShutdown('asked to end (' + EndReasonName(Notification.Reason) + ')', EndReasonServiceStop);
end;

procedure RunServices(const BootMode: string; ShutdownEvent: Int64);
var
  List: TWaitList;
  Ready: Int64;
begin
  TakeNotifications(NotifyEndRequests);
  WantBootModeServices(BootMode);
  repeat
    if ShuttingDown then
    begin
      StopServicesInOrder;
      if EveryServiceStopped then
        Break;
    end
    else
      StartWaitingServices;
    BuildWaitList(List, ShutdownEvent);
    Ready := WaitForHandles(Slice(List.Handles, List.Count), MillisecondsToNextDeadline);
    if (Ready >= 0) and (Ready < List.Count) then
      case List.Sources[Ready] of
        SourceShutdown: BeginShutdown('the system is shutting down', EndReasonShutdown);
        SourceNotifications: ActOnNotifications;
        SourcePort: AcceptClients;
        SourceClient: ServeClient(List.Clients[Ready]);
        SourceService: ServiceProcessEnded(List.ProcessServices[Ready]);
      end;
    HandleDeadlines;
  until False;
  Say('every service has stopped');
end;

end.
