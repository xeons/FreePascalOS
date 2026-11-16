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
  The manager's port: requests from `service` and from services
  (Sys.ServiceControl has the protocol).

  Up to MaximumClients connections are served at a time (more wait at
  the port). Listing and status are for anyone; starting, stopping and
  restarting for root - the kernel says who holds the other end of each
  connection (CallGetChannelPeer). Readiness is taken only from a
  process of the service's own session (its program, or one it
  started), so no other program can make a service look ready.
}
unit Services.Control;

{$mode objfpc}
{$H+}

interface

const
  MaximumClients = 8;

var
  ControlPort: Int64;
  Clients: array[0..MaximumClients - 1] of Int64;
  ClientCount: LongInt;

{ Creates the port named Name; an error code. }
function OpenControlPort(const Name: string): LongInt;
{ Takes the connections waiting at the port. }
procedure AcceptClients;
{ Serves what the client at Position sent (or drops it once gone). }
procedure ServeClient(Position: LongInt);

implementation

uses
  SysUtils,
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Objects,
  Sys.Processes,
  Sys.ServiceControl,
  Services.Catalog,
  Services.Supervisor,
  Services.Shutdown;

function OpenControlPort(const Name: string): LongInt;
begin
  ClientCount := 0;
  ControlPort := CreatePort(PChar(Name));
  if ControlPort < 0 then
  begin
    Result := ErrorCodeOf(ControlPort);
    ControlPort := NoHandle;
  end
  else
    Result := ErrorNone;
end;

procedure AcceptClients;
var
  Channel: Int64;
begin
  repeat
    Channel := AcceptConnection(ControlPort);
    if Channel < 0 then
      Exit;
    if ClientCount >= MaximumClients then
      CloseHandle(Channel)
    else
    begin
      Clients[ClientCount] := Channel;
      Inc(ClientCount);
    end;
  until False;
end;

procedure DropClient(Position: LongInt);
var
  Index: LongInt;
begin
  CloseHandle(Clients[Position]);
  for Index := Position to ClientCount - 2 do
    Clients[Index] := Clients[Index + 1];
  Dec(ClientCount);
end;

procedure DescribeService(Service: TService; out Status: TServiceStatus);
begin
  FillMemory(@Status, SizeOf(Status), 0);
  CopyText(@Status.Name[0], PChar(Service.Definition.Name), ServiceNameCapacity);
  CopyText(@Status.Description[0], PChar(Service.Definition.Description), ServiceTextCapacity);
  Status.State := Service.State;
  Status.InBootMode := Ord(Service.InBootMode);
  Status.ProcessId := Service.ProcessId;
  Status.Restarts := LongWord(Service.TotalRestarts);
  Status.LastExitCode := Service.LastExitCode;
  Status.HasEnded := Ord(Service.HasEnded);
  Status.StartedAt := Service.StartedAt;
  Status.ReadyAt := Service.ReadyAt;
  if Service.Problem <> '' then
    CopyText(@Status.Reason[0], PChar(Service.Problem), ServiceTextCapacity)
  else
    CopyText(@Status.Reason[0], PChar(Service.Reason), ServiceTextCapacity);
end;

procedure ListServices(var Reply: TServiceReply);
var
  Index: LongInt;
begin
  Reply.Count := 0;
  for Index := 0 to High(ServiceTable) do
    if Reply.Count < MaximumServicesInReply then
    begin
      DescribeService(ServiceTable[Index], Reply.Services[Reply.Count]);
      Inc(Reply.Count);
    end;
end;

{ May the process at the other end tell that Service is ready? }
function IsFromServiceSession(Service: TService; const Peer: TAbiChannelPeer): Boolean;
var
  SessionId: QWord;
begin
  Result := Service.HasProcess and SessionOfProcess(Peer.ProcessId, SessionId) and
    (SessionId = Service.ProcessId);
end;

{ Carries out a request that names Service; the error code. }
function ActOnService(Service: TService; Code: LongWord; const Peer: TAbiChannelPeer): LongInt;
begin
  Result := ErrorNone;
  if Code = ServiceRequestReady then
  begin
    if not IsFromServiceSession(Service, Peer) then
      Exit(ErrorNotPermitted);
    ServiceIsReady(Service);
    Exit;
  end;
  if Peer.UserId <> 0 then
    Exit(ErrorNotPermitted);
  if ShuttingDown then
    Exit(ErrorBusy);
  if (Service.Problem <> '') and (Code <> ServiceRequestStop) then
    Exit(ErrorInvalidArgument);
  case Code of
    ServiceRequestStart: WantService(Service);
    ServiceRequestStop: StopService(Service, 'asked to', EndReasonServiceStop);
    ServiceRequestRestart: RestartService(Service);
  end;
end;

procedure Answer(const Request: TServiceRequest; const Peer: TAbiChannelPeer; var Reply: TServiceReply);
var
  Service: TService;
begin
  Reply.Error := ErrorNone;
  Reply.Count := 0;
  if Request.Code = ServiceRequestList then
  begin
    ListServices(Reply);
    Exit;
  end;
  Service := FindService(string(PChar(@Request.Name[0])));
  if Service = nil then
  begin
    Reply.Error := ErrorNotFound;
    Exit;
  end;
  case Request.Code of
    ServiceRequestStatus: ;
    ServiceRequestStart, ServiceRequestStop, ServiceRequestRestart, ServiceRequestReady:
      Reply.Error := ActOnService(Service, Request.Code, Peer);
  else
    Reply.Error := ErrorInvalidArgument;
  end;
  { The service as it is now. }
  DescribeService(Service, Reply.Services[0]);
  Reply.Count := 1;
end;

procedure ServeClient(Position: LongInt);
var
  Request: TServiceRequest;
  Reply: TServiceReply;
  Peer: TAbiChannelPeer;
  Length: QWord;
  NoHandles: array[0..0] of Int64;
  HandleCount: QWord;
  Error: LongInt;
begin
  Error := ReceiveMessage(Clients[Position], @Request, SizeOf(Request), Length, NoHandles, HandleCount);
  if Error = ErrorWouldBlock then
    Exit;
  if (Error <> ErrorNone) or (Length < SizeOf(Request)) or
     (GetChannelPeer(Clients[Position], Peer) <> ErrorNone) then
  begin
    DropClient(Position);
    Exit;
  end;
  Request.Name[ServiceNameCapacity - 1] := #0;
  Answer(Request, Peer, Reply);
  SendMessage(Clients[Position], @Reply, ServiceReplyHeaderSize + Reply.Count * SizeOf(TServiceStatus), []);
end;

end.
