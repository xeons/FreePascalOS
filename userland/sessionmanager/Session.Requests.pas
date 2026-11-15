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
  The session manager's port, "session" (Windowing.Sessions has the
  protocol): the desktop asks it to log off, shut down or restart.

  Only the user of the session (or root) is listened to: the kernel says
  who holds the other end of each connection. The answer goes before
  the request is carried out, since logging off ends the program that
  asked. Shutting down is the kernel's (CallShutdown): it tells the
  service manager, which stops the services in order, this one among
  them.
}
unit Session.Requests;

{$mode objfpc}
{$H+}

interface

uses
  Session.UserSession;

{ Creates the port; False if it cannot be made. }
function OpenSessionPort(Session: TUserSession): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Objects,
  Windowing.HandleWatches,
  Windowing.Sessions,
  Session.Report;

type
  TRequestServer = class
  private
    FPort: Int64;
    FSession: TUserSession;
    procedure ConnectionWaiting(Handle: Int64);
    procedure RequestArrived(Handle: Int64);
    function Permitted(const Peer: TAbiChannelPeer): Boolean;
    procedure CarryOut(Code: LongWord);
  end;

var
  Server: TRequestServer;

function OpenSessionPort(Session: TUserSession): Boolean;
var
  Port: Int64;
begin
  Port := CreatePort(SessionPortName);
  if Port < 0 then
    Exit(False);
  Server := TRequestServer.Create;
  Server.FPort := Port;
  Server.FSession := Session;
  WatchHandle(Port, @Server.ConnectionWaiting);
  Result := True;
end;

procedure TRequestServer.ConnectionWaiting(Handle: Int64);
var
  Channel: Int64;
begin
  repeat
    Channel := AcceptConnection(FPort);
    if Channel >= 0 then
      if not WatchHandle(Channel, @RequestArrived) then
        CloseHandle(Channel);
  until Channel < 0;
end;

function TRequestServer.Permitted(const Peer: TAbiChannelPeer): Boolean;
begin
  Result := (Peer.UserId = 0) or (FSession.IsActive and (Peer.UserId = FSession.UserId));
end;

procedure TRequestServer.CarryOut(Code: LongWord);
begin
  case Code of
    SessionRequestLogOff: FSession.LogOff;
    SessionRequestPowerOff:
      begin
        Say('shutting down');
        KernelShutdown(ShutdownPowerOff);
      end;
    SessionRequestReboot:
      begin
        Say('restarting');
        KernelShutdown(ShutdownReboot);
      end;
  end;
end;

procedure TRequestServer.RequestArrived(Handle: Int64);
var
  Request: TSessionRequest;
  Reply: TSessionReply;
  Peer: TAbiChannelPeer;
  Length: QWord;
  NoHandles: array[0..0] of Int64;
  HandleCount: QWord;
  Error: LongInt;
begin
  Error := ReceiveMessage(Handle, @Request, SizeOf(Request), Length, NoHandles, HandleCount);
  if Error = ErrorWouldBlock then
    Exit;
  if (Error <> ErrorNone) or (Length < SizeOf(Request)) or (GetChannelPeer(Handle, Peer) <> ErrorNone) then
  begin
    StopWatchingHandle(Handle);
    CloseHandle(Handle);
    Exit;
  end;
  Reply.Reserved := 0;
  if not Permitted(Peer) then
    Reply.Error := ErrorNotPermitted
  else if (Request.Code < SessionRequestLogOff) or (Request.Code > SessionRequestReboot) then
    Reply.Error := ErrorInvalidArgument
  else
    Reply.Error := ErrorNone;
  SendMessage(Handle, @Reply, SizeOf(Reply), []);
  if Reply.Error = ErrorNone then
    CarryOut(Request.Code);
end;

end.
