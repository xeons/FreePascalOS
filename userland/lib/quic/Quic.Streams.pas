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
  One stream (RFC 9000 sections 2 and 3): its identifier, which says who
  opened it and whether it goes both ways; its sending part (the send
  buffer, the peer's limit, a reset to send) and its receiving part (the
  receive buffer, the limit given to the peer, a STOP_SENDING to send, a
  reset from the peer); and what is waiting to go out about it.

  A stream is done with when both parts are: everything sent was
  acknowledged (or the reset was), and the application read to the end
  (or saw the reset, or asked the peer to stop). The connection then
  forgets it (Quic.StreamTable).
}
unit Quic.Streams;

{$mode objfpc}

interface

uses
  Quic.ReceiveBuffers,
  Quic.SendBuffers;

type
  TQuicStream = record
    Id: QWord;
    CanSend: Boolean;
    CanReceive: Boolean;
    LocallyInitiated: Boolean;
    { The application has been told of this peer stream (accepted). }
    Accepted: Boolean;

    Send: TQuicSendBuffer;
    { The peer's MAX_STREAM_DATA. }
    SendLimit: QWord;
    { The application reset the sending part (RESET_STREAM). }
    ResetRequested: Boolean;
    ResetCode: QWord;
    ResetPending: Boolean;
    ResetAcknowledged: Boolean;
    { The peer sent STOP_SENDING. }
    StopSendingReceived: Boolean;
    StopSendingReceivedCode: QWord;
    StreamDataBlockedPending: Boolean;
    { The limit (plus one) STREAM_DATA_BLOCKED was last sent for. }
    BlockedReportedAt: QWord;

    Receive: TQuicReceiveBuffer;
    { What was given to the peer as its limit, and the window. }
    ReceiveLimit: QWord;
    ReceiveWindow: QWord;
    MaxStreamDataPending: Boolean;
    { The application asked the peer to stop (STOP_SENDING). }
    StopSendingRequested: Boolean;
    StopSendingCode: QWord;
    StopSendingPending: Boolean;
    { The peer reset its sending part. }
    PeerReset: Boolean;
    PeerResetCode: QWord;
    { The application has been told of the end (0 read, or the reset). }
    EndSeen: Boolean;
  end;
  PQuicStream = ^TQuicStream;

function StreamIsBidirectional(Id: QWord): Boolean;
function StreamIsServerInitiated(Id: QWord): Boolean;
{ The sending part has nothing more to do. }
function StreamSendDone(Stream: PQuicStream): Boolean;
{ The receiving part has nothing more to do. }
function StreamReceiveDone(Stream: PQuicStream): Boolean;
{ Sends RESET_STREAM's final size: as far as the data went. }
function StreamFinalSize(Stream: PQuicStream): QWord;

implementation

uses
  Quic.Constants;

function StreamIsBidirectional(Id: QWord): Boolean;
begin
  Result := (Id and StreamUnidirectional) = 0;
end;

function StreamIsServerInitiated(Id: QWord): Boolean;
begin
  Result := (Id and StreamInitiatedByServer) <> 0;
end;

function StreamSendDone(Stream: PQuicStream): Boolean;
begin
  if not Stream^.CanSend then
    Exit(True);
  if Stream^.ResetRequested then
    Exit(Stream^.ResetAcknowledged);
  Result := Stream^.Send.AllAcknowledged;
end;

function StreamReceiveDone(Stream: PQuicStream): Boolean;
begin
  if not Stream^.CanReceive then
    Exit(True);
  if Stream^.StopSendingRequested then
    Exit(not Stream^.StopSendingPending);
  Result := Stream^.EndSeen;
end;

function StreamFinalSize(Stream: PQuicStream): QWord;
begin
  Result := Stream^.Send.SentOffset;
end;

end.
