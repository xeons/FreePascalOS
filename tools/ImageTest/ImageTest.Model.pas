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
  The image model and what works on it, without files: sizes refused,
  metadata, surfaces shared and handed over without copying, the eight
  orientations, scaling and fitting, frames composited with each
  blend and disposal; then the registry and the convenience layer:
  formats by content, names, loading from bytes, streams and files,
  PNG and unknown content refused with their reasons, saving.
}
unit ImageTest.Model;

{$mode objfpc}
{$H+}

interface

procedure TestModel;

implementation

uses
  SysUtils,
  Classes,
  Drawing.Colors,
  Drawing.Surfaces,
  Image.Errors,
  Image.Metadata,
  Image.Model,
  Image.Frames,
  Image.Surfaces,
  Image.Compositing,
  Image.Orientation,
  Image.Scaling,
  Image.Codecs,
  Image.Files,
  ImageTest.Checks;

procedure TestSizes;
var
  Reason: TImageErrorReason;
begin
  Check(ImageSizeAllowed(1, 1) and ImageSizeAllowed(MaximumImageSide, 2), 'sizes allowed');
  Check(not ImageSizeAllowed(0, 5) and not ImageSizeAllowed(5, -1) and not ImageSizeAllowed(MaximumImageSide + 1, 1),
    'sides refused');
  Check(not ImageSizeAllowed(MaximumImageSide, MaximumImageSide), 'too many pixels refused');
  Reason := ImageErrorNone;
  try
    TImage.Create(0, 10).Free;
  except
    on Error: EImageError do
      Reason := Error.Reason;
  end;
  Check(Reason = ImageErrorTooLarge, 'an image of no width is refused');
end;

procedure TestMetadata;
var
  Image: TImage;
  Copy: TImage;
begin
  Image := TImage.Create(2, 2);
  try
    Image.Metadata.SetValue('Comment', 'one');
    Image.Metadata.SetValue('Author', 'two');
    Image.Metadata.SetValue('comment', 'three');
    Check(Image.Metadata.Count = 2, 'metadata keys are not repeated');
    Check(Image.Metadata.GetValue('COMMENT') = 'three', 'metadata keys ignore case');
    Check(Image.Metadata.Keys[1] = 'Author', 'metadata keeps its order');
    Image.Metadata.Remove('Author');
    Check(not Image.Metadata.Contains('Author') and (Image.Metadata.GetValue('Author', 'none') = 'none'),
      'metadata removed');
    Image.IccProfile := TBytes.Create(1, 2, 3);
    Image.Orientation := OrientationRotate90;
    Image.Resolution := MakeResolution(96, 120);
    Image.SetPixel(1, 1, $80112233);
    Copy := Image.Clone;
    try
      Check((Copy.GetPixel(1, 1) = $80112233) and (Length(Copy.IccProfile) = 3) and
        (Copy.Orientation = OrientationRotate90) and (Copy.Resolution.VerticalDpi = 120) and
        (Copy.Metadata.GetValue('Comment') = 'three'), 'a clone has everything');
      Check(Copy.Pixels <> Image.Pixels, 'a clone has pixels of its own');
    finally
      Copy.Free;
    end;
    Check(Image.GetPixel(-1, 0) = ColorTransparent, 'outside is transparent');
    Check(OrientationFromExif(6) = OrientationRotate90, 'EXIF 6 is turned 90 degrees');
    Check(OrientationFromExif(42) = OrientationNormal, 'an unknown EXIF orientation is normal');
    Check(OrientationToExif(OrientationRotate270) = 8, 'orientation back to EXIF');
  finally
    Image.Free;
  end;
end;

procedure TestSurfaces;
var
  Image: TImage;
  Surface: TSurface;
  Pixels: PLongWord;
  Back: TImage;
begin
  Image := TImage.Create(5, 4);
  try
    Surface := ImageSurface(Image);
    Check((Surface.Pixels = Image.Pixels) and (Surface.Stride = 5) and not Surface.OwnsPixels,
      'a surface on an image shares its pixels');
    SetSurfacePixel(Surface, 2, 3, $FF00FF00);
    Check(Image.GetPixel(2, 3) = $FF00FF00, 'drawing on the surface changes the image');
    Pixels := Image.Pixels;
    Surface := SurfaceTakingImage(Image);
    Check((Surface.Pixels = Pixels) and Surface.OwnsPixels and (Image.Width = 0) and (Image.Pixels = nil),
      'the pixels move to a surface without a copy');
    Back := ImageTakingSurface(Surface);
    try
      Check((Back.Pixels = Pixels) and (Surface.Pixels = nil) and (Back.GetPixel(2, 3) = $FF00FF00),
        'and back to an image without a copy');
    finally
      Back.Free;
    end;
  finally
    Image.Free;
  end;
  { A surface with a gap between lines is copied. }
  CreateSurface(Surface, 8, 3, $FF123456);
  Surface.Width := 6;
  Back := ImageTakingSurface(Surface);
  try
    Check((Back.Width = 6) and (Back.GetPixel(5, 2) = $FF123456) and (Surface.Pixels = nil),
      'a surface with a stride of its own is copied');
  finally
    Back.Free;
  end;
end;

{ A 3 x 2 picture whose pixels are their own positions. }
function PositionPicture: TImage;
var
  X: LongInt;
  Y: LongInt;
begin
  Result := TImage.Create(3, 2);
  for Y := 0 to 1 do
    for X := 0 to 2 do
      Result.SetPixel(X, Y, $FF000000 or LongWord(Y * 16 + X));
end;

function PositionsText(Image: TImage): string;
var
  X: LongInt;
  Y: LongInt;
begin
  Result := '';
  for Y := 0 to Image.Height - 1 do
  begin
    for X := 0 to Image.Width - 1 do
      Result := Result + IntToHex(Image.GetPixel(X, Y) and $FF, 2);
    if Y < Image.Height - 1 then
      Result := Result + '/';
  end;
end;

procedure TestOrientation;
const
  { The picture 00 01 02 / 10 11 12 as each orientation shows it. }
  Expected: array[TImageOrientation] of string = (
    '000102/101112',
    '020100/121110',
    '121110/020100',
    '101112/000102',
    '0010/0111/0212',
    '1000/1101/1202',
    '1202/1101/1000',
    '0212/0111/0010');
var
  Orientation: TImageOrientation;
  Picture: TImage;
  Turned: TImage;
begin
  for Orientation := Low(TImageOrientation) to High(TImageOrientation) do
  begin
    Picture := PositionPicture;
    try
      Picture.Orientation := Orientation;
      Turned := OrientedImage(Picture);
      try
        Check((PositionsText(Turned) = Expected[Orientation]) and (Turned.Orientation = OrientationNormal),
          'orientation ' + IntToStr(OrientationToExif(Orientation)) + ': ' + PositionsText(Turned));
      finally
        Turned.Free;
      end;
    finally
      Picture.Free;
    end;
  end;
end;

procedure TestScaling;
var
  Picture: TImage;
  Scaled: TImage;
  Width: LongInt;
  Height: LongInt;
begin
  Picture := TImage.Create(4, 4);
  try
    Picture.Fill($FF000000);
    Picture.SetPixel(0, 0, $FFFFFFFF);
    Picture.SetPixel(1, 0, $FFFFFFFF);
    Picture.SetPixel(0, 1, $FFFFFFFF);
    Picture.SetPixel(1, 1, $FFFFFFFF);
    Picture.SetPixel(2, 2, $FFFFFFFF);
    Scaled := ScaleImage(Picture, 2, 2);
    try
      Check((Scaled.GetPixel(0, 0) = $FFFFFFFF) and (Scaled.GetPixel(1, 0) = $FF000000) and
        (Scaled.GetPixel(1, 1) = $FF404040), 'shrinking averages the area: ' + IntToHex(Scaled.GetPixel(1, 1), 8));
    finally
      Scaled.Free;
    end;
  finally
    Picture.Free;
  end;
  FitSize(4000, 3000, 256, 256, Width, Height);
  Check((Width = 256) and (Height = 192), 'a thumbnail of 4000 x 3000 is 256 x 192');
  FitSize(100, 400, 256, 256, Width, Height);
  Check((Width = 64) and (Height = 256), 'a thumbnail of 100 x 400 is 64 x 256');
  FitSize(50, 40, 256, 256, Width, Height);
  Check((Width = 50) and (Height = 40), 'a small picture is not made larger');
  Picture := TImage.Create(400, 300);
  try
    Scaled := ThumbnailImage(Picture, 100, 100);
    try
      Check((Scaled.Width = 100) and (Scaled.Height = 75), 'thumbnail size');
    finally
      Scaled.Free;
    end;
  finally
    Picture.Free;
  end;
end;

function SolidImage(Width, Height: LongInt; Color: TColor): TImage;
begin
  Result := TImage.Create(Width, Height);
  Result.Fill(Color);
end;

procedure TestCompositing;
var
  Animation: TAnimatedImage;
  Frame: TImageFrame;
  Compositor: TFrameCompositor;
  Canvas: TImage;
begin
  Animation := TAnimatedImage.Create(4, 4);
  try
    Frame := TImageFrame.Create(SolidImage(4, 4, $FF0000FF));
    Animation.AddFrame(Frame);
    Frame := TImageFrame.Create(SolidImage(2, 2, $80FF0000));
    Frame.Left := 1;
    Frame.Top := 1;
    Frame.Disposal := FrameDisposalPrevious;
    Animation.AddFrame(Frame);
    Frame := TImageFrame.Create(SolidImage(2, 2, $8000FF00));
    Frame.Left := 3;
    Frame.Top := 3;
    Frame.Blend := FrameBlendSource;
    Frame.Disposal := FrameDisposalBackground;
    Animation.AddFrame(Frame);
    Frame := TImageFrame.Create(SolidImage(1, 1, $FFFFFFFF));
    Animation.AddFrame(Frame);
    Compositor := TFrameCompositor.Create(Animation);
    try
      Canvas := Compositor.RenderFrame(1);
      Check(Canvas.GetPixel(1, 1) = BlendColors($FF0000FF, $80FF0000), 'a frame blended over the canvas');
      Check(Canvas.GetPixel(0, 0) = $FF0000FF, 'outside the frame the canvas stays');
      Canvas := Compositor.RenderFrame(2);
      Check(Canvas.GetPixel(1, 1) = $FF0000FF, 'disposal to previous puts the canvas back');
      Check(Canvas.GetPixel(3, 3) = $8000FF00, 'a frame that is its source replaces, cut at the canvas');
      Canvas := Compositor.RenderFrame(3);
      Check((Canvas.GetPixel(3, 3) = ColorTransparent) and (Canvas.GetPixel(0, 0) = $FFFFFFFF) and
        (Canvas.GetPixel(2, 2) = $FF0000FF), 'disposal to background clears to transparent');
    finally
      Compositor.Free;
    end;
  finally
    Animation.Free;
  end;
end;

procedure TestRegistry;
var
  Image: TImage;
  Reason: TImageErrorReason;
  Stream: TMemoryStream;
  Data: TBytes;
  FileName: string;
begin
  Check(DetectFileFormat(FixtureBytes('bmp24.bmp')) = ImageFormatBmp, 'BMP recognised by content');
  Check(DetectFileFormat(FixtureBytes('icon-multi.ico')) = ImageFormatIco, 'ICO recognised by content');
  Check(DetectFileFormat(FixtureBytes('anim.gif')) = ImageFormatGif, 'GIF recognised by content');
  Check(DetectFileFormat(TBytes.Create($89, $50, $4E, $47, $0D, $0A, $1A, $0A, 0, 0)) = ImageFormatPng,
    'PNG recognised by content');
  Check(DetectFileFormat(TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8)) = ImageFormatUnknown, 'other bytes are unknown');
  Check(ImageFormatFromName('JPG') = ImageFormatJpeg, 'format from a name');
  Check(ImageFormatFromName('.bmp') = ImageFormatBmp, 'format from an extension');
  Check(ImageFormatFromName('xyz') = ImageFormatUnknown, 'an unknown name');
  Image := nil;
  Check(not TryLoadImage(TBytes.Create($89, $50, $4E, $47, $0D, $0A, $1A, $0A, 0, 0, 0, 13), Image, Reason) and
    (Reason = ImageErrorNeedsPng), 'a PNG needs PNG');
  Check(not TryLoadImage(TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12), Image, Reason) and
    (Reason = ImageErrorUnknownFormat), 'unknown content refused');
  Check(not TryLoadImage(TBytes(nil), Image, Reason) and (Reason = ImageErrorUnknownFormat),
    'no bytes refused');
  Check(not TryLoadImage(FixturePath('no-such-file.bmp'), Image, Reason) and (Reason = ImageErrorFile),
    'a missing file refused');
  { The name says GIF, the content is a BMP. }
  Image := LoadImage(FixturePath('pillow-rgb.bmp'));
  try
    Check(Image.SourceFormatName = 'BMP', 'loaded from a file');
    FileName := FixturePath('saved-as-gif-but-bmp.gif');
    SaveImage(Image, FileName, ImageFormatBmp);
  finally
    Image.Free;
  end;
  Image := LoadImage(FileName);
  try
    Check(Image.SourceFormatName = 'BMP', 'the content decides, not the name');
  finally
    Image.Free;
  end;
  Stream := TMemoryStream.Create;
  try
    Data := FixtureBytes('anim.gif');
    Stream.WriteBuffer(Data[0], Length(Data));
    Stream.Position := 0;
    Image := LoadImage(Stream);
    try
      Check(Image is TAnimatedImage, 'loaded from a stream');
    finally
      Image.Free;
    end;
  finally
    Stream.Free;
  end;
  Image := TImage.Create(2, 2);
  try
    Reason := ImageErrorNone;
    try
      EncodeImage(Image, ImageFormatPng);
    except
      on Error: EImageError do
        Reason := Error.Reason;
    end;
    Check(Reason = ImageErrorNoEncoder, 'no encoder for PNG yet');
  finally
    Image.Free;
  end;
end;

procedure TestModel;
begin
  TestSizes;
  TestMetadata;
  TestSurfaces;
  TestOrientation;
  TestScaling;
  TestCompositing;
  TestRegistry;
end;

end.
