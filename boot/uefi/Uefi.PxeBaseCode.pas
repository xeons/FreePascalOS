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
  EFI_PXE_BASE_CODE_PROTOCOL (UEFI specification, section 24.3): the
  firmware's PXE client, of which the loader uses the TFTP transfers
  (Mtftp) and the DHCP state a PXE boot left behind.
}
unit Uefi.PxeBaseCode;

{$mode objfpc}

interface

uses
  Uefi.Base;

const
  PxePacketSize = 1472;

  { EFI_PXE_BASE_CODE_TFTP_OPCODE }
  PxeTftpGetFileSize = 1;
  PxeTftpReadFile = 2;

  { Offsets in a DHCPv4 (BOOTP) packet. }
  BootpServerAddressOffset = 20;
  BootpBootFileOffset = 108;
  BootpBootFileLength = 128;

  PxeBaseCodeProtocolGuid: TEfiGuid = (
    Data1: $03C4E603; Data2: $AC28; Data3: $11D3;
    Data4: ($9A, $2D, $00, $90, $27, $3F, $C1, $4D));

type
  { EFI_IP_ADDRESS: room for an IPv6 address; IPv4 uses the first four
    bytes. }
  TEfiIpAddress = record
    case Integer of
      0: (Bytes: array[0..15] of Byte);
      1: (Words: array[0..3] of LongWord);
  end;
  PEfiIpAddress = ^TEfiIpAddress;

  TPxePacket = array[0..PxePacketSize - 1] of Byte;

  TEfiPxeBaseCodeMode = record
    Started: Byte;
    Ipv6Available: Byte;
    Ipv6Supported: Byte;
    UsingIpv6: Byte;
    BisSupported: Byte;
    BisDetected: Byte;
    AutoArp: Byte;
    SendGuid: Byte;
    DhcpDiscoverValid: Byte;
    DhcpAckReceived: Byte;
    ProxyOfferReceived: Byte;
    PxeDiscoverValid: Byte;
    PxeReplyReceived: Byte;
    PxeBisReplyReceived: Byte;
    IcmpErrorReceived: Byte;
    TftpErrorReceived: Byte;
    MakeCallbacks: Byte;
    TimeToLive: Byte;
    TypeOfService: Byte;
    StationIp: TEfiIpAddress;
    SubnetMask: TEfiIpAddress;
    DhcpDiscover: TPxePacket;
    DhcpAck: TPxePacket;
    ProxyOffer: TPxePacket;
    PxeDiscover: TPxePacket;
    PxeReply: TPxePacket;
  end;
  PEfiPxeBaseCodeMode = ^TEfiPxeBaseCodeMode;

  PEfiPxeBaseCodeProtocol = ^TEfiPxeBaseCodeProtocol;

  TEfiPxeStart = function(This: PEfiPxeBaseCodeProtocol; UseIpv6: Byte): TEfiStatus;
  TEfiPxeMtftp = function(This: PEfiPxeBaseCodeProtocol; Operation: LongWord;
    Buffer: Pointer; Overwrite: Byte; BufferSize: PQWord; BlockSize: PQWord;
    ServerIp: PEfiIpAddress; FileName: PChar; Information: Pointer;
    DontUseBuffer: Byte): TEfiStatus;
  TEfiPxeSetStationIp = function(This: PEfiPxeBaseCodeProtocol;
    NewStationIp: PEfiIpAddress; NewSubnetMask: PEfiIpAddress): TEfiStatus;

  TEfiPxeBaseCodeProtocol = record
    Revision: QWord;
    Start: TEfiPxeStart;
    Stop: Pointer;
    Dhcp: Pointer;
    Discover: Pointer;
    Mtftp: TEfiPxeMtftp;
    UdpWrite: Pointer;
    UdpRead: Pointer;
    SetIpFilter: Pointer;
    Arp: Pointer;
    SetParameters: Pointer;
    SetStationIp: TEfiPxeSetStationIp;
    SetPackets: Pointer;
    Mode: PEfiPxeBaseCodeMode;
  end;

implementation

end.
