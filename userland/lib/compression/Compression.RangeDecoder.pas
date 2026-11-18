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
  The LZMA range decoder: bits coded with adaptive probabilities, bit
  trees over them, and bits coded with a fixed probability of one half
  ("direct" bits).

  A probability is the chance of a 0 in 11 bits, starting at one half;
  each decoded bit moves it 1/32 of the way towards what was seen.

  The decoder reads from a buffer of known size. It is normalized before
  each bit (and once more at the end of a chunk, NormalizeRangeDecoder),
  so after the last bit of a well-formed chunk every input byte has been
  read and Code is zero. Past the end of the input it reads zeros and
  sets Overrun: the caller's output limit bounds the work, and the
  caller then rejects the chunk.
}
unit Compression.RangeDecoder;

{$mode objfpc}
{$pointermath on}
{$inline on}

interface

const
  ProbabilityBits = 11;
  ProbabilityInitial = 1 shl (ProbabilityBits - 1);
  { In the interface for the inline routines' sake. }
  RangeTopValue = LongWord(1) shl 24;
  ProbabilityMoveBits = 5;
  ProbabilityTotal = 1 shl ProbabilityBits;

type
  TProbability = Word;
  PProbability = ^TProbability;

  TRangeDecoder = record
    Input: PByte;
    InputEnd: PByte;
    Range: LongWord;
    Code: LongWord;
    Overrun: Boolean;
  end;

{ Starts on InputSize bytes: False if they are fewer than the five the
  decoder starts with or the first is not zero. }
function StartRangeDecoder(var Decoder: TRangeDecoder; Input: PByte; InputSize: SizeUInt): Boolean;

procedure NormalizeRangeDecoder(var Decoder: TRangeDecoder); inline;

{ True when the chunk ended as the encoder ends one: input all read,
  Code zero, no overrun (call after NormalizeRangeDecoder). }
function RangeDecoderFinished(const Decoder: TRangeDecoder): Boolean;

function DecodeBit(var Decoder: TRangeDecoder; var Probability: TProbability): LongWord; inline;

{ BitCount bits, most significant first, through a tree of 1 shl BitCount
  probabilities (index 1 is the root). }
function DecodeBitTree(var Decoder: TRangeDecoder; Probabilities: PProbability; BitCount: LongWord): LongWord;

{ The same, least significant bit first. }
function DecodeReverseBitTree(var Decoder: TRangeDecoder; Probabilities: PProbability;
  BitCount: LongWord): LongWord;

function DecodeDirectBits(var Decoder: TRangeDecoder; BitCount: LongWord): LongWord;

implementation

const
  StartByteCount = 5;

function StartRangeDecoder(var Decoder: TRangeDecoder; Input: PByte; InputSize: SizeUInt): Boolean;
var
  Index: Integer;
begin
  Result := False;
  Decoder.Overrun := False;
  if (InputSize < StartByteCount) or (Input[0] <> 0) then
    Exit;
  Decoder.Range := $FFFFFFFF;
  Decoder.Code := 0;
  for Index := 1 to StartByteCount - 1 do
    Decoder.Code := (Decoder.Code shl 8) or Input[Index];
  Decoder.Input := Input + StartByteCount;
  Decoder.InputEnd := Input + InputSize;
  { The encoder never starts with a code at or above the range. }
  Result := Decoder.Code <> $FFFFFFFF;
end;

procedure NormalizeRangeDecoder(var Decoder: TRangeDecoder);
begin
  if Decoder.Range < RangeTopValue then
  begin
    Decoder.Range := Decoder.Range shl 8;
    if Decoder.Input < Decoder.InputEnd then
    begin
      Decoder.Code := (Decoder.Code shl 8) or Decoder.Input^;
      Inc(Decoder.Input);
    end
    else
    begin
      Decoder.Code := Decoder.Code shl 8;
      Decoder.Overrun := True;
    end;
  end;
end;

function RangeDecoderFinished(const Decoder: TRangeDecoder): Boolean;
begin
  Result := (not Decoder.Overrun) and (Decoder.Input = Decoder.InputEnd) and (Decoder.Code = 0);
end;

function DecodeBit(var Decoder: TRangeDecoder; var Probability: TProbability): LongWord;
var
  Bound: LongWord;
begin
  NormalizeRangeDecoder(Decoder);
  Bound := (Decoder.Range shr ProbabilityBits) * Probability;
  if Decoder.Code < Bound then
  begin
    Decoder.Range := Bound;
    Probability := Probability + (ProbabilityTotal - Probability) shr ProbabilityMoveBits;
    Result := 0;
  end
  else
  begin
    Decoder.Range := Decoder.Range - Bound;
    Decoder.Code := Decoder.Code - Bound;
    Probability := Probability - Probability shr ProbabilityMoveBits;
    Result := 1;
  end;
end;

function DecodeBitTree(var Decoder: TRangeDecoder; Probabilities: PProbability; BitCount: LongWord): LongWord;
var
  Symbol: LongWord;
  Index: LongWord;
begin
  Symbol := 1;
  for Index := 1 to BitCount do
    Symbol := (Symbol shl 1) or DecodeBit(Decoder, Probabilities[Symbol]);
  Result := Symbol - (LongWord(1) shl BitCount);
end;

function DecodeReverseBitTree(var Decoder: TRangeDecoder; Probabilities: PProbability;
  BitCount: LongWord): LongWord;
var
  Symbol: LongWord;
  Bit: LongWord;
  Index: LongWord;
begin
  Symbol := 1;
  Result := 0;
  for Index := 1 to BitCount do
  begin
    Bit := DecodeBit(Decoder, Probabilities[Symbol]);
    Symbol := (Symbol shl 1) or Bit;
    Result := Result or (Bit shl (Index - 1));
  end;
end;

function DecodeDirectBits(var Decoder: TRangeDecoder; BitCount: LongWord): LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 1 to BitCount do
  begin
    NormalizeRangeDecoder(Decoder);
    Decoder.Range := Decoder.Range shr 1;
    if Decoder.Code >= Decoder.Range then
    begin
      Decoder.Code := Decoder.Code - Decoder.Range;
      Result := (Result shl 1) or 1;
    end
    else
      Result := Result shl 1;
  end;
end;

end.
