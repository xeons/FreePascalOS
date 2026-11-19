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
  The SACK scoreboard of a sending connection (RFC 6675).

  It keeps what the peer reported holding above its cumulative
  acknowledgment: up to 32 ranges of sequence space, in order, apart
  (merged when they touch). The holes between them, from the first
  unacknowledged byte up to the last SACKed one, are what may be lost.

  - IsLost: a byte is taken as lost once three separate ranges, or more
    than two segments' worth of bytes, were SACKed above it (DupThresh
    3). Within one hole every byte has the same SACKed bytes above it,
    so a hole is lost or not as a whole.
  - Pipe: the bytes taken to be in the network - every unSACKed byte
    not lost, plus every byte of a hole retransmitted in this recovery
    (those below RetransmittedUpTo).
  - NextRetransmission: the first stretch (at most one segment) of a
    hole above RetransmittedUpTo - lost ones only for rule 1 of NextSeg,
    any for rule 3.

  A block that is not wholly between the first unacknowledged byte and
  the highest byte sent is ignored (RFC 2018 says such blocks are not
  to be trusted; a D-SACK below the acknowledgment is one). When the
  scoreboard is full the highest range gives way: the lower ones decide
  what is retransmitted next.

  Pure: no kernel units, so the host test (tools/TcpTest) builds it.
}
unit Network.TcpScoreboard;

{$mode objfpc}

interface

uses
  Network.TcpOptions;

const
  MaximumScoreboardRanges = 32;
  DuplicateThreshold = 3;

type
  TSackScoreboard = record
    Count: LongWord;
    Ranges: array[0..MaximumScoreboardRanges - 1] of TSackBlock;
  end;

procedure ClearScoreboard(out Board: TSackScoreboard);
{ Adds a block the peer reported; True if it SACKed a byte not SACKed
  before. }
function AddSackBlock(var Board: TSackScoreboard; Start, Finish, SendUnacknowledged,
  SendMaximum: LongWord): Boolean;
{ Forgets what the cumulative acknowledgment now covers. }
procedure TrimScoreboard(var Board: TSackScoreboard; SendUnacknowledged: LongWord);
function SackedBytes(constref Board: TSackScoreboard): LongWord;
function IsSacked(constref Board: TSackScoreboard; Sequence: LongWord): Boolean;
{ RFC 6675 IsLost for the byte at Sequence (Mss: the sender's segment
  size). }
function IsLost(constref Board: TSackScoreboard; Sequence, Mss: LongWord): Boolean;
{ RFC 6675 SetPipe: the bytes in the network. }
function ScoreboardPipe(constref Board: TSackScoreboard; SendUnacknowledged, SendMaximum,
  RetransmittedUpTo, Mss: LongWord): LongWord;
{ The next stretch of a hole to send again, at or above
  RetransmittedUpTo, at most Mss bytes; lost holes only if OnlyLost.
  False if there is none. }
function NextRetransmission(constref Board: TSackScoreboard; SendUnacknowledged, RetransmittedUpTo,
  Mss: LongWord; OnlyLost: Boolean; out Sequence, Length: LongWord): Boolean;

implementation

uses
  Network.TcpSequences;

procedure ClearScoreboard(out Board: TSackScoreboard);
begin
  FillChar(Board, SizeOf(Board), 0);
end;

procedure RemoveRange(var Board: TSackScoreboard; Index: LongWord);
begin
  while Index + 1 < Board.Count do
  begin
    Board.Ranges[Index] := Board.Ranges[Index + 1];
    Inc(Index);
  end;
  Dec(Board.Count);
end;

procedure InsertRange(var Board: TSackScoreboard; Index, Start, Finish: LongWord);
var
  Position: LongWord;
begin
  if Board.Count = MaximumScoreboardRanges then
  begin
    { Full: the highest range gives way, unless it is the new one. }
    if Index = Board.Count then
      Exit;
    Dec(Board.Count);
  end;
  Position := Board.Count;
  while Position > Index do
  begin
    Board.Ranges[Position] := Board.Ranges[Position - 1];
    Dec(Position);
  end;
  Board.Ranges[Index].Start := Start;
  Board.Ranges[Index].Finish := Finish;
  Inc(Board.Count);
end;

{ Joins the range at Index with those after it that it reaches. }
procedure MergeFollowing(var Board: TSackScoreboard; Index: LongWord);
begin
  while (Index + 1 < Board.Count) and
        SequenceAfterOrEqual(Board.Ranges[Index].Finish, Board.Ranges[Index + 1].Start) do
  begin
    Board.Ranges[Index].Finish := LaterSequence(Board.Ranges[Index].Finish, Board.Ranges[Index + 1].Finish);
    RemoveRange(Board, Index + 1);
  end;
end;

function CoveredBytes(constref Board: TSackScoreboard; Start, Finish: LongWord): LongWord;
var
  Index: LongWord;
  From: LongWord;
  UpTo: LongWord;
begin
  Result := 0;
  Index := 0;
  while Index < Board.Count do
  begin
    From := LaterSequence(Start, Board.Ranges[Index].Start);
    UpTo := EarlierSequence(Finish, Board.Ranges[Index].Finish);
    if SequenceBefore(From, UpTo) then
      Result := Result + SequenceDistance(From, UpTo);
    Inc(Index);
  end;
end;

function AddSackBlock(var Board: TSackScoreboard; Start, Finish, SendUnacknowledged,
  SendMaximum: LongWord): Boolean;
var
  Index: LongWord;
begin
  Result := False;
  if not SequenceBefore(Start, Finish) or SequenceBefore(Start, SendUnacknowledged) or
     SequenceAfter(Finish, SendMaximum) then
    Exit;
  Result := CoveredBytes(Board, Start, Finish) < SequenceDistance(Start, Finish);
  if not Result then
    Exit;
  { The first range that starts after the block. }
  Index := 0;
  while (Index < Board.Count) and SequenceBeforeOrEqual(Board.Ranges[Index].Start, Start) do
    Inc(Index);
  if (Index > 0) and SequenceAfterOrEqual(Board.Ranges[Index - 1].Finish, Start) then
  begin
    { It reaches the range before. }
    Board.Ranges[Index - 1].Finish := LaterSequence(Board.Ranges[Index - 1].Finish, Finish);
    MergeFollowing(Board, Index - 1);
    Exit;
  end;
  InsertRange(Board, Index, Start, Finish);
  if (Index < Board.Count) and (Board.Ranges[Index].Start = Start) then
    MergeFollowing(Board, Index);
end;

procedure TrimScoreboard(var Board: TSackScoreboard; SendUnacknowledged: LongWord);
begin
  while (Board.Count > 0) and SequenceBeforeOrEqual(Board.Ranges[0].Finish, SendUnacknowledged) do
    RemoveRange(Board, 0);
  if (Board.Count > 0) and SequenceBefore(Board.Ranges[0].Start, SendUnacknowledged) then
    Board.Ranges[0].Start := SendUnacknowledged;
end;

function SackedBytes(constref Board: TSackScoreboard): LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  Index := 0;
  while Index < Board.Count do
  begin
    Result := Result + SequenceDistance(Board.Ranges[Index].Start, Board.Ranges[Index].Finish);
    Inc(Index);
  end;
end;

function IsSacked(constref Board: TSackScoreboard; Sequence: LongWord): Boolean;
var
  Index: LongWord;
begin
  Index := 0;
  while Index < Board.Count do
  begin
    if SequenceAfterOrEqual(Sequence, Board.Ranges[Index].Start) and
       SequenceBefore(Sequence, Board.Ranges[Index].Finish) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function IsLost(constref Board: TSackScoreboard; Sequence, Mss: LongWord): Boolean;
var
  Index: LongWord;
  RangesAbove: LongWord;
  BytesAbove: QWord;
begin
  RangesAbove := 0;
  BytesAbove := 0;
  Index := 0;
  while Index < Board.Count do
  begin
    if SequenceAfter(Board.Ranges[Index].Finish, Sequence + 1) then
    begin
      Inc(RangesAbove);
      BytesAbove := BytesAbove + SequenceDistance(LaterSequence(Board.Ranges[Index].Start, Sequence + 1),
        Board.Ranges[Index].Finish);
    end;
    Inc(Index);
  end;
  Result := (RangesAbove >= DuplicateThreshold) or (BytesAbove > QWord(DuplicateThreshold - 1) * Mss);
end;

{ What a hole from HoleStart up to HoleEnd adds to the pipe. }
function HolePipe(constref Board: TSackScoreboard; HoleStart, HoleEnd, RetransmittedUpTo,
  Mss: LongWord): LongWord;
begin
  Result := 0;
  if not IsLost(Board, HoleStart, Mss) then
    Result := SequenceDistance(HoleStart, HoleEnd);
  if SequenceAfter(RetransmittedUpTo, HoleStart) then
    Result := Result + SequenceDistance(HoleStart, EarlierSequence(RetransmittedUpTo, HoleEnd));
end;

function ScoreboardPipe(constref Board: TSackScoreboard; SendUnacknowledged, SendMaximum,
  RetransmittedUpTo, Mss: LongWord): LongWord;
var
  Index: LongWord;
  Position: LongWord;
begin
  Result := 0;
  Position := SendUnacknowledged;
  Index := 0;
  while Index < Board.Count do
  begin
    if SequenceBefore(Position, Board.Ranges[Index].Start) then
      Result := Result + HolePipe(Board, Position, Board.Ranges[Index].Start, RetransmittedUpTo, Mss);
    Position := LaterSequence(Position, Board.Ranges[Index].Finish);
    Inc(Index);
  end;
  { Above everything SACKed: in flight, not lost. }
  if SequenceBefore(Position, SendMaximum) then
    Result := Result + SequenceDistance(Position, SendMaximum);
end;

function NextRetransmission(constref Board: TSackScoreboard; SendUnacknowledged, RetransmittedUpTo,
  Mss: LongWord; OnlyLost: Boolean; out Sequence, Length: LongWord): Boolean;
var
  Index: LongWord;
  Position: LongWord;
  HoleStart: LongWord;
  HoleEnd: LongWord;
begin
  Sequence := 0;
  Length := 0;
  Position := SendUnacknowledged;
  Index := 0;
  while Index < Board.Count do
  begin
    HoleStart := LaterSequence(Position, RetransmittedUpTo);
    HoleEnd := Board.Ranges[Index].Start;
    if SequenceBefore(HoleStart, HoleEnd) and (not OnlyLost or IsLost(Board, HoleStart, Mss)) then
    begin
      Sequence := HoleStart;
      Length := SequenceDistance(HoleStart, HoleEnd);
      if Length > Mss then
        Length := Mss;
      Exit(True);
    end;
    Position := LaterSequence(Position, Board.Ranges[Index].Finish);
    Inc(Index);
  end;
  Result := False;
end;

end.
