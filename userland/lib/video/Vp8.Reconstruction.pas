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
  Reconstructing VP8 macroblocks: reading a macroblock's coefficients
  from its row's token partition, predicting it (intra from the pixels
  around it, or from a reference picture), and adding the inverse
  transformed residual.

  A row of macroblocks needs the row above finished up to one
  macroblock further right (the 4x4 prediction's above-right pixels);
  rows in different token partitions can be reconstructed at the same
  time as long as they keep that distance (TVp8FrameReconstruction has
  no state shared between rows but the above contexts, which are per
  column and read by a row only after the row above wrote them).
}
unit Vp8.Reconstruction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Video.BoolDecoder, Video.WorkerPool, Vp8.Tables, Vp8.FrameHeader, Vp8.Modes, Vp8.Residuals,
  Vp8.Pictures;

type
  TVp8Dequantizer = record
    Y1Dc, Y1Ac, Y2Dc, Y2Ac, UvDc, UvAc: LongInt;
  end;

  { What reconstruction needs of a frame. }
  TVp8FrameReconstruction = class
  public
    Header: TVp8FrameHeader;
    Target: TVp8Picture;
    References: array[1..3] of TVp8Picture;
    Grid: ^TVp8ModeInfoGrid;
    Probabilities: ^TCoefficientProbabilities;
    { By segment (all the same without segmentation). }
    Dequantizers: array[0..3] of TVp8Dequantizer;
    SegmentationEnabled: Boolean;
    { One per macroblock column. }
    AboveContexts: array of TEntropyContexts;
    { Reconstructs row Row with the tokens of Decoder. With Progress
      (rows reconstructed at the same time), waits for the row above to
      be far enough and publishes how far this row got: the number of
      macroblocks done, the number plus 1 once the row is finished. }
    procedure ReconstructRow(Row: LongInt; var Decoder: TBoolDecoder; Progress: TVideoProgress);
  end;

{ The quantizer steps of quantizer index Index with the header's deltas. }
function ComputeDequantizer(constref Header: TVp8FrameHeader; Index: LongInt): TVp8Dequantizer;

implementation

uses
  Vp8.Transforms, Vp8.IntraPrediction, Vp8.InterPrediction;

type
  TRowState = record
    Left: TEntropyContexts;
    Coefficients: TMacroblockCoefficients;
  end;

function ClampIndex(Index: LongInt): LongInt; inline;
begin
  if Index < 0 then
    Result := 0
  else if Index > 127 then
    Result := 127
  else
    Result := Index;
end;

function ComputeDequantizer(constref Header: TVp8FrameHeader; Index: LongInt): TVp8Dequantizer;
begin
  Result.Y1Dc := DcQuantizerSteps[ClampIndex(Index + Header.Y1DcDelta)];
  Result.Y2Dc := DcQuantizerSteps[ClampIndex(Index + Header.Y2DcDelta)] * 2;
  Result.UvDc := DcQuantizerSteps[ClampIndex(Index + Header.UvDcDelta)];
  if Result.UvDc > 132 then
    Result.UvDc := 132;
  Result.Y1Ac := AcQuantizerSteps[ClampIndex(Index)];
  Result.Y2Ac := (AcQuantizerSteps[ClampIndex(Index + Header.Y2AcDelta)] * 101581) shr 16;
  if Result.Y2Ac < 8 then
    Result.Y2Ac := 8;
  Result.UvAc := AcQuantizerSteps[ClampIndex(Index + Header.UvAcDelta)];
end;

{ Dequantizes a block in place: Dc for the first coefficient, Ac for
  the others. }
procedure Dequantize(Values: PSmallInt; Dc, Ac: LongInt);
var
  Index: LongInt;
begin
  Values[0] := SmallInt(Values[0] * Dc);
  for Index := 1 to 15 do
    Values[Index] := SmallInt(Values[Index] * Ac);
end;

{ Adds a block's residual: the full transform when it has more than a
  DC, else the DC alone. }
procedure AddResidual(Values: PSmallInt; BlockEnd: LongInt; Dc, Ac: LongInt;
  Target: PByte; Stride: LongInt);
begin
  if BlockEnd > 1 then
  begin
    Dequantize(Values, Dc, Ac);
    AddInverseTransform(Values, Target, Stride);
  end
  else
    AddDcOnly(SmallInt(Values[0] * Dc), Target, Stride);
end;

type
  TEdgeDistances = record
    ToLeft, ToRight, ToTop, ToBottom: LongInt;
  end;

procedure ClampToBorder(var Mv: TVp8MotionVector; constref Edges: TEdgeDistances);
begin
  if Mv.Col < Edges.ToLeft - (19 shl 3) then
    Mv.Col := Edges.ToLeft - (16 shl 3)
  else if Mv.Col > Edges.ToRight + (18 shl 3) then
    Mv.Col := Edges.ToRight + (16 shl 3);
  if Mv.Row < Edges.ToTop - (19 shl 3) then
    Mv.Row := Edges.ToTop - (16 shl 3)
  else if Mv.Row > Edges.ToBottom + (18 shl 3) then
    Mv.Row := Edges.ToBottom + (16 shl 3);
end;

procedure ClampChromaToBorder(var Mv: TVp8MotionVector; constref Edges: TEdgeDistances);
begin
  if 2 * Mv.Col < Edges.ToLeft - (19 shl 3) then
    Mv.Col := SarLongint(Edges.ToLeft - (16 shl 3), 1);
  if 2 * Mv.Col > Edges.ToRight + (18 shl 3) then
    Mv.Col := SarLongint(Edges.ToRight + (16 shl 3), 1);
  if 2 * Mv.Row < Edges.ToTop - (19 shl 3) then
    Mv.Row := SarLongint(Edges.ToTop - (16 shl 3), 1);
  if 2 * Mv.Row > Edges.ToBottom + (18 shl 3) then
    Mv.Row := SarLongint(Edges.ToBottom + (16 shl 3), 1);
end;

{ Predicts a block of plane Plane at (X, Y) from Reference with Mv (in
  eighth pixels of that plane). }
procedure PredictFromReference(Reference: TVp8Picture; Plane: LongInt; X, Y: LongInt;
  constref Mv: TVp8MotionVector; Target: PByte; TargetStride, Width, Height: LongInt;
  Bilinear: Boolean);
var
  Stride: LongInt;
  Source: PByte;
begin
  Stride := Reference.Planes[Plane].Stride;
  Source := Reference.Planes[Plane].Origin + (Y + SarLongint(Mv.Row, 3)) * Stride +
    X + SarLongint(Mv.Col, 3);
  PredictInterBlock(Source, Stride, Mv.Col and 7, Mv.Row and 7, Target, TargetStride,
    Width, Height, Bilinear);
end;

function HalveChromaComponent(Value: LongInt; FullPixel: Boolean): SmallInt;
begin
  if Value < 0 then
    Dec(Value)
  else
    Inc(Value);
  Value := Value div 2;
  if FullPixel then
    Value := Value and not 7;
  Result := Value;
end;

function AverageChromaComponent(Sum: LongInt; FullPixel: Boolean): SmallInt;
begin
  if Sum < 0 then
    Dec(Sum, 4)
  else
    Inc(Sum, 4);
  Sum := Sum div 8;
  if FullPixel then
    Sum := Sum and not 7;
  Result := Sum;
end;

procedure PredictInter(Recon: TVp8FrameReconstruction; Info: PVp8MacroblockInfo;
  Row, Column: LongInt; Y, U, V: PByte);
var
  Reference: TVp8Picture;
  Edges: TEdgeDistances;
  Mv, ChromaMv: TVp8MotionVector;
  YStride, UvStride, Block, I, J, SumRow, SumCol, First: LongInt;
  Bilinear, FullPixel: Boolean;
begin
  Reference := Recon.References[Info^.Reference];
  YStride := Recon.Target.Planes[0].Stride;
  UvStride := Recon.Target.Planes[1].Stride;
  Bilinear := Recon.Header.Bilinear;
  FullPixel := Recon.Header.FullPixel;
  Edges.ToLeft := -((Column * 16) shl 3);
  Edges.ToRight := ((Recon.Grid^.Columns - 1 - Column) * 16) shl 3;
  Edges.ToTop := -((Row * 16) shl 3);
  Edges.ToBottom := ((Recon.Grid^.Rows - 1 - Row) * 16) shl 3;
  if Info^.YMode <> ModeSplit then
  begin
    Mv := Info^.Mv;
    if Info^.NeedsClamping then
      ClampToBorder(Mv, Edges);
    PredictFromReference(Reference, 0, Column * 16, Row * 16, Mv, Y, YStride, 16, 16, Bilinear);
    ChromaMv.Row := HalveChromaComponent(Mv.Row, FullPixel);
    ChromaMv.Col := HalveChromaComponent(Mv.Col, FullPixel);
    { The reference decoder leaves the chroma unpredicted then. }
    if (2 * ChromaMv.Col < Edges.ToLeft - (19 shl 3)) or (2 * ChromaMv.Col > Edges.ToRight + (18 shl 3)) or
      (2 * ChromaMv.Row < Edges.ToTop - (19 shl 3)) or (2 * ChromaMv.Row > Edges.ToBottom + (18 shl 3)) then
      Exit;
    PredictFromReference(Reference, 1, Column * 8, Row * 8, ChromaMv, U, UvStride, 8, 8, Bilinear);
    PredictFromReference(Reference, 2, Column * 8, Row * 8, ChromaMv, V, UvStride, 8, 8, Bilinear);
    Exit;
  end;
  for Block := 0 to 15 do
  begin
    Mv := Info^.SubblockMvs[Block];
    if Info^.NeedsClamping then
      ClampToBorder(Mv, Edges);
    PredictFromReference(Reference, 0, Column * 16 + (Block and 3) * 4, Row * 16 + (Block shr 2) * 4,
      Mv, Y + (Block shr 2) * 4 * YStride + (Block and 3) * 4, YStride, 4, 4, Bilinear);
  end;
  for I := 0 to 1 do
    for J := 0 to 1 do
    begin
      First := I * 8 + J * 2;
      SumRow := Info^.SubblockMvs[First].Row + Info^.SubblockMvs[First + 1].Row +
        Info^.SubblockMvs[First + 4].Row + Info^.SubblockMvs[First + 5].Row;
      SumCol := Info^.SubblockMvs[First].Col + Info^.SubblockMvs[First + 1].Col +
        Info^.SubblockMvs[First + 4].Col + Info^.SubblockMvs[First + 5].Col;
      ChromaMv.Row := AverageChromaComponent(SumRow, FullPixel);
      ChromaMv.Col := AverageChromaComponent(SumCol, FullPixel);
      if Info^.NeedsClamping then
        ClampChromaToBorder(ChromaMv, Edges);
      PredictFromReference(Reference, 1, Column * 8 + J * 4, Row * 8 + I * 4, ChromaMv,
        U + I * 4 * UvStride + J * 4, UvStride, 4, 4, Bilinear);
      PredictFromReference(Reference, 2, Column * 8 + J * 4, Row * 8 + I * 4, ChromaMv,
        V + I * 4 * UvStride + J * 4, UvStride, 4, 4, Bilinear);
    end;
end;

procedure ReconstructMacroblock(Recon: TVp8FrameReconstruction; var Decoder: TBoolDecoder;
  var State: TRowState; Row, Column: LongInt);
var
  Info: PVp8MacroblockInfo;
  Dequantizer: TVp8Dequantizer;
  Y, U, V, Above: PByte;
  YStride, UvStride, Block, Total, LumaDc: LongInt;
  Coefficients: ^TMacroblockCoefficients;
  AboveRight: LongWord;
  Left: array[0..3] of Byte;
begin
  Info := MacroblockAt(Recon.Grid^, Row, Column);
  Coefficients := @State.Coefficients;
  if Recon.SegmentationEnabled then
    Dequantizer := Recon.Dequantizers[Info^.Segment]
  else
    Dequantizer := Recon.Dequantizers[0];
  if Info^.Skip then
    ClearContexts(@Recon.AboveContexts[Column], @State.Left, not Info^.HasSubblocks)
  else
  begin
    Total := ReadMacroblockCoefficients(Decoder, Recon.Probabilities^,
      not Info^.HasSubblocks, @Recon.AboveContexts[Column], @State.Left, Coefficients^);
    Info^.Skip := Total = 0;
  end;
  YStride := Recon.Target.Planes[0].Stride;
  UvStride := Recon.Target.Planes[1].Stride;
  Y := Recon.Target.Planes[0].Origin + Row * 16 * YStride + Column * 16;
  U := Recon.Target.Planes[1].Origin + Row * 8 * UvStride + Column * 8;
  V := Recon.Target.Planes[2].Origin + Row * 8 * UvStride + Column * 8;
  if Info^.Reference = ReferenceIntra then
  begin
    PredictBlock(Info^.UvMode, U, UvStride, 8, Column > 0, Row > 0);
    PredictBlock(Info^.UvMode, V, UvStride, 8, Column > 0, Row > 0);
    if Info^.YMode <> ModeBlocks then
      PredictBlock(Info^.YMode, Y, YStride, 16, Column > 0, Row > 0)
    else
    begin
      { The above-right pixels of the blocks on the right come from the
        macroblock above-right, copied down beside rows 3, 7 and 11. }
      Move((Y - YStride + 16)^, AboveRight, 4);
      Move(AboveRight, (Y + 3 * YStride + 16)^, 4);
      Move(AboveRight, (Y + 7 * YStride + 16)^, 4);
      Move(AboveRight, (Y + 11 * YStride + 16)^, 4);
      for Block := 0 to 15 do
      begin
        Above := Y + ((Block shr 2) * 4 - 1) * YStride + (Block and 3) * 4;
        Left[0] := Above[YStride - 1];
        Left[1] := Above[2 * YStride - 1];
        Left[2] := Above[3 * YStride - 1];
        Left[3] := Above[4 * YStride - 1];
        PredictSubblock(Info^.SubblockModes[Block], Above + YStride, YStride, Above, @Left[0]);
        if (not Info^.Skip) and (Coefficients^.Ends[Block] > 0) then
          AddResidual(@Coefficients^.Values[Block, 0], Coefficients^.Ends[Block],
            Dequantizer.Y1Dc, Dequantizer.Y1Ac, Above + YStride, YStride);
      end;
    end;
  end
  else
    PredictInter(Recon, Info, Row, Column, Y, U, V);
  if not Info^.Skip then
  begin
    if Info^.YMode <> ModeBlocks then
    begin
      LumaDc := Dequantizer.Y1Dc;
      if Info^.YMode <> ModeSplit then
      begin
        if Coefficients^.Ends[SecondOrderBlock] > 1 then
        begin
          Dequantize(@Coefficients^.Values[SecondOrderBlock, 0], Dequantizer.Y2Dc, Dequantizer.Y2Ac);
          InverseWalsh(@Coefficients^.Values[SecondOrderBlock, 0], @Coefficients^.Values[0, 0]);
        end
        else
          InverseWalshDcOnly(SmallInt(Coefficients^.Values[SecondOrderBlock, 0] * Dequantizer.Y2Dc),
            @Coefficients^.Values[0, 0]);
        LumaDc := 1;
      end;
      for Block := 0 to 15 do
        AddResidual(@Coefficients^.Values[Block, 0], Coefficients^.Ends[Block], LumaDc,
          Dequantizer.Y1Ac, Y + (Block shr 2) * 4 * YStride + (Block and 3) * 4, YStride);
    end;
    for Block := 16 to 19 do
      AddResidual(@Coefficients^.Values[Block, 0], Coefficients^.Ends[Block], Dequantizer.UvDc,
        Dequantizer.UvAc, U + ((Block - 16) shr 1) * 4 * UvStride + ((Block - 16) and 1) * 4, UvStride);
    for Block := 20 to 23 do
      AddResidual(@Coefficients^.Values[Block, 0], Coefficients^.Ends[Block], Dequantizer.UvDc,
        Dequantizer.UvAc, V + ((Block - 20) shr 1) * 4 * UvStride + ((Block - 20) and 1) * 4, UvStride);
    FillChar(Coefficients^, SizeOf(Coefficients^.Values), 0);
  end;
end;

procedure TVp8FrameReconstruction.ReconstructRow(Row: LongInt; var Decoder: TBoolDecoder;
  Progress: TVideoProgress);
var
  State: TRowState;
  Column, Line, Index: LongInt;
  P: PByte;
begin
  FillChar(State, SizeOf(State), 0);
  { The column left of the picture is 129 for intra prediction. }
  with Target.Planes[0] do
    for Line := 0 to 15 do
      Origin[(Row * 16 + Line) * Stride - 1] := 129;
  for Index := 1 to 2 do
    with Target.Planes[Index] do
      for Line := 0 to 7 do
        Origin[(Row * 8 + Line) * Stride - 1] := 129;
  for Column := 0 to Grid^.Columns - 1 do
  begin
    if (Progress <> nil) and (Row > 0) then
      Progress.WaitFor(Row - 1, Column + 2);
    ReconstructMacroblock(Self, Decoder, State, Row, Column);
    if Progress <> nil then
      Progress.Publish(Row, Column + 1);
  end;
  { The last macroblocks' above-right pixels for the next row: the
    last pixel of the last two lines, repeated. }
  with Target.Planes[0] do
    for Line := 14 to 15 do
    begin
      P := Origin + (Row * 16 + Line) * Stride + Width;
      FillChar(P^, 4, P[-1]);
    end;
  for Index := 1 to 2 do
    with Target.Planes[Index] do
      for Line := 6 to 7 do
      begin
        P := Origin + (Row * 8 + Line) * Stride + Width;
        FillChar(P^, 4, P[-1]);
      end;
  if Progress <> nil then
    Progress.Publish(Row, Grid^.Columns + 1);
end;

end.
