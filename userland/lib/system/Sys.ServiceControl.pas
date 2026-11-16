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
  Talking to the service manager (userland/servicemanager), the first
  program, which starts the system's services and keeps them running.

  It serves the port "servicemanager". A request (TServiceRequest) names
  what to do and, for most, a service; the reply (TServiceReply) has an
  error code and the status of the services asked about (every one for
  a list). Anyone may list and ask for a status; starting, stopping and
  restarting are for root (the manager asks the kernel who connected).

  A service tells the manager it is ready (NotifyServiceReady) once it
  can do its work (the display server, once its port takes clients), so
  the services that need it start only then. The manager gives every
  service the variables SERVICE_NAME and SERVICE_PORT (its port's name);
  outside the manager there is nobody to tell, and NotifyServiceReady
  does nothing.
}
unit Sys.ServiceControl;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

const
  ServiceManagerPortName = 'servicemanager';
  ServicePortVariable = 'SERVICE_PORT';
  ServiceNameVariable = 'SERVICE_NAME';
  ServiceNameCapacity = 48;
  ServiceTextCapacity = 72;
  MaximumServicesInReply = 48;

  { TServiceRequest.Code }
  ServiceRequestList = 1;
  ServiceRequestStatus = 2;
  ServiceRequestStart = 3;
  ServiceRequestStop = 4;
  ServiceRequestRestart = 5;
  { From a service's own process (or one it started): it is ready. }
  ServiceRequestReady = 6;

  { TServiceStatus.State }
  ServiceStateStopped = 0;
  { Wanted, but something it needs is not running yet. }
  ServiceStateWaiting = 1;
  { Started; not ready yet. }
  ServiceStateStarting = 2;
  ServiceStateRunning = 3;
  ServiceStateStopping = 4;
  { Ended; started again after its pause. }
  ServiceStateRestarting = 5;
  { Ended too often, or could not start; left alone until started. }
  ServiceStateFailed = 6;

type
  TServiceRequest = record
    Code: LongWord;
    Reserved: LongWord;
    Name: array[0..ServiceNameCapacity - 1] of Char;
  end;

  TServiceStatus = record
    Name: array[0..ServiceNameCapacity - 1] of Char;
    Description: array[0..ServiceTextCapacity - 1] of Char;
    State: LongWord;
    { Started for the boot mode (not only by hand). }
    InBootMode: LongWord;
    { The running process (0 for none). }
    ProcessId: QWord;
    { Times it was started again after ending. }
    Restarts: LongWord;
    { How it last ended, when HasEnded is not 0. }
    LastExitCode: LongInt;
    HasEnded: LongWord;
    Reserved: LongWord;
    { Uptime in milliseconds when it last started and became ready (0:
      not yet). }
    StartedAt: QWord;
    ReadyAt: QWord;
    { Why it waits or failed, or what it last did. }
    Reason: array[0..ServiceTextCapacity - 1] of Char;
  end;
  PServiceStatus = ^TServiceStatus;

  TServiceReply = record
    Error: LongInt;
    Count: LongWord;
    Services: array[0..MaximumServicesInReply - 1] of TServiceStatus;
  end;

const
  ServiceReplyHeaderSize = 8;

{ Sends Code (and the service Name, which may be '') to the manager at
  the port PortName ('': the system's) and waits for the reply. Returns
  an error when the manager cannot be reached; else Reply.Error is the
  manager's answer. }
function AskServiceManager(const PortName: string; Code: LongWord; const Name: string;
  out Reply: TServiceReply): LongInt;

{ Tells the manager that started this program (or the program that
  started this one) that its service is ready. Does nothing when no
  manager started it. }
procedure NotifyServiceReady;

{ "running", "failed", ... }
function ServiceStateName(State: LongWord): string;

implementation

uses
  SysUtils,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Objects;

const
  ReplyTimeoutMilliseconds = 10000;

function AskServiceManager(const PortName: string; Code: LongWord; const Name: string;
  out Reply: TServiceReply): LongInt;
var
  Request: TServiceRequest;
  Channel: Int64;
  ReplyLength: QWord;
begin
  FillMemory(@Reply, ServiceReplyHeaderSize, 0);
  Reply.Count := 0;
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Code := Code;
  StrPLCopy(@Request.Name[0], Name, ServiceNameCapacity - 1);
  if PortName = '' then
    Channel := ConnectPort(ServiceManagerPortName)
  else
    Channel := ConnectPort(PChar(PortName));
  if Channel < 0 then
    Exit(ErrorCodeOf(Channel));
  Result := CallChannel(Channel, @Request, SizeOf(Request), @Reply, SizeOf(Reply), ReplyLength,
    ReplyTimeoutMilliseconds);
  CloseHandle(Channel);
  if (Result = ErrorNone) and (ReplyLength < ServiceReplyHeaderSize) then
    Result := ErrorIo;
end;

procedure NotifyServiceReady;
var
  PortName: string;
  Reply: TServiceReply;
begin
  PortName := GetVariable(ServicePortVariable);
  if PortName = '' then
    Exit;
  AskServiceManager(PortName, ServiceRequestReady, GetVariable(ServiceNameVariable), Reply);
end;

function ServiceStateName(State: LongWord): string;
begin
  case State of
    ServiceStateStopped: Result := 'stopped';
    ServiceStateWaiting: Result := 'waiting';
    ServiceStateStarting: Result := 'starting';
    ServiceStateRunning: Result := 'running';
    ServiceStateStopping: Result := 'stopping';
    ServiceStateRestarting: Result := 'restarting';
    ServiceStateFailed: Result := 'failed';
  else
    Result := 'unknown';
  end;
end;

end.
