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
  Decoding a page of a TIFF file.

  Pages are not frames: a TIFF of several pages (a scanned document, a
  fax) has no delays and its pages may differ in size, so decoding the
  file gives its first page, with 'PageCount' in the metadata when
  there are more, and DecodeTiffPage gives any other; TiffPageCount
  says how many there are.

  The page's directory (Image.Tiff.Pages) says how its strips or tiles
  are compressed: JPEG chunks are decoded whole by the JPEG decoder
  (Image.Tiff.Jpeg); the others are decompressed into planes of samples
  (Image.Tiff.Strips) and turned into colours (Image.Tiff.Photometric).
  Besides the pixels: the orientation (the pixels are not turned), the
  resolution in dots per inch (from centimetres if that is the unit, none
  when there is no unit), the ICC profile, and the description, software
  and date in the metadata.
}
unit Image.Tiff.Reading;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model;

{ How many pages Data's TIFF file has. }
function TiffPageCount(const Data: TBytes): LongInt;
{ Page PageIndex (from 0) of Data's TIFF file. }
function DecodeTiffPage(const Data: TBytes; PageIndex: LongInt): TImage;

implementation

uses
  Image.Metadata,
  Image.Tiff.Tags,
  Image.Tiff.Directory,
  Image.Tiff.Pages,
  Image.Tiff.Strips,
  Image.Tiff.Photometric,
  Image.Tiff.Jpeg;

const
  CentimetresPerInch = 2.54;

function TiffPageCount(const Data: TBytes): LongInt;
var
  TiffFile: TTiffFile;
begin
  TiffFile := TTiffFile.Create(Data);
  try
    Result := Length(TiffFile.PageOffsets);
  finally
    TiffFile.Free;
  end;
end;

function SourceBits(constref Page: TTiffPage): LongInt;
begin
  if Page.Photometric = TiffPhotometricPalette then
    Result := Page.BitsPerSample
  else
    Result := Page.BitsPerSample * Page.SamplesPerPixel;
end;

procedure SetProperties(constref Page: TTiffPage; PageCount: LongInt; Image: TImage);
var
  Associated: Boolean;
begin
  Image.SourceFormatName := 'TIFF';
  Image.SourceBitsPerPixel := SourceBits(Page);
  Image.SourceHasAlpha := TiffAlphaSample(Page, Associated) >= 0;
  Image.Orientation := OrientationFromExif(Page.Orientation);
  if (Page.HorizontalResolution > 0) and (Page.VerticalResolution > 0) then
    case Page.ResolutionUnit of
      TiffResolutionUnitInch:
        Image.Resolution := MakeResolution(Page.HorizontalResolution, Page.VerticalResolution);
      TiffResolutionUnitCentimetre:
        Image.Resolution := MakeResolution(Page.HorizontalResolution * CentimetresPerInch,
          Page.VerticalResolution * CentimetresPerInch);
    end;
  Image.IccProfile := Page.IccProfile;
  if Page.Description <> '' then
    Image.Metadata.SetValue(MetadataKeyDescription, Page.Description);
  if Page.Software <> '' then
    Image.Metadata.SetValue(MetadataKeySoftware, Page.Software);
  if Page.DateTime <> '' then
    Image.Metadata.SetValue(MetadataKeyDateTime, Page.DateTime);
  if PageCount > 1 then
    Image.Metadata.SetValue(MetadataKeyPageCount, IntToStr(PageCount));
end;

procedure DecodePixels(TiffFile: TTiffFile; constref Page: TTiffPage; Image: TImage);
var
  Planes: TTiffPlanes;
begin
  case Page.Compression of
    TiffCompressionNone, TiffCompressionPackBits, TiffCompressionLzw, TiffCompressionAdobeDeflate,
    TiffCompressionDeflate:
      begin
        Planes := ReadTiffPlanes(TiffFile.Data, Page, TiffFile.BigEndian);
        ConvertTiffPlanes(Page, Planes, Image);
      end;
    TiffCompressionJpeg:
      DecodeTiffJpegChunks(TiffFile.Data, Page, Image);
    TiffCompressionOldJpeg:
      RaiseImageError(ImageErrorUnsupported, 'old-style TIFF JPEG');
    TiffCompressionCcittRle, TiffCompressionCcittGroup3, TiffCompressionCcittGroup4:
      RaiseImageError(ImageErrorUnsupported, 'TIFF CCITT fax compression');
  else
    RaiseImageError(ImageErrorUnsupported, 'TIFF compression ' + IntToStr(Page.Compression));
  end;
end;

function DecodeTiffPage(const Data: TBytes; PageIndex: LongInt): TImage;
var
  TiffFile: TTiffFile;
  Offsets: TTiffIntegerArray;
  Page: TTiffPage;
  Image: TImage;
begin
  TiffFile := TTiffFile.Create(Data);
  try
    Offsets := TiffFile.PageOffsets;
    if (PageIndex < 0) or (PageIndex >= Length(Offsets)) then
      RaiseImageError(ImageErrorMalformed, 'no TIFF page ' + IntToStr(PageIndex));
    Page := ReadTiffPage(TiffFile, Offsets[PageIndex]);
    Image := TImage.Create(Page.Width, Page.Height);
    try
      DecodePixels(TiffFile, Page, Image);
      SetProperties(Page, Length(Offsets), Image);
    except
      Image.Free;
      raise;
    end;
    Result := Image;
  finally
    TiffFile.Free;
  end;
end;

end.
