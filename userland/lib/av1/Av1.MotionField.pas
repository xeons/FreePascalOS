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
  The motion field (specification sections 7.9 and 7.19).

  MotionFieldEstimation projects the motion vectors the reference frames
  saved onto the current frame, one field per reference frame on an 8x8
  grid (Frame.MotionFieldMvs; both components -32768 where nothing was
  projected). StoreMotionField prepares the vectors the current frame
  saves for later frames (Frame.MfRefFrames, Frame.MfMvs).

  The reference frames' SavedRefFrames and SavedMvs are RefMiRows by
  RefMiCols, RefMiCols per row.
}
unit Av1.MotionField;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.References, Av1.FrameContext;

procedure MotionFieldEstimation(Frame: TFrameContext);
procedure StoreMotionField(Frame: TFrameContext);

implementation

{ The get MV projection process (7.9.3). }
function GetMvProjection(const Vector: TMotionVector; Numerator, Denominator: Integer): TMotionVector;
var
  ClippedDenominator, ClippedNumerator, Component: Integer;
  Scaled: Int64;
begin
  ClippedDenominator := Min(MAX_FRAME_DISTANCE, Denominator);
  ClippedNumerator := Clip3(-MAX_FRAME_DISTANCE, MAX_FRAME_DISTANCE, Numerator);
  for Component := 0 to 1 do
  begin
    Scaled := Round2SignedInt64(Int64(Vector[Component]) * ClippedNumerator * Div_Mult[ClippedDenominator], 14);
    if Scaled < -(1 shl 14) + 1 then
      Scaled := -(1 shl 14) + 1
    else if Scaled > (1 shl 14) - 1 then
      Scaled := (1 shl 14) - 1;
    Result[Component] := Scaled;
  end;
end;

{ project( ) of the get block position process (7.9.4). }
function Project(Position8, Delta, DestinationSign, Maximum8, MaximumOffset8: Integer;
  var PositionValid: Boolean): Integer;
var
  Base8, Offset8: Integer;
begin
  Base8 := (Position8 shr 3) shl 3;
  if Delta >= 0 then
    Offset8 := Delta shr (3 + 1 + MI_SIZE_LOG2)
  else
    Offset8 := -((-Delta) shr (3 + 1 + MI_SIZE_LOG2));
  Inc(Position8, DestinationSign * Offset8);
  if (Position8 < 0) or (Position8 >= Maximum8) or (Position8 < Base8 - MaximumOffset8) or
    (Position8 >= Base8 + 8 + MaximumOffset8) then
    PositionValid := False;
  Result := Position8;
end;

{ The projection process (7.9.2); False when the source frame cannot be used. }
function ProjectReference(Frame: TFrameContext; Source, DestinationSign: Integer): Boolean;
var
  Reference: TReferenceFrame;
  Width8, Height8, X8, Y8, Row, Col, SourceRef, RefToCur, RefOffset, RefToDst, Destination: Integer;
  PositionY8, PositionX8: Integer;
  PositionValid: Boolean;
  Vector, Projected: TMotionVector;
begin
  Result := False;
  Reference := Frame.ReferenceFrames[Source];
  if Reference = nil then
    Exit;
  Width8 := Frame.Header.MiCols shr 1;
  Height8 := Frame.Header.MiRows shr 1;
  if (Reference.RefMiRows <> Frame.Header.MiRows) or (Reference.RefMiCols <> Frame.Header.MiCols) or
    (Reference.RefFrameType = INTRA_ONLY_FRAME) or (Reference.RefFrameType = KEY_FRAME) then
    Exit;
  RefToCur := Frame.GetRelativeDist(Frame.Header.OrderHints[Source], Frame.Header.OrderHint);
  for Y8 := 0 to Height8 - 1 do
    for X8 := 0 to Width8 - 1 do
    begin
      Row := 2 * Y8 + 1;
      Col := 2 * X8 + 1;
      SourceRef := Reference.SavedRefFrames[Row * Reference.RefMiCols + Col];
      if SourceRef <= INTRA_FRAME then
        Continue;
      RefOffset := Frame.GetRelativeDist(Frame.Header.OrderHints[Source], Reference.SavedOrderHints[SourceRef]);
      PositionValid := (Abs(RefToCur) <= MAX_FRAME_DISTANCE) and (Abs(RefOffset) <= MAX_FRAME_DISTANCE) and
        (RefOffset > 0);
      if not PositionValid then
        Continue;
      Vector := Reference.SavedMvs[Row * Reference.RefMiCols + Col];
      Projected := GetMvProjection(Vector, RefToCur * DestinationSign, RefOffset);
      PositionY8 := Project(Y8, Projected[0], DestinationSign, Height8, MAX_OFFSET_HEIGHT, PositionValid);
      PositionX8 := Project(X8, Projected[1], DestinationSign, Width8, MAX_OFFSET_WIDTH, PositionValid);
      if not PositionValid then
        Continue;
      for Destination := LAST_FRAME to ALTREF_FRAME do
      begin
        RefToDst := Frame.GetRelativeDist(Frame.Header.OrderHint, Frame.Header.OrderHints[Destination]);
        Frame.MotionFieldMvs[Destination][PositionY8 * Frame.MotionFieldStride + PositionX8] :=
          GetMvProjection(Vector, RefToDst, RefOffset);
      end;
    end;
  Result := True;
end;

procedure MotionFieldEstimation(Frame: TFrameContext);
var
  Reference, Width8, Height8, X8, Y8, RefStamp, LastIndex: Integer;
  Invalid: TMotionVector;
  Last: TReferenceFrame;
begin
  Width8 := Frame.Header.MiCols shr 1;
  Height8 := Frame.Header.MiRows shr 1;
  Invalid[0] := InvalidMotionVector;
  Invalid[1] := InvalidMotionVector;
  for Reference := LAST_FRAME to ALTREF_FRAME do
    for Y8 := 0 to Height8 - 1 do
      for X8 := 0 to Width8 - 1 do
        Frame.MotionFieldMvs[Reference][Y8 * Frame.MotionFieldStride + X8] := Invalid;
  LastIndex := LAST_FRAME;
  Last := Frame.ReferenceFrames[LastIndex];
  if (Last <> nil) and (Last.SavedOrderHints[ALTREF_FRAME] <> Frame.Header.OrderHints[GOLDEN_FRAME]) then
    ProjectReference(Frame, LAST_FRAME, -1);
  RefStamp := MFMV_STACK_SIZE - 2;
  if Frame.GetRelativeDist(Frame.Header.OrderHints[BWDREF_FRAME], Frame.Header.OrderHint) > 0 then
    if ProjectReference(Frame, BWDREF_FRAME, 1) then
      Dec(RefStamp);
  if Frame.GetRelativeDist(Frame.Header.OrderHints[ALTREF2_FRAME], Frame.Header.OrderHint) > 0 then
    if ProjectReference(Frame, ALTREF2_FRAME, 1) then
      Dec(RefStamp);
  if (Frame.GetRelativeDist(Frame.Header.OrderHints[ALTREF_FRAME], Frame.Header.OrderHint) > 0) and
    (RefStamp >= 0) then
    if ProjectReference(Frame, ALTREF_FRAME, 1) then
      Dec(RefStamp);
  if RefStamp >= 0 then
    ProjectReference(Frame, LAST2_FRAME, -1);
end;

procedure StoreMotionField(Frame: TFrameContext);
var
  Row, Col, List, Reference, Distance, Index: Integer;
  Info: PBlockInfo;
begin
  for Row := 0 to Frame.Header.MiRows - 1 do
    for Col := 0 to Frame.Header.MiCols - 1 do
    begin
      Index := Frame.MiIndex(Row, Col);
      Frame.MfRefFrames[Index] := NONE;
      Frame.MfMvs[Index][0] := 0;
      Frame.MfMvs[Index][1] := 0;
      Info := @Frame.Blocks[Index];
      for List := 0 to 1 do
      begin
        Reference := Info^.RefFrame[List];
        if Reference > INTRA_FRAME then
        begin
          { RefOrderHint[ ref_frame_idx[ r - LAST_FRAME ] ] is OrderHints[ r ]. }
          Distance := Frame.GetRelativeDist(Frame.Header.OrderHints[Reference], Frame.Header.OrderHint);
          if Distance < 0 then
            if (Abs(Info^.Mv[List][0]) <= REFMVS_LIMIT) and (Abs(Info^.Mv[List][1]) <= REFMVS_LIMIT) then
            begin
              Frame.MfRefFrames[Index] := Reference;
              Frame.MfMvs[Index] := Info^.Mv[List];
            end;
        end;
      end;
    end;
end;

end.
