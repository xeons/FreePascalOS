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
  Progress bars: how far along something is, as blocks filling a sunken
  well from the left (each block a gradient in the theme's colours). A
  marquee (Marquee) says only that something is going on: diagonal
  stripes that move along the well, on a timer of its own.
}
unit Controls.ProgressBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base,
  Controls.Timers;

type
  TProgressBar = class(TControl)
  private
    FMinimum: LongInt;
    FMaximum: LongInt;
    FPosition: LongInt;
    FMarquee: Boolean;
    FMarqueeTimer: TTimer;
    { Pixels: how far the stripes have moved. }
    FMarqueeOffset: LongInt;
    procedure SetPosition(Value: LongInt);
    procedure SetMaximum(Value: LongInt);
    procedure SetMarquee(Value: Boolean);
    procedure MarqueeTicked(Sender: TTimer);
    procedure PaintBlocks(const Canvas: TCanvas; const Well: TRectangle);
    procedure PaintStripes(const Canvas: TCanvas; const Well: TRectangle);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function PreferredSize: TSize; override;
    property Minimum: LongInt read FMinimum write FMinimum;
    property Maximum: LongInt read FMaximum write SetMaximum;
    property Position: LongInt read FPosition write SetPosition;
    { Moving stripes instead of blocks (Position is not shown). }
    property Marquee: Boolean read FMarquee write SetMarquee;
  end;

implementation

uses
  Drawing.Colors,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.LayoutRules,
  Controls.Painting;

const
  { Logical units. }
  DefaultProgressWidth = 150;
  ProgressHeight = 18;
  { Logical units: a block and the gap after it; the stripes' period
    and width. Milliseconds between the stripes' steps. }
  BlockWidth = 8;
  BlockGap = 2;
  StripePeriod = 16;
  StripeWidth = 8;
  MarqueeInterval = 40;

{ As wide as it is (or a default), a block high. }
function TProgressBar.PreferredSize: TSize;
var
  Width: LongInt;
begin
  Width := RectangleWidth(Bounds);
  if Width <= 0 then
    Width := DefaultProgressWidth;
  Result := MakeSize(Width, ProgressHeight);
end;

constructor TProgressBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FMaximum := 100;
end;

procedure TProgressBar.SetPosition(Value: LongInt);
begin
  if Value < FMinimum then
    Value := FMinimum;
  if Value > FMaximum then
    Value := FMaximum;
  if Value = FPosition then
    Exit;
  FPosition := Value;
  Invalidate;
  Changed;
end;

procedure TProgressBar.SetMaximum(Value: LongInt);
begin
  FMaximum := Value;
  SetPosition(FPosition);
  Invalidate;
end;

destructor TProgressBar.Destroy;
begin
  FMarqueeTimer.Free;
  inherited Destroy;
end;

procedure TProgressBar.SetMarquee(Value: Boolean);
begin
  if FMarquee = Value then
    Exit;
  FMarquee := Value;
  if FMarqueeTimer = nil then
  begin
    FMarqueeTimer := TTimer.Create(Self);
    FMarqueeTimer.Enabled := False;
    FMarqueeTimer.Interval := MarqueeInterval;
    FMarqueeTimer.OnTimer := @MarqueeTicked;
  end;
  if Value then
    FMarqueeTimer.Start
  else
    FMarqueeTimer.Stop;
  Invalidate;
end;

procedure TProgressBar.MarqueeTicked(Sender: TTimer);
begin
  FMarqueeOffset := (FMarqueeOffset + Scaled(1)) mod Scaled(StripePeriod);
  Invalidate;
end;

procedure TProgressBar.PaintBlocks(const Canvas: TCanvas; const Well: TRectangle);
var
  Filled: LongInt;
  Width: LongInt;
  X: LongInt;
begin
  if FMaximum <= FMinimum then
    Exit;
  Filled := Int64(RectangleWidth(Well)) * (FPosition - FMinimum) div (FMaximum - FMinimum);
  X := 0;
  while X < Filled do
  begin
    Width := Scaled(BlockWidth);
    if X + Width > Filled then
      Width := Filled - X;
    FillVerticalGradient(Canvas, MakeRectangle(Well.Left + X, Well.Top, Width, RectangleHeight(Well)),
      Theme.ProgressBlockLight, Theme.ProgressBlock);
    X := X + Width + Scaled(BlockGap);
  end;
end;

{ Stripes leaning right: on each row they start a pixel further left
  than on the row above, and all move right with the offset. }
procedure TProgressBar.PaintStripes(const Canvas: TCanvas; const Well: TRectangle);
var
  Clipped: TCanvas;
  Period: LongInt;
  Width: LongInt;
  Y: LongInt;
  Start: LongInt;
begin
  Clipped := Canvas;
  NarrowCanvasClip(Clipped, Well);
  FillRectangle(Clipped, Well, Theme.MarqueeBackground);
  Period := Scaled(StripePeriod);
  Width := Scaled(StripeWidth);
  if Period <= 0 then
    Exit;
  for Y := Well.Top to Well.Bottom - 1 do
  begin
    { The first start at or left of Well.Left - Period. }
    Start := (FMarqueeOffset - (Y - Well.Top)) mod Period;
    if Start < 0 then
      Start := Start + Period;
    Start := Well.Left - 2 * Period + Start;
    while Start < Well.Right do
    begin
      FillSpan(Clipped, Y, Start, Start + Width, Theme.MarqueeStripe);
      Start := Start + Period;
    end;
  end;
end;

procedure TProgressBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Well: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.ProgressTrough);
  DrawSunkenEdge(Canvas, Box);
  Well := InflateRectangle(Box, -Scaled(2));
  if FMarquee then
    PaintStripes(Canvas, Well)
  else
    PaintBlocks(Canvas, Well);
end;

end.
