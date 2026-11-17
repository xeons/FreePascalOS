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
  Picture boxes: a control showing a picture (libimage's TImage), given
  to it (TakeImage) or read from a file (LoadFromFile: any format
  libimage reads).

  An image's pixels count as logical units, so a picture is the same
  size on every display: at 150 % a 100 x 100 picture covers 150 x 150
  pixels. SizeMode says how it fits the box (Controls.PictureGeometry):
  at its size at the top left, stretched to fill it, zoomed to fit with
  its proportions kept, centred, or with the box taking the picture's
  size. A picture shown at another size is resampled smoothly
  (Image.Resampling) once for that size and kept, so painting again
  only copies it.

  Transparent pixels show what is behind the box (its parent) unless
  Color is set, which fills the box first. An animation (GIF, APNG,
  animated WebP, JPEG XL) plays (TFrameCompositor, frame by frame on a
  timer, each shown for its delay, as many times as the file says or
  for ever); Play and Stop start and stop it. A file that cannot be
  read leaves the box showing what went wrong (ErrorText) in place of a
  picture.
}
unit Controls.PictureBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Image.Model,
  Image.Frames,
  Image.Compositing,
  Controls.Base,
  Controls.Timers,
  Controls.PictureGeometry;

type
  TPictureBox = class(TControl)
  private
    FImage: TImage;
    FAnimation: TAnimatedImage;
    FCompositor: TFrameCompositor;
    FTimer: TTimer;
    { The picture shown now (the image, or the animation's frame), and a
      number that changes whenever it does. }
    FFrame: TImage;
    FFrameSerial: LongWord;
    FLoopsDone: LongInt;
    FPlaying: Boolean;
    FAutoPlay: Boolean;
    FSizeMode: TPictureSizeMode;
    FColor: TColor;
    FErrorText: string;
    { The frame resampled for the size it is shown at. }
    FResampled: TImage;
    FResampledSerial: LongWord;
    procedure SetSizeMode(Value: TPictureSizeMode);
    procedure SetColor(Value: TColor);
    procedure ForgetResampled;
    procedure ReleaseImage;
    procedure FitBoxToPicture;
    function ResampledFrame(Width, Height: LongInt): TImage;
    function FrameDelay(Index: LongInt): LongWord;
    procedure TimerTicked(Sender: TTimer);
    procedure ShowFrameChanged;
    procedure PaintError(var Canvas: TCanvas);
    function GetFrameIndex: LongInt;
    function GetFrameCount: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Shows Image, which the box takes as its own (an animation plays if
      AutoPlay). }
    procedure TakeImage(Image: TImage);
    { Shows the picture in a file; False (and ErrorText says why) if it
      cannot be read. }
    function LoadFromFile(const FileName: string): Boolean;
    { No picture, no error. }
    procedure Clear;
    { Starts the animation (again from the start if it had finished). }
    procedure Play;
    { Stops it at the frame shown. }
    procedure Stop;
    { Where the picture is drawn now (own pixels; empty if none). }
    function PictureBounds: TRectangle;
    { The picture's size in logical units (0 x 0 if none). }
    function PictureWidth: LongInt;
    function PictureHeight: LongInt;
    property Image: TImage read FImage;
    property SizeMode: TPictureSizeMode read FSizeMode write SetSizeMode;
    { The background (transparent, the default: none). }
    property Color: TColor read FColor write SetColor;
    { What went wrong reading the last file ('' if nothing). }
    property ErrorText: string read FErrorText;
    property Playing: Boolean read FPlaying;
    { Animations play as soon as they are shown (True unless set). }
    property AutoPlay: Boolean read FAutoPlay write FAutoPlay;
    { The animation's frame shown, and how many it has (0 for a still). }
    property FrameIndex: LongInt read GetFrameIndex;
    property FrameCount: LongInt read GetFrameCount;
  end;

implementation

uses
  SysUtils,
  Windowing.Theme,
  Windowing.Connection,
  Image.Errors,
  Image.Files,
  Image.Surfaces,
  Image.Resampling,
  Controls.Icons,
  Controls.Text;

const
  { Milliseconds a frame with no delay (or a very short one) is shown,
    as browsers do. }
  ShortestFrameDelay = 20;
  DefaultFrameDelay = 100;

constructor TPictureBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FColor := ColorTransparent;
  FAutoPlay := True;
  FSizeMode := PictureSizeNormal;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerTicked;
end;

destructor TPictureBox.Destroy;
begin
  FTimer.Free;
  ReleaseImage;
  inherited Destroy;
end;

procedure TPictureBox.ForgetResampled;
begin
  FreeAndNil(FResampled);
end;

procedure TPictureBox.ReleaseImage;
begin
  FTimer.Stop;
  FPlaying := False;
  ForgetResampled;
  FreeAndNil(FCompositor);
  FAnimation := nil;
  FFrame := nil;
  FreeAndNil(FImage);
end;

procedure TPictureBox.Clear;
begin
  ReleaseImage;
  FErrorText := '';
  Invalidate;
end;

procedure TPictureBox.TakeImage(Image: TImage);
begin
  ReleaseImage;
  FErrorText := '';
  FImage := Image;
  FFrame := Image;
  if (Image is TAnimatedImage) and (TAnimatedImage(Image).FrameCount > 0) then
  begin
    FAnimation := TAnimatedImage(Image);
    FCompositor := TFrameCompositor.Create(FAnimation);
    FFrame := FCompositor.RenderFrame(0);
  end;
  FLoopsDone := 0;
  Inc(FFrameSerial);
  FitBoxToPicture;
  Invalidate;
  if FAutoPlay then
    Play;
end;

function TPictureBox.LoadFromFile(const FileName: string): Boolean;
var
  Loaded: TImage;
  Reason: TImageErrorReason;
begin
  Loaded := nil;
  try
    Result := TryLoadImage(FileName, Loaded, Reason, [ImageLoadApplyOrientation, ImageLoadConvertToSrgb]);
  except
    on Exception do
    begin
      Result := False;
      Reason := ImageErrorMalformed;
    end;
  end;
  if Result then
  begin
    TakeImage(Loaded);
    Exit;
  end;
  Loaded.Free;
  ReleaseImage;
  FErrorText := ImageErrorReasonText(Reason);
  Invalidate;
end;

procedure TPictureBox.SetSizeMode(Value: TPictureSizeMode);
begin
  if FSizeMode = Value then
    Exit;
  FSizeMode := Value;
  FitBoxToPicture;
  Invalidate;
end;

procedure TPictureBox.SetColor(Value: TColor);
begin
  if FColor = Value then
    Exit;
  FColor := Value;
  Invalidate;
end;

function TPictureBox.PictureWidth: LongInt;
begin
  Result := 0;
  if FFrame <> nil then
    Result := FFrame.Width;
end;

function TPictureBox.PictureHeight: LongInt;
begin
  Result := 0;
  if FFrame <> nil then
    Result := FFrame.Height;
end;

{ AutoSize: the box takes the picture's size, where it is. }
procedure TPictureBox.FitBoxToPicture;
begin
  if (FSizeMode <> PictureSizeAuto) or (FFrame = nil) then
    Exit;
  SetBounds(Bounds.Left, Bounds.Top, PictureWidth, PictureHeight);
end;

function TPictureBox.GetFrameIndex: LongInt;
begin
  Result := 0;
  if FCompositor <> nil then
    Result := FCompositor.CurrentIndex;
end;

function TPictureBox.GetFrameCount: LongInt;
begin
  Result := 0;
  if FAnimation <> nil then
    Result := FAnimation.FrameCount;
end;

{ --- Playing ---------------------------------------------------------------- }

function TPictureBox.FrameDelay(Index: LongInt): LongWord;
var
  Delay: LongInt;
begin
  Delay := FAnimation.Frames[Index].Delay;
  if Delay < ShortestFrameDelay then
    Delay := DefaultFrameDelay;
  Result := Delay;
end;

procedure TPictureBox.Play;
begin
  if (FAnimation = nil) or (FAnimation.FrameCount < 2) then
    Exit;
  { Finished: from the start again. }
  if (FAnimation.LoopCount > 0) and (FLoopsDone >= FAnimation.LoopCount) then
  begin
    FLoopsDone := 0;
    FFrame := FCompositor.RenderFrame(0);
    ShowFrameChanged;
  end;
  FPlaying := True;
  FTimer.Interval := FrameDelay(FCompositor.CurrentIndex);
  FTimer.Start;
end;

procedure TPictureBox.Stop;
begin
  FPlaying := False;
  FTimer.Stop;
end;

procedure TPictureBox.ShowFrameChanged;
begin
  Inc(FFrameSerial);
  Invalidate;
end;

procedure TPictureBox.TimerTicked(Sender: TTimer);
begin
  if (FCompositor = nil) or not FPlaying then
  begin
    Stop;
    Exit;
  end;
  if FCompositor.CurrentIndex + 1 >= FAnimation.FrameCount then
  begin
    Inc(FLoopsDone);
    if (FAnimation.LoopCount > 0) and (FLoopsDone >= FAnimation.LoopCount) then
    begin
      { Played as many times as it says: it stays on its last frame. }
      Stop;
      Exit;
    end;
  end;
  FFrame := FCompositor.NextFrame;
  ShowFrameChanged;
  FTimer.Interval := FrameDelay(FCompositor.CurrentIndex);
end;

{ --- Painting ---------------------------------------------------------------- }

function TPictureBox.PictureBounds: TRectangle;
begin
  if FFrame = nil then
    Exit(MakeRectangle(0, 0, 0, 0));
  Result := PicturePlacement(FSizeMode, Scaled(FFrame.Width), Scaled(FFrame.Height), RectangleWidth(PixelBounds),
    RectangleHeight(PixelBounds));
end;

{ The frame at Width x Height: itself at its own size, else resampled
  (kept until the frame or the size changes). A smoother filter for a
  still picture, a quicker one for an animation's frames. }
function TPictureBox.ResampledFrame(Width, Height: LongInt): TImage;
var
  Filter: TResamplingFilter;
begin
  if (Width = FFrame.Width) and (Height = FFrame.Height) then
    Exit(FFrame);
  if (FResampled <> nil) and (FResampledSerial = FFrameSerial) and (FResampled.Width = Width) and
     (FResampled.Height = Height) then
    Exit(FResampled);
  ForgetResampled;
  Filter := ResamplingMitchell;
  if FAnimation <> nil then
    Filter := ResamplingTriangle;
  FResampled := ResampleImage(FFrame, Width, Height, Filter);
  FResampledSerial := FFrameSerial;
  Result := FResampled;
end;

procedure TPictureBox.PaintError(var Canvas: TCanvas);
var
  Box: TRectangle;
  IconSize: LongInt;
  IconBox: TRectangle;
  TextTop: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  DrawRectangleOutline(Canvas, Box, Theme.Shadow);
  IconSize := Scaled(LargeIconSize);
  IconBox := MakeRectangle((RectangleWidth(Box) - IconSize) div 2,
    (RectangleHeight(Box) - IconSize - TextHeight(ControlFace)) div 2, IconSize, IconSize);
  DrawStockIcon(Canvas, StockIconFile, IconBox);
  TextTop := IconBox.Bottom + Scaled(4);
  DrawTextInBox(Canvas, ControlFace, FErrorText, MakeRectangle(Scaled(4), TextTop, RectangleWidth(Box) - Scaled(8),
    TextHeight(ControlFace)), AlignTextCenter, Theme.DisabledText);
end;

procedure TPictureBox.Paint(var Canvas: TCanvas);
var
  Place: TRectangle;
  Shown: TImage;
begin
  if AlphaOf(FColor) <> 0 then
    FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)), FColor);
  if FErrorText <> '' then
  begin
    PaintError(Canvas);
    Exit;
  end;
  if FFrame = nil then
    Exit;
  Place := PictureBounds;
  if RectangleIsEmpty(Place) then
    Exit;
  Shown := ResampledFrame(RectangleWidth(Place), RectangleHeight(Place));
  DrawSurface(Canvas, ImageSurface(Shown), MakeRectangle(0, 0, Shown.Width, Shown.Height), Place.Left, Place.Top,
    True, AlphaOpaque);
end;

end.
