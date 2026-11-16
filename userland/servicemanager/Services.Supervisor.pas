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
  Keeping the services running.

  A wanted service starts as soon as every service it needs is running
  and ready (until then it is "waiting"). Once started it is "starting"
  until it is ready - at once, or when it says so (ready = notify) - and
  then "running". A service not ready within its ready-timeout is ended,
  which counts as a failure.

  When a service's program ends, whatever else it started (its session)
  is ended too, and its restart policy decides: never, on failure (an
  exit status other than 0), or always. A restart waits restart-delay
  first ("restarting"); after restart-limit restarts in a row the service
  is left "failed" (a run of half a minute or more starts the count
  again; 0 means no limit). A service ended on purpose (stopped, or at
  shutdown) is "stopped".

  Stopping a service ("stopping") asks every program of its session to
  end (Sys.Notifications: the reason is a service stop, or the
  shutdown), so a program that takes the request can tidy up first;
  one that does not is ended at once by the kernel. A service whose
  program is still running after its stop-timeout is ended outright,
  with its whole session; and whenever the service's program ends,
  whatever is left of its session goes with it.
}
unit Services.Supervisor;

{$mode objfpc}
{$H+}

interface

uses
  Services.Catalog;

{ Wants Service running (and everything it needs). By hand, its count of
  restarts starts again. }
procedure WantService(Service: TService);
{ Starts every wanted service that is not running and whose needs are
  ready; notes why the others wait. }
procedure StartWaitingServices;
{ The service's program has ended (its process handle is signaled). }
procedure ServiceProcessEnded(Service: TService);
{ Ends the service on purpose (Why says why, in the log): asks its
  programs to end for Reason (EndReason*), and ends them outright once
  the stop-timeout has passed. }
procedure StopService(Service: TService; const Why: string; Reason: LongWord);
{ Stops it and starts it again once it has ended. }
procedure RestartService(Service: TService);
{ It (or a program it started) says it is ready. }
procedure ServiceIsReady(Service: TService);
{ Acts on restarts that are due, waits for readiness that ran out and
  stops that took too long. }
procedure HandleDeadlines;
{ Milliseconds until the next deadline, or -1 for none. }
function MillisecondsToNextDeadline: Int64;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Notifications,
  Sys.Objects,
  Sys.Processes,
  Sys.ServiceControl,
  Sys.Time,
  Services.Definitions,
  Services.Launch,
  Services.Logs;

const
  { A run this long shows the service works: its restarts in a row are
    forgotten. }
  LongRunMilliseconds = 30000;
  { The exit status of an ended program (128 + SIGTERM's number). }
  StoppedExitCode = 143;

procedure WantService(Service: TService);
var
  Index: LongInt;
  Needed: TService;
begin
  if Service.Problem <> '' then
    Exit;
  Service.Wanted := True;
  Service.StartWhenStopped := False;
  Service.RestartsInARow := 0;
  if Service.State = ServiceStateFailed then
    Service.State := ServiceStateStopped;
  for Index := 0 to High(Service.Definition.Needs) do
  begin
    Needed := FindService(Service.Definition.Needs[Index]);
    if (Needed <> nil) and not Needed.Wanted then
      WantService(Needed);
  end;
end;

{ The first need of Service that is not running and ready; nil if none. }
function FirstUnreadyNeed(Service: TService): TService;
var
  Index: LongInt;
  Needed: TService;
begin
  for Index := 0 to High(Service.Definition.Needs) do
  begin
    Needed := FindService(Service.Definition.Needs[Index]);
    if (Needed = nil) or (Needed.State <> ServiceStateRunning) then
      Exit(Needed);
  end;
  Result := nil;
end;

procedure BecomeReady(Service: TService);
begin
  Service.State := ServiceStateRunning;
  Service.ReadyAt := UptimeMilliseconds;
  Service.DeadlineAt := 0;
  Service.Reason := '';
end;

procedure StartService(Service: TService);
var
  Error: LongInt;
begin
  Error := LaunchService(Service);
  if Error <> ErrorNone then
  begin
    Service.State := ServiceStateFailed;
    Service.Wanted := False;
    Say(Service.Definition.Name + ' failed: ' + Service.Reason);
    Exit;
  end;
  Service.StartedAt := UptimeMilliseconds;
  Service.ReadyAt := 0;
  Service.Reason := '';
  Say('started ' + Service.Definition.Name + ' (process ' + IntToStr(Service.ProcessId) + ')');
  if Service.Definition.Readiness = ReadyWhenStarted then
    BecomeReady(Service)
  else
  begin
    Service.State := ServiceStateStarting;
    Service.DeadlineAt := Service.StartedAt + QWord(Service.Definition.ReadyTimeoutMilliseconds);
  end;
end;

procedure StartWaitingServices;
var
  Index: LongInt;
  Service: TService;
  Missing: TService;
begin
  for Index := 0 to High(ServiceTable) do
  begin
    Service := ServiceTable[Index];
    if not Service.Wanted or Service.HasProcess then
      Continue;
    if (Service.State <> ServiceStateStopped) and (Service.State <> ServiceStateWaiting) then
      Continue;
    Missing := FirstUnreadyNeed(Service);
    if Missing <> nil then
    begin
      Service.State := ServiceStateWaiting;
      Service.Reason := 'waiting for ' + Missing.Definition.Name;
    end
    else
      StartService(Service);
  end;
end;

procedure CloseProcess(Service: TService);
begin
  CloseHandle(Service.ProcessHandle);
  Service.ProcessHandle := NoHandle;
  if Service.LogHandle <> NoHandle then
    CloseFile(Service.LogHandle);
  Service.LogHandle := NoHandle;
end;

{ What the restart policy says about an end with ExitCode. }
function PolicyRestarts(Service: TService; ExitCode: LongInt): Boolean;
begin
  case Service.Definition.Restart of
    RestartAlways: Result := True;
    RestartOnFailure: Result := ExitCode <> 0;
  else
    Result := False;
  end;
end;

procedure DecideAfterEnd(Service: TService; ExitCode: LongInt);
var
  Ended: string;
begin
  Ended := 'ended with status ' + IntToStr(ExitCode);
  if UptimeMilliseconds - Service.StartedAt >= LongRunMilliseconds then
    Service.RestartsInARow := 0;
  if not PolicyRestarts(Service, ExitCode) then
  begin
    Service.Wanted := False;
    if ExitCode = 0 then
      Service.State := ServiceStateStopped
    else
      Service.State := ServiceStateFailed;
    Service.Reason := Ended;
    Say(Service.Definition.Name + ' ' + Ended);
  end
  else if (Service.Definition.RestartLimit > 0) and (Service.RestartsInARow >= Service.Definition.RestartLimit) then
  begin
    Service.Wanted := False;
    Service.State := ServiceStateFailed;
    Service.Reason := Ended + '; gave up after ' + IntToStr(Service.RestartsInARow) + ' restarts';
    Say(Service.Definition.Name + ' ' + Service.Reason);
  end
  else
  begin
    Inc(Service.RestartsInARow);
    Inc(Service.TotalRestarts);
    Service.State := ServiceStateRestarting;
    Service.DeadlineAt := UptimeMilliseconds + QWord(Service.Definition.RestartDelayMilliseconds);
    Service.Reason := Ended + '; starting again';
    Say(Service.Definition.Name + ' ' + Service.Reason);
  end;
end;

procedure ServiceProcessEnded(Service: TService);
var
  ExitCode: LongInt;
  WasStopping: Boolean;
begin
  if WaitForProgramWithTimeout(Service.ProcessHandle, 0, ExitCode) <> ErrorNone then
    ExitCode := -1;
  { Whatever it started goes with it. }
  EndSession(Service.ProcessId, StoppedExitCode);
  CloseProcess(Service);
  Service.ProcessId := 0;
  Service.LastExitCode := ExitCode;
  Service.HasEnded := True;
  Service.DeadlineAt := 0;
  WasStopping := Service.State = ServiceStateStopping;
  if WasStopping or not Service.Wanted then
  begin
    Service.State := ServiceStateStopped;
    Say('stopped ' + Service.Definition.Name);
    if Service.StartWhenStopped then
      WantService(Service);
  end
  else
    DecideAfterEnd(Service, ExitCode);
end;

procedure EndProcess(Service: TService);
begin
  EndSession(Service.ProcessId, StoppedExitCode);
  TerminateProgram(Service.ProcessId, StoppedExitCode);
end;

procedure StopService(Service: TService; const Why: string; Reason: LongWord);
begin
  Service.Wanted := False;
  Service.StartWhenStopped := False;
  Service.DeadlineAt := 0;
  if not Service.HasProcess then
  begin
    if Service.State <> ServiceStateFailed then
      Service.State := ServiceStateStopped;
    Exit;
  end;
  if Service.State = ServiceStateStopping then
    Exit;
  Service.State := ServiceStateStopping;
  Service.Reason := Why;
  Say('stopping ' + Service.Definition.Name + ' (' + Why + ')');
  { Its session's id is the id of its program, which leads it. }
  AskSessionToEnd(Service.ProcessId, Reason);
  Service.DeadlineAt := UptimeMilliseconds + QWord(Service.Definition.StopTimeoutMilliseconds);
end;

procedure RestartService(Service: TService);
begin
  if not Service.HasProcess then
  begin
    WantService(Service);
    Exit;
  end;
  StopService(Service, 'restarting', EndReasonServiceStop);
  Service.StartWhenStopped := True;
end;

procedure ServiceIsReady(Service: TService);
begin
  if Service.State <> ServiceStateStarting then
    Exit;
  BecomeReady(Service);
  Say(Service.Definition.Name + ' is ready after ' + IntToStr(Service.ReadyAt - Service.StartedAt) + ' ms');
end;

procedure HandleDeadlines;
var
  Index: LongInt;
  Service: TService;
  Now: QWord;
begin
  Now := UptimeMilliseconds;
  for Index := 0 to High(ServiceTable) do
  begin
    Service := ServiceTable[Index];
    if (Service.DeadlineAt = 0) or (Service.DeadlineAt > Now) then
      Continue;
    Service.DeadlineAt := 0;
    if Service.State = ServiceStateRestarting then
      Service.State := ServiceStateStopped
    else if (Service.State = ServiceStateStarting) and Service.HasProcess then
    begin
      { Its end comes as a failure, and the policy decides. }
      Service.Reason := 'not ready in time';
      Say(Service.Definition.Name + ' was not ready in time');
      EndProcess(Service);
    end
    else if (Service.State = ServiceStateStopping) and Service.HasProcess then
    begin
      Say(Service.Definition.Name + ' did not stop in time: ending it');
      EndProcess(Service);
    end;
  end;
end;

function MillisecondsToNextDeadline: Int64;
var
  Index: LongInt;
  Now: QWord;
  Earliest: QWord;
begin
  Earliest := 0;
  for Index := 0 to High(ServiceTable) do
    if (ServiceTable[Index].DeadlineAt <> 0) and ((Earliest = 0) or (ServiceTable[Index].DeadlineAt < Earliest)) then
      Earliest := ServiceTable[Index].DeadlineAt;
  if Earliest = 0 then
    Exit(-1);
  Now := UptimeMilliseconds;
  if Earliest <= Now then
    Exit(0);
  Result := Int64(Earliest - Now);
end;

end.
