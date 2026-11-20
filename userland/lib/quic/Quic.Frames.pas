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
  Reading QUIC frames (RFC 9000 section 19) out of a decrypted packet
  payload. ParseFrame takes one frame into a TQuicFrame whose byte
  fields point into the payload (nothing is copied). Every length is
  checked; a frame that runs past the payload, a stream offset beyond
  2^62, a frame type that is not known, or an ACK range below zero is a
  FRAME_ENCODING_ERROR. Runs of PADDING come out as one frame.

  An ACK frame's ranges come out as [Smallest, Largest] pairs, largest
  first; at most MaximumAckRanges are kept (the rest are read and
  passed over: those packets just stay unacknowledged for now).
}
unit Quic.Frames;

{$mode objfpc}
{$pointermath on}

interface

uses
  Quic.Buffers,
  Quic.ConnectionIds;

const
  MaximumAckRanges = 64;

type
  TQuicAckRange = record
    Smallest: QWord;
    Largest: QWord;
  end;

  TQuicFrame = record
    FrameType: QWord;
    { ACK. }
    LargestAcknowledged: QWord;
    AckDelay: QWord;
    AckRangeCount: Integer;
    AckRanges: array[0..MaximumAckRanges - 1] of TQuicAckRange;
    HasEcnCounts: Boolean;
    { STREAM, CRYPTO, RESET_STREAM, STOP_SENDING, MAX_STREAM_DATA,
      STREAM_DATA_BLOCKED. }
    StreamId: QWord;
    Offset: QWord;
    Data: PByte;
    DataLength: QWord;
    Fin: Boolean;
    { RESET_STREAM, STOP_SENDING, CONNECTION_CLOSE. }
    ErrorCode: QWord;
    { RESET_STREAM. }
    FinalSize: QWord;
    { MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS, *_BLOCKED. }
    Maximum: QWord;
    Bidirectional: Boolean;
    { NEW_CONNECTION_ID, RETIRE_CONNECTION_ID. }
    SequenceNumber: QWord;
    RetirePriorTo: QWord;
    ConnectionId: TQuicConnectionId;
    ResetToken: PByte;
    { CONNECTION_CLOSE: the frame type that caused it (transport only),
      and whether it is an application's close. }
    CausingFrameType: QWord;
    IsApplicationClose: Boolean;
    { PADDING: how many bytes. }
    PaddingLength: QWord;
  end;

{ One frame; False on a FRAME_ENCODING_ERROR. }
function ParseFrame(var Reader: TQuicReader; out Frame: TQuicFrame): Boolean;
{ Whether a frame type makes the packet ack-eliciting (all but ACK,
  PADDING and CONNECTION_CLOSE). }
function FrameIsAckEliciting(FrameType: QWord): Boolean;
{ Whether the frame type may appear in Initial and Handshake packets
  (PADDING, PING, ACK, CRYPTO and the transport CONNECTION_CLOSE). }
function FrameAllowedInHandshakeSpaces(FrameType: QWord): Boolean;

implementation

uses
  Quic.Constants,
  Quic.VariableIntegers;

function FrameIsAckEliciting(FrameType: QWord): Boolean;
begin
  Result := (FrameType > $FF) or not (Byte(FrameType) in [FramePadding, FrameAck, FrameAckWithEcn,
    FrameConnectionCloseTransport, FrameConnectionCloseApplication]);
end;

function FrameAllowedInHandshakeSpaces(FrameType: QWord): Boolean;
begin
  Result := (FrameType <= $FF) and (Byte(FrameType) in [FramePadding, FramePing, FrameAck, FrameAckWithEcn,
    FrameCrypto, FrameConnectionCloseTransport]);
end;

function ParseAck(var Reader: TQuicReader; var Frame: TQuicFrame): Boolean;
var
  RangeCount, FirstRange, Gap, RangeLength, Index: QWord;
  Smallest, Count: QWord;
begin
  if not Reader.ReadVariable(Frame.LargestAcknowledged) or not Reader.ReadVariable(Frame.AckDelay) or
     not Reader.ReadVariable(RangeCount) or not Reader.ReadVariable(FirstRange) then
    Exit(False);
  if FirstRange > Frame.LargestAcknowledged then
    Exit(False);
  Smallest := Frame.LargestAcknowledged - FirstRange;
  Frame.AckRanges[0].Largest := Frame.LargestAcknowledged;
  Frame.AckRanges[0].Smallest := Smallest;
  Frame.AckRangeCount := 1;
  Index := 0;
  while Index < RangeCount do
  begin
    if not Reader.ReadVariable(Gap) or not Reader.ReadVariable(RangeLength) then
      Exit(False);
    { The next range's largest is Smallest - Gap - 2. }
    if Smallest < Gap + 2 then
      Exit(False);
    Count := Smallest - Gap - 2;
    if RangeLength > Count then
      Exit(False);
    Smallest := Count - RangeLength;
    if Frame.AckRangeCount < MaximumAckRanges then
    begin
      Frame.AckRanges[Frame.AckRangeCount].Largest := Count;
      Frame.AckRanges[Frame.AckRangeCount].Smallest := Smallest;
      Inc(Frame.AckRangeCount);
    end;
    Inc(Index);
  end;
  if Frame.FrameType = FrameAckWithEcn then
  begin
    Frame.HasEcnCounts := True;
    { ECT(0), ECT(1) and CE counts: read, not used. }
    if not Reader.ReadVariable(Count) or not Reader.ReadVariable(Count) or not Reader.ReadVariable(Count) then
      Exit(False);
  end;
  Result := True;
end;

function ParseStream(var Reader: TQuicReader; var Frame: TQuicFrame): Boolean;
var
  Bits: Byte;
begin
  Bits := Byte(Frame.FrameType and $07);
  if not Reader.ReadVariable(Frame.StreamId) then
    Exit(False);
  Frame.Offset := 0;
  if (Bits and FrameStreamOffsetBit) <> 0 then
    if not Reader.ReadVariable(Frame.Offset) then
      Exit(False);
  if (Bits and FrameStreamLengthBit) <> 0 then
  begin
    if not Reader.ReadVariable(Frame.DataLength) then
      Exit(False);
  end
  else
    Frame.DataLength := Reader.Remaining;
  if not Reader.ReadBytes(Frame.DataLength, Frame.Data) then
    Exit(False);
  if Frame.Offset + Frame.DataLength > MaximumVariableInteger then
    Exit(False);
  Frame.Fin := (Bits and FrameStreamFinBit) <> 0;
  Result := True;
end;

function ParseCrypto(var Reader: TQuicReader; var Frame: TQuicFrame): Boolean;
begin
  Result := Reader.ReadVariable(Frame.Offset) and Reader.ReadVariable(Frame.DataLength) and
    Reader.ReadBytes(Frame.DataLength, Frame.Data) and (Frame.Offset + Frame.DataLength <= MaximumVariableInteger);
end;

function ParseNewConnectionId(var Reader: TQuicReader; var Frame: TQuicFrame): Boolean;
var
  IdLength: Byte;
  IdBytes: PByte;
begin
  if not Reader.ReadVariable(Frame.SequenceNumber) or not Reader.ReadVariable(Frame.RetirePriorTo) or
     not Reader.ReadByte(IdLength) then
    Exit(False);
  if (IdLength < 1) or (IdLength > MaximumConnectionIdLength) or (Frame.RetirePriorTo > Frame.SequenceNumber) then
    Exit(False);
  if not Reader.ReadBytes(IdLength, IdBytes) or not Reader.ReadBytes(StatelessResetTokenLength, Frame.ResetToken) then
    Exit(False);
  Result := MakeConnectionId(IdBytes, IdLength, Frame.ConnectionId);
end;

function ParseConnectionClose(var Reader: TQuicReader; var Frame: TQuicFrame): Boolean;
begin
  Frame.IsApplicationClose := Frame.FrameType = FrameConnectionCloseApplication;
  if not Reader.ReadVariable(Frame.ErrorCode) then
    Exit(False);
  if not Frame.IsApplicationClose then
    if not Reader.ReadVariable(Frame.CausingFrameType) then
      Exit(False);
  Result := Reader.ReadVariable(Frame.DataLength) and Reader.ReadBytes(Frame.DataLength, Frame.Data);
end;

function ParseFrame(var Reader: TQuicReader; out Frame: TQuicFrame): Boolean;
var
  Count: QWord;
begin
  Frame.FrameType := 0;
  Frame.AckRangeCount := 0;
  Frame.HasEcnCounts := False;
  Frame.Data := nil;
  Frame.DataLength := 0;
  Frame.Fin := False;
  Frame.Offset := 0;
  if not Reader.ReadVariable(Frame.FrameType) then
    Exit(False);
  case Frame.FrameType of
    FramePadding:
      begin
        Count := 1;
        while (Reader.Remaining > 0) and (Reader.Position^ = 0) do
        begin
          Inc(Reader.Position);
          Inc(Count);
        end;
        Frame.PaddingLength := Count;
        Result := True;
      end;
    FramePing, FrameHandshakeDone:
      Result := True;
    FrameAck, FrameAckWithEcn:
      Result := ParseAck(Reader, Frame);
    FrameResetStream:
      Result := Reader.ReadVariable(Frame.StreamId) and Reader.ReadVariable(Frame.ErrorCode) and
        Reader.ReadVariable(Frame.FinalSize);
    FrameStopSending:
      Result := Reader.ReadVariable(Frame.StreamId) and Reader.ReadVariable(Frame.ErrorCode);
    FrameCrypto:
      Result := ParseCrypto(Reader, Frame);
    FrameNewToken:
      Result := Reader.ReadVariable(Frame.DataLength) and (Frame.DataLength > 0) and
        Reader.ReadBytes(Frame.DataLength, Frame.Data);
    FrameStream..FrameStreamLast:
      Result := ParseStream(Reader, Frame);
    FrameMaxData, FrameDataBlocked:
      Result := Reader.ReadVariable(Frame.Maximum);
    FrameMaxStreamData, FrameStreamDataBlocked:
      Result := Reader.ReadVariable(Frame.StreamId) and Reader.ReadVariable(Frame.Maximum);
    FrameMaxStreamsBidirectional, FrameMaxStreamsUnidirectional,
    FrameStreamsBlockedBidirectional, FrameStreamsBlockedUnidirectional:
      begin
        Frame.Bidirectional := (Frame.FrameType = FrameMaxStreamsBidirectional) or
          (Frame.FrameType = FrameStreamsBlockedBidirectional);
        Result := Reader.ReadVariable(Frame.Maximum) and (Frame.Maximum <= MaximumStreamCount);
      end;
    FrameNewConnectionId:
      Result := ParseNewConnectionId(Reader, Frame);
    FrameRetireConnectionId:
      Result := Reader.ReadVariable(Frame.SequenceNumber);
    FramePathChallenge, FramePathResponse:
      begin
        Frame.DataLength := 8;
        Result := Reader.ReadBytes(8, Frame.Data);
      end;
    FrameConnectionCloseTransport, FrameConnectionCloseApplication:
      Result := ParseConnectionClose(Reader, Frame);
  else
    Result := False;
  end;
end;

end.
