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
  The compressor's search for earlier copies of what comes next (LZ77
  with hash chains, as zlib does it).

  The input goes into a buffer of two windows (64 KiB). Position is the
  next byte to code, Lookahead how many are there from it on. Every
  position coded is put at the head of the chain for the hash of its
  first three bytes (Head), its predecessor kept in Prev; a search walks
  a chain back as far as a match may reach, at most ChainLength links,
  and keeps the longest match, comparing eight bytes at a time. When
  Position is far enough into the second window, the buffer slides down
  by a window and the chains with it.

  The buffer has a few bytes of slack after it, so comparisons and
  hashes may read a little past the data; what they find there is
  never used.
}
unit Compression.MatchFinder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.DeflateFormat;

const
  WindowMask = WindowSize - 1;
  SearchBufferSize = 2 * WindowSize;
  { Enough left to find a whole match and hash past it. }
  MinimumLookahead = MaximumMatch + MinimumMatch + 1;
  { How far back a match may start (kept below the window so that the
    look ahead fits). }
  MaximumDistance = WindowSize - MinimumLookahead;
  { Matches of three bytes further back than this cost more than the
    literals. }
  TooFarForShortMatch = 4096;
  NoPosition = -1;
  { Chains by a multiplicative hash of the next three bytes. }
  HashBits = 15;
  HashSize = 1 shl HashBits;
  HashMultiplier = LongWord($9E3779B1);

type
  TSearchLimits = record
    { A match this long already: search only a quarter of the chain. }
    GoodLength: Integer;
    { Look for a longer match after one this long only (lazy levels);
      insert the positions inside a match only up to this long (greedy
      levels). }
    MaximumLazy: Integer;
    { Stop searching at a match this long. }
    NiceLength: Integer;
    ChainLength: Integer;
  end;

  TMatchFinder = class
  private
    FWindow: array[0..SearchBufferSize + 15] of Byte;
    FHead: array of LongInt;
    FPrevious: array[0..WindowSize - 1] of LongInt;
    function CommonLength(Scan: PByte; Match: PByte; Limit: Integer): Integer; inline;
  public
    { The next position to code and how many bytes there are from it. }
    Position: LongInt;
    Lookahead: LongInt;
    { Where the current block's input starts (negative once slid away). }
    BlockStart: LongInt;

    constructor Create;
    procedure Reset;
    { Before any input: puts the end of Data (as much as a match can
      reach back) in the window as if it had just been coded, so that
      matches may refer into it (a preset dictionary). }
    procedure Preload(Data: PByte; Count: SizeInt);
    { Empties every chain: nothing coded so far is found again (after a
      full flush). }
    procedure ForgetHistory;
    { Adds input after the look ahead; returns how much fitted. }
    function Fill(Data: PByte; Count: SizeInt): SizeInt;
    { True if Fill would slide first; then Slide moves everything down
      by WindowSize, and positions the caller keeps must move too. }
    function NeedsSlide: Boolean;
    procedure Slide;
    { Puts At at the head of its chain; returns the position that was
      there (NoPosition if none). }
    function Insert(At: LongInt): LongInt; inline;
    { The longest match for Position along the chain from Candidate
      that is longer than PreviousLength; MatchStart is set only when
      one is found. Never more than Lookahead. }
    function LongestMatch(Candidate: LongInt; PreviousLength: Integer; const Limits: TSearchLimits;
      var MatchStart: LongInt): Integer;
    function ByteAt(At: LongInt): Byte; inline;
    function AddressOf(At: LongInt): PByte; inline;
  end;

implementation

constructor TMatchFinder.Create;
begin
  inherited Create;
  SetLength(FHead, HashSize);
  Reset;
end;

procedure TMatchFinder.Reset;
var
  Index: Integer;
begin
  for Index := 0 to HashSize - 1 do
    FHead[Index] := NoPosition;
  FillChar(FWindow, SizeOf(FWindow), 0);
  Position := 0;
  Lookahead := 0;
  BlockStart := 0;
end;

function TMatchFinder.ByteAt(At: LongInt): Byte;
begin
  Result := FWindow[At];
end;

function TMatchFinder.AddressOf(At: LongInt): PByte;
begin
  Result := @FWindow[At];
end;

function TMatchFinder.Insert(At: LongInt): LongInt;
var
  Hash: LongWord;
begin
  Hash := LongWord(QWord(PLongWord(@FWindow[At])^ and $FFFFFF) * HashMultiplier) shr (32 - HashBits);
  Result := FHead[Hash];
  FPrevious[At and WindowMask] := Result;
  FHead[Hash] := At;
end;

procedure TMatchFinder.Preload(Data: PByte; Count: SizeInt);
var
  At: LongInt;
begin
  if Count > MaximumDistance then
  begin
    Inc(Data, Count - MaximumDistance);
    Count := MaximumDistance;
  end;
  if (Count <= 0) or (Position <> 0) or (Lookahead <> 0) then
    Exit;
  Move(Data^, FWindow[0], Count);
  At := 0;
  while At + MinimumMatch <= Count do
  begin
    Insert(At);
    Inc(At);
  end;
  Position := Count;
  BlockStart := Count;
end;

procedure TMatchFinder.ForgetHistory;
var
  Index: Integer;
begin
  for Index := 0 to HashSize - 1 do
    FHead[Index] := NoPosition;
end;

function TMatchFinder.NeedsSlide: Boolean;
begin
  Result := Position >= WindowSize + MaximumDistance;
end;

procedure TMatchFinder.Slide;
var
  Index: Integer;
begin
  Move(FWindow[WindowSize], FWindow[0], Position + Lookahead - WindowSize);
  Dec(Position, WindowSize);
  Dec(BlockStart, WindowSize);
  for Index := 0 to HashSize - 1 do
    if FHead[Index] >= WindowSize then
      Dec(FHead[Index], WindowSize)
    else
      FHead[Index] := NoPosition;
  for Index := 0 to WindowSize - 1 do
    if FPrevious[Index] >= WindowSize then
      Dec(FPrevious[Index], WindowSize)
    else
      FPrevious[Index] := NoPosition;
end;

function TMatchFinder.Fill(Data: PByte; Count: SizeInt): SizeInt;
var
  FillEnd: LongInt;
begin
  FillEnd := Position + Lookahead;
  Result := SearchBufferSize - FillEnd;
  if Result > Count then
    Result := Count;
  if Result <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  Move(Data^, FWindow[FillEnd], Result);
  Inc(Lookahead, Result);
end;

function TMatchFinder.CommonLength(Scan: PByte; Match: PByte; Limit: Integer): Integer;
var
  Difference: QWord;
begin
  Result := 0;
  while Result < Limit do
  begin
    Difference := PQWord(Scan + Result)^ xor PQWord(Match + Result)^;
    if Difference <> 0 then
    begin
      Inc(Result, BsfQWord(Difference) shr 3);
      Break;
    end;
    Inc(Result, 8);
  end;
  if Result > Limit then
    Result := Limit;
end;

function TMatchFinder.LongestMatch(Candidate: LongInt; PreviousLength: Integer; const Limits: TSearchLimits;
  var MatchStart: LongInt): Integer;
var
  ChainLeft: Integer;
  BestLength: Integer;
  NiceLength: Integer;
  LengthLimit: Integer;
  Lowest: LongInt;
  Scan: PByte;
  Match: PByte;
  Length: Integer;
  Next: LongInt;
begin
  ChainLeft := Limits.ChainLength;
  BestLength := PreviousLength;
  if BestLength >= Limits.GoodLength then
    ChainLeft := ChainLeft shr 2;
  NiceLength := Limits.NiceLength;
  if NiceLength > Lookahead then
    NiceLength := Lookahead;
  LengthLimit := MaximumMatch;
  if LengthLimit > Lookahead then
    LengthLimit := Lookahead;
  Lowest := Position - MaximumDistance;
  if Lowest < NoPosition then
    Lowest := NoPosition;
  Scan := @FWindow[Position];
  { Nothing longer can be had. }
  if BestLength >= LengthLimit then
    Candidate := Lowest;

  while (Candidate > Lowest) and (ChainLeft > 0) do
  begin
    Match := @FWindow[Candidate];
    if (Match[BestLength] = Scan[BestLength]) and (Match[0] = Scan[0]) and (Match[1] = Scan[1]) then
    begin
      Length := CommonLength(Scan, Match, LengthLimit);
      if Length > BestLength then
      begin
        BestLength := Length;
        MatchStart := Candidate;
        if Length >= NiceLength then
          Break;
      end;
    end;
    Next := FPrevious[Candidate and WindowMask];
    if Next >= Candidate then
      Break;
    Candidate := Next;
    Dec(ChainLeft);
  end;
  Result := BestLength;
  if Result > Lookahead then
    Result := Lookahead;
end;

end.
