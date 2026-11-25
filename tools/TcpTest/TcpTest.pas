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
  Host test of the kernel TCP's pure parts (make tcp-test):

  - Network.TcpSequences: comparisons across the wrap.
  - Network.TcpOptions: a SYN with every option written byte for byte as
    other stacks lay it out and read back; SYN-ACKs with fewer options;
    timestamps and SACK blocks on an ACK; how many SACK blocks fit;
    malformed and unknown options; a window scale above 14.
  - Network.TcpWindows: scaled window fields (rounding, never shrinking
    what was promised, the 16-bit cap), the buffers' growth.
  - Network.TcpScoreboard: blocks added, merged, ignored outside the
    window, trimmed by the acknowledgment; IsLost, the pipe and the next
    retransmission of RFC 6675 over a scenario with three holes.
  - Network.TcpReceivedBlocks: the receiver's blocks, most recent first,
    merged and dropped as the acknowledgment passes them.
  - Network.SipHash: the reference vectors of SipHash-2-4.
  - Network.KeyedNumbers: RFC 6528 initial sequence numbers (the same
    endpoints and key give the same offset, others differ, the clock
    moves them on), timestamp offsets, RFC 6056 port candidates in range
    and covering it, the double hash's counters, RFC 7739
    identifications.
  - Network.TcpAcceptance: the window test with its zero-window
    allowance, RFC 5961's reset dispositions and acknowledgment range.
  - Network.TokenBuckets: bursts, refill, the cap.

  Prints every failed check and exits with 1 if there was one.
}
program TcpTest;

{$mode objfpc}

uses
  SysUtils,
  Network.TcpSequences,
  Network.TcpOptions,
  Network.TcpWindows,
  Network.TcpScoreboard,
  Network.TcpReceivedBlocks,
  Network.SipHash,
  Network.KeyedNumbers,
  Network.TcpAcceptance,
  Network.TokenBuckets;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('TCP TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: QWord; const What: string);
begin
  Check(Actual = Expected, What + ' is ' + IntToStr(Actual) + ', expected ' + IntToStr(Expected));
end;

function BytesMatch(Actual: PByte; const Expected: array of Byte): Boolean;
var
  Index: Integer;
begin
  Result := True;
  for Index := 0 to High(Expected) do
    if Actual[Index] <> Expected[Index] then
      Exit(False);
end;

{ --- Sequence numbers ------------------------------------------------------- }

procedure TestSequences;
begin
  Check(SequenceBefore(1, 2), '1 before 2');
  Check(SequenceBefore($FFFFFFF0, 5), 'before across the wrap');
  Check(SequenceAfter(5, $FFFFFFF0), 'after across the wrap');
  Check(not SequenceBefore(7, 7) and SequenceBeforeOrEqual(7, 7), 'equal');
  CheckNumber(SequenceDistance($FFFFFFF0, $10), $20, 'the distance across the wrap');
  CheckNumber(LaterSequence($FFFFFFFF, 3), 3, 'the later across the wrap');
  CheckNumber(EarlierSequence($FFFFFFFF, 3), $FFFFFFFF, 'the earlier across the wrap');
end;

{ --- Options ---------------------------------------------------------------- }

procedure TestSynWithEverything;
const
  Expected: array[0..19] of Byte = (
    2, 4, $05, $B4,                       { MSS 1460 }
    4, 2,                                 { SACK permitted }
    8, 10, $01, $02, $03, $04, 0, 0, 0, 0, { timestamps }
    1, 3, 3, 7);                          { NOP, window scale 7 }
var
  Options: TTcpOptions;
  Parsed: TTcpOptions;
  Buffer: array[0..63] of Byte;
  Length: LongWord;
begin
  ClearTcpOptions(Options);
  Options.HasMaximumSegment := True;
  Options.MaximumSegment := 1460;
  Options.SackPermitted := True;
  Options.HasTimestamps := True;
  Options.TimestampValue := $01020304;
  Options.HasWindowScale := True;
  Options.WindowShift := 7;
  CheckNumber(TcpOptionsLength(Options, True), 20, 'a SYN''s options with everything');
  FillChar(Buffer, SizeOf(Buffer), $EE);
  Length := WriteTcpOptions(@Buffer[0], Options, True);
  CheckNumber(Length, 20, 'the bytes written for a SYN');
  Check(BytesMatch(@Buffer[0], Expected), 'a SYN''s options are laid out as other stacks lay them');
  ParseTcpOptions(@Buffer[0], Length, Parsed);
  Check(Parsed.HasMaximumSegment and (Parsed.MaximumSegment = 1460), 'the MSS reads back');
  Check(Parsed.SackPermitted, 'SACK permitted reads back');
  Check(Parsed.HasTimestamps and (Parsed.TimestampValue = $01020304) and (Parsed.TimestampEcho = 0),
    'the timestamps read back');
  Check(Parsed.HasWindowScale and (Parsed.WindowShift = 7), 'the window scale reads back');
  CheckNumber(Parsed.SackBlockCount, 0, 'no SACK blocks on a SYN');
end;

procedure TestSynWithFewer;
var
  Options: TTcpOptions;
  Parsed: TTcpOptions;
  Buffer: array[0..63] of Byte;
  Length: LongWord;
begin
  { What answers a peer that offered only the MSS and SACK. }
  ClearTcpOptions(Options);
  Options.HasMaximumSegment := True;
  Options.MaximumSegment := 536;
  Options.SackPermitted := True;
  Length := WriteTcpOptions(@Buffer[0], Options, True);
  CheckNumber(Length, 8, 'MSS and SACK permitted');
  Check(BytesMatch(@Buffer[0], [2, 4, 2, $18, 1, 1, 4, 2]), 'SACK permitted padded with two no-operations');
  ParseTcpOptions(@Buffer[0], Length, Parsed);
  Check(Parsed.SackPermitted and not Parsed.HasTimestamps and not Parsed.HasWindowScale,
    'only SACK permitted reads back');

  ClearTcpOptions(Options);
  Options.HasMaximumSegment := True;
  Options.MaximumSegment := 1440;
  Options.HasTimestamps := True;
  Options.TimestampValue := 7;
  Options.TimestampEcho := 9;
  Length := WriteTcpOptions(@Buffer[0], Options, True);
  CheckNumber(Length, 16, 'MSS and timestamps');
  CheckNumber(Length mod 4, 0, 'a multiple of four');
  ParseTcpOptions(@Buffer[0], Length, Parsed);
  Check(Parsed.HasTimestamps and (Parsed.TimestampValue = 7) and (Parsed.TimestampEcho = 9),
    'timestamps alone read back');
end;

procedure TestAckOptions;
var
  Options: TTcpOptions;
  Parsed: TTcpOptions;
  Buffer: array[0..63] of Byte;
  Length: LongWord;
begin
  ClearTcpOptions(Options);
  Options.HasTimestamps := True;
  Options.TimestampValue := 1000;
  Options.TimestampEcho := 2000;
  CheckNumber(SackBlocksThatFit(Options, MaximumTcpOptionBytes), 3, 'three SACK blocks beside timestamps');
  Options.SackBlockCount := 3;
  Options.SackBlocks[0].Start := 3000;
  Options.SackBlocks[0].Finish := 4000;
  Options.SackBlocks[1].Start := 5000;
  Options.SackBlocks[1].Finish := 6000;
  Options.SackBlocks[2].Start := $FFFFFF00;
  Options.SackBlocks[2].Finish := $100;
  CheckNumber(TcpOptionsLength(Options, False), 40, 'timestamps and three blocks fill the 40 bytes');
  Length := WriteTcpOptions(@Buffer[0], Options, False);
  CheckNumber(Length, 40, 'the bytes written for an ACK');
  Check(BytesMatch(@Buffer[0], [1, 1, 8, 10]), 'the timestamps lead, after two no-operations');
  Check(BytesMatch(@Buffer[12], [1, 1, 5, 26]), 'the SACK option: three blocks, 26 bytes');
  ParseTcpOptions(@Buffer[0], Length, Parsed);
  CheckNumber(Parsed.SackBlockCount, 3, 'three blocks read back');
  Check((Parsed.SackBlocks[1].Start = 5000) and (Parsed.SackBlocks[1].Finish = 6000), 'the second block');
  Check((Parsed.SackBlocks[2].Start = $FFFFFF00) and (Parsed.SackBlocks[2].Finish = $100),
    'a block across the wrap');
  Check(Parsed.HasTimestamps and (Parsed.TimestampEcho = 2000), 'TSecr reads back');
  Check(not Parsed.SackPermitted and not Parsed.HasWindowScale, 'nothing else');

  ClearTcpOptions(Options);
  CheckNumber(SackBlocksThatFit(Options, MaximumTcpOptionBytes), 4, 'four SACK blocks without timestamps');
  CheckNumber(SackBlocksThatFit(Options, 11), 0, 'no block in 11 bytes');
  CheckNumber(SackBlocksThatFit(Options, 12), 1, 'one block in 12 bytes');
  { The SYN-only options are not written on an ACK. }
  Options.HasWindowScale := True;
  Options.WindowShift := 3;
  Options.SackPermitted := True;
  CheckNumber(TcpOptionsLength(Options, False), 0, 'a window scale and SACK permitted stay off an ACK');
end;

procedure TestMalformedOptions;
var
  Parsed: TTcpOptions;
  Bytes: array[0..15] of Byte;
begin
  { An unknown option is passed over. }
  Bytes[0] := 30; Bytes[1] := 4; Bytes[2] := 0; Bytes[3] := 0;
  Bytes[4] := 2; Bytes[5] := 4; Bytes[6] := $02; Bytes[7] := $18;
  ParseTcpOptions(@Bytes[0], 8, Parsed);
  Check(Parsed.HasMaximumSegment and (Parsed.MaximumSegment = 536), 'past an unknown option');
  { A length of 0 or 1 ends reading. }
  Bytes[0] := 2; Bytes[1] := 0;
  ParseTcpOptions(@Bytes[0], 8, Parsed);
  Check(not Parsed.HasMaximumSegment, 'a zero length ends reading');
  { A length past the end ends reading. }
  Bytes[0] := 8; Bytes[1] := 10;
  ParseTcpOptions(@Bytes[0], 8, Parsed);
  Check(not Parsed.HasTimestamps, 'an option past the end is not read');
  { The wrong length for its kind: passed over. }
  Bytes[0] := 2; Bytes[1] := 3; Bytes[2] := 9;
  Bytes[3] := 3; Bytes[4] := 3; Bytes[5] := 20;
  Bytes[6] := 0;
  ParseTcpOptions(@Bytes[0], 8, Parsed);
  Check(not Parsed.HasMaximumSegment, 'an MSS of three bytes is ignored');
  Check(Parsed.HasWindowScale and (Parsed.WindowShift = MaximumWindowShift), 'a window scale of 20 is taken as 14');
  { A SACK option whose length is not 2 + 8n. }
  Bytes[0] := 5; Bytes[1] := 7;
  ParseTcpOptions(@Bytes[0], 8, Parsed);
  CheckNumber(Parsed.SackBlockCount, 0, 'a SACK option of 7 bytes');
  { End of options. }
  Bytes[0] := 0; Bytes[1] := 2; Bytes[2] := 4; Bytes[3] := 5; Bytes[4] := $B4;
  ParseTcpOptions(@Bytes[0], 5, Parsed);
  Check(not Parsed.HasMaximumSegment, 'nothing after the end of options');
end;

{ --- Windows ---------------------------------------------------------------- }

procedure TestWindows;
begin
  CheckNumber(LargestWindow(0), 65535, 'the largest unscaled window');
  CheckNumber(LargestWindow(OwnWindowShift), 65535 * 128, 'the largest window with our shift');
  Check(LargestWindow(OwnWindowShift) >= MaximumReceiveBufferBytes, 'our shift covers the largest buffer');
  CheckNumber(LargestWindow(14), 65535 shl 14, 'the largest window of all (about 1 GiB)');
  CheckNumber(ScaledWindowField(65535, 0, 0), 65535, 'no scaling');
  CheckNumber(ScaledWindowField(100000, 0, 0), 65535, 'unscaled: at most 65535');
  CheckNumber(ScaledWindowField(1000000, 0, 7), 7812, 'a megabyte in 128-byte units, rounded down');
  CheckNumber(ScaledWindowField(4 * 1024 * 1024, 0, 7), 32768, '4 MiB');
  CheckNumber(ScaledWindowField(100 * 1024 * 1024, 0, 7), 65535, 'at most 65535 units');
  { Data arrived but was not read: the room shrank, the promise holds. }
  CheckNumber(ScaledWindowField(1000, 1100, 7), 9, 'raised to cover what was promised (rounded up)');
  CheckNumber(ScaledWindowField(1280, 1280, 7), 10, 'exact units stay');
  CheckNumber(ScaledWindowField(0, 0, 7), 0, 'a zero window');
  CheckNumber(ScaledWindowField(127, 0, 7), 0, 'less than a unit is a zero window');
  CheckNumber(WindowFromField(7812, 7), 999936, 'a scaled field from the peer');
  CheckNumber(WindowFromField(65535, 14), 65535 shl 14, 'the largest field and shift');

  CheckNumber(TunedReceiveBuffer(65536, 10000, MaximumReceiveBufferBytes), 65536,
    'a slow reader keeps 64 KiB');
  CheckNumber(TunedReceiveBuffer(65536, 65536, MaximumReceiveBufferBytes), 262144,
    'a reader of 64 KiB per round trip gets 256 KiB');
  CheckNumber(TunedReceiveBuffer(65536, 300000, MaximumReceiveBufferBytes), 2097152,
    'doubling up to four times the round trip''s bytes');
  CheckNumber(TunedReceiveBuffer(65536, 50000000, MaximumReceiveBufferBytes), MaximumReceiveBufferBytes,
    'at most 4 MiB');
  CheckNumber(TunedReceiveBuffer(MaximumReceiveBufferBytes, 50000000, MaximumReceiveBufferBytes),
    MaximumReceiveBufferBytes, 'a full-size buffer stays');
  CheckNumber(TunedSendBuffer(65536, 14600, 1000000, MaximumSendBufferBytes), 65536,
    'a small congestion window keeps 64 KiB');
  CheckNumber(TunedSendBuffer(65536, 200000, 1000000, MaximumSendBufferBytes), 524288,
    'twice the congestion window, doubled');
  CheckNumber(TunedSendBuffer(65536, 2000000, 65535, MaximumSendBufferBytes), 131072,
    'the peer''s window limits it too');
end;

{ --- The SACK scoreboard ---------------------------------------------------- }

const
  Mss = 1000;
  Base = $FFFFF000;  { close to the wrap, to catch unsigned comparisons }

function At(Segment: LongWord): LongWord;
begin
  Result := LongWord(QWord(Base) + QWord(Segment) * Mss);
end;

procedure TestScoreboardRanges;
var
  Board: TSackScoreboard;
begin
  ClearScoreboard(Board);
  Check(AddSackBlock(Board, At(2), At(3), At(0), At(10)), 'a new block is news');
  Check(not AddSackBlock(Board, At(2), At(3), At(0), At(10)), 'the same block again is not');
  Check(AddSackBlock(Board, At(5), At(6), At(0), At(10)), 'a second block');
  CheckNumber(Board.Count, 2, 'two ranges');
  Check(AddSackBlock(Board, At(3), At(5), At(0), At(10)), 'the gap between them filled');
  CheckNumber(Board.Count, 1, 'merged into one range');
  Check((Board.Ranges[0].Start = At(2)) and (Board.Ranges[0].Finish = At(6)), 'from segment 2 to 6');
  CheckNumber(SackedBytes(Board), 4 * Mss, 'four segments SACKed');
  Check(not AddSackBlock(Board, At(9), At(11), At(0), At(10)), 'a block beyond what was sent is ignored');
  Check(not AddSackBlock(Board, At(0) - 100, At(1), At(0), At(10)), 'a block below the acknowledgment is ignored');
  Check(not AddSackBlock(Board, At(4), At(4), At(0), At(10)), 'an empty block is ignored');
  Check(AddSackBlock(Board, At(1), At(7), At(0), At(10)), 'a block over the whole range and more');
  CheckNumber(Board.Count, 1, 'still one range');
  Check((Board.Ranges[0].Start = At(1)) and (Board.Ranges[0].Finish = At(7)), 'from segment 1 to 7');
  Check(IsSacked(Board, At(3)) and not IsSacked(Board, At(7)) and not IsSacked(Board, At(0)), 'IsSacked');
  TrimScoreboard(Board, At(3));
  Check((Board.Count = 1) and (Board.Ranges[0].Start = At(3)), 'the acknowledgment trims the range');
  TrimScoreboard(Board, At(8));
  CheckNumber(Board.Count, 0, 'and drops it once past');
end;

procedure TestScoreboardFull;
var
  Board: TSackScoreboard;
  Index: LongWord;
begin
  ClearScoreboard(Board);
  for Index := 0 to MaximumScoreboardRanges + 3 do
    AddSackBlock(Board, At(2 * Index + 1), At(2 * Index + 2), At(0), At(200));
  CheckNumber(Board.Count, MaximumScoreboardRanges, 'a full scoreboard keeps its limit');
  Check(Board.Ranges[0].Start = At(1), 'the lowest range stays');
  { A low block still gets in: the highest gives way. }
  ClearScoreboard(Board);
  for Index := 1 to MaximumScoreboardRanges do
    AddSackBlock(Board, At(2 * Index + 10), At(2 * Index + 11), At(0), At(200));
  AddSackBlock(Board, At(1), At(2), At(0), At(200));
  Check((Board.Count = MaximumScoreboardRanges) and (Board.Ranges[0].Start = At(1)),
    'a low block pushes out the highest');
end;

{ Segments 0..9 sent; 1, 4 and 7 lost; the others SACKed. }
procedure TestRecoveryScenario;
var
  Board: TSackScoreboard;
  Sequence: LongWord;
  Length: LongWord;
begin
  ClearScoreboard(Board);
  AddSackBlock(Board, At(2), At(4), At(0), At(10));
  AddSackBlock(Board, At(5), At(7), At(0), At(10));
  AddSackBlock(Board, At(8), At(10), At(0), At(10));
  { Segment 0 was acknowledged. }
  TrimScoreboard(Board, At(1));
  CheckNumber(Board.Count, 3, 'three ranges');
  Check(IsLost(Board, At(1), Mss), 'segment 1: three ranges above it, lost');
  { Only two ranges above segment 4, but four segments (4000 bytes):
    more than 2 * MSS, so lost; above 7 only two segments. }
  Check(IsLost(Board, At(4), Mss), 'segment 4: more than two segments SACKed above, lost');
  Check(not IsLost(Board, At(7), Mss), 'segment 7: only two segments above, not lost');
  { Pipe before anything is retransmitted: only hole 7 counts. }
  CheckNumber(ScoreboardPipe(Board, At(1), At(10), At(1), Mss), Mss, 'the pipe: the hole not lost');
  Check(NextRetransmission(Board, At(1), At(1), Mss, True, Sequence, Length) and
    (Sequence = At(1)) and (Length = Mss), 'rule 1: segment 1 first');
  CheckNumber(ScoreboardPipe(Board, At(1), At(10), At(2), Mss), 2 * Mss, 'segment 1 resent: in the pipe');
  Check(NextRetransmission(Board, At(1), At(2), Mss, True, Sequence, Length) and
    (Sequence = At(4)), 'rule 1: then segment 4');
  Check(not NextRetransmission(Board, At(1), At(5), Mss, True, Sequence, Length),
    'rule 1: nothing else is lost');
  Check(NextRetransmission(Board, At(1), At(5), Mss, False, Sequence, Length) and
    (Sequence = At(7)), 'rule 3: segment 7, not known lost');
  CheckNumber(ScoreboardPipe(Board, At(1), At(12), At(5), Mss), 5 * Mss,
    'two resent, hole 7, two new segments');
  { Segment 1 arrives: the acknowledgment moves to 4. }
  TrimScoreboard(Board, At(4));
  CheckNumber(Board.Count, 2, 'two ranges left');
  Check(not IsSacked(Board, At(3)), 'below the acknowledgment nothing is SACKed');
end;

procedure TestPartialSegments;
var
  Board: TSackScoreboard;
  Sequence: LongWord;
  Length: LongWord;
begin
  ClearScoreboard(Board);
  AddSackBlock(Board, At(3), At(6), At(0), At(6));
  { A hole of three segments: resent one segment at a time. }
  Check(NextRetransmission(Board, At(0), At(0), Mss, True, Sequence, Length) and (Length = Mss),
    'at most one segment');
  Check(NextRetransmission(Board, At(0), At(0) + 1500, Mss, True, Sequence, Length) and
    (Sequence = At(0) + 1500) and (Length = Mss), 'from where retransmission stopped');
  Check(NextRetransmission(Board, At(0), At(2) + 500, Mss, True, Sequence, Length) and (Length = 500),
    'the end of the hole');
end;

{ --- The receiver's blocks ------------------------------------------------- }

procedure TestReceivedBlocks;
var
  Blocks: TReceivedBlocks;
begin
  ClearReceivedBlocks(Blocks);
  RememberReceivedBlock(Blocks, At(2), At(3));
  RememberReceivedBlock(Blocks, At(5), At(6));
  CheckNumber(Blocks.Count, 2, 'two blocks');
  Check(Blocks.Blocks[0].Start = At(5), 'the latest first');
  { Segment 3 joins the first run: that block leads now. }
  RememberReceivedBlock(Blocks, At(2), At(4));
  Check((Blocks.Count = 2) and (Blocks.Blocks[0].Start = At(2)) and (Blocks.Blocks[0].Finish = At(4)),
    'a grown block moves to the front');
  Check(Blocks.Blocks[1].Start = At(5), 'the other follows');
  { Segment 4 joins both runs. }
  RememberReceivedBlock(Blocks, At(2), At(6));
  Check((Blocks.Count = 1) and (Blocks.Blocks[0].Finish = At(6)), 'one block swallows the other');
  RememberReceivedBlock(Blocks, At(8), At(9));
  RememberReceivedBlock(Blocks, At(10), At(11));
  RememberReceivedBlock(Blocks, At(12), At(13));
  RememberReceivedBlock(Blocks, At(14), At(15));
  CheckNumber(Blocks.Count, MaximumSackBlocks, 'at most four remembered');
  Check(Blocks.Blocks[0].Start = At(14), 'the newest leads');
  Check(Blocks.Blocks[3].Start = At(8), 'the oldest of those kept is last');
  ForgetReceivedBlocks(Blocks, At(10) + 500);
  CheckNumber(Blocks.Count, 3, 'the acknowledgment drops a block it passed');
  Check(Blocks.Blocks[2].Start = At(10) + 500, 'and trims one it reached into');
end;

{ --- SipHash and the keyed numbers ----------------------------------------- }

function ReferenceKey: TSipHashKey;
var
  Bytes: array[0..15] of Byte;
  Index: Integer;
begin
  for Index := 0 to 15 do
    Bytes[Index] := Index;
  Result := SipHashKeyFromBytes(@Bytes[0]);
end;

procedure TestSipHash;
const
  Lengths: array[0..5] of LongWord = (0, 1, 7, 8, 15, 63);
  Expected: array[0..5] of QWord = (QWord($726FDB47DD0E0E31), QWord($74F839C593DC67FD),
    QWord($AB0200F58B01D137), QWord($93F5F5799A932462), QWord($A129CA6149BE45E5), QWord($958A324CEB064572));
var
  Message: array[0..63] of Byte;
  Index: Integer;
  Key: TSipHashKey;
begin
  for Index := 0 to 63 do
    Message[Index] := Index;
  Key := ReferenceKey;
  for Index := 0 to High(Lengths) do
    Check(SipHash24(Key, @Message[0], Lengths[Index]) = Expected[Index],
      'SipHash-2-4 of ' + IntToStr(Lengths[Index]) + ' bytes matches the reference');
end;

procedure TestKeyedNumbers;
var
  Key: TSipHashKey;
  OtherKey: TSipHashKey;
  Local: TKeyedEndpoint;
  Remote: TKeyedEndpoint;
  OtherRemote: TKeyedEndpoint;
  First: LongWord;
  Table: TPerturbationTable;
  Seen: array[49152..65535] of Boolean;
  Attempt: LongWord;
  Port: Word;
  AllSeen: Boolean;
begin
  Key := ReferenceKey;
  OtherKey := Key;
  OtherKey.Second := OtherKey.Second xor 1;
  Local := KeyedIpv4Endpoint($0A00020F, 49200);
  Remote := KeyedIpv4Endpoint($5DB8D822, 443);
  OtherRemote := KeyedIpv4Endpoint($5DB8D822, 80);
  First := KeyedInitialSequence(Key, Local, Remote, 0);
  CheckNumber(KeyedInitialSequence(Key, Local, Remote, 0), First, 'the same endpoints, the same ISN');
  CheckNumber(KeyedInitialSequence(Key, Local, Remote, 4000 * 1000), LongWord(First + 1000),
    'the ISN moves on with the 4-microsecond clock');
  Check(KeyedInitialSequence(Key, Local, OtherRemote, 0) <> First, 'another peer port, another ISN offset');
  Check(KeyedInitialSequence(OtherKey, Local, Remote, 0) <> First, 'another key, another ISN offset');
  Check(LongWord(KeyedInitialSequence(Key, Local, OtherRemote, 0) - First) <> 64000,
    'not the old fixed step between connections');
  Check(KeyedTimestampOffset(Key, Local, Remote) <> KeyedTimestampOffset(Key, Local, OtherRemote),
    'timestamp offsets differ between connections');
  Check(PerturbationIndex(Key, Local, Remote) < PerturbationTableLength, 'the counter index is in the table');

  FillChar(Table, SizeOf(Table), 0);
  CheckNumber(TakePerturbation(Table, 5, 3), 0, 'a counter starts where it is');
  CheckNumber(TakePerturbation(Table, 5, 0), 3, 'and moves on by the step (at least 1)');
  CheckNumber(TakePerturbation(Table, 5 + PerturbationTableLength, 1), 4, 'the index wraps the table');

  FillChar(Seen, SizeOf(Seen), 0);
  Attempt := 0;
  while Attempt <= 65535 - 49152 do
  begin
    Port := DynamicPortCandidate($DEADBEEF, 77, Attempt, 49152, 65535);
    Check(Port >= 49152, 'a port candidate in the dynamic range');
    if Port >= 49152 then
      Seen[Port] := True;
    Inc(Attempt);
  end;
  AllSeen := True;
  for Port := 49152 to 65535 do
    if not Seen[Port] then
      AllSeen := False;
  Check(AllSeen, 'the candidates cover the whole range');
  Check(DynamicPortCandidate(LongWord(HashEndpoints(Key, Local, Remote)), 0, 0, 49152, 65535) <>
    DynamicPortCandidate(LongWord(HashEndpoints(Key, Local, OtherRemote)), 0, 0, 49152, 65535),
    'searches towards different peers start apart');

  Check(KeyedIpv4Identification(Key, $0A00020F, $5DB8D822, 6, 0) <>
    KeyedIpv4Identification(Key, $0A00020F, $5DB8D823, 6, 0), 'identifications differ by destination');
  CheckNumber(Word(KeyedIpv4Identification(Key, 1, 2, 17, 9) - KeyedIpv4Identification(Key, 1, 2, 17, 8)), 1,
    'the counter steps an identification by one');
  Check(Ipv4IdentificationIndex(Key, 1, 2, 17) < PerturbationTableLength, 'the identification counter index');
end;

{ --- RFC 5961 and the window test ----------------------------------------- }

procedure TestAcceptance;
begin
  Check(SegmentIsAcceptable(1000, 100, 1000, 500), 'data at RCV.NXT in the window');
  Check(SegmentIsAcceptable(900, 200, 1000, 500), 'data reaching into the window from before');
  Check(not SegmentIsAcceptable(800, 100, 1000, 500), 'data wholly before the window');
  Check(not SegmentIsAcceptable(1500, 10, 1000, 500), 'data just past the window');
  Check(SegmentIsAcceptable(1499, 0, 1000, 500), 'an empty segment at the window''s last byte');
  Check(SegmentIsAcceptable($FFFFFFF0, 32, $FFFFFFF8, 100), 'acceptable across the wrap');
  { RFC 9293 3.10.7.4: a zero window still takes ACKs and RSTs at
    RCV.NXT, even on a segment that carries data. }
  Check(SegmentIsAcceptable(1000, 100, 1000, 0), 'zero window: data at RCV.NXT is taken for its ACK');
  Check(SegmentIsAcceptable(1000, 0, 1000, 0), 'zero window: an empty segment at RCV.NXT');
  Check(not SegmentIsAcceptable(1001, 0, 1000, 0), 'zero window: anything else is not');

  Check(ResetDisposition(1000, 1000, 500) = ResetAccepted, 'a reset at exactly RCV.NXT ends the connection');
  Check(ResetDisposition(1200, 1000, 500) = ResetChallenged, 'a reset elsewhere in the window: challenge ACK');
  Check(ResetDisposition(2000, 1000, 500) = ResetDropped, 'a reset outside the window is dropped');
  Check(ResetDisposition(999, 1000, 500) = ResetDropped, 'a reset just before the window is dropped');

  Check(AcknowledgmentDisposition(5000, 5000, 6000, 1000) = AcknowledgmentAcceptable, 'ACK of SND.UNA');
  Check(AcknowledgmentDisposition(6000, 5000, 6000, 1000) = AcknowledgmentAcceptable, 'ACK of SND.MAX');
  Check(AcknowledgmentDisposition(6001, 5000, 6000, 1000) = AcknowledgmentTooNew, 'ACK of what was never sent');
  Check(AcknowledgmentDisposition(4000, 5000, 6000, 1000) = AcknowledgmentAcceptable,
    'an old ACK within MAX.SND.WND is acceptable');
  Check(AcknowledgmentDisposition(3999, 5000, 6000, 1000) = AcknowledgmentTooOld,
    'an ACK older than SND.UNA - MAX.SND.WND is not (RFC 5961 5.2)');
  Check(AcknowledgmentDisposition(LongWord($80000000) + 5000, 5000, 6000, 1000) = AcknowledgmentTooNew,
    'an ACK half the sequence space away');
  Check(AcknowledgmentDisposition($FFFFFF00, $10, $20, $200) = AcknowledgmentAcceptable,
    'the range across the wrap');
end;

procedure TestTokenBuckets;
const
  Second = QWord(1000000000);
var
  Bucket: TTokenBucket;
  Taken: Integer;
  Index: Integer;
begin
  InitializeTokenBucket(Bucket, 10, 5);
  Taken := 0;
  for Index := 1 to 20 do
    if TakeToken(Bucket, Second) then
      Inc(Taken);
  CheckNumber(Taken, 5, 'a full bucket gives its burst at once');
  Check(not TakeToken(Bucket, Second + Second div 20), 'half a token''s time later: nothing');
  Check(TakeToken(Bucket, Second + Second div 10), 'a tenth of a second at 10 per second: one');
  Check(not TakeToken(Bucket, Second + Second div 10), 'and only one');
  Taken := 0;
  for Index := 1 to 20 do
    if TakeToken(Bucket, 100 * Second) then
      Inc(Taken);
  CheckNumber(Taken, 5, 'a long quiet refills no more than the burst');
  Check(not TakeToken(Bucket, 50 * Second), 'a clock that goes back gives nothing');
end;

begin
  TestSipHash;
  TestKeyedNumbers;
  TestAcceptance;
  TestTokenBuckets;
  TestSequences;
  TestSynWithEverything;
  TestSynWithFewer;
  TestAckOptions;
  TestMalformedOptions;
  TestWindows;
  TestScoreboardRanges;
  TestScoreboardFull;
  TestRecoveryScenario;
  TestPartialSegments;
  TestReceivedBlocks;
  if Failures > 0 then
  begin
    WriteLn('TCP TEST: ', Failures, ' failed');
    Halt(1);
  end;
  WriteLn('TCP TEST: passed');
end.
