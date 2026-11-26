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
  VP9 pictures: three planes of 16-bit samples (whatever the bit depth,
  so that one code path serves 8, 10 and 12 bits), a whole number of
  64x64 superblocks in size so that blocks at the edges can be decoded
  whole, with the frame's motion vectors for the next frame.

  Each plane knows its visible ("crop") size and its size rounded up to
  8 luma pixels, the width intra prediction may read up to.
}
unit Vp9.Pictures;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Media.Frames, Vp9.ModeInfo;

type
  TVp9Plane = record
    Samples: array of Word;
    Stride: LongInt;
    { Allocated, visible, and visible rounded up to 8 luma pixels. }
    Width, Height: LongInt;
    CropWidth, CropHeight: LongInt;
    AlignedWidth, AlignedHeight: LongInt;
    Origin: PWord;
  end;
  PVp9Plane = ^TVp9Plane;

  TVp9Picture = class
  public
    Planes: array[0..2] of TVp9Plane;
    Width, Height: LongInt;
    SubsamplingX, SubsamplingY: LongInt;
    BitDepth: LongInt;
    ColorSpace: LongInt;
    FullRange: Boolean;
    { Reference slots and decoder uses holding the picture. }
    ReferenceCount: LongInt;
    { The frame's motion vectors, one per 8x8 unit. }
    MvReferences: array of TVp9MvReference;
    MiRows, MiColumns: LongInt;
    { (Re)allocates for a frame of Width x Height; keeps the buffers
      when they are big enough. }
    procedure Allocate(NewWidth, NewHeight, NewSubsamplingX, NewSubsamplingY, NewBitDepth: LongInt);
    { Copies the visible picture into Frame. }
    procedure CopyTo(var Frame: TVideoFrame);
  end;

implementation

procedure AllocatePlane(var Plane: TVp9Plane; Width, Height, CropWidth, CropHeight,
  AlignedWidth, AlignedHeight: LongInt);
var
  Needed: PtrInt;
begin
  { A margin right and below for filters that read a little past the
    edge of the last blocks. }
  Plane.Stride := Width + 16;
  Needed := PtrInt(Plane.Stride) * (Height + 16);
  if Length(Plane.Samples) < Needed then
  begin
    Plane.Samples := nil;
    SetLength(Plane.Samples, Needed);
  end;
  Plane.Width := Width;
  Plane.Height := Height;
  Plane.CropWidth := CropWidth;
  Plane.CropHeight := CropHeight;
  Plane.AlignedWidth := AlignedWidth;
  Plane.AlignedHeight := AlignedHeight;
  Plane.Origin := @Plane.Samples[0];
end;

procedure TVp9Picture.Allocate(NewWidth, NewHeight, NewSubsamplingX, NewSubsamplingY, NewBitDepth: LongInt);
var
  SuperblockWidth, SuperblockHeight, Aligned8Width, Aligned8Height, Index: LongInt;
begin
  Width := NewWidth;
  Height := NewHeight;
  SubsamplingX := NewSubsamplingX;
  SubsamplingY := NewSubsamplingY;
  BitDepth := NewBitDepth;
  SuperblockWidth := (NewWidth + 63) and not 63;
  SuperblockHeight := (NewHeight + 63) and not 63;
  Aligned8Width := (NewWidth + 7) and not 7;
  Aligned8Height := (NewHeight + 7) and not 7;
  AllocatePlane(Planes[0], SuperblockWidth, SuperblockHeight, NewWidth, NewHeight, Aligned8Width, Aligned8Height);
  for Index := 1 to 2 do
    AllocatePlane(Planes[Index], SuperblockWidth shr SubsamplingX, SuperblockHeight shr SubsamplingY,
      (NewWidth + SubsamplingX) shr SubsamplingX, (NewHeight + SubsamplingY) shr SubsamplingY,
      Aligned8Width shr SubsamplingX, Aligned8Height shr SubsamplingY);
  MiRows := Aligned8Height shr 3;
  MiColumns := Aligned8Width shr 3;
  if Length(MvReferences) < MiRows * MiColumns then
  begin
    MvReferences := nil;
    SetLength(MvReferences, MiRows * MiColumns);
  end;
end;

procedure TVp9Picture.CopyTo(var Frame: TVideoFrame);
var
  Index, Row, Column, BytesPerSample: LongInt;
  Source: PWord;
  Target: PByte;
begin
  Frame.Width := Width;
  Frame.Height := Height;
  Frame.BitDepth := BitDepth;
  if (SubsamplingX = 0) and (SubsamplingY = 0) then
    Frame.Layout := pl444
  else if (SubsamplingX = 1) and (SubsamplingY = 0) then
    Frame.Layout := pl422
  else
    Frame.Layout := pl420;
  { The colour space code of the header, as ITU-T H.273 codes. }
  case ColorSpace of
    1: begin Frame.MatrixCoefficients := 6; Frame.ColorPrimaries := 6; Frame.TransferCharacteristics := 6; end;
    2: begin Frame.MatrixCoefficients := 1; Frame.ColorPrimaries := 1; Frame.TransferCharacteristics := 1; end;
    3: begin Frame.MatrixCoefficients := 7; Frame.ColorPrimaries := 7; Frame.TransferCharacteristics := 7; end;
    4: begin Frame.MatrixCoefficients := 5; Frame.ColorPrimaries := 5; Frame.TransferCharacteristics := 6; end;
    5: begin Frame.MatrixCoefficients := 9; Frame.ColorPrimaries := 9; Frame.TransferCharacteristics := 14; end;
    7: begin Frame.MatrixCoefficients := 0; Frame.ColorPrimaries := 1; Frame.TransferCharacteristics := 13; end;
  else
    begin Frame.MatrixCoefficients := 2; Frame.ColorPrimaries := 2; Frame.TransferCharacteristics := 2; end;
  end;
  Frame.FullRange := FullRange;
  if BitDepth > 8 then
    BytesPerSample := 2
  else
    BytesPerSample := 1;
  for Index := 0 to 2 do
  begin
    Frame.Planes[Index].Width := Planes[Index].CropWidth;
    Frame.Planes[Index].Height := Planes[Index].CropHeight;
    Frame.Planes[Index].Stride := Planes[Index].CropWidth * BytesPerSample;
    Frame.Planes[Index].Data := nil;
    SetLength(Frame.Planes[Index].Data, Frame.Planes[Index].Stride * Planes[Index].CropHeight);
    for Row := 0 to Planes[Index].CropHeight - 1 do
    begin
      Source := Planes[Index].Origin + Row * Planes[Index].Stride;
      Target := @Frame.Planes[Index].Data[Row * Frame.Planes[Index].Stride];
      if BytesPerSample = 2 then
        Move(Source^, Target^, Planes[Index].CropWidth * 2)
      else
        for Column := 0 to Planes[Index].CropWidth - 1 do
          Target[Column] := Source[Column];
    end;
  end;
end;

end.
