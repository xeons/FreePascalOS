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
  The output process (specification section 7.18): the shown frame's
  samples, cropped to UpscaledWidth by FrameHeight, with film grain
  added when the frame asks for it, as a Media.Frames TVideoFrame
  (bytes for 8-bit streams, little-endian 16-bit words otherwise).
}
unit Av1.Output;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Media.Frames, Av1.SequenceHeader, Av1.FrameHeader, Av1.Picture;

{ The output frame of Picture (w = Width, h = Height samples of luma). }
procedure ProduceOutputFrame(Picture: TPicture; Width, Height: Integer; const Sequence: TSequenceHeader;
  const FilmGrain: TFilmGrainParams; PresentationTime: Int64; out Frame: TVideoFrame);

implementation

uses
  Av1.FilmGrain;

procedure CopyPlane(const Source: TPlane; Width, Height, BitDepth: Integer; out Target: TVideoPlane);
var
  X, Y: Integer;
  SourceRow: PWord;
  TargetRow: PByte;
begin
  Target.Width := Width;
  Target.Height := Height;
  if BitDepth = 8 then
    Target.Stride := Width
  else
    Target.Stride := Width * 2;
  Target.Data := nil;
  SetLength(Target.Data, Target.Stride * Height);
  for Y := 0 to Height - 1 do
  begin
    SourceRow := @Source.Samples[Y * Source.Stride];
    TargetRow := @Target.Data[Y * Target.Stride];
    if BitDepth = 8 then
      for X := 0 to Width - 1 do
        TargetRow[X] := SourceRow[X]
    else
      for X := 0 to Width - 1 do
      begin
        TargetRow[2 * X] := SourceRow[X] and $FF;
        TargetRow[2 * X + 1] := SourceRow[X] shr 8;
      end;
  end;
end;

procedure ProduceOutputFrame(Picture: TPicture; Width, Height: Integer; const Sequence: TSequenceHeader;
  const FilmGrain: TFilmGrainParams; PresentationTime: Int64; out Frame: TVideoFrame);
var
  Source, Grained: TPicture;
  Plane, SubX, SubY: Integer;
begin
  Frame := Default(TVideoFrame);
  Frame.Width := Width;
  Frame.Height := Height;
  Frame.BitDepth := Picture.BitDepth;
  if Picture.NumPlanes = 1 then
    Frame.Layout := plMonochrome
  else if (Picture.SubsamplingX <> 0) and (Picture.SubsamplingY <> 0) then
    Frame.Layout := pl420
  else if Picture.SubsamplingX <> 0 then
    Frame.Layout := pl422
  else
    Frame.Layout := pl444;
  Frame.ColorPrimaries := Sequence.color_primaries;
  Frame.TransferCharacteristics := Sequence.transfer_characteristics;
  Frame.MatrixCoefficients := Sequence.matrix_coefficients;
  Frame.FullRange := Sequence.color_range;
  Frame.PresentationTime := PresentationTime;
  Grained := nil;
  Source := Picture;
  try
    if Sequence.film_grain_params_present and FilmGrain.apply_grain then
    begin
      Grained := TPicture.Create(Width, Height, Picture.SubsamplingX, Picture.SubsamplingY, Picture.NumPlanes,
        Picture.BitDepth, 0);
      ApplyFilmGrain(Picture, Width, Height, Sequence, FilmGrain, Grained);
      Source := Grained;
    end;
    for Plane := 0 to Picture.NumPlanes - 1 do
    begin
      if Plane = 0 then
      begin
        SubX := 0;
        SubY := 0;
      end
      else
      begin
        SubX := Picture.SubsamplingX;
        SubY := Picture.SubsamplingY;
      end;
      CopyPlane(Source.Planes[Plane], (Width + SubX) shr SubX, (Height + SubY) shr SubY, Picture.BitDepth,
        Frame.Planes[Plane]);
    end;
  finally
    Grained.Free;
  end;
end;

end.
