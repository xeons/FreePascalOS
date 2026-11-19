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
  The listening server: makes the host keys that are missing, listens on
  the configured port (IPv4, and IPv6 when the network has it), tells
  the service manager it is ready, and hands each connection to a new
  process of its own (this program again, with --connection and the
  socket as its standard input), so a connection that fails takes
  nothing else with it. At most 32 connections are served at once.
}
unit Sshd.Listener;

{$mode objfpc}{$H+}

interface

uses
  Sshd.Configuration;

function RunListener(const Configuration: TSshdConfiguration; const ConfigurationPath: string): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.AddressText,
  Sys.Errors,
  Sys.InternetAddresses,
  Sys.Objects,
  Sys.Processes,
  Sys.ServiceControl,
  Sys.Sockets,
  Util.Commands,
  Ssh.HostKeys,
  Sshd.HostKeyStore,
  Sshd.Log;

const
  ListenBacklog = 16;
  MaximumConnections = 32;
  DefaultProgramPath = '/bin/sshd';

var
  Listeners: array of Int64;
  Connections: array of Int64;

{ KeepAlive: the connections it accepts take the keep-alive option
  (OpenSSH's TCPKeepAlive, on by default: a peer that vanished is
  noticed after about two hours and a quarter). }
function OpenListener(constref Address: TInternetAddress; Port: Word; KeepAlive: Boolean): Int64;
var
  Family: LongWord;
  Error: LongInt;
begin
  if Address.Family = AddressFamilyIPv6 then
    Family := AddressFamilyIPv6
  else
    Family := AddressFamilyIPv4;
  Result := CreateSocket(Family, SocketKindStream, ProtocolDefault);
  if Result < 0 then
    Exit;
  SetSocketOption(Result, SocketOptionReuseAddress, 1);
  SetSocketOption(Result, SocketOptionKeepAlive, Ord(KeepAlive));
  Error := BindSocket(Result, MakeSocketAddress(Address, Port));
  if Error = ErrorNone then
    Error := ListenOnSocket(Result, ListenBacklog);
  if Error <> ErrorNone then
  begin
    CloseSocket(Result);
    Result := -Error;
  end;
end;

procedure AddListener(constref Address: TInternetAddress; Port: Word; Required, KeepAlive: Boolean);
var
  Socket: Int64;
begin
  Socket := OpenListener(Address, Port, KeepAlive);
  if Socket < 0 then
  begin
    if Required then
      LogLine(Format('cannot listen on %s port %d: %s', [AddressToText(Address), Port,
        ErrorMessage(LongInt(-Socket))]));
    Exit;
  end;
  LogLine(Format('listening on %s port %d', [AddressToText(Address), Port]));
  SetLength(Listeners, Length(Listeners) + 1);
  Listeners[High(Listeners)] := Socket;
end;

function ProgramPath: string;
begin
  Result := ParamStr(0);
  if (Result = '') or (Result[1] <> '/') then
    Result := DefaultProgramPath;
end;

procedure StartConnection(Socket: Int64; const ConfigurationPath: string);
var
  Arguments: TTextVector;
  Options: TProcessOptions;
  Process: Int64;
  Path: string;
begin
  Path := ProgramPath;
  Arguments := TextVector([Path, '--connection', '-f', ConfigurationPath]);
  DefaultProcessOptions(Options);
  Options.InputHandle := Socket;
  Process := StartProgram(PChar(Path), @Arguments[0], Options);
  if Process < 0 then
  begin
    LogLine('cannot start a connection process: ' + ErrorMessage(LongInt(-Process)));
    Exit;
  end;
  SetLength(Connections, Length(Connections) + 1);
  Connections[High(Connections)] := Process;
end;

procedure AcceptConnection(Listener: Int64; const ConfigurationPath: string);
var
  Socket: Int64;
  Peer: TAbiSocketAddress;
begin
  Socket := AcceptOnSocket(Listener, Peer);
  if Socket < 0 then
    Exit;
  if Length(Connections) >= MaximumConnections then
    LogLine('too many connections: ' + SocketHostToText(Peer) + ' refused')
  else
    StartConnection(Socket, ConfigurationPath);
  { The connection's process has its own handle to it. }
  CloseSocket(Socket);
end;

procedure ConnectionEnded(Index: Integer);
var
  ExitCode: LongInt;
begin
  WaitForProgramWithTimeout(Connections[Index], 0, ExitCode);
  CloseHandle(Connections[Index]);
  while Index < High(Connections) do
  begin
    Connections[Index] := Connections[Index + 1];
    Inc(Index);
  end;
  SetLength(Connections, Length(Connections) - 1);
end;

function RunListener(const Configuration: TSshdConfiguration; const ConfigurationPath: string): LongInt;
var
  HostKeys: THostKeyArray;
  Index: Integer;
  Handles: array of Int64;
  Ready: Int64;
begin
  HostKeys := LoadOrCreateHostKeys(Configuration.HostKeyPaths, True);
  if Length(HostKeys) = 0 then
  begin
    LogLine('no host keys: not starting');
    Exit(1);
  end;
  for Index := 0 to High(HostKeys) do
    HostKeys[Index].Free;

  AddListener(AnyIpv4Address, Configuration.Port, True, Configuration.TcpKeepAlive);
  AddListener(AnyIpv6Address, Configuration.Port, False, Configuration.TcpKeepAlive);
  if Length(Listeners) = 0 then
    Exit(1);
  NotifyServiceReady;
  LogLine('ready');

  repeat
    Handles := Copy(Listeners);
    for Index := 0 to High(Connections) do
      if Length(Handles) < MaximumWaitHandles then
      begin
        SetLength(Handles, Length(Handles) + 1);
        Handles[High(Handles)] := Connections[Index];
      end;
    Ready := WaitForHandles(Handles, InfiniteWait);
    if Ready < 0 then
    begin
      SleepMilliseconds(100);
      Continue;
    end;
    if Ready < Length(Listeners) then
      AcceptConnection(Listeners[Ready], ConfigurationPath)
    else
      ConnectionEnded(Integer(Ready) - Length(Listeners));
  until False;
end;

end.
