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
  Starting the network layer, in two steps.

  InitializeNetworking sets up the lock, the receive queue, the socket
  object type, the TCP table and the loopback interface. It runs the
  first time it is needed: when the first driver registers an adapter
  (Io.NetworkAdapters), or from StartNetworking on a machine without
  one; it does nothing the second time.

  StartNetworking (Kernel.Startup, once the drivers are up) starts the
  network thread, which handles what arrived meanwhile.
}
unit Network.Startup;

{$mode objfpc}

interface

procedure InitializeNetworking;
procedure StartNetworking;

implementation

uses
  Kernel.Threads,
  Kernel.Panic,
  Processes.Thread,
  Network.Core,
  Network.Interfaces,
  Network.Sockets,
  Network.TcpConnections,
  Network.Loopback,
  Network.Thread,
  Debug.Output;

const
  NetworkThreadPriority = DefaultThreadPriority + 5;

var
  IsInitialized: Boolean;
  IsStarted: Boolean;

procedure InitializeNetworking;
begin
  if IsInitialized then
    Exit;
  IsInitialized := True;
  InitializeNetworkCore;
  InitializeSockets;
  InitializeTcpConnections;
  LockNetwork;
  CreateLoopbackInterface;
  UnlockNetwork;
end;

procedure StartNetworking;
begin
  InitializeNetworking;
  if IsStarted then
    Exit;
  IsStarted := True;
  if CreateSystemThread(@RunNetworkThread, nil, NetworkThreadPriority, 'Network', False) = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the network thread', 0, 0, 0, 0);
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite('started with ');
  DebugWriteDecimal(NetworkInterfaceCount);
  DebugWriteLine(' interfaces (lo and the adapters)');
  DebugEndMessage;
end;

end.
