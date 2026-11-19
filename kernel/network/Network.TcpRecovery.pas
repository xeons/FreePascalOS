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
  TCP loss recovery: what follows three duplicate acknowledgments.

  Recovery begins at the third duplicate acknowledgment, or - with SACK
  - as soon as the scoreboard says the first unacknowledged byte is lost
  (RFC 6675 IsLost), unless the acknowledgment is still below where the
  last recovery or timeout ended ("recover", RFC 6582: one reduction per
  window of loss). The slow start threshold becomes half the flight (at
  least two segments), the first unacknowledged segment is sent again
  at once, and recovery lasts until everything sent when it began is
  acknowledged.

  Without SACK it is NewReno (RFC 6582): the congestion window starts at
  the threshold plus three segments and grows a segment per further
  duplicate; a partial acknowledgment sends the next unacknowledged
  segment at once and deflates the window by what it acknowledged; the
  full acknowledgment sets it to the threshold (at most the flight plus
  a segment).

  With SACK it is RFC 6675's conservative recovery: the congestion
  window is the threshold, and while it exceeds the pipe (the bytes the
  scoreboard says are in the network) by a segment, the sender sends the
  next lost hole (NextSeg rule 1), else new data (rule 2), else a hole
  not yet known lost (rule 3) - only what is missing goes again.

  A timeout ends recovery and clears the scoreboard (RFC 2018 8: the
  receiver may have dropped what it SACKed).
}
unit Network.TcpRecovery;

{$mode objfpc}

interface

uses
  Network.TcpTypes;

{ An acknowledgment that acknowledged nothing new (NewlySacked: it SACKed
  something new). May begin recovery. }
procedure NoteDuplicateAcknowledgment(Connection: PTcpConnection; NewlySacked: Boolean);
{ During recovery, an acknowledgment of AckedBytes new bytes (the send
  buffer already trimmed): partial, or the end of recovery. }
procedure NoteRecoveryAcknowledgment(Connection: PTcpConnection; AckedBytes: LongWord);
{ With SACK during recovery: sends what the pipe allows of the holes.
  New data is left to TcpOutput, limited by SackRecoveryRoom. }
procedure SendDuringSackRecovery(Connection: PTcpConnection);
{ With SACK during recovery: how far the congestion window exceeds the
  pipe. }
function SackRecoveryRoom(Connection: PTcpConnection): LongWord;
{ The retransmission timer expired: recovery ends, the scoreboard is
  cleared, and "recover" moves to the highest byte sent. }
procedure AbandonRecovery(Connection: PTcpConnection);
{ The slow start threshold after a loss: half the flight, at least two
  segments. }
procedure LowerSlowStartThreshold(Connection: PTcpConnection);
{ Sends Length bytes from Sequence again (with the FIN if they reach
  it). }
procedure RetransmitStretch(Connection: PTcpConnection; Sequence, Length: LongWord);

implementation

uses
  Network.TcpSequences,
  Network.TcpScoreboard,
  Network.TcpSegments,
  Network.TcpOutput;

function Minimum(First, Second: LongWord): LongWord;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

procedure LowerSlowStartThreshold(Connection: PTcpConnection);
var
  Half: LongWord;
begin
  Half := InFlight(Connection) div 2;
  if Half < 2 * SenderSegmentSize(Connection) then
    Half := 2 * SenderSegmentSize(Connection);
  Connection^.SlowStartThreshold := Half;
end;

procedure RetransmitStretch(Connection: PTcpConnection; Sequence, Length: LongWord);
var
  Offset: LongWord;
  DataLength: LongWord;
  Flags: Byte;
begin
  Offset := SequenceDistance(Connection^.SendUnacknowledged, Sequence);
  DataLength := 0;
  if Offset < Connection^.SendBuffer.Count then
    DataLength := Minimum(Length, Connection^.SendBuffer.Count - Offset);
  Flags := 0;
  if FinIsSent(Connection) and SequenceAfter(Sequence + Length, Connection^.FinSequence) then
    Flags := TcpFlagFin;
  if (DataLength > 0) or (Flags <> 0) then
    SendConnectionSegment(Connection, Sequence, Flags, Offset, DataLength);
  Connection^.RetransmittedUpTo := LaterSequence(Connection^.RetransmittedUpTo, Sequence + Length);
end;

{ The first stretch to send when recovery begins: the first hole. }
procedure RetransmitFirstSegment(Connection: PTcpConnection);
var
  Sequence: LongWord;
  Length: LongWord;
  Size: LongWord;
begin
  Size := SenderSegmentSize(Connection);
  if not (Connection^.SackPermitted and NextRetransmission(Connection^.Scoreboard,
     Connection^.SendUnacknowledged, Connection^.SendUnacknowledged, Size, False, Sequence, Length)) then
  begin
    Sequence := Connection^.SendUnacknowledged;
    Length := Minimum(Size, InFlight(Connection));
  end;
  RetransmitStretch(Connection, Sequence, Length);
end;

procedure EnterLossRecovery(Connection: PTcpConnection);
begin
  LowerSlowStartThreshold(Connection);
  Connection^.InRecovery := True;
  Connection^.RecoveryPoint := Connection^.SendMaximum;
  Connection^.RetransmittedUpTo := Connection^.SendUnacknowledged;
  Connection^.IsTiming := False;
  if Connection^.SackPermitted then
    Connection^.CongestionWindow := Connection^.SlowStartThreshold
  else
    Connection^.CongestionWindow := Connection^.SlowStartThreshold + 3 * SenderSegmentSize(Connection);
  RetransmitFirstSegment(Connection);
  ArmRetransmitTimer(Connection);
end;

procedure NoteDuplicateAcknowledgment(Connection: PTcpConnection; NewlySacked: Boolean);
var
  LossIsKnown: Boolean;
begin
  if Connection^.InRecovery then
  begin
    { NewReno: each duplicate says a segment left the network. }
    if not Connection^.SackPermitted then
      Connection^.CongestionWindow := Connection^.CongestionWindow + SenderSegmentSize(Connection);
    Exit;
  end;
  Inc(Connection^.DuplicateAcks);
  LossIsKnown := Connection^.DuplicateAcks >= DuplicateThreshold;
  if Connection^.SackPermitted and NewlySacked and
     IsLost(Connection^.Scoreboard, Connection^.SendUnacknowledged, SenderSegmentSize(Connection)) then
    LossIsKnown := True;
  if LossIsKnown and SequenceAfterOrEqual(Connection^.SendUnacknowledged, Connection^.RecoveryPoint) then
    EnterLossRecovery(Connection);
end;

procedure LeaveRecovery(Connection: PTcpConnection);
var
  Size: LongWord;
  Flight: LongWord;
begin
  Connection^.InRecovery := False;
  Connection^.DuplicateAcks := 0;
  if Connection^.SackPermitted then
  begin
    Connection^.CongestionWindow := Connection^.SlowStartThreshold;
    Exit;
  end;
  { RFC 6582 3.2 step 3, the first option. }
  Size := SenderSegmentSize(Connection);
  Flight := InFlight(Connection);
  if Flight < Size then
    Flight := Size;
  Connection^.CongestionWindow := Minimum(Connection^.SlowStartThreshold, Flight + Size);
end;

procedure NoteRecoveryAcknowledgment(Connection: PTcpConnection; AckedBytes: LongWord);
var
  Size: LongWord;
begin
  if SequenceAfterOrEqual(Connection^.SendUnacknowledged, Connection^.RecoveryPoint) then
  begin
    LeaveRecovery(Connection);
    Exit;
  end;
  Connection^.RetransmittedUpTo := LaterSequence(Connection^.RetransmittedUpTo, Connection^.SendUnacknowledged);
  if Connection^.SackPermitted then
    Exit;
  { NewReno's partial acknowledgment: the next hole goes at once. }
  Size := SenderSegmentSize(Connection);
  RetransmitStretch(Connection, Connection^.SendUnacknowledged, Minimum(Size, InFlight(Connection)));
  if AckedBytes >= Connection^.CongestionWindow then
    Connection^.CongestionWindow := Size
  else
    Connection^.CongestionWindow := Connection^.CongestionWindow - AckedBytes;
  if AckedBytes >= Size then
    Connection^.CongestionWindow := Connection^.CongestionWindow + Size;
end;

function CurrentPipe(Connection: PTcpConnection): LongWord;
begin
  Result := ScoreboardPipe(Connection^.Scoreboard, Connection^.SendUnacknowledged, Connection^.SendMaximum,
    Connection^.RetransmittedUpTo, SenderSegmentSize(Connection));
end;

function SackRecoveryRoom(Connection: PTcpConnection): LongWord;
var
  Pipe: LongWord;
begin
  Pipe := CurrentPipe(Connection);
  if Pipe >= Connection^.CongestionWindow then
    Result := 0
  else
    Result := Connection^.CongestionWindow - Pipe;
end;

{ Rule 2 of NextSeg: whether new data could go now. }
function NewDataCanGo(Connection: PTcpConnection): Boolean;
var
  Offset: LongWord;
begin
  Offset := InFlight(Connection);
  Result := (Connection^.SendNext = Connection^.SendMaximum) and (Offset < Connection^.SendBuffer.Count) and
    (Offset < Connection^.SendWindow);
end;

procedure SendDuringSackRecovery(Connection: PTcpConnection);
var
  Size: LongWord;
  Sequence: LongWord;
  Length: LongWord;
  Sent: LongWord;
begin
  Size := SenderSegmentSize(Connection);
  Sent := 0;
  { Bounded: each turn sends a segment or stops. }
  while Sent < 4096 do
  begin
    if SackRecoveryRoom(Connection) < Size then
      Exit;
    if NextRetransmission(Connection^.Scoreboard, Connection^.SendUnacknowledged,
       Connection^.RetransmittedUpTo, Size, True, Sequence, Length) then
      RetransmitStretch(Connection, Sequence, Length)
    else if NewDataCanGo(Connection) then
      Exit
    else if NextRetransmission(Connection^.Scoreboard, Connection^.SendUnacknowledged,
       Connection^.RetransmittedUpTo, Size, False, Sequence, Length) then
      RetransmitStretch(Connection, Sequence, Length)
    else
      Exit;
    Inc(Sent);
  end;
end;

procedure AbandonRecovery(Connection: PTcpConnection);
begin
  Connection^.InRecovery := False;
  Connection^.DuplicateAcks := 0;
  Connection^.RecoveryPoint := Connection^.SendMaximum;
  Connection^.RetransmittedUpTo := Connection^.SendUnacknowledged;
  ClearScoreboard(Connection^.Scoreboard);
end;

end.
