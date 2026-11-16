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
  The image model: a TImage is Width x Height pixels and what is known
  about them.

  Pixels are libdrawing's colours (Drawing.Colors): a LongWord
  $AARRGGBB each, straight (not premultiplied) alpha, so blue, green,
  red, alpha in memory; lines follow each other with no gap (the stride
  is the width). That is exactly a libdrawing surface, so an image is
  drawn without converting anything (Image.Surfaces).

  Beside the pixels: the resolution (dots per inch, 0 when the file does
  not say), the orientation the picture is meant to be seen in (EXIF's
  eight; the pixels are as stored, Image.Orientation turns them), the
  ICC colour profile as the file carried it (empty if none), metadata
  as ordered key/value text (Image.Metadata), and where the pixels came
  from: the format and its bits per pixel.

  A size is refused (EImageError, ImageErrorTooLarge) when either side
  is not positive or above MaximumImageSide, or there would be more than
  MaximumImagePixels; decoders check before they allocate, so a few
  bytes of malformed header never ask for gigabytes.
}
unit Image.Model;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Errors,
  Image.Metadata;

const
  MaximumImageSide = 65535;
  { 128 million pixels: half a gigabyte. }
  MaximumImagePixels = 128 * 1024 * 1024;

type
  { EXIF's orientations (1 to 8, in that order): how the stored pixels
    are to be turned to be seen upright. }
  TImageOrientation = (
    OrientationNormal,            { 1 }
    OrientationMirrorHorizontal,  { 2 }
    OrientationRotate180,         { 3 }
    OrientationMirrorVertical,    { 4 }
    OrientationTranspose,         { 5: mirrored, then turned 90 degrees anticlockwise }
    OrientationRotate90,          { 6: turned 90 degrees clockwise to be seen }
    OrientationTransverse,        { 7 }
    OrientationRotate270          { 8: turned 90 degrees anticlockwise to be seen }
  );

  TImageResolution = record
    HorizontalDpi: Double;
    VerticalDpi: Double;
  end;

  { What converting an image's colours to sRGB did (Image.ColorProfiles). }
  TColorConversionResult = (
    { The image is sRGB already, or says nothing about its colours. }
    ColorConversionNotNeeded,
    ColorConversionDone,
    { Converted, but not exactly as the profile says (a CMYK profile, a
      LUT that could not be read and the colorants used instead). }
    ColorConversionApproximate,
    { The profile cannot be used; the image is as it was. }
    ColorConversionUnsupported
  );

  TImage = class
  private
    FWidth: LongInt;
    FHeight: LongInt;
    FPixels: PLongWord;
    FResolution: TImageResolution;
    FOrientation: TImageOrientation;
    FIccProfile: TBytes;
    FMetadata: TImageMetadata;
    FSourceFormatName: string;
    FSourceBitsPerPixel: LongInt;
    FSourceHasAlpha: Boolean;
  public
    { Width x Height transparent pixels. }
    constructor Create(ImageWidth, ImageHeight: LongInt);
    { An image on NewPixels (from GetMem, NewWidth x NewHeight, no gap
      between lines), which it takes as its own; if the size is refused
      the pixels stay the caller's. }
    constructor CreateAdopting(NewPixels: PLongWord; NewWidth, NewHeight: LongInt);
    destructor Destroy; override;

    { The first pixel of line Y (no checks). }
    function Line(Y: LongInt): PLongWord; inline;
    { The pixel at (X, Y); transparent outside. }
    function GetPixel(X, Y: LongInt): TColor;
    { Sets the pixel at (X, Y) when it is inside. }
    procedure SetPixel(X, Y: LongInt; Color: TColor);
    procedure Fill(Color: TColor);
    { True when every pixel is opaque. }
    function IsOpaque: Boolean;

    { A copy: pixels and everything known about them. }
    function Clone: TImage;
    { Resolution, orientation, profile, metadata and source of Other. }
    procedure CopyPropertiesFrom(Other: TImage);
    { The colours converted from the ICC profile (or PNG gamma and
      chromaticities) to sRGB: Image.ColorProfiles.ConvertImageToSrgb. }
    function ConvertToSrgb: TColorConversionResult;

    { The image takes Pixels (from GetMem, Width x Height, no gap
      between lines) as its own, freeing what it had. }
    procedure AdoptPixels(NewPixels: PLongWord; NewWidth, NewHeight: LongInt);
    { Gives the pixels away (the caller frees them with FreeMem); the
      image is left 0 x 0. }
    function ReleasePixels: PLongWord;

    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
    property Pixels: PLongWord read FPixels;
    property Resolution: TImageResolution read FResolution write FResolution;
    property Orientation: TImageOrientation read FOrientation write FOrientation;
    property IccProfile: TBytes read FIccProfile write FIccProfile;
    property Metadata: TImageMetadata read FMetadata;
    { 'BMP', 'GIF', 'JPEG'... (Image.Codecs' format names). }
    property SourceFormatName: string read FSourceFormatName write FSourceFormatName;
    property SourceBitsPerPixel: LongInt read FSourceBitsPerPixel write FSourceBitsPerPixel;
    property SourceHasAlpha: Boolean read FSourceHasAlpha write FSourceHasAlpha;
  end;

{ Raises EImageError (ImageErrorTooLarge) unless Width x Height is a
  size an image may have. }
procedure CheckImageSize(Width, Height: Int64);
function ImageSizeAllowed(Width, Height: Int64): Boolean;

{ EXIF's value (1 to 8) as an orientation; anything else is normal. }
function OrientationFromExif(Value: LongInt): TImageOrientation;
function OrientationToExif(Orientation: TImageOrientation): LongInt;
{ True for the orientations that swap width and height. }
function OrientationSwapsSides(Orientation: TImageOrientation): Boolean;

function MakeResolution(HorizontalDpi, VerticalDpi: Double): TImageResolution;

implementation

uses
  Image.ColorProfiles;

function ImageSizeAllowed(Width, Height: Int64): Boolean;
begin
  Result := (Width > 0) and (Height > 0) and (Width <= MaximumImageSide) and (Height <= MaximumImageSide)
    and (Width * Height <= MaximumImagePixels);
end;

procedure CheckImageSize(Width, Height: Int64);
begin
  if not ImageSizeAllowed(Width, Height) then
    RaiseImageError(ImageErrorTooLarge, IntToStr(Width) + ' x ' + IntToStr(Height));
end;

function OrientationFromExif(Value: LongInt): TImageOrientation;
begin
  if (Value >= 1) and (Value <= 8) then
    Result := TImageOrientation(Value - 1)
  else
    Result := OrientationNormal;
end;

function OrientationToExif(Orientation: TImageOrientation): LongInt;
begin
  Result := Ord(Orientation) + 1;
end;

function OrientationSwapsSides(Orientation: TImageOrientation): Boolean;
begin
  Result := Orientation in [OrientationTranspose, OrientationRotate90, OrientationTransverse,
    OrientationRotate270];
end;

function MakeResolution(HorizontalDpi, VerticalDpi: Double): TImageResolution;
begin
  Result.HorizontalDpi := HorizontalDpi;
  Result.VerticalDpi := VerticalDpi;
end;

constructor TImage.Create(ImageWidth, ImageHeight: LongInt);
var
  Count: PtrUInt;
begin
  inherited Create;
  FMetadata := TImageMetadata.Create;
  CheckImageSize(ImageWidth, ImageHeight);
  Count := PtrUInt(ImageWidth) * PtrUInt(ImageHeight);
  FPixels := GetMem(Count * SizeOf(LongWord));
  if FPixels = nil then
    RaiseImageError(ImageErrorTooLarge, 'out of memory');
  FillDWord(FPixels^, Count, 0);
  FWidth := ImageWidth;
  FHeight := ImageHeight;
end;

constructor TImage.CreateAdopting(NewPixels: PLongWord; NewWidth, NewHeight: LongInt);
begin
  inherited Create;
  FMetadata := TImageMetadata.Create;
  CheckImageSize(NewWidth, NewHeight);
  FPixels := NewPixels;
  FWidth := NewWidth;
  FHeight := NewHeight;
end;

destructor TImage.Destroy;
begin
  if FPixels <> nil then
    FreeMem(FPixels);
  FMetadata.Free;
  inherited Destroy;
end;

function TImage.Line(Y: LongInt): PLongWord;
begin
  Result := FPixels + PtrInt(Y) * FWidth;
end;

function TImage.GetPixel(X, Y: LongInt): TColor;
begin
  if (X < 0) or (Y < 0) or (X >= FWidth) or (Y >= FHeight) then
    Exit(ColorTransparent);
  Result := Line(Y)[X];
end;

procedure TImage.SetPixel(X, Y: LongInt; Color: TColor);
begin
  if (X < 0) or (Y < 0) or (X >= FWidth) or (Y >= FHeight) then
    Exit;
  Line(Y)[X] := Color;
end;

procedure TImage.Fill(Color: TColor);
begin
  if FPixels <> nil then
    FillDWord(FPixels^, PtrUInt(FWidth) * PtrUInt(FHeight), Color);
end;

function TImage.IsOpaque: Boolean;
var
  Index: PtrUInt;
  Count: PtrUInt;
begin
  Count := PtrUInt(FWidth) * PtrUInt(FHeight);
  Index := 0;
  while Index < Count do
  begin
    if (FPixels[Index] shr 24) <> AlphaOpaque then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function TImage.Clone: TImage;
begin
  Result := TImage.Create(FWidth, FHeight);
  Move(FPixels^, Result.FPixels^, PtrUInt(FWidth) * PtrUInt(FHeight) * SizeOf(LongWord));
  Result.CopyPropertiesFrom(Self);
end;

procedure TImage.CopyPropertiesFrom(Other: TImage);
begin
  FResolution := Other.FResolution;
  FOrientation := Other.FOrientation;
  FIccProfile := Copy(Other.FIccProfile);
  FMetadata.Assign(Other.FMetadata);
  FSourceFormatName := Other.FSourceFormatName;
  FSourceBitsPerPixel := Other.FSourceBitsPerPixel;
  FSourceHasAlpha := Other.FSourceHasAlpha;
end;

function TImage.ConvertToSrgb: TColorConversionResult;
begin
  Result := ConvertImageToSrgb(Self);
end;

procedure TImage.AdoptPixels(NewPixels: PLongWord; NewWidth, NewHeight: LongInt);
begin
  CheckImageSize(NewWidth, NewHeight);
  if FPixels <> nil then
    FreeMem(FPixels);
  FPixels := NewPixels;
  FWidth := NewWidth;
  FHeight := NewHeight;
end;

function TImage.ReleasePixels: PLongWord;
begin
  Result := FPixels;
  FPixels := nil;
  FWidth := 0;
  FHeight := 0;
end;

end.
