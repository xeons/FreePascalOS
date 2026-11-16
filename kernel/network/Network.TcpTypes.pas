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
  TCP: the connection record and what every TCP unit shares.

  A connection lives apart from its socket: it is made by connect, by a
  listening socket for each SYN it accepts (a child, on its listener's
  queue until accepted), and it outlives its socket while it closes
  (FIN_WAIT, LAST_ACK, TIME_WAIT). Socket points back at the socket
  while there is one. The units:

    Network.TcpConnections  the table: making, finding, freeing
    Network.TcpSegments     segments: reading headers, building, RST
    Network.TcpInput        the state machine for arriving segments
    Network.TcpOutput       sending: windows, Nagle, retransmission, RTT
    Network.TcpTimers       retransmission, delayed ACKs, TIME_WAIT
    Network.TcpSockets      what sockets ask of it

  Sequence numbers wrap: SequenceBefore and friends compare them as
  RFC 793 does, by the sign of the 32-bit difference.
}
unit Network.TcpTypes;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Network.Addresses,
  Network.ByteRings,
  Network.Interfaces;

const
  TcpFlagFin = $01;
  TcpFlagSyn = $02;
  TcpFlagReset = $04;
  TcpFlagPush = $08;
  TcpFlagAck = $10;

  TcpHeaderBytes = 20;
  TcpMssOptionBytes = 4;
  { The MSS a peer that sends none is assumed to take (RFC 1122). }
  DefaultPeerMss = 536;
  SendBufferBytes = 64 * 1024;
  { The largest window without window scaling. }
  ReceiveBufferBytes = 65535;
  MaximumOutOfOrderSegments = 32;

  NanosecondsPerMillisecond = QWord(1000) * 1000;
  InitialRetransmissionTimeout = 1000 * NanosecondsPerMillisecond;
  MinimumRetransmissionTimeout = 200 * NanosecondsPerMillisecond;
  MaximumRetransmissionTimeout = 60000 * NanosecondsPerMillisecond;
  { Retransmissions before the connection is given up. }
  MaximumRetransmissions = 12;
  MaximumSynRetransmissions = 5;
  DelayedAckNanoseconds = 40 * NanosecondsPerMillisecond;
  { Twice the maximum segment lifetime (taken as 30 seconds). }
  TimeWaitNanoseconds = 60000 * NanosecondsPerMillisecond;
  { How long a connection whose socket is gone waits in FIN_WAIT_2. }
  OrphanFinWaitNanoseconds = 60000 * NanosecondsPerMillisecond;

type
  TTcpState = (TcpClosed, TcpListen, TcpSynSent, TcpSynReceived, TcpEstablished, TcpFinWait1,
    TcpFinWait2, TcpCloseWait, TcpClosing, TcpLastAck, TcpTimeWait);

  { A segment that arrived ahead of what is expected, kept until the gap
    is filled. Length bytes follow the record. }
  POutOfOrderSegment = ^TOutOfOrderSegment;
  TOutOfOrderSegment = record
    Link: TListEntry;
    Sequence: LongWord;
    Length: LongWord;
  end;

  PTcpConnection = ^TTcpConnection;
  TTcpConnection = record
    Link: TListEntry;
    State: TTcpState;
    { The socket (a PSocket) while there is one. }
    Socket: Pointer;
    Local: TNetworkEndpoint;
    Remote: TNetworkEndpoint;
    BoundInterface: PNetworkInterface;
    TimeToLive: Byte;
    NoDelay: Boolean;

    { A child: the listening connection it came from, until accepted. }
    Listener: PTcpConnection;
    AcceptLink: TListEntry;
    { A listener: children connected and waiting to be accepted, and
      how many children it has in all (connected or not). }
    AcceptQueue: TListEntry;
    AcceptQueueCount: LongWord;
    ChildCount: LongWord;
    Backlog: LongWord;

    { Sending. }
    InitialSendSequence: LongWord;
    SendUnacknowledged: LongWord;
    SendNext: LongWord;
    { The highest sequence number sent so far. }
    SendMaximum: LongWord;
    SendWindow: LongWord;
    SendWindowSequence: LongWord;
    SendWindowAcknowledgment: LongWord;
    { The largest segment we send (the peer's MSS, our MTU). }
    MaximumSegment: LongWord;
    CongestionWindow: LongWord;
    SlowStartThreshold: LongWord;
    DuplicateAcks: LongWord;
    { Bytes from the first unacknowledged one: sent and not yet
      acknowledged, then not yet sent. }
    SendBuffer: TByteRing;
    { Our FIN, once asked for, takes the sequence number after the last
      byte of data. }
    FinQueued: Boolean;
    FinSequence: LongWord;

    { Receiving. }
    InitialReceiveSequence: LongWord;
    ReceiveNext: LongWord;
    ReceiveBuffer: TByteRing;
    { The right edge of the window last advertised. }
    AdvertisedEdge: LongWord;
    FinReceived: Boolean;
    OutOfOrder: TListEntry;
    OutOfOrderCount: LongWord;

    { Timers, as NetworkNow times (0: not set). }
    RetransmitDeadline: QWord;
    RetransmitCount: LongWord;
    RetransmissionTimeout: QWord;
    SmoothedRoundTrip: QWord;
    RoundTripVariance: QWord;
    HasRoundTripSample: Boolean;
    { The segment being timed (Karn: never a retransmitted one). }
    IsTiming: Boolean;
    TimingSequence: LongWord;
    TimingStart: QWord;
    AckPending: Boolean;
    AckDeadline: QWord;
    SegmentsSinceAck: LongWord;
    { TIME_WAIT's end, or how long an orphan waits in FIN_WAIT_2. }
    CloseDeadline: QWord;

    { Why the connection failed (ErrorConnectionRefused, ...); reported
      to the socket once. }
    Error: LongInt;
    WasEstablished: Boolean;
  end;

function SequenceBefore(First, Second: LongWord): Boolean;
function SequenceBeforeOrEqual(First, Second: LongWord): Boolean;
function SequenceAfter(First, Second: LongWord): Boolean;
function SequenceAfterOrEqual(First, Second: LongWord): Boolean;
{ Abi.SystemCalls TcpState* for a state. }
function AbiTcpState(State: TTcpState): LongWord;
{ Whether data may still be sent and received in the state. }
function StateCanSend(State: TTcpState): Boolean;
function StateCanReceive(State: TTcpState): Boolean;

implementation

uses
  Abi.SystemCalls;

function SequenceBefore(First, Second: LongWord): Boolean;
begin
  Result := LongInt(First - Second) < 0;
end;

function SequenceBeforeOrEqual(First, Second: LongWord): Boolean;
begin
  Result := LongInt(First - Second) <= 0;
end;

function SequenceAfter(First, Second: LongWord): Boolean;
begin
  Result := LongInt(First - Second) > 0;
end;

function SequenceAfterOrEqual(First, Second: LongWord): Boolean;
begin
  Result := LongInt(First - Second) >= 0;
end;

function AbiTcpState(State: TTcpState): LongWord;
begin
  case State of
    TcpListen: Result := TcpStateListen;
    TcpSynSent: Result := TcpStateSynSent;
    TcpSynReceived: Result := TcpStateSynReceived;
    TcpEstablished: Result := TcpStateEstablished;
    TcpFinWait1: Result := TcpStateFinWait1;
    TcpFinWait2: Result := TcpStateFinWait2;
    TcpCloseWait: Result := TcpStateCloseWait;
    TcpClosing: Result := TcpStateClosing;
    TcpLastAck: Result := TcpStateLastAck;
    TcpTimeWait: Result := TcpStateTimeWait;
  else
    Result := TcpStateClosed;
  end;
end;

function StateCanSend(State: TTcpState): Boolean;
begin
  Result := State in [TcpEstablished, TcpCloseWait];
end;

function StateCanReceive(State: TTcpState): Boolean;
begin
  Result := State in [TcpEstablished, TcpFinWait1, TcpFinWait2];
end;

end.
