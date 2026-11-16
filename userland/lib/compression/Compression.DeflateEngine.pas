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
  The compressor of raw deflate data: input goes into the match finder,
  is turned into literals and matches, and comes out as blocks in a bit
  writer, the caller taking the bytes from there.

  How positions become symbols depends on the level (zlib's levels, with
  zlib's search limits):

    0     stored blocks, no search
    1-3   greedy: the longest match at each position is taken
    4-9   lazy: a match is taken only if the next position does not
          start a longer one; otherwise a literal goes out and the
          longer match is weighed against the one after it

  A block is sent when it has as many symbols as it holds, and at the
  end; WriteBlock picks how.
}
unit Compression.DeflateEngine;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.DeflateFormat,
  Compression.MatchFinder,
  Compression.DeflateBlocks,
  Compression.BitWriter;

type
  TDeflateEngine = class
  private
    FLevel: Integer;
    FLimits: TSearchLimits;
    FFinder: TMatchFinder;
    FBlock: TDeflateBlock;
    FWriter: TBitWriter;
    FMatchLength: Integer;
    FMatchStart: LongInt;
    FPreviousLength: Integer;
    FPreviousMatch: LongInt;
    FMatchAvailable: Boolean;
    procedure EmitBlock(IsLast: Boolean);
    procedure EmitBlockEndingAt(BlockEnd: LongInt; IsLast: Boolean);
    function MostlyLiterals: Boolean;
    procedure ProcessStored;
    procedure ProcessGreedy(Flushing: Boolean);
    procedure ProcessLazy(Flushing: Boolean);
  public
    constructor Create(Level: Integer; Writer: TBitWriter);
    destructor Destroy; override;
    procedure Reset;
    { Takes as much input as fits now; returns how much. }
    function Consume(Data: PByte; Count: SizeInt): SizeInt;
    { Codes what has come in, keeping enough back to find whole matches
      unless Flushing. Full blocks go to the writer. }
    procedure Process(Flushing: Boolean);
    { Codes the rest and sends the last block (not padded to a byte). }
    procedure Finish;
    { Before any input: the data seen as coming just before it (a preset
      dictionary), which matches may refer back into. }
    procedure SetDictionary(Data: PByte; Count: SizeInt);
    { Codes everything taken so far and ends it with an empty stored
      block, so that the output so far is whole bytes that decompress to
      all of the input so far (a sync flush). With Full, nothing before
      is referred to after it either, so decompression may start again
      from here (a full flush). }
    procedure Flush(Full: Boolean);
    property Level: Integer read FLevel;
  end;

implementation

const
  LevelLimits: array[1..9] of TSearchLimits = (
    (GoodLength: 4; MaximumLazy: 4; NiceLength: 8; ChainLength: 4),
    (GoodLength: 4; MaximumLazy: 5; NiceLength: 16; ChainLength: 8),
    (GoodLength: 4; MaximumLazy: 6; NiceLength: 32; ChainLength: 32),
    (GoodLength: 4; MaximumLazy: 4; NiceLength: 16; ChainLength: 16),
    (GoodLength: 8; MaximumLazy: 16; NiceLength: 32; ChainLength: 32),
    (GoodLength: 8; MaximumLazy: 16; NiceLength: 128; ChainLength: 128),
    (GoodLength: 8; MaximumLazy: 32; NiceLength: 128; ChainLength: 256),
    (GoodLength: 32; MaximumLazy: 128; NiceLength: 258; ChainLength: 1024),
    (GoodLength: 32; MaximumLazy: 258; NiceLength: 258; ChainLength: 4096));
  LastGreedyLevel = 3;

constructor TDeflateEngine.Create(Level: Integer; Writer: TBitWriter);
begin
  inherited Create;
  if Level < 0 then
    Level := 0;
  if Level > 9 then
    Level := 9;
  FLevel := Level;
  if Level > 0 then
    FLimits := LevelLimits[Level];
  FWriter := Writer;
  FFinder := TMatchFinder.Create;
  FBlock := TDeflateBlock.Create;
  Reset;
end;

destructor TDeflateEngine.Destroy;
begin
  FBlock.Free;
  FFinder.Free;
  inherited Destroy;
end;

procedure TDeflateEngine.Reset;
begin
  FFinder.Reset;
  FBlock.Clear;
  FMatchLength := MinimumMatch - 1;
  FMatchStart := 0;
  FPreviousLength := MinimumMatch - 1;
  FPreviousMatch := 0;
  FMatchAvailable := False;
end;

{ True if the block so far is (nearly) all literals: input that does not
  compress, which is best stored. }
function TDeflateEngine.MostlyLiterals: Boolean;
begin
  Result := Int64(FBlock.Count) * 10 > Int64(FFinder.Position - FFinder.BlockStart) * 9;
end;

function TDeflateEngine.Consume(Data: PByte; Count: SizeInt): SizeInt;
var
  BlockEnd: LongInt;
begin
  if FFinder.NeedsSlide then
  begin
    { Sliding would lose the start of the block's input, and with it the
      choice of storing the block; a block that will probably be stored
      goes out first. A literal still being weighed (lazy levels) is not
      in it yet. }
    if (FFinder.BlockStart >= 0) and (FFinder.BlockStart < WindowSize) and (FBlock.Count > 0) and MostlyLiterals then
    begin
      BlockEnd := FFinder.Position;
      if FMatchAvailable then
        Dec(BlockEnd);
      EmitBlockEndingAt(BlockEnd, False);
    end;
    FFinder.Slide;
    Dec(FMatchStart, WindowSize);
    Dec(FPreviousMatch, WindowSize);
  end;
  Result := FFinder.Fill(Data, Count);
end;

procedure TDeflateEngine.EmitBlock(IsLast: Boolean);
begin
  EmitBlockEndingAt(FFinder.Position, IsLast);
end;

{ Sends the block, whose input runs from BlockStart to BlockEnd. }
procedure TDeflateEngine.EmitBlockEndingAt(BlockEnd: LongInt; IsLast: Boolean);
var
  RawData: PByte;
begin
  RawData := nil;
  if FFinder.BlockStart >= 0 then
    RawData := FFinder.AddressOf(FFinder.BlockStart);
  WriteBlock(FWriter, FBlock, RawData, BlockEnd - FFinder.BlockStart, IsLast);
  FBlock.Clear;
  FFinder.BlockStart := BlockEnd;
end;

procedure TDeflateEngine.Process(Flushing: Boolean);
begin
  if FLevel = 0 then
    ProcessStored
  else if FLevel <= LastGreedyLevel then
    ProcessGreedy(Flushing)
  else
    ProcessLazy(Flushing);
end;

{ Stored: once the buffer is full, everything in it goes out. }
procedure TDeflateEngine.ProcessStored;
begin
  if (FFinder.Lookahead > 0) and (FFinder.Position + FFinder.Lookahead = SearchBufferSize) then
  begin
    WriteStoredBlocks(FWriter, FFinder.AddressOf(FFinder.Position), FFinder.Lookahead, False);
    Inc(FFinder.Position, FFinder.Lookahead);
    FFinder.Lookahead := 0;
    FFinder.BlockStart := FFinder.Position;
  end;
end;

procedure TDeflateEngine.ProcessGreedy(Flushing: Boolean);
var
  Finder: TMatchFinder;
  HashHead: LongInt;
begin
  Finder := FFinder;
  while True do
  begin
    if (Finder.Lookahead < MinimumLookahead) and not Flushing then
      Exit;
    if Finder.Lookahead = 0 then
      Exit;
    HashHead := NoPosition;
    if Finder.Lookahead >= MinimumMatch then
      HashHead := Finder.Insert(Finder.Position);
    FMatchLength := 0;
    if (HashHead <> NoPosition) and (Finder.Position - HashHead <= MaximumDistance) then
      FMatchLength := Finder.LongestMatch(HashHead, MinimumMatch - 1, FLimits, FMatchStart);
    if FMatchLength >= MinimumMatch then
    begin
      FBlock.AddMatch(FMatchLength, Finder.Position - FMatchStart);
      Dec(Finder.Lookahead, FMatchLength);
      if (FMatchLength <= FLimits.MaximumLazy) and (Finder.Lookahead >= MinimumMatch) then
      begin
        Dec(FMatchLength);
        repeat
          Inc(Finder.Position);
          Finder.Insert(Finder.Position);
          Dec(FMatchLength);
        until FMatchLength = 0;
        Inc(Finder.Position);
      end
      else
        Inc(Finder.Position, FMatchLength);
    end
    else
    begin
      FBlock.AddLiteral(Finder.ByteAt(Finder.Position));
      Dec(Finder.Lookahead);
      Inc(Finder.Position);
    end;
    if FBlock.IsFull then
      EmitBlock(False);
  end;
end;

procedure TDeflateEngine.ProcessLazy(Flushing: Boolean);
var
  Finder: TMatchFinder;
  HashHead: LongInt;
  LastInsert: LongInt;
begin
  Finder := FFinder;
  while True do
  begin
    if (Finder.Lookahead < MinimumLookahead) and not Flushing then
      Exit;
    if Finder.Lookahead = 0 then
      Exit;
    HashHead := NoPosition;
    if Finder.Lookahead >= MinimumMatch then
      HashHead := Finder.Insert(Finder.Position);

    FPreviousLength := FMatchLength;
    FPreviousMatch := FMatchStart;
    FMatchLength := MinimumMatch - 1;
    if (HashHead <> NoPosition) and (FPreviousLength < FLimits.MaximumLazy) and
      (Finder.Position - HashHead <= MaximumDistance) then
    begin
      FMatchLength := Finder.LongestMatch(HashHead, FPreviousLength, FLimits, FMatchStart);
      if (FMatchLength = MinimumMatch) and (Finder.Position - FMatchStart > TooFarForShortMatch) then
        FMatchLength := MinimumMatch - 1;
    end;

    if (FPreviousLength >= MinimumMatch) and (FMatchLength <= FPreviousLength) then
    begin
      { The match at the previous position wins. }
      LastInsert := Finder.Position + Finder.Lookahead - MinimumMatch;
      FBlock.AddMatch(FPreviousLength, Finder.Position - 1 - FPreviousMatch);
      Dec(Finder.Lookahead, FPreviousLength - 1);
      Dec(FPreviousLength, 2);
      repeat
        Inc(Finder.Position);
        if Finder.Position <= LastInsert then
          Finder.Insert(Finder.Position);
        Dec(FPreviousLength);
      until FPreviousLength = 0;
      FMatchAvailable := False;
      FMatchLength := MinimumMatch - 1;
      Inc(Finder.Position);
      if FBlock.IsFull then
        EmitBlock(False);
    end
    else if FMatchAvailable then
    begin
      { The previous position goes out as a literal. }
      FBlock.AddLiteral(Finder.ByteAt(Finder.Position - 1));
      if FBlock.IsFull then
        EmitBlock(False);
      Inc(Finder.Position);
      Dec(Finder.Lookahead);
    end
    else
    begin
      FMatchAvailable := True;
      Inc(Finder.Position);
      Dec(Finder.Lookahead);
    end;
  end;
end;

procedure TDeflateEngine.SetDictionary(Data: PByte; Count: SizeInt);
begin
  if FLevel > 0 then
    FFinder.Preload(Data, Count);
end;

procedure TDeflateEngine.Flush(Full: Boolean);
begin
  if FLevel = 0 then
  begin
    if FFinder.Lookahead > 0 then
      WriteStoredBlocks(FWriter, FFinder.AddressOf(FFinder.Position), FFinder.Lookahead, False);
    Inc(FFinder.Position, FFinder.Lookahead);
    FFinder.Lookahead := 0;
    FFinder.BlockStart := FFinder.Position;
  end
  else
  begin
    Process(True);
    if FMatchAvailable then
    begin
      FBlock.AddLiteral(FFinder.ByteAt(FFinder.Position - 1));
      FMatchAvailable := False;
    end;
    FMatchLength := MinimumMatch - 1;
    if FBlock.Count > 0 then
      EmitBlock(False);
  end;
  WriteStoredBlocks(FWriter, nil, 0, False);
  if Full then
    FFinder.ForgetHistory;
end;

procedure TDeflateEngine.Finish;
begin
  if FLevel = 0 then
  begin
    WriteStoredBlocks(FWriter, FFinder.AddressOf(FFinder.Position), FFinder.Lookahead, True);
    Inc(FFinder.Position, FFinder.Lookahead);
    FFinder.Lookahead := 0;
    FFinder.BlockStart := FFinder.Position;
    Exit;
  end;
  Process(True);
  if FMatchAvailable then
  begin
    FBlock.AddLiteral(FFinder.ByteAt(FFinder.Position - 1));
    FMatchAvailable := False;
  end;
  EmitBlock(True);
end;

end.
