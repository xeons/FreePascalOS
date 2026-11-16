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
  TIFF's numbers: the tags of a directory entry, the types of their
  values, and the values of the tags that choose how a picture is
  stored (compression, photometric interpretation, planar
  configuration, predictor, extra samples, resolution unit).
}
unit Image.Tiff.Tags;

{$mode objfpc}
{$H+}

interface

const
  { Field types: the size of one value follows from each. }
  TiffTypeByte = 1;
  TiffTypeAscii = 2;
  TiffTypeShort = 3;
  TiffTypeLong = 4;
  TiffTypeRational = 5;
  TiffTypeSignedByte = 6;
  TiffTypeUndefined = 7;
  TiffTypeSignedShort = 8;
  TiffTypeSignedLong = 9;
  TiffTypeSignedRational = 10;
  TiffTypeFloat = 11;
  TiffTypeDouble = 12;
  TiffTypeIfd = 13;
  TiffTypeLong8 = 16;
  TiffTypeSignedLong8 = 17;
  TiffTypeIfd8 = 18;

  { Tags. }
  TiffTagNewSubfileType = 254;
  TiffTagImageWidth = 256;
  TiffTagImageLength = 257;
  TiffTagBitsPerSample = 258;
  TiffTagCompression = 259;
  TiffTagPhotometric = 262;
  TiffTagFillOrder = 266;
  TiffTagImageDescription = 270;
  TiffTagStripOffsets = 273;
  TiffTagOrientation = 274;
  TiffTagSamplesPerPixel = 277;
  TiffTagRowsPerStrip = 278;
  TiffTagStripByteCounts = 279;
  TiffTagXResolution = 282;
  TiffTagYResolution = 283;
  TiffTagPlanarConfiguration = 284;
  TiffTagT4Options = 292;
  TiffTagT6Options = 293;
  TiffTagResolutionUnit = 296;
  TiffTagSoftware = 305;
  TiffTagDateTime = 306;
  TiffTagPredictor = 317;
  TiffTagColorMap = 320;
  TiffTagTileWidth = 322;
  TiffTagTileLength = 323;
  TiffTagTileOffsets = 324;
  TiffTagTileByteCounts = 325;
  TiffTagInkSet = 332;
  TiffTagExtraSamples = 338;
  TiffTagSampleFormat = 339;
  TiffTagJpegTables = 347;
  { Old-style JPEG: where a whole JPEG stream of the page is. }
  TiffTagJpegInterchangeFormat = 513;
  TiffTagJpegInterchangeFormatLength = 514;
  TiffTagYCbCrCoefficients = 529;
  TiffTagYCbCrSubsampling = 530;
  TiffTagReferenceBlackWhite = 532;
  TiffTagIccProfile = 34675;

  { Compression. }
  TiffCompressionNone = 1;
  TiffCompressionCcittRle = 2;
  TiffCompressionCcittGroup3 = 3;
  TiffCompressionCcittGroup4 = 4;
  TiffCompressionLzw = 5;
  TiffCompressionOldJpeg = 6;
  TiffCompressionJpeg = 7;
  TiffCompressionAdobeDeflate = 8;
  TiffCompressionDeflate = 32946;
  TiffCompressionPackBits = 32773;

  { Photometric interpretation. }
  TiffPhotometricWhiteIsZero = 0;
  TiffPhotometricBlackIsZero = 1;
  TiffPhotometricRgb = 2;
  TiffPhotometricPalette = 3;
  TiffPhotometricMask = 4;
  TiffPhotometricSeparated = 5;
  TiffPhotometricYCbCr = 6;
  TiffPhotometricCieLab = 8;

  { Planar configuration: samples of a pixel together, or each sample
    in a plane of its own. }
  TiffPlanarChunky = 1;
  TiffPlanarSeparate = 2;

  TiffPredictorNone = 1;
  TiffPredictorHorizontal = 2;
  TiffPredictorFloatingPoint = 3;

  { Extra samples. }
  TiffExtraUnspecified = 0;
  TiffExtraAssociatedAlpha = 1;
  TiffExtraUnassociatedAlpha = 2;

  TiffSampleFormatUnsigned = 1;
  TiffSampleFormatSigned = 2;
  TiffSampleFormatFloat = 3;

  TiffResolutionUnitNone = 1;
  TiffResolutionUnitInch = 2;
  TiffResolutionUnitCentimetre = 3;

  TiffInkSetCmyk = 1;

  { Fill order 2: the bits of each byte from the lowest. }
  TiffFillOrderLowestFirst = 2;

{ The size in bytes of one value of FieldType, 0 for a type not known. }
function TiffTypeSize(FieldType: LongWord): LongInt;

implementation

function TiffTypeSize(FieldType: LongWord): LongInt;
begin
  case FieldType of
    TiffTypeByte, TiffTypeAscii, TiffTypeSignedByte, TiffTypeUndefined:
      Result := 1;
    TiffTypeShort, TiffTypeSignedShort:
      Result := 2;
    TiffTypeLong, TiffTypeSignedLong, TiffTypeFloat, TiffTypeIfd:
      Result := 4;
    TiffTypeRational, TiffTypeSignedRational, TiffTypeDouble, TiffTypeLong8, TiffTypeSignedLong8, TiffTypeIfd8:
      Result := 8;
  else
    Result := 0;
  end;
end;

end.
