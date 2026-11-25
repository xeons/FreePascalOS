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
  TCP: arriving segments (RFC 793, "Segment Arrives", with the
  corrections of RFC 1122 and RFC 5961's caution about resets).

  A segment for no connection is answered with a reset - unless a
  listener takes its port: a SYN then makes a child in SYN_RECEIVED,
  which answers with SYN-ACK and joins the accept queue once the
  handshake completes; only then does it get its buffers. A listener
  keeps to its backlog, and all listeners together to
  MaximumHalfOpenConnections children in SYN_RECEIVED: when there is no
  room, the listener's oldest half-open child gives way (a flood of
  SYNs pushes out its own), and with none to give way the SYN is
  dropped and the peer tries again. A SYN for a connection in TIME_WAIT
  whose sequence number (and timestamp) is beyond the old one's ends
  the old one and opens a new one (RFC 1122 4.2.2.13, RFC 6191).

  On a synchronized connection a segment must fall in the receive
  window (Network.TcpAcceptance; else it is answered with an ACK and
  dropped), and is trimmed to it. RFC 5961's defences against blind
  attacks: a reset ends the connection only at exactly RCV.NXT (one
  elsewhere in the window gets a challenge ACK), a SYN never resets it
  but gets a challenge ACK wherever it falls, and an acknowledgment of
  what was never sent, or older than the largest window the peer
  offered, gets one and goes no further; challenge ACKs are rate
  limited per connection (RFC 5961 7). The
  acknowledgment frees the send buffer, moves the closing states on
  (our FIN acknowledged) and updates the send window. Data in order
  goes to the receive buffer, and what waited out of order behind it
  follows; data ahead of what is expected waits (as much as the receive
  buffer holds) and is acknowledged at once with what is expected and,
  with SACK, the blocks of what waits (Network.TcpReceivedBlocks), so
  the peer resends only the gaps. A FIN in order ends the stream for the
  reader and moves to CLOSE_WAIT, CLOSING or TIME_WAIT.

  The handshake agrees on window scaling, SACK and timestamps: each is
  used only if both SYNs carry it. With timestamps, a segment whose
  TSval is older than the one last kept is dropped with an ACK (PAWS,
  RFC 7323 5), and TS.Recent follows segments up to the last
  acknowledgment sent (RFC 7323 4.3). SACK blocks of an acknowledgment
  go on the scoreboard; duplicate acknowledgments (or ones that SACK
  something new) move loss recovery on (Network.TcpRecovery). Anything
  that arrives counts as a sign of life for the keep-alives.
}
unit Network.TcpInput;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Ipv4,
  Network.IpDatagrams;

procedure TcpInput(constref Datagram: TIpDatagram; Payload: PByte; Length: LongWord);
{ A destination unreachable about a segment we sent (its endpoints as
  we sent it): while connecting, it ends the attempt with Error. }
procedure TcpReportError(constref Local, Remote: TNetworkEndpoint; Sequence: LongWord; Error: LongInt);
{ True if Sequence, quoted by an ICMP error about a segment we sent from
  Local to Remote, is one a connection between them has in flight
  (RFC 5927 4.1): the error is then about a real segment. }
function TcpQuotedSequenceIsValid(constref Local, Remote: TNetworkEndpoint; Sequence: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.LinkedList,
  Memory.KernelHeap,
  Abi.SystemCalls,
  Network.Core,
  Network.ByteRings,
  Network.Interfaces,
  Network.TcpTypes,
  Network.TcpOptions,
  Network.TcpWindows,
  Network.TcpScoreboard,
  Network.TcpReceivedBlocks,
  Network.TcpConnections,
  Network.TcpSegments,
  Network.TcpStates,
  Network.TcpOutput,
  Network.TcpRecovery,
  Network.TcpAcceptance,
  Network.TokenBuckets,
  Network.UnpredictableNumbers,
  Network.Statistics;

function Minimum(First, Second: LongWord): LongWord;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

function NegotiatedSegmentSize(constref Segment: TTcpSegment; Connection: PTcpConnection): LongWord;
var
  PeerMss: LongWord;
begin
  PeerMss := Segment.Options.MaximumSegment;
  if not Segment.Options.HasMaximumSegment or (PeerMss = 0) then
    PeerMss := DefaultPeerMss;
  Result := Minimum(PeerMss, OwnMaximumSegment(Connection^.Remote, Connection^.BoundInterface));
  if Result < 64 then
    Result := 64;
end;

{ What a SYN from the peer agrees to, of what the connection offers
  (a listener's child offers everything). }
procedure AgreeOnOptions(Connection: PTcpConnection; constref Segment: TTcpSegment);
begin
  Connection^.WindowScaling := Connection^.WindowScaling and Segment.Options.HasWindowScale;
  if Connection^.WindowScaling then
  begin
    Connection^.SendWindowShift := Segment.Options.WindowShift;
    Connection^.ReceiveWindowShift := OwnWindowShift;
  end
  else
  begin
    Connection^.SendWindowShift := 0;
    Connection^.ReceiveWindowShift := 0;
  end;
  Connection^.SackPermitted := Connection^.SackPermitted and Segment.Options.SackPermitted;
  Connection^.Timestamps := Connection^.Timestamps and Segment.Options.HasTimestamps;
  if Connection^.Timestamps then
  begin
    Connection^.TimestampRecent := Segment.Options.TimestampValue;
    Connection^.TimestampRecentTime := NetworkNow;
  end;
end;

{ A child takes its listener's options. }
procedure InheritFromListener(Child, Listener: PTcpConnection);
begin
  Child^.BoundInterface := Listener^.BoundInterface;
  Child^.TimeToLive := Listener^.TimeToLive;
  Child^.NoDelay := Listener^.NoDelay;
  Child^.KeepAlive := Listener^.KeepAlive;
  Child^.KeepAliveIdleSeconds := Listener^.KeepAliveIdleSeconds;
  Child^.KeepAliveIntervalSeconds := Listener^.KeepAliveIntervalSeconds;
  Child^.KeepAliveCount := Listener^.KeepAliveCount;
  Child^.RequestedReceiveBuffer := Listener^.RequestedReceiveBuffer;
  Child^.RequestedSendBuffer := Listener^.RequestedSendBuffer;
  Child^.DropEvery := Listener^.DropEvery;
  Child^.WindowScaling := True;
  Child^.SackPermitted := True;
  Child^.Timestamps := True;
end;

{ Sends an ACK that RFC 5961 calls for (or one for a segment that moves
  nothing), unless the connection sent its share of them already. }
procedure SendChallengeAck(Connection: PTcpConnection);
begin
  if TakeToken(Connection^.ChallengeAcks, NetworkNow) then
    SendAckNow(Connection);
end;

{ --- LISTEN --------------------------------------------------------------- }

{ True if Listener may take another child: there is room, or its
  oldest half-open child was pushed out to make some. }
function MakeRoomForChild(Listener: PTcpConnection): Boolean;
var
  Oldest: PTcpConnection;
begin
  if (Listener^.ChildCount < Listener^.Backlog) and (HalfOpenConnectionCount < MaximumHalfOpenConnections) then
    Exit(True);
  Oldest := OldestHalfOpenChild(Listener);
  if Oldest = nil then
    Exit(False);
  FreeTcpConnection(Oldest);
  Result := (Listener^.ChildCount < Listener^.Backlog) and (HalfOpenConnectionCount < MaximumHalfOpenConnections);
end;

procedure HandleListen(Listener: PTcpConnection; constref Datagram: TIpDatagram;
  constref Segment: TTcpSegment);
var
  Child: PTcpConnection;
begin
  if (Segment.Flags and TcpFlagReset) <> 0 then
    Exit;
  if (Segment.Flags and TcpFlagAck) <> 0 then
  begin
    SendResetFor(Datagram, Segment);
    Exit;
  end;
  if ((Segment.Flags and TcpFlagSyn) = 0) or not MakeRoomForChild(Listener) then
    Exit;
  Child := CreateTcpConnection;
  if Child = nil then
    Exit;
  InheritFromListener(Child, Listener);
  Child^.Local := DatagramDestination(Datagram, Segment.DestinationPort);
  Child^.Remote := DatagramSource(Datagram, Segment.SourcePort);
  Child^.Listener := Listener;
  Inc(Listener^.ChildCount);
  MarkHalfOpen(Child);
  Child^.InitialReceiveSequence := Segment.Sequence;
  Child^.ReceiveNext := Segment.Sequence + 1;
  Child^.SendWindow := Segment.Window;
  Child^.LargestSendWindow := Segment.Window;
  Child^.SendWindowSequence := Segment.Sequence;
  Child^.MaximumSegment := NegotiatedSegmentSize(Segment, Child);
  AgreeOnOptions(Child, Segment);
  Child^.InitialSendSequence := InitialSequenceFor(Child^.Local, Child^.Remote);
  Child^.TimestampOffset := TimestampOffsetFor(Child^.Local, Child^.Remote);
  Child^.SendUnacknowledged := Child^.InitialSendSequence;
  Child^.SendNext := Child^.InitialSendSequence;
  Child^.SendMaximum := Child^.InitialSendSequence;
  Child^.State := TcpSynReceived;
  Inc(NetworkStatistics.Tcp.PassiveOpens);
  TcpOutput(Child);
end;

{ --- SYN_SENT ------------------------------------------------------------- }

procedure HandleSynSent(Connection: PTcpConnection; constref Datagram: TIpDatagram;
  constref Segment: TTcpSegment);
var
  HasAck: Boolean;
begin
  HasAck := (Segment.Flags and TcpFlagAck) <> 0;
  if HasAck and (SequenceBeforeOrEqual(Segment.Acknowledgment, Connection^.InitialSendSequence) or
     SequenceAfter(Segment.Acknowledgment, Connection^.SendNext)) then
  begin
    SendResetFor(Datagram, Segment);
    Exit;
  end;
  if (Segment.Flags and TcpFlagReset) <> 0 then
  begin
    if HasAck then
      CloseTcpConnection(Connection, ErrorConnectionRefused, False);
    Exit;
  end;
  if (Segment.Flags and TcpFlagSyn) = 0 then
    Exit;
  Connection^.InitialReceiveSequence := Segment.Sequence;
  Connection^.ReceiveNext := Segment.Sequence + 1;
  Connection^.MaximumSegment := NegotiatedSegmentSize(Segment, Connection);
  AgreeOnOptions(Connection, Segment);
  Connection^.SendWindow := Segment.Window;
  Connection^.LargestSendWindow := Segment.Window;
  Connection^.SendWindowSequence := Segment.Sequence;
  Connection^.SendWindowAcknowledgment := Segment.Acknowledgment;
  if not HasAck then
  begin
    { Both sides opened at once: answer with SYN-ACK. }
    Connection^.SendNext := Connection^.InitialSendSequence;
    Connection^.RetransmitDeadline := 0;
    Connection^.State := TcpSynReceived;
    TcpOutput(Connection);
    Exit;
  end;
  Connection^.SendUnacknowledged := Segment.Acknowledgment;
  NoteAcknowledgment(Connection, Segment.Acknowledgment, 0, 0);
  InitializeCongestionState(Connection);
  EnterTcpState(Connection, TcpEstablished);
  SendAckNow(Connection);
end;

{ --- Synchronized states --------------------------------------------------- }

function SegmentIsAcceptable(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
begin
  Result := Network.TcpAcceptance.SegmentIsAcceptable(Segment.Sequence, SegmentSequenceLength(Segment),
    Connection^.ReceiveNext, ReceiveWindow(Connection));
end;

{ Cuts away what was received before and what lies beyond the window. }
procedure TrimToWindow(Connection: PTcpConnection; var Segment: TTcpSegment);
var
  Excess: LongWord;
  Skip: LongWord;
  WindowEnd: LongWord;
begin
  if SequenceBefore(Segment.Sequence, Connection^.ReceiveNext) then
  begin
    Excess := Connection^.ReceiveNext - Segment.Sequence;
    if (Segment.Flags and TcpFlagSyn) <> 0 then
    begin
      Segment.Flags := Segment.Flags and not TcpFlagSyn;
      Segment.Sequence := Segment.Sequence + 1;
      Dec(Excess);
    end;
    Skip := Minimum(Excess, Segment.DataLength);
    Segment.Data := Segment.Data + Skip;
    Segment.DataLength := Segment.DataLength - Skip;
    Segment.Sequence := Segment.Sequence + Skip;
    { The FIN came before as well. }
    if Excess > Skip then
      Segment.Flags := Segment.Flags and not TcpFlagFin;
  end;
  WindowEnd := Connection^.ReceiveNext + ReceiveWindow(Connection);
  if SequenceAfter(Segment.Sequence + Segment.DataLength, WindowEnd) then
  begin
    Segment.DataLength := WindowEnd - Segment.Sequence;
    Segment.Flags := Segment.Flags and not TcpFlagFin;
  end;
end;

{ True if the connection is gone (or must not look at the segment
  further). }
function HandleReset(Connection: PTcpConnection): Boolean;
begin
  case Connection^.State of
    TcpSynReceived:
      if Connection^.Listener <> nil then
        CloseTcpConnection(Connection, ErrorNone, False)
      else
        CloseTcpConnection(Connection, ErrorConnectionRefused, False);
    TcpEstablished, TcpFinWait1, TcpFinWait2, TcpCloseWait:
      CloseTcpConnection(Connection, ErrorConnectionReset, False);
  else
    CloseTcpConnection(Connection, ErrorNone, False);
  end;
  Result := True;
end;

function FinIsAcknowledged(Connection: PTcpConnection): Boolean;
begin
  Result := Connection^.FinQueued and SequenceAfter(Connection^.SendUnacknowledged, Connection^.FinSequence);
end;

procedure UpdateSendWindow(Connection: PTcpConnection; constref Segment: TTcpSegment);
begin
  if SequenceBefore(Connection^.SendWindowSequence, Segment.Sequence) or
     ((Connection^.SendWindowSequence = Segment.Sequence) and
      SequenceBeforeOrEqual(Connection^.SendWindowAcknowledgment, Segment.Acknowledgment)) then
  begin
    Connection^.SendWindow := SegmentWindow(Connection, Segment);
    if Connection^.SendWindow > Connection^.LargestSendWindow then
      Connection^.LargestSendWindow := Connection^.SendWindow;
    Connection^.SendWindowSequence := Segment.Sequence;
    Connection^.SendWindowAcknowledgment := Segment.Acknowledgment;
    { A peer that answers our probes is still there. }
    if Segment.Window = 0 then
      Connection^.RetransmitCount := 0;
  end;
end;

{ The acknowledgment of a segment on a synchronized connection. False if
  the rest of the segment must be dropped. }
{ The SACK blocks of an acknowledgment onto the scoreboard; True if they
  SACKed something new. }
function TakeSackBlocks(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
var
  Index: LongWord;
begin
  Result := False;
  if not Connection^.SackPermitted then
    Exit;
  Index := 0;
  while Index < Segment.Options.SackBlockCount do
  begin
    if AddSackBlock(Connection^.Scoreboard, Segment.Options.SackBlocks[Index].Start,
       Segment.Options.SackBlocks[Index].Finish, Connection^.SendUnacknowledged, Connection^.SendMaximum) then
      Result := True;
    Inc(Index);
  end;
end;

function EchoedTimestamp(constref Segment: TTcpSegment): LongWord;
begin
  if Segment.Options.HasTimestamps then
    Result := Segment.Options.TimestampEcho
  else
    Result := 0;
end;

function HandleAcknowledgment(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
var
  Acked: LongWord;
  DataAcked: LongWord;
  Acknowledgment: LongWord;
  NewlySacked: Boolean;
  IsDuplicate: Boolean;
begin
  Acknowledgment := Segment.Acknowledgment;
  if AcknowledgmentDisposition(Acknowledgment, Connection^.SendUnacknowledged, Connection^.SendMaximum,
     Connection^.LargestSendWindow) <> AcknowledgmentAcceptable then
  begin
    SendChallengeAck(Connection);
    Exit(False);
  end;
  Result := True;
  if SequenceAfter(Acknowledgment, Connection^.SendUnacknowledged) then
  begin
    Acked := Acknowledgment - Connection^.SendUnacknowledged;
    DataAcked := Acked;
    if Connection^.FinQueued and SequenceAfter(Acknowledgment, Connection^.FinSequence) then
      Dec(DataAcked);
    DataAcked := Minimum(DataAcked, Connection^.SendBuffer.Count);
    DiscardFromByteRing(Connection^.SendBuffer, DataAcked);
    Connection^.SendUnacknowledged := Acknowledgment;
    if SequenceBefore(Connection^.SendNext, Acknowledgment) then
      Connection^.SendNext := Acknowledgment;
    TrimScoreboard(Connection^.Scoreboard, Acknowledgment);
    TakeSackBlocks(Connection, Segment);
    UpdateSendWindow(Connection, Segment);
    NoteAcknowledgment(Connection, Acknowledgment, DataAcked, EchoedTimestamp(Segment));
    NotifyConnectionSocket(Connection);
  end
  else
  begin
    NewlySacked := (Acknowledgment = Connection^.SendUnacknowledged) and TakeSackBlocks(Connection, Segment);
    { RFC 5681's duplicate (nothing new, the same window), or one that
      SACKs something new (RFC 6675). }
    IsDuplicate := (Acknowledgment = Connection^.SendUnacknowledged) and (Segment.DataLength = 0) and
       ((Segment.Flags and (TcpFlagSyn or TcpFlagFin)) = 0) and
       (Connection^.SendNext <> Connection^.SendUnacknowledged) and
       ((SegmentWindow(Connection, Segment) = Connection^.SendWindow) or NewlySacked);
    if IsDuplicate then
      NoteDuplicateAcknowledgment(Connection, NewlySacked);
    if SequenceAfterOrEqual(Acknowledgment, Connection^.SendUnacknowledged) then
      UpdateSendWindow(Connection, Segment);
  end;
end;

{ What our FIN being acknowledged changes. True if the connection is
  gone. }
function AdvanceClosingStates(Connection: PTcpConnection): Boolean;
begin
  Result := False;
  if not FinIsAcknowledged(Connection) then
    Exit;
  case Connection^.State of
    TcpFinWait1:
      begin
        EnterTcpState(Connection, TcpFinWait2);
        if Connection^.Socket = nil then
        begin
          Connection^.CloseDeadline := NetworkNow + OrphanFinWaitNanoseconds;
          RequestNetworkWakeAt(Connection^.CloseDeadline);
        end;
      end;
    TcpClosing:
      EnterTimeWait(Connection);
    TcpLastAck:
      begin
        CloseTcpConnection(Connection, ErrorNone, False);
        Result := True;
      end;
  end;
end;

function OutOfOrderEntry(Entry: PListEntry): POutOfOrderSegment;
begin
  Result := POutOfOrderSegment(ContainingRecord(Entry, FieldOffset(POutOfOrderSegment(nil)^.Link)));
end;

{ The stretch of data waiting out of order, without a gap, that holds
  Sequence. False if no stored segment holds it. }
function OutOfOrderRunAround(Connection: PTcpConnection; Sequence: LongWord; out Start, Finish: LongWord): Boolean;
var
  Entry: PListEntry;
  Stored: POutOfOrderSegment;
  IsFirst: Boolean;
begin
  Result := False;
  Start := 0;
  Finish := 0;
  IsFirst := True;
  Entry := Connection^.OutOfOrder.Next;
  while Entry <> @Connection^.OutOfOrder do
  begin
    Stored := OutOfOrderEntry(Entry);
    if IsFirst or SequenceAfter(Stored^.Sequence, Finish) then
    begin
      if Result then
        Exit;
      Start := Stored^.Sequence;
      Finish := Stored^.Sequence + Stored^.Length;
      IsFirst := False;
    end
    else if SequenceAfter(Stored^.Sequence + Stored^.Length, Finish) then
      Finish := Stored^.Sequence + Stored^.Length;
    if SequenceAfterOrEqual(Sequence, Start) and SequenceBefore(Sequence, Finish) then
      Result := True;
    Entry := Entry^.Next;
  end;
end;

{ The run that holds a segment just stored leads the SACK blocks. }
procedure ReportOutOfOrder(Connection: PTcpConnection; Sequence: LongWord);
var
  Start: LongWord;
  Finish: LongWord;
begin
  if not Connection^.SackPermitted then
    Exit;
  if OutOfOrderRunAround(Connection, Sequence, Start, Finish) then
    RememberReceivedBlock(Connection^.ReceivedBlocks, Start, Finish);
end;

procedure StoreOutOfOrder(Connection: PTcpConnection; constref Segment: TTcpSegment);
var
  Entry: PListEntry;
  Existing: POutOfOrderSegment;
  Stored: POutOfOrderSegment;
begin
  if (Segment.DataLength = 0) or (Connection^.OutOfOrderCount >= MaximumOutOfOrderSegments) or
     (QWord(Connection^.OutOfOrderBytes) + Segment.DataLength > Connection^.ReceiveBuffer.Capacity) then
    Exit;
  { Kept in order of sequence; the same start twice is kept once. }
  Entry := Connection^.OutOfOrder.Next;
  while Entry <> @Connection^.OutOfOrder do
  begin
    Existing := POutOfOrderSegment(ContainingRecord(Entry, FieldOffset(POutOfOrderSegment(nil)^.Link)));
    if Existing^.Sequence = Segment.Sequence then
      Exit;
    if SequenceAfter(Existing^.Sequence, Segment.Sequence) then
      Break;
    Entry := Entry^.Next;
  end;
  Stored := POutOfOrderSegment(AllocateKernelMemory(SizeOf(TOutOfOrderSegment) + Segment.DataLength));
  if Stored = nil then
    Exit;
  Stored^.Sequence := Segment.Sequence;
  Stored^.Length := Segment.DataLength;
  CopyMemory(PByte(Stored) + SizeOf(TOutOfOrderSegment), Segment.Data, Segment.DataLength);
  InsertBefore(Entry, @Stored^.Link);
  Inc(Connection^.OutOfOrderCount);
  Connection^.OutOfOrderBytes := Connection^.OutOfOrderBytes + Segment.DataLength;
end;

{ Appends what waited out of order and now follows on. }
procedure TakeOutOfOrder(Connection: PTcpConnection);
var
  Entry: PListEntry;
  Stored: POutOfOrderSegment;
  Skip: LongWord;
  Accepted: LongWord;
begin
  Entry := FirstListEntry(Connection^.OutOfOrder);
  while Entry <> nil do
  begin
    Stored := POutOfOrderSegment(ContainingRecord(Entry, FieldOffset(POutOfOrderSegment(nil)^.Link)));
    if SequenceAfter(Stored^.Sequence, Connection^.ReceiveNext) then
      Exit;
    Skip := Connection^.ReceiveNext - Stored^.Sequence;
    if Skip < Stored^.Length then
    begin
      Accepted := AppendToByteRing(Connection^.ReceiveBuffer,
        PByte(Stored) + SizeOf(TOutOfOrderSegment) + Skip, Stored^.Length - Skip);
      Connection^.ReceiveNext := Connection^.ReceiveNext + Accepted;
    end;
    RemoveListEntry(Entry);
    Dec(Connection^.OutOfOrderCount);
    Connection^.OutOfOrderBytes := Connection^.OutOfOrderBytes - Stored^.Length;
    FreeKernelMemory(Stored);
    Entry := FirstListEntry(Connection^.OutOfOrder);
  end;
end;

{ The receiver's round trip (for growing the receive buffer): the time
  since the timestamp a data segment echoes, smoothed. }
procedure NoteReceiveRoundTrip(Connection: PTcpConnection; constref Segment: TTcpSegment);
var
  Elapsed: LongInt;
  Sample: QWord;
begin
  if not Connection^.Timestamps or not Segment.Options.HasTimestamps or (Segment.Options.TimestampEcho = 0) then
    Exit;
  Elapsed := LongInt(ConnectionTimestamp(Connection) - Segment.Options.TimestampEcho);
  if Elapsed < 0 then
    Exit;
  Sample := QWord(Elapsed) * NanosecondsPerMillisecond;
  if Connection^.ReceiveRoundTrip = 0 then
    Connection^.ReceiveRoundTrip := Sample
  else
    Connection^.ReceiveRoundTrip := (7 * Connection^.ReceiveRoundTrip + Sample) div 8;
end;

{ Data on a connection that may receive. False if the segment is ahead
  of what is expected (stored; its FIN not taken yet). }
function HandleData(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
var
  Accepted: LongWord;
  HadGap: Boolean;
begin
  if Segment.DataLength = 0 then
    Exit(Segment.Sequence = Connection^.ReceiveNext);
  NoteReceiveRoundTrip(Connection, Segment);
  if Segment.Sequence <> Connection^.ReceiveNext then
  begin
    StoreOutOfOrder(Connection, Segment);
    ReportOutOfOrder(Connection, Segment.Sequence);
    SendAckNow(Connection);
    Exit(False);
  end;
  HadGap := Connection^.OutOfOrderCount > 0;
  Accepted := AppendToByteRing(Connection^.ReceiveBuffer, Segment.Data, Segment.DataLength);
  Connection^.ReceiveNext := Connection^.ReceiveNext + Accepted;
  if HadGap then
    TakeOutOfOrder(Connection);
  ForgetReceivedBlocks(Connection^.ReceivedBlocks, Connection^.ReceiveNext);
  ScheduleAck(Connection, HadGap);
  NotifyConnectionSocket(Connection);
  Result := Accepted = Segment.DataLength;
end;

{ The peer's FIN, in order. True if the connection is gone. }
procedure HandleFin(Connection: PTcpConnection);
begin
  Connection^.ReceiveNext := Connection^.ReceiveNext + 1;
  Connection^.FinReceived := True;
  SendAckNow(Connection);
  case Connection^.State of
    TcpSynReceived, TcpEstablished:
      EnterTcpState(Connection, TcpCloseWait);
    TcpFinWait1:
      if FinIsAcknowledged(Connection) then
        EnterTimeWait(Connection)
      else
        EnterTcpState(Connection, TcpClosing);
    TcpFinWait2, TcpTimeWait:
      EnterTimeWait(Connection);
  else
    NotifyConnectionSocket(Connection);
  end;
end;

{ SYN_RECEIVED: the ACK that completes the handshake. False if the
  segment goes no further. }
function CompleteHandshake(Connection: PTcpConnection; constref Datagram: TIpDatagram;
  constref Segment: TTcpSegment): Boolean;
begin
  if not (SequenceAfter(Segment.Acknowledgment, Connection^.SendUnacknowledged) and
          SequenceBeforeOrEqual(Segment.Acknowledgment, Connection^.SendNext)) then
  begin
    SendResetFor(Datagram, Segment);
    Exit(False);
  end;
  { The buffers come with the connection's completion, not with its
    SYN. }
  if (Connection^.ReceiveBuffer.Data = nil) and not CreateConnectionBuffers(Connection) then
  begin
    CloseTcpConnection(Connection, ErrorOutOfMemory, True);
    Exit(False);
  end;
  ClearHalfOpen(Connection);
  Connection^.SendUnacknowledged := Segment.Acknowledgment;
  Connection^.SendWindow := SegmentWindow(Connection, Segment);
  if Connection^.SendWindow > Connection^.LargestSendWindow then
    Connection^.LargestSendWindow := Connection^.SendWindow;
  Connection^.SendWindowSequence := Segment.Sequence;
  Connection^.SendWindowAcknowledgment := Segment.Acknowledgment;
  NoteAcknowledgment(Connection, Segment.Acknowledgment, 0, 0);
  InitializeCongestionState(Connection);
  EnterTcpState(Connection, TcpEstablished);
  QueueForAccept(Connection);
  Result := True;
end;

{ The test hook (SocketOptionTestDropEvery): every Nth data segment is
  lost on the way. }
function DroppedForTest(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
begin
  Result := False;
  if (Connection^.DropEvery = 0) or (Segment.DataLength = 0) then
    Exit;
  Inc(Connection^.DropCounter);
  Result := (Connection^.DropCounter mod Connection^.DropEvery) = 0;
end;

{ PAWS (RFC 7323 5.3): True if the segment's timestamp is older than
  the one kept, so the segment is an old duplicate. }
function FailsPaws(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
begin
  Result := False;
  if not Connection^.Timestamps or not Segment.Options.HasTimestamps or
     ((Segment.Flags and TcpFlagReset) <> 0) then
    Exit;
  if not SequenceBefore(Segment.Options.TimestampValue, Connection^.TimestampRecent) then
    Exit;
  { Idle for more than 24 days: what was kept means nothing now. }
  if NetworkNow - Connection^.TimestampRecentTime > TimestampRecentLifetime then
  begin
    Connection^.TimestampRecent := Segment.Options.TimestampValue;
    Connection^.TimestampRecentTime := NetworkNow;
    Exit;
  end;
  Result := True;
end;

{ RFC 7323 4.3: keeps the timestamp of a segment that reaches back to
  our last acknowledgment, to echo it. }
procedure KeepRecentTimestamp(Connection: PTcpConnection; constref Segment: TTcpSegment);
begin
  if not Connection^.Timestamps or not Segment.Options.HasTimestamps then
    Exit;
  if SequenceAfterOrEqual(Segment.Options.TimestampValue, Connection^.TimestampRecent) and
     SequenceBeforeOrEqual(Segment.Sequence, Connection^.LastAckSent) then
  begin
    Connection^.TimestampRecent := Segment.Options.TimestampValue;
    Connection^.TimestampRecentTime := NetworkNow;
  end;
end;

{ RFC 1122 4.2.2.13 and RFC 6191: a SYN that may end a connection in
  TIME_WAIT and open a new one - beyond the old sequence numbers and, if
  both carry timestamps, the old timestamps. }
function IsReopeningSyn(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
begin
  Result := False;
  if (Connection^.State <> TcpTimeWait) or
     ((Segment.Flags and (TcpFlagSyn or TcpFlagAck or TcpFlagReset)) <> TcpFlagSyn) or
     not SequenceAfter(Segment.Sequence, Connection^.ReceiveNext) then
    Exit;
  if Connection^.Timestamps and Segment.Options.HasTimestamps and
     not SequenceAfter(Segment.Options.TimestampValue, Connection^.TimestampRecent) then
    Exit;
  Result := True;
end;

procedure HandleSynchronized(Connection: PTcpConnection; constref Datagram: TIpDatagram;
  Segment: TTcpSegment);
var
  InOrder: Boolean;
  HadData: Boolean;
begin
  if DroppedForTest(Connection, Segment) then
    Exit;
  { A sign of life for the keep-alives. }
  Connection^.LastReceived := NetworkNow;
  Connection^.KeepAliveProbes := 0;
  if FailsPaws(Connection, Segment) or not SegmentIsAcceptable(Connection, Segment) then
  begin
    { RFC 5961: a reset outside the window is dropped without a word;
      a SYN anywhere gets a challenge ACK. }
    if (Segment.Flags and TcpFlagReset) <> 0 then
      Exit;
    if (Segment.Flags and TcpFlagSyn) <> 0 then
      SendChallengeAck(Connection)
    else
      SendAckNow(Connection);
    Exit;
  end;
  if (Segment.Flags and TcpFlagReset) <> 0 then
  begin
    { Only a reset at exactly the expected sequence number is believed
      (RFC 5961 3.2); one elsewhere in the window gets a challenge ACK. }
    case ResetDisposition(Segment.Sequence, Connection^.ReceiveNext, ReceiveWindow(Connection)) of
      ResetAccepted: HandleReset(Connection);
      ResetChallenged: SendChallengeAck(Connection);
    end;
    Exit;
  end;
  if (Segment.Flags and TcpFlagSyn) <> 0 then
  begin
    { RFC 5961 4.2: never a reset for a SYN, whatever its sequence. }
    SendChallengeAck(Connection);
    Exit;
  end;
  KeepRecentTimestamp(Connection, Segment);
  HadData := Segment.DataLength > 0;
  TrimToWindow(Connection, Segment);
  if (Segment.Flags and TcpFlagAck) = 0 then
    Exit;
  if Connection^.State = TcpSynReceived then
    if not CompleteHandshake(Connection, Datagram, Segment) then
      Exit;
  if not HandleAcknowledgment(Connection, Segment) then
    Exit;
  if AdvanceClosingStates(Connection) then
    Exit;

  InOrder := True;
  if StateCanReceive(Connection^.State) then
  begin
    InOrder := HandleData(Connection, Segment);
    { Data that found no room (a zero window): the peer learns the
      window from the ACK. }
    if HadData and (Segment.DataLength = 0) then
      SendAckNow(Connection);
  end
  else if Segment.DataLength > 0 then
    { Data after the peer's FIN: nothing to do with it but say so. }
    SendAckNow(Connection);
  if InOrder and ((Segment.Flags and TcpFlagFin) <> 0) and
     (Segment.Sequence + Segment.DataLength = Connection^.ReceiveNext) and
     not Connection^.FinReceived then
    HandleFin(Connection)
  else if InOrder and ((Segment.Flags and TcpFlagFin) <> 0) and (Connection^.State = TcpTimeWait) then
  begin
    { The peer sent its FIN again: our ACK was lost. }
    SendAckNow(Connection);
    EnterTimeWait(Connection);
  end;
  TcpOutput(Connection);
end;

procedure TcpInput(constref Datagram: TIpDatagram; Payload: PByte; Length: LongWord);
var
  Segment: TTcpSegment;
  Connection: PTcpConnection;
  Listener: PTcpConnection;
begin
  if not ParseTcpSegment(Datagram, Payload, Length, Segment) then
  begin
    Inc(NetworkStatistics.Tcp.ReceiveErrors);
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  Inc(NetworkStatistics.Tcp.SegmentsReceived);
  if Datagram.IsBroadcast then
    Exit;
  Connection := FindTcpConnection(DatagramDestination(Datagram, Segment.DestinationPort),
    DatagramSource(Datagram, Segment.SourcePort));
  if (Connection <> nil) and IsReopeningSyn(Connection, Segment) and
     (FindTcpListener(DatagramDestination(Datagram, Segment.DestinationPort)) <> nil) then
  begin
    CloseTcpConnection(Connection, ErrorNone, False);
    Connection := nil;
  end;
  if Connection = nil then
  begin
    Listener := FindTcpListener(DatagramDestination(Datagram, Segment.DestinationPort));
    if Listener <> nil then
      HandleListen(Listener, Datagram, Segment)
    else
      SendResetFor(Datagram, Segment);
    Exit;
  end;
  if Connection^.State = TcpSynSent then
    HandleSynSent(Connection, Datagram, Segment)
  else
    HandleSynchronized(Connection, Datagram, Segment);
end;

procedure TcpReportError(constref Local, Remote: TNetworkEndpoint; Sequence: LongWord; Error: LongInt);
var
  Connection: PTcpConnection;
begin
  Connection := FindTcpConnection(Local, Remote);
  if (Connection = nil) or (Connection^.State <> TcpSynSent) then
    Exit;
  if SequenceBefore(Sequence, Connection^.SendUnacknowledged) or
     SequenceAfter(Sequence, Connection^.SendMaximum) then
    Exit;
  CloseTcpConnection(Connection, Error, False);
end;

function TcpQuotedSequenceIsValid(constref Local, Remote: TNetworkEndpoint; Sequence: LongWord): Boolean;
var
  Connection: PTcpConnection;
begin
  Connection := FindTcpConnection(Local, Remote);
  Result := (Connection <> nil) and SequenceAfterOrEqual(Sequence, Connection^.SendUnacknowledged) and
    SequenceBefore(Sequence, Connection^.SendMaximum);
end;

end.
