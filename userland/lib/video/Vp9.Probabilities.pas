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
  VP9 probabilities: a frame context (every probability a frame is
  decoded with), the counts of what a frame decoded, the differential
  updates of the compressed header, and the backward adaptation that
  merges the counts into the context the next frames start from
  (section 8.4 of the VP9 specification; libvpx's vp9_entropy*.c).
}
unit Vp9.Probabilities;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Video.BoolDecoder;

type
  { Coefficient probabilities of one transform size: plane type,
    reference (intra or inter), band, context, the 3 modelled nodes. }
  TVp9CoefficientModel = array[0..1, 0..1, 0..5, 0..5, 0..2] of Byte;

  TVp9MvComponentProbabilities = record
    Sign: Byte;
    Classes: array[0..9] of Byte;
    Class0: array[0..0] of Byte;
    Bits: array[0..9] of Byte;
    Class0Fraction: array[0..1, 0..2] of Byte;
    Fraction: array[0..2] of Byte;
    Class0HighPrecision: Byte;
    HighPrecision: Byte;
  end;

  TVp9FrameContext = record
    YModes: array[0..3, 0..8] of Byte;
    UvModes: array[0..9, 0..8] of Byte;
    Partitions: array[0..15, 0..2] of Byte;
    Coefficients: array[0..3] of TVp9CoefficientModel;
    SwitchableFilters: array[0..3, 0..1] of Byte;
    InterModes: array[0..6, 0..2] of Byte;
    IntraInter: array[0..3] of Byte;
    CompoundInter: array[0..4] of Byte;
    SingleReference: array[0..4, 0..1] of Byte;
    CompoundReference: array[0..4] of Byte;
    Transform8x8: array[0..1, 0..0] of Byte;
    Transform16x16: array[0..1, 0..1] of Byte;
    Transform32x32: array[0..1, 0..2] of Byte;
    Skip: array[0..2] of Byte;
    MvJoints: array[0..2] of Byte;
    MvComponents: array[0..1] of TVp9MvComponentProbabilities;
    Initialized: Boolean;
  end;
  PVp9FrameContext = ^TVp9FrameContext;

  TVp9MvComponentCounts = record
    Sign: array[0..1] of LongWord;
    Classes: array[0..10] of LongWord;
    Class0: array[0..1] of LongWord;
    Bits: array[0..9, 0..1] of LongWord;
    Class0Fraction: array[0..1, 0..3] of LongWord;
    Fraction: array[0..3] of LongWord;
    Class0HighPrecision: array[0..1] of LongWord;
    HighPrecision: array[0..1] of LongWord;
  end;

  { Coefficient token counts: zero, one, more, end of block. }
  TVp9CoefficientCounts = array[0..1, 0..1, 0..5, 0..5, 0..3] of LongWord;
  TVp9EndOfBlockCounts = array[0..1, 0..1, 0..5, 0..5] of LongWord;

  TVp9Counts = record
    YModes: array[0..3, 0..9] of LongWord;
    UvModes: array[0..9, 0..9] of LongWord;
    Partitions: array[0..15, 0..3] of LongWord;
    Coefficients: array[0..3] of TVp9CoefficientCounts;
    EndOfBlockBranches: array[0..3] of TVp9EndOfBlockCounts;
    SwitchableFilters: array[0..3, 0..2] of LongWord;
    InterModes: array[0..6, 0..3] of LongWord;
    IntraInter: array[0..3, 0..1] of LongWord;
    CompoundInter: array[0..4, 0..1] of LongWord;
    SingleReference: array[0..4, 0..1, 0..1] of LongWord;
    CompoundReference: array[0..4, 0..1] of LongWord;
    Transform8x8: array[0..1, 0..1] of LongWord;
    Transform16x16: array[0..1, 0..2] of LongWord;
    Transform32x32: array[0..1, 0..3] of LongWord;
    Skip: array[0..2, 0..1] of LongWord;
    MvJoints: array[0..3] of LongWord;
    MvComponents: array[0..1] of TVp9MvComponentCounts;
  end;
  PVp9Counts = ^TVp9Counts;

{ The probabilities a frame context starts with. }
procedure SetDefaultProbabilities(out Context: TVp9FrameContext);

{ A differentially coded probability update (if its flag is set). }
procedure ReadProbabilityUpdate(var Decoder: TBoolDecoder; var Probability: Byte);

{ Adds Source's counts to Target's (tiles decoded apart). }
procedure AddCounts(var Target: TVp9Counts; constref Source: TVp9Counts);

{ Merges Counts into Context; Previous is the context the frame started
  from. KeyOrIntraOnly and AfterKeyFrame select the coefficient update
  rate. }
procedure AdaptCoefficientProbabilities(var Context: TVp9FrameContext; constref Previous: TVp9FrameContext;
  constref Counts: TVp9Counts; KeyOrIntraOnly, AfterKeyFrame: Boolean);
procedure AdaptModeProbabilities(var Context: TVp9FrameContext; constref Previous: TVp9FrameContext;
  constref Counts: TVp9Counts; SwitchableFilter, TransformSelect: Boolean);
procedure AdaptMvProbabilities(var Context: TVp9FrameContext; constref Previous: TVp9FrameContext;
  constref Counts: TVp9Counts; AllowHighPrecision: Boolean);

implementation

uses
  Vp9.Tables;

procedure SetDefaultProbabilities(out Context: TVp9FrameContext);
var
  Component: LongInt;
begin
  Context := Default(TVp9FrameContext);
  Move(DefaultYModeProbabilities, Context.YModes, SizeOf(Context.YModes));
  Move(DefaultUvModeProbabilities, Context.UvModes, SizeOf(Context.UvModes));
  Move(DefaultPartitionProbabilities, Context.Partitions, SizeOf(Context.Partitions));
  Move(DefaultCoefficientProbabilities4x4, Context.Coefficients[0], SizeOf(TVp9CoefficientModel));
  Move(DefaultCoefficientProbabilities8x8, Context.Coefficients[1], SizeOf(TVp9CoefficientModel));
  Move(DefaultCoefficientProbabilities16x16, Context.Coefficients[2], SizeOf(TVp9CoefficientModel));
  Move(DefaultCoefficientProbabilities32x32, Context.Coefficients[3], SizeOf(TVp9CoefficientModel));
  Move(DefaultSwitchableFilterProbabilities, Context.SwitchableFilters, SizeOf(Context.SwitchableFilters));
  Move(DefaultInterModeProbabilities, Context.InterModes, SizeOf(Context.InterModes));
  Move(DefaultIntraInterProbabilities, Context.IntraInter, SizeOf(Context.IntraInter));
  Move(DefaultCompoundInterProbabilities, Context.CompoundInter, SizeOf(Context.CompoundInter));
  Move(DefaultSingleReferenceProbabilities, Context.SingleReference, SizeOf(Context.SingleReference));
  Move(DefaultCompoundReferenceProbabilities, Context.CompoundReference, SizeOf(Context.CompoundReference));
  Move(DefaultTransform8x8Probabilities, Context.Transform8x8, SizeOf(Context.Transform8x8));
  Move(DefaultTransform16x16Probabilities, Context.Transform16x16, SizeOf(Context.Transform16x16));
  Move(DefaultTransform32x32Probabilities, Context.Transform32x32, SizeOf(Context.Transform32x32));
  Move(DefaultSkipProbabilities, Context.Skip, SizeOf(Context.Skip));
  Move(DefaultMvJointProbabilities, Context.MvJoints, SizeOf(Context.MvJoints));
  for Component := 0 to 1 do
    with Context.MvComponents[Component] do
    begin
      Sign := DefaultMvSignProbabilities[Component];
      Move(DefaultMvClassProbabilities[Component], Classes, SizeOf(Classes));
      Class0[0] := DefaultMvClass0Probabilities[Component];
      Move(DefaultMvBitsProbabilities[Component], Bits, SizeOf(Bits));
      Move(DefaultMvClass0FractionProbabilities[Component], Class0Fraction, SizeOf(Class0Fraction));
      Move(DefaultMvFractionProbabilities[Component], Fraction, SizeOf(Fraction));
      Class0HighPrecision := DefaultMvClass0HighPrecisionProbabilities[Component];
      HighPrecision := DefaultMvHighPrecisionProbabilities[Component];
    end;
  Context.Initialized := True;
end;

const
  DifferentialUpdateProbability = 252;
  InverseMap: array[0..254] of Byte = (
    7, 20, 33, 46, 59, 72, 85, 98, 111, 124, 137, 150, 163, 176, 189,
    202, 215, 228, 241, 254, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11,
    12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 24, 25, 26, 27,
    28, 29, 30, 31, 32, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43,
    44, 45, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60,
    61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 73, 74, 75, 76,
    77, 78, 79, 80, 81, 82, 83, 84, 86, 87, 88, 89, 90, 91, 92,
    93, 94, 95, 96, 97, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108,
    109, 110, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 125,
    126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 138, 139, 140, 141,
    142, 143, 144, 145, 146, 147, 148, 149, 151, 152, 153, 154, 155, 156, 157,
    158, 159, 160, 161, 162, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173,
    174, 175, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 190,
    191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 203, 204, 205, 206,
    207, 208, 209, 210, 211, 212, 213, 214, 216, 217, 218, 219, 220, 221, 222,
    223, 224, 225, 226, 227, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238,
    239, 240, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 253);

function InverseRecenterNonNegative(V, M: LongInt): LongInt;
begin
  if V > 2 * M then
    Result := V
  else if (V and 1) <> 0 then
    Result := M - ((V + 1) shr 1)
  else
    Result := M + (V shr 1);
end;

function InverseRemapProbability(V, M: LongInt): LongInt;
begin
  V := InverseMap[V];
  Dec(M);
  if (M shl 1) <= 255 then
    Result := 1 + InverseRecenterNonNegative(V, M)
  else
    Result := 255 - InverseRecenterNonNegative(V, 255 - 1 - M);
end;

function DecodeUniform(var Decoder: TBoolDecoder): LongInt;
const
  L = 8;
  M = (1 shl L) - 191;
var
  V: LongInt;
begin
  V := Decoder.ReadLiteral(L - 1);
  if V < M then
    Result := V
  else
    Result := (V shl 1) - M + Decoder.ReadBit;
end;

function DecodeTermSubexponential(var Decoder: TBoolDecoder): LongInt;
begin
  if Decoder.ReadBit = 0 then
    Exit(Decoder.ReadLiteral(4));
  if Decoder.ReadBit = 0 then
    Exit(Decoder.ReadLiteral(4) + 16);
  if Decoder.ReadBit = 0 then
    Exit(Decoder.ReadLiteral(5) + 32);
  Result := DecodeUniform(Decoder) + 64;
end;

procedure ReadProbabilityUpdate(var Decoder: TBoolDecoder; var Probability: Byte);
var
  Delta: LongInt;
begin
  if Decoder.ReadBool(DifferentialUpdateProbability) <> 0 then
  begin
    Delta := DecodeTermSubexponential(Decoder);
    if Delta > 254 then
      Delta := 254;
    Probability := InverseRemapProbability(Delta, Probability);
  end;
end;

procedure AddLongWords(Target, Source: PLongWord; Count: PtrInt);
var
  Index: PtrInt;
begin
  for Index := 0 to Count - 1 do
    Inc(Target[Index], Source[Index]);
end;

procedure AddCounts(var Target: TVp9Counts; constref Source: TVp9Counts);
begin
  AddLongWords(PLongWord(@Target), PLongWord(@Source), SizeOf(TVp9Counts) div SizeOf(LongWord));
end;

{ The probability of a 0 given the counts, from 1 to 255. }
function GetProbability(Count0, Total: LongWord): LongInt;
var
  P: LongInt;
begin
  P := LongInt((QWord(Count0) * 256 + (Total shr 1)) div Total);
  if P > 255 then
    P := 255;
  if P < 1 then
    P := 1;
  Result := P;
end;

function WeightedProbability(Probability1, Probability2, Factor: LongInt): Byte;
begin
  Result := (Probability1 * (256 - Factor) + Probability2 * Factor + 128) shr 8;
end;

function MergeProbabilities(Previous: Byte; Count0, Count1: LongWord; CountSaturation,
  MaxUpdateFactor: LongWord): Byte;
var
  Probability: LongInt;
  Count, Factor: LongWord;
begin
  if Count0 + Count1 = 0 then
    Probability := 128
  else
    Probability := GetProbability(Count0, Count0 + Count1);
  Count := Count0 + Count1;
  if Count > CountSaturation then
    Count := CountSaturation;
  Factor := MaxUpdateFactor * Count div CountSaturation;
  Result := WeightedProbability(Previous, Probability, Factor);
end;

const
  ModeMvCountSaturation = 20;
  CountToUpdateFactor: array[0..ModeMvCountSaturation] of Byte = (
    0, 6, 12, 19, 25, 32, 38, 44, 51, 57, 64, 70, 76, 83, 89, 96, 102, 108, 115, 121, 128);

function ModeMvMergeProbabilities(Previous: Byte; Count0, Count1: LongWord): Byte;
var
  Total, Count: LongWord;
begin
  Total := Count0 + Count1;
  if Total = 0 then
    Exit(Previous);
  Count := Total;
  if Count > ModeMvCountSaturation then
    Count := ModeMvCountSaturation;
  Result := WeightedProbability(Previous, GetProbability(Count0, Total), CountToUpdateFactor[Count]);
end;

function TreeMergeNode(Index: LongInt; Tree: PShortInt; Previous: PByte; Counts: PLongWord;
  Probabilities: PByte): LongWord;
var
  LeftCount, RightCount: LongWord;
begin
  if Tree[Index] <= 0 then
    LeftCount := Counts[-Tree[Index]]
  else
    LeftCount := TreeMergeNode(Tree[Index], Tree, Previous, Counts, Probabilities);
  if Tree[Index + 1] <= 0 then
    RightCount := Counts[-Tree[Index + 1]]
  else
    RightCount := TreeMergeNode(Tree[Index + 1], Tree, Previous, Counts, Probabilities);
  Probabilities[Index shr 1] := ModeMvMergeProbabilities(Previous[Index shr 1], LeftCount, RightCount);
  Result := LeftCount + RightCount;
end;

procedure TreeMergeProbabilities(Tree: PShortInt; Previous: PByte; Counts: PLongWord; Probabilities: PByte);
begin
  TreeMergeNode(0, Tree, Previous, Counts, Probabilities);
end;

procedure AdaptCoefficientProbabilities(var Context: TVp9FrameContext; constref Previous: TVp9FrameContext;
  constref Counts: TVp9Counts; KeyOrIntraOnly, AfterKeyFrame: Boolean);
var
  CountSaturation, UpdateFactor: LongWord;
  Size, Plane, Reference, Band, ContextIndex, ContextCount: LongInt;
  N0, N1, N2, EndCount, Branches: LongWord;
begin
  CountSaturation := 24;
  if KeyOrIntraOnly then
    UpdateFactor := 112
  else if AfterKeyFrame then
    UpdateFactor := 128
  else
    UpdateFactor := 112;
  for Size := 0 to 3 do
    for Plane := 0 to 1 do
      for Reference := 0 to 1 do
        for Band := 0 to 5 do
        begin
          if Band = 0 then
            ContextCount := 3
          else
            ContextCount := 6;
          for ContextIndex := 0 to ContextCount - 1 do
          begin
            N0 := Counts.Coefficients[Size][Plane, Reference, Band, ContextIndex, 0];
            N1 := Counts.Coefficients[Size][Plane, Reference, Band, ContextIndex, 1];
            N2 := Counts.Coefficients[Size][Plane, Reference, Band, ContextIndex, 2];
            EndCount := Counts.Coefficients[Size][Plane, Reference, Band, ContextIndex, 3];
            Branches := Counts.EndOfBlockBranches[Size][Plane, Reference, Band, ContextIndex];
            Context.Coefficients[Size][Plane, Reference, Band, ContextIndex, 0] := MergeProbabilities(
              Previous.Coefficients[Size][Plane, Reference, Band, ContextIndex, 0], EndCount,
              Branches - EndCount, CountSaturation, UpdateFactor);
            Context.Coefficients[Size][Plane, Reference, Band, ContextIndex, 1] := MergeProbabilities(
              Previous.Coefficients[Size][Plane, Reference, Band, ContextIndex, 1], N0, N1 + N2,
              CountSaturation, UpdateFactor);
            Context.Coefficients[Size][Plane, Reference, Band, ContextIndex, 2] := MergeProbabilities(
              Previous.Coefficients[Size][Plane, Reference, Band, ContextIndex, 2], N1, N2,
              CountSaturation, UpdateFactor);
          end;
        end;
end;

procedure AdaptModeProbabilities(var Context: TVp9FrameContext; constref Previous: TVp9FrameContext;
  constref Counts: TVp9Counts; SwitchableFilter, TransformSelect: Boolean);
var
  I, J: LongInt;
begin
  for I := 0 to 3 do
    Context.IntraInter[I] := ModeMvMergeProbabilities(Previous.IntraInter[I], Counts.IntraInter[I, 0],
      Counts.IntraInter[I, 1]);
  for I := 0 to 4 do
    Context.CompoundInter[I] := ModeMvMergeProbabilities(Previous.CompoundInter[I],
      Counts.CompoundInter[I, 0], Counts.CompoundInter[I, 1]);
  for I := 0 to 4 do
    Context.CompoundReference[I] := ModeMvMergeProbabilities(Previous.CompoundReference[I],
      Counts.CompoundReference[I, 0], Counts.CompoundReference[I, 1]);
  for I := 0 to 4 do
    for J := 0 to 1 do
      Context.SingleReference[I, J] := ModeMvMergeProbabilities(Previous.SingleReference[I, J],
        Counts.SingleReference[I, J, 0], Counts.SingleReference[I, J, 1]);
  for I := 0 to 6 do
    TreeMergeProbabilities(@InterModeTree[0], @Previous.InterModes[I, 0], @Counts.InterModes[I, 0],
      @Context.InterModes[I, 0]);
  for I := 0 to 3 do
    TreeMergeProbabilities(@IntraModeTree[0], @Previous.YModes[I, 0], @Counts.YModes[I, 0],
      @Context.YModes[I, 0]);
  for I := 0 to 9 do
    TreeMergeProbabilities(@IntraModeTree[0], @Previous.UvModes[I, 0], @Counts.UvModes[I, 0],
      @Context.UvModes[I, 0]);
  for I := 0 to 15 do
    TreeMergeProbabilities(@PartitionTree[0], @Previous.Partitions[I, 0], @Counts.Partitions[I, 0],
      @Context.Partitions[I, 0]);
  if SwitchableFilter then
    for I := 0 to 3 do
      TreeMergeProbabilities(@SwitchableFilterTree[0], @Previous.SwitchableFilters[I, 0],
        @Counts.SwitchableFilters[I, 0], @Context.SwitchableFilters[I, 0]);
  if TransformSelect then
    for I := 0 to 1 do
    begin
      Context.Transform8x8[I, 0] := ModeMvMergeProbabilities(Previous.Transform8x8[I, 0],
        Counts.Transform8x8[I, 0], Counts.Transform8x8[I, 1]);
      Context.Transform16x16[I, 0] := ModeMvMergeProbabilities(Previous.Transform16x16[I, 0],
        Counts.Transform16x16[I, 0], Counts.Transform16x16[I, 1] + Counts.Transform16x16[I, 2]);
      Context.Transform16x16[I, 1] := ModeMvMergeProbabilities(Previous.Transform16x16[I, 1],
        Counts.Transform16x16[I, 1], Counts.Transform16x16[I, 2]);
      Context.Transform32x32[I, 0] := ModeMvMergeProbabilities(Previous.Transform32x32[I, 0],
        Counts.Transform32x32[I, 0], Counts.Transform32x32[I, 1] + Counts.Transform32x32[I, 2] +
        Counts.Transform32x32[I, 3]);
      Context.Transform32x32[I, 1] := ModeMvMergeProbabilities(Previous.Transform32x32[I, 1],
        Counts.Transform32x32[I, 1], Counts.Transform32x32[I, 2] + Counts.Transform32x32[I, 3]);
      Context.Transform32x32[I, 2] := ModeMvMergeProbabilities(Previous.Transform32x32[I, 2],
        Counts.Transform32x32[I, 2], Counts.Transform32x32[I, 3]);
    end;
  for I := 0 to 2 do
    Context.Skip[I] := ModeMvMergeProbabilities(Previous.Skip[I], Counts.Skip[I, 0], Counts.Skip[I, 1]);
end;

procedure AdaptMvProbabilities(var Context: TVp9FrameContext; constref Previous: TVp9FrameContext;
  constref Counts: TVp9Counts; AllowHighPrecision: Boolean);
var
  Component, J: LongInt;
begin
  TreeMergeProbabilities(@MvJointTree[0], @Previous.MvJoints[0], @Counts.MvJoints[0], @Context.MvJoints[0]);
  for Component := 0 to 1 do
  begin
    Context.MvComponents[Component].Sign := ModeMvMergeProbabilities(Previous.MvComponents[Component].Sign,
      Counts.MvComponents[Component].Sign[0], Counts.MvComponents[Component].Sign[1]);
    TreeMergeProbabilities(@MvClassTree[0], @Previous.MvComponents[Component].Classes[0],
      @Counts.MvComponents[Component].Classes[0], @Context.MvComponents[Component].Classes[0]);
    TreeMergeProbabilities(@MvClass0Tree[0], @Previous.MvComponents[Component].Class0[0],
      @Counts.MvComponents[Component].Class0[0], @Context.MvComponents[Component].Class0[0]);
    for J := 0 to 9 do
      Context.MvComponents[Component].Bits[J] := ModeMvMergeProbabilities(
        Previous.MvComponents[Component].Bits[J], Counts.MvComponents[Component].Bits[J, 0],
        Counts.MvComponents[Component].Bits[J, 1]);
    for J := 0 to 1 do
      TreeMergeProbabilities(@MvFractionTree[0], @Previous.MvComponents[Component].Class0Fraction[J, 0],
        @Counts.MvComponents[Component].Class0Fraction[J, 0],
        @Context.MvComponents[Component].Class0Fraction[J, 0]);
    TreeMergeProbabilities(@MvFractionTree[0], @Previous.MvComponents[Component].Fraction[0],
      @Counts.MvComponents[Component].Fraction[0], @Context.MvComponents[Component].Fraction[0]);
    if AllowHighPrecision then
    begin
      Context.MvComponents[Component].Class0HighPrecision := ModeMvMergeProbabilities(
        Previous.MvComponents[Component].Class0HighPrecision,
        Counts.MvComponents[Component].Class0HighPrecision[0],
        Counts.MvComponents[Component].Class0HighPrecision[1]);
      Context.MvComponents[Component].HighPrecision := ModeMvMergeProbabilities(
        Previous.MvComponents[Component].HighPrecision, Counts.MvComponents[Component].HighPrecision[0],
        Counts.MvComponents[Component].HighPrecision[1]);
    end;
  end;
end;

end.
