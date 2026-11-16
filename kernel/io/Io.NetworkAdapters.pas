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

{ A stand-in until the network stack exists: it keeps the list and names
  the adapters, and drops what arrives. }

uses
  Memory.KernelHeap;

const
  MaximumAdapters = 16;

var
  Adapters: array[0..MaximumAdapters - 1] of PNetworkAdapter;
  AdapterCount: Integer;

procedure WriteName(Adapter: PNetworkAdapter; Number: Integer);
var
  Digits: array[0..3] of Char;
  DigitCount: Integer;
  Position: Integer;
begin
  DigitCount := 0;
  repeat
    Digits[DigitCount] := Char(Ord('0') + Number mod 10);
    Number := Number div 10;
    Inc(DigitCount);
  until Number = 0;
  Adapter^.Name[0] := 'e';
  Adapter^.Name[1] := 't';
  Adapter^.Name[2] := 'h';
  Position := 3;
  while DigitCount > 0 do
  begin
    Dec(DigitCount);
    Adapter^.Name[Position] := Digits[DigitCount];
    Inc(Position);
  end;
  Adapter^.Name[Position] := #0;
end;

function RegisterNetworkAdapter(const Routines: TNetworkDriverRoutines; Context: Pointer;
  const Address: TEthernetAddress; Description: PChar): PNetworkAdapter;
var
  Index: Integer;
begin
  Result := nil;
  if AdapterCount = MaximumAdapters then
    Exit;
  Result := PNetworkAdapter(AllocateZeroedKernelMemory(SizeOf(TNetworkAdapter)));
  if Result = nil then
    Exit;
  Result^.Routines := Routines;
  Result^.Context := Context;
  Result^.Address := Address;
  WriteName(Result, AdapterCount);
  Index := 0;
  while (Description <> nil) and (Description[Index] <> #0) and (Index < High(Result^.Description)) do
  begin
    Result^.Description[Index] := Description[Index];
    Inc(Index);
  end;
  Result^.Description[Index] := #0;
  Adapters[AdapterCount] := Result;
  Inc(AdapterCount);
end;

procedure NetworkFrameReceived(Adapter: PNetworkAdapter; Frame: PByte; Length: LongWord);
begin
end;

procedure NetworkLinkChanged(Adapter: PNetworkAdapter);
begin
end;

procedure NetworkTransmitReady(Adapter: PNetworkAdapter);
begin
end;

function NetworkAdapterCount: Integer;
begin
  Result := AdapterCount;
end;

end.
