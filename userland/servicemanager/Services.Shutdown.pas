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
  Stopping every service when the system shuts down.

  The kernel tells the manager a shutdown has started (the event of
  CallWatchShutdown: the power button, poweroff, reboot, the desktop's
  Shut down) and waits for it to end. The services stop in the reverse
  of the order they started in: a service is stopped once no running
  service needs it any more, so the session goes before the display
  server, and services that do not need each other stop together. Each
  is stopped as `service stop` would (its programs asked to end, for the
  reason "shutdown", and ended outright after its stop-timeout). Once
  none runs, the manager ends, and the kernel asks whatever is left to
  end, then ends it, writes the disks out and powers off.

  A manager asked to end (a second one, for tests) stops its services
  the same way, for the reason "service stop", and ends.
}
unit Services.Shutdown;

{$mode objfpc}
{$H+}

interface

var
  ShuttingDown: Boolean = False;

{ Stops wanting every service, and cancels restarts. Why goes in the
  log; Reason (EndReason*) is what the services' programs are told. }
procedure BeginShutdown(const Why: string; Reason: LongWord);
{ Stops each running service that no running service needs. }
procedure StopServicesInOrder;
{ True once no service has a process. }
function EveryServiceStopped: Boolean;

implementation

uses
  Sys.ServiceControl,
  Services.Catalog,
  Services.Logs,
  Services.Supervisor;

var
  StopReason: LongWord;

procedure BeginShutdown(const Why: string; Reason: LongWord);
var
  Index: LongInt;
  Service: TService;
begin
  ShuttingDown := True;
  StopReason := Reason;
  Say(Why + ': stopping the services');
  for Index := 0 to High(ServiceTable) do
  begin
    Service := ServiceTable[Index];
    Service.Wanted := False;
    Service.StartWhenStopped := False;
    if not Service.HasProcess and (Service.State <> ServiceStateFailed) then
    begin
      Service.State := ServiceStateStopped;
      Service.DeadlineAt := 0;
    end;
  end;
end;

{ True if a service that still has a process needs Service. }
function IsStillNeeded(Service: TService): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(ServiceTable) do
    if (ServiceTable[Index] <> Service) and ServiceTable[Index].HasProcess and Needs(ServiceTable[Index], Service) then
      Exit(True);
  Result := False;
end;

procedure StopServicesInOrder;
var
  Index: LongInt;
  Service: TService;
begin
  for Index := 0 to High(ServiceTable) do
  begin
    Service := ServiceTable[Index];
    if Service.HasProcess and (Service.State <> ServiceStateStopping) and not IsStillNeeded(Service) then
      StopService(Service, 'shutting down', StopReason);
  end;
end;

function EveryServiceStopped: Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(ServiceTable) do
    if ServiceTable[Index].HasProcess then
      Exit(False);
  Result := True;
end;

end.
