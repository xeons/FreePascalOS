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
  The SACK blocks a receiving connection reports (RFC 2018 4).

  The out-of-order queue holds what arrived ahead of the next expected
  byte; these are the blocks of it the acknowledgments name, most
  recent first: the block holding the segment that arrived last leads
  (the sender learns of every arrival at least once even when only
  three blocks fit), the others follow in the order they last changed.
  A block that grows swallows the older ones it now covers or touches;
  the cumulative acknowledgment passing a block drops it.

  Pure: no kernel units, so the host test (tools/TcpTest) builds it.
}
unit Network.TcpReceivedBlocks;

{$mode objfpc}

interface

uses
  Network.TcpOptions;

type
  TReceivedBlocks = record
    Count: LongWord;
    Blocks: array[0..MaximumSackBlocks - 1] of TSackBlock;
  end;

procedure ClearReceivedBlocks(out Blocks: TReceivedBlocks);
{ The out-of-order data from Start up to Finish (the whole run that
  holds the segment just stored) leads the list now. }
procedure RememberReceivedBlock(var Blocks: TReceivedBlocks; Start, Finish: LongWord);
{ Drops (or trims) what the next expected byte has passed. }
procedure ForgetReceivedBlocks(var Blocks: TReceivedBlocks; ReceiveNext: LongWord);

implementation

uses
  Runtime.Memory,
  Network.TcpSequences;

procedure ClearReceivedBlocks(out Blocks: TReceivedBlocks);
begin
  FillMemory(@Blocks, SizeOf(Blocks), 0);
end;

procedure RemoveBlock(var Blocks: TReceivedBlocks; Index: LongWord);
begin
  while Index + 1 < Blocks.Count do
  begin
    Blocks.Blocks[Index] := Blocks.Blocks[Index + 1];
    Inc(Index);
  end;
  Dec(Blocks.Count);
end;

function BlocksTouch(constref Block: TSackBlock; Start, Finish: LongWord): Boolean;
begin
  Result := SequenceBeforeOrEqual(Block.Start, Finish) and SequenceAfterOrEqual(Block.Finish, Start);
end;

procedure RememberReceivedBlock(var Blocks: TReceivedBlocks; Start, Finish: LongWord);
var
  Index: LongWord;
begin
  if not SequenceBefore(Start, Finish) then
    Exit;
  Index := 0;
  while Index < Blocks.Count do
  begin
    if BlocksTouch(Blocks.Blocks[Index], Start, Finish) then
    begin
      Start := EarlierSequence(Start, Blocks.Blocks[Index].Start);
      Finish := LaterSequence(Finish, Blocks.Blocks[Index].Finish);
      RemoveBlock(Blocks, Index);
    end
    else
      Inc(Index);
  end;
  if Blocks.Count = MaximumSackBlocks then
    Dec(Blocks.Count);
  Index := Blocks.Count;
  while Index > 0 do
  begin
    Blocks.Blocks[Index] := Blocks.Blocks[Index - 1];
    Dec(Index);
  end;
  Blocks.Blocks[0].Start := Start;
  Blocks.Blocks[0].Finish := Finish;
  Inc(Blocks.Count);
end;

procedure ForgetReceivedBlocks(var Blocks: TReceivedBlocks; ReceiveNext: LongWord);
var
  Index: LongWord;
begin
  Index := 0;
  while Index < Blocks.Count do
  begin
    if SequenceBeforeOrEqual(Blocks.Blocks[Index].Finish, ReceiveNext) then
      RemoveBlock(Blocks, Index)
    else
    begin
      if SequenceBefore(Blocks.Blocks[Index].Start, ReceiveNext) then
        Blocks.Blocks[Index].Start := ReceiveNext;
      Inc(Index);
    end;
  end;
end;

end.
