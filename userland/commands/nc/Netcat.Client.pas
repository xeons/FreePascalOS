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
  nc HOST PORT...: connecting. The ports are tried in order and the
  first that takes the connection is used; with -z every port is only
  tried, and -v says how each went:

    Connection to 127.0.0.1 7000 port [tcp/*] succeeded!
    nc: connect to 127.0.0.1 port 7001 (tcp) failed: Connection refused

  A UDP "connection" always succeeds; -z -u sends a datagram and waits
  (-w, else a second) for the port unreachable that a closed port
  answers with: no answer counts as open, as with OpenBSD's nc.
}
unit Netcat.Client;

{$mode objfpc}
{$H+}

interface

{ Ports are operands as given ("80", "20-30"); returns the exit
  status: 0 if a port took the connection. }
function RunClient(const Host: string; const Ports: array of string): Integer;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.InternetAddresses,
  Sys.AddressText,
  Sys.Objects,
  Sys.Sockets,
  Util.Messages,
  Netcat.Settings,
  Netcat.Ports,
  Netcat.Sockets,
  Netcat.Relay;

const
  UdpProbeMilliseconds = 1000;

var
  HostAddressText: string;

procedure ReportConnected(Port: Word);
begin
  ReportProgress(Format('Connection to %s %u port [%s/*] succeeded!', [HostAddressText, Port, TransportName]));
end;

procedure ReportFailure(Port: Word; Error: LongInt);
begin
  if Settings.Verbose then
    ReportError(Error, Format('connect to %s port %u (%s) failed', [HostAddressText, Port, TransportName]));
end;

{ Connects Socket, within -w if it was given. }
function ConnectWithin(Socket: Int64; constref Address: TAbiSocketAddress): LongInt;
begin
  if Settings.TimeoutMilliseconds <> NoTimeLimit then
    SetSocketOption(Socket, SocketOptionSendTimeout, Settings.TimeoutMilliseconds);
  Result := ConnectSocket(Socket, Address);
  if Result = ErrorWouldBlock then
    Result := ErrorTimedOut;
  { -w also limits the time a connection is idle, not one send. }
  if Settings.TimeoutMilliseconds <> NoTimeLimit then
    SetSocketOption(Socket, SocketOptionSendTimeout, 0);
end;

{ -z -u: a closed port answers a datagram with port unreachable, which
  the socket reports as ErrorConnectionRefused. }
function ProbeUdpPort(Socket: Int64): LongInt;
var
  Probe: Byte;
  Answer: Byte;
  WaitMilliseconds: Int64;
  Sent: Int64;
  Received: Int64;
begin
  Probe := Ord('X');
  Sent := SendOnSocket(Socket, @Probe, 1, 0);
  if Sent < 0 then
    Exit(ErrorCodeOf(Sent));
  WaitMilliseconds := UdpProbeMilliseconds;
  if Settings.TimeoutMilliseconds <> NoTimeLimit then
    WaitMilliseconds := Settings.TimeoutMilliseconds;
  if WaitForHandles([Socket], WaitMilliseconds) <> 0 then
    Exit(ErrorNone);
  Received := ReceiveOnSocket(Socket, @Answer, 1, SocketFlagDontWait);
  if Received = -ErrorConnectionRefused then
    Exit(ErrorConnectionRefused);
  Result := ErrorNone;
end;

{ Tries Port; the socket stays open and connected (Socket) on success. }
function TryPort(constref Address: TInternetAddress; Port: Word; out Socket: Int64): LongInt;
var
  Local: TInternetAddress;
begin
  if Address.Family = AddressFamilyIPv6 then
    Local := AnyIpv6Address
  else
    Local := AnyIpv4Address;
  Socket := OpenSocket(Local, Settings.LocalPort);
  Result := ConnectWithin(Socket, MakeSocketAddress(Address, Port));
  if (Result = ErrorNone) and Settings.Datagrams and Settings.ScanOnly then
    Result := ProbeUdpPort(Socket);
  if Result = ErrorNone then
    Exit;
  CloseSocket(Socket);
  Socket := -1;
end;

{ Every port of every range in turn: -z tries them all, otherwise the
  first that connects is relayed. Returns the exit status. }
function RunClient(const Host: string; const Ports: array of string): Integer;
var
  Address: TInternetAddress;
  Operand: string;
  First: Word;
  Last: Word;
  Port: LongWord;
  Socket: Int64;
  Error: LongInt;
begin
  Address := ResolveHost(Host);
  HostAddressText := AddressToText(Address);
  Result := 1;
  for Operand in Ports do
  begin
    if not ParsePortRange(Operand, First, Last) then
      Fail(1, Operand + ': bad port or port range');
    { A LongWord, so that a range ending at 65535 ends. }
    Port := First;
    while Port <= Last do
    begin
      Error := TryPort(Address, Word(Port), Socket);
      if Error <> ErrorNone then
        ReportFailure(Word(Port), Error)
      else
      begin
        ReportConnected(Word(Port));
        Result := 0;
        if not Settings.ScanOnly then
        begin
          if not RelayConnection(Socket) then
            Result := 1;
          CloseSocket(Socket);
          Exit;
        end;
        CloseSocket(Socket);
      end;
      Inc(Port);
    end;
  end;
end;

end.
