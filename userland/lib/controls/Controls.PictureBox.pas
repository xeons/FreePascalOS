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
  Color is set, which fills the box first.

  Zoom (1 unless set) shows the picture at that multiple of its size in
  the normal, centred and AutoSize modes, and the box's preferred size
  follows it, so a zoomed picture in a scrolling panel scrolls (the
  image viewer). Large or strongly enlarged pictures are not resampled
  whole: only what the clip leaves visible is drawn, pixel by pixel
  (nearest neighbour), so 3200 % of a large photo costs no more than
  the window. Orientation turns or mirrors what is shown (EXIF's eight,
  Image.Orientation), every frame of an animation too; ShowFrame shows
  one frame of an animation, stopped. An animation (GIF, APNG,
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
    FZoom: Double;
    FOrientation: TImageOrientation;
    { The frame turned as Orientation says, for FOrientedSerial. }
    FOriented: TImage;
    FOrientedSerial: LongWord;
    procedure SetZoom(Value: Double);
    procedure SetOrientation(Value: TImageOrientation);
    function ZoomedSize(Logical: LongInt): LongInt;
    procedure PreferredSizeChanged;
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
    function PreferredSize: TSize; override;
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
    { Stops the animation and shows its frame Index (0 to FrameCount - 1). }
    procedure ShowFrame(Index: LongInt);
    { The picture as shown now: the image, or the animation's frame,
      turned as Orientation says (the box's; nil if none). }
    function CurrentPicture: TImage;
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
    { The multiple of its size the picture is shown at (normal, centre
      and AutoSize; above 0). }
    property Zoom: Double read FZoom write SetZoom;
    { How what is shown is turned (normal unless set). }
    property Orientation: TImageOrientation read FOrientation write SetOrientation;
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
  Image.Orientation,
  Controls.Icons,
  Controls.Text,
  Controls.LayoutRules;

const
  { Milliseconds a frame with no delay (or a very short one) is shown,
    as browsers do. }
  ShortestFrameDelay = 20;
  DefaultFrameDelay = 100;
  { Pixels: a picture shown larger than this is drawn as the clip
    leaves it (nearest neighbour) rather than resampled whole. }
  LargestResampledPixels = 4 * 1024 * 1024;
  { Enlarged this many times or more, pixels are shown as squares. }
  PixelatedZoom = 3.0;

constructor TPictureBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FColor := ColorTransparent;
  FAutoPlay := True;
  FSizeMode := PictureSizeNormal;
  FZoom := 1;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerTicked;
end;

destructor TPictureBox.Destroy;
begin
  { ReleaseImage stops the timer: it goes after. }
  ReleaseImage;
  FTimer.Free;
  inherited Destroy;
end;

procedure TPictureBox.ForgetResampled;
begin
  FreeAndNil(FResampled);
  FreeAndNil(FOriented);
end;

{ The box's preferred size changed: its parent places it again. }
procedure TPictureBox.PreferredSizeChanged;
begin
  if AutoSize and (Parent <> nil) then
    Parent.RequestLayout;
end;

procedure TPictureBox.SetZoom(Value: Double);
begin
  if (Value <= 0) or (Value = FZoom) then
    Exit;
  FZoom := Value;
  ForgetResampled;
  FitBoxToPicture;
  PreferredSizeChanged;
  Invalidate;
end;

procedure TPictureBox.SetOrientation(Value: TImageOrientation);
begin
  if Value = FOrientation then
    Exit;
  FOrientation := Value;
  ForgetResampled;
  Inc(FFrameSerial);
  FitBoxToPicture;
  PreferredSizeChanged;
  Invalidate;
end;

{ The frame as it is shown: turned as Orientation says (kept until the
  frame or the orientation changes). }
function TPictureBox.CurrentPicture: TImage;
var
  Stored: TImageOrientation;
begin
  if (FFrame = nil) or (FOrientation = OrientationNormal) then
    Exit(FFrame);
  if (FOriented <> nil) and (FOrientedSerial = FFrameSerial) then
    Exit(FOriented);
  FreeAndNil(FOriented);
  Stored := FFrame.Orientation;
  FFrame.Orientation := FOrientation;
  try
    FOriented := OrientedImage(FFrame);
  finally
    FFrame.Orientation := Stored;
  end;
  FOrientedSerial := FFrameSerial;
  Result := FOriented;
end;

{ Logical units: a size of the picture zoomed. }
function TPictureBox.ZoomedSize(Logical: LongInt): LongInt;
begin
  Result := Round(Logical * FZoom);
  if Result < 1 then
    Result := 1;
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
  PreferredSizeChanged;
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
  PreferredSizeChanged;
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
  if FFrame = nil then
    Exit;
  if OrientationSwapsSides(FOrientation) then
    Result := FFrame.Height
  else
    Result := FFrame.Width;
end;

function TPictureBox.PictureHeight: LongInt;
begin
  Result := 0;
  if FFrame = nil then
    Exit;
  if OrientationSwapsSides(FOrientation) then
    Result := FFrame.Width
  else
    Result := FFrame.Height;
end;

{ AutoSize: the box takes the picture's size, where it is. }
{ The picture's size (its size now if there is none). }
function TPictureBox.PreferredSize: TSize;
begin
  if (PictureWidth <= 0) or (PictureHeight <= 0) then
    Result := inherited PreferredSize
  else
    Result := MakeSize(ZoomedSize(PictureWidth), ZoomedSize(PictureHeight));
end;

procedure TPictureBox.FitBoxToPicture;
begin
  if (FSizeMode <> PictureSizeAuto) or (FFrame = nil) then
    Exit;
  SetBounds(Bounds.Left, Bounds.Top, ZoomedSize(PictureWidth), ZoomedSize(PictureHeight));
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

procedure TPictureBox.ShowFrame(Index: LongInt);
begin
  if (FCompositor = nil) or (Index < 0) or (Index >= FAnimation.FrameCount) then
    Exit;
  Stop;
  FFrame := FCompositor.RenderFrame(Index);
  ShowFrameChanged;
end;

{ Whether it is on the screen: it and every parent visible (not on a
  tab control's hidden page, say). }
function ShownOnScreen(Control: TControl): Boolean;
begin
  while Control <> nil do
  begin
    if not Control.Visible then
      Exit(False);
    Control := Control.Parent;
  end;
  Result := True;
end;

procedure TPictureBox.ShowFrameChanged;
begin
  Inc(FFrameSerial);
  { (A frame not on the screen needs no painting.) }
  if ShownOnScreen(Self) then
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
  if FSizeMode in [PictureSizeStretch, PictureSizeZoom] then
    Result := PicturePlacement(FSizeMode, Scaled(PictureWidth), Scaled(PictureHeight), RectangleWidth(PixelBounds),
      RectangleHeight(PixelBounds))
  else
    Result := PicturePlacement(FSizeMode, Scaled(ZoomedSize(PictureWidth)), Scaled(ZoomedSize(PictureHeight)),
      RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
end;

{ The frame at Width x Height: itself at its own size, else resampled
  (kept until the frame or the size changes). A smoother filter for a
  still picture, a quicker one for an animation's frames. }
function TPictureBox.ResampledFrame(Width, Height: LongInt): TImage;
var
  Filter: TResamplingFilter;
  Shown: TImage;
begin
  Shown := CurrentPicture;
  if (Width = Shown.Width) and (Height = Shown.Height) then
    Exit(Shown);
  if (FResampled <> nil) and (FResampledSerial = FFrameSerial) and (FResampled.Width = Width) and
     (FResampled.Height = Height) then
    Exit(FResampled);
  FreeAndNil(FResampled);
  Filter := ResamplingMitchell;
  if FAnimation <> nil then
    Filter := ResamplingTriangle;
  FResampled := ResampleImage(Shown, Width, Height, Filter);
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
  { Large or much enlarged: only what shows, pixel by pixel. }
  Shown := CurrentPicture;
  if (Int64(RectangleWidth(Place)) * RectangleHeight(Place) > LargestResampledPixels) or
     (RectangleWidth(Place) >= PixelatedZoom * Shown.Width) then
  begin
    DrawSurfaceStretched(Canvas, ImageSurface(Shown), MakeRectangle(0, 0, Shown.Width, Shown.Height), Place, True);
    Exit;
  end;
  Shown := ResampledFrame(RectangleWidth(Place), RectangleHeight(Place));
  DrawSurface(Canvas, ImageSurface(Shown), MakeRectangle(0, 0, Shown.Width, Shown.Height), Place.Left, Place.Top,
    True, AlphaOpaque);
end;

end.
