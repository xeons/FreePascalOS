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
  Layer III scale factors: reading them (MPEG-1's slen pairs with scfsi
  reuse, MPEG-2's partitions with the intensity stereo variant) and
  turning them, with the global gain, subblock gains and pre-emphasis,
  into one multiplier per scale factor band:

    2^((global_gain - 210) / 4) * 2^(-(scalefac_multiplier * scalefac))

  computed in quarter powers of two (LdexpQuarter). The multipliers keep
  the decoder's output in 16-bit scale (Media.Mp3.Synthesis divides it
  out). Mid/side stereo's 1/sqrt(2) is folded in here as -2 quarters.

  IntensityPositions keeps each band's raw scale factor (MPEG-2: 255 for
  the illegal intensity position, the largest value of its length); the
  next granule's scfsi copies from it.
}
unit Media.Mp3.Scalefactors;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Mp3.BitStream,
  Media.Mp3.SideInfo;

type
  TMp3BandMultipliers = array[0..39] of Single;
  TMp3IntensityPositions = array[0..38] of Byte;

{ y * 2^(-QuarterExponent / 4) for QuarterExponent >= 0. }
function LdexpQuarter(Value: Single; QuarterExponent: Integer): Single;
procedure DecodeScalefactors(Header: PByte; var IntensityPositions: TMp3IntensityPositions; var Stream: TMp3BitStream;
  const Granule: TMp3GranuleInfo; var Multipliers: TMp3BandMultipliers; Channel: Integer);

implementation

uses
  Media.Mp3.Header;

const
  { The dequantizer's output scale: one bit below 16-bit full scale. }
  DequantizerOutputBits = -1;
  MaximumScalefactor = 255 + DequantizerOutputBits * 4 - 210;
  MaximumScalefactorRounded = (MaximumScalefactor + 3) and not 3;

function LdexpQuarter(Value: Single; QuarterExponent: Integer): Single;
const
  FractionPowers: array[0..3] of Single = (9.31322575e-10, 7.83145814e-10, 6.58544508e-10, 5.53767716e-10);
var
  Step: Integer;
begin
  repeat
    Step := QuarterExponent;
    if Step > 120 then
      Step := 120;
    Value := Value * FractionPowers[Step and 3] * (LongWord(1 shl 30) shr (Step shr 2));
    Dec(QuarterExponent, Step);
  until QuarterExponent <= 0;
  Result := Value;
end;

procedure ReadScalefactors(Scalefactors, IntensityPositions: PByte; Sizes, Counts: PByte; var Stream: TMp3BitStream;
  Scfsi: Integer);
var
  Part, Index, Count, Bits, Value, Illegal: Integer;
begin
  Part := 0;
  while (Part < 4) and (Counts[Part] <> 0) do
  begin
    Count := Counts[Part];
    if (Scfsi and 8) <> 0 then
      Move(IntensityPositions^, Scalefactors^, Count)
    else
    begin
      Bits := Sizes[Part];
      if Bits = 0 then
      begin
        FillChar(Scalefactors^, Count, 0);
        FillChar(IntensityPositions^, Count, 0);
      end
      else
      begin
        if Scfsi < 0 then
          Illegal := (1 shl Bits) - 1
        else
          Illegal := -1;
        for Index := 0 to Count - 1 do
        begin
          Value := GetBits(Stream, Bits);
          if Value = Illegal then
            IntensityPositions[Index] := 255
          else
            IntensityPositions[Index] := Value;
          Scalefactors[Index] := Value;
        end;
      end;
    end;
    Inc(IntensityPositions, Count);
    Inc(Scalefactors, Count);
    Inc(Part);
    Scfsi := Scfsi * 2;
  end;
  Scalefactors[0] := 0;
  Scalefactors[1] := 0;
  Scalefactors[2] := 0;
end;

procedure DecodeScalefactors(Header: PByte; var IntensityPositions: TMp3IntensityPositions; var Stream: TMp3BitStream;
  const Granule: TMp3GranuleInfo; var Multipliers: TMp3BandMultipliers; Channel: Integer);
const
  Partitions: array[0..2, 0..27] of Byte = (
    (6, 5, 5, 5, 6, 5, 5, 5, 6, 5, 7, 3, 11, 10, 0, 0, 7, 7, 7, 0, 6, 6, 6, 3, 8, 8, 5, 0),
    (8, 9, 6, 12, 6, 9, 9, 9, 6, 9, 12, 6, 15, 18, 0, 0, 6, 15, 12, 0, 6, 12, 9, 6, 6, 18, 9, 0),
    (9, 9, 6, 12, 9, 9, 9, 9, 9, 9, 12, 6, 18, 18, 0, 0, 12, 12, 12, 0, 12, 9, 9, 6, 15, 12, 9, 0));
  CompressDecode: array[0..15] of Byte = (0, 1, 2, 3, 12, 5, 6, 7, 9, 10, 11, 13, 14, 15, 18, 19);
  Modulus: array[0..23] of Byte = (5, 5, 4, 4, 5, 5, 4, 1, 4, 3, 1, 1, 5, 6, 6, 1, 4, 4, 4, 1, 4, 3, 1, 1);
  Preamplification: array[0..9] of Byte = (1, 1, 1, 1, 2, 2, 3, 3, 3, 2);
var
  Partition: PByte;
  Sizes: array[0..3] of Byte;
  Scalefactors: array[0..39] of Byte;
  Index, Shift, GainExponent, Scfsi, Part, Row, Product, Compress, SubShift: Integer;
  IntensityChannel: Boolean;
  Gain: Single;
begin
  Row := Ord(Granule.ShortBandCount <> 0) + Ord(Granule.LongBandCount = 0);
  Partition := @Partitions[Row, 0];
  Shift := Granule.ScalefacScale + 1;
  Scfsi := Granule.Scfsi;
  FillChar(Scalefactors, SizeOf(Scalefactors), 0);
  if HeaderIsMpeg1(Header) then
  begin
    Part := CompressDecode[Granule.ScalefacCompress];
    Sizes[0] := Part shr 2;
    Sizes[1] := Part shr 2;
    Sizes[2] := Part and 3;
    Sizes[3] := Part and 3;
  end
  else
  begin
    IntensityChannel := HeaderHasIntensityStereo(Header) and (Channel <> 0);
    Compress := Granule.ScalefacCompress shr Ord(IntensityChannel);
    Part := Ord(IntensityChannel) * 3 * 4;
    Product := 1;
    while Compress >= 0 do
    begin
      Product := 1;
      for Index := 3 downto 0 do
      begin
        Sizes[Index] := (Compress div Product) mod Modulus[Part + Index];
        Product := Product * Modulus[Part + Index];
      end;
      Dec(Compress, Product);
      Inc(Part, 4);
    end;
    Inc(Partition, Part);
    Scfsi := -16;
  end;
  ReadScalefactors(@Scalefactors[0], @IntensityPositions[0], @Sizes[0], Partition, Stream, Scfsi);
  if Granule.ShortBandCount <> 0 then
  begin
    SubShift := 3 - Shift;
    Index := 0;
    while Index < Granule.ShortBandCount do
    begin
      Inc(Scalefactors[Granule.LongBandCount + Index], Granule.SubblockGain[0] shl SubShift);
      Inc(Scalefactors[Granule.LongBandCount + Index + 1], Granule.SubblockGain[1] shl SubShift);
      Inc(Scalefactors[Granule.LongBandCount + Index + 2], Granule.SubblockGain[2] shl SubShift);
      Inc(Index, 3);
    end;
  end
  else if Granule.Preflag <> 0 then
    for Index := 0 to 9 do
      Inc(Scalefactors[11 + Index], Preamplification[Index]);
  GainExponent := Granule.GlobalGain + DequantizerOutputBits * 4 - 210;
  if HeaderIsMidSideStereo(Header) then
    Dec(GainExponent, 2);
  Gain := LdexpQuarter(1 shl (MaximumScalefactorRounded div 4), MaximumScalefactorRounded - GainExponent);
  for Index := 0 to Granule.LongBandCount + Granule.ShortBandCount - 1 do
    Multipliers[Index] := LdexpQuarter(Gain, Scalefactors[Index] shl Shift);
end;

end.
