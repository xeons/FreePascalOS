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
  The controls tour's pictures, drawn when it starts (there are no
  picture files on the system to show):

  - an image list of four 16 x 16 pictures (play, stop, zoom, a
    picture) in 16, 24 and 32 pixels: the first three from strips, the
    last from an icon file the tour writes (/tmp/controlstour.ico) and
    reads back, as a program would load its icons;
  - an animation written as an APNG (/tmp/controlstour.png) for the
    picture box to read: a blue frame round a transparent middle, an
    orange ball going to and fro across it.
}
unit Tour.Artwork;

{$mode objfpc}
{$H+}

interface

uses
  Controls.ImageList;

const
  PlayPicture = 0;
  StopPicture = 1;
  ZoomPicture = 2;
  PicturePicture = 3;
  AnimationFileName = '/tmp/controlstour.png';
  IconFileName = '/tmp/controlstour.ico';
  { The animation's frame (the same in every frame), and its size. }
  AnimationBorderColor = $FF3060C0;
  AnimationWidth = 64;
  AnimationHeight = 48;
  AnimationBorder = 4;

{ The tour's image list (16 x 16 logical units). }
function MakeTourImages: TImageList;
{ Writes the animation; False if it could not be. }
function WriteTourAnimation: Boolean;

implementation

uses
  SysUtils,
  Classes,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.SmoothShapes,
  Drawing.Rasterizer,
  Image.Model,
  Image.Frames,
  Image.Codecs,
  Image.Files,
  Image.Surfaces,
  Image.Ico.Writing;

const
  StripPictures = 3;
  PlayColor = $FF2E9E44;
  StopColor = $FFC8372D;
  ZoomColor = $FF30343A;
  SkyColor = $FF8EC5F0;
  HillColor = $FF4F9A3C;
  SunColor = $FFF2C230;
  BallColor = $FFF07820;
  AnimationFrames = 12;
  AnimationDelay = 80;

{ A point of a picture Size pixels across, designed on a 16 grid. }
function GridPoint(Size: LongInt; X, Y: Double): TPrecisePoint;
begin
  Result := PrecisePoint(X * Size / 16, Y * Size / 16);
end;

function GridBox(Size: LongInt; X, Y, Width, Height: Double): TRectangle;
begin
  Result := MakeRectangle(Round(X * Size / 16), Round(Y * Size / 16), Round(Width * Size / 16),
    Round(Height * Size / 16));
end;

procedure DrawPlay(const Canvas: TCanvas; Size, Left: LongInt);
var
  Points: array[0..2] of TPrecisePoint;
begin
  Points[0] := GridPoint(Size, 4, 2);
  Points[1] := GridPoint(Size, 13, 8);
  Points[2] := GridPoint(Size, 4, 14);
  Points[0].X := Points[0].X + Left;
  Points[1].X := Points[1].X + Left;
  Points[2].X := Points[2].X + Left;
  FillSmoothPolygon(Canvas, Points, PlayColor);
end;

procedure DrawStop(const Canvas: TCanvas; Size, Left: LongInt);
begin
  FillRectangle(Canvas, OffsetRectangle(GridBox(Size, 3, 3, 10, 10), Left, 0), StopColor);
end;

procedure DrawZoom(const Canvas: TCanvas; Size, Left: LongInt);
var
  Handle: array[0..3] of TPrecisePoint;
  Index: LongInt;
begin
  DrawSmoothEllipseOutline(Canvas, OffsetRectangle(GridBox(Size, 1.5, 1.5, 9, 9), Left, 0), 1.5 * Size / 16, ZoomColor);
  Handle[0] := GridPoint(Size, 9, 10.5);
  Handle[1] := GridPoint(Size, 10.5, 9);
  Handle[2] := GridPoint(Size, 15, 13.5);
  Handle[3] := GridPoint(Size, 13.5, 15);
  for Index := 0 to 3 do
    Handle[Index].X := Handle[Index].X + Left;
  FillSmoothPolygon(Canvas, Handle, ZoomColor);
end;

{ Play, stop and zoom side by side, Size pixels each. }
function MakeStrip(Size: LongInt): TImage;
var
  Canvas: TCanvas;
begin
  Result := TImage.Create(StripPictures * Size, Size);
  BeginCanvas(Canvas, ImageSurface(Result));
  DrawPlay(Canvas, Size, 0);
  DrawStop(Canvas, Size, Size);
  DrawZoom(Canvas, Size, 2 * Size);
end;

{ A landscape in a frame: sky, sun and a hill. }
function MakeLandscape(Size: LongInt): TImage;
var
  Canvas: TCanvas;
  Hill: array[0..3] of TPrecisePoint;
begin
  Result := TImage.Create(Size, Size);
  BeginCanvas(Canvas, ImageSurface(Result));
  FillRectangle(Canvas, GridBox(Size, 1, 2, 14, 12), SkyColor);
  FillSmoothEllipse(Canvas, GridBox(Size, 9, 3.5, 4, 4), SunColor);
  Hill[0] := GridPoint(Size, 1, 14);
  Hill[1] := GridPoint(Size, 1, 10);
  Hill[2] := GridPoint(Size, 7, 7);
  Hill[3] := GridPoint(Size, 15, 14);
  FillSmoothPolygon(Canvas, Hill, HillColor);
  DrawRectangleOutline(Canvas, GridBox(Size, 1, 2, 14, 12), ZoomColor);
end;

procedure WriteBytes(const FileName: string; const Data: TBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
end;

{ The landscape through an icon file with its 16 and 32 pixel pictures;
  the 24 pixel one is made from the 32 when it is wanted. }
procedure AddLandscape(Images: TImageList);
var
  Small: TImage;
  Large: TImage;
begin
  Small := MakeLandscape(16);
  Large := MakeLandscape(32);
  try
    try
      WriteBytes(IconFileName, EncodeIconFile([Small, Large], False));
    except
      on Exception do;
    end;
    if Images.AddFromFile(IconFileName) < 0 then
      Images.Add(Small);
  finally
    Small.Free;
    Large.Free;
  end;
end;

function MakeTourImages: TImageList;
var
  Strip: TImage;
  First: LongInt;
  Size: LongInt;
begin
  Result := TImageList.Create(16, 16);
  First := -1;
  for Size in [16, 24, 32] do
  begin
    Strip := MakeStrip(Size);
    if First < 0 then
      First := Result.AddStrip(Strip)
    else
      Result.AddStripVariants(First, Strip);
    Strip.Free;
  end;
  AddLandscape(Result);
end;

{ Frame Index of the animation: the border, and the ball at its place. }
function MakeAnimationFrame(Index: LongInt): TImage;
var
  Canvas: TCanvas;
  Step: LongInt;
  Travel: LongInt;
  BallLeft: LongInt;
begin
  Result := TImage.Create(AnimationWidth, AnimationHeight);
  BeginCanvas(Canvas, ImageSurface(Result));
  FillRectangle(Canvas, MakeRectangle(0, 0, AnimationWidth, AnimationBorder), AnimationBorderColor);
  FillRectangle(Canvas, MakeRectangle(0, AnimationHeight - AnimationBorder, AnimationWidth, AnimationBorder),
    AnimationBorderColor);
  FillRectangle(Canvas, MakeRectangle(0, 0, AnimationBorder, AnimationHeight), AnimationBorderColor);
  FillRectangle(Canvas, MakeRectangle(AnimationWidth - AnimationBorder, 0, AnimationBorder, AnimationHeight),
    AnimationBorderColor);
  { There and back again over the frames. }
  Step := Index;
  if Step > AnimationFrames div 2 then
    Step := AnimationFrames - Step;
  Travel := AnimationWidth - 2 * AnimationBorder - 20;
  BallLeft := AnimationBorder + 2 + Travel * Step div (AnimationFrames div 2);
  FillSmoothEllipse(Canvas, MakeRectangle(BallLeft, AnimationHeight div 2 - 8, 16, 16), BallColor);
end;

function WriteTourAnimation: Boolean;
var
  Animation: TAnimatedImage;
  Frame: TImageFrame;
  Index: LongInt;
begin
  Result := False;
  Animation := TAnimatedImage.Create(AnimationWidth, AnimationHeight);
  try
    for Index := 0 to AnimationFrames - 1 do
    begin
      Frame := TImageFrame.Create(MakeAnimationFrame(Index));
      Frame.Delay := AnimationDelay;
      Frame.Disposal := FrameDisposalNone;
      Frame.Blend := FrameBlendSource;
      Animation.AddFrame(Frame);
    end;
    { The first frame is the picture shown where animations are not. }
    Move(Animation.Frames[0].Image.Pixels^, Animation.Pixels^, AnimationWidth * AnimationHeight * SizeOf(LongWord));
    Animation.LoopCount := 0;
    try
      SaveImage(Animation, AnimationFileName, ImageFormatPng);
      Result := True;
    except
      on Exception do;
    end;
  finally
    Animation.Free;
  end;
end;

end.
