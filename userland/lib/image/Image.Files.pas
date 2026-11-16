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
  Loading and saving images: the convenience layer over the codecs.

  LoadImage reads a file, a stream or bytes, picks the decoder by the
  content's signature (never the file's name) and gives a TImage (a
  TAnimatedImage for an animation; check with "is"); the caller frees
  it. With ImageLoadApplyOrientation a picture whose EXIF says to turn
  it comes back turned, its orientation normal. Problems raise
  EImageError with a reason: ImageErrorUnknownFormat for content no
  decoder takes, ImageErrorNeedsPng for a PNG (no decoder yet),
  ImageErrorFile when the file cannot be read, and the decoder's own.
  TryLoadImage gives False and the reason instead.

  SaveImage and EncodeImage write in the format asked for
  (ImageFormatFromName turns 'png', 'jpg'... into one);
  ImageErrorNoEncoder when the library cannot write it.
}
unit Image.Files;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Image.Errors,
  Image.Model,
  Image.Frames,
  Image.Codecs;

type
  TImageLoadOption = (ImageLoadApplyOrientation);
  TImageLoadOptions = set of TImageLoadOption;

function LoadImage(const FileName: string; Options: TImageLoadOptions = []): TImage; overload;
function LoadImage(Stream: TStream; Options: TImageLoadOptions = []): TImage; overload;
function LoadImage(const Data: TBytes; Options: TImageLoadOptions = []): TImage; overload;
function TryLoadImage(const FileName: string; out Image: TImage; out Reason: TImageErrorReason;
  Options: TImageLoadOptions = []): Boolean; overload;
function TryLoadImage(const Data: TBytes; out Image: TImage; out Reason: TImageErrorReason;
  Options: TImageLoadOptions = []): Boolean; overload;

procedure SaveImage(Image: TImage; const FileName: string; Format: TImageFormat; Quality: LongInt = 90); overload;
procedure SaveImage(Image: TImage; Stream: TStream; Format: TImageFormat; Quality: LongInt = 90); overload;
function EncodeImage(Image: TImage; Format: TImageFormat; Quality: LongInt = 90): TBytes;

{ The format of a file's content (its first bytes are enough). }
function DetectFileFormat(const Data: TBytes): TImageFormat;
function ReadFileBytes(const FileName: string): TBytes;
function ReadStreamBytes(Stream: TStream): TBytes;

implementation

uses
  Image.Orientation,
  Image.StandardCodecs;

function ReadStreamBytes(Stream: TStream): TBytes;
const
  ChunkSize = 65536;
var
  Count: LongInt;
  Size: PtrInt;
begin
  Result := nil;
  Size := 0;
  repeat
    if Size + ChunkSize > Length(Result) then
      SetLength(Result, 2 * (Size + ChunkSize));
    Count := Stream.Read(Result[Size], ChunkSize);
    if Count > 0 then
      Inc(Size, Count);
  until Count <= 0;
  SetLength(Result, Size);
end;

function ReadFileBytes(const FileName: string): TBytes;
var
  Stream: TFileStream;
begin
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  except
    on Error: Exception do
      raise EImageError.Create(ImageErrorFile, FileName + ': ' + Error.Message);
  end;
  try
    try
      Result := ReadStreamBytes(Stream);
    except
      on Error: EStreamError do
        raise EImageError.Create(ImageErrorFile, FileName + ': ' + Error.Message);
    end;
  finally
    Stream.Free;
  end;
end;

function DetectFileFormat(const Data: TBytes): TImageFormat;
begin
  RegisterStandardImageCodecs;
  Result := DetectImageFormat(Data);
end;

function LoadImage(const Data: TBytes; Options: TImageLoadOptions): TImage;
var
  DecoderClass: TImageDecoderClass;
  Decoder: TImageDecoder;
  Turned: TImage;
begin
  RegisterStandardImageCodecs;
  DecoderClass := FindImageDecoder(Data);
  if DecoderClass = nil then
  begin
    if DetectImageFormat(Data) = ImageFormatPng then
      RaiseImageError(ImageErrorNeedsPng, 'no PNG decoder yet');
    RaiseImageError(ImageErrorUnknownFormat, '');
  end;
  Decoder := DecoderClass.Create;
  try
    Result := Decoder.Decode(Data);
  finally
    Decoder.Free;
  end;
  if (ImageLoadApplyOrientation in Options) and (Result.Orientation <> OrientationNormal) and
    not (Result is TAnimatedImage) then
  begin
    try
      Turned := OrientedImage(Result);
    finally
      Result.Free;
    end;
    Result := Turned;
  end;
end;

function LoadImage(Stream: TStream; Options: TImageLoadOptions): TImage;
begin
  Result := LoadImage(ReadStreamBytes(Stream), Options);
end;

function LoadImage(const FileName: string; Options: TImageLoadOptions): TImage;
begin
  Result := LoadImage(ReadFileBytes(FileName), Options);
end;

function TryLoadImage(const Data: TBytes; out Image: TImage; out Reason: TImageErrorReason;
  Options: TImageLoadOptions): Boolean;
begin
  Image := nil;
  Reason := ImageErrorNone;
  try
    Image := LoadImage(Data, Options);
  except
    on Error: EImageError do
      Reason := Error.Reason;
    on EOutOfMemory do
      Reason := ImageErrorTooLarge;
  end;
  Result := Image <> nil;
end;

function TryLoadImage(const FileName: string; out Image: TImage; out Reason: TImageErrorReason;
  Options: TImageLoadOptions): Boolean;
var
  Data: TBytes;
begin
  Image := nil;
  try
    Data := ReadFileBytes(FileName);
  except
    on Error: EImageError do
    begin
      Reason := Error.Reason;
      Exit(False);
    end;
  end;
  Result := TryLoadImage(Data, Image, Reason, Options);
end;

function EncodeImage(Image: TImage; Format: TImageFormat; Quality: LongInt): TBytes;
var
  EncoderClass: TImageEncoderClass;
  Encoder: TImageEncoder;
begin
  RegisterStandardImageCodecs;
  EncoderClass := FindImageEncoder(Format);
  if EncoderClass = nil then
    RaiseImageError(ImageErrorNoEncoder, ImageFormatName(Format));
  Encoder := EncoderClass.Create;
  try
    Encoder.Quality := Quality;
    Result := Encoder.Encode(Image);
  finally
    Encoder.Free;
  end;
end;

procedure SaveImage(Image: TImage; Stream: TStream; Format: TImageFormat; Quality: LongInt);
var
  Data: TBytes;
begin
  Data := EncodeImage(Image, Format, Quality);
  if Length(Data) > 0 then
    Stream.WriteBuffer(Data[0], Length(Data));
end;

procedure SaveImage(Image: TImage; const FileName: string; Format: TImageFormat; Quality: LongInt);
var
  Data: TBytes;
  Stream: TFileStream;
begin
  Data := EncodeImage(Image, Format, Quality);
  try
    Stream := TFileStream.Create(FileName, fmCreate);
  except
    on Error: Exception do
      raise EImageError.Create(ImageErrorFile, FileName + ': ' + Error.Message);
  end;
  try
    try
      if Length(Data) > 0 then
        Stream.WriteBuffer(Data[0], Length(Data));
    except
      on Error: EStreamError do
        raise EImageError.Create(ImageErrorFile, FileName + ': ' + Error.Message);
    end;
  finally
    Stream.Free;
  end;
end;

end.
