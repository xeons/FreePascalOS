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
  Writing QUIC frames (RFC 9000 section 19) into a packet being built.
  Each routine writes the whole frame or, when it does not fit, sets
  the writer's Failed flag; callers check the room first with the
  *Length functions where a frame is cut to fit (STREAM, CRYPTO, ACK).
  STREAM frames always carry their length, so any frame may follow.
}
unit Quic.FrameWriter;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Quic.Buffers,
  Quic.ConnectionIds,
  Quic.RangeSets;

const
  { Ranges an ACK frame carries at most (the newest ones). }
  MaximumWrittenAckRanges = 32;

{ An ACK frame for the packet numbers in Received (not empty), largest
  first, with AckDelay already scaled down by the exponent; as many
  ranges as fit in the writer's room (at least the first). }
procedure WriteAckFrame(var Writer: TQuicWriter; constref Received: TQuicRangeSet; AckDelay: QWord);
function CryptoFrameHeaderLength(Offset, Length: QWord): Integer;
procedure WriteCryptoFrameHeader(var Writer: TQuicWriter; Offset, Length: QWord);
function StreamFrameHeaderLength(StreamId, Offset, Length: QWord): Integer;
procedure WriteStreamFrameHeader(var Writer: TQuicWriter; StreamId, Offset, Length: QWord; Fin: Boolean);
procedure WritePingFrame(var Writer: TQuicWriter);
procedure WriteHandshakeDoneFrame(var Writer: TQuicWriter);
procedure WriteResetStreamFrame(var Writer: TQuicWriter; StreamId, ErrorCode, FinalSize: QWord);
procedure WriteStopSendingFrame(var Writer: TQuicWriter; StreamId, ErrorCode: QWord);
procedure WriteMaxDataFrame(var Writer: TQuicWriter; Maximum: QWord);
procedure WriteMaxStreamDataFrame(var Writer: TQuicWriter; StreamId, Maximum: QWord);
procedure WriteMaxStreamsFrame(var Writer: TQuicWriter; Bidirectional: Boolean; Maximum: QWord);
procedure WriteDataBlockedFrame(var Writer: TQuicWriter; Maximum: QWord);
procedure WriteStreamDataBlockedFrame(var Writer: TQuicWriter; StreamId, Maximum: QWord);
procedure WriteStreamsBlockedFrame(var Writer: TQuicWriter; Bidirectional: Boolean; Maximum: QWord);
procedure WriteNewConnectionIdFrame(var Writer: TQuicWriter; SequenceNumber, RetirePriorTo: QWord;
  constref Id: TQuicConnectionId; constref ResetToken: TStatelessResetToken);
procedure WriteRetireConnectionIdFrame(var Writer: TQuicWriter; SequenceNumber: QWord);
procedure WritePathFrame(var Writer: TQuicWriter; FrameType: Byte; Data: PByte);
procedure WriteNewTokenFrame(var Writer: TQuicWriter; Token: PByte; Length: PtrUInt);
{ A transport close (0x1c, with the frame type that caused it) or an
  application's (0x1d). }
procedure WriteConnectionCloseFrame(var Writer: TQuicWriter; Application: Boolean; ErrorCode, CausingFrameType: QWord;
  const Reason: string);

implementation

uses
  Quic.Constants,
  Quic.VariableIntegers;

procedure WriteAckFrame(var Writer: TQuicWriter; constref Received: TQuicRangeSet; AckDelay: QWord);
var
  Index, RangeCount, Written: Integer;
  Largest, FirstRange, PreviousSmallest, Gap, RangeLength: QWord;
  Room, Needed: PtrUInt;
  Scratch: TQuicWriter;
begin
  if Received.Count = 0 then
  begin
    Writer.Failed := True;
    Exit;
  end;
  Index := Received.Count - 1;
  Largest := Received.Ranges[Index].Finish - 1;
  FirstRange := Largest - Received.Ranges[Index].Start;
  { How many more ranges fit: each takes its gap and length. }
  Needed := 1 + VariableIntegerLength(Largest) + VariableIntegerLength(AckDelay) + 1 +
    VariableIntegerLength(FirstRange);
  Room := Writer.Room;
  if Needed > Room then
  begin
    Writer.Failed := True;
    Exit;
  end;
  RangeCount := 0;
  PreviousSmallest := Received.Ranges[Index].Start;
  while (Index - RangeCount - 1 >= 0) and (RangeCount < MaximumWrittenAckRanges) do
  begin
    Gap := PreviousSmallest - Received.Ranges[Index - RangeCount - 1].Finish - 1;
    RangeLength := Received.Ranges[Index - RangeCount - 1].Finish - 1 - Received.Ranges[Index - RangeCount - 1].Start;
    if Needed + PtrUInt(VariableIntegerLength(Gap) + VariableIntegerLength(RangeLength)) > Room then
      Break;
    Needed := Needed + PtrUInt(VariableIntegerLength(Gap) + VariableIntegerLength(RangeLength));
    PreviousSmallest := Received.Ranges[Index - RangeCount - 1].Start;
    Inc(RangeCount);
  end;
  Scratch := Writer;
  Scratch.WriteByte(FrameAck);
  Scratch.WriteVariable(Largest);
  Scratch.WriteVariable(AckDelay);
  Scratch.WriteVariable(RangeCount);
  Scratch.WriteVariable(FirstRange);
  PreviousSmallest := Received.Ranges[Index].Start;
  for Written := 1 to RangeCount do
  begin
    Gap := PreviousSmallest - Received.Ranges[Index - Written].Finish - 1;
    RangeLength := Received.Ranges[Index - Written].Finish - 1 - Received.Ranges[Index - Written].Start;
    Scratch.WriteVariable(Gap);
    Scratch.WriteVariable(RangeLength);
    PreviousSmallest := Received.Ranges[Index - Written].Start;
  end;
  Writer := Scratch;
end;

function CryptoFrameHeaderLength(Offset, Length: QWord): Integer;
begin
  Result := 1 + VariableIntegerLength(Offset) + VariableIntegerLength(Length);
end;

procedure WriteCryptoFrameHeader(var Writer: TQuicWriter; Offset, Length: QWord);
begin
  Writer.WriteByte(FrameCrypto);
  Writer.WriteVariable(Offset);
  Writer.WriteVariable(Length);
end;

function StreamFrameHeaderLength(StreamId, Offset, Length: QWord): Integer;
begin
  Result := 1 + VariableIntegerLength(StreamId) + VariableIntegerLength(Length);
  if Offset > 0 then
    Result := Result + VariableIntegerLength(Offset);
end;

procedure WriteStreamFrameHeader(var Writer: TQuicWriter; StreamId, Offset, Length: QWord; Fin: Boolean);
var
  FrameType: Byte;
begin
  FrameType := FrameStream or FrameStreamLengthBit;
  if Offset > 0 then
    FrameType := FrameType or FrameStreamOffsetBit;
  if Fin then
    FrameType := FrameType or FrameStreamFinBit;
  Writer.WriteByte(FrameType);
  Writer.WriteVariable(StreamId);
  if Offset > 0 then
    Writer.WriteVariable(Offset);
  Writer.WriteVariable(Length);
end;

procedure WritePingFrame(var Writer: TQuicWriter);
begin
  Writer.WriteByte(FramePing);
end;

procedure WriteHandshakeDoneFrame(var Writer: TQuicWriter);
begin
  Writer.WriteByte(FrameHandshakeDone);
end;

procedure WriteResetStreamFrame(var Writer: TQuicWriter; StreamId, ErrorCode, FinalSize: QWord);
begin
  Writer.WriteByte(FrameResetStream);
  Writer.WriteVariable(StreamId);
  Writer.WriteVariable(ErrorCode);
  Writer.WriteVariable(FinalSize);
end;

procedure WriteStopSendingFrame(var Writer: TQuicWriter; StreamId, ErrorCode: QWord);
begin
  Writer.WriteByte(FrameStopSending);
  Writer.WriteVariable(StreamId);
  Writer.WriteVariable(ErrorCode);
end;

procedure WriteMaxDataFrame(var Writer: TQuicWriter; Maximum: QWord);
begin
  Writer.WriteByte(FrameMaxData);
  Writer.WriteVariable(Maximum);
end;

procedure WriteMaxStreamDataFrame(var Writer: TQuicWriter; StreamId, Maximum: QWord);
begin
  Writer.WriteByte(FrameMaxStreamData);
  Writer.WriteVariable(StreamId);
  Writer.WriteVariable(Maximum);
end;

procedure WriteMaxStreamsFrame(var Writer: TQuicWriter; Bidirectional: Boolean; Maximum: QWord);
begin
  if Bidirectional then
    Writer.WriteByte(FrameMaxStreamsBidirectional)
  else
    Writer.WriteByte(FrameMaxStreamsUnidirectional);
  Writer.WriteVariable(Maximum);
end;

procedure WriteDataBlockedFrame(var Writer: TQuicWriter; Maximum: QWord);
begin
  Writer.WriteByte(FrameDataBlocked);
  Writer.WriteVariable(Maximum);
end;

procedure WriteStreamDataBlockedFrame(var Writer: TQuicWriter; StreamId, Maximum: QWord);
begin
  Writer.WriteByte(FrameStreamDataBlocked);
  Writer.WriteVariable(StreamId);
  Writer.WriteVariable(Maximum);
end;

procedure WriteStreamsBlockedFrame(var Writer: TQuicWriter; Bidirectional: Boolean; Maximum: QWord);
begin
  if Bidirectional then
    Writer.WriteByte(FrameStreamsBlockedBidirectional)
  else
    Writer.WriteByte(FrameStreamsBlockedUnidirectional);
  Writer.WriteVariable(Maximum);
end;

procedure WriteNewConnectionIdFrame(var Writer: TQuicWriter; SequenceNumber, RetirePriorTo: QWord;
  constref Id: TQuicConnectionId; constref ResetToken: TStatelessResetToken);
begin
  Writer.WriteByte(FrameNewConnectionId);
  Writer.WriteVariable(SequenceNumber);
  Writer.WriteVariable(RetirePriorTo);
  Writer.WriteByte(Id.Length);
  Writer.WriteBytes(@Id.Bytes[0], Id.Length);
  Writer.WriteBytes(@ResetToken[0], StatelessResetTokenLength);
end;

procedure WriteRetireConnectionIdFrame(var Writer: TQuicWriter; SequenceNumber: QWord);
begin
  Writer.WriteByte(FrameRetireConnectionId);
  Writer.WriteVariable(SequenceNumber);
end;

procedure WritePathFrame(var Writer: TQuicWriter; FrameType: Byte; Data: PByte);
begin
  Writer.WriteByte(FrameType);
  Writer.WriteBytes(Data, 8);
end;

procedure WriteNewTokenFrame(var Writer: TQuicWriter; Token: PByte; Length: PtrUInt);
begin
  Writer.WriteByte(FrameNewToken);
  Writer.WriteVariable(Length);
  Writer.WriteBytes(Token, Length);
end;

procedure WriteConnectionCloseFrame(var Writer: TQuicWriter; Application: Boolean; ErrorCode, CausingFrameType: QWord;
  const Reason: string);
var
  ReasonLength: PtrUInt;
begin
  ReasonLength := Length(Reason);
  { The reason is cut to keep the frame small. }
  if ReasonLength > 200 then
    ReasonLength := 200;
  if Application then
    Writer.WriteByte(FrameConnectionCloseApplication)
  else
    Writer.WriteByte(FrameConnectionCloseTransport);
  Writer.WriteVariable(ErrorCode);
  if not Application then
    Writer.WriteVariable(CausingFrameType);
  Writer.WriteVariable(ReasonLength);
  if ReasonLength > 0 then
    Writer.WriteBytes(PByte(PChar(Reason)), ReasonLength);
end;

end.
