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
  The blocks of a datagram being put together from fragments: a bitmap
  of its 8-byte blocks, and how a new fragment fits what came before
  (RFC 8200 4.5, RFC 5722):

    * it fits: none of its blocks came yet, and it agrees with the end
      the last fragment set;
    * it is a duplicate: all its blocks came already (the caller then
      compares the bytes - an exact copy is dropped, anything else is an
      overlap);
    * it overlaps: some of its blocks came, or it disagrees about the
      end. The whole datagram is then given up, without an error to the
      sender (RFC 5722 3).

  Every fragment but the last is a multiple of 8 bytes long and starts
  on a multiple of 8, so two fragments that do not overlap never share
  a block. Pure: the host test builds it.
}
unit Network.ReassemblyBlocks;

{$mode objfpc}

interface

const
  ReassemblyBlockBytes = 8;
  MaximumReassemblyPayload = 65535;
  ReassemblyBlockCount = (MaximumReassemblyPayload + ReassemblyBlockBytes - 1) div ReassemblyBlockBytes;

type
  TReassemblyBlocks = record
    Bits: array[0..(ReassemblyBlockCount + 7) div 8 - 1] of Byte;
  end;

  TFragmentFit = (FragmentFits, FragmentDuplicate, FragmentOverlaps);

procedure ClearReassemblyBlocks(out Blocks: TReassemblyBlocks);
procedure MarkReassemblyBlocks(var Blocks: TReassemblyBlocks; Offset, Length: LongWord);
{ True if every block of the PayloadLength bytes came. }
function ReassemblyBlocksComplete(constref Blocks: TReassemblyBlocks; PayloadLength: LongWord): Boolean;
{ How a fragment of Length bytes at Offset fits; KnownPayloadLength is
  the length the last fragment gave (0 while it has not come). Offset +
  Length is at most MaximumReassemblyPayload. }
function ClassifyFragment(constref Blocks: TReassemblyBlocks; Offset, Length: LongWord; MoreFragments: Boolean;
  KnownPayloadLength: LongWord): TFragmentFit;

implementation

function BlockIsSet(constref Blocks: TReassemblyBlocks; Block: LongWord): Boolean;
begin
  Result := (Blocks.Bits[Block div 8] and (1 shl (Block mod 8))) <> 0;
end;

procedure ClearReassemblyBlocks(out Blocks: TReassemblyBlocks);
var
  Index: Integer;
begin
  for Index := 0 to High(Blocks.Bits) do
    Blocks.Bits[Index] := 0;
end;

procedure MarkReassemblyBlocks(var Blocks: TReassemblyBlocks; Offset, Length: LongWord);
var
  Block: LongWord;
  LastBlock: LongWord;
begin
  if Length = 0 then
    Exit;
  Block := Offset div ReassemblyBlockBytes;
  LastBlock := (Offset + Length - 1) div ReassemblyBlockBytes;
  while Block <= LastBlock do
  begin
    Blocks.Bits[Block div 8] := Blocks.Bits[Block div 8] or (1 shl (Block mod 8));
    Inc(Block);
  end;
end;

{ How many of the blocks First..Last are set. }
function CountSetBlocks(constref Blocks: TReassemblyBlocks; First, Last: LongWord): LongWord;
var
  Block: LongWord;
begin
  Result := 0;
  Block := First;
  while Block <= Last do
  begin
    if BlockIsSet(Blocks, Block) then
      Inc(Result);
    Inc(Block);
  end;
end;

function ReassemblyBlocksComplete(constref Blocks: TReassemblyBlocks; PayloadLength: LongWord): Boolean;
begin
  if PayloadLength = 0 then
    Exit(False);
  Result := CountSetBlocks(Blocks, 0, (PayloadLength - 1) div ReassemblyBlockBytes) =
    (PayloadLength - 1) div ReassemblyBlockBytes + 1;
end;

function ClassifyFragment(constref Blocks: TReassemblyBlocks; Offset, Length: LongWord; MoreFragments: Boolean;
  KnownPayloadLength: LongWord): TFragmentFit;
var
  FirstBlock: LongWord;
  LastBlock: LongWord;
  SetCount: LongWord;
  EndBlock: LongWord;
begin
  if KnownPayloadLength <> 0 then
  begin
    if Offset + Length > KnownPayloadLength then
      Exit(FragmentOverlaps);
    if not MoreFragments and (Offset + Length <> KnownPayloadLength) then
      Exit(FragmentOverlaps);
  end
  else if not MoreFragments then
  begin
    { A last fragment that ends before data already come. }
    EndBlock := (Offset + Length + ReassemblyBlockBytes - 1) div ReassemblyBlockBytes;
    if (EndBlock < ReassemblyBlockCount) and
       (CountSetBlocks(Blocks, EndBlock, ReassemblyBlockCount - 1) > 0) then
      Exit(FragmentOverlaps);
  end;
  if Length = 0 then
    Exit(FragmentFits);
  FirstBlock := Offset div ReassemblyBlockBytes;
  LastBlock := (Offset + Length - 1) div ReassemblyBlockBytes;
  SetCount := CountSetBlocks(Blocks, FirstBlock, LastBlock);
  if SetCount = 0 then
    Result := FragmentFits
  else if SetCount = LastBlock - FirstBlock + 1 then
    Result := FragmentDuplicate
  else
    Result := FragmentOverlaps;
end;

end.
