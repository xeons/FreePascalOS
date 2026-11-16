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
  What an interface keeps for IPv6 (part of TNetworkInterface): its
  mode, its addresses with their lifetimes and duplicate address
  detection, what routers advertised (hop limit, MTU, timers, DNS
  servers), and where router solicitation and MLD reports stand.

  Times are NetworkNow times; Ipv6Forever stands for an infinite
  lifetime. The multicast groups an interface belongs to are not kept:
  they follow from its addresses (all-nodes, and the solicited-node
  group of each address).
}
unit Network.Ipv6Types;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Network.Ipv6Addresses;

const
  MaximumIpv6InterfaceAddresses = 7;
  Ipv6Forever = High(QWord);
  DefaultIpv6HopLimit = 64;
  { RFC 8200: every link carries at least this much. }
  MinimumIpv6Mtu = 1280;

type
  TIpv6AddressState = (Ipv6AddressFree, Ipv6AddressTentative, Ipv6AddressPreferred, Ipv6AddressDeprecated);

  TIpv6AddressOrigin = (
    { fe80:: with the interface identifier, made at link up. }
    Ipv6OriginLinkLocal,
    { SLAAC: a router's prefix with the interface identifier. }
    Ipv6OriginAutomatic,
    { Given by hand (ifconfig, the network service). }
    Ipv6OriginManual,
    { ::1 on lo. }
    Ipv6OriginLoopback);
  TIpv6AddressOrigins = set of TIpv6AddressOrigin;

  PIpv6InterfaceAddress = ^TIpv6InterfaceAddress;
  TIpv6InterfaceAddress = record
    State: TIpv6AddressState;
    Origin: TIpv6AddressOrigin;
    Address: TIpv6Address;
    PrefixLength: LongWord;
    ValidUntil: QWord;
    PreferredUntil: QWord;
    { Tentative: when the next probe goes or detection ends, and the
      probes sent so far. }
    DadDeadline: QWord;
    DadProbesSent: LongWord;
  end;

  TIpv6DnsServer = record
    InUse: Boolean;
    Address: TIpv6Address;
    ValidUntil: QWord;
  end;

  TIpv6InterfaceState = record
    { Ipv6Mode*. }
    Mode: LongWord;
    { The link-local address was made for the link that is up now. }
    IsStarted: Boolean;
    { From router advertisements. }
    HopLimit: Byte;
    { 0: the interface's MTU. }
    Mtu: LongWord;
    ReachableMilliseconds: LongWord;
    RetransmitMilliseconds: LongWord;
    Addresses: array[0..MaximumIpv6InterfaceAddresses - 1] of TIpv6InterfaceAddress;
    DnsServers: array[0..MaximumDnsServers - 1] of TIpv6DnsServer;
    { Router solicitations: how many went, and when the next is due (0:
      none). }
    SolicitationsSent: LongWord;
    NextSolicitation: QWord;
    { Unsolicited MLD reports still to send, and when (0: none). }
    MldReportsLeft: LongWord;
    NextMldReport: QWord;
  end;

implementation

end.
