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
  Loss detection (RFC 9002 section 6 and appendix A): acknowledgements
  free sent packets (their stream and CRYPTO ranges count as delivered),
  give RTT samples and grow the congestion window; a packet is lost when
  one sent three packets later was acknowledged, or when it is 9/8 of
  an RTT older than an acknowledged one. Lost frames are queued again
  (data from the send buffers, control frames with current values).

  The loss detection timer is the earliest time threshold, else the
  probe timeout (PTO): smoothed RTT + 4 RTT variances (+ max_ack_delay
  for 1-RTT packets once the handshake is confirmed), doubled with each
  PTO in a row. When it fires, one or two probe packets go out in the
  space it was for, carrying the oldest data in flight again (or a
  PING); a client that has nothing in flight before the server has
  validated its address probes anyway, so the handshake cannot
  deadlock on the amplification limit.
}
unit Quic.LossRecovery;

{$mode objfpc}
{$H+}

interface

uses
  Quic.ConnectionState,
  Quic.Frames,
  Quic.SentPackets;

{ An ack-eliciting (or in-flight) packet was sent. }
procedure OnPacketSent(State: PQuicConnectionState; Space: Integer; Packet: PQuicSentPacket);
{ An ACK frame came in Space: 0, or a transport error code (an
  acknowledgement of a packet never sent). }
function OnAckReceived(State: PQuicConnectionState; Space: Integer; constref Frame: TQuicFrame; Now: Int64): QWord;
procedure SetLossDetectionTimer(State: PQuicConnectionState);
procedure OnLossDetectionTimeout(State: PQuicConnectionState; Now: Int64);
{ Drops a space's keys and everything in flight in it (RFC 9001
  section 4.9). }
procedure DiscardSpace(State: PQuicConnectionState; Space: Integer);
{ A Retry: everything sent in Initial packets is to go again in the new
  ones (the packets themselves are forgotten). }
procedure RequeueInitialPackets(State: PQuicConnectionState);
{ Whether ack-eliciting packets are in flight in any space. }
function AckElicitingInFlight(State: PQuicConnectionState): Boolean;

implementation

uses
  Quic.Congestion,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.PacketProtection,
  Quic.Streams,
  Quic.StreamTable;

procedure OnFrameAcknowledged(State: PQuicConnectionState; Space: Integer; constref Frame: TQuicSentFrame);
var
  Stream: PQuicStream;
  Received: ^TQuicPacketSpace;
  Index: Integer;
begin
  case Frame.Kind of
    SentStream:
      begin
        Stream := FindStream(State, Frame.Number);
        if Stream <> nil then
          Stream^.Send.OnAcknowledged(Frame.Offset, Frame.Length, Frame.Flag);
      end;
    SentCrypto:
      if not State^.Spaces[Space].Discarded then
        State^.Spaces[Space].CryptoSend.OnAcknowledged(Frame.Offset, Frame.Length, False);
    SentAck:
      begin
        { The peer has this ACK: no need to acknowledge the ranges below
          the one with its largest number again. }
        Received := @State^.Spaces[Space];
        Index := 0;
        while (Index < Received^.Received.Count) and (Received^.Received.Ranges[Index].Finish <= Frame.Number) do
          Inc(Index);
        if (Index > 0) and (Index < Received^.Received.Count) then
        begin
          if Received^.Received.Ranges[Index].Start > Received^.IgnoreBelow then
            Received^.IgnoreBelow := Received^.Received.Ranges[Index].Start;
          Received^.Received.Remove(0, Received^.IgnoreBelow);
        end;
      end;
    SentResetStream:
      begin
        Stream := FindStream(State, Frame.Number);
        if Stream <> nil then
          Stream^.ResetAcknowledged := True;
      end;
  end;
end;

procedure QueueRetire(State: PQuicConnectionState; Sequence: QWord);
var
  Count: Integer;
begin
  Count := Length(State^.RetireQueue);
  SetLength(State^.RetireQueue, Count + 1);
  State^.RetireQueue[Count] := Sequence;
end;

procedure OnFrameLost(State: PQuicConnectionState; Space: Integer; constref Frame: TQuicSentFrame);
var
  Stream: PQuicStream;
begin
  case Frame.Kind of
    SentStream:
      begin
        Stream := FindStream(State, Frame.Number);
        if (Stream <> nil) and not Stream^.ResetRequested then
          Stream^.Send.OnLost(Frame.Offset, Frame.Length, Frame.Flag);
      end;
    SentCrypto:
      if not State^.Spaces[Space].Discarded then
        State^.Spaces[Space].CryptoSend.OnLost(Frame.Offset, Frame.Length, False);
    SentMaxData:
      State^.MaxDataPending := True;
    SentMaxStreamData:
      begin
        Stream := FindStream(State, Frame.Number);
        if (Stream <> nil) and not Stream^.Receive.FinalSizeKnown then
          Stream^.MaxStreamDataPending := True;
      end;
    SentMaxStreams:
      if Frame.Flag then
        State^.MaxStreamsBidirectionalPending := True
      else
        State^.MaxStreamsUnidirectionalPending := True;
    SentResetStream:
      begin
        Stream := FindStream(State, Frame.Number);
        if Stream <> nil then
          Stream^.ResetPending := True;
      end;
    SentStopSending:
      begin
        Stream := FindStream(State, Frame.Number);
        if (Stream <> nil) and not Stream^.PeerReset and not Stream^.Receive.Finished then
          Stream^.StopSendingPending := True;
      end;
    SentHandshakeDone:
      State^.HandshakeDonePending := True;
    SentRetireConnectionId:
      QueueRetire(State, Frame.Number);
  end;
end;

function PeerCompletedAddressValidation(State: PQuicConnectionState): Boolean;
begin
  { A server's address needs no validation; a client knows the server
    has validated its address once a Handshake packet is acknowledged
    or the handshake is confirmed. }
  Result := (State^.Role = RoleServer) or State^.HandshakeConfirmed or
    (State^.Spaces[SpaceHandshake].LargestAcknowledged <> High(QWord));
end;

function SpaceHasAckElicitingInFlight(State: PQuicConnectionState; Space: Integer): Boolean;
var
  Index: Integer;
  Ring: ^TQuicSentPacketRing;
begin
  Ring := @State^.Spaces[Space].Sent;
  for Index := 0 to Ring^.Span - 1 do
    if Ring^.At(Index)^.InUse and Ring^.At(Index)^.AckEliciting then
      Exit(True);
  Result := False;
end;

function AckElicitingInFlight(State: PQuicConnectionState): Boolean;
var
  Space: Integer;
begin
  for Space := 0 to SpaceCount - 1 do
    if SpaceHasAckElicitingInFlight(State, Space) then
      Exit(True);
  Result := False;
end;

procedure OnPacketSent(State: PQuicConnectionState; Space: Integer; Packet: PQuicSentPacket);
begin
  if Packet^.InFlight then
  begin
    if Packet^.AckEliciting then
      State^.Spaces[Space].TimeOfLastAckEliciting := Packet^.TimeSent;
    OnPacketSentCongestion(State^.Congestion, Packet^.Size);
    SetLossDetectionTimer(State);
  end;
end;

{ The probe time of the earliest space with something in flight. }
function ProbeTimeAndSpace(State: PQuicConnectionState; out ProbeSpace: Integer): Int64;
var
  Duration, Candidate: Int64;
  Space: Integer;
begin
  ProbeSpace := SpaceInitial;
  Duration := ProbeTimeoutBase(State^.Rtt);
  if State^.ProbeCount > 0 then
    Duration := Duration shl State^.ProbeCount;
  if not AckElicitingInFlight(State) then
  begin
    { The client's anti-deadlock probe. }
    if State^.Spaces[SpaceHandshake].SendKeys.Ready then
      ProbeSpace := SpaceHandshake;
    Exit(QuicMilliseconds + Duration);
  end;
  Result := High(Int64);
  for Space := 0 to SpaceCount - 1 do
  begin
    if not SpaceHasAckElicitingInFlight(State, Space) then
      Continue;
    Candidate := Duration;
    if Space = SpaceApplication then
    begin
      { No 1-RTT probes until the handshake is confirmed. }
      if not State^.HandshakeConfirmed then
        Break;
      Candidate := Duration + (Int64(State^.PeerParameters.MaxAckDelay) shl State^.ProbeCount);
    end;
    Candidate := State^.Spaces[Space].TimeOfLastAckEliciting + Candidate;
    if Candidate < Result then
    begin
      Result := Candidate;
      ProbeSpace := Space;
    end;
  end;
  if Result = High(Int64) then
    Result := 0;
end;

function EarliestLossTime(State: PQuicConnectionState; out LossSpace: Integer): Int64;
var
  Space: Integer;
begin
  Result := 0;
  LossSpace := SpaceInitial;
  for Space := 0 to SpaceCount - 1 do
    if (State^.Spaces[Space].LossTime <> 0) and ((Result = 0) or (State^.Spaces[Space].LossTime < Result)) then
    begin
      Result := State^.Spaces[Space].LossTime;
      LossSpace := Space;
    end;
end;

procedure SetLossDetectionTimer(State: PQuicConnectionState);
var
  Space: Integer;
  LossTime: Int64;
begin
  LossTime := EarliestLossTime(State, Space);
  if LossTime <> 0 then
  begin
    State^.LossDetectionDeadline := LossTime;
    Exit;
  end;
  if not AckElicitingInFlight(State) and PeerCompletedAddressValidation(State) then
  begin
    State^.LossDetectionDeadline := 0;
    Exit;
  end;
  { A server would also stop here at the amplification limit; probes
    then wait for the client. }
  State^.LossDetectionDeadline := ProbeTimeAndSpace(State, Space);
end;

procedure DeclareLost(State: PQuicConnectionState; Space: Integer; Packet: PQuicSentPacket);
var
  Index: Integer;
begin
  for Index := 0 to Packet^.FrameCount - 1 do
    OnFrameLost(State, Space, Packet^.Frames[Index]);
  if Packet^.InFlight then
    RemoveFromFlight(State^.Congestion, Packet^.Size);
  if Packet^.IsPathMtuProbe then
    State^.PathMtu := PathMtuDone
  else
    Inc(State^.Statistics.PacketsLost);
  State^.Spaces[Space].Sent.MarkFree(Packet);
end;

procedure DetectLostPackets(State: PQuicConnectionState; Space: Integer; Now: Int64);
var
  LossDelay, LostSendTime, NewestLost, OldestLost, Duration: Int64;
  SpaceState: ^TQuicPacketSpace;
  Index: Integer;
  Packet: PQuicSentPacket;
  LostAny: Boolean;
  OldestNumber, NewestNumber: QWord;
begin
  SpaceState := @State^.Spaces[Space];
  SpaceState^.LossTime := 0;
  if SpaceState^.LargestAcknowledged = High(QWord) then
    Exit;
  LossDelay := State^.Rtt.LatestRtt;
  if State^.Rtt.SmoothedRtt > LossDelay then
    LossDelay := State^.Rtt.SmoothedRtt;
  LossDelay := (LossDelay * TimeThresholdNumerator) div TimeThresholdDenominator;
  if LossDelay < TimerGranularityMilliseconds then
    LossDelay := TimerGranularityMilliseconds;
  LostSendTime := Now - LossDelay;
  LostAny := False;
  NewestLost := 0;
  OldestLost := High(Int64);
  OldestNumber := High(QWord);
  NewestNumber := 0;
  Index := 0;
  while Index < SpaceState^.Sent.Span do
  begin
    Packet := SpaceState^.Sent.At(Index);
    Inc(Index);
    if not Packet^.InUse or (Packet^.PacketNumber > SpaceState^.LargestAcknowledged) then
      Continue;
    if (Packet^.TimeSent <= LostSendTime) or
       (SpaceState^.LargestAcknowledged >= Packet^.PacketNumber + PacketThreshold) then
    begin
      if not Packet^.IsPathMtuProbe and Packet^.InFlight then
      begin
        LostAny := True;
        if Packet^.TimeSent > NewestLost then
          NewestLost := Packet^.TimeSent;
        if Packet^.TimeSent < OldestLost then
          OldestLost := Packet^.TimeSent;
        if Packet^.PacketNumber < OldestNumber then
          OldestNumber := Packet^.PacketNumber;
        if Packet^.PacketNumber > NewestNumber then
          NewestNumber := Packet^.PacketNumber;
      end;
      DeclareLost(State, Space, Packet);
    end
    else if (SpaceState^.LossTime = 0) or (Packet^.TimeSent + LossDelay < SpaceState^.LossTime) then
      SpaceState^.LossTime := Packet^.TimeSent + LossDelay;
  end;
  SpaceState^.Sent.Compact;
  if not LostAny then
    Exit;
  OnCongestionEvent(State^.Congestion, NewestLost, Now);
  { Persistent congestion: losses over three PTOs, with an RTT known and
    nothing sent between them acknowledged (RFC 9002 section 7.6). }
  if State^.Rtt.HasSample and (NewestNumber > OldestNumber) and
     not SpaceState^.AcknowledgedSent.Overlaps(OldestNumber, NewestNumber + 1) then
  begin
    Duration := (ProbeTimeoutBase(State^.Rtt) + Int64(State^.PeerParameters.MaxAckDelay)) *
      PersistentCongestionThreshold;
    if NewestLost - OldestLost > Duration then
      OnPersistentCongestion(State^.Congestion);
  end;
end;

function PacketIsAcknowledged(constref Frame: TQuicFrame; PacketNumber: QWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Frame.AckRangeCount - 1 do
    if (PacketNumber >= Frame.AckRanges[Index].Smallest) and (PacketNumber <= Frame.AckRanges[Index].Largest) then
      Exit(True);
  Result := False;
end;

procedure OnPathMtuProbeAcknowledged(State: PQuicConnectionState; Packet: PQuicSentPacket);
begin
  State^.PathMtu := PathMtuDone;
  if Packet^.Size > State^.MaximumDatagramSize then
  begin
    State^.MaximumDatagramSize := Packet^.Size;
    State^.Congestion.DatagramSize := Packet^.Size;
  end;
end;

function OnAckReceived(State: PQuicConnectionState; Space: Integer; constref Frame: TQuicFrame; Now: Int64): QWord;
var
  SpaceState: ^TQuicPacketSpace;
  Index, FrameIndex: Integer;
  Packet: PQuicSentPacket;
  LargestNewly: QWord;
  LargestNewlyTime: Int64;
  LargestNewlyEliciting, NewlyAcknowledged, AnyEliciting: Boolean;
  AckDelay: Int64;
begin
  Result := 0;
  SpaceState := @State^.Spaces[Space];
  if Frame.LargestAcknowledged >= SpaceState^.NextPacketNumber then
    Exit(TransportProtocolViolation);
  if (SpaceState^.LargestAcknowledged = High(QWord)) or (Frame.LargestAcknowledged > SpaceState^.LargestAcknowledged) then
    SpaceState^.LargestAcknowledged := Frame.LargestAcknowledged;
  for Index := 0 to Frame.AckRangeCount - 1 do
    SpaceState^.AcknowledgedSent.Add(Frame.AckRanges[Index].Smallest, Frame.AckRanges[Index].Largest + 1);

  NewlyAcknowledged := False;
  AnyEliciting := False;
  LargestNewly := 0;
  LargestNewlyTime := 0;
  LargestNewlyEliciting := False;
  Index := 0;
  while Index < SpaceState^.Sent.Span do
  begin
    Packet := SpaceState^.Sent.At(Index);
    Inc(Index);
    if not Packet^.InUse or (Packet^.PacketNumber > Frame.LargestAcknowledged) or
       not PacketIsAcknowledged(Frame, Packet^.PacketNumber) then
      Continue;
    if not NewlyAcknowledged or (Packet^.PacketNumber > LargestNewly) then
    begin
      LargestNewly := Packet^.PacketNumber;
      LargestNewlyTime := Packet^.TimeSent;
      LargestNewlyEliciting := Packet^.AckEliciting;
    end;
    NewlyAcknowledged := True;
    if Packet^.AckEliciting then
      AnyEliciting := True;
    for FrameIndex := 0 to Packet^.FrameCount - 1 do
      OnFrameAcknowledged(State, Space, Packet^.Frames[FrameIndex]);
    if Packet^.IsPathMtuProbe then
      OnPathMtuProbeAcknowledged(State, Packet);
    if Packet^.InFlight then
      OnPacketAcknowledgedCongestion(State^.Congestion, Packet^.Size, Packet^.TimeSent);
    if (Space = SpaceApplication) and State^.KeyUpdateUnconfirmed and
       (Packet^.PacketNumber >= State^.FirstPacketOfPhase) then
      State^.KeyUpdateUnconfirmed := False;
    SpaceState^.Sent.MarkFree(Packet);
  end;
  SpaceState^.Sent.Compact;
  if not NewlyAcknowledged then
    Exit;
  if (LargestNewly = Frame.LargestAcknowledged) and LargestNewlyEliciting then
  begin
    AckDelay := 0;
    if Space = SpaceApplication then
      AckDelay := Int64((Frame.AckDelay shl State^.PeerParameters.AckDelayExponent) div 1000);
    UpdateRtt(State^.Rtt, Now - LargestNewlyTime, AckDelay, State^.HandshakeConfirmed,
      Int64(State^.PeerParameters.MaxAckDelay));
  end;
  DetectLostPackets(State, Space, Now);
  if PeerCompletedAddressValidation(State) and AnyEliciting then
    State^.ProbeCount := 0;
  SetLossDetectionTimer(State);
end;

{ Queues the frames of up to Count of the oldest packets in flight in
  Space again (the packets stay in flight): what a probe carries. }
procedure RequeueOldest(State: PQuicConnectionState; Space: Integer; Count: Integer);
var
  Index, FrameIndex, Done: Integer;
  Packet: PQuicSentPacket;
begin
  Done := 0;
  Index := 0;
  while (Index < State^.Spaces[Space].Sent.Span) and (Done < Count) do
  begin
    Packet := State^.Spaces[Space].Sent.At(Index);
    Inc(Index);
    if not Packet^.InUse or not Packet^.AckEliciting or Packet^.IsPathMtuProbe then
      Continue;
    for FrameIndex := 0 to Packet^.FrameCount - 1 do
      OnFrameLost(State, Space, Packet^.Frames[FrameIndex]);
    Inc(Done);
  end;
end;

procedure OnLossDetectionTimeout(State: PQuicConnectionState; Now: Int64);
var
  Space: Integer;
begin
  if EarliestLossTime(State, Space) <> 0 then
  begin
    DetectLostPackets(State, Space, Now);
    SetLossDetectionTimer(State);
    Exit;
  end;
  if not AckElicitingInFlight(State) then
  begin
    { Anti-deadlock: a client with nothing in flight. }
    if State^.Spaces[SpaceHandshake].SendKeys.Ready and not State^.Spaces[SpaceHandshake].Discarded then
      Space := SpaceHandshake
    else
      Space := SpaceInitial;
    State^.Spaces[Space].ProbesWanted := 1;
  end
  else
  begin
    ProbeTimeAndSpace(State, Space);
    State^.Spaces[Space].ProbesWanted := 2;
    RequeueOldest(State, Space, 2);
    { A client still in the handshake sends its Initial again too, in
      case the server lost it (it cannot have Handshake keys without
      it). }
    if (State^.Role = RoleClient) and (Space = SpaceHandshake) and not State^.Spaces[SpaceInitial].Discarded then
    begin
      RequeueOldest(State, SpaceInitial, 1);
      State^.Spaces[SpaceInitial].ProbesWanted := 1;
    end;
  end;
  Inc(State^.ProbeCount);
  SetLossDetectionTimer(State);
end;

procedure DiscardSpace(State: PQuicConnectionState; Space: Integer);
var
  Index: Integer;
  Packet: PQuicSentPacket;
begin
  if State^.Spaces[Space].Discarded then
    Exit;
  for Index := 0 to State^.Spaces[Space].Sent.Span - 1 do
  begin
    Packet := State^.Spaces[Space].Sent.At(Index);
    if Packet^.InUse and Packet^.InFlight then
      RemoveFromFlight(State^.Congestion, Packet^.Size);
  end;
  State^.Spaces[Space].Sent.Clear;
  WipePacketKeys(State^.Spaces[Space].SendKeys);
  WipePacketKeys(State^.Spaces[Space].ReceiveKeys);
  State^.Spaces[Space].Discarded := True;
  State^.Spaces[Space].LossTime := 0;
  State^.Spaces[Space].AckPending := False;
  State^.Spaces[Space].AckDeadline := 0;
  State^.Spaces[Space].ProbesWanted := 0;
  State^.Spaces[Space].CryptoSend.Release;
  State^.Spaces[Space].CryptoReceive.Release;
  State^.ProbeCount := 0;
  SetLossDetectionTimer(State);
end;

procedure RequeueInitialPackets(State: PQuicConnectionState);
var
  Index, FrameIndex: Integer;
  Packet: PQuicSentPacket;
begin
  for Index := 0 to State^.Spaces[SpaceInitial].Sent.Span - 1 do
  begin
    Packet := State^.Spaces[SpaceInitial].Sent.At(Index);
    if not Packet^.InUse then
      Continue;
    for FrameIndex := 0 to Packet^.FrameCount - 1 do
      OnFrameLost(State, SpaceInitial, Packet^.Frames[FrameIndex]);
    if Packet^.InFlight then
      RemoveFromFlight(State^.Congestion, Packet^.Size);
  end;
  State^.Spaces[SpaceInitial].Sent.Clear;
  State^.Spaces[SpaceInitial].LossTime := 0;
  SetLossDetectionTimer(State);
end;

end.
