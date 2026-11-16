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
  listener takes its port: a SYN then makes a child in SYN_RECEIVED
  (if the backlog has room; otherwise it is dropped and the peer tries
  again), which answers with SYN-ACK and joins the accept queue once
  the handshake completes.

  On a synchronized connection a segment must fall in the receive
  window (else it is answered with an ACK and dropped), and is trimmed
  to it. A reset ends the connection (refused while connecting, reset
  later); a SYN in the window is an error that resets it. The
  acknowledgment frees the send buffer, moves the closing states on
  (our FIN acknowledged) and updates the send window. Data in order
  goes to the receive buffer, and what waited out of order behind it
  follows; data ahead of what is expected waits (a few segments) and is
  acknowledged at once with what is expected, so the peer's fast
  retransmit fills the gap. A FIN in order ends the stream for the
  reader and moves to CLOSE_WAIT, CLOSING or TIME_WAIT.
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
  Network.TcpConnections,
  Network.TcpSegments,
  Network.TcpStates,
  Network.TcpOutput,
  Network.Statistics;

const
  DuplicateAcksForFastRetransmit = 3;

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
  PeerMss := Segment.PeerMss;
  if PeerMss = 0 then
    PeerMss := DefaultPeerMss;
  Result := Minimum(PeerMss, OwnMaximumSegment(Connection^.Remote, Connection^.BoundInterface));
  if Result < 64 then
    Result := 64;
end;

{ --- LISTEN --------------------------------------------------------------- }

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
  if ((Segment.Flags and TcpFlagSyn) = 0) or (Listener^.ChildCount >= Listener^.Backlog) then
    Exit;
  Child := CreateTcpConnection;
  if Child = nil then
    Exit;
  if not CreateConnectionBuffers(Child) then
  begin
    FreeTcpConnection(Child);
    Exit;
  end;
  Child^.Local := DatagramDestination(Datagram, Segment.DestinationPort);
  Child^.Remote := DatagramSource(Datagram, Segment.SourcePort);
  Child^.BoundInterface := Listener^.BoundInterface;
  Child^.TimeToLive := Listener^.TimeToLive;
  Child^.NoDelay := Listener^.NoDelay;
  Child^.Listener := Listener;
  Inc(Listener^.ChildCount);
  Child^.InitialReceiveSequence := Segment.Sequence;
  Child^.ReceiveNext := Segment.Sequence + 1;
  Child^.SendWindow := Segment.Window;
  Child^.SendWindowSequence := Segment.Sequence;
  Child^.MaximumSegment := NegotiatedSegmentSize(Segment, Child);
  Child^.InitialSendSequence := GenerateInitialSequence;
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
  Connection^.SendWindow := Segment.Window;
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
  NoteAcknowledgment(Connection, Segment.Acknowledgment, 0);
  InitializeCongestionState(Connection);
  EnterTcpState(Connection, TcpEstablished);
  SendAckNow(Connection);
end;

{ --- Synchronized states --------------------------------------------------- }

function SegmentIsAcceptable(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
var
  Window: LongWord;
  Length: LongWord;
  WindowEnd: LongWord;
begin
  Window := ReceiveWindow(Connection);
  Length := SegmentSequenceLength(Segment);
  WindowEnd := Connection^.ReceiveNext + Window;
  if Length = 0 then
  begin
    if Window = 0 then
      Exit(Segment.Sequence = Connection^.ReceiveNext);
    Exit(SequenceAfterOrEqual(Segment.Sequence, Connection^.ReceiveNext) and
      SequenceBefore(Segment.Sequence, WindowEnd));
  end;
  if Window = 0 then
    Exit(False);
  Result := (SequenceAfterOrEqual(Segment.Sequence, Connection^.ReceiveNext) and
      SequenceBefore(Segment.Sequence, WindowEnd)) or
    (SequenceAfterOrEqual(Segment.Sequence + Length - 1, Connection^.ReceiveNext) and
      SequenceBefore(Segment.Sequence + Length - 1, WindowEnd));
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
    Connection^.SendWindow := Segment.Window;
    Connection^.SendWindowSequence := Segment.Sequence;
    Connection^.SendWindowAcknowledgment := Segment.Acknowledgment;
    { A peer that answers our probes is still there. }
    if Segment.Window = 0 then
      Connection^.RetransmitCount := 0;
  end;
end;

{ The acknowledgment of a segment on a synchronized connection. False if
  the rest of the segment must be dropped. }
function HandleAcknowledgment(Connection: PTcpConnection; constref Segment: TTcpSegment): Boolean;
var
  Acked: LongWord;
  DataAcked: LongWord;
  Acknowledgment: LongWord;
begin
  Acknowledgment := Segment.Acknowledgment;
  if SequenceAfter(Acknowledgment, Connection^.SendMaximum) then
  begin
    SendAckNow(Connection);
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
    UpdateSendWindow(Connection, Segment);
    NoteAcknowledgment(Connection, Acknowledgment, DataAcked);
    NotifyConnectionSocket(Connection);
  end
  else
  begin
    if (Acknowledgment = Connection^.SendUnacknowledged) and (Segment.DataLength = 0) and
       ((Segment.Flags and (TcpFlagSyn or TcpFlagFin)) = 0) and (Segment.Window = Connection^.SendWindow) and
       (Connection^.SendNext <> Connection^.SendUnacknowledged) then
    begin
      Inc(Connection^.DuplicateAcks);
      if Connection^.DuplicateAcks = DuplicateAcksForFastRetransmit then
        FastRetransmit(Connection);
    end;
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

procedure StoreOutOfOrder(Connection: PTcpConnection; constref Segment: TTcpSegment);
var
  Entry: PListEntry;
  Existing: POutOfOrderSegment;
  Stored: POutOfOrderSegment;
begin
  if (Segment.DataLength = 0) or (Connection^.OutOfOrderCount >= MaximumOutOfOrderSegments) then
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
    FreeKernelMemory(Stored);
    Entry := FirstListEntry(Connection^.OutOfOrder);
  end;
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
  if Segment.Sequence <> Connection^.ReceiveNext then
  begin
    StoreOutOfOrder(Connection, Segment);
    SendAckNow(Connection);
    Exit(False);
  end;
  HadGap := Connection^.OutOfOrderCount > 0;
  Accepted := AppendToByteRing(Connection^.ReceiveBuffer, Segment.Data, Segment.DataLength);
  Connection^.ReceiveNext := Connection^.ReceiveNext + Accepted;
  if HadGap then
    TakeOutOfOrder(Connection);
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
  Connection^.SendUnacknowledged := Segment.Acknowledgment;
  Connection^.SendWindow := Segment.Window;
  Connection^.SendWindowSequence := Segment.Sequence;
  Connection^.SendWindowAcknowledgment := Segment.Acknowledgment;
  NoteAcknowledgment(Connection, Segment.Acknowledgment, 0);
  InitializeCongestionState(Connection);
  EnterTcpState(Connection, TcpEstablished);
  QueueForAccept(Connection);
  Result := True;
end;

procedure HandleSynchronized(Connection: PTcpConnection; constref Datagram: TIpDatagram;
  Segment: TTcpSegment);
var
  InOrder: Boolean;
begin
  if not SegmentIsAcceptable(Connection, Segment) then
  begin
    if (Segment.Flags and TcpFlagReset) = 0 then
      SendAckNow(Connection);
    Exit;
  end;
  TrimToWindow(Connection, Segment);
  if (Segment.Flags and TcpFlagReset) <> 0 then
  begin
    { Only a reset at exactly the expected sequence number is believed
      at once (RFC 5961); one elsewhere in the window gets an ACK. }
    if Segment.Sequence = Connection^.ReceiveNext then
      HandleReset(Connection)
    else
      SendAckNow(Connection);
    Exit;
  end;
  if (Segment.Flags and TcpFlagSyn) <> 0 then
  begin
    CloseTcpConnection(Connection, ErrorConnectionReset, True);
    Exit;
  end;
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
    InOrder := HandleData(Connection, Segment)
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

end.
