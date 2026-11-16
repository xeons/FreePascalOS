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
  The service's port, "systemsettings": connections are accepted as
  they come, and each request on a connection is checked
  (SystemSettings.Authorization), carried out (SystemSettings.Requests)
  and answered, one at a time, in one loop that waits on the port and
  every connection at once. A connection whose other end went away is
  closed.
}
unit SystemSettings.Server;

{$mode objfpc}
{$H+}

interface

{ Creates the port; False if it cannot be made (another service holds
  the name). }
function OpenSettingsPort: Boolean;
{ Serves requests; never returns. }
procedure ServeRequests;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Objects,
  Sys.SystemSettings,
  Util.Accounts,
  SystemSettings.Authorization,
  SystemSettings.Requests,
  SystemSettings.Report;

const
  { The port takes one place in the wait. }
  MaximumConnections = MaximumWaitHandles - 1;

var
  Port: Int64 = -1;
  Connections: array of Int64;

function OpenSettingsPort: Boolean;
begin
  Port := CreatePort(SystemSettingsPortName);
  Result := Port >= 0;
end;

procedure AcceptWaitingConnections;
var
  Channel: Int64;
begin
  repeat
    Channel := AcceptConnection(Port);
    if Channel < 0 then
      Exit;
    if Length(Connections) >= MaximumConnections then
      CloseHandle(Channel)
    else
    begin
      SetLength(Connections, Length(Connections) + 1);
      Connections[High(Connections)] := Channel;
    end;
  until False;
end;

procedure DropConnection(Index: Integer);
var
  Position: Integer;
begin
  CloseHandle(Connections[Index]);
  for Position := Index to High(Connections) - 1 do
    Connections[Position] := Connections[Position + 1];
  SetLength(Connections, Length(Connections) - 1);
end;

{ The texts end within their fields whatever the caller sent. }
procedure TerminateTexts(var Request: TSystemSettingsRequest);
begin
  Request.Authorization[High(Request.Authorization)] := #0;
  Request.UserName[High(Request.UserName)] := #0;
  Request.FullName[High(Request.FullName)] := #0;
  Request.Password[High(Request.Password)] := #0;
  Request.Text[High(Request.Text)] := #0;
end;

function CallerName(const Peer: TAbiChannelPeer): string;
begin
  Result := UserNameOrNumber(Peer.UserId);
end;

{ Serves the request waiting on connection Index; False if the
  connection is over. }
function ServeConnection(Index: Integer): Boolean;
var
  Request: TSystemSettingsRequest;
  Reply: TSystemSettingsReply;
  Peer: TAbiChannelPeer;
  Length: QWord;
  NoHandles: array[0..0] of Int64;
  HandleCount: QWord;
  Error: LongInt;
begin
  Error := ReceiveMessage(Connections[Index], @Request, SizeOf(Request), Length, NoHandles, HandleCount);
  if Error = ErrorWouldBlock then
    Exit(True);
  if (Error <> ErrorNone) or (Length < SizeOf(Request)) or (GetChannelPeer(Connections[Index], Peer) <> ErrorNone) then
    Exit(False);
  TerminateTexts(Request);
  Reply.Reserved := 0;
  Reply.Error := AuthorizeRequest(Peer, Request);
  if Reply.Error = ErrorNone then
    Reply.Error := CarryOutRequest(Peer, Request)
  else
    Say(Format('request %d of %s refused: wrong password', [Request.Code, CallerName(Peer)]));
  if Reply.Error <> ErrorNone then
    Say(Format('request %d of %s: %s', [Request.Code, CallerName(Peer), ErrorMessage(Reply.Error)]));
  FillChar(Request, SizeOf(Request), 0);
  SendMessage(Connections[Index], @Reply, SizeOf(Reply), []);
  Result := True;
end;

procedure ServeRequests;
var
  Handles: array of Int64;
  Index: Integer;
  Ready: Int64;
begin
  repeat
    SetLength(Handles, Length(Connections) + 1);
    Handles[0] := Port;
    for Index := 0 to High(Connections) do
      Handles[Index + 1] := Connections[Index];
    Ready := WaitForHandles(Handles, InfiniteWait);
    if Ready = 0 then
      AcceptWaitingConnections
    else if (Ready > 0) and (Ready <= Length(Connections)) then
    begin
      if not ServeConnection(Integer(Ready) - 1) then
        DropConnection(Integer(Ready) - 1);
    end;
  until False;
end;

end.
