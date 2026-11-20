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
  Variable-length integers (RFC 9000 appendix A.1's examples), range
  sets, every frame written and read back, ACK frames with gaps,
  malformed frames, and transport parameters both ways.
}
unit QuicTest.Framing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure RunFramingTests;

implementation

uses
  SysUtils,
  TestChecks,
  Quic.Buffers,
  Quic.ConnectionIds,
  Quic.Constants,
  Quic.FrameWriter,
  Quic.Frames,
  Quic.RangeSets,
  Quic.TransportParameters,
  Quic.VariableIntegers;

procedure CheckVariable(const Hex: string; Expected: QWord);
var
  Bytes: TByteArray;
  Value: QWord;
  Encoded: array[0..7] of Byte;
  Count: Integer;
begin
  Bytes := HexToBytes(Hex);
  Count := DecodeVariableInteger(@Bytes[0], Length(Bytes), Value);
  Check((Count = Length(Bytes)) and (Value = Expected), 'varint decodes ' + Hex);
  Count := EncodeVariableInteger(Expected, @Encoded[0]);
  { 4025 is not the shortest form, so it only decodes. }
  if Count = Length(Bytes) then
    CheckBytes(@Encoded[0], Count, Hex, 'varint encodes ' + Hex);
end;

procedure TestVariableIntegers;
var
  Bytes: TByteArray;
  Value: QWord;
  Encoded: array[0..7] of Byte;
begin
  CheckVariable('c2197c5eff14e88c', 151288809941952652);
  CheckVariable('9d7f3e7d', 494878333);
  CheckVariable('7bbd', 15293);
  CheckVariable('25', 37);
  CheckVariable('4025', 37);
  Check(EncodeVariableInteger(37, @Encoded[0]) = 1, 'varint 37 is one byte');
  Check(EncodeVariableInteger(MaximumVariableInteger, @Encoded[0]) = 8, 'varint maximum is eight bytes');
  Bytes := HexToBytes('c2197c5eff14e8');
  Check(DecodeVariableInteger(@Bytes[0], Length(Bytes), Value) = 0, 'varint cut short');
  Check(VariableIntegerLength(63) = 1, 'varint 63');
  Check(VariableIntegerLength(64) = 2, 'varint 64');
  Check(VariableIntegerLength(16383) = 2, 'varint 16383');
  Check(VariableIntegerLength(16384) = 4, 'varint 16384');
  Check(VariableIntegerLength(1073741823) = 4, 'varint 2^30 - 1');
  Check(VariableIntegerLength(1073741824) = 8, 'varint 2^30');
end;

procedure TestRangeSets;
var
  Ranges: TQuicRangeSet;
  Taken: TQuicRange;
begin
  Ranges := Default(TQuicRangeSet);
  Ranges.Add(10, 20);
  Ranges.Add(30, 40);
  Ranges.Add(20, 30);
  Check((Ranges.Count = 1) and (Ranges.Ranges[0].Start = 10) and (Ranges.Ranges[0].Finish = 40), 'ranges merge');
  Ranges.Remove(15, 25);
  Check((Ranges.Count = 2) and (Ranges.Ranges[0].Finish = 15) and (Ranges.Ranges[1].Start = 25), 'range split');
  Check(Ranges.Contains(14) and not Ranges.Contains(15) and Ranges.Contains(25), 'range contains');
  Check(Ranges.ContiguousEnd(10) = 15, 'contiguous end');
  Ranges.Add(0, 5);
  Ranges.Add(50, 60);
  Check(Ranges.Count = 4, 'four ranges');
  Check(Ranges.TakeLowest(3, Taken) and (Taken.Start = 0) and (Taken.Finish = 3), 'take lowest, cut');
  Check(Ranges.Lowest = 3, 'rest of the lowest range stays');
  Ranges.Remove(0, 100);
  Check(Ranges.IsEmpty, 'all removed');
  Ranges.MaximumRanges := 2;
  Ranges.Add(1, 2);
  Ranges.Add(3, 4);
  Ranges.Add(5, 6);
  Check((Ranges.Count = 2) and (Ranges.Lowest = 3), 'bounded set drops the lowest range');
  Ranges.Add(0, 10);
  Check((Ranges.Count = 1) and (Ranges.HighestFinish = 10), 'one range covers all');
end;

function ParseOne(Buffer: PByte; Length: PtrUInt; out Frame: TQuicFrame): Boolean;
var
  Reader: TQuicReader;
begin
  Reader.Initialize(Buffer, Length);
  Result := ParseFrame(Reader, Frame) and Reader.AtEnd;
end;

procedure TestAckFrames;
var
  Received: TQuicRangeSet;
  Buffer: array[0..255] of Byte;
  Writer: TQuicWriter;
  Frame: TQuicFrame;
  Bytes: TByteArray;
begin
  Received := Default(TQuicRangeSet);
  Received.Add(0, 3);
  Received.Add(5, 6);
  Received.Add(10, 21);
  Writer.Initialize(@Buffer[0], SizeOf(Buffer));
  WriteAckFrame(Writer, Received, 7);
  Check(not Writer.Failed, 'ACK written');
  Check(ParseOne(@Buffer[0], Writer.Length, Frame), 'ACK parses');
  Check((Frame.LargestAcknowledged = 20) and (Frame.AckDelay = 7) and (Frame.AckRangeCount = 3), 'ACK fields');
  Check((Frame.AckRanges[0].Smallest = 10) and (Frame.AckRanges[0].Largest = 20), 'ACK first range');
  Check((Frame.AckRanges[1].Smallest = 5) and (Frame.AckRanges[1].Largest = 5), 'ACK second range');
  Check((Frame.AckRanges[2].Smallest = 0) and (Frame.AckRanges[2].Largest = 2), 'ACK third range');
  { Largest 5, first range 2, one range: gap 0, length 0 -> 0..0? gap 0 means
    the next largest is 3 - 0 - 2 = 1. }
  Bytes := HexToBytes('0205000102000000');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'ACK with a trailing byte is not one frame');
  Bytes := HexToBytes('02050001020000');
  Check(ParseOne(@Bytes[0], Length(Bytes), Frame) and (Frame.AckRanges[1].Largest = 1) and
    (Frame.AckRanges[1].Smallest = 1), 'ACK gap arithmetic');
  Bytes := HexToBytes('02050006');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'ACK first range below zero');
  Bytes := HexToBytes('0205000105');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'ACK cut short');
  { A tight writer still fits the first range. }
  Writer.Initialize(@Buffer[0], 6);
  WriteAckFrame(Writer, Received, 7);
  Check(not Writer.Failed and ParseOne(@Buffer[0], Writer.Length, Frame) and (Frame.AckRangeCount = 1),
    'ACK cut to the room left');
end;

procedure TestFrameRoundTrips;
var
  Buffer: array[0..511] of Byte;
  Writer: TQuicWriter;
  Reader: TQuicReader;
  Frame: TQuicFrame;
  Id: TQuicConnectionId;
  Token: TStatelessResetToken;
  Data: array[0..9] of Byte;
  Path: array[0..7] of Byte;
  Index: Integer;
  Bytes: TByteArray;
begin
  for Index := 0 to 9 do
    Data[Index] := Index + 1;
  for Index := 0 to 7 do
    Path[Index] := $A0 + Index;
  FillChar(Token, SizeOf(Token), $5A);
  Id := RandomConnectionId(8);
  Writer.Initialize(@Buffer[0], SizeOf(Buffer));
  WriteStreamFrameHeader(Writer, 4, 1000, 10, True);
  Writer.WriteBytes(@Data[0], 10);
  WriteStreamFrameHeader(Writer, 8, 0, 10, False);
  Writer.WriteBytes(@Data[0], 10);
  WriteCryptoFrameHeader(Writer, 77, 10);
  Writer.WriteBytes(@Data[0], 10);
  WriteResetStreamFrame(Writer, 3, 258, 99999);
  WriteStopSendingFrame(Writer, 7, 1);
  WriteMaxDataFrame(Writer, 1 shl 40);
  WriteMaxStreamDataFrame(Writer, 4, 65536);
  WriteMaxStreamsFrame(Writer, True, 100);
  WriteMaxStreamsFrame(Writer, False, 3);
  WriteDataBlockedFrame(Writer, 5);
  WriteStreamDataBlockedFrame(Writer, 4, 6);
  WriteStreamsBlockedFrame(Writer, False, 7);
  WriteNewConnectionIdFrame(Writer, 2, 1, Id, Token);
  WriteRetireConnectionIdFrame(Writer, 1);
  WritePathFrame(Writer, FramePathChallenge, @Path[0]);
  WritePathFrame(Writer, FramePathResponse, @Path[0]);
  WriteNewTokenFrame(Writer, @Data[0], 5);
  WritePingFrame(Writer);
  WriteHandshakeDoneFrame(Writer);
  Writer.WriteZeros(5);
  WriteConnectionCloseFrame(Writer, False, TransportProtocolViolation, FrameStream, 'bad');
  WriteConnectionCloseFrame(Writer, True, 259, 0, 'bye');
  Check(not Writer.Failed, 'frames written');

  Reader.Initialize(@Buffer[0], Writer.Length);
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = $0F) and (Frame.StreamId = 4) and (Frame.Offset = 1000) and
    (Frame.DataLength = 10) and Frame.Fin and (CompareByte(Frame.Data^, Data[0], 10) = 0), 'STREAM with offset and FIN');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = $0A) and (Frame.StreamId = 8) and (Frame.Offset = 0) and
    not Frame.Fin, 'STREAM at offset 0');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FrameCrypto) and (Frame.Offset = 77) and
    (Frame.DataLength = 10), 'CRYPTO');
  Check(ParseFrame(Reader, Frame) and (Frame.StreamId = 3) and (Frame.ErrorCode = 258) and (Frame.FinalSize = 99999),
    'RESET_STREAM');
  Check(ParseFrame(Reader, Frame) and (Frame.StreamId = 7) and (Frame.ErrorCode = 1), 'STOP_SENDING');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FrameMaxData) and (Frame.Maximum = QWord(1) shl 40),
    'MAX_DATA');
  Check(ParseFrame(Reader, Frame) and (Frame.StreamId = 4) and (Frame.Maximum = 65536), 'MAX_STREAM_DATA');
  Check(ParseFrame(Reader, Frame) and Frame.Bidirectional and (Frame.Maximum = 100), 'MAX_STREAMS bidirectional');
  Check(ParseFrame(Reader, Frame) and not Frame.Bidirectional and (Frame.Maximum = 3), 'MAX_STREAMS unidirectional');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FrameDataBlocked) and (Frame.Maximum = 5), 'DATA_BLOCKED');
  Check(ParseFrame(Reader, Frame) and (Frame.StreamId = 4) and (Frame.Maximum = 6), 'STREAM_DATA_BLOCKED');
  Check(ParseFrame(Reader, Frame) and not Frame.Bidirectional and (Frame.Maximum = 7), 'STREAMS_BLOCKED');
  Check(ParseFrame(Reader, Frame) and (Frame.SequenceNumber = 2) and (Frame.RetirePriorTo = 1) and
    SameConnectionId(Frame.ConnectionId, Id) and (CompareByte(Frame.ResetToken^, Token[0], 16) = 0),
    'NEW_CONNECTION_ID');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FrameRetireConnectionId) and (Frame.SequenceNumber = 1),
    'RETIRE_CONNECTION_ID');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FramePathChallenge) and
    (CompareByte(Frame.Data^, Path[0], 8) = 0), 'PATH_CHALLENGE');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FramePathResponse), 'PATH_RESPONSE');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FrameNewToken) and (Frame.DataLength = 5), 'NEW_TOKEN');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FramePing), 'PING');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FrameHandshakeDone), 'HANDSHAKE_DONE');
  Check(ParseFrame(Reader, Frame) and (Frame.FrameType = FramePadding) and (Frame.PaddingLength = 5),
    'PADDING run');
  Check(ParseFrame(Reader, Frame) and not Frame.IsApplicationClose and
    (Frame.ErrorCode = TransportProtocolViolation) and (Frame.CausingFrameType = FrameStream) and
    (Frame.DataLength = 3), 'CONNECTION_CLOSE (transport)');
  Check(ParseFrame(Reader, Frame) and Frame.IsApplicationClose and (Frame.ErrorCode = 259) and
    (Frame.DataLength = 3), 'CONNECTION_CLOSE (application)');
  Check(Reader.AtEnd, 'all frames read');

  Bytes := HexToBytes('1f');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'unknown frame type');
  Bytes := HexToBytes('0e040564');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'STREAM running past the packet');
  Bytes := HexToBytes('1801020011223344556677889900aabbccddeeff00');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'NEW_CONNECTION_ID retiring beyond itself');
  Bytes := HexToBytes('0f00ffffffffffffffff01aa');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'STREAM beyond 2^62');
  Bytes := HexToBytes('12d000000000000001');
  Check(not ParseOne(@Bytes[0], Length(Bytes), Frame), 'MAX_STREAMS beyond 2^60');
  { A STREAM frame without LEN takes the rest of the packet. }
  Bytes := HexToBytes('0c0405616263');
  Check(ParseOne(@Bytes[0], Length(Bytes), Frame) and (Frame.Offset = 5) and (Frame.DataLength = 3),
    'STREAM without length');
end;

procedure TestTransportParameters;
var
  Parameters, Decoded: TQuicTransportParameters;
  Encoded: TBytes;
  Bytes: TByteArray;
begin
  DefaultTransportParameters(Parameters);
  Parameters.MaxIdleTimeout := 30000;
  Parameters.InitialMaxData := 1048576;
  Parameters.InitialMaxStreamDataBidiLocal := 262144;
  Parameters.InitialMaxStreamDataBidiRemote := 262144;
  Parameters.InitialMaxStreamDataUni := 65536;
  Parameters.InitialMaxStreamsBidi := 100;
  Parameters.InitialMaxStreamsUni := 3;
  Parameters.ActiveConnectionIdLimit := 4;
  Parameters.MaxAckDelay := 20;
  Parameters.HasInitialSourceConnectionId := True;
  Parameters.InitialSourceConnectionId := RandomConnectionId(8);
  Parameters.HasOriginalDestinationConnectionId := True;
  Parameters.OriginalDestinationConnectionId := RandomConnectionId(12);
  Parameters.HasStatelessResetToken := True;
  FillChar(Parameters.StatelessResetToken, 16, 7);
  Parameters.DisableActiveMigration := True;
  Encoded := EncodeTransportParameters(Parameters);
  Check(Length(Encoded) > 0, 'transport parameters encode');
  Check(DecodeTransportParameters(@Encoded[0], Length(Encoded), True, Decoded), 'transport parameters decode');
  Check((Decoded.MaxIdleTimeout = 30000) and (Decoded.InitialMaxData = 1048576) and
    (Decoded.InitialMaxStreamDataBidiLocal = 262144) and (Decoded.InitialMaxStreamDataUni = 65536) and
    (Decoded.InitialMaxStreamsBidi = 100) and (Decoded.InitialMaxStreamsUni = 3) and
    (Decoded.ActiveConnectionIdLimit = 4) and (Decoded.MaxAckDelay = 20) and (Decoded.AckDelayExponent = 3) and
    Decoded.DisableActiveMigration and (Decoded.MaxUdpPayloadSize = 65527), 'transport parameter values');
  Check(Decoded.HasInitialSourceConnectionId and
    SameConnectionId(Decoded.InitialSourceConnectionId, Parameters.InitialSourceConnectionId) and
    Decoded.HasOriginalDestinationConnectionId and
    SameConnectionId(Decoded.OriginalDestinationConnectionId, Parameters.OriginalDestinationConnectionId) and
    Decoded.HasStatelessResetToken and (Decoded.StatelessResetToken[15] = 7), 'transport parameter IDs');
  Check(not DecodeTransportParameters(@Encoded[0], Length(Encoded), False, Decoded),
    'a client may not send server parameters');
  { Duplicates, bad values, an unknown (reserved) parameter. }
  Bytes := HexToBytes('0104801e8480' + '0104801e8480');
  Check(not DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded), 'duplicate parameter');
  Bytes := HexToBytes('0a0115');
  Check(not DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded), 'ack_delay_exponent above 20');
  Bytes := HexToBytes('03024000');
  Check(not DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded), 'max_udp_payload_size below 1200');
  Bytes := HexToBytes('0e0101');
  Check(not DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded), 'active_connection_id_limit 1');
  Bytes := HexToBytes('0b024000' + '1b03616263' + '04024000');
  Check(DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded) and (Decoded.MaxAckDelay = 0) and
    (Decoded.InitialMaxData = 0), 'unknown parameters skipped');
  Bytes := HexToBytes('040240');
  Check(not DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded), 'parameter running past the end');
  Bytes := HexToBytes('0403400000');
  Check(not DecodeTransportParameters(@Bytes[0], Length(Bytes), True, Decoded), 'integer not filling its length');
end;

procedure RunFramingTests;
begin
  TestVariableIntegers;
  TestRangeSets;
  TestAckFrames;
  TestFrameRoundTrips;
  TestTransportParameters;
end;

end.
