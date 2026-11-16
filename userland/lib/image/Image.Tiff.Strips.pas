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
  A TIFF page's strips or tiles (not JPEG) put together into planes of
  samples as they are stored, before they become colours.

  Samples are counted in units: a unit is one pixel's samples, except
  for YCbCr subsampled H x V, where a unit is a block of H x V luma
  samples followed by one Cb and one Cr (and a "line" of units covers V
  lines of pixels). A plane holds every line of units of the picture,
  each line starting on a byte; with separate planes there is one per
  sample, each unit one sample.

  Each chunk is decompressed (Image.Tiff.Decompression), the predictor
  (horizontal, or floating point: Image.Tiff.FloatSamples) undone on
  its own lines, and its lines copied into the planes at the
  chunk's place: strips one under the other, tiles side by side (a tile
  is a multiple of 16 pixels wide, so it starts on a byte; the parts of
  tiles beyond the picture are dropped).
}
unit Image.Tiff.Strips;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Tiff.Tags,
  Image.Tiff.Pages;

type
  TTiffPlanes = record
    UnitWidth: LongInt;
    UnitHeight: LongInt;
    Subsampled: Boolean;
    PlaneCount: LongInt;
    BitsPerUnit: LongInt;
    UnitsAcross: LongInt;
    UnitLines: LongInt;
    LineBytes: PtrInt;
    Planes: array of TBytes;
    BigEndian: Boolean;
  end;

{ Every strip or tile of Page decompressed into planes. }
function ReadTiffPlanes(const Data: TBytes; constref Page: TTiffPage; BigEndian: Boolean): TTiffPlanes;

implementation

uses
  Image.Tiff.Decompression,
  Image.Tiff.Predictor,
  Image.Tiff.FloatSamples;

const
  { The most bytes the planes, or one chunk, may take. }
  MaximumPlaneBytes = Int64(1) shl 31;
  MaximumChunkBytes = Int64(1) shl 28;

procedure Unsupported(const Detail: string);
begin
  RaiseImageError(ImageErrorUnsupported, 'TIFF ' + Detail);
end;

function DivideRoundingUp(Value, Divisor: Int64): Int64;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

procedure WorkOutGeometry(constref Page: TTiffPage; var Planes: TTiffPlanes);
var
  Total: Int64;
begin
  Planes.Subsampled := (Page.Photometric = TiffPhotometricYCbCr) and
    ((Page.SubsamplingHorizontal > 1) or (Page.SubsamplingVertical > 1));
  Planes.PlaneCount := TiffPlaneCount(Page);
  if Planes.Subsampled then
  begin
    if Page.PlanarConfiguration = TiffPlanarSeparate then
      Unsupported('subsampled YCbCr in separate planes');
    if Page.SamplesPerPixel <> 3 then
      Unsupported('subsampled YCbCr with extra samples');
    Planes.UnitWidth := Page.SubsamplingHorizontal;
    Planes.UnitHeight := Page.SubsamplingVertical;
    Planes.BitsPerUnit := (Planes.UnitWidth * Planes.UnitHeight + 2) * Page.BitsPerSample;
  end
  else
  begin
    Planes.UnitWidth := 1;
    Planes.UnitHeight := 1;
    if Planes.PlaneCount = 1 then
      Planes.BitsPerUnit := Page.SamplesPerPixel * Page.BitsPerSample
    else
      Planes.BitsPerUnit := Page.BitsPerSample;
  end;
  Planes.UnitsAcross := DivideRoundingUp(Page.Width, Planes.UnitWidth);
  Planes.UnitLines := DivideRoundingUp(Page.Height, Planes.UnitHeight);
  Planes.LineBytes := DivideRoundingUp(Int64(Planes.UnitsAcross) * Planes.BitsPerUnit, 8);
  Total := Int64(Planes.LineBytes) * Planes.UnitLines * Planes.PlaneCount;
  if Total > MaximumPlaneBytes then
    RaiseImageError(ImageErrorTooLarge, 'TIFF samples');
  if Page.Tiled then
  begin
    if (Page.ChunkWidth mod Planes.UnitWidth <> 0) or (Page.ChunkHeight mod Planes.UnitHeight <> 0) then
      Unsupported('tiles not a whole number of subsampling blocks');
    if (Int64(Page.ChunkWidth div Planes.UnitWidth) * Planes.BitsPerUnit) mod 8 <> 0 then
      Unsupported('tiles not a whole number of bytes wide');
  end
  else if (Page.ChunkHeight mod Planes.UnitHeight <> 0) and (Page.ChunksDown > 1) then
    Unsupported('strips not a whole number of subsampling blocks');
end;

procedure CheckPredictor(constref Page: TTiffPage; constref Planes: TTiffPlanes);
begin
  case Page.Predictor of
    TiffPredictorNone:
      ;
    TiffPredictorHorizontal:
      if Planes.Subsampled or ((Page.BitsPerSample <> 8) and (Page.BitsPerSample <> 16)) then
        Unsupported('horizontal predictor on these samples');
    TiffPredictorFloatingPoint:
      if Planes.Subsampled or (Page.SampleFormat <> TiffSampleFormatFloat) then
        Unsupported('floating point predictor on samples that are not floating point');
  else
    RaiseImageError(ImageErrorMalformed, 'TIFF predictor');
  end;
end;

procedure ReadChunk(const Data: TBytes; constref Page: TTiffPage; var Planes: TTiffPlanes; Index: LongInt);
var
  ChunksPerPlane: LongInt;
  Plane: LongInt;
  WithinPlane: LongInt;
  Left: LongInt;
  Top: LongInt;
  ChunkUnitsAcross: LongInt;
  ChunkUnitLines: LongInt;
  ChunkLineBytes: PtrInt;
  Rows: LongInt;
  Expected: Int64;
  Bytes: TBytes;
  SamplesPerUnit: LongInt;
  FirstLine: LongInt;
  ByteOffset: PtrInt;
  CopyCount: PtrInt;
  Line: LongInt;
begin
  ChunksPerPlane := Page.ChunksAcross * Page.ChunksDown;
  Plane := Index div ChunksPerPlane;
  WithinPlane := Index mod ChunksPerPlane;
  Left := (WithinPlane mod Page.ChunksAcross) * Page.ChunkWidth;
  Top := (WithinPlane div Page.ChunksAcross) * Page.ChunkHeight;
  if Page.Tiled then
  begin
    ChunkUnitsAcross := Page.ChunkWidth div Planes.UnitWidth;
    ChunkUnitLines := Page.ChunkHeight div Planes.UnitHeight;
  end
  else
  begin
    ChunkUnitsAcross := Planes.UnitsAcross;
    Rows := Page.Height - Top;
    if Rows > Page.ChunkHeight then
      Rows := Page.ChunkHeight;
    ChunkUnitLines := DivideRoundingUp(Rows, Planes.UnitHeight);
  end;
  ChunkLineBytes := DivideRoundingUp(Int64(ChunkUnitsAcross) * Planes.BitsPerUnit, 8);
  Expected := Int64(ChunkLineBytes) * ChunkUnitLines;
  if Expected > MaximumChunkBytes then
    RaiseImageError(ImageErrorTooLarge, 'TIFF strip or tile');
  Bytes := DecompressTiffChunk(Data, Page, Index, Expected);
  if Planes.PlaneCount = 1 then
    SamplesPerUnit := Page.SamplesPerPixel
  else
    SamplesPerUnit := 1;
  if Page.Predictor = TiffPredictorHorizontal then
    UndoHorizontalPredictor(PByte(Bytes), ChunkUnitLines, ChunkLineBytes, ChunkUnitsAcross, SamplesPerUnit,
      Page.BitsPerSample, Planes.BigEndian)
  else if Page.Predictor = TiffPredictorFloatingPoint then
    UndoFloatingPointPredictor(PByte(Bytes), ChunkUnitLines, ChunkLineBytes, ChunkUnitsAcross * SamplesPerUnit,
      SamplesPerUnit, Page.BitsPerSample div 8, Planes.BigEndian);
  FirstLine := Top div Planes.UnitHeight;
  ByteOffset := (Int64(Left div Planes.UnitWidth) * Planes.BitsPerUnit) div 8;
  CopyCount := ChunkLineBytes;
  if CopyCount > Planes.LineBytes - ByteOffset then
    CopyCount := Planes.LineBytes - ByteOffset;
  if CopyCount <= 0 then
    Exit;
  for Line := 0 to ChunkUnitLines - 1 do
  begin
    if FirstLine + Line >= Planes.UnitLines then
      Break;
    Move(Bytes[PtrInt(Line) * ChunkLineBytes], Planes.Planes[Plane][PtrInt(FirstLine + Line) * Planes.LineBytes +
      ByteOffset], CopyCount);
  end;
end;

function ReadTiffPlanes(const Data: TBytes; constref Page: TTiffPage; BigEndian: Boolean): TTiffPlanes;
var
  Plane: LongInt;
  Index: LongInt;
  ChunkCount: LongInt;
begin
  Result := Default(TTiffPlanes);
  Result.BigEndian := BigEndian;
  WorkOutGeometry(Page, Result);
  CheckPredictor(Page, Result);
  SetLength(Result.Planes, Result.PlaneCount);
  for Plane := 0 to Result.PlaneCount - 1 do
  begin
    SetLength(Result.Planes[Plane], PtrInt(Result.LineBytes) * Result.UnitLines);
    FillChar(Result.Planes[Plane][0], Length(Result.Planes[Plane]), 0);
  end;
  ChunkCount := Page.ChunksAcross * Page.ChunksDown * Result.PlaneCount;
  for Index := 0 to ChunkCount - 1 do
    ReadChunk(Data, Page, Result, Index);
end;

end.
