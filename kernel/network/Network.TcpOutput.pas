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
  retransmission timer runs while anything is unacknowledged; when it
  expires, sending starts again from the first unacknowledged byte, the
  timeout doubles (up to a minute) and the congestion window falls back
  to one segment. Three duplicate acknowledgments retransmit the first
  segment at once (fast retransmit). The timeout follows the measured
  round trip time (RFC 6298: the smoothed time plus four times its
  variance, at least 200 ms), measured on one segment at a time and
  never on a retransmitted one (Karn). The congestion window grows by a
  segment per acknowledgment in slow start and by about a segment per
  round trip after (RFC 5681).

  A peer that advertises a zero window is probed with one byte each
  time the timer expires, so that a lost window update does not stall
  the connection. Acknowledgments of received data are delayed up to
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
  buffer is trimmed by the caller; this takes the round trip sample,
  grows the congestion window and sets the timer again. }
procedure NoteAcknowledgment(Connection: PTcpConnection; Acknowledgment, AckedBytes: LongWord);
{ The third duplicate acknowledgment. }
procedure FastRetransmit(Connection: PTcpConnection);
{ The retransmission timer expired. True if the connection gave up and
  was freed (it had no socket). }
function RetransmissionTimerExpired(Connection: PTcpConnection): Boolean;
{ Sets up the congestion state of a connection that becomes
  synchronized. }
procedure InitializeCongestionState(Connection: PTcpConnection);

implementation

uses
  Abi.SystemCalls,
  Network.Core,
  Network.ByteRings,
  Network.TcpSegments,
  Network.TcpStates;

const
  InitialWindowSegments = 10;
  MaximumCongestionWindow = 1024 * 1024;
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
  Connection^.CongestionWindow := InitialWindowSegments * Connection^.MaximumSegment;
  Connection^.SlowStartThreshold := MaximumCongestionWindow;
  Connection^.DuplicateAcks := 0;
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

{ How many bytes to send next (0: nothing now), and whether the FIN
  goes with them. }
function NextSegmentLength(Connection: PTcpConnection; Offset: LongWord; out WithFin: Boolean): LongWord;
var
  Available: LongWord;
  Window: LongWord;
  Usable: LongWord;
begin
  WithFin := False;
  Available := Connection^.SendBuffer.Count - Offset;
  Window := Minimum(Connection^.SendWindow, Connection^.CongestionWindow);
  if InFlight(Connection) >= Window then
    Usable := 0
  else
    Usable := Window - InFlight(Connection);
  Result := Minimum(Minimum(Available, Usable), Connection^.MaximumSegment);
  WithFin := Connection^.FinQueued and (Result = Available);
  { Nagle: a small segment waits for what is in flight. }
  if (Result > 0) and (Result < Connection^.MaximumSegment) and not WithFin and
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
    if not Connection^.IsTiming and (Length > 0) and (Connection^.SendNext = Connection^.SendMaximum) then
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
begin
  if Connection^.CongestionWindow < Connection^.SlowStartThreshold then
    Growth := Minimum(AckedBytes, Connection^.MaximumSegment)
  else
  begin
    Growth := (Connection^.MaximumSegment * Connection^.MaximumSegment) div Connection^.CongestionWindow;
    if Growth = 0 then
      Growth := 1;
  end;
  Connection^.CongestionWindow := Minimum(Connection^.CongestionWindow + Growth, MaximumCongestionWindow);
end;

procedure NoteAcknowledgment(Connection: PTcpConnection; Acknowledgment, AckedBytes: LongWord);
begin
  if Connection^.IsTiming and SequenceAfterOrEqual(Acknowledgment, Connection^.TimingSequence) then
  begin
    Connection^.IsTiming := False;
    TakeRoundTripSample(Connection, NetworkNow - Connection^.TimingStart);
  end;
  Connection^.RetransmitCount := 0;
  Connection^.DuplicateAcks := 0;
  if AckedBytes > 0 then
    GrowCongestionWindow(Connection, AckedBytes);
  if Connection^.SendUnacknowledged = Connection^.SendNext then
    Connection^.RetransmitDeadline := 0
  else
    ArmRetransmitTimer(Connection);
end;

procedure HalveCongestionWindow(Connection: PTcpConnection);
var
  Half: LongWord;
begin
  Half := InFlight(Connection) div 2;
  if Half < 2 * Connection^.MaximumSegment then
    Half := 2 * Connection^.MaximumSegment;
  Connection^.SlowStartThreshold := Half;
end;

procedure FastRetransmit(Connection: PTcpConnection);
var
  Length: LongWord;
  Flags: Byte;
begin
  HalveCongestionWindow(Connection);
  Connection^.CongestionWindow := Connection^.SlowStartThreshold;
  Connection^.IsTiming := False;
  Length := Minimum(Minimum(InFlight(Connection), Connection^.MaximumSegment), Connection^.SendBuffer.Count);
  Flags := 0;
  if FinIsSent(Connection) and (Length = Connection^.SendBuffer.Count) then
    Flags := TcpFlagFin;
  if (Length > 0) or (Flags <> 0) then
    SendConnectionSegment(Connection, Connection^.SendUnacknowledged, Flags, 0, Length);
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
     StateCanSend(Connection^.State) then
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
  if not (Connection^.State in [TcpSynSent, TcpSynReceived]) then
  begin
    HalveCongestionWindow(Connection);
    Connection^.CongestionWindow := Connection^.MaximumSegment;
  end;
  Connection^.DuplicateAcks := 0;
  Connection^.IsTiming := False;
  Connection^.SendNext := Connection^.SendUnacknowledged;
  Connection^.RetransmissionTimeout := Connection^.RetransmissionTimeout * 2;
  if Connection^.RetransmissionTimeout > MaximumRetransmissionTimeout then
    Connection^.RetransmissionTimeout := MaximumRetransmissionTimeout;
  TcpOutput(Connection);
end;

end.
