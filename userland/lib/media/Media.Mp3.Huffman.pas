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
  Layer III Huffman decoding and requantisation (ISO 11172-3 2.4.3.4):
  the big values region (pairs, in up to three regions with their own
  tables, values of 15 extended by linear bits), then the count1 region
  (quadruples of 0 or +-1) up to the end of the granule's part 2/3. Each
  value becomes sign * |v|^(4/3) * the multiplier of its scale factor
  band (Media.Mp3.Scalefactors).

  |v|^(4/3) comes from a table below 129 and from a table entry and a
  second order correction above it. The bit reading keeps a 32-bit cache
  filled a byte at a time, so the main data buffer must have a few bytes
  of slack after its end. The scheme is minimp3's (public domain, by
  lieff).

  Range checks are off in this unit: the bit cache works by shifting bits
  out of a 32-bit word (the truncation is the point).
}
unit Media.Mp3.Huffman;

{$mode objfpc}
{$H+}
{$pointermath on}
{$R-}
{$Q-}

interface

uses
  Media.Mp3.BitStream,
  Media.Mp3.SideInfo;

{ Decodes one granule of one channel into Destination (576 values; what
  is not coded stays as it is, so it is cleared first by the caller), from
  Stream's position to Limit (in bits; the stream is left at Limit).
  Multipliers has one value per scale factor band. }
procedure DecodeHuffman(Destination: PSingle; var Stream: TMp3BitStream; const Granule: TMp3GranuleInfo;
  Multipliers: PSingle; Limit: Integer);
function PowerFourThirds(Value: Integer): Single;

implementation

uses
  Media.Mp3.HuffmanTables;

const
  { |v|^(4/3) for v = -15..0 (negated) and 0..128. }
  PowerTable: array[0..144] of Single = (
    0, -1, -2.519842, -4.326749, -6.349604, -8.549880, -10.902724, -13.390518,
    -16.000000, -18.720754, -21.544347, -24.463781, -27.473142, -30.567351, -33.741992, -36.993181,
    0, 1, 2.519842, 4.326749, 6.349604, 8.549880, 10.902724, 13.390518,
    16.000000, 18.720754, 21.544347, 24.463781, 27.473142, 30.567351, 33.741992, 36.993181,
    40.317474, 43.711787, 47.173345, 50.699631, 54.288352, 57.937408, 61.644865, 65.408941,
    69.227979, 73.100443, 77.024898, 81.000000, 85.024491, 89.097188, 93.216975, 97.382800,
    101.593667, 105.848633, 110.146801, 114.487321, 118.869381, 123.292209, 127.755065, 132.257246,
    136.798076, 141.376907, 145.993119, 150.646117, 155.335327, 160.060199, 164.820202, 169.614826,
    174.443577, 179.305980, 184.201575, 189.129918, 194.090580, 199.083145, 204.107210, 209.162385,
    214.248292, 219.364564, 224.510845, 229.686789, 234.892058, 240.126328, 245.389280, 250.680604,
    256.000000, 261.347174, 266.721841, 272.123723, 277.552547, 283.008049, 288.489971, 293.998060,
    299.532071, 305.091761, 310.676898, 316.287249, 321.922592, 327.582707, 333.267377, 338.976394,
    344.709550, 350.466646, 356.247482, 362.051866, 367.879608, 373.730522, 379.604427, 385.501143,
    391.420496, 397.362314, 403.326427, 409.312672, 415.320884, 421.350905, 427.402579, 433.475750,
    439.570269, 445.685987, 451.822757, 457.980436, 464.158883, 470.357960, 476.577530, 482.817459,
    489.077615, 495.357868, 501.658090, 507.978156, 514.317941, 520.677324, 527.056184, 533.454404,
    539.871867, 546.308458, 552.764065, 559.238575, 565.731879, 572.243870, 578.774440, 585.323483,
    591.890898, 598.476581, 605.080431, 611.702349, 618.342238, 625.000000, 631.675540, 638.368763,
    645.079578);

function PowerFourThirds(Value: Integer): Single;
var
  Fraction: Single;
  Sign, Multiplier: Integer;
begin
  if Value < 129 then
    Exit(PowerTable[16 + Value]);
  Multiplier := 256;
  if Value < 1024 then
  begin
    Multiplier := 16;
    Value := Value shl 3;
  end;
  Sign := (2 * Value) and 64;
  Fraction := ((Value and 63) - Sign) / ((Value and not 63) + Sign);
  Result := PowerTable[16 + ((Value + Sign) shr 6)] * (1 + Fraction * (Single(4) / 3 + Fraction * (Single(2) / 9)))
    * Multiplier;
end;

procedure DecodeHuffman(Destination: PSingle; var Stream: TMp3BitStream; const Granule: TMp3GranuleInfo;
  Multipliers: PSingle; Limit: Integer);
var
  Multiplier: Single;
  Region, BigValueCount, TableNumber, RegionBandCount, LinBits, PairCount, PairsToDecode: Integer;
  Pair, Width, Leaf, Value, Shift: Integer;
  Codebook: PSmallInt;
  Count1Table, BandWidth, Next: PByte;
  Cache: LongWord;

  procedure Flush(Count: Integer); inline;
  begin
    Cache := LongWord(Cache shl Count);
    Inc(Shift, Count);
  end;

  procedure Refill; inline;
  begin
    while Shift >= 0 do
    begin
      Cache := Cache or LongWord(LongWord(Next^) shl Shift);
      Inc(Next);
      Dec(Shift, 8);
    end;
  end;

  function Peek(Count: Integer): LongWord; inline;
  begin
    Result := Cache shr (32 - Count);
  end;

  function BitPosition: Integer; inline;
  begin
    Result := (Next - Stream.Data) * 8 - 24 + Shift;
  end;

  function SignedOne: Single; inline;
  begin
    if LongInt(Cache) < 0 then
      Result := -Multiplier
    else
      Result := Multiplier;
  end;

  { Takes the next band's pair count and multiplier when the current band
    is used up; False at the end of the bands. }
  function NextPairInBand: Boolean; inline;
  begin
    Dec(PairCount);
    if PairCount = 0 then
    begin
      PairCount := BandWidth^ div 2;
      Inc(BandWidth);
      if PairCount = 0 then
        Exit(False);
      Multiplier := Multipliers^;
      Inc(Multipliers);
    end;
    Result := True;
  end;

begin
  Multiplier := 0;
  Region := 0;
  BigValueCount := Granule.BigValues;
  BandWidth := Granule.BandWidths;
  Next := Stream.Data + (Stream.Position shr 3);
  Cache := LongWord((LongWord(Next[0]) shl 24) or (LongWord(Next[1]) shl 16) or (LongWord(Next[2]) shl 8)
    or Next[3]);
  Cache := LongWord(Cache shl (Stream.Position and 7));
  Shift := (Stream.Position and 7) - 8;
  Inc(Next, 4);

  while (BigValueCount > 0) and (Region < 3) do
  begin
    TableNumber := Granule.TableSelect[Region];
    RegionBandCount := Granule.RegionCount[Region];
    Inc(Region);
    Codebook := @HuffmanTables[HuffmanTableStart[TableNumber]];
    LinBits := LinearBits[TableNumber];
    repeat
      PairCount := BandWidth^ div 2;
      Inc(BandWidth);
      if PairCount = 0 then
      begin
        { The end of the bands: the big values count was impossible. }
        BigValueCount := 0;
        Break;
      end;
      PairsToDecode := PairCount;
      if BigValueCount < PairsToDecode then
        PairsToDecode := BigValueCount;
      Multiplier := Multipliers^;
      Inc(Multipliers);
      repeat
        Width := 5;
        Leaf := Codebook[Peek(Width)];
        while Leaf < 0 do
        begin
          Flush(Width);
          Width := Leaf and 7;
          Leaf := Codebook[LongInt(Peek(Width)) - SarLongint(Leaf, 3)];
        end;
        Flush(Leaf shr 8);
        for Pair := 0 to 1 do
        begin
          Value := Leaf and 15;
          if (Value = 15) and (LinBits > 0) then
          begin
            Inc(Value, Peek(LinBits));
            Flush(LinBits);
            Refill;
            Destination^ := SignedOne * PowerFourThirds(Value);
          end
          else
            Destination^ := PowerTable[16 + Value - 16 * LongInt(Cache shr 31)] * Multiplier;
          if Value <> 0 then
            Flush(1);
          Inc(Destination);
          Leaf := Leaf shr 4;
        end;
        Refill;
        Dec(PairsToDecode);
      until PairsToDecode <= 0;
      Dec(BigValueCount, PairCount);
      Dec(RegionBandCount);
    until (BigValueCount <= 0) or (RegionBandCount < 0);
  end;

  if Granule.Count1Table <> 0 then
    Count1Table := @Count1TableB[0]
  else
    Count1Table := @Count1TableA[0];
  PairCount := 1 - BigValueCount;
  while True do
  begin
    Leaf := Count1Table[Peek(4)];
    if (Leaf and 8) = 0 then
      Leaf := Count1Table[(Leaf shr 3) + (LongWord(Cache shl 4) shr (32 - (Leaf and 3)))];
    Flush(Leaf and 7);
    if BitPosition > Limit then
      Break;
    if not NextPairInBand then
      Break;
    if (Leaf and 128) <> 0 then
    begin
      Destination[0] := SignedOne;
      Flush(1);
    end;
    if (Leaf and 64) <> 0 then
    begin
      Destination[1] := SignedOne;
      Flush(1);
    end;
    if not NextPairInBand then
      Break;
    if (Leaf and 32) <> 0 then
    begin
      Destination[2] := SignedOne;
      Flush(1);
    end;
    if (Leaf and 16) <> 0 then
    begin
      Destination[3] := SignedOne;
      Flush(1);
    end;
    Refill;
    Inc(Destination, 4);
  end;
  Stream.Position := Limit;
end;

end.
