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
  Layer III side information (ISO 11172-3 2.4.1.7, ISO 13818-3 2.4.1.7):
  where the frame's main data starts in the bit reservoir and, for each
  granule and channel, its length, big values, gains, block type,
  Huffman table choices and scale factor settings.

  Each granule is also given its scale factor band widths: long blocks
  (22 bands), short blocks (13 bands x 3 windows, listed window by
  window) or mixed (long bands up to the first 36 lines, then short).
  The tables, per sample rate (the 9 rates folded to 8 rows, MPEG-2.5's
  11 and 12 kHz sharing MPEG-2's), are those of the standards; their
  layout follows minimp3 (public domain, by lieff).
}
unit Media.Mp3.SideInfo;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Mp3.BitStream;

const
  Mp3ShortBlockType = 2;
  Mp3StopBlockType = 3;

type
  TMp3GranuleInfo = record
    { The scale factor band widths, 0-terminated. }
    BandWidths: PByte;
    Part23Length, BigValues, ScalefacCompress: Integer;
    GlobalGain, BlockType, MixedBlockFlag, LongBandCount, ShortBandCount: Integer;
    TableSelect: array[0..2] of Integer;
    RegionCount: array[0..2] of Integer;
    SubblockGain: array[0..2] of Integer;
    Preflag, ScalefacScale, Count1Table, Scfsi: Integer;
  end;

  PMp3GranuleInfo = ^TMp3GranuleInfo;

  { Up to two granules of two channels: granule-major. }
  TMp3GranuleInfos = array[0..3] of TMp3GranuleInfo;

{ Reads the side information of the frame Header (the stream is just
  after the header and CRC); returns main_data_begin, or -1 if the side
  information is impossible. }
function ReadSideInfo(var Stream: TMp3BitStream; var Granules: TMp3GranuleInfos; Header: PByte): Integer;

implementation

uses
  Media.Mp3.Header;

const
  LongBands: array[0..7, 0..22] of Byte = (
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0),
    (12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2, 0),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36, 0),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26, 0));

  ShortBands: array[0..7, 0..39] of Byte = (
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24,
     30, 30, 30, 40, 40, 40, 18, 18, 18, 0),
    (8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2,
     2, 2, 2, 2, 2, 2, 26, 26, 26, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26,
     32, 32, 32, 42, 42, 42, 18, 18, 18, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24,
     32, 32, 32, 44, 44, 44, 12, 12, 12, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24,
     30, 30, 30, 40, 40, 40, 18, 18, 18, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18,
     22, 22, 22, 30, 30, 30, 56, 56, 56, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16,
     20, 20, 20, 26, 26, 26, 66, 66, 66, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26,
     34, 34, 34, 42, 42, 42, 12, 12, 12, 0));

  MixedBands: array[0..7, 0..39] of Byte = (
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30,
     40, 40, 40, 18, 18, 18, 0, 0, 0, 0),
    (12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2,
     2, 2, 2, 2, 2, 2, 26, 26, 26, 0),
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32,
     42, 42, 42, 18, 18, 18, 0, 0, 0, 0),
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32,
     44, 44, 44, 12, 12, 12, 0, 0, 0, 0),
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30,
     40, 40, 40, 18, 18, 18, 0, 0, 0, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22,
     22, 22, 30, 30, 30, 56, 56, 56, 0, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20,
     20, 20, 26, 26, 26, 66, 66, 66, 0, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34,
     34, 34, 42, 42, 42, 12, 12, 12, 0, 0));

function ReadSideInfo(var Stream: TMp3BitStream; var Granules: TMp3GranuleInfos; Header: PByte): Integer;
var
  Tables, Scfsi: LongWord;
  MainDataBegin, Part23Sum, RateIndex, GranuleCount, Index: Integer;
  Mpeg1, Mono: Boolean;
  Granule: ^TMp3GranuleInfo;
begin
  Mpeg1 := HeaderIsMpeg1(Header);
  Mono := HeaderIsMono(Header);
  RateIndex := HeaderRateIndex(Header);
  if RateIndex <> 0 then
    Dec(RateIndex);
  if Mono then
    GranuleCount := 1
  else
    GranuleCount := 2;
  Scfsi := 0;
  if Mpeg1 then
  begin
    GranuleCount := GranuleCount * 2;
    MainDataBegin := GetBits(Stream, 9);
    { Private bits, then 4 scfsi bits per channel (used by the second
      granule only). }
    if Mono then
      Scfsi := GetBits(Stream, 9) and $0F
    else
      Scfsi := GetBits(Stream, 11) and $FF;
  end
  else
    MainDataBegin := GetBits(Stream, 8 + GranuleCount) shr GranuleCount;
  Part23Sum := 0;
  for Index := 0 to GranuleCount - 1 do
  begin
    Granule := @Granules[Index];
    Granule^ := Default(TMp3GranuleInfo);
    Granule^.Part23Length := GetBits(Stream, 12);
    Inc(Part23Sum, Granule^.Part23Length);
    Granule^.BigValues := GetBits(Stream, 9);
    if Granule^.BigValues > 288 then
      Exit(-1);
    Granule^.GlobalGain := GetBits(Stream, 8);
    if Mpeg1 then
      Granule^.ScalefacCompress := GetBits(Stream, 4)
    else
      Granule^.ScalefacCompress := GetBits(Stream, 9);
    Granule^.BandWidths := @LongBands[RateIndex, 0];
    Granule^.LongBandCount := 22;
    Granule^.ShortBandCount := 0;
    if GetBits(Stream, 1) <> 0 then
    begin
      Granule^.BlockType := GetBits(Stream, 2);
      if Granule^.BlockType = 0 then
        Exit(-1);
      Granule^.MixedBlockFlag := GetBits(Stream, 1);
      Granule^.RegionCount[0] := 7;
      Granule^.RegionCount[1] := 255;
      Granule^.RegionCount[2] := 255;
      if Granule^.BlockType = Mp3ShortBlockType then
      begin
        if Granule^.MixedBlockFlag = 0 then
        begin
          Granule^.RegionCount[0] := 8;
          Granule^.BandWidths := @ShortBands[RateIndex, 0];
          Granule^.LongBandCount := 0;
          Granule^.ShortBandCount := 39;
        end
        else
        begin
          Granule^.BandWidths := @MixedBands[RateIndex, 0];
          if Mpeg1 then
            Granule^.LongBandCount := 8
          else
            Granule^.LongBandCount := 6;
          Granule^.ShortBandCount := 30;
        end;
      end;
      Tables := GetBits(Stream, 10) shl 5;
      Granule^.SubblockGain[0] := GetBits(Stream, 3);
      Granule^.SubblockGain[1] := GetBits(Stream, 3);
      Granule^.SubblockGain[2] := GetBits(Stream, 3);
    end
    else
    begin
      Granule^.BlockType := 0;
      Granule^.MixedBlockFlag := 0;
      Tables := GetBits(Stream, 15);
      Granule^.RegionCount[0] := GetBits(Stream, 4);
      Granule^.RegionCount[1] := GetBits(Stream, 3);
      Granule^.RegionCount[2] := 255;
    end;
    Granule^.TableSelect[0] := Tables shr 10;
    Granule^.TableSelect[1] := (Tables shr 5) and 31;
    Granule^.TableSelect[2] := Tables and 31;
    if Mpeg1 then
      Granule^.Preflag := GetBits(Stream, 1)
    else
      Granule^.Preflag := Ord(Granule^.ScalefacCompress >= 500);
    Granule^.ScalefacScale := GetBits(Stream, 1);
    Granule^.Count1Table := GetBits(Stream, 1);
    { Granules of the second half take their channel's scfsi; short
      blocks always read their own scale factors. }
    if Mpeg1 and (Index >= GranuleCount div 2) and (Granule^.BlockType <> Mp3ShortBlockType) then
    begin
      if Mono then
        Granule^.Scfsi := Scfsi and 15
      else if Index = 2 then
        Granule^.Scfsi := (Scfsi shr 4) and 15
      else
        Granule^.Scfsi := Scfsi and 15;
    end;
  end;
  if Part23Sum + Stream.Position > Stream.Limit + MainDataBegin * 8 then
    Exit(-1);
  Result := MainDataBegin;
end;

end.
