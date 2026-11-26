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
  The Layer III hybrid filter bank's frequency domain half (ISO 11172-3
  2.4.3.4.10): reordering short block lines (coded band by band, window
  by window) into subband order, alias reduction between neighbouring
  subbands of long blocks, the IMDCT (36 points for long, start and stop
  blocks, three 12-point transforms for short ones) with windowing and
  overlap-add, and the frequency inversion of odd subbands.

  The 36-point IMDCT is two 9-point DCT-IIIs and twiddles, the 12-point
  one two 3-point transforms, as in minimp3 (public domain, by lieff).
  A granule is 32 subbands of 18 lines; the overlap is 9 values per
  subband per channel (the window's symmetry halves it).
}
unit Media.Mp3.Hybrid;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TMp3Overlap = array[0..32 * 9 - 1] of Single;

{ Reorders the short block lines from Lines (bands of BandWidths, window
  by window) using Scratch (576 values). }
procedure ReorderShortLines(Lines, Scratch: PSingle; BandWidths: PByte);
procedure ReduceAliasing(Lines: PSingle; BandCount: Integer);
{ The IMDCT, windowing and overlap of one granule; LongBandCount
  subbands are long blocks even when BlockType is short (mixed blocks). }
procedure InverseTransformGranule(Lines: PSingle; var Overlap: TMp3Overlap; BlockType, LongBandCount: Integer);
procedure InvertOddSubbands(Lines: PSingle);

implementation

uses
  Media.Mp3.SideInfo;

const
  MdctWindows: array[0..1, 0..17] of Single = (
    (0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953, 0.88701083, 0.84339145, 0.79335334, 0.73727734,
     0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343, 0.46174861, 0.53729961, 0.60876143, 0.67559021),
    (1, 1, 1, 1, 1, 1, 0.99144486, 0.92387953, 0.79335334, 0, 0, 0, 0, 0, 0, 0.13052619, 0.38268343, 0.60876143));

  Twiddles9: array[0..17] of Single = (
    0.73727734, 0.79335334, 0.84339145, 0.88701083, 0.92387953, 0.95371695, 0.97629601, 0.99144486, 0.99904822,
    0.67559021, 0.60876143, 0.53729961, 0.46174861, 0.38268343, 0.30070580, 0.21643961, 0.13052619, 0.04361938);

  Twiddles3: array[0..5] of Single = (0.79335334, 0.92387953, 0.99144486, 0.60876143, 0.38268343, 0.13052619);

  AliasCoefficients: array[0..1, 0..7] of Single = (
    (0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316),
    (0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997));

procedure ReorderShortLines(Lines, Scratch: PSingle; BandWidths: PByte);
var
  Source, Target: PSingle;
  Width, Index: Integer;
begin
  Source := Lines;
  Target := Scratch;
  Width := BandWidths^;
  while Width <> 0 do
  begin
    for Index := 0 to Width - 1 do
    begin
      Target[0] := Source[0];
      Target[1] := Source[Width];
      Target[2] := Source[2 * Width];
      Inc(Target, 3);
      Inc(Source);
    end;
    Inc(Source, 2 * Width);
    Inc(BandWidths, 3);
    Width := BandWidths^;
  end;
  Move(Scratch^, Lines^, (Target - Scratch) * SizeOf(Single));
end;

procedure ReduceAliasing(Lines: PSingle; BandCount: Integer);
var
  Index: Integer;
  Upper, Lower: Single;
begin
  while BandCount > 0 do
  begin
    for Index := 0 to 7 do
    begin
      Upper := Lines[18 + Index];
      Lower := Lines[17 - Index];
      Lines[18 + Index] := Upper * AliasCoefficients[0, Index] - Lower * AliasCoefficients[1, Index];
      Lines[17 - Index] := Upper * AliasCoefficients[1, Index] + Lower * AliasCoefficients[0, Index];
    end;
    Dec(BandCount);
    Inc(Lines, 18);
  end;
end;

procedure Dct3Nine(Y: PSingle);
var
  S0, S1, S2, S3, S4, S5, S6, S7, S8, T0, T2, T4: Single;
begin
  S0 := Y[0];
  S2 := Y[2];
  S4 := Y[4];
  S6 := Y[6];
  S8 := Y[8];
  T0 := S0 + S6 * 0.5;
  S0 := S0 - S6;
  T4 := (S4 + S2) * 0.93969262;
  T2 := (S8 + S2) * 0.76604444;
  S6 := (S4 - S8) * 0.17364818;
  S4 := S4 + S8 - S2;

  S2 := S0 - S4 * 0.5;
  Y[4] := S4 + S0;
  S8 := T0 - T2 + S6;
  S0 := T0 - T4 + T2;
  S4 := T0 + T4 - S6;

  S1 := Y[1];
  S3 := Y[3];
  S5 := Y[5];
  S7 := Y[7];

  S3 := S3 * 0.86602540;
  T0 := (S5 + S1) * 0.98480775;
  T4 := (S5 - S7) * 0.34202014;
  T2 := (S1 + S7) * 0.64278761;
  S1 := (S1 - S5 - S7) * 0.86602540;

  S5 := T0 - S3 - T2;
  S7 := T4 - S3 - T0;
  S3 := T4 + S3 - T2;

  Y[0] := S4 - S7;
  Y[1] := S2 + S1;
  Y[2] := S0 - S3;
  Y[3] := S8 + S5;
  Y[5] := S8 - S5;
  Y[6] := S0 + S3;
  Y[7] := S2 - S1;
  Y[8] := S4 + S7;
end;

procedure InverseTransform36(Lines, Overlap: PSingle; Window: PSingle; BandCount: Integer);
var
  Band, Index: Integer;
  Cosines, Sines: array[0..8] of Single;
  Previous, Sum: Single;
begin
  for Band := 0 to BandCount - 1 do
  begin
    Cosines[0] := -Lines[0];
    Sines[0] := Lines[17];
    for Index := 0 to 3 do
    begin
      Sines[8 - 2 * Index] := Lines[4 * Index + 1] - Lines[4 * Index + 2];
      Cosines[1 + 2 * Index] := Lines[4 * Index + 1] + Lines[4 * Index + 2];
      Sines[7 - 2 * Index] := Lines[4 * Index + 4] - Lines[4 * Index + 3];
      Cosines[2 + 2 * Index] := -(Lines[4 * Index + 3] + Lines[4 * Index + 4]);
    end;
    Dct3Nine(@Cosines[0]);
    Dct3Nine(@Sines[0]);
    Sines[1] := -Sines[1];
    Sines[3] := -Sines[3];
    Sines[5] := -Sines[5];
    Sines[7] := -Sines[7];
    for Index := 0 to 8 do
    begin
      Previous := Overlap[Index];
      Sum := Cosines[Index] * Twiddles9[9 + Index] + Sines[Index] * Twiddles9[Index];
      Overlap[Index] := Cosines[Index] * Twiddles9[Index] - Sines[Index] * Twiddles9[9 + Index];
      Lines[Index] := Previous * Window[Index] - Sum * Window[9 + Index];
      Lines[17 - Index] := Previous * Window[9 + Index] + Sum * Window[Index];
    end;
    Inc(Lines, 18);
    Inc(Overlap, 9);
  end;
end;

procedure InverseDct3(X0, X1, X2: Single; Target: PSingle); inline;
var
  M1, A1: Single;
begin
  M1 := X1 * 0.86602540;
  A1 := X0 - X2 * 0.5;
  Target[1] := X0 + X2;
  Target[0] := A1 + M1;
  Target[2] := A1 - M1;
end;

procedure InverseTransform12(X, Target, Overlap: PSingle);
var
  Cosines, Sines: array[0..2] of Single;
  Index: Integer;
  Previous, Sum: Single;
begin
  InverseDct3(-X[0], X[6] + X[3], X[12] + X[9], @Cosines[0]);
  InverseDct3(X[15], X[12] - X[9], X[6] - X[3], @Sines[0]);
  Sines[1] := -Sines[1];
  for Index := 0 to 2 do
  begin
    Previous := Overlap[Index];
    Sum := Cosines[Index] * Twiddles3[3 + Index] + Sines[Index] * Twiddles3[Index];
    Overlap[Index] := Cosines[Index] * Twiddles3[Index] - Sines[Index] * Twiddles3[3 + Index];
    Target[Index] := Previous * Twiddles3[2 - Index] - Sum * Twiddles3[5 - Index];
    Target[5 - Index] := Previous * Twiddles3[5 - Index] + Sum * Twiddles3[2 - Index];
  end;
end;

procedure InverseTransformShort(Lines, Overlap: PSingle; BandCount: Integer);
var
  Copy: array[0..17] of Single;
begin
  while BandCount > 0 do
  begin
    Move(Lines^, Copy[0], SizeOf(Copy));
    Move(Overlap^, Lines^, 6 * SizeOf(Single));
    InverseTransform12(@Copy[0], Lines + 6, Overlap + 6);
    InverseTransform12(@Copy[1], Lines + 12, Overlap + 6);
    InverseTransform12(@Copy[2], Overlap, Overlap + 6);
    Dec(BandCount);
    Inc(Overlap, 9);
    Inc(Lines, 18);
  end;
end;

procedure InverseTransformGranule(Lines: PSingle; var Overlap: TMp3Overlap; BlockType, LongBandCount: Integer);
var
  OverlapPointer: PSingle;
begin
  OverlapPointer := @Overlap[0];
  if LongBandCount > 0 then
  begin
    InverseTransform36(Lines, OverlapPointer, @MdctWindows[0, 0], LongBandCount);
    Inc(Lines, 18 * LongBandCount);
    Inc(OverlapPointer, 9 * LongBandCount);
  end;
  if BlockType = Mp3ShortBlockType then
    InverseTransformShort(Lines, OverlapPointer, 32 - LongBandCount)
  else
    InverseTransform36(Lines, OverlapPointer, @MdctWindows[Ord(BlockType = Mp3StopBlockType), 0],
      32 - LongBandCount);
end;

procedure InvertOddSubbands(Lines: PSingle);
var
  Band, Index: Integer;
begin
  Inc(Lines, 18);
  Band := 0;
  while Band < 32 do
  begin
    Index := 1;
    while Index < 18 do
    begin
      Lines[Index] := -Lines[Index];
      Inc(Index, 2);
    end;
    Inc(Band, 2);
    Inc(Lines, 36);
  end;
end;

end.
