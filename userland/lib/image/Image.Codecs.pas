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
  Decoders and encoders, and the registry that picks them.

  A decoder (TImageDecoder) says from a file's first bytes whether the
  file is its format (CanDecode: magic bytes, never the file's name) and
  turns the whole file, in memory, into a TImage (a TAnimatedImage for
  an animation). It raises EImageError for what it cannot read. An
  encoder (TImageEncoder) turns a TImage into a file of its format, with
  a quality (1 to 100, for lossy formats) and bits per pixel (0: the
  encoder's choice) set first.

  Decoders are asked in the order they were registered, so formats whose
  signatures are weak (DIB, the headerless BMP) are registered last.
  Image.StandardCodecs registers every format of the library.

  The embedded image hook: a container that holds whole files of another
  format (an ICO's PNG entries) decodes them through DecodeEmbeddedImage,
  which finds a registered decoder for them, so a PNG decoder registered
  later is used without the container knowing of it. A PNG with no PNG
  decoder registered (a program that registers codecs itself, without
  Image.StandardCodecs) is ImageErrorNeedsPng.
}
unit Image.Codecs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model;

type
  TImageFormat = (
    ImageFormatUnknown,
    ImageFormatBmp,
    ImageFormatDib,
    ImageFormatIco,
    ImageFormatCur,
    ImageFormatGif,
    ImageFormatJpeg,
    ImageFormatPng,
    ImageFormatTiff,
    ImageFormatJxl
  );

  TImageDecoder = class
  public
    constructor Create; virtual;
    class function Format: TImageFormat; virtual; abstract;
    { True when Data (a file's first bytes, or all of it) is this format. }
    class function CanDecode(const Data: TBytes): Boolean; virtual; abstract;
    function Decode(const Data: TBytes): TImage; virtual; abstract;
  end;
  TImageDecoderClass = class of TImageDecoder;

  TImageEncoder = class
  private
    FQuality: LongInt;
    FBitsPerPixel: LongInt;
  public
    constructor Create; virtual;
    class function Format: TImageFormat; virtual; abstract;
    function Encode(Image: TImage): TBytes; virtual; abstract;
    { 1 to 100, for lossy formats (90 unless set). }
    property Quality: LongInt read FQuality write FQuality;
    { 0 for the encoder's choice. }
    property BitsPerPixel: LongInt read FBitsPerPixel write FBitsPerPixel;
  end;
  TImageEncoderClass = class of TImageEncoder;

const
  PngSignature: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);

function ImageFormatName(Format: TImageFormat): string;
{ 'bmp', 'JPEG', 'jpg'... as a format (for a SaveImage given a name). }
function ImageFormatFromName(const Name: string): TImageFormat;

procedure RegisterImageDecoder(DecoderClass: TImageDecoderClass);
procedure RegisterImageEncoder(EncoderClass: TImageEncoderClass);
{ The first registered decoder for Data, or nil. }
function FindImageDecoder(const Data: TBytes): TImageDecoderClass;
function FindImageDecoderForFormat(Format: TImageFormat): TImageDecoderClass;
function FindImageEncoder(Format: TImageFormat): TImageEncoderClass;

{ Data's format by its signature, without a decoder; PNG is known
  before its decoder is. }
function DetectImageFormat(const Data: TBytes): TImageFormat;

{ A whole embedded file decoded by whichever decoder takes it. }
function DecodeEmbeddedImage(const Data: TBytes): TImage;

implementation

var
  Decoders: array of TImageDecoderClass;
  Encoders: array of TImageEncoderClass;

constructor TImageDecoder.Create;
begin
  inherited Create;
end;

constructor TImageEncoder.Create;
begin
  inherited Create;
  FQuality := 90;
  FBitsPerPixel := 0;
end;

function ImageFormatName(Format: TImageFormat): string;
begin
  case Format of
    ImageFormatBmp: Result := 'BMP';
    ImageFormatDib: Result := 'DIB';
    ImageFormatIco: Result := 'ICO';
    ImageFormatCur: Result := 'CUR';
    ImageFormatGif: Result := 'GIF';
    ImageFormatJpeg: Result := 'JPEG';
    ImageFormatPng: Result := 'PNG';
    ImageFormatTiff: Result := 'TIFF';
    ImageFormatJxl: Result := 'JPEG XL';
  else
    Result := 'unknown';
  end;
end;

function ImageFormatFromName(const Name: string): TImageFormat;
var
  Lower: string;
begin
  Lower := LowerCase(Name);
  if (Lower <> '') and (Lower[1] = '.') then
    Delete(Lower, 1, 1);
  if Lower = 'bmp' then
    Result := ImageFormatBmp
  else if Lower = 'dib' then
    Result := ImageFormatDib
  else if Lower = 'ico' then
    Result := ImageFormatIco
  else if Lower = 'cur' then
    Result := ImageFormatCur
  else if Lower = 'gif' then
    Result := ImageFormatGif
  else if (Lower = 'jpeg') or (Lower = 'jpg') or (Lower = 'jpe') or (Lower = 'jfif') then
    Result := ImageFormatJpeg
  else if (Lower = 'png') or (Lower = 'apng') then
    Result := ImageFormatPng
  else if (Lower = 'tiff') or (Lower = 'tif') then
    Result := ImageFormatTiff
  else if Lower = 'jxl' then
    Result := ImageFormatJxl
  else
    Result := ImageFormatUnknown;
end;

procedure RegisterImageDecoder(DecoderClass: TImageDecoderClass);
var
  Index: LongInt;
begin
  for Index := 0 to Length(Decoders) - 1 do
    if Decoders[Index] = DecoderClass then
      Exit;
  SetLength(Decoders, Length(Decoders) + 1);
  Decoders[High(Decoders)] := DecoderClass;
end;

procedure RegisterImageEncoder(EncoderClass: TImageEncoderClass);
var
  Index: LongInt;
begin
  for Index := 0 to Length(Encoders) - 1 do
    if Encoders[Index] = EncoderClass then
      Exit;
  SetLength(Encoders, Length(Encoders) + 1);
  Encoders[High(Encoders)] := EncoderClass;
end;

function FindImageDecoder(const Data: TBytes): TImageDecoderClass;
var
  Index: LongInt;
begin
  for Index := 0 to Length(Decoders) - 1 do
    if Decoders[Index].CanDecode(Data) then
      Exit(Decoders[Index]);
  Result := nil;
end;

function FindImageDecoderForFormat(Format: TImageFormat): TImageDecoderClass;
var
  Index: LongInt;
begin
  for Index := 0 to Length(Decoders) - 1 do
    if Decoders[Index].Format = Format then
      Exit(Decoders[Index]);
  Result := nil;
end;

function FindImageEncoder(Format: TImageFormat): TImageEncoderClass;
var
  Index: LongInt;
begin
  for Index := 0 to Length(Encoders) - 1 do
    if Encoders[Index].Format = Format then
      Exit(Encoders[Index]);
  Result := nil;
end;

function DetectImageFormat(const Data: TBytes): TImageFormat;
var
  DecoderClass: TImageDecoderClass;
  Index: LongInt;
begin
  if Length(Data) >= Length(PngSignature) then
  begin
    Result := ImageFormatPng;
    for Index := 0 to High(PngSignature) do
      if Data[Index] <> PngSignature[Index] then
        Result := ImageFormatUnknown;
    if Result = ImageFormatPng then
      Exit;
  end;
  DecoderClass := FindImageDecoder(Data);
  if DecoderClass = nil then
    Result := ImageFormatUnknown
  else
    Result := DecoderClass.Format;
end;

function DecodeEmbeddedImage(const Data: TBytes): TImage;
var
  DecoderClass: TImageDecoderClass;
  Decoder: TImageDecoder;
begin
  DecoderClass := FindImageDecoder(Data);
  if DecoderClass = nil then
  begin
    if DetectImageFormat(Data) = ImageFormatPng then
      RaiseImageError(ImageErrorNeedsPng, 'no PNG decoder registered');
    RaiseImageError(ImageErrorUnknownFormat, 'embedded image');
  end;
  Decoder := DecoderClass.Create;
  try
    Result := Decoder.Decode(Data);
  finally
    Decoder.Free;
  end;
end;

end.
