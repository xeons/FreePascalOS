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
    Network.TcpKeepAlive    keep-alive probes
    Network.TcpBuffers      buffers that grow, socket buffer sizes
    Network.TcpPathMtu      a smaller path MTU lowers the MSS
    Network.TcpSockets      what sockets ask of it
  and the pure ones the host test builds:
    Network.TcpSequences    sequence number comparisons
    Network.TcpOptions      options: MSS, window scale, SACK, timestamps
    Network.TcpWindows      window scaling and buffer growth arithmetic
    Network.TcpScoreboard   the sender's SACK scoreboard (RFC 6675)
    Network.TcpReceivedBlocks  the SACK blocks a receiver reports

  Sequence numbers wrap: SequenceBefore and friends compare them as
  RFC 793 does, by the sign of the 32-bit difference
  (Network.TcpSequences).
}
unit Network.TcpTypes;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Network.Addresses,
  Network.ByteRings,
  Network.Interfaces,
  Network.TcpScoreboard,
  Network.TcpReceivedBlocks;

const
  TcpFlagFin = $01;
  TcpFlagSyn = $02;
  TcpFlagReset = $04;
  TcpFlagPush = $08;
  TcpFlagAck = $10;

  TcpHeaderBytes = 20;
  { The MSS a peer that sends none is assumed to take (RFC 1122). }
  DefaultPeerMss = 536;
  { Segments kept out of order at most (and never more bytes than the
    receive buffer holds). }
  MaximumOutOfOrderSegments = 1024;

  NanosecondsPerMillisecond = QWord(1000) * 1000;
  InitialRetransmissionTimeout = 1000 * NanosecondsPerMillisecond;
  MinimumRetransmissionTimeout = 200 * NanosecondsPerMillisecond;
  MaximumRetransmissionTimeout = 60000 * NanosecondsPerMillisecond;
  { Retransmissions before the connection is given up. }
  MaximumRetransmissions = 12;
  MaximumSynRetransmissions = 5;
  DelayedAckNanoseconds = 40 * NanosecondsPerMillisecond;
  { RFC 6298 5.7: the timeout once data flows after a SYN was sent
    again. }
  SynRetransmittedTimeout = 3000 * NanosecondsPerMillisecond;
  { Twice the maximum segment lifetime (taken as 30 seconds). }
  TimeWaitNanoseconds = 60000 * NanosecondsPerMillisecond;
  { How long a connection whose socket is gone waits in FIN_WAIT_2. }
  OrphanFinWaitNanoseconds = 60000 * NanosecondsPerMillisecond;
  NanosecondsPerSecond = 1000 * NanosecondsPerMillisecond;
  { Keep-alives as Linux has them by default: the first probe after two
    hours of quiet, then every 75 seconds, nine unanswered and the
    connection is dropped. }
  DefaultKeepAliveIdleSeconds = 7200;
  DefaultKeepAliveIntervalSeconds = 75;
  DefaultKeepAliveCount = 9;
  { RFC 7323 5.5: a TS.Recent older than this is not used for PAWS. }
  TimestampRecentLifetime = QWord(24) * 24 * 3600 * NanosecondsPerSecond;

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
    { Keep-alives (SocketOptionKeepAlive and friends). }
    KeepAlive: Boolean;
    KeepAliveIdleSeconds: LongWord;
    KeepAliveIntervalSeconds: LongWord;
    KeepAliveCount: LongWord;
    { Buffer sizes a socket asked for (0: grow on their own). }
    RequestedReceiveBuffer: LongWord;
    RequestedSendBuffer: LongWord;
    { Test hook (SocketOptionTestDropEvery): every Nth data segment that
      arrives is dropped as if lost (0: none). }
    DropEvery: LongWord;
    DropCounter: LongWord;

    { What the handshake agreed (for a SYN_SENT connection: what its SYN
      offers). }
    WindowScaling: Boolean;
    { The peer's shift (applied to the windows it sends) and ours. }
    SendWindowShift: Byte;
    ReceiveWindowShift: Byte;
    SackPermitted: Boolean;
    Timestamps: Boolean;
    { RFC 7323: the timestamp to echo, when it was taken, and the
      acknowledgment last sent. }
    TimestampRecent: LongWord;
    TimestampRecentTime: QWord;
    LastAckSent: LongWord;
    { RTTM: a sample is taken from the echoed timestamp of the first
      acknowledgment that reaches this (once a round trip). }
    TimestampSampleMark: LongWord;

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
    { Loss recovery (NewReno, RFC 6582, or with SACK RFC 6675): under
      way until RecoveryPoint (the highest sequence sent when it began)
      is acknowledged; RecoveryPoint is also "recover" after a timeout.
      With SACK, holes below RetransmittedUpTo were sent again. }
    InRecovery: Boolean;
    RecoveryPoint: LongWord;
    RetransmittedUpTo: LongWord;
    Scoreboard: TSackScoreboard;
    { Segments sent again on this connection (SocketOptionTcpRetransmissions). }
    RetransmittedSegments: LongWord;
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
    OutOfOrderBytes: LongWord;
    { The SACK blocks our acknowledgments carry. }
    ReceivedBlocks: TReceivedBlocks;
    { Receive buffer tuning: bytes read since TuningStart; a round trip
      measured from the peer's echo of our timestamps. }
    TuningStart: QWord;
    TuningBytes: LongWord;
    ReceiveRoundTrip: QWord;

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
    SynRetransmitted: Boolean;
    AckPending: Boolean;
    AckDeadline: QWord;
    SegmentsSinceAck: LongWord;
    { TIME_WAIT's end, or how long an orphan waits in FIN_WAIT_2. }
    CloseDeadline: QWord;
    { Keep-alive: when to look again, probes unanswered, and when the
      peer last sent anything. }
    KeepAliveDeadline: QWord;
    KeepAliveProbes: LongWord;
    LastReceived: QWord;

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
  Abi.SystemCalls,
  Network.TcpSequences;

function SequenceBefore(First, Second: LongWord): Boolean;
begin
  Result := Network.TcpSequences.SequenceBefore(First, Second);
end;

function SequenceBeforeOrEqual(First, Second: LongWord): Boolean;
begin
  Result := Network.TcpSequences.SequenceBeforeOrEqual(First, Second);
end;

function SequenceAfter(First, Second: LongWord): Boolean;
begin
  Result := Network.TcpSequences.SequenceAfter(First, Second);
end;

function SequenceAfterOrEqual(First, Second: LongWord): Boolean;
begin
  Result := Network.TcpSequences.SequenceAfterOrEqual(First, Second);
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
