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
  The LZMA decoder (as the LZMA SDK's specification describes it), for
  the chunks of LZMA2 (Compression.Lzma2Decoder).

  The output is one flat buffer holding everything decoded so far, so it
  is the dictionary as well: a match copies from earlier in the buffer.
  Nothing wraps, and the dictionary size of the stream does not matter.
  DictionaryStart is where the last dictionary reset was: matches may
  not reach before it, and positions (for the literal and position
  states) count from it.

  Each step is a literal, a match with a new distance, or a repeat of
  one of the last four distances ("reps"). A twelve-valued state of the
  last few kinds of step picks the probabilities. Every distance is
  checked against the output so far and every length against the end of
  the chunk; a stream may not end with the end marker inside LZMA2.

  Freestanding (the kernel compiles it): the caller provides the
  decoder record, some 30 KiB.
}
unit Compression.LzmaDecoder;

{$mode objfpc}
{$pointermath on}
{$inline on}

interface

uses
  Compression.DecodeResults,
  Compression.RangeDecoder;

const
  StateCount = 12;
  PositionStatesMaximum = 16;
  DistanceStates = 4;
  PositionSlotBits = 6;
  EndPositionModelIndex = 14;
  FullDistances = 128;
  AlignBits = 4;
  LiteralCoderSize = $300;
  { LZMA2 allows at most four literal context and position bits in all. }
  LiteralCodersMaximum = 16;
  LiteralContextAndPositionBitsMaximum = 4;
  PositionBitsMaximum = 4;

type
  TLengthProbabilities = record
    Choice: TProbability;
    Choice2: TProbability;
    Low: array[0..PositionStatesMaximum - 1, 0..7] of TProbability;
    Middle: array[0..PositionStatesMaximum - 1, 0..7] of TProbability;
    High: array[0..255] of TProbability;
  end;

  TLzmaProbabilities = record
    IsMatch: array[0..StateCount - 1, 0..PositionStatesMaximum - 1] of TProbability;
    IsRep: array[0..StateCount - 1] of TProbability;
    IsRepG0: array[0..StateCount - 1] of TProbability;
    IsRepG1: array[0..StateCount - 1] of TProbability;
    IsRepG2: array[0..StateCount - 1] of TProbability;
    IsRep0Long: array[0..StateCount - 1, 0..PositionStatesMaximum - 1] of TProbability;
    PositionSlot: array[0..DistanceStates - 1, 0..(1 shl PositionSlotBits) - 1] of TProbability;
    SpecialPositions: array[0..FullDistances - EndPositionModelIndex] of TProbability;
    Align: array[0..(1 shl AlignBits) - 1] of TProbability;
    MatchLengths: TLengthProbabilities;
    RepLengths: TLengthProbabilities;
    Literals: array[0..LiteralCoderSize * LiteralCodersMaximum - 1] of TProbability;
  end;

  TLzmaDecoder = record
    Probabilities: TLzmaProbabilities;
    State: LongWord;
    Rep0: LongWord;
    Rep1: LongWord;
    Rep2: LongWord;
    Rep3: LongWord;
    LiteralContextBits: LongWord;
    LiteralPositionMask: LongWord;
    PositionMask: LongWord;
  end;

{ Takes the properties byte of LZMA2: (PositionBits * 5 +
  LiteralPositionBits) * 9 + LiteralContextBits. False if it is out of
  LZMA2's range. }
function SetLzmaProperties(var Decoder: TLzmaDecoder; Properties: Byte): Boolean;

{ Every probability back to one half, the state and reps to zero. }
procedure ResetLzmaState(var Decoder: TLzmaDecoder);

{ Decodes into Output from Position until ChunkEnd, reading through
  Coder. Matches must stay within the chunk. }
function DecodeLzmaChunk(var Decoder: TLzmaDecoder; var Coder: TRangeDecoder; Output: PByte;
  DictionaryStart: SizeUInt; var Position: SizeUInt; ChunkEnd: SizeUInt): TDecodeResult;

implementation

const
  { States below this one follow a literal. }
  LiteralStateCount = 7;
  MatchLengthMinimum = 2;
  EndMarkerDistance = $FFFFFFFF;

function SetLzmaProperties(var Decoder: TLzmaDecoder; Properties: Byte): Boolean;
var
  LiteralContextBits: LongWord;
  LiteralPositionBits: LongWord;
  PositionBits: LongWord;
begin
  Result := False;
  if Properties >= 9 * 5 * 5 then
    Exit;
  LiteralContextBits := Properties mod 9;
  LiteralPositionBits := (Properties div 9) mod 5;
  PositionBits := Properties div 45;
  if (LiteralContextBits + LiteralPositionBits > LiteralContextAndPositionBitsMaximum) or
     (PositionBits > PositionBitsMaximum) then
    Exit;
  Decoder.LiteralContextBits := LiteralContextBits;
  Decoder.LiteralPositionMask := (LongWord(1) shl LiteralPositionBits) - 1;
  Decoder.PositionMask := (LongWord(1) shl PositionBits) - 1;
  Result := True;
end;

procedure ResetLzmaState(var Decoder: TLzmaDecoder);
var
  Probabilities: PProbability;
  Index: SizeUInt;
  Count: SizeUInt;
begin
  Probabilities := PProbability(@Decoder.Probabilities);
  Count := SizeOf(Decoder.Probabilities) div SizeOf(TProbability);
  Index := 0;
  while Index < Count do
  begin
    Probabilities[Index] := ProbabilityInitial;
    Inc(Index);
  end;
  Decoder.State := 0;
  Decoder.Rep0 := 0;
  Decoder.Rep1 := 0;
  Decoder.Rep2 := 0;
  Decoder.Rep3 := 0;
end;

function StateAfterLiteral(State: LongWord): LongWord; inline;
begin
  if State < 4 then
    Result := 0
  else if State < 10 then
    Result := State - 3
  else
    Result := State - 6;
end;

function DecodeLength(var Coder: TRangeDecoder; var Lengths: TLengthProbabilities;
  PositionState: LongWord): LongWord;
begin
  if DecodeBit(Coder, Lengths.Choice) = 0 then
    Result := DecodeBitTree(Coder, @Lengths.Low[PositionState, 0], 3)
  else if DecodeBit(Coder, Lengths.Choice2) = 0 then
    Result := 8 + DecodeBitTree(Coder, @Lengths.Middle[PositionState, 0], 3)
  else
    Result := 16 + DecodeBitTree(Coder, @Lengths.High[0], 8);
end;

{ The distance of a new match, minus one (EndMarkerDistance for the end
  marker); LengthSymbol is its length minus two. }
function DecodeDistance(var Probabilities: TLzmaProbabilities; var Coder: TRangeDecoder;
  LengthSymbol: LongWord): LongWord;
var
  DistanceState: LongWord;
  Slot: LongWord;
  DirectBits: LongWord;
begin
  DistanceState := LengthSymbol;
  if DistanceState > DistanceStates - 1 then
    DistanceState := DistanceStates - 1;
  Slot := DecodeBitTree(Coder, @Probabilities.PositionSlot[DistanceState, 0], PositionSlotBits);
  if Slot < 4 then
    Exit(Slot);
  DirectBits := (Slot shr 1) - 1;
  Result := (2 or (Slot and 1)) shl DirectBits;
  if Slot < EndPositionModelIndex then
    Result := Result + DecodeReverseBitTree(Coder, @Probabilities.SpecialPositions[Result - Slot], DirectBits)
  else
  begin
    Result := Result + (DecodeDirectBits(Coder, DirectBits - AlignBits) shl AlignBits);
    Result := Result + DecodeReverseBitTree(Coder, @Probabilities.Align[0], AlignBits);
  end;
end;

function DecodeLiteral(var Decoder: TLzmaDecoder; var Coder: TRangeDecoder; Output: PByte;
  Position: SizeUInt; Relative: SizeUInt): Byte;
var
  Previous: LongWord;
  CoderIndex: LongWord;
  Literal: PProbability;
  Symbol: LongWord;
  MatchByte: LongWord;
  MatchBit: LongWord;
  Bit: LongWord;
begin
  Previous := 0;
  if Relative > 0 then
    Previous := Output[Position - 1];
  CoderIndex := ((LongWord(Relative) and Decoder.LiteralPositionMask) shl Decoder.LiteralContextBits) +
    (Previous shr (8 - Decoder.LiteralContextBits));
  Literal := @Decoder.Probabilities.Literals[LiteralCoderSize * CoderIndex];
  Symbol := 1;
  { After a match the byte at the last distance guides the first bits,
    until one differs from it. }
  if Decoder.State >= LiteralStateCount then
  begin
    MatchByte := Output[Position - Decoder.Rep0 - 1];
    repeat
      MatchBit := (MatchByte shr 7) and 1;
      MatchByte := (MatchByte shl 1) and $FF;
      Bit := DecodeBit(Coder, Literal[((1 + MatchBit) shl 8) + Symbol]);
      Symbol := (Symbol shl 1) or Bit;
      if MatchBit <> Bit then
        Break;
    until Symbol >= $100;
  end;
  while Symbol < $100 do
    Symbol := (Symbol shl 1) or DecodeBit(Coder, Literal[Symbol]);
  Result := Byte(Symbol - $100);
end;

{ A repeated distance (the IsRep bit was 1): the step is a single byte
  (ShortRep True) or a match of the length that follows. }
function DecodeRepeat(var Decoder: TLzmaDecoder; var Coder: TRangeDecoder; PositionState: LongWord;
  out ShortRep: Boolean): LongWord;
var
  Probabilities: ^TLzmaProbabilities;
  State: LongWord;
  Distance: LongWord;
begin
  Probabilities := @Decoder.Probabilities;
  State := Decoder.State;
  ShortRep := False;
  Result := 0;
  if DecodeBit(Coder, Probabilities^.IsRepG0[State]) = 0 then
  begin
    if DecodeBit(Coder, Probabilities^.IsRep0Long[State, PositionState]) = 0 then
    begin
      ShortRep := True;
      if State < LiteralStateCount then
        Decoder.State := 9
      else
        Decoder.State := 11;
      Exit;
    end;
  end
  else
  begin
    if DecodeBit(Coder, Probabilities^.IsRepG1[State]) = 0 then
      Distance := Decoder.Rep1
    else
    begin
      if DecodeBit(Coder, Probabilities^.IsRepG2[State]) = 0 then
        Distance := Decoder.Rep2
      else
      begin
        Distance := Decoder.Rep3;
        Decoder.Rep3 := Decoder.Rep2;
      end;
      Decoder.Rep2 := Decoder.Rep1;
    end;
    Decoder.Rep1 := Decoder.Rep0;
    Decoder.Rep0 := Distance;
  end;
  Result := DecodeLength(Coder, Probabilities^.RepLengths, PositionState);
  if State < LiteralStateCount then
    Decoder.State := 8
  else
    Decoder.State := 11;
end;

procedure CopyMatch(Output: PByte; Position: SizeUInt; Distance: SizeUInt; Length: SizeUInt); inline;
var
  Source: PByte;
  Destination: PByte;
  Finish: PByte;
begin
  Destination := Output + Position;
  Source := Destination - Distance;
  Finish := Destination + Length;
  { Byte by byte: the source may overlap what is being written. }
  while Destination < Finish do
  begin
    Destination^ := Source^;
    Inc(Destination);
    Inc(Source);
  end;
end;

function DecodeLzmaChunk(var Decoder: TLzmaDecoder; var Coder: TRangeDecoder; Output: PByte;
  DictionaryStart: SizeUInt; var Position: SizeUInt; ChunkEnd: SizeUInt): TDecodeResult;
var
  Relative: SizeUInt;
  PositionState: LongWord;
  LengthSymbol: LongWord;
  Distance: LongWord;
  Length: SizeUInt;
  ShortRep: Boolean;
begin
  while Position < ChunkEnd do
  begin
    Relative := Position - DictionaryStart;
    PositionState := LongWord(Relative) and Decoder.PositionMask;

    if DecodeBit(Coder, Decoder.Probabilities.IsMatch[Decoder.State, PositionState]) = 0 then
    begin
      if (Decoder.State >= LiteralStateCount) and (Decoder.Rep0 >= Relative) then
        Exit(DecodeCorrupt);
      Output[Position] := DecodeLiteral(Decoder, Coder, Output, Position, Relative);
      Inc(Position);
      Decoder.State := StateAfterLiteral(Decoder.State);
      Continue;
    end;

    if DecodeBit(Coder, Decoder.Probabilities.IsRep[Decoder.State]) = 0 then
    begin
      LengthSymbol := DecodeLength(Coder, Decoder.Probabilities.MatchLengths, PositionState);
      if Decoder.State < LiteralStateCount then
        Decoder.State := 7
      else
        Decoder.State := 10;
      Distance := DecodeDistance(Decoder.Probabilities, Coder, LengthSymbol);
      if Distance = EndMarkerDistance then
        Exit(DecodeCorrupt);
      Decoder.Rep3 := Decoder.Rep2;
      Decoder.Rep2 := Decoder.Rep1;
      Decoder.Rep1 := Decoder.Rep0;
      Decoder.Rep0 := Distance;
    end
    else
    begin
      if Relative = 0 then
        Exit(DecodeCorrupt);
      LengthSymbol := DecodeRepeat(Decoder, Coder, PositionState, ShortRep);
      if ShortRep then
      begin
        if Decoder.Rep0 >= Relative then
          Exit(DecodeCorrupt);
        Output[Position] := Output[Position - Decoder.Rep0 - 1];
        Inc(Position);
        Continue;
      end;
    end;

    Length := LengthSymbol + MatchLengthMinimum;
    if (Decoder.Rep0 >= Relative) or (Length > ChunkEnd - Position) then
      Exit(DecodeCorrupt);
    CopyMatch(Output, Position, SizeUInt(Decoder.Rep0) + 1, Length);
    Inc(Position, Length);
  end;
  Result := DecodeSucceeded;
end;

end.
