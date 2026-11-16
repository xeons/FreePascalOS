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
  The system call interface of networking: sockets, and the calls that
  list and configure the network interfaces, the routes, the ARP cache
  and the DNS servers. Included at the end of Abi.SystemCalls.inc.

  Addresses carry a family (AddressFamily*), so that IPv6 can be added
  without new calls: an IPv4 address takes the first four bytes of the
  sixteen, in the order it is written (10.0.2.15 is 10, 0, 2, 15).
  Ports are in the machine's byte order.
}
const
  { --- Sockets ------------------------------------------------------------- }

  { (Family, Kind, Protocol): a new socket handle (HandleKindSocket).
    Family is AddressFamilyIPv4; Kind is SocketKindStream (TCP),
    SocketKindDatagram (UDP, or ICMP echo with ProtocolIcmp) or
    SocketKindRaw (ICMP, root only), with SocketKindNonBlocking or'ed in
    for a socket whose calls never wait. Protocol 0 picks the kind's
    usual one. Closing the last handle closes the socket; a TCP
    connection is then ended gracefully by the kernel. }
  CallCreateSocket = 104;
  { (Handle, AddressAddress): the local address and port (a
    TAbiSocketAddress; port 0: one the kernel chooses, address 0.0.0.0:
    every interface). ErrorAddressInUse, ErrorAddressNotAvailable for an
    address none of the interfaces has, ErrorAccessDenied for a port
    below 1024 for anyone but root. }
  CallBindSocket = 105;
  { (Handle, Backlog): a stream socket takes connections; at most
    Backlog (1 to MaximumListenBacklog) wait to be accepted. }
  CallListenSocket = 106;
  { (Handle, PeerAddress or 0): waits for a connection and returns a new
    socket handle for it (non-blocking: ErrorWouldBlock if none waits). }
  CallAcceptSocket = 107;
  { (Handle, AddressAddress): a stream socket connects (waits for the
    handshake; non-blocking: ErrorInProgress, then the socket becomes
    writable and SocketOptionError tells how it went); a datagram socket
    only remembers the peer it sends to and receives from.
    ErrorConnectionRefused, ErrorTimedOut, ErrorNetworkUnreachable. }
  CallConnectSocket = 108;
  { (Handle, Buffer, Length, Flags, AddressAddress or 0): sends; to the
    connected peer if AddressAddress is 0. Returns the bytes taken (a
    stream socket may take fewer when non-blocking or interrupted).
    A datagram larger than one frame can carry (1472 bytes of UDP) fails
    with ErrorMessageTooLong: nothing is sent in fragments. A broadcast
    needs SocketOptionBroadcast (ErrorAccessDenied). Flags: SocketFlag*. }
  CallSendSocket = 109;
  { (Handle, Buffer, Length, Flags, AddressAddress or 0): receives, and
    where it came from. 0 at the end of a stream (the peer shut its
    side). A datagram longer than Length is cut short. }
  CallReceiveSocket = 110;
  { (Handle, How): SocketShutdownReceive, SocketShutdownSend or both. }
  CallShutdownSocket = 111;
  { (Handle, Option): the value of SocketOption*. }
  CallGetSocketOption = 112;
  { (Handle, Option, Value). }
  CallSetSocketOption = 113;
  { (Handle, Which, AddressAddress): the local (SocketAddressLocal) or
    the peer's (SocketAddressPeer) address; ErrorNotConnected for a peer
    there is not. }
  CallGetSocketAddress = 114;
  { (Handle, Conditions, Timeout): waits until one of Conditions
    (SocketReadable, SocketWritable) holds, at most Timeout ms
    (InfiniteWait: as long as it takes); returns the ones that hold, or
    ErrorTimedOut. CallWaitForHandles waits for a socket to be readable
    (data, a connection to accept, the end of the stream or an error). }
  CallWaitForSocket = 115;

  { --- Network configuration -----------------------------------------------
    Anyone may list; only root may change (ErrorNotPermitted). }

  { (BufferAddress, Capacity): describes the interfaces, one
    TAbiNetworkInterface each, as many as fit in Capacity records;
    returns how many there are. }
  CallListNetworkInterfaces = 116;
  { (ConfigurationAddress): changes an interface as a
    TAbiInterfaceConfiguration says. Root only. }
  CallConfigureNetworkInterface = 117;
  { (Operation, RouteAddress): RouteAdd or RouteRemove the TAbiRoute
    (removing: the one with its destination, prefix and gateway). Root
    only. ErrorNetworkUnreachable for a gateway no interface reaches. }
  CallChangeRoute = 118;
  { (BufferAddress, Capacity): the routing table, TAbiRoute records;
    returns how many routes there are. }
  CallListRoutes = 119;
  { (BufferAddress, Capacity): the ARP cache, TAbiArpEntry records;
    returns how many entries there are. }
  CallListArpEntries = 120;
  { (BufferAddress, Capacity): every socket and TCP connection (also
    those closing after their socket went), TAbiSocketInformation
    records; returns how many there are. }
  CallListSockets = 121;
  { (ServersAddress): the system's DNS servers and search domain, a
    TAbiDnsServers. The kernel keeps them for the resolver, as it keeps
    the time zone's name. }
  CallGetDnsServers = 122;
  { (ServersAddress): new DNS servers. Root only. }
  CallSetDnsServers = 123;
  { (): an event handle (automatic reset) signaled after every change to
    the network's configuration from now on: an adapter registered, a
    link that came or went, an interface turned on or off or given an
    address, a route or the DNS servers changed. The watcher looks again
    (CallListNetworkInterfaces ...) when it is signaled. Anyone. }
  CallWatchNetworkChanges = 125;
  { (StatisticsAddress): the protocols' counters since the start, a
    TAbiNetworkStatistics (netstat -s). Anyone may read them. }
  CallGetNetworkStatistics = 126;

  AddressFamilyUnspecified = 0;
  AddressFamilyIPv4 = 2;
  { Not yet supported; the number is kept for it. }
  AddressFamilyIPv6 = 10;

  SocketKindStream = 1;
  SocketKindDatagram = 2;
  SocketKindRaw = 3;
  { Or'ed into the kind of CallCreateSocket: never wait. }
  SocketKindNonBlocking = $100;

  ProtocolDefault = 0;
  ProtocolIcmp = 1;
  ProtocolTcp = 6;
  ProtocolUdp = 17;

  { Flags of CallSendSocket and CallReceiveSocket. }
  { Receive: leave what is read in the queue. }
  SocketFlagPeek = $01;
  { Do not wait, whatever the socket's mode. }
  SocketFlagDontWait = $02;

  SocketShutdownReceive = 1;
  SocketShutdownSend = 2;
  SocketShutdownBoth = 3;

  SocketAddressLocal = 0;
  SocketAddressPeer = 1;

  { Conditions of CallWaitForSocket. }
  SocketReadable = $01;
  SocketWritable = $02;

  { Options (CallGetSocketOption, CallSetSocketOption). }
  { Milliseconds a receive (or accept) waits before ErrorWouldBlock; 0
    waits as long as it takes. }
  SocketOptionReceiveTimeout = 1;
  { The same for sending (and connecting). }
  SocketOptionSendTimeout = 2;
  { 1: datagrams may be sent to a broadcast address. }
  SocketOptionBroadcast = 3;
  { 1: the address may be bound while another socket has it (datagram
    sockets that all ask for it) or while a connection on it waits out
    TIME_WAIT. }
  SocketOptionReuseAddress = 4;
  { The time to live of the datagrams sent (1-255; 64 at first). }
  SocketOptionTimeToLive = 5;
  { 1: calls never wait (ErrorWouldBlock, ErrorInProgress). }
  SocketOptionNonBlocking = 6;
  { Read only: the error a non-blocking connect ended with (0: it
    connected), or a pending error; reading it clears it. }
  SocketOptionError = 7;
  { 1: TCP sends small segments at once (no Nagle). }
  SocketOptionNoDelay = 8;
  { Read only: SocketKind*. }
  SocketOptionKind = 9;
  { Read only: the time to live the last datagram received had (ping
    shows it). }
  SocketOptionReceivedTimeToLive = 10;
  { The interface (its index, 1 for the first; 0: any) the socket sends
    on and receives from: a DHCP client sends its broadcasts on one
    interface, which may not have an address yet. Root only. }
  SocketOptionInterface = 11;
  { Read only: bytes waiting to be read (the first datagram's size for a
    datagram socket). }
  SocketOptionReadableBytes = 12;

  MaximumListenBacklog = 64;
  { The most records a listing (interfaces, routes, ARP entries,
    sockets) returns; a longer list is cut short there. }
  MaximumListedNetworkRecords = 1024;
  { The largest UDP datagram sent: one Ethernet frame without fragments. }
  MaximumDatagramBytes = 1472;

  { TCP states (TAbiSocketInformation.State; 0 for other sockets). }
  TcpStateClosed = 1;
  TcpStateListen = 2;
  TcpStateSynSent = 3;
  TcpStateSynReceived = 4;
  TcpStateEstablished = 5;
  TcpStateFinWait1 = 6;
  TcpStateFinWait2 = 7;
  TcpStateCloseWait = 8;
  TcpStateClosing = 9;
  TcpStateLastAck = 10;
  TcpStateTimeWait = 11;

  NetworkInterfaceNameCapacity = 16;
  NetworkInterfaceDescriptionCapacity = 48;
  HardwareAddressCapacity = 8;
  MaximumInterfaceAddresses = 4;
  MaximumDnsServers = 4;
  DnsDomainCapacity = 64;

  { TAbiNetworkInterface.Flags. }
  { Turned on (ifconfig up). }
  InterfaceFlagUp = $01;
  { The link is there (a cable, a virtual switch). }
  InterfaceFlagRunning = $02;
  InterfaceFlagLoopback = $04;
  InterfaceFlagBroadcast = $08;

  { TAbiInterfaceConfiguration.Changes. }
  InterfaceChangeAddress = $01;
  InterfaceChangeUp = $02;
  InterfaceChangeMtu = $04;

  { TAbiRoute.Flags. }
  { Through a gateway (else the destination is on the link). }
  RouteFlagGateway = $01;
  { Made by the kernel for an interface's own network; removed with the
    address. }
  RouteFlagInterface = $02;
  { Its interface is up. }
  RouteFlagUp = $04;

  RouteAdd = 1;
  RouteRemove = 2;

  { TAbiArpEntry.State. }
  { Asked for, no answer yet. }
  ArpStateIncomplete = 1;
  ArpStateReachable = 2;

type
  { A socket address: AddressFamilyIPv4 with its four bytes first. }
  TAbiSocketAddress = record
    Family: Word;
    Port: Word;
    Reserved: LongWord;
    Address: array[0..15] of Byte;
    Reserved2: QWord;
  end;
  PAbiSocketAddress = ^TAbiSocketAddress;

  { An address with its network prefix (10.0.2.15/24). }
  TAbiInterfaceAddress = record
    Family: Word;
    PrefixLength: Word;
    Reserved: LongWord;
    Address: array[0..15] of Byte;
  end;

  { Packets and bytes through an interface, and what went wrong. }
  TAbiInterfaceCounters = record
    ReceivedPackets: QWord;
    ReceivedBytes: QWord;
    ReceiveErrors: QWord;
    { Frames dropped: no room to keep them, or of a kind nobody takes. }
    ReceiveDrops: QWord;
    SentPackets: QWord;
    SentBytes: QWord;
    SendErrors: QWord;
    SendDrops: QWord;
  end;

  { CallListNetworkInterfaces. }
  TAbiNetworkInterface = record
    Name: array[0..NetworkInterfaceNameCapacity - 1] of Char;
    Description: array[0..NetworkInterfaceDescriptionCapacity - 1] of Char;
    HardwareAddress: array[0..HardwareAddressCapacity - 1] of Byte;
    HardwareAddressLength: LongWord;
    { 1 for the first interface. }
    Index: LongWord;
    Flags: LongWord;
    Mtu: LongWord;
    AddressCount: LongWord;
    Reserved: LongWord;
    Addresses: array[0..MaximumInterfaceAddresses - 1] of TAbiInterfaceAddress;
    Counters: TAbiInterfaceCounters;
  end;
  PAbiNetworkInterface = ^TAbiNetworkInterface;

  { CallConfigureNetworkInterface: what Changes names is set. An address
    of AddressFamilyUnspecified removes the interface's address. }
  TAbiInterfaceConfiguration = record
    Name: array[0..NetworkInterfaceNameCapacity - 1] of Char;
    Changes: LongWord;
    { 1: up, 0: down. }
    Up: LongWord;
    Mtu: LongWord;
    Reserved: LongWord;
    Address: TAbiInterfaceAddress;
  end;

  { A route: where datagrams to Destination go (prefix 0: the default
    route). }
  TAbiRoute = record
    Destination: TAbiInterfaceAddress;
    { All zero: the destination is on the link. }
    Gateway: array[0..15] of Byte;
    { Empty when adding: the interface that reaches the gateway. }
    InterfaceName: array[0..NetworkInterfaceNameCapacity - 1] of Char;
    Flags: LongWord;
    Metric: LongWord;
  end;
  PAbiRoute = ^TAbiRoute;

  TAbiArpEntry = record
    Address: array[0..15] of Byte;
    HardwareAddress: array[0..HardwareAddressCapacity - 1] of Byte;
    InterfaceName: array[0..NetworkInterfaceNameCapacity - 1] of Char;
    State: LongWord;
    { Seconds until it is forgotten (asked again). }
    ExpiresInSeconds: LongWord;
  end;
  PAbiArpEntry = ^TAbiArpEntry;

  TAbiSocketInformation = record
    Family: Word;
    Kind: Word;
    Protocol: Word;
    Reserved: Word;
    { TcpState* for TCP, 0 for the others. }
    State: LongWord;
    { The user who made it (0 for a connection that has no socket left). }
    OwnerUserId: LongWord;
    LocalAddress: TAbiSocketAddress;
    PeerAddress: TAbiSocketAddress;
    { Bytes waiting to be read, and sent but not yet acknowledged or
      not yet sent. }
    ReceiveQueued: LongWord;
    SendQueued: LongWord;
    { The process that made the socket, or accepted the connection (0
      for a connection that has no socket left). It may have ended
      since while a process it handed the socket to keeps it open. }
    OwnerProcessId: QWord;
  end;
  PAbiSocketInformation = ^TAbiSocketInformation;

  { Counters of IP. Nothing is forwarded yet, so Forwarded stays 0. }
  TAbiIpStatistics = record
    { Every datagram that arrived, the damaged ones included. }
    Received: QWord;
    { A bad version, length or header checksum. }
    HeaderErrors: QWord;
    { Not addressed to this machine (or from a broadcast or multicast
      source). }
    AddressErrors: QWord;
    UnknownProtocols: QWord;
    { Handed to ICMP, UDP or TCP. }
    Delivered: QWord;
    Forwarded: QWord;
    { Datagrams the protocols asked to send. }
    SendRequests: QWord;
    { Not sent: too large for the interface, or no memory. }
    SendDiscards: QWord;
    { Not sent: no route to the destination. }
    NoRoutes: QWord;
    { Fragments received, datagrams put together from them, and those
      that never were (timed out, or pushed out by newer ones). }
    ReassemblyFragments: QWord;
    Reassembled: QWord;
    ReassemblyFailures: QWord;
  end;

const
  { ICMP types counted one by one (0 to 18; larger ones are counted only
    in the totals). }
  IcmpTypesCounted = 19;

type
  TAbiIcmpStatistics = record
    Received: QWord;
    { Too short, or a bad checksum. }
    ReceiveErrors: QWord;
    Sent: QWord;
    SendErrors: QWord;
    ReceivedByType: array[0..IcmpTypesCounted - 1] of QWord;
    SentByType: array[0..IcmpTypesCounted - 1] of QWord;
  end;

  TAbiTcpStatistics = record
    { Connections begun by connect (CLOSED to SYN_SENT), and taken by
      listeners (LISTEN to SYN_RECEIVED). }
    ActiveOpens: QWord;
    PassiveOpens: QWord;
    { Connections that failed while being set up (SYN_SENT or
      SYN_RECEIVED to CLOSED). }
    FailedAttempts: QWord;
    { ESTABLISHED or CLOSE_WAIT ended at once: by a reset either way,
      or given up. }
    EstablishedResets: QWord;
    { Connections in ESTABLISHED or CLOSE_WAIT now. }
    CurrentlyEstablished: QWord;
    SegmentsReceived: QWord;
    { Retransmissions are counted apart, in SegmentsRetransmitted. }
    SegmentsSent: QWord;
    SegmentsRetransmitted: QWord;
    { Too short, or a bad checksum. }
    ReceiveErrors: QWord;
    ResetsSent: QWord;
  end;

  TAbiUdpStatistics = record
    { Delivered to a socket. }
    Received: QWord;
    { For a port no socket has. }
    NoPorts: QWord;
    { Damaged (lengths, checksum), or no room in the socket's queue. }
    ReceiveErrors: QWord;
    { Of the errors, those for want of room in a socket's queue. }
    ReceiveQueueErrors: QWord;
    Sent: QWord;
  end;

  { CallGetNetworkStatistics. }
  TAbiNetworkStatistics = record
    Ip: TAbiIpStatistics;
    Icmp: TAbiIcmpStatistics;
    Tcp: TAbiTcpStatistics;
    Udp: TAbiUdpStatistics;
  end;
  PAbiNetworkStatistics = ^TAbiNetworkStatistics;

  TAbiDnsServers = record
    Count: LongWord;
    Reserved: LongWord;
    Servers: array[0..MaximumDnsServers - 1] of TAbiSocketAddress;
    { The domain names without a dot are looked up in. }
    SearchDomain: array[0..DnsDomainCapacity - 1] of Char;
  end;
  PAbiDnsServers = ^TAbiDnsServers;
