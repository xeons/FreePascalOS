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
  The constrained directional enhancement filter (specification section
  7.15): each 8x8 block of a 64x64 unit with a cdef_idx, unless all its
  4x4 blocks are skipped, has its direction and variance measured on the
  luma samples and is filtered along that direction, reading CurrFrame
  and writing CdefFrame (which starts as a copy of CurrFrame). Samples
  outside the frame's mode info area are unavailable to the filter.
  CdefRows filters a range of 8x8 block rows, for threads.
}
unit Av1.Cdef;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.Picture;

{ Whether CDEF can change anything in the frame. }
function CdefEnabled(Frame: TFrameContext): Boolean;
{ Filters the 8x8 blocks whose mode info row r (even) is in [ RowStart, RowEnd ),
  from Frame.CurrFrame into Frame.CdefFrame (already a copy of CurrFrame). }
procedure CdefRows(Frame: TFrameContext; RowStart, RowEnd: Integer);

implementation

function CdefEnabled(Frame: TFrameContext): Boolean;
begin
  Result := Frame.Sequence.enable_cdef and not Frame.Header.CodedLossless and not Frame.Header.allow_intrabc;
end;

{ The CDEF direction process (section 7.15.2). }
procedure CdefDirection(Frame: TFrameContext; R, C: Integer; out YDir, Variance: Integer);
var
  Cost: array[0..7] of Int64;
  Partial: array[0..7, 0..14] of Integer;
  I, J, X, X0, Y0, Shift: Integer;
  BestCost: Int64;
  Source: PWord;
  Stride: Integer;
begin
  FillChar(Cost, SizeOf(Cost), 0);
  FillChar(Partial, SizeOf(Partial), 0);
  BestCost := 0;
  YDir := 0;
  X0 := C shl MI_SIZE_LOG2;
  Y0 := R shl MI_SIZE_LOG2;
  Shift := Frame.Sequence.BitDepth - 8;
  Stride := Frame.CurrFrame.Planes[0].Stride;
  for I := 0 to 7 do
  begin
    Source := @Frame.CurrFrame.Planes[0].Samples[(Y0 + I) * Stride + X0];
    for J := 0 to 7 do
    begin
      X := (Source[J] shr Shift) - 128;
      Inc(Partial[0][I + J], X);
      Inc(Partial[1][I + J div 2], X);
      Inc(Partial[2][I], X);
      Inc(Partial[3][3 + I - J div 2], X);
      Inc(Partial[4][7 + I - J], X);
      Inc(Partial[5][3 - I div 2 + J], X);
      Inc(Partial[6][J], X);
      Inc(Partial[7][I div 2 + J], X);
    end;
  end;
  for I := 0 to 7 do
  begin
    Inc(Cost[2], Int64(Partial[2][I]) * Partial[2][I]);
    Inc(Cost[6], Int64(Partial[6][I]) * Partial[6][I]);
  end;
  Cost[2] := Cost[2] * Div_Table[8];
  Cost[6] := Cost[6] * Div_Table[8];
  for I := 0 to 6 do
  begin
    Inc(Cost[0], (Int64(Partial[0][I]) * Partial[0][I] + Int64(Partial[0][14 - I]) * Partial[0][14 - I]) *
      Div_Table[I + 1]);
    Inc(Cost[4], (Int64(Partial[4][I]) * Partial[4][I] + Int64(Partial[4][14 - I]) * Partial[4][14 - I]) *
      Div_Table[I + 1]);
  end;
  Inc(Cost[0], Int64(Partial[0][7]) * Partial[0][7] * Div_Table[8]);
  Inc(Cost[4], Int64(Partial[4][7]) * Partial[4][7] * Div_Table[8]);
  I := 1;
  while I < 8 do
  begin
    for J := 0 to 4 do
      Inc(Cost[I], Int64(Partial[I][3 + J]) * Partial[I][3 + J]);
    Cost[I] := Cost[I] * Div_Table[8];
    for J := 0 to 2 do
      Inc(Cost[I], (Int64(Partial[I][J]) * Partial[I][J] + Int64(Partial[I][10 - J]) * Partial[I][10 - J]) *
        Div_Table[2 * J + 2]);
    Inc(I, 2);
  end;
  for I := 0 to 7 do
    if Cost[I] > BestCost then
    begin
      BestCost := Cost[I];
      YDir := I;
    end;
  Variance := Integer((BestCost - Cost[(YDir + 4) and 7]) shr 10);
end;

function Constrain(Difference, Threshold, DampingAdjust: Integer): Integer; inline;
var
  Magnitude, Limit: Integer;
begin
  if Threshold = 0 then
    Exit(0);
  Magnitude := Abs(Difference);
  Limit := Threshold - (Magnitude shr DampingAdjust);
  if Limit < 0 then
    Limit := 0;
  if Limit > Magnitude then
    Limit := Magnitude;
  if Difference < 0 then
    Result := -Limit
  else
    Result := Limit;
end;

{ The CDEF filter process (section 7.15.3) for one plane of the block at r, c. }
procedure CdefFilter(Frame: TFrameContext; Plane, R, C, PriStr, SecStr, Damping, Dir: Integer);
var
  SubX, SubY, X0, Y0, W, H, I, J, K, Sign, DirOffset, CoeffShift: Integer;
  PlaneWidth, PlaneHeight, Stride: Integer;
  Sum, X, Maximum, Minimum, Sample, SampleX, SampleY, CandidateDir: Integer;
  PriTap, SecTap: array[0..1] of Integer;
  PriDampingAdjust, SecDampingAdjust: Integer;
  Source, Target: PWord;
  Index: Integer;
begin
  if Plane > 0 then
  begin
    SubX := Frame.Sequence.subsampling_x;
    SubY := Frame.Sequence.subsampling_y;
  end
  else
  begin
    SubX := 0;
    SubY := 0;
  end;
  CoeffShift := Frame.Sequence.BitDepth - 8;
  X0 := (C * MI_SIZE) shr SubX;
  Y0 := (R * MI_SIZE) shr SubY;
  W := 8 shr SubX;
  H := 8 shr SubY;
  { is_inside_filter_region: the mode info area of the frame. }
  PlaneWidth := (Frame.Header.MiCols * MI_SIZE) shr SubX;
  PlaneHeight := (Frame.Header.MiRows * MI_SIZE) shr SubY;
  Stride := Frame.CurrFrame.Planes[Plane].Stride;
  Source := @Frame.CurrFrame.Planes[Plane].Samples[0];
  Target := @Frame.CdefFrame.Planes[Plane].Samples[0];
  PriTap[0] := Cdef_Pri_Taps[(PriStr shr CoeffShift) and 1][0];
  PriTap[1] := Cdef_Pri_Taps[(PriStr shr CoeffShift) and 1][1];
  SecTap[0] := Cdef_Sec_Taps[(PriStr shr CoeffShift) and 1][0];
  SecTap[1] := Cdef_Sec_Taps[(PriStr shr CoeffShift) and 1][1];
  PriDampingAdjust := 0;
  SecDampingAdjust := 0;
  if PriStr <> 0 then
    PriDampingAdjust := Max(0, Damping - FloorLog2(PriStr));
  if SecStr <> 0 then
    SecDampingAdjust := Max(0, Damping - FloorLog2(SecStr));
  for I := 0 to H - 1 do
    for J := 0 to W - 1 do
    begin
      Sum := 0;
      X := Source[(Y0 + I) * Stride + X0 + J];
      Maximum := X;
      Minimum := X;
      for K := 0 to 1 do
      begin
        Sign := -1;
        while Sign <= 1 do
        begin
          { primary taps along dir }
          SampleY := Y0 + I + Sign * Cdef_Directions[Dir][K][0];
          SampleX := X0 + J + Sign * Cdef_Directions[Dir][K][1];
          if (SampleX >= 0) and (SampleX < PlaneWidth) and (SampleY >= 0) and (SampleY < PlaneHeight) then
          begin
            Sample := Source[SampleY * Stride + SampleX];
            Inc(Sum, PriTap[K] * Constrain(Sample - X, PriStr, PriDampingAdjust));
            if Sample > Maximum then
              Maximum := Sample;
            if Sample < Minimum then
              Minimum := Sample;
          end;
          DirOffset := -2;
          while DirOffset <= 2 do
          begin
            CandidateDir := (Dir + DirOffset) and 7;
            SampleY := Y0 + I + Sign * Cdef_Directions[CandidateDir][K][0];
            SampleX := X0 + J + Sign * Cdef_Directions[CandidateDir][K][1];
            if (SampleX >= 0) and (SampleX < PlaneWidth) and (SampleY >= 0) and (SampleY < PlaneHeight) then
            begin
              Sample := Source[SampleY * Stride + SampleX];
              Inc(Sum, SecTap[K] * Constrain(Sample - X, SecStr, SecDampingAdjust));
              if Sample > Maximum then
                Maximum := Sample;
              if Sample < Minimum then
                Minimum := Sample;
            end;
            Inc(DirOffset, 4);
          end;
          Inc(Sign, 2);
        end;
      end;
      Index := (Y0 + I) * Stride + X0 + J;
      Target[Index] := Clip3(Minimum, Maximum, X + SarLongint(8 + Sum - Ord(Sum < 0), 4));
    end;
end;

{ The CDEF block process (section 7.15.1) after the copy, for an index other than -1. }
procedure CdefBlock(Frame: TFrameContext; R, C, Idx: Integer);
var
  CoeffShift, YDir, Variance, PriStr, SecStr, Dir, VarStr, Damping: Integer;
  Skip: Boolean;
begin
  CoeffShift := Frame.Sequence.BitDepth - 8;
  Skip := Frame.Block(R, C)^.Skip and Frame.Block(R + 1, C)^.Skip and Frame.Block(R, C + 1)^.Skip and
    Frame.Block(R + 1, C + 1)^.Skip;
  if Skip then
    Exit;
  CdefDirection(Frame, R, C, YDir, Variance);
  PriStr := Frame.Header.cdef_y_pri_strength[Idx] shl CoeffShift;
  SecStr := Frame.Header.cdef_y_sec_strength[Idx] shl CoeffShift;
  if PriStr = 0 then
    Dir := 0
  else
    Dir := YDir;
  if (Variance shr 6) <> 0 then
    VarStr := Min(FloorLog2(Variance shr 6), 12)
  else
    VarStr := 0;
  if Variance <> 0 then
    PriStr := (PriStr * (4 + VarStr) + 8) shr 4
  else
    PriStr := 0;
  Damping := Frame.Header.CdefDamping + CoeffShift;
  CdefFilter(Frame, 0, R, C, PriStr, SecStr, Damping, Dir);
  if Frame.Sequence.NumPlanes = 1 then
    Exit;
  PriStr := Frame.Header.cdef_uv_pri_strength[Idx] shl CoeffShift;
  SecStr := Frame.Header.cdef_uv_sec_strength[Idx] shl CoeffShift;
  if PriStr = 0 then
    Dir := 0
  else
    Dir := Cdef_Uv_Dir[Frame.Sequence.subsampling_x][Frame.Sequence.subsampling_y][YDir];
  Damping := Frame.Header.CdefDamping + CoeffShift - 1;
  CdefFilter(Frame, 1, R, C, PriStr, SecStr, Damping, Dir);
  CdefFilter(Frame, 2, R, C, PriStr, SecStr, Damping, Dir);
end;

procedure CdefRows(Frame: TFrameContext; RowStart, RowEnd: Integer);
var
  R, C, Idx: Integer;
begin
  R := RowStart and not 1;
  while (R < RowEnd) and (R < Frame.Header.MiRows) do
  begin
    C := 0;
    while C < Frame.Header.MiCols do
    begin
      Idx := Frame.CdefIdx[Frame.MiIndex(R and not 15, C and not 15)];
      if Idx <> -1 then
        CdefBlock(Frame, R, C, Idx);
      Inc(C, 2);
    end;
    Inc(R, 2);
  end;
end;

end.
