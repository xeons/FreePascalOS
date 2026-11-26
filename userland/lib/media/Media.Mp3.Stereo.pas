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
  Layer III joint stereo (ISO 11172-3 2.4.3.4.9, ISO 13818-3 2.4.3.2):
  mid/side (L = M + S, R = M - S; the 1/sqrt(2) is in the scale
  factors) and intensity stereo, where bands above the right channel's
  last non-zero band carry only the left channel and a position: MPEG-1
  pans by tan(position * pi / 12), MPEG-2 scales one side by a power of
  2^(-1/4) or 2^(-1/2) (the intensity scale bit of scalefac_compress).
  Short blocks find the last non-zero band per window.

  The two channels are in one array, the right 576 values after the left.
}
unit Media.Mp3.Stereo;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Mp3.SideInfo,
  Media.Mp3.Scalefactors;

procedure MidSideStereo(Left: PSingle; Count: Integer);
{ Granules points at the left channel's granule; the right's follows. }
procedure IntensityStereo(Left: PSingle; var IntensityPositions: TMp3IntensityPositions;
  Granules: PMp3GranuleInfo; Header: PByte);

implementation

uses
  Media.Mp3.Header;

procedure MidSideStereo(Left: PSingle; Count: Integer);
var
  Index: Integer;
  Right: PSingle;
  Mid, Side: Single;
begin
  Right := Left + 576;
  for Index := 0 to Count - 1 do
  begin
    Mid := Left[Index];
    Side := Right[Index];
    Left[Index] := Mid + Side;
    Right[Index] := Mid - Side;
  end;
end;

procedure IntensityBand(Left: PSingle; Count: Integer; LeftScale, RightScale: Single);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
  begin
    Left[Index + 576] := Left[Index] * RightScale;
    Left[Index] := Left[Index] * LeftScale;
  end;
end;

procedure FindTopBands(Right: PSingle; BandWidths: PByte; BandCount: Integer; var TopBand: array of Integer);
var
  Band, Line: Integer;
begin
  TopBand[0] := -1;
  TopBand[1] := -1;
  TopBand[2] := -1;
  for Band := 0 to BandCount - 1 do
  begin
    Line := 0;
    while Line < BandWidths[Band] do
    begin
      if (Right[Line] <> 0) or (Right[Line + 1] <> 0) then
      begin
        TopBand[Band mod 3] := Band;
        Break;
      end;
      Inc(Line, 2);
    end;
    Inc(Right, BandWidths[Band]);
  end;
end;

procedure ProcessStereo(Left: PSingle; const IntensityPositions: TMp3IntensityPositions; BandWidths: PByte;
  Header: PByte; const TopBand: array of Integer; Mpeg2Shift: Integer);
const
  Pans: array[0..13] of Single = (0, 1, 0.21132487, 0.78867513, 0.36602540, 0.63397460, 0.5, 0.5, 0.63397460,
    0.36602540, 0.78867513, 0.21132487, 1, 0);
var
  Band, Position, MaximumPosition: Integer;
  LeftScale, RightScale, Scale: Single;
begin
  if HeaderIsMpeg1(Header) then
    MaximumPosition := 7
  else
    MaximumPosition := 64;
  Band := 0;
  while BandWidths[Band] <> 0 do
  begin
    Position := IntensityPositions[Band];
    if (Band > TopBand[Band mod 3]) and (Position < MaximumPosition) then
    begin
      if HeaderHasMidSide(Header) then
        Scale := 1.41421356
      else
        Scale := 1;
      if HeaderIsMpeg1(Header) then
      begin
        LeftScale := Pans[2 * Position];
        RightScale := Pans[2 * Position + 1];
      end
      else
      begin
        LeftScale := 1;
        RightScale := LdexpQuarter(1, ((Position + 1) shr 1) shl Mpeg2Shift);
        if (Position and 1) <> 0 then
        begin
          LeftScale := RightScale;
          RightScale := 1;
        end;
      end;
      IntensityBand(Left, BandWidths[Band], LeftScale * Scale, RightScale * Scale);
    end
    else if HeaderHasMidSide(Header) then
      MidSideStereo(Left, BandWidths[Band]);
    Inc(Left, BandWidths[Band]);
    Inc(Band);
  end;
end;

procedure IntensityStereo(Left: PSingle; var IntensityPositions: TMp3IntensityPositions;
  Granules: PMp3GranuleInfo; Header: PByte);
var
  TopBand: array[0..2] of Integer;
  BandCount, Index, Windows, DefaultPosition, TopIndex, Previous, Largest: Integer;
begin
  BandCount := Granules[0].LongBandCount + Granules[0].ShortBandCount;
  if Granules[0].ShortBandCount <> 0 then
    Windows := 3
  else
    Windows := 1;
  FindTopBands(Left + 576, Granules[0].BandWidths, BandCount, TopBand);
  if Granules[0].LongBandCount <> 0 then
  begin
    Largest := TopBand[0];
    if TopBand[1] > Largest then
      Largest := TopBand[1];
    if TopBand[2] > Largest then
      Largest := TopBand[2];
    TopBand[0] := Largest;
    TopBand[1] := Largest;
    TopBand[2] := Largest;
  end;
  if HeaderIsMpeg1(Header) then
    DefaultPosition := 3
  else
    DefaultPosition := 0;
  for Index := 0 to Windows - 1 do
  begin
    { The last band has no scale factor of its own: it takes the one
      before it, or the default if that band is not intensity coded. }
    TopIndex := BandCount - Windows + Index;
    Previous := TopIndex - Windows;
    if TopBand[Index] >= Previous then
      IntensityPositions[TopIndex] := DefaultPosition
    else
      IntensityPositions[TopIndex] := IntensityPositions[Previous];
  end;
  ProcessStereo(Left, IntensityPositions, Granules[0].BandWidths, Header, TopBand, Granules[1].ScalefacCompress and 1);
end;

end.
