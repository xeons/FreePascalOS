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
  The network interface a network boot goes through, and its IPv4
  address.

  The interface is a handle with EFI_IP4_CONFIG2_PROTOCOL (the firmware's
  IPv4 stack bound to a network card): the one the loader was started
  from when it came over the network, otherwise the first one. If the
  firmware has not bound its network stack to any card (it connects
  only the devices it boots from), the loader connects the drivers to
  the cards, or to every device if the cards' own drivers are not
  connected either.

  An interface a PXE or HTTP boot used already has an address. Otherwise
  the loader switches it to DHCP (Ip4Config2 policy; the firmware keeps
  that setting) and waits for an address. The address stays configured,
  so the HTTP and TFTP clients created afterwards use it.
}
unit Loader.NetworkInterface;

{$mode objfpc}
{$pointermath on}

interface

uses
  Uefi.Base,
  Uefi.DevicePath;

type
  TNetworkInterface = record
    Handle: TEfiHandle;
    StationAddress: array[0..3] of Byte;
    SubnetMask: array[0..3] of Byte;
  end;

{ Finds the interface and makes sure it has an IPv4 address. }
function OpenNetworkInterface(out NetworkInterface: TNetworkInterface): TEfiStatus;

procedure PrintIpv4Address(const Address: array of Byte);

{ The device path of the device the loader was started from, or nil. }
function LoaderDevicePath: PEfiDevicePathNode;

implementation

uses
  Runtime.Memory,
  Uefi.LoadedImage,
  Uefi.Ip4Config2,
  Uefi.SystemTable,
  Loader.Firmware,
  Loader.Console;

const
  DhcpWaitMilliseconds = 30 * 1000;
  PollIntervalMilliseconds = 100;
  InterfaceInfoBufferSize = 2048;

procedure PrintIpv4Address(const Address: array of Byte);
var
  Index: Integer;
begin
  for Index := 0 to 3 do
  begin
    if Index > 0 then
      PrintText('.');
    PrintDecimal(Address[Index]);
  end;
end;

function LoaderDevicePath: PEfiDevicePathNode;
var
  LoadedImage: PEfiLoadedImageProtocol;
  Path: PEfiDevicePathNode;
begin
  Result := nil;
  if EfiIsError(FirmwareBootServices^.HandleProtocol(LoaderImageHandle,
       @LoadedImageProtocolGuid, @LoadedImage)) then
    Exit;
  if EfiIsError(FirmwareBootServices^.HandleProtocol(LoadedImage^.DeviceHandle,
       @DevicePathProtocolGuid, @Path)) then
    Exit;
  Result := Path;
end;

{ Connects the firmware's drivers to every handle that has Protocol
  (nil: every handle), and to what they create below them. }
procedure ConnectHandlesWith(Protocol: PEfiGuid);
var
  HandleCount: QWord;
  Handles: PEfiHandle;
  Index: QWord;
  SearchType: LongWord;
begin
  Handles := nil;
  HandleCount := 0;
  if Protocol = nil then
    SearchType := EfiLocateAllHandles
  else
    SearchType := EfiLocateByProtocol;
  if EfiIsError(FirmwareBootServices^.LocateHandleBuffer(SearchType, Protocol, nil,
       @HandleCount, @Handles)) then
    Exit;
  Index := 0;
  while Index < HandleCount do
  begin
    FirmwareBootServices^.ConnectController(Handles[Index], nil, nil, 1);
    Inc(Index);
  end;
  FirmwareBootServices^.FreePool(Handles);
end;

function ChooseInterfaceHandle(out Handle: TEfiHandle): Boolean;
var
  HandleCount: QWord;
  Handles: PEfiHandle;
  Index: QWord;
  OwnPath: PEfiDevicePathNode;
  CandidatePath: PEfiDevicePathNode;
begin
  Handle := nil;
  Handles := nil;
  HandleCount := 0;
  if EfiIsError(FirmwareBootServices^.LocateHandleBuffer(EfiLocateByProtocol,
       @Ip4Config2ProtocolGuid, nil, @HandleCount, @Handles)) or (HandleCount = 0) then
    Exit(False);

  Handle := Handles[0];
  OwnPath := LoaderDevicePath;
  Index := 0;
  while Index < HandleCount do
  begin
    if not EfiIsError(FirmwareBootServices^.HandleProtocol(Handles[Index],
         @DevicePathProtocolGuid, @CandidatePath)) and
       DevicePathStartsWith(OwnPath, CandidatePath) then
    begin
      Handle := Handles[Index];
      Break;
    end;
    Inc(Index);
  end;
  FirmwareBootServices^.FreePool(Handles);
  Result := True;
end;

function ReadInterfaceAddress(Config: PEfiIp4Config2Protocol;
  var NetworkInterface: TNetworkInterface): Boolean;
var
  Buffer: array[0..InterfaceInfoBufferSize - 1] of Byte;
  BufferSize: QWord;
  Information: PEfiIp4Config2InterfaceInfo;
begin
  BufferSize := SizeOf(Buffer);
  Result := False;
  if EfiIsError(Config^.GetData(Config, Ip4Config2DataTypeInterfaceInfo, @BufferSize, @Buffer[0])) then
    Exit;
  Information := PEfiIp4Config2InterfaceInfo(@Buffer[0]);
  CopyMemory(@NetworkInterface.StationAddress[0], @Information^.StationAddress[0], 4);
  CopyMemory(@NetworkInterface.SubnetMask[0], @Information^.SubnetMask[0], 4);
  Result := PLongWord(@Information^.StationAddress[0])^ <> 0;
end;

function WaitForAddress(Config: PEfiIp4Config2Protocol;
  var NetworkInterface: TNetworkInterface): Boolean;
var
  Waited: QWord;
  Policy: LongWord;
begin
  if ReadInterfaceAddress(Config, NetworkInterface) then
    Exit(True);

  PrintText('Network: asking for an address by DHCP');
  Policy := Ip4Config2PolicyDhcp;
  { EFI_ABORTED: DHCP is the policy already and is under way. }
  Config^.SetData(Config, Ip4Config2DataTypePolicy, SizeOf(Policy), @Policy);
  Waited := 0;
  while Waited < DhcpWaitMilliseconds do
  begin
    FirmwareBootServices^.Stall(PollIntervalMilliseconds * 1000);
    Waited := Waited + PollIntervalMilliseconds;
    if ReadInterfaceAddress(Config, NetworkInterface) then
    begin
      PrintLine('');
      Exit(True);
    end;
    if Waited mod 1000 = 0 then
      PrintText('.');
  end;
  PrintLine('');
  Result := False;
end;

function OpenNetworkInterface(out NetworkInterface: TNetworkInterface): TEfiStatus;
var
  Config: PEfiIp4Config2Protocol;
begin
  FillMemory(@NetworkInterface, SizeOf(NetworkInterface), 0);
  if not ChooseInterfaceHandle(NetworkInterface.Handle) then
  begin
    { The network cards' drivers may not be connected either (the
      firmware connects only what it boots from). }
    PrintLine('Network: connecting the firmware''s network drivers');
    ConnectHandlesWith(@SimpleNetworkProtocolGuid);
    if not ChooseInterfaceHandle(NetworkInterface.Handle) then
    begin
      ConnectHandlesWith(nil);
      if not ChooseInterfaceHandle(NetworkInterface.Handle) then
        Exit(EfiNotFound);
    end;
  end;

  Result := FirmwareBootServices^.HandleProtocol(NetworkInterface.Handle,
    @Ip4Config2ProtocolGuid, @Config);
  if EfiIsError(Result) then
    Exit;
  if not WaitForAddress(Config, NetworkInterface) then
    Exit(EfiNoMapping);

  PrintText('Network: address ');
  PrintIpv4Address(NetworkInterface.StationAddress);
  PrintText(' mask ');
  PrintIpv4Address(NetworkInterface.SubnetMask);
  PrintLine('');
  Result := EfiSuccess;
end;

end.
