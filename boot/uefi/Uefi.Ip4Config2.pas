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
  EFI_IP4_CONFIG2_PROTOCOL (UEFI specification, section 28.5): how a
  network interface gets its IPv4 address, statically or by DHCP. The
  loader asks for DHCP when nothing has configured the interface yet.
}
unit Uefi.Ip4Config2;

{$mode objfpc}

interface

uses
  Uefi.Base;

const
  { EFI_IP4_CONFIG2_DATA_TYPE }
  Ip4Config2DataTypeInterfaceInfo = 0;
  Ip4Config2DataTypePolicy = 1;
  { EFI_IP4_CONFIG2_POLICY }
  Ip4Config2PolicyDhcp = 1;

  Ip4Config2ProtocolGuid: TEfiGuid = (
    Data1: $5B446ED1; Data2: $E30B; Data3: $4FAA;
    Data4: ($87, $1A, $36, $54, $EC, $A3, $60, $80));

  SimpleNetworkProtocolGuid: TEfiGuid = (
    Data1: $A19832B9; Data2: $AC25; Data3: $11D3;
    Data4: ($9A, $2D, $00, $90, $27, $3F, $C1, $4D));

type
  { EFI_IP4_CONFIG2_INTERFACE_INFO; the route table follows it in the
    same buffer. }
  TEfiIp4Config2InterfaceInfo = record
    Name: array[0..31] of WideChar;
    InterfaceType: Byte;
    HardwareAddressSize: LongWord;
    HardwareAddress: array[0..31] of Byte;
    StationAddress: array[0..3] of Byte;
    SubnetMask: array[0..3] of Byte;
    RouteTableSize: LongWord;
    RouteTable: Pointer;
  end;
  PEfiIp4Config2InterfaceInfo = ^TEfiIp4Config2InterfaceInfo;

  PEfiIp4Config2Protocol = ^TEfiIp4Config2Protocol;

  TEfiIp4Config2SetData = function(This: PEfiIp4Config2Protocol; DataType: LongWord;
    DataSize: QWord; Data: Pointer): TEfiStatus;
  TEfiIp4Config2GetData = function(This: PEfiIp4Config2Protocol; DataType: LongWord;
    DataSize: PQWord; Data: Pointer): TEfiStatus;

  TEfiIp4Config2Protocol = record
    SetData: TEfiIp4Config2SetData;
    GetData: TEfiIp4Config2GetData;
    RegisterDataNotify: Pointer;
    UnregisterDataNotify: Pointer;
  end;

implementation

end.
