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
  The reference frames (specification section 7.20): what the reference
  frame update process saves of a decoded frame (its samples, sizes,
  order hints, motion field, segmentation map, CDFs, global motion,
  loop filter deltas, segmentation features and film grain parameters).

  A decoded frame is one TReferenceFrame shared by every slot its
  refresh_frame_flags name; the slots count their references to it.
}
unit Av1.References;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.CdfContext, Av1.FrameHeader, Av1.Picture;

type
  TMotionVector = array[0..1] of Integer;   { [ 0 ] row, [ 1 ] column, in 1/8 samples }
  PMotionVector = ^TMotionVector;

  TReferenceFrame = class
  private
    FReferences: Integer;
  public
    Picture: TPicture;                       { FrameStore: the frame after loop restoration }
    RefFrameId: Integer;
    RefUpscaledWidth, RefFrameWidth, RefFrameHeight: Integer;
    RefRenderWidth, RefRenderHeight: Integer;
    RefMiCols, RefMiRows: Integer;
    RefFrameType: Integer;
    RefSubsamplingX, RefSubsamplingY: Integer;
    RefBitDepth: Integer;
    RefOrderHint: Integer;
    RefShowableFrame: Boolean;
    SavedOrderHints: array[0..TOTAL_REFS_PER_FRAME - 1] of Integer;
    SavedRefFrames: array of ShortInt;       { MfRefFrames, RefMiRows by RefMiCols }
    SavedMvs: array of TMotionVector;        { MfMvs }
    SavedGmParams: TGlobalMotionParams;
    SavedSegmentIds: array of Byte;
    SavedCdfs: TCdfContext;
    SavedFilmGrain: TFilmGrainParams;
    SavedLoopFilterDeltas: TLoopFilterDeltas;
    SavedSegmentation: TSegmentationFeatures;
    constructor Create;
    destructor Destroy; override;
    function Acquire: TReferenceFrame;
    procedure Release;
  end;

  { The eight reference slots and their validity. }
  TReferenceSlots = record
    Frames: array[0..NUM_REF_FRAMES - 1] of TReferenceFrame;
    RefValid: array[0..NUM_REF_FRAMES - 1] of Boolean;
    RefOrderHint: array[0..NUM_REF_FRAMES - 1] of Integer;
    RefFrameId: array[0..NUM_REF_FRAMES - 1] of Integer;
  end;
  PReferenceSlots = ^TReferenceSlots;

procedure ReleaseReferenceSlots(var Slots: TReferenceSlots);
procedure AssignReferenceSlot(var Slots: TReferenceSlots; Index: Integer; Frame: TReferenceFrame);

implementation

constructor TReferenceFrame.Create;
begin
  inherited Create;
  FReferences := 1;
end;

destructor TReferenceFrame.Destroy;
begin
  Picture.Free;
  inherited Destroy;
end;

function TReferenceFrame.Acquire: TReferenceFrame;
begin
  InterLockedIncrement(FReferences);
  Result := Self;
end;

procedure TReferenceFrame.Release;
begin
  if InterLockedDecrement(FReferences) = 0 then
    Free;
end;

procedure ReleaseReferenceSlots(var Slots: TReferenceSlots);
var
  Index: Integer;
begin
  for Index := 0 to NUM_REF_FRAMES - 1 do
  begin
    if Slots.Frames[Index] <> nil then
      Slots.Frames[Index].Release;
    Slots.Frames[Index] := nil;
    Slots.RefValid[Index] := False;
  end;
end;

procedure AssignReferenceSlot(var Slots: TReferenceSlots; Index: Integer; Frame: TReferenceFrame);
begin
  if Slots.Frames[Index] = Frame then
    Exit;
  if Frame <> nil then
    Frame.Acquire;
  if Slots.Frames[Index] <> nil then
    Slots.Frames[Index].Release;
  Slots.Frames[Index] := Frame;
end;

end.
