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
  TCP: sending.

  TcpOutput sends what the windows allow: as much of the send buffer as
  fits in the smaller of the peer's window and the congestion window,
  in segments of at most the MSS, then the FIN once all the data has
  gone. A small segment waits while data is in flight (Nagle, RFC 896)
  unless SocketOptionNoDelay is set or it carries the FIN.

  Every segment sent is kept in the send buffer until acknowledged. The
  retransmission timer runs while anything is unacknowledged (RFC 6298
  5.1-5.3); when it expires, sending starts again from the first
  unacknowledged byte, the timeout doubles (up to a minute), the slow
  start threshold halves (on the first expiry only) and the congestion
  window falls back to one segment. Duplicate acknowledgments start loss
  recovery (Network.TcpRecovery: NewReno, or SACK-based). The timeout
  follows the measured round trip time (RFC 6298: the smoothed time plus
  four times its variance, at least 200 ms - Linux's floor rather than
  the RFC's second), measured once a round trip: from the echoed
  timestamp when timestamps are on (RFC 7323 4: retransmissions can be
  timed too), else on one segment at a time and never a retransmitted
  one (Karn). A SYN sent again leaves a timeout of at least 3 s for the
  data (RFC 6298 5.7). The congestion window grows by a segment per
  acknowledgment in slow start and by about a segment per round trip
  after (RFC 5681), never during recovery.

  Segments carry at most SenderSegmentSize bytes: the MSS less the
  timestamps option.

  A peer that advertises a zero window is probed with one byte each
  time the timer expires, so that a lost window update does not stall
  the connection - in every state with data still to send, closing ones
  too; a connection whose socket is gone gives up after
  MaximumOrphanZeroWindowProbes probes, answered or not, so that a peer
  that keeps its window shut cannot keep it for ever. Acknowledgments of received data are delayed up to
  40 ms, or sent at once for every second segment.
}
unit Network.TcpOutput;

{$mode objfpc}

interface

uses
  Network.TcpTypes;

procedure TcpOutput(Connection: PTcpConnection);
{ Sends an acknowledgment (with the window) now. }
procedure SendAckNow(Connection: PTcpConnection);
{ Data arrived: acknowledges it soon, or at once if Immediately or for
  every second segment. }
procedure ScheduleAck(Connection: PTcpConnection; Immediately: Boolean);
{ The peer acknowledged up to Acknowledgment, AckedBytes of data: the
  buffer is trimmed by the caller; this takes the round trip sample
  (from EchoedTimestamp, the segment's TSecr, when timestamps are on;
  0: none), grows the congestion window or moves recovery on, and sets
  the timer again. }
procedure NoteAcknowledgment(Connection: PTcpConnection; Acknowledgment, AckedBytes, EchoedTimestamp: LongWord);
{ The retransmission timer expired. True if the connection gave up and
  was freed (it had no socket). }
function RetransmissionTimerExpired(Connection: PTcpConnection): Boolean;
{ Sets up the congestion state of a connection that becomes
  synchronized. }
procedure InitializeCongestionState(Connection: PTcpConnection);
procedure ArmRetransmitTimer(Connection: PTcpConnection);
{ Bytes sent and not yet acknowledged. }
function InFlight(Connection: PTcpConnection): LongWord;
function FinIsSent(Connection: PTcpConnection): Boolean;
{ The segment size went down (a smaller path MTU): what is in flight is
  sent again from the first unacknowledged byte, in segments of the new
  size, without a congestion response (RFC 8201 5.4, RFC 1191). }
procedure ResendAfterSegmentSizeChange(Connection: PTcpConnection);

implementation

uses
  Abi.SystemCalls,
  Network.Core,
  Network.ByteRings,
  Network.TcpScoreboard,
  Network.TcpSegments,
  Network.TcpRecovery,
  Network.TcpStates;

const
  InitialWindowSegments = 10;
  MaximumCongestionWindow = 16 * 1024 * 1024;
  ClockGranularity = 1 * NanosecondsPerMillisecond;
  MaximumZeroWindowProbes = 60;

function Minimum(First, Second: LongWord): LongWord;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

procedure InitializeCongestionState(Connection: PTcpConnection);
begin
  Connection^.CongestionWindow := InitialWindowSegments * SenderSegmentSize(Connection);
  Connection^.SlowStartThreshold := MaximumCongestionWindow;
  Connection^.DuplicateAcks := 0;
  Connection^.InRecovery := False;
  Connection^.RecoveryPoint := Connection^.InitialSendSequence;
  Connection^.RetransmittedUpTo := Connection^.SendUnacknowledged;
  ClearScoreboard(Connection^.Scoreboard);
  Connection^.TimestampSampleMark := Connection^.SendNext;
  if Connection^.SynRetransmitted and (Connection^.RetransmissionTimeout < SynRetransmittedTimeout) then
    Connection^.RetransmissionTimeout := SynRetransmittedTimeout;
end;

procedure ArmRetransmitTimer(Connection: PTcpConnection);
begin
  Connection^.RetransmitDeadline := NetworkNow + Connection^.RetransmissionTimeout;
  RequestNetworkWakeAt(Connection^.RetransmitDeadline);
end;

function InFlight(Connection: PTcpConnection): LongWord;
begin
  Result := Connection^.SendNext - Connection^.SendUnacknowledged;
end;

{ SYN_SENT and SYN_RECEIVED: the SYN (with an ACK of theirs in
  SYN_RECEIVED), again after a timeout. }
procedure SendSynchronize(Connection: PTcpConnection);
begin
  if Connection^.SendNext <> Connection^.InitialSendSequence then
    Exit;
  SendConnectionSegment(Connection, Connection^.InitialSendSequence, TcpFlagSyn, 0, 0);
  Connection^.SendNext := Connection^.InitialSendSequence + 1;
  if SequenceAfter(Connection^.SendNext, Connection^.SendMaximum) then
    Connection^.SendMaximum := Connection^.SendNext;
  if Connection^.RetransmitCount = 0 then
  begin
    Connection^.IsTiming := True;
    Connection^.TimingSequence := Connection^.SendNext;
    Connection^.TimingStart := NetworkNow;
  end;
  ArmRetransmitTimer(Connection);
end;

function FinIsSent(Connection: PTcpConnection): Boolean;
begin
  Result := Connection^.FinQueued and SequenceAfter(Connection^.SendNext, Connection^.FinSequence);
end;

{ What the windows let go now: the peer's, and the congestion window
  less the flight (or, in SACK recovery, less the pipe). }
function UsableWindow(Connection: PTcpConnection): LongWord;
var
  PeerRoom: LongWord;
  CongestionRoom: LongWord;
begin
  if InFlight(Connection) >= Connection^.SendWindow then
    PeerRoom := 0
  else
    PeerRoom := Connection^.SendWindow - InFlight(Connection);
  if Connection^.InRecovery and Connection^.SackPermitted then
    CongestionRoom := SackRecoveryRoom(Connection)
  else if InFlight(Connection) >= Connection^.CongestionWindow then
    CongestionRoom := 0
  else
    CongestionRoom := Connection^.CongestionWindow - InFlight(Connection);
  Result := Minimum(PeerRoom, CongestionRoom);
end;

{ How many bytes to send next (0: nothing now), and whether the FIN
  goes with them. }
function NextSegmentLength(Connection: PTcpConnection; Offset: LongWord; out WithFin: Boolean): LongWord;
var
  Available: LongWord;
  Size: LongWord;
begin
  WithFin := False;
  Size := SenderSegmentSize(Connection);
  Available := Connection^.SendBuffer.Count - Offset;
  Result := Minimum(Minimum(Available, UsableWindow(Connection)), Size);
  WithFin := Connection^.FinQueued and (Result = Available);
  { Nagle: a small segment waits for what is in flight. }
  if (Result > 0) and (Result < Size) and not WithFin and
     (InFlight(Connection) > 0) and not Connection^.NoDelay then
    Result := 0;
  if (Result = 0) and (Available > 0) then
    WithFin := False;
end;

procedure TcpOutput(Connection: PTcpConnection);
var
  Offset: LongWord;
  Length: LongWord;
  WithFin: Boolean;
  Flags: Byte;
  SentAnything: Boolean;
begin
  case Connection^.State of
    TcpSynSent, TcpSynReceived:
      begin
        SendSynchronize(Connection);
        Exit;
      end;
    TcpEstablished, TcpCloseWait, TcpFinWait1, TcpClosing, TcpLastAck:
      ;
  else
    begin
      if Connection^.AckPending and (Connection^.State in [TcpFinWait2, TcpTimeWait]) then
        SendAckNow(Connection);
      Exit;
    end;
  end;

  if Connection^.InRecovery and Connection^.SackPermitted then
    SendDuringSackRecovery(Connection);
  SentAnything := False;
  while not FinIsSent(Connection) do
  begin
    Offset := InFlight(Connection);
    if Offset > Connection^.SendBuffer.Count then
      Break;
    Length := NextSegmentLength(Connection, Offset, WithFin);
    if (Length = 0) and not WithFin then
      Break;
    Flags := 0;
    if (Length > 0) and (Offset + Length = Connection^.SendBuffer.Count) then
      Flags := Flags or TcpFlagPush;
    if WithFin then
      Flags := Flags or TcpFlagFin;
    if not Connection^.IsTiming and not Connection^.Timestamps and (Length > 0) and
       (Connection^.SendNext = Connection^.SendMaximum) then
    begin
      Connection^.IsTiming := True;
      Connection^.TimingSequence := Connection^.SendNext + Length;
      Connection^.TimingStart := NetworkNow;
    end;
    SendConnectionSegment(Connection, Connection^.SendNext, Flags, Offset, Length);
    SentAnything := True;
    Connection^.SendNext := Connection^.SendNext + Length;
    if WithFin then
      Connection^.SendNext := Connection^.SendNext + 1;
    if SequenceAfter(Connection^.SendNext, Connection^.SendMaximum) then
      Connection^.SendMaximum := Connection^.SendNext;
    if Connection^.RetransmitDeadline = 0 then
      ArmRetransmitTimer(Connection);
  end;

  { A zero window: the timer probes it. }
  if (Connection^.SendWindow = 0) and (InFlight(Connection) = 0) and
     (Connection^.SendBuffer.Count > 0) and (Connection^.RetransmitDeadline = 0) then
    ArmRetransmitTimer(Connection);
  if not SentAnything and Connection^.AckPending and (Connection^.SegmentsSinceAck >= 2) then
    SendAckNow(Connection);
end;

procedure SendAckNow(Connection: PTcpConnection);
begin
  SendConnectionSegment(Connection, Connection^.SendNext, 0, 0, 0);
end;

procedure ScheduleAck(Connection: PTcpConnection; Immediately: Boolean);
begin
  Connection^.AckPending := True;
  Inc(Connection^.SegmentsSinceAck);
  if Immediately or (Connection^.SegmentsSinceAck >= 2) then
  begin
    SendAckNow(Connection);
    Exit;
  end;
  if Connection^.AckDeadline = 0 then
  begin
    Connection^.AckDeadline := NetworkNow + DelayedAckNanoseconds;
    RequestNetworkWakeAt(Connection^.AckDeadline);
  end;
end;

procedure TakeRoundTripSample(Connection: PTcpConnection; Sample: QWord);
var
  Difference: QWord;
  VarianceTerm: QWord;
begin
  if not Connection^.HasRoundTripSample then
  begin
    Connection^.SmoothedRoundTrip := Sample;
    Connection^.RoundTripVariance := Sample div 2;
    Connection^.HasRoundTripSample := True;
  end
  else
  begin
    if Sample > Connection^.SmoothedRoundTrip then
      Difference := Sample - Connection^.SmoothedRoundTrip
    else
      Difference := Connection^.SmoothedRoundTrip - Sample;
    Connection^.RoundTripVariance := (3 * Connection^.RoundTripVariance + Difference) div 4;
    Connection^.SmoothedRoundTrip := (7 * Connection^.SmoothedRoundTrip + Sample) div 8;
  end;
  VarianceTerm := 4 * Connection^.RoundTripVariance;
  if VarianceTerm < ClockGranularity then
    VarianceTerm := ClockGranularity;
  Connection^.RetransmissionTimeout := Connection^.SmoothedRoundTrip + VarianceTerm;
  if Connection^.RetransmissionTimeout < MinimumRetransmissionTimeout then
    Connection^.RetransmissionTimeout := MinimumRetransmissionTimeout;
  if Connection^.RetransmissionTimeout > MaximumRetransmissionTimeout then
    Connection^.RetransmissionTimeout := MaximumRetransmissionTimeout;
end;

procedure GrowCongestionWindow(Connection: PTcpConnection; AckedBytes: LongWord);
var
  Growth: LongWord;
  Size: LongWord;
begin
  Size := SenderSegmentSize(Connection);
  if Connection^.CongestionWindow < Connection^.SlowStartThreshold then
    Growth := Minimum(AckedBytes, Size)
  else
  begin
    Growth := (Size * Size) div Connection^.CongestionWindow;
    if Growth = 0 then
      Growth := 1;
  end;
  Connection^.CongestionWindow := Minimum(Connection^.CongestionWindow + Growth, MaximumCongestionWindow);
end;

{ RTTM (RFC 7323 4): the time since the timestamp the peer echoes, once
  a round trip. False if there was no such sample. }
function TakeTimestampSample(Connection: PTcpConnection; Acknowledgment, EchoedTimestamp: LongWord): Boolean;
var
  Elapsed: LongInt;
begin
  Result := False;
  if not Connection^.Timestamps or (EchoedTimestamp = 0) or
     SequenceBefore(Acknowledgment, Connection^.TimestampSampleMark) then
    Exit;
  Elapsed := LongInt(ConnectionTimestamp(Connection) - EchoedTimestamp);
  if Elapsed < 0 then
    Exit;
  TakeRoundTripSample(Connection, QWord(Elapsed) * NanosecondsPerMillisecond);
  Connection^.TimestampSampleMark := Connection^.SendMaximum;
  Result := True;
end;

procedure NoteAcknowledgment(Connection: PTcpConnection; Acknowledgment, AckedBytes, EchoedTimestamp: LongWord);
begin
  if TakeTimestampSample(Connection, Acknowledgment, EchoedTimestamp) then
    Connection^.IsTiming := False
  else if Connection^.IsTiming and SequenceAfterOrEqual(Acknowledgment, Connection^.TimingSequence) then
  begin
    Connection^.IsTiming := False;
    TakeRoundTripSample(Connection, NetworkNow - Connection^.TimingStart);
  end;
  Connection^.RetransmitCount := 0;
  if Connection^.InRecovery then
    NoteRecoveryAcknowledgment(Connection, AckedBytes)
  else
  begin
    Connection^.DuplicateAcks := 0;
    if AckedBytes > 0 then
      GrowCongestionWindow(Connection, AckedBytes);
  end;
  if Connection^.SendUnacknowledged = Connection^.SendNext then
    Connection^.RetransmitDeadline := 0
  else
    ArmRetransmitTimer(Connection);
end;

{ Gives the connection up; True if that freed it. }
function GiveUp(Connection: PTcpConnection; SendReset: Boolean): Boolean;
begin
  Result := Connection^.Socket = nil;
  CloseTcpConnection(Connection, ErrorTimedOut, SendReset);
end;

function ProbeZeroWindow(Connection: PTcpConnection): Boolean;
begin
  Result := False;
  Inc(Connection^.RetransmitCount);
  if Connection^.RetransmitCount > MaximumZeroWindowProbes then
    Exit(GiveUp(Connection, True));
  if Connection^.Socket = nil then
  begin
    Inc(Connection^.OrphanProbes);
    if Connection^.OrphanProbes > MaximumOrphanZeroWindowProbes then
      Exit(GiveUp(Connection, True));
  end;
  { One byte beyond the window: the peer answers with its window. }
  SendConnectionSegment(Connection, Connection^.SendNext, 0, 0, 1);
  Connection^.SendNext := Connection^.SendNext + 1;
  if SequenceAfter(Connection^.SendNext, Connection^.SendMaximum) then
    Connection^.SendMaximum := Connection^.SendNext;
  if Connection^.RetransmissionTimeout < MaximumRetransmissionTimeout div 2 then
    Connection^.RetransmissionTimeout := Connection^.RetransmissionTimeout * 2;
  ArmRetransmitTimer(Connection);
end;

function RetransmissionTimerExpired(Connection: PTcpConnection): Boolean;
var
  Limit: LongWord;
begin
  Result := False;
  Connection^.RetransmitDeadline := 0;
  if (Connection^.SendWindow = 0) and (InFlight(Connection) = 0) and (Connection^.SendBuffer.Count > 0) and
     (Connection^.State in [TcpEstablished, TcpCloseWait, TcpFinWait1, TcpClosing, TcpLastAck]) then
    Exit(ProbeZeroWindow(Connection));
  if InFlight(Connection) = 0 then
    Exit;
  if Connection^.State in [TcpSynSent, TcpSynReceived] then
    Limit := MaximumSynRetransmissions
  else
    Limit := MaximumRetransmissions;
  Inc(Connection^.RetransmitCount);
  if Connection^.RetransmitCount > Limit then
    Exit(GiveUp(Connection, Connection^.State <> TcpSynSent));
  if Connection^.State in [TcpSynSent, TcpSynReceived] then
    Connection^.SynRetransmitted := True
  else
  begin
    { RFC 5681 (4): the threshold is lowered once, not again for each
      expiry of the same loss. }
    if Connection^.RetransmitCount = 1 then
      LowerSlowStartThreshold(Connection);
    Connection^.CongestionWindow := SenderSegmentSize(Connection);
    AbandonRecovery(Connection);
  end;
  Connection^.DuplicateAcks := 0;
  Connection^.IsTiming := False;
  Connection^.SendNext := Connection^.SendUnacknowledged;
  Connection^.RetransmissionTimeout := Connection^.RetransmissionTimeout * 2;
  if Connection^.RetransmissionTimeout > MaximumRetransmissionTimeout then
    Connection^.RetransmissionTimeout := MaximumRetransmissionTimeout;
  TcpOutput(Connection);
end;

procedure ResendAfterSegmentSizeChange(Connection: PTcpConnection);
begin
  if (InFlight(Connection) = 0) or not (Connection^.State in [TcpEstablished, TcpCloseWait, TcpFinWait1,
     TcpClosing, TcpLastAck]) then
    Exit;
  AbandonRecovery(Connection);
  Connection^.IsTiming := False;
  Connection^.SendNext := Connection^.SendUnacknowledged;
  TcpOutput(Connection);
end;

end.
