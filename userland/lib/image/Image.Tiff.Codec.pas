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
  TIFF as a decoder and an encoder for the registry.

  A file of several pages decodes as its first page, with 'PageCount'
  (MetadataKeyPageCount) in the metadata; pages are not frames (they
  have no delays and may differ in size). TiffPageCount and
  DecodeTiffPage (Image.Tiff.Reading, passed on here) pick any page.
  Encoding writes one page, deflate compressed with the horizontal
  predictor; Image.Tiff.Writing has the other choices and several pages.
}
unit Image.Tiff.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Codecs;

type
  TTiffDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TTiffEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

{ How many pages Data's TIFF file has. }
function TiffPageCount(const Data: TBytes): LongInt;
{ Page PageIndex (from 0) of Data's TIFF file. }
function DecodeTiffPage(const Data: TBytes; PageIndex: LongInt): TImage;

implementation

uses
  Image.Tiff.Directory,
  Image.Tiff.Reading,
  Image.Tiff.Writing;

function TiffPageCount(const Data: TBytes): LongInt;
begin
  Result := Image.Tiff.Reading.TiffPageCount(Data);
end;

function DecodeTiffPage(const Data: TBytes; PageIndex: LongInt): TImage;
begin
  Result := Image.Tiff.Reading.DecodeTiffPage(Data, PageIndex);
end;

class function TTiffDecoder.Format: TImageFormat;
begin
  Result := ImageFormatTiff;
end;

class function TTiffDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := LooksLikeTiff(Data);
end;

function TTiffDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := Image.Tiff.Reading.DecodeTiffPage(Data, 0);
end;

class function TTiffEncoder.Format: TImageFormat;
begin
  Result := ImageFormatTiff;
end;

function TTiffEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeTiffImage(Image, DefaultTiffWriteOptions);
end;

end.
