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
  The polyphase synthesis filter bank (ISO 11172-3 2.4.3.2.2, Annex
  3-A.2): 32 subband samples at a time back to 32 PCM samples.

  The standard's matrixing (a 32 x 64 cosine matrix) is done as a fast
  32-point DCT-II on each time slot of the granule at once (stage
  butterflies with the secant factors), and the 512-tap window is applied
  to the 16 most recent slots kept in the state, two channels side by
  side, using the window's symmetry: each pair of outputs n and 32 - n
  shares the same products. This is minimp3's arrangement (public
  domain, by lieff). The window coefficients are the standard's D[i]
  in integer units; the dequantizer's scale (Media.Mp3.Scalefactors)
  makes their products 16-bit samples, which OutputScale brings to
  -1..1.

  The state is 15 slots of 64 values (left and right interleaved by
  pairs).
}
unit Media.Mp3.Synthesis;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TMp3SynthesisState = array[0..15 * 64 - 1] of Single;
  { The working area: the state plus a granule's 18 slots. }
  TMp3SynthesisLines = array[0..(18 + 15) * 64 - 1] of Single;

{ Turns SubbandCount (18 for Layer III) slots of Lines (32 subbands of 18
  values per channel; the right channel 576 values after the left) into
  interleaved PCM floats (-1..1) at Output. }
procedure SynthesizeGranule(var State: TMp3SynthesisState; Lines: PSingle; SlotCount, Channels: Integer;
  Output: PSingle; var Work: TMp3SynthesisLines);

implementation

const
  { The decoder works in 16-bit scale; output is -1..1. }
  OutputScale = 1 / 32768;

  Window: array[0..239] of Single = (
    -1, 26, -31, 208, 218, 401, -519, 2063, 2000, 4788, -5517, 7134, 5959, 35640, -39336, 74992,
    -1, 24, -35, 202, 222, 347, -581, 2080, 1952, 4425, -5879, 7640, 5288, 33791, -41176, 74856,
    -1, 21, -38, 196, 225, 294, -645, 2087, 1893, 4063, -6237, 8092, 4561, 31947, -43006, 74630,
    -1, 19, -41, 190, 227, 244, -711, 2085, 1822, 3705, -6589, 8492, 3776, 30112, -44821, 74313,
    -1, 17, -45, 183, 228, 197, -779, 2075, 1739, 3351, -6935, 8840, 2935, 28289, -46617, 73908,
    -1, 16, -49, 176, 228, 153, -848, 2057, 1644, 3004, -7271, 9139, 2037, 26482, -48390, 73415,
    -2, 14, -53, 169, 227, 111, -919, 2032, 1535, 2663, -7597, 9389, 1082, 24694, -50137, 72835,
    -2, 13, -58, 161, 224, 72, -991, 2001, 1414, 2330, -7910, 9592, 70, 22929, -51853, 72169,
    -2, 11, -63, 154, 221, 36, -1064, 1962, 1280, 2006, -8209, 9750, -998, 21189, -53534, 71420,
    -2, 10, -68, 147, 215, 2, -1137, 1919, 1131, 1692, -8491, 9863, -2122, 19478, -55178, 70590,
    -3, 9, -73, 139, 208, -29, -1210, 1870, 970, 1388, -8755, 9935, -3300, 17799, -56778, 69679,
    -3, 8, -79, 132, 200, -57, -1283, 1817, 794, 1095, -8998, 9966, -4533, 16155, -58333, 68692,
    -4, 7, -85, 125, 189, -83, -1356, 1759, 605, 814, -9219, 9959, -5818, 14548, -59838, 67629,
    -4, 7, -91, 117, 177, -106, -1428, 1698, 402, 545, -9416, 9916, -7154, 12980, -61289, 66494,
    -5, 6, -97, 111, 163, -127, -1498, 1634, 185, 288, -9585, 9838, -8540, 11455, -62684, 65290);

  Secants: array[0..23] of Single = (
    10.19000816, 0.50060302, 0.50241929, 3.40760851, 0.50547093, 0.52249861, 2.05778098, 0.51544732,
    0.56694406, 1.48416460, 0.53104258, 0.64682180, 1.16943991, 0.55310392, 0.78815460, 0.97256821,
    0.58293498, 1.06067765, 0.83934963, 0.62250412, 1.72244716, 0.74453628, 0.67480832, 5.10114861);

{ The 32-point DCT-II of each of SlotCount time slots (stride 18). }
procedure DctII(Lines: PSingle; SlotCount: Integer);
var
  Slot, Index: Integer;
  T: array[0..3, 0..7] of Single;
  Y: PSingle;
  X0, X1, X2, X3, X4, X5, X6, X7, XT, T0, T1, T2, T3: Single;
begin
  for Slot := 0 to SlotCount - 1 do
  begin
    Y := Lines + Slot;
    for Index := 0 to 7 do
    begin
      X0 := Y[Index * 18];
      X1 := Y[(15 - Index) * 18];
      X2 := Y[(16 + Index) * 18];
      X3 := Y[(31 - Index) * 18];
      T0 := X0 + X3;
      T1 := X1 + X2;
      T2 := (X1 - X2) * Secants[3 * Index];
      T3 := (X0 - X3) * Secants[3 * Index + 1];
      T[0, Index] := T0 + T1;
      T[1, Index] := (T0 - T1) * Secants[3 * Index + 2];
      T[2, Index] := T3 + T2;
      T[3, Index] := (T3 - T2) * Secants[3 * Index + 2];
    end;
    for Index := 0 to 3 do
    begin
      X0 := T[Index, 0];
      X1 := T[Index, 1];
      X2 := T[Index, 2];
      X3 := T[Index, 3];
      X4 := T[Index, 4];
      X5 := T[Index, 5];
      X6 := T[Index, 6];
      X7 := T[Index, 7];
      XT := X0 - X7;
      X0 := X0 + X7;
      X7 := X1 - X6;
      X1 := X1 + X6;
      X6 := X2 - X5;
      X2 := X2 + X5;
      X5 := X3 - X4;
      X3 := X3 + X4;
      X4 := X0 - X3;
      X0 := X0 + X3;
      X3 := X1 - X2;
      X1 := X1 + X2;
      T[Index, 0] := X0 + X1;
      T[Index, 4] := (X0 - X1) * 0.70710677;
      X5 := X5 + X6;
      X6 := (X6 + X7) * 0.70710677;
      X7 := X7 + XT;
      X3 := (X3 + X4) * 0.70710677;
      { A rotation by pi/8 in three shears. }
      X5 := X5 - X7 * 0.198912367;
      X7 := X7 + X5 * 0.382683432;
      X5 := X5 - X7 * 0.198912367;
      X0 := XT - X6;
      XT := XT + X6;
      T[Index, 1] := (XT + X7) * 0.50979561;
      T[Index, 2] := (X4 + X3) * 0.54119611;
      T[Index, 3] := (X0 - X5) * 0.60134488;
      T[Index, 5] := (X0 + X5) * 0.89997619;
      T[Index, 6] := (X4 - X3) * 1.30656302;
      T[Index, 7] := (XT - X7) * 2.56291556;
    end;
    for Index := 0 to 6 do
    begin
      Y[0] := T[0, Index];
      Y[18] := T[2, Index] + T[3, Index] + T[3, Index + 1];
      Y[2 * 18] := T[1, Index] + T[1, Index + 1];
      Y[3 * 18] := T[2, Index + 1] + T[3, Index] + T[3, Index + 1];
      Inc(Y, 4 * 18);
    end;
    Y[0] := T[0, 7];
    Y[18] := T[2, 7] + T[3, 7];
    Y[2 * 18] := T[1, 7];
    Y[3 * 18] := T[3, 7];
  end;
end;

{ The outputs 0 and 16 of a slot: the window's middle taps. }
procedure SynthesizePair(Output: PSingle; Channels: Integer; Z: PSingle);
var
  A: Single;
begin
  A := (Z[14 * 64] - Z[0]) * 29;
  A := A + (Z[1 * 64] + Z[13 * 64]) * 213;
  A := A + (Z[12 * 64] - Z[2 * 64]) * 459;
  A := A + (Z[3 * 64] + Z[11 * 64]) * 2037;
  A := A + (Z[10 * 64] - Z[4 * 64]) * 5153;
  A := A + (Z[5 * 64] + Z[9 * 64]) * 6574;
  A := A + (Z[8 * 64] - Z[6 * 64]) * 37489;
  A := A + Z[7 * 64] * 75038;
  Output[0] := A * OutputScale;
  Inc(Z, 2);
  A := Z[14 * 64] * 104;
  A := A + Z[12 * 64] * 1567;
  A := A + Z[10 * 64] * 9727;
  A := A + Z[8 * 64] * 64019;
  A := A + Z[6 * 64] * -9975;
  A := A + Z[4 * 64] * -45;
  A := A + Z[2 * 64] * 146;
  A := A + Z[0 * 64] * -5;
  Output[16 * Channels] := A * OutputScale;
end;

{ Two time slots (Left and Left + 1) to 64 samples per channel. }
procedure SynthesizeSlots(Left: PSingle; Output: PSingle; Channels: Integer; Lines: PSingle);
var
  Right, OutputRight, Z, W, Vz, Vy: PSingle;
  Index, Tap, Lane: Integer;
  A, B: array[0..3] of Single;
  W0, W1: Single;
begin
  Right := Left + 576 * (Channels - 1);
  OutputRight := Output + (Channels - 1);
  Z := Lines + 15 * 64;

  Z[4 * 15] := Left[18 * 16];
  Z[4 * 15 + 1] := Right[18 * 16];
  Z[4 * 15 + 2] := Left[0];
  Z[4 * 15 + 3] := Right[0];

  Z[4 * 31] := Left[1 + 18 * 16];
  Z[4 * 31 + 1] := Right[1 + 18 * 16];
  Z[4 * 31 + 2] := Left[1];
  Z[4 * 31 + 3] := Right[1];

  SynthesizePair(OutputRight, Channels, Lines + 4 * 15 + 1);
  SynthesizePair(OutputRight + 32 * Channels, Channels, Lines + 4 * 15 + 64 + 1);
  SynthesizePair(Output, Channels, Lines + 4 * 15);
  SynthesizePair(Output + 32 * Channels, Channels, Lines + 4 * 15 + 64);

  W := @Window[0];
  for Index := 14 downto 0 do
  begin
    Z[4 * Index] := Left[18 * (31 - Index)];
    Z[4 * Index + 1] := Right[18 * (31 - Index)];
    Z[4 * Index + 2] := Left[1 + 18 * (31 - Index)];
    Z[4 * Index + 3] := Right[1 + 18 * (31 - Index)];
    Z[4 * (Index + 16)] := Left[1 + 18 * (1 + Index)];
    Z[4 * (Index + 16) + 1] := Right[1 + 18 * (1 + Index)];
    Z[4 * (Index - 16) + 2] := Left[18 * (1 + Index)];
    Z[4 * (Index - 16) + 3] := Right[18 * (1 + Index)];

    for Tap := 0 to 7 do
    begin
      W0 := W[0];
      W1 := W[1];
      Inc(W, 2);
      Vz := @Z[4 * Index - Tap * 64];
      Vy := @Z[4 * Index - (15 - Tap) * 64];
      if Tap = 0 then
        for Lane := 0 to 3 do
        begin
          B[Lane] := Vz[Lane] * W1 + Vy[Lane] * W0;
          A[Lane] := Vz[Lane] * W0 - Vy[Lane] * W1;
        end
      else if (Tap and 1) = 0 then
        for Lane := 0 to 3 do
        begin
          B[Lane] := B[Lane] + Vz[Lane] * W1 + Vy[Lane] * W0;
          A[Lane] := A[Lane] + Vz[Lane] * W0 - Vy[Lane] * W1;
        end
      else
        for Lane := 0 to 3 do
        begin
          B[Lane] := B[Lane] + Vz[Lane] * W1 + Vy[Lane] * W0;
          A[Lane] := A[Lane] + Vy[Lane] * W1 - Vz[Lane] * W0;
        end;
    end;

    OutputRight[(15 - Index) * Channels] := A[1] * OutputScale;
    OutputRight[(17 + Index) * Channels] := B[1] * OutputScale;
    Output[(15 - Index) * Channels] := A[0] * OutputScale;
    Output[(17 + Index) * Channels] := B[0] * OutputScale;
    OutputRight[(47 - Index) * Channels] := A[3] * OutputScale;
    OutputRight[(49 + Index) * Channels] := B[3] * OutputScale;
    Output[(47 - Index) * Channels] := A[2] * OutputScale;
    Output[(49 + Index) * Channels] := B[2] * OutputScale;
  end;
end;

procedure SynthesizeGranule(var State: TMp3SynthesisState; Lines: PSingle; SlotCount, Channels: Integer;
  Output: PSingle; var Work: TMp3SynthesisLines);
var
  Channel, Slot, Index: Integer;
begin
  for Channel := 0 to Channels - 1 do
    DctII(Lines + 576 * Channel, SlotCount);
  Move(State[0], Work[0], SizeOf(State));
  Slot := 0;
  while Slot < SlotCount do
  begin
    SynthesizeSlots(Lines + Slot, Output + 32 * Channels * Slot, Channels, @Work[Slot * 64]);
    Inc(Slot, 2);
  end;
  if Channels = 1 then
  begin
    { Mono keeps only its own lanes, as the reference decoder does. }
    Index := 0;
    while Index < 15 * 64 do
    begin
      State[Index] := Work[SlotCount * 64 + Index];
      Inc(Index, 2);
    end;
  end
  else
    Move(Work[SlotCount * 64], State[0], SizeOf(State));
end;

end.
