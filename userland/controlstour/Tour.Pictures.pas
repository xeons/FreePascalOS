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
  The controls tour's Pictures page, a small picture viewer: a toolbar
  with pictures from the image list (play, stop, and a button that
  changes how the picture fits), a picture box playing an animation
  read from a file (Tour.Artwork writes it), a paint box the tour draws
  itself, moved on by a timer, and a list view showing the image list's
  pictures. Every control has a hint.

  It prints:

    picture N             the animation was read: N frames
    picture-error TEXT    it could not be
    tick N                the timer's first ticks (1 to 3)
    size-mode N           how the picture fits now (TPictureSizeMode)
    playing 0|1           the animation stopped or started
}
unit Tour.Pictures;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Window,
  Controls.TabControl,
  Controls.ToolBar,
  Controls.ListViewBase,
  Controls.ListView,
  Controls.PaintBox,
  Controls.PictureBox,
  Controls.ImageList,
  Controls.Timers;

type
  TPicturesPage = class
  private
    FWindow: TControlWindow;
    FPage: TControl;
    FToolBar: TToolBar;
    FPicture: TPictureBox;
    FPaintBox: TPaintBox;
    FList: TListView;
    FTimer: TTimer;
    FTicks: LongInt;
    procedure PlayClicked(Sender: TControl);
    procedure StopClicked(Sender: TControl);
    procedure FitClicked(Sender: TControl);
    procedure TimerTicked(Sender: TTimer);
    procedure PaintSpinner(Sender: TControl; var Canvas: TCanvas);
    procedure BuildList(Images: TImageList);
  public
    { A new page of Tabs, its pictures from Images (which must last as
      long as the page). }
    constructor Create(Window: TControlWindow; Tabs: TTabControl; Images: TImageList);
    destructor Destroy; override;
    { Where its controls are (the page is shown). }
    procedure TellPlaces;
    property Page: TControl read FPage;
  end;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.PictureGeometry,
  Tour.Artwork,
  Tour.Output;

const
  TickMilliseconds = 50;
  SpinnerColor = $FF3060C0;
  SpinnerDotColor = $FFF07820;

constructor TPicturesPage.Create(Window: TControlWindow; Tabs: TTabControl; Images: TImageList);
begin
  inherited Create;
  FWindow := Window;
  FPage := Tabs.AddPage('&Pictures');
  Tabs.PageImageIndex[Tabs.PageCount - 1] := PicturePicture;
  FToolBar := TToolBar.Create(FPage);
  FToolBar.Images := Images;
  FToolBar.AddImageButton(PlayPicture, '', 'Play the animation', 26, @PlayClicked);
  FToolBar.AddImageButton(StopPicture, '', 'Stop the animation', 26, @StopClicked);
  FToolBar.AddSeparator;
  FToolBar.AddImageButton(ZoomPicture, 'Fit', 'How the picture fits its box:'#10'normal, stretched, zoomed or centred',
    56, @FitClicked);
  FPicture := TPictureBox.Create(FPage);
  FPicture.SetBounds(8, 34, 200, 150);
  FPicture.SizeMode := PictureSizeZoom;
  FPicture.Hint := 'An animated picture (APNG)'#10'written by the tour and read back';
  if WriteTourAnimation and FPicture.LoadFromFile(AnimationFileName) then
    Say('picture ' + IntToStr(FPicture.FrameCount))
  else
    Say('picture-error ' + FPicture.ErrorText);
  FPaintBox := TPaintBox.Create(FPage);
  FPaintBox.SetBounds(216, 34, 100, 100);
  FPaintBox.Hint := 'A paint box the tour draws, moved on by a timer';
  FPaintBox.OnPaint := @PaintSpinner;
  BuildList(Images);
  FTimer := TTimer.Create(Window);
  FTimer.Interval := TickMilliseconds;
  FTimer.OnTimer := @TimerTicked;
end;

destructor TPicturesPage.Destroy;
begin
  FTimer.Free;
  inherited Destroy;
end;

procedure TPicturesPage.BuildList(Images: TImageList);
var
  Row: LongInt;
begin
  FList := TListView.Create(FPage);
  FList.SetBounds(324, 34, 140, 150);
  FList.AddColumn('Picture', 120);
  FList.Images := Images;
  FList.Hint := 'The image list''s pictures';
  Row := FList.AddRow(['Play']);
  FList.Items[Row].ImageIndex := PlayPicture;
  Row := FList.AddRow(['Stop']);
  FList.Items[Row].ImageIndex := StopPicture;
  Row := FList.AddRow(['Zoom']);
  FList.Items[Row].ImageIndex := ZoomPicture;
  Row := FList.AddRow(['Landscape']);
  FList.Items[Row].ImageIndex := PicturePicture;
  FList.ViewMode := ViewLargeIcons;
end;

procedure TPicturesPage.PlayClicked(Sender: TControl);
begin
  FPicture.Play;
  Say('playing ' + IntToStr(Ord(FPicture.Playing)));
end;

procedure TPicturesPage.StopClicked(Sender: TControl);
begin
  FPicture.Stop;
  Say('playing ' + IntToStr(Ord(FPicture.Playing)));
end;

{ Normal, stretched, zoomed, centred, and round again. }
procedure TPicturesPage.FitClicked(Sender: TControl);
begin
  if FPicture.SizeMode >= PictureSizeCenter then
    FPicture.SizeMode := PictureSizeNormal
  else
    FPicture.SizeMode := Succ(FPicture.SizeMode);
  Say('size-mode ' + IntToStr(Ord(FPicture.SizeMode)));
end;

procedure TPicturesPage.TimerTicked(Sender: TTimer);
begin
  Inc(FTicks);
  if FTicks <= 3 then
    Say('tick ' + IntToStr(FTicks));
  if FPage.Visible then
    FPaintBox.Invalidate;
end;

{ A ring with a dot going round it, a step each tick. }
procedure TPicturesPage.PaintSpinner(Sender: TControl; var Canvas: TCanvas);
var
  Size: LongInt;
  Radius: Double;
  Angle: Double;
  CentreX: Double;
  CentreY: Double;
  Dot: LongInt;
begin
  Size := FPaintBox.PixelWidth;
  if FPaintBox.PixelHeight < Size then
    Size := FPaintBox.PixelHeight;
  Dot := Scaled(12);
  Radius := (Size - Dot) / 2;
  CentreX := FPaintBox.PixelWidth / 2;
  CentreY := FPaintBox.PixelHeight / 2;
  DrawSmoothEllipseOutline(Canvas, MakeRectangle(Round(CentreX - Radius), Round(CentreY - Radius), Round(2 * Radius),
    Round(2 * Radius)), Scaled(2), SpinnerColor);
  Angle := FTicks * 2 * Pi / 40;
  FillSmoothEllipse(Canvas, MakeRectangle(Round(CentreX + Radius * Cos(Angle)) - Dot div 2,
    Round(CentreY + Radius * Sin(Angle)) - Dot div 2, Dot, Dot), SpinnerDotColor);
end;

procedure TPicturesPage.TellPlaces;
var
  Shown: TRectangle;
begin
  { The animation's border, two of its 64 pixels in from the left
    halfway down, and its transparent middle near the top left. }
  Shown := FPicture.PictureBounds;
  TellPlace(FWindow, 'picture-border', FPicture, Shown.Left + RectangleWidth(Shown) * 2 div AnimationWidth,
    Shown.Top + RectangleHeight(Shown) div 2);
  TellPlace(FWindow, 'picture-inside', FPicture, Shown.Left + RectangleWidth(Shown) * 10 div AnimationWidth,
    Shown.Top + RectangleHeight(Shown) * 10 div AnimationHeight);
  TellPlace(FWindow, 'picture-box', FPicture, RectangleWidth(FPicture.PixelBounds) div 2,
    RectangleHeight(FPicture.PixelBounds) div 2);
  TellPlace(FWindow, 'paint-box', FPaintBox, RectangleWidth(FPaintBox.PixelBounds) div 2,
    RectangleHeight(FPaintBox.PixelBounds) div 2);
  TellPlace(FWindow, 'fit-button', FToolBar.Children[3], RectangleWidth(FToolBar.Children[3].PixelBounds) div 2,
    RectangleHeight(FToolBar.Children[3].PixelBounds) div 2);
end;

end.
