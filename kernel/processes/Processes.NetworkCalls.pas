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
  System calls that list and configure the network: the interfaces,
  the routes, the ARP cache, the sockets and connections, and the DNS
  servers (CallListNetworkInterfaces to CallSetDnsServers), and watching
  them for changes (CallWatchNetworkChanges). Anyone may list and watch;
  changing is root's (ErrorNotPermitted), as for the clock. Every change
  made signals the watchers (Network.ChangeWatchers).

  A listing is made in a kernel buffer under the network lock and then
  copied out, so the program sees one consistent moment.
}
unit Processes.NetworkCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformListNetworkInterfaces(BufferAddress, Capacity: QWord): Int64;
function PerformConfigureNetworkInterface(ConfigurationAddress: QWord): Int64;
function PerformChangeRoute(Operation, RouteAddress: QWord): Int64;
function PerformListRoutes(BufferAddress, Capacity: QWord): Int64;
function PerformListArpEntries(BufferAddress, Capacity: QWord): Int64;
function PerformListSockets(BufferAddress, Capacity: QWord): Int64;
function PerformGetDnsServers(ServersAddress: QWord): Int64;
function PerformSetDnsServers(ServersAddress: QWord): Int64;
function PerformWatchNetworkChanges: Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Memory.KernelHeap,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Handles,
  Kernel.Mutex,
  Objects.Events,
  Objects.Manager,
  Network.Core,
  Network.ChangeWatchers,
  Network.Addresses,
  Network.Interfaces,
  Network.InterfaceConfiguration,
  Network.Routing,
  Network.Arp,
  Network.SocketListing,
  Network.Dns;

const
  { The most records one listing call returns. }
  MaximumListedRecords = 256;

type
  TListKind = (ListInterfaces, ListRoutes, ListArpEntries, ListSocketEntries);

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerIsRoot: Boolean;
begin
  Result := CurrentProcess^.Credentials.EffectiveUserId = RootUserId;
end;

function RecordSize(Kind: TListKind): QWord;
begin
  case Kind of
    ListInterfaces: Result := SizeOf(TAbiNetworkInterface);
    ListRoutes: Result := SizeOf(TAbiRoute);
    ListArpEntries: Result := SizeOf(TAbiArpEntry);
  else
    Result := SizeOf(TAbiSocketInformation);
  end;
end;

{ Fills Records (room for Capacity) under the lock; returns how many
  there are. }
function FillRecords(Kind: TListKind; Records: PByte; Capacity: LongWord): LongWord;
var
  Position: LongWord;
begin
  LockNetwork;
  case Kind of
    ListInterfaces:
      begin
        Result := NetworkInterfaceCount;
        Position := 0;
        while (Position < Result) and (Position < Capacity) do
        begin
          DescribeInterface(NetworkInterfaceAt(Position), PAbiNetworkInterface(Records)[Position]);
          Inc(Position);
        end;
      end;
    ListRoutes:
      begin
        Result := RouteCount;
        Position := 0;
        while (Position < Result) and (Position < Capacity) do
        begin
          DescribeRoute(Position, PAbiRoute(Records)[Position]);
          Inc(Position);
        end;
      end;
    ListArpEntries:
      begin
        Result := ArpEntryCount;
        Position := 0;
        while (Position < Result) and (Position < Capacity) do
        begin
          DescribeArpEntry(Position, PAbiArpEntry(Records)[Position]);
          Inc(Position);
        end;
      end;
  else
    Result := ListSockets(PAbiSocketInformation(Records), Capacity);
  end;
  UnlockNetwork;
end;

function PerformListing(Kind: TListKind; BufferAddress, Capacity: QWord): Int64;
var
  Records: PByte;
  Count: LongWord;
  Copied: QWord;
  Error: LongInt;
begin
  if Capacity > MaximumListedRecords then
    Capacity := MaximumListedRecords;
  Records := nil;
  if Capacity > 0 then
  begin
    if not UserRangeIsValid(BufferAddress, Capacity * RecordSize(Kind), True) then
      Exit(Failure(ErrorBadAddress));
    Records := PByte(AllocateZeroedKernelMemory(Capacity * RecordSize(Kind)));
    if Records = nil then
      Exit(Failure(ErrorOutOfMemory));
  end;
  Count := FillRecords(Kind, Records, LongWord(Capacity));
  Copied := Count;
  if Copied > Capacity then
    Copied := Capacity;
  Error := ErrorNone;
  if Copied > 0 then
    Error := CopyToUser(BufferAddress, Records, Copied * RecordSize(Kind));
  if Records <> nil then
    FreeKernelMemory(Records);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Count;
end;

function PerformListNetworkInterfaces(BufferAddress, Capacity: QWord): Int64;
begin
  Result := PerformListing(ListInterfaces, BufferAddress, Capacity);
end;

function PerformListRoutes(BufferAddress, Capacity: QWord): Int64;
begin
  Result := PerformListing(ListRoutes, BufferAddress, Capacity);
end;

function PerformListArpEntries(BufferAddress, Capacity: QWord): Int64;
begin
  Result := PerformListing(ListArpEntries, BufferAddress, Capacity);
end;

function PerformListSockets(BufferAddress, Capacity: QWord): Int64;
begin
  Result := PerformListing(ListSocketEntries, BufferAddress, Capacity);
end;

function PerformConfigureNetworkInterface(ConfigurationAddress: QWord): Int64;
var
  Configuration: TAbiInterfaceConfiguration;
  Error: LongInt;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  Error := CopyFromUser(@Configuration, ConfigurationAddress, SizeOf(Configuration));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  LockNetwork;
  Error := ConfigureInterface(Configuration);
  UnlockNetwork;
  if Error = ErrorNone then
    NoteNetworkChange;
  Result := Failure(Error);
end;

function PerformChangeRoute(Operation, RouteAddress: QWord): Int64;
var
  Route: TAbiRoute;
  Name: array[0..NetworkInterfaceNameCapacity - 1] of Char;
  NetworkInterface: PNetworkInterface;
  Destination: TIpv4Address;
  Gateway: TIpv4Address;
  Error: LongInt;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  Error := CopyFromUser(@Route, RouteAddress, SizeOf(Route));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if Route.Destination.Family <> AddressFamilyIPv4 then
    Exit(Failure(ErrorAddressFamilyNotSupported));
  Destination := ReadIpv4Address(@Route.Destination.Address[0]);
  Gateway := ReadIpv4Address(@Route.Gateway[0]);
  CopyText(@Name[0], @Route.InterfaceName[0], NetworkInterfaceNameCapacity);
  LockNetwork;
  NetworkInterface := nil;
  if Name[0] <> #0 then
    NetworkInterface := FindInterfaceByName(@Name[0]);
  if (Name[0] <> #0) and (NetworkInterface = nil) then
    Error := ErrorNoDevice
  else
    case Operation of
      RouteAdd:
        if (Gateway = AnyAddress) and (NetworkInterface = nil) then
          Error := ErrorInvalidArgument
        else
          Error := AddRoute(Destination, Route.Destination.PrefixLength, Gateway, NetworkInterface, 0,
            Route.Metric);
      RouteRemove:
        Error := RemoveRoute(Destination, Route.Destination.PrefixLength, Gateway);
    else
      Error := ErrorInvalidArgument;
    end;
  UnlockNetwork;
  if Error = ErrorNone then
    NoteNetworkChange;
  Result := Failure(Error);
end;

function PerformGetDnsServers(ServersAddress: QWord): Int64;
var
  Servers: TAbiDnsServers;
begin
  GetDnsServers(Servers);
  Result := Failure(CopyToUser(ServersAddress, @Servers, SizeOf(Servers)));
end;

function PerformSetDnsServers(ServersAddress: QWord): Int64;
var
  Servers: TAbiDnsServers;
  Error: LongInt;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  Error := CopyFromUser(@Servers, ServersAddress, SizeOf(Servers));
  if Error = ErrorNone then
    Error := SetDnsServers(Servers);
  if Error = ErrorNone then
    NoteNetworkChange;
  Result := Failure(Error);
end;

function PerformWatchNetworkChanges: Int64;
var
  Process: PProcess;
  Watcher: PEventObject;
  Handle: Int64;
begin
  Watcher := CreateNetworkChangeWatcher;
  if Watcher = nil then
    Exit(Failure(ErrorOutOfMemory));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Handle := InsertHandle(Process^.Handles, HandleKindEvent, Watcher, 0);
  ReleaseMutex(Process^.Lock);
  { The handle has its own reference (or none, if it could not be made);
    the creation reference goes. }
  DereferenceObject(Watcher);
  if Handle < 0 then
    Exit(Failure(ErrorTooManyHandles));
  Result := Handle;
end;

end.
