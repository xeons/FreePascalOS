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
  What the frames of a received packet do (RFC 9000 section 19). Only
  PADDING, PING, ACK, CRYPTO and the transport CONNECTION_CLOSE may come
  in Initial and Handshake packets; anything else there, a frame that
  does not parse, or one that breaks a rule (a stream that cannot carry
  it, data beyond a limit, a final size that changes, HANDSHAKE_DONE or
  NEW_TOKEN sent to a server) closes the connection with the matching
  transport error.

  CRYPTO data of the 1-RTT level (NewSessionTicket) is read and dropped:
  there is no resumption over QUIC here.
}
unit Quic.FrameHandling;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Quic.ConnectionState;

{ The frames of one packet's payload. False when the connection is
  closing because of them; AckEliciting tells whether the packet asks
  for an acknowledgement. }
function HandleFrames(State: PQuicConnectionState; Space: Integer; Payload: PByte; Length: PtrUInt; Now: Int64;
  out AckEliciting: Boolean): Boolean;

implementation

uses
  SysUtils,
  Quic.Buffers,
  Quic.ConnectionIds,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.Frames,
  Quic.LossRecovery,
  Quic.ReceiveBuffers,
  Quic.Streams,
  Quic.StreamTable;

function Violation(State: PQuicConnectionState; Code, FrameType: QWord; const Reason: string): Boolean;
begin
  CloseWithTransportError(State, Code, FrameType, Reason, QuicErrorProtocolViolation);
  Result := False;
end;

function HandleCrypto(State: PQuicConnectionState; Space: Integer; constref Frame: TQuicFrame): Boolean;
var
  Receive: ^TQuicReceiveBuffer;
  Scratch: array[0..1023] of Byte;
begin
  Receive := @State^.Spaces[Space].CryptoReceive;
  case Receive^.Insert(Frame.Offset, Frame.Data, Frame.DataLength, False) of
    InsertBeyondLimit:
      Exit(Violation(State, TransportCryptoBufferExceeded, FrameCrypto, 'too much CRYPTO data'));
    InsertFinalSizeError:
      Exit(Violation(State, TransportProtocolViolation, FrameCrypto, 'bad CRYPTO data'));
  end;
  if Space = SpaceApplication then
    while Receive^.Read(@Scratch[0], SizeOf(Scratch)) > 0 do
      ;
  Result := True;
end;

function StreamFor(State: PQuicConnectionState; constref Frame: TQuicFrame; out Stream: PQuicStream): Boolean;
var
  Code: QWord;
begin
  Stream := StreamForFrame(State, Frame.StreamId, Code);
  if (Stream = nil) and (Code <> 0) then
    Exit(Violation(State, Code, Frame.FrameType, 'frame for a stream that cannot be open'));
  Result := True;
end;

function HandleStream(State: PQuicConnectionState; constref Frame: TQuicFrame): Boolean;
var
  Stream: PQuicStream;
  Highest: QWord;
begin
  if not StreamFor(State, Frame, Stream) then
    Exit(False);
  if Stream = nil then
    Exit(True);
  if not Stream^.CanReceive then
    Exit(Violation(State, TransportStreamStateError, Frame.FrameType, 'STREAM on a send-only stream'));
  if Stream^.PeerReset then
    Exit(True);
  Highest := Frame.Offset + Frame.DataLength;
  if Highest > Stream^.ReceiveLimit then
    Exit(Violation(State, TransportFlowControlError, Frame.FrameType, 'stream data beyond its limit'));
  if not NoteStreamDataReceived(State, Stream, Highest) then
    Exit(Violation(State, TransportFlowControlError, Frame.FrameType, 'data beyond the connection limit'));
  case Stream^.Receive.Insert(Frame.Offset, Frame.Data, Frame.DataLength, Frame.Fin) of
    InsertBeyondLimit:
      Exit(Violation(State, TransportFlowControlError, Frame.FrameType, 'stream data beyond its window'));
    InsertFinalSizeError:
      Exit(Violation(State, TransportFinalSizeError, Frame.FrameType, 'stream data beyond its final size'));
  end;
  Result := True;
end;

function HandleResetStream(State: PQuicConnectionState; constref Frame: TQuicFrame): Boolean;
var
  Stream: PQuicStream;
begin
  if not StreamFor(State, Frame, Stream) then
    Exit(False);
  if Stream = nil then
    Exit(True);
  if not Stream^.CanReceive then
    Exit(Violation(State, TransportStreamStateError, FrameResetStream, 'RESET_STREAM on a send-only stream'));
  if Frame.FinalSize > Stream^.ReceiveLimit then
    Exit(Violation(State, TransportFlowControlError, FrameResetStream, 'final size beyond the limit'));
  if not NoteStreamDataReceived(State, Stream, Frame.FinalSize) then
    Exit(Violation(State, TransportFlowControlError, FrameResetStream, 'final size beyond the connection limit'));
  if Stream^.Receive.SetFinalSize(Frame.FinalSize) <> InsertAccepted then
    Exit(Violation(State, TransportFinalSizeError, FrameResetStream, 'the final size changed'));
  if Frame.FinalSize > Stream^.Receive.HighestOffset then
    Stream^.Receive.HighestOffset := Frame.FinalSize;
  if not Stream^.PeerReset then
  begin
    Stream^.PeerReset := True;
    Stream^.PeerResetCode := Frame.ErrorCode;
    { The bytes never read count as consumed for the connection. }
    State^.DataConsumed := State^.DataConsumed + (Frame.FinalSize - Stream^.Receive.ReadOffset);
    Stream^.MaxStreamDataPending := False;
  end;
  Result := True;
end;

function HandleStopSending(State: PQuicConnectionState; constref Frame: TQuicFrame): Boolean;
var
  Stream: PQuicStream;
begin
  if not StreamFor(State, Frame, Stream) then
    Exit(False);
  if Stream = nil then
    Exit(True);
  if not Stream^.CanSend then
    Exit(Violation(State, TransportStreamStateError, FrameStopSending, 'STOP_SENDING on a receive-only stream'));
  Stream^.StopSendingReceived := True;
  Stream^.StopSendingReceivedCode := Frame.ErrorCode;
  { Answer with a reset (section 3.5), unless everything arrived. }
  if not Stream^.ResetRequested and not Stream^.Send.AllAcknowledged then
  begin
    Stream^.ResetRequested := True;
    Stream^.ResetCode := Frame.ErrorCode;
    Stream^.ResetPending := True;
    Stream^.Send.Lost.Clear;
  end;
  Result := True;
end;

function HandleMaxStreamData(State: PQuicConnectionState; constref Frame: TQuicFrame): Boolean;
var
  Stream: PQuicStream;
begin
  if not StreamFor(State, Frame, Stream) then
    Exit(False);
  if Stream = nil then
    Exit(True);
  if not Stream^.CanSend then
    Exit(Violation(State, TransportStreamStateError, FrameMaxStreamData, 'MAX_STREAM_DATA on a receive-only stream'));
  if Frame.Maximum > Stream^.SendLimit then
    Stream^.SendLimit := Frame.Maximum;
  Result := True;
end;

function HandleStreamDataBlocked(State: PQuicConnectionState; constref Frame: TQuicFrame): Boolean;
var
  Stream: PQuicStream;
begin
  if not StreamFor(State, Frame, Stream) then
    Exit(False);
  if (Stream <> nil) and not Stream^.CanReceive then
    Exit(Violation(State, TransportStreamStateError, FrameStreamDataBlocked, 'STREAM_DATA_BLOCKED on a send-only stream'));
  Result := True;
end;

function HandleNewConnectionId(State: PQuicConnectionState; constref Frame: TQuicFrame): Boolean;
var
  Index, Free, Active: Integer;
begin
  if CurrentDestinationId(State).Length = 0 then
    Exit(Violation(State, TransportProtocolViolation, FrameNewConnectionId, 'NEW_CONNECTION_ID with empty IDs'));
  Free := -1;
  for Index := 0 to MaximumPeerConnectionIds - 1 do
  begin
    if State^.PeerIds[Index].InUse and (State^.PeerIds[Index].Sequence = Frame.SequenceNumber) then
    begin
      if not SameConnectionId(State^.PeerIds[Index].Id, Frame.ConnectionId) then
        Exit(Violation(State, TransportProtocolViolation, FrameNewConnectionId, 'a sequence number reused'));
      Exit(True);
    end;
    if not State^.PeerIds[Index].InUse and (Free < 0) then
      Free := Index;
  end;
  { Retire what the peer wants retired. }
  for Index := 0 to MaximumPeerConnectionIds - 1 do
    if State^.PeerIds[Index].InUse and (State^.PeerIds[Index].Sequence < Frame.RetirePriorTo) then
    begin
      State^.PeerIds[Index].InUse := False;
      SetLength(State^.RetireQueue, Length(State^.RetireQueue) + 1);
      State^.RetireQueue[High(State^.RetireQueue)] := State^.PeerIds[Index].Sequence;
      if Free < 0 then
        Free := Index;
    end;
  if Frame.SequenceNumber < Frame.RetirePriorTo then
  begin
    { Retired as it comes. }
    SetLength(State^.RetireQueue, Length(State^.RetireQueue) + 1);
    State^.RetireQueue[High(State^.RetireQueue)] := Frame.SequenceNumber;
  end
  else
  begin
    Active := 0;
    for Index := 0 to MaximumPeerConnectionIds - 1 do
      if State^.PeerIds[Index].InUse then
        Inc(Active);
    if (Free < 0) or (QWord(Active) >= State^.LocalParameters.ActiveConnectionIdLimit) then
      Exit(Violation(State, TransportConnectionIdLimitError, FrameNewConnectionId, 'too many connection IDs'));
    State^.PeerIds[Free].InUse := True;
    State^.PeerIds[Free].Sequence := Frame.SequenceNumber;
    State^.PeerIds[Free].Id := Frame.ConnectionId;
    State^.PeerIds[Free].HasResetToken := True;
    Move(Frame.ResetToken^, State^.PeerIds[Free].ResetToken[0], StatelessResetTokenLength);
  end;
  { The ID in use was retired: move to the lowest one left. }
  if not State^.PeerIds[State^.CurrentPeerId].InUse then
    for Index := 0 to MaximumPeerConnectionIds - 1 do
      if State^.PeerIds[Index].InUse and (not State^.PeerIds[State^.CurrentPeerId].InUse or
         (State^.PeerIds[Index].Sequence < State^.PeerIds[State^.CurrentPeerId].Sequence)) then
        State^.CurrentPeerId := Index;
  Result := True;
end;

procedure HandleConnectionClose(State: PQuicConnectionState; constref Frame: TQuicFrame; Now: Int64);
begin
  State^.PeerClosed := True;
  State^.PeerCloseCode := Frame.ErrorCode;
  State^.PeerCloseIsApplication := Frame.IsApplicationClose;
  SetString(State^.PeerCloseReason, PChar(Frame.Data), Frame.DataLength);
  if State^.Phase in [PhaseHandshaking, PhaseEstablished] then
  begin
    State^.Error := QuicErrorClosedByPeer;
    State^.ErrorDetail := State^.PeerCloseReason;
  end;
  if State^.Phase <> PhaseClosed then
  begin
    State^.Phase := PhaseDraining;
    State^.ClosePending := False;
    State^.CloseDeadline := Now + 3 * ProbeTimeout(State, SpaceApplication);
  end;
end;

function HandleOneFrame(State: PQuicConnectionState; Space: Integer; constref Frame: TQuicFrame;
  Now: Int64): Boolean;
var
  Code: QWord;
begin
  Result := True;
  case Frame.FrameType of
    FramePadding, FramePing:
      ;
    FrameAck, FrameAckWithEcn:
      begin
        Code := OnAckReceived(State, Space, Frame, Now);
        if Code <> 0 then
          Exit(Violation(State, Code, Frame.FrameType, 'acknowledgement of a packet never sent'));
      end;
    FrameCrypto:
      Result := HandleCrypto(State, Space, Frame);
    FrameStream..FrameStreamLast:
      Result := HandleStream(State, Frame);
    FrameResetStream:
      Result := HandleResetStream(State, Frame);
    FrameStopSending:
      Result := HandleStopSending(State, Frame);
    FrameNewToken:
      begin
        if State^.Role = RoleServer then
          Exit(Violation(State, TransportProtocolViolation, FrameNewToken, 'NEW_TOKEN from a client'));
        SetLength(State^.ReceivedToken, Frame.DataLength);
        Move(Frame.Data^, State^.ReceivedToken[0], Frame.DataLength);
      end;
    FrameMaxData:
      if Frame.Maximum > State^.PeerMaxData then
        State^.PeerMaxData := Frame.Maximum;
    FrameMaxStreamData:
      Result := HandleMaxStreamData(State, Frame);
    FrameMaxStreamsBidirectional:
      if Frame.Maximum > State^.PeerMaxStreamsBidirectional then
        State^.PeerMaxStreamsBidirectional := Frame.Maximum;
    FrameMaxStreamsUnidirectional:
      if Frame.Maximum > State^.PeerMaxStreamsUnidirectional then
        State^.PeerMaxStreamsUnidirectional := Frame.Maximum;
    FrameDataBlocked, FrameStreamsBlockedBidirectional, FrameStreamsBlockedUnidirectional:
      ;
    FrameStreamDataBlocked:
      Result := HandleStreamDataBlocked(State, Frame);
    FrameNewConnectionId:
      Result := HandleNewConnectionId(State, Frame);
    FrameRetireConnectionId:
      { Only sequence number 0 was ever issued; it stays in use. }
      if Frame.SequenceNumber > 0 then
        Exit(Violation(State, TransportProtocolViolation, FrameRetireConnectionId, 'retiring an ID never issued'));
    FramePathChallenge:
      begin
        Move(Frame.Data^, State^.PathResponseData[0], 8);
        State^.PathResponsePending := True;
      end;
    FramePathResponse:
      ;
    FrameConnectionCloseTransport, FrameConnectionCloseApplication:
      HandleConnectionClose(State, Frame, Now);
    FrameHandshakeDone:
      begin
        if State^.Role = RoleServer then
          Exit(Violation(State, TransportProtocolViolation, FrameHandshakeDone, 'HANDSHAKE_DONE from a client'));
        if not State^.HandshakeConfirmed then
        begin
          State^.HandshakeConfirmed := True;
          DiscardSpace(State, SpaceHandshake);
        end;
      end;
  end;
end;

function HandleFrames(State: PQuicConnectionState; Space: Integer; Payload: PByte; Length: PtrUInt; Now: Int64;
  out AckEliciting: Boolean): Boolean;
var
  Reader: TQuicReader;
  Frame: TQuicFrame;
begin
  AckEliciting := False;
  if Length = 0 then
    Exit(Violation(State, TransportProtocolViolation, 0, 'a packet without frames'));
  Reader.Initialize(Payload, Length);
  while not Reader.AtEnd do
  begin
    if not ParseFrame(Reader, Frame) then
      Exit(Violation(State, TransportFrameEncodingError, Frame.FrameType, 'a malformed frame'));
    if (Space <> SpaceApplication) and not FrameAllowedInHandshakeSpaces(Frame.FrameType) then
      Exit(Violation(State, TransportProtocolViolation, Frame.FrameType, 'a frame not allowed in this packet'));
    if FrameIsAckEliciting(Frame.FrameType) then
      AckEliciting := True;
    if not HandleOneFrame(State, Space, Frame, Now) then
      Exit(False);
    if State^.Phase in [PhaseDraining, PhaseClosed] then
      Break;
  end;
  Result := True;
end;

end.
