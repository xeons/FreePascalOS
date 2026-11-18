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
  Reading a file over TFTP with the firmware's PXE client (its Mtftp
  service).

  The PXE client must be started and know its address: after a PXE boot
  it is both; otherwise the loader starts it and gives it the address
  the interface has (Loader.NetworkInterface), without a DHCP exchange
  of its own (the PXE client ignores DHCP offers that name no boot file,
  which is what an ordinary router sends). Without a gateway the server
  must then be on the local network.

  The size comes first (the TFTP "tsize" option, which the server must
  support), then the file is read straight into memory of that size,
  in 1468-byte blocks where the server agrees.
}
unit Loader.TftpTransfer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Uefi.Base,
  Loader.FileLoading,
  Loader.NetworkInterface;

{ Reads Path (relative to the server's root, '/' separated) from the
  TFTP server at ServerAddress. }
function FetchFileOverTftp(const NetworkInterface: TNetworkInterface;
  const ServerAddress: array of Byte; Path: PChar; MemoryType: LongWord;
  out LoadedFile: TLoadedFile): TEfiStatus;

implementation

uses
  Runtime.Memory,
  Uefi.DevicePath,
  Uefi.LoadedImage,
  Uefi.SystemTable,
  Uefi.PxeBaseCode,
  Loader.Firmware,
  Loader.Console;

const
  PreferredBlockSize = 1468;

{ The PXE client lives on a child handle of the interface: the device
  the loader came from after a PXE boot, otherwise the IPv4 PXE handle
  (there is one for IPv6 too) whose device path continues the
  interface's. }
function FindPxeClient(const NetworkInterface: TNetworkInterface;
  out Pxe: PEfiPxeBaseCodeProtocol): TEfiStatus;
var
  LoadedImage: PEfiLoadedImageProtocol;
  InterfacePath: PEfiDevicePathNode;
  CandidatePath: PEfiDevicePathNode;
  HandleCount: QWord;
  Handles: PEfiHandle;
  Index: QWord;
begin
  Pxe := nil;
  if not EfiIsError(FirmwareBootServices^.HandleProtocol(LoaderImageHandle,
       @LoadedImageProtocolGuid, @LoadedImage)) and
     not EfiIsError(FirmwareBootServices^.HandleProtocol(LoadedImage^.DeviceHandle,
       @PxeBaseCodeProtocolGuid, @Pxe)) then
    Exit(EfiSuccess);
  if not EfiIsError(FirmwareBootServices^.HandleProtocol(NetworkInterface.Handle,
       @PxeBaseCodeProtocolGuid, @Pxe)) then
    Exit(EfiSuccess);

  InterfacePath := nil;
  FirmwareBootServices^.HandleProtocol(NetworkInterface.Handle, @DevicePathProtocolGuid,
    @InterfacePath);
  Handles := nil;
  HandleCount := 0;
  Result := FirmwareBootServices^.LocateHandleBuffer(EfiLocateByProtocol,
    @PxeBaseCodeProtocolGuid, nil, @HandleCount, @Handles);
  if EfiIsError(Result) then
    Exit;
  Result := EfiNotFound;
  Index := 0;
  while Index < HandleCount do
  begin
    if not EfiIsError(FirmwareBootServices^.HandleProtocol(Handles[Index],
         @DevicePathProtocolGuid, @CandidatePath)) and
       (FindDevicePathNode(CandidatePath, DevicePathTypeMessaging, DevicePathSubTypeIpv4) <> nil) and
       ((InterfacePath = nil) or DevicePathStartsWith(CandidatePath, InterfacePath)) then
    begin
      Result := FirmwareBootServices^.HandleProtocol(Handles[Index],
        @PxeBaseCodeProtocolGuid, @Pxe);
      Break;
    end;
    Inc(Index);
  end;
  FirmwareBootServices^.FreePool(Handles);
end;

function OpenPxeClient(const NetworkInterface: TNetworkInterface;
  out Pxe: PEfiPxeBaseCodeProtocol): TEfiStatus;
var
  StationIp: TEfiIpAddress;
  SubnetMask: TEfiIpAddress;
begin
  Result := FindPxeClient(NetworkInterface, Pxe);
  if EfiIsError(Result) then
    Exit;
  if Pxe^.Mode^.Started <> 0 then
    Exit(EfiSuccess);

  Result := Pxe^.Start(Pxe, 0);
  if EfiIsError(Result) and (Result <> EfiAlreadyStarted) then
    Exit;
  FillMemory(@StationIp, SizeOf(StationIp), 0);
  FillMemory(@SubnetMask, SizeOf(SubnetMask), 0);
  CopyMemory(@StationIp.Bytes[0], @NetworkInterface.StationAddress[0], 4);
  CopyMemory(@SubnetMask.Bytes[0], @NetworkInterface.SubnetMask[0], 4);
  Result := Pxe^.SetStationIp(Pxe, @StationIp, @SubnetMask);
end;

function FetchFileOverTftp(const NetworkInterface: TNetworkInterface;
  const ServerAddress: array of Byte; Path: PChar; MemoryType: LongWord;
  out LoadedFile: TLoadedFile): TEfiStatus;
var
  Pxe: PEfiPxeBaseCodeProtocol;
  Server: TEfiIpAddress;
  FileSize: QWord;
  BufferSize: QWord;
  BlockSize: QWord;
begin
  FillMemory(@LoadedFile, SizeOf(LoadedFile), 0);
  Result := OpenPxeClient(NetworkInterface, Pxe);
  if EfiIsError(Result) then
    Exit;

  FillMemory(@Server, SizeOf(Server), 0);
  CopyMemory(@Server.Bytes[0], @ServerAddress[0], 4);
  BlockSize := PreferredBlockSize;
  FileSize := 0;
  Result := Pxe^.Mtftp(Pxe, PxeTftpGetFileSize, nil, 0, @FileSize, @BlockSize, @Server,
    Path, nil, 0);
  if EfiIsError(Result) then
  begin
    if (Result = EfiTftpError) or (Result = EfiNotFound) then
      Result := EfiNotFound;
    Exit;
  end;

  if not AllocateLoadedFile(LoadedFile, FileSize + 1, MemoryType) then
    Exit(EfiOutOfResources);
  BufferSize := FileSize;
  BlockSize := PreferredBlockSize;
  Result := Pxe^.Mtftp(Pxe, PxeTftpReadFile, LoadedFile.Contents, 0, @BufferSize, @BlockSize,
    @Server, Path, nil, 0);
  if (not EfiIsError(Result)) and (BufferSize <> FileSize) then
    Result := EfiDeviceError;
  if EfiIsError(Result) then
    ReleaseLoadedFile(LoadedFile)
  else
    LoadedFile.SizeInBytes := FileSize;
end;

end.
