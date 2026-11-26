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
  The symbol decoder of the AV1 specification (section 8.2): the
  multi-symbol arithmetic decoder with adaptive CDFs.

  The specification reads the bits of its 15-bit window one
  renormalization at a time; this keeps a 64-bit window of bits instead,
  filled a byte at a time. The window holds the inverted bits, so that
  running out of data shifts in ones, which stand for the zero padding
  bits the specification uses past the end of the tile's data: the
  results are the same as the specification's.
}
unit Av1.SymbolDecoder;

{$mode objfpc}

interface

uses
  Av1.Common;

const
  WindowBits = 64;

type
  TSymbolDecoder = record
    Data, DataEnd: PByte;
    Difference: QWord;          { the inverted bits not yet consumed, from the top }
    Range: LongWord;            { SymbolRange }
    Count: Integer;             { bits in Difference beyond the 16 compared }
    DisableCdfUpdate: Boolean;
  end;

{ init_symbol( sz ): the decoder over Size bytes at Data. }
procedure InitializeSymbolDecoder(out Decoder: TSymbolDecoder; Data: PByte; Size: Integer;
  DisableCdfUpdate: Boolean);
{ read_symbol( cdf ) for a CDF of N symbols (N + 1 words). }
function ReadSymbol(var Decoder: TSymbolDecoder; Cdf: PWord; N: Integer): Integer;
{ read_symbol( cdf ) for a CDF that is built for one symbol and thrown
  away (split_or_horz, split_or_vert): no adaptation. }
function ReadSymbolWithoutAdaptation(var Decoder: TSymbolDecoder; Cdf: PWord; N: Integer): Integer;
{ read_bool( ): a bit of even probability. }
function ReadBoolean(var Decoder: TSymbolDecoder): Integer;
{ read_literal( n ): n bits of even probability, most significant first. }
function ReadLiteral(var Decoder: TSymbolDecoder; Bits: Integer): Integer;
{ NS( n ) of the specification: a value below Count with read_literal bits. }
function ReadUniform(var Decoder: TSymbolDecoder; Count: Integer): Integer;

implementation

const
  EC_PROB_SHIFT = 6;
  EC_MIN_PROB = 4;
  { Count when every byte has been read: enough that refills stop. }
  LotsOfBits = $4000;

procedure Refill(var Decoder: TSymbolDecoder);
var
  Shift: Integer;
begin
  Shift := WindowBits - 9 - (Decoder.Count + 15);
  while (Shift >= 0) and (Decoder.Data < Decoder.DataEnd) do
  begin
    Decoder.Difference := Decoder.Difference xor (QWord(Decoder.Data^) shl Shift);
    Inc(Decoder.Data);
    Inc(Decoder.Count, 8);
    Dec(Shift, 8);
  end;
  if Decoder.Data >= Decoder.DataEnd then
    Decoder.Count := LotsOfBits;
end;

procedure InitializeSymbolDecoder(out Decoder: TSymbolDecoder; Data: PByte; Size: Integer;
  DisableCdfUpdate: Boolean);
begin
  Decoder.Data := Data;
  Decoder.DataEnd := Data + Size;
  Decoder.Difference := (QWord(1) shl (WindowBits - 1)) - 1;
  Decoder.Range := $8000;
  Decoder.Count := -15;
  Decoder.DisableCdfUpdate := DisableCdfUpdate;
  Refill(Decoder);
end;

procedure Normalize(var Decoder: TSymbolDecoder; Difference: QWord; Range: LongWord); inline;
var
  Bits: Integer;
begin
  Bits := 15 - BsrDWord(Range);
  Dec(Decoder.Count, Bits);
  Decoder.Difference := ((Difference + 1) shl Bits) - 1;
  Decoder.Range := Range shl Bits;
  if Decoder.Count < 0 then
    Refill(Decoder);
end;

function ReadSymbolWithoutAdaptation(var Decoder: TSymbolDecoder; Cdf: PWord; N: Integer): Integer;
var
  Compared, Current, Previous, Range: LongWord;
  Symbol: Integer;
begin
  Compared := LongWord(Decoder.Difference shr (WindowBits - 16));
  Range := Decoder.Range;
  Current := Range;
  Symbol := -1;
  repeat
    Inc(Symbol);
    Previous := Current;
    Current := (((Range shr 8) * (LongWord(32768 - Cdf[Symbol]) shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT))
      + LongWord(EC_MIN_PROB * (N - Symbol - 1));
  until Compared >= Current;
  Normalize(Decoder, Decoder.Difference - (QWord(Current) shl (WindowBits - 16)), Previous - Current);
  Result := Symbol;
end;

function ReadSymbol(var Decoder: TSymbolDecoder; Cdf: PWord; N: Integer): Integer;
var
  Compared, Current, Previous, Range: LongWord;
  Symbol, Rate, Index: Integer;
  Count: Word;
begin
  Compared := LongWord(Decoder.Difference shr (WindowBits - 16));
  Range := Decoder.Range;
  Current := Range;
  Symbol := -1;
  repeat
    Inc(Symbol);
    Previous := Current;
    Current := (((Range shr 8) * (LongWord(32768 - Cdf[Symbol]) shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT))
      + LongWord(EC_MIN_PROB * (N - Symbol - 1));
  until Compared >= Current;
  Normalize(Decoder, Decoder.Difference - (QWord(Current) shl (WindowBits - 16)), Previous - Current);
  if not Decoder.DisableCdfUpdate then
  begin
    Count := Cdf[N];
    Rate := 3 + Ord(Count > 15) + Ord(Count > 31);
    if N >= 4 then
      Inc(Rate, 2)
    else if N >= 2 then
      Inc(Rate, 1);
    for Index := 0 to N - 2 do
    begin
      if Index >= Symbol then
        Cdf[Index] := Cdf[Index] + ((32768 - Cdf[Index]) shr Rate)
      else
        Cdf[Index] := Cdf[Index] - (Cdf[Index] shr Rate);
    end;
    if Count < 32 then
      Cdf[N] := Count + 1;
  end;
  Result := Symbol;
end;

function ReadBoolean(var Decoder: TSymbolDecoder): Integer;
var
  Compared, Split, Range: LongWord;
begin
  Compared := LongWord(Decoder.Difference shr (WindowBits - 16));
  Range := Decoder.Range;
  { cdf[ 0 ] = 1 << 14, N = 2 }
  Split := (((Range shr 8) * (LongWord(16384) shr EC_PROB_SHIFT)) shr (7 - EC_PROB_SHIFT)) + EC_MIN_PROB;
  if Compared >= Split then
  begin
    Normalize(Decoder, Decoder.Difference - (QWord(Split) shl (WindowBits - 16)), Range - Split);
    Result := 0;
  end
  else
  begin
    Normalize(Decoder, Decoder.Difference, Split);
    Result := 1;
  end;
end;

function ReadLiteral(var Decoder: TSymbolDecoder; Bits: Integer): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to Bits do
    Result := 2 * Result + ReadBoolean(Decoder);
end;

function ReadUniform(var Decoder: TSymbolDecoder; Count: Integer): Integer;
var
  Width, Threshold, Value: Integer;
begin
  Width := FloorLog2(Count) + 1;
  Threshold := (1 shl Width) - Count;
  Value := ReadLiteral(Decoder, Width - 1);
  if Value < Threshold then
    Exit(Value);
  Result := (Value shl 1) - Threshold + ReadBoolean(Decoder);
end;

end.
