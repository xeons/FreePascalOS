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
  Decoded media: the frame records every decoder produces.

  A video frame is planar Y'CbCr (or monochrome) with 8, 10 or 12-bit
  samples; an audio buffer holds interleaved floats between -1 and 1, its
  channels in the WAVE / SMPTE order (front left, front right, centre,
  LFE, back left, back right, side left, side right).

  This is the contract between libmedia and the video decoders (libvideo,
  libav1); the record layouts must not change without changing them too.
  ConvertFrameToBgra turns a video frame into 32-bit BGRA pixels (the
  work is done by Media.ColorConversion).
}
unit Media.Frames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TPixelLayout = (pl420, pl422, pl444, plMonochrome);

  TVideoPlane = record
    { Samples: 1 byte each when BitDepth = 8, else 2 bytes little-endian. }
    Data: TBytes;
    { Bytes per row. }
    Stride: Integer;
    Width, Height: Integer;
  end;

  TVideoFrame = record
    { The display size. }
    Width, Height: Integer;
    { 8, 10 or 12. }
    BitDepth: Integer;
    Layout: TPixelLayout;
    { Y, U (Cb), V (Cr). }
    Planes: array[0..2] of TVideoPlane;
    { ITU-T H.273 codes. }
    ColorPrimaries, TransferCharacteristics, MatrixCoefficients: Integer;
    FullRange: Boolean;
    { In the track's TimeBase units. }
    PresentationTime: Int64;
  end;

  TAudioBuffer = record
    SampleRate: Integer;
    Channels: Integer;
    { Interleaved, -1..1. }
    Samples: array of Single;
    PresentationTime: Int64;
  end;

const
  { ITU-T H.273 matrix coefficients. }
  MatrixIdentity = 0;
  MatrixBt709 = 1;
  MatrixUnspecified = 2;
  MatrixFcc = 4;
  MatrixBt470bg = 5;
  MatrixSmpte170m = 6;
  MatrixSmpte240m = 7;
  MatrixBt2020NonConstant = 9;
  MatrixBt2020Constant = 10;

  { ITU-T H.273 colour primaries and transfer characteristics. }
  PrimariesBt709 = 1;
  PrimariesUnspecified = 2;
  TransferBt709 = 1;
  TransferUnspecified = 2;

  { Audio channel positions, in the order TAudioBuffer keeps them. }
  ChannelFrontLeft = 0;
  ChannelFrontRight = 1;
  ChannelFrontCentre = 2;
  ChannelLowFrequency = 3;
  ChannelBackLeft = 4;
  ChannelBackRight = 5;
  ChannelSideLeft = 6;
  ChannelSideRight = 7;

{ The number of sample frames (samples per channel) in Buffer. }
function AudioFrameCount(const Buffer: TAudioBuffer): Integer;
{ The chroma plane size of a luma size in Layout. }
procedure ChromaSize(Layout: TPixelLayout; LumaWidth, LumaHeight: Integer; out ChromaWidth, ChromaHeight: Integer);
{ Allocates Frame's planes for Width x Height in Layout and BitDepth
  (strides are the row size rounded up to 16 bytes); the colour fields
  are set to unspecified, limited range. }
procedure AllocateVideoFrame(out Frame: TVideoFrame; Width, Height, BitDepth: Integer; Layout: TPixelLayout);
{ A plane's sample at X, Y (either sample size). }
function PlaneSample(const Plane: TVideoPlane; BitDepth, X, Y: Integer): Integer; inline;
{ Writes Frame's Width x Height pixels as B, G, R, A (255) bytes at
  Target, rows TargetStride bytes apart: the BT.601, BT.709, BT.2020,
  SMPTE 240M, FCC or identity matrix its MatrixCoefficients names
  (unspecified: BT.709 above 576 lines, else BT.601), limited or full
  range, 10 and 12-bit samples brought down to 8. }
procedure ConvertFrameToBgra(const Frame: TVideoFrame; Target: PByte; TargetStride: Integer);

implementation

uses
  Media.ColorConversion;

function AudioFrameCount(const Buffer: TAudioBuffer): Integer;
begin
  if Buffer.Channels <= 0 then
    Result := 0
  else
    Result := Length(Buffer.Samples) div Buffer.Channels;
end;

procedure ChromaSize(Layout: TPixelLayout; LumaWidth, LumaHeight: Integer; out ChromaWidth, ChromaHeight: Integer);
begin
  case Layout of
    pl420:
      begin
        ChromaWidth := (LumaWidth + 1) div 2;
        ChromaHeight := (LumaHeight + 1) div 2;
      end;
    pl422:
      begin
        ChromaWidth := (LumaWidth + 1) div 2;
        ChromaHeight := LumaHeight;
      end;
    pl444:
      begin
        ChromaWidth := LumaWidth;
        ChromaHeight := LumaHeight;
      end;
  else
    begin
      ChromaWidth := 0;
      ChromaHeight := 0;
    end;
  end;
end;

procedure AllocatePlane(out Plane: TVideoPlane; Width, Height, BytesPerSample: Integer);
begin
  Plane.Width := Width;
  Plane.Height := Height;
  Plane.Stride := (Width * BytesPerSample + 15) and not 15;
  Plane.Data := nil;
  SetLength(Plane.Data, Plane.Stride * Height);
end;

procedure AllocateVideoFrame(out Frame: TVideoFrame; Width, Height, BitDepth: Integer; Layout: TPixelLayout);
var
  BytesPerSample, ChromaWidth, ChromaHeight, PlaneIndex: Integer;
begin
  Frame := Default(TVideoFrame);
  Frame.Width := Width;
  Frame.Height := Height;
  Frame.BitDepth := BitDepth;
  Frame.Layout := Layout;
  Frame.ColorPrimaries := PrimariesUnspecified;
  Frame.TransferCharacteristics := TransferUnspecified;
  Frame.MatrixCoefficients := MatrixUnspecified;
  Frame.FullRange := False;
  if BitDepth > 8 then
    BytesPerSample := 2
  else
    BytesPerSample := 1;
  AllocatePlane(Frame.Planes[0], Width, Height, BytesPerSample);
  ChromaSize(Layout, Width, Height, ChromaWidth, ChromaHeight);
  for PlaneIndex := 1 to 2 do
    if Layout = plMonochrome then
      Frame.Planes[PlaneIndex] := Default(TVideoPlane)
    else
      AllocatePlane(Frame.Planes[PlaneIndex], ChromaWidth, ChromaHeight, BytesPerSample);
end;

function PlaneSample(const Plane: TVideoPlane; BitDepth, X, Y: Integer): Integer;
var
  Offset: Integer;
begin
  if BitDepth > 8 then
  begin
    Offset := Y * Plane.Stride + X * 2;
    Result := Plane.Data[Offset] or (Plane.Data[Offset + 1] shl 8);
  end
  else
    Result := Plane.Data[Y * Plane.Stride + X];
end;

procedure ConvertFrameToBgra(const Frame: TVideoFrame; Target: PByte; TargetStride: Integer);
begin
  ConvertYuvFrameToBgra(Frame, Target, TargetStride);
end;

end.
