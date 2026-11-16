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
  What a TIFF directory says about its page, gathered in one record:
  the size, the samples (how many, how many bits, how they are to be
  read as colour), how the data is cut up (strips of RowsPerStrip
  lines, or tiles) and compressed, and what else is known (resolution,
  orientation, profile, text).

  Defaults are TIFF's: one sample of one bit, no compression, chunky
  samples, one strip for the whole picture, YCbCr subsampled 2 x 2 with
  the coefficients of Rec. 601 and the reference black and white of
  full range. What the decoders cannot do (samples of differing sizes,
  signed samples, integers of more than 16 bits, floating point samples
  of other than 16 or 32 bits, fax compression of anything but one
  bilevel sample) is ImageErrorUnsupported here, before anything is
  decoded.

  Strips and tiles are both "chunks": a strip is a chunk the width of
  the picture and RowsPerStrip lines high. With separate planes there
  are as many chunks again for each sample, plane after plane.
}
unit Image.Tiff.Pages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Tiff.Tags,
  Image.Tiff.Directory;

type
  TTiffPage = record
    Width: LongInt;
    Height: LongInt;
    BitsPerSample: LongInt;
    SamplesPerPixel: LongInt;
    { TiffSampleFormatUnsigned or TiffSampleFormatFloat. }
    SampleFormat: LongInt;
    Compression: LongInt;
    Photometric: LongInt;
    PlanarConfiguration: LongInt;
    Predictor: LongInt;
    FillOrder: LongInt;
    ExtraSamples: TTiffIntegerArray;
    Tiled: Boolean;
    { A strip is the picture's width by RowsPerStrip lines. }
    ChunkWidth: LongInt;
    ChunkHeight: LongInt;
    ChunksAcross: LongInt;
    ChunksDown: LongInt;
    ChunkOffsets: TTiffIntegerArray;
    ChunkByteCounts: TTiffIntegerArray;
    ColorMap: TTiffIntegerArray;
    SubsamplingHorizontal: LongInt;
    SubsamplingVertical: LongInt;
    YCbCrCoefficients: array[0..2] of Double;
    ReferenceBlackWhite: array[0..5] of Double;
    JpegTables: TBytes;
    { Old-style JPEG's stream of the whole page (0 when none). }
    JpegInterchangeOffset: Int64;
    JpegInterchangeLength: Int64;
    { Fax compression's options. }
    T4Options: LongWord;
    T6Options: LongWord;
    InkSet: LongInt;
    Orientation: LongInt;
    HorizontalResolution: Double;
    VerticalResolution: Double;
    ResolutionUnit: LongInt;
    IccProfile: TBytes;
    Description: string;
    Software: string;
    DateTime: string;
  end;

{ The page whose directory is at Offset. }
function ReadTiffPage(TiffFile: TTiffFile; Offset: Int64): TTiffPage;
{ The planes the page's samples are in: 1, or SamplesPerPixel when
  they are separate. }
function TiffPlaneCount(constref Page: TTiffPage): LongInt;
{ The samples that are colour, not extra (alpha and the like). }
function TiffColorSampleCount(constref Page: TTiffPage): LongInt;
{ The index of the alpha sample and whether it is premultiplied; -1
  when there is none. }
function TiffAlphaSample(constref Page: TTiffPage; out Associated: Boolean): LongInt;

implementation

const
  UnlimitedRows = 4294967295;

procedure Unsupported(const Detail: string);
begin
  RaiseImageError(ImageErrorUnsupported, 'TIFF ' + Detail);
end;

procedure Malformed(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'TIFF ' + Detail);
end;

function TiffPlaneCount(constref Page: TTiffPage): LongInt;
begin
  if Page.PlanarConfiguration = TiffPlanarSeparate then
    Result := Page.SamplesPerPixel
  else
    Result := 1;
end;

function TiffColorSampleCount(constref Page: TTiffPage): LongInt;
begin
  Result := Page.SamplesPerPixel - Length(Page.ExtraSamples);
  if Result < 1 then
    Result := 1;
end;

function TiffAlphaSample(constref Page: TTiffPage; out Associated: Boolean): LongInt;
var
  Index: LongInt;
  ColorSamples: LongInt;
begin
  Associated := False;
  ColorSamples := TiffColorSampleCount(Page);
  for Index := 0 to Length(Page.ExtraSamples) - 1 do
    if (Page.ExtraSamples[Index] = TiffExtraAssociatedAlpha) or
      (Page.ExtraSamples[Index] = TiffExtraUnassociatedAlpha) then
    begin
      Associated := Page.ExtraSamples[Index] = TiffExtraAssociatedAlpha;
      if ColorSamples + Index >= Page.SamplesPerPixel then
        Exit(-1);
      Exit(ColorSamples + Index);
    end;
  Result := -1;
end;

{ Value as a LongInt, those beyond its range at its ends (they then
  fail the checks on the field as any other wrong value does). }
function ClampToLongInt(Value: Int64): LongInt;
begin
  if Value > High(LongInt) then
    Result := High(LongInt)
  else if Value < Low(LongInt) then
    Result := Low(LongInt)
  else
    Result := Value;
end;

function IntegerTag(TiffFile: TTiffFile; constref Directory: TTiffDirectory; Tag: LongWord;
  Default: Int64): LongInt;
begin
  Result := ClampToLongInt(TiffFile.IntegerOf(Directory, Tag, Default));
end;

function DivideRoundingUp(Value, Divisor: Int64): Int64;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

procedure ReadSamples(TiffFile: TTiffFile; constref Directory: TTiffDirectory; var Page: TTiffPage);
var
  Bits: TTiffIntegerArray;
  Formats: TTiffIntegerArray;
  Index: LongInt;
begin
  Page.SamplesPerPixel := IntegerTag(TiffFile, Directory, TiffTagSamplesPerPixel, 1);
  if (Page.SamplesPerPixel < 1) or (Page.SamplesPerPixel > 16) then
    Unsupported('samples per pixel');
  Bits := TiffFile.IntegersOf(Directory, TiffTagBitsPerSample);
  if Length(Bits) = 0 then
    Page.BitsPerSample := 1
  else
  begin
    Page.BitsPerSample := ClampToLongInt(Bits[0]);
    for Index := 1 to Length(Bits) - 1 do
      if (Index < Page.SamplesPerPixel) and (Bits[Index] <> Bits[0]) then
        Unsupported('samples of different sizes');
  end;
  Formats := TiffFile.IntegersOf(Directory, TiffTagSampleFormat);
  Page.SampleFormat := TiffSampleFormatUnsigned;
  if Length(Formats) > 0 then
    Page.SampleFormat := ClampToLongInt(Formats[0]);
  for Index := 1 to Length(Formats) - 1 do
    if (Index < Page.SamplesPerPixel) and (Formats[Index] <> Formats[0]) then
      Unsupported('samples of different formats');
  case Page.SampleFormat of
    TiffSampleFormatUnsigned:
      if (Page.BitsPerSample < 1) or (Page.BitsPerSample > 16) then
        Unsupported(IntToStr(Page.BitsPerSample) + ' bits per sample');
    TiffSampleFormatFloat:
      if (Page.BitsPerSample <> 16) and (Page.BitsPerSample <> 32) then
        Unsupported(IntToStr(Page.BitsPerSample) + '-bit floating point samples');
  else
    Unsupported('samples that are neither unsigned integers nor floating point');
  end;
  Page.ExtraSamples := TiffFile.IntegersOf(Directory, TiffTagExtraSamples);
  if Length(Page.ExtraSamples) >= Page.SamplesPerPixel then
    SetLength(Page.ExtraSamples, Page.SamplesPerPixel - 1);
end;

procedure ReadChunks(TiffFile: TTiffFile; constref Directory: TTiffDirectory; var Page: TTiffPage);
var
  RowsPerStrip: Int64;
  Expected: Int64;
  Entry: TTiffEntry;
begin
  Page.Tiled := TiffFile.FindEntry(Directory, TiffTagTileWidth, Entry);
  if Page.Tiled then
  begin
    Page.ChunkWidth := IntegerTag(TiffFile, Directory, TiffTagTileWidth, 0);
    Page.ChunkHeight := IntegerTag(TiffFile, Directory, TiffTagTileLength, 0);
    if (Page.ChunkWidth < 1) or (Page.ChunkHeight < 1) or (Page.ChunkWidth > MaximumImageSide) or
      (Page.ChunkHeight > MaximumImageSide) then
      Malformed('tile size');
    Page.ChunkOffsets := TiffFile.IntegersOf(Directory, TiffTagTileOffsets);
    Page.ChunkByteCounts := TiffFile.IntegersOf(Directory, TiffTagTileByteCounts);
  end
  else
  begin
    RowsPerStrip := IntegerTag(TiffFile, Directory, TiffTagRowsPerStrip, UnlimitedRows);
    if (RowsPerStrip < 1) or (RowsPerStrip > Page.Height) then
      RowsPerStrip := Page.Height;
    Page.ChunkWidth := Page.Width;
    Page.ChunkHeight := RowsPerStrip;
    Page.ChunkOffsets := TiffFile.IntegersOf(Directory, TiffTagStripOffsets);
    Page.ChunkByteCounts := TiffFile.IntegersOf(Directory, TiffTagStripByteCounts);
  end;
  Page.ChunksAcross := DivideRoundingUp(Page.Width, Page.ChunkWidth);
  Page.ChunksDown := DivideRoundingUp(Page.Height, Page.ChunkHeight);
  Expected := Int64(Page.ChunksAcross) * Page.ChunksDown * TiffPlaneCount(Page);
  if Length(Page.ChunkOffsets) < Expected then
    Malformed('fewer strips or tiles than the picture needs');
  { Without byte counts a chunk runs to the end of the file (it is cut
    to the size it decodes to). }
  if Length(Page.ChunkByteCounts) = 0 then
    SetLength(Page.ChunkByteCounts, Length(Page.ChunkOffsets))
  else if Length(Page.ChunkByteCounts) < Expected then
    Malformed('fewer byte counts than strips or tiles');
end;

function IsSubsamplingFactor(Factor: LongInt): Boolean;
begin
  Result := (Factor = 1) or (Factor = 2) or (Factor = 4);
end;

procedure ReadColorSettings(TiffFile: TTiffFile; constref Directory: TTiffDirectory; var Page: TTiffPage);
var
  Values: TTiffIntegerArray;
  Numbers: TTiffNumberArray;
  Index: LongInt;
begin
  Page.ColorMap := TiffFile.IntegersOf(Directory, TiffTagColorMap);
  Page.InkSet := IntegerTag(TiffFile, Directory, TiffTagInkSet, TiffInkSetCmyk);
  Page.SubsamplingHorizontal := 2;
  Page.SubsamplingVertical := 2;
  Values := TiffFile.IntegersOf(Directory, TiffTagYCbCrSubsampling);
  if Length(Values) >= 2 then
  begin
    Page.SubsamplingHorizontal := ClampToLongInt(Values[0]);
    Page.SubsamplingVertical := ClampToLongInt(Values[1]);
  end;
  if not IsSubsamplingFactor(Page.SubsamplingHorizontal) or not IsSubsamplingFactor(Page.SubsamplingVertical) then
    Malformed('YCbCr subsampling');
  Page.YCbCrCoefficients[0] := 0.299;
  Page.YCbCrCoefficients[1] := 0.587;
  Page.YCbCrCoefficients[2] := 0.114;
  Numbers := TiffFile.NumbersOf(Directory, TiffTagYCbCrCoefficients);
  if (Length(Numbers) >= 3) and (Numbers[1] <> 0) then
    for Index := 0 to 2 do
      Page.YCbCrCoefficients[Index] := Numbers[Index];
  Page.ReferenceBlackWhite[0] := 0;
  Page.ReferenceBlackWhite[1] := 255;
  Page.ReferenceBlackWhite[2] := 128;
  Page.ReferenceBlackWhite[3] := 255;
  Page.ReferenceBlackWhite[4] := 128;
  Page.ReferenceBlackWhite[5] := 255;
  Numbers := TiffFile.NumbersOf(Directory, TiffTagReferenceBlackWhite);
  if Length(Numbers) >= 6 then
    for Index := 0 to 5 do
      Page.ReferenceBlackWhite[Index] := Numbers[Index];
  Page.JpegTables := TiffFile.BytesOf(Directory, TiffTagJpegTables);
  Page.JpegInterchangeOffset := TiffFile.IntegerOf(Directory, TiffTagJpegInterchangeFormat, 0);
  Page.JpegInterchangeLength := TiffFile.IntegerOf(Directory, TiffTagJpegInterchangeFormatLength, 0);
  Page.T4Options := LongWord(TiffFile.IntegerOf(Directory, TiffTagT4Options, 0) and $FFFFFFFF);
  Page.T6Options := LongWord(TiffFile.IntegerOf(Directory, TiffTagT6Options, 0) and $FFFFFFFF);
end;

procedure ReadDescription(TiffFile: TTiffFile; constref Directory: TTiffDirectory; var Page: TTiffPage);
begin
  Page.Orientation := IntegerTag(TiffFile, Directory, TiffTagOrientation, 1);
  Page.HorizontalResolution := TiffFile.NumberOf(Directory, TiffTagXResolution, 0);
  Page.VerticalResolution := TiffFile.NumberOf(Directory, TiffTagYResolution, 0);
  Page.ResolutionUnit := IntegerTag(TiffFile, Directory, TiffTagResolutionUnit, TiffResolutionUnitInch);
  Page.IccProfile := TiffFile.BytesOf(Directory, TiffTagIccProfile);
  Page.Description := TiffFile.TextOf(Directory, TiffTagImageDescription);
  Page.Software := TiffFile.TextOf(Directory, TiffTagSoftware);
  Page.DateTime := TiffFile.TextOf(Directory, TiffTagDateTime);
end;

procedure CheckCompression(constref Page: TTiffPage);
begin
  case Page.Compression of
    TiffCompressionCcittRle, TiffCompressionCcittGroup3, TiffCompressionCcittGroup4:
      if (Page.BitsPerSample <> 1) or (Page.SamplesPerPixel <> 1) then
        Unsupported('CCITT fax compression of other than one bilevel sample');
  end;
  if (Page.SampleFormat = TiffSampleFormatFloat) and ((Page.Photometric = TiffPhotometricPalette) or
    (Page.Photometric = TiffPhotometricYCbCr) or (Page.Compression = TiffCompressionJpeg) or
    (Page.Compression = TiffCompressionOldJpeg)) then
    Unsupported('floating point samples with this photometric interpretation or compression');
end;

procedure CheckColor(var Page: TTiffPage);
var
  ColorSamples: LongInt;
begin
  CheckCompression(Page);
  ColorSamples := TiffColorSampleCount(Page);
  case Page.Photometric of
    TiffPhotometricWhiteIsZero, TiffPhotometricBlackIsZero:
      ;
    TiffPhotometricRgb:
      if ColorSamples < 3 then
        Malformed('RGB of fewer than three samples');
    TiffPhotometricPalette:
      if Length(Page.ColorMap) < 3 * (Int64(1) shl Page.BitsPerSample) then
        Malformed('colour map');
    TiffPhotometricSeparated:
      begin
        if Page.InkSet <> TiffInkSetCmyk then
          Unsupported('inks other than CMYK');
        if ColorSamples < 4 then
          Malformed('CMYK of fewer than four samples');
      end;
    TiffPhotometricYCbCr:
      begin
        if ColorSamples < 3 then
          Malformed('YCbCr of fewer than three samples');
        if (Page.Compression <> TiffCompressionJpeg) and (Page.BitsPerSample <> 8) then
          Unsupported('YCbCr samples of other than 8 bits');
      end;
  else
    Unsupported('photometric interpretation ' + IntToStr(Page.Photometric));
  end;
end;

function ReadTiffPage(TiffFile: TTiffFile; Offset: Int64): TTiffPage;
var
  Directory: TTiffDirectory;
  Entry: TTiffEntry;
begin
  Result := Default(TTiffPage);
  Directory := TiffFile.ReadDirectory(Offset);
  Result.Width := IntegerTag(TiffFile, Directory, TiffTagImageWidth, 0);
  Result.Height := IntegerTag(TiffFile, Directory, TiffTagImageLength, 0);
  CheckImageSize(Result.Width, Result.Height);
  ReadSamples(TiffFile, Directory, Result);
  Result.Compression := IntegerTag(TiffFile, Directory, TiffTagCompression, TiffCompressionNone);
  if not TiffFile.FindEntry(Directory, TiffTagPhotometric, Entry) then
  begin
    { Missing: a guess from the samples, as readers commonly make. }
    if Result.SamplesPerPixel >= 3 then
      Result.Photometric := TiffPhotometricRgb
    else
      Result.Photometric := TiffPhotometricBlackIsZero;
  end
  else
    Result.Photometric := IntegerTag(TiffFile, Directory, TiffTagPhotometric, TiffPhotometricBlackIsZero);
  Result.PlanarConfiguration := IntegerTag(TiffFile, Directory, TiffTagPlanarConfiguration, TiffPlanarChunky);
  if (Result.PlanarConfiguration <> TiffPlanarChunky) and (Result.PlanarConfiguration <> TiffPlanarSeparate) then
    Malformed('planar configuration');
  if Result.SamplesPerPixel = 1 then
    Result.PlanarConfiguration := TiffPlanarChunky;
  Result.Predictor := IntegerTag(TiffFile, Directory, TiffTagPredictor, TiffPredictorNone);
  Result.FillOrder := IntegerTag(TiffFile, Directory, TiffTagFillOrder, 1);
  ReadChunks(TiffFile, Directory, Result);
  ReadColorSettings(TiffFile, Directory, Result);
  ReadDescription(TiffFile, Directory, Result);
  CheckColor(Result);
end;

end.
