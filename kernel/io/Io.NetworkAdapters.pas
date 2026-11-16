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
  Network adapters: the part of networking that does not depend on the
  hardware. A network driver registers each adapter it has
  (RegisterNetworkAdapter) with the routines that send a frame and report
  the link, and calls back when a frame arrives, when the link changes,
  and when it has room to send again. Frames are Ethernet II frames from
  the destination address on, without the frame check sequence.
}
unit Io.NetworkAdapters;

{$mode objfpc}
{$pointermath on}

interface

const
  EthernetAddressLength = 6;
  { An Ethernet frame without its check sequence: 14 header bytes and up
    to 1500 of payload. }
  MaximumFrameBytes = 1514;
  MinimumFrameBytes = 60;

  NetworkAdapterKindEthernet = 1;
  NetworkAdapterKindLoopback = 2;

type
  TEthernetAddress = array[0..EthernetAddressLength - 1] of Byte;

  TNetworkDriverRoutines = record
    { Sends one frame (Length bytes at Frame, at most MaximumFrameBytes;
      the driver pads short frames). The driver copies the frame before
      returning. False if the driver has no room now (the frame was not
      taken); it then calls NetworkTransmitReady once it has room.
      Called at dispatch level or below; must not wait. }
    Transmit: function(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
    { Whether the link is up now. }
    LinkUp: function(Context: Pointer): Boolean;
    { NetworkAdapterKind*. }
    Kind: LongWord;
  end;

  PNetworkAdapter = ^TNetworkAdapter;
  TNetworkAdapter = record
    Routines: TNetworkDriverRoutines;
    Context: Pointer;
    Address: TEthernetAddress;
    { "eth0", "eth1", ... given at registration. }
    Name: array[0..15] of Char;
    { "Intel 82574L", "virtio network device", ... }
    Description: array[0..47] of Char;
    { Private to the network layer. }
    State: Pointer;
  end;

{ Registers an adapter and names it (eth0, eth1, ... in the order they
  register). nil if memory is short. Called while the system starts, at
  passive level. }
function RegisterNetworkAdapter(const Routines: TNetworkDriverRoutines; Context: Pointer;
  const Address: TEthernetAddress; Description: PChar): PNetworkAdapter;
{ For the driver, at dispatch level or below (its deferred routine): a
  frame arrived. The network layer copies it before returning. }
procedure NetworkFrameReceived(Adapter: PNetworkAdapter; Frame: PByte; Length: LongWord);
{ For the driver: the link went up or down (LinkUp tells which). }
procedure NetworkLinkChanged(Adapter: PNetworkAdapter);
{ For the driver: after Transmit returned False, it has room again. }
procedure NetworkTransmitReady(Adapter: PNetworkAdapter);
{ How many adapters registered. }
function NetworkAdapterCount: Integer;

implementation

{
  The adapter's State is its network interface (Network.Interfaces).
  Registering sets the network layer up first if nothing has yet (the
  loopback interface comes first, so it is always number 1); frames
  that arrive before the network thread runs wait in the receive queue.
}

uses
  Runtime.Memory,
  Runtime.Text,
  Runtime.Atomic,
  Memory.KernelHeap,
  Network.Packets,
  Network.Core,
  Network.Interfaces,
  Network.Startup,
  Debug.Output;

var
  RegisteredAdapterCount: Integer;
  EthernetAdapterCount: Integer;

procedure NameAdapter(Adapter: PNetworkAdapter);
var
  Number: TNumberText;
begin
  CopyText(@Adapter^.Name[0], 'eth', SizeOf(Adapter^.Name));
  CopyText(@Adapter^.Name[3], FormatDecimal(EthernetAdapterCount, Number), SizeOf(Adapter^.Name) - 3);
  Inc(EthernetAdapterCount);
end;

procedure WriteAdapterDescription(Adapter: PNetworkAdapter);
var
  Index: Integer;
begin
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@Adapter^.Name[0]);
  DebugWrite(': ');
  DebugWrite(@Adapter^.Description[0]);
  DebugWrite(', address ');
  for Index := 0 to EthernetAddressLength - 1 do
  begin
    if Index > 0 then
      DebugWriteCharacter(':');
    DebugWriteHex(Adapter^.Address[Index], 2);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function RegisterNetworkAdapter(const Routines: TNetworkDriverRoutines; Context: Pointer;
  const Address: TEthernetAddress; Description: PChar): PNetworkAdapter;
var
  NetworkInterface: PNetworkInterface;
begin
  InitializeNetworking;
  Result := PNetworkAdapter(AllocateZeroedKernelMemory(SizeOf(TNetworkAdapter)));
  if Result = nil then
    Exit;
  Result^.Routines := Routines;
  Result^.Context := Context;
  Result^.Address := Address;
  CopyText(@Result^.Description[0], Description, SizeOf(Result^.Description));
  NameAdapter(Result);
  LockNetwork;
  NetworkInterface := CreateNetworkInterface(Result, False);
  UnlockNetwork;
  if NetworkInterface = nil then
  begin
    FreeKernelMemory(Result);
    Exit(nil);
  end;
  Result^.State := NetworkInterface;
  Inc(RegisteredAdapterCount);
  WriteAdapterDescription(Result);
end;

procedure NetworkFrameReceived(Adapter: PNetworkAdapter; Frame: PByte; Length: LongWord);
var
  NetworkInterface: PNetworkInterface;
  Packet: PPacket;
begin
  NetworkInterface := PNetworkInterface(Adapter^.State);
  if (NetworkInterface = nil) or (Length > MaximumFrameBytes) or (Length = 0) then
    Exit;
  Packet := AllocatePacket(0);
  if Packet = nil then
  begin
    AtomicIncrement(NetworkInterface^.QueueDrops);
    Exit;
  end;
  CopyMemory(@Packet^.Bytes[0], Frame, Length);
  Packet^.Length := Length;
  Packet^.NetworkInterface := NetworkInterface;
  if not QueueReceivedPacket(Packet) then
    AtomicIncrement(NetworkInterface^.QueueDrops);
end;

procedure NetworkLinkChanged(Adapter: PNetworkAdapter);
begin
  if Adapter^.State <> nil then
    PostInterfaceEvent(PNetworkInterface(Adapter^.State), InterfaceEventLinkChanged);
end;

procedure NetworkTransmitReady(Adapter: PNetworkAdapter);
begin
  if Adapter^.State <> nil then
    PostInterfaceEvent(PNetworkInterface(Adapter^.State), InterfaceEventTransmitReady);
end;

function NetworkAdapterCount: Integer;
begin
  Result := RegisteredAdapterCount;
end;

end.
