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
  Sliders: a value from Minimum to Maximum, chosen by moving a thumb
  along a groove (a volume, the mouse's speed).

  A press on the groove puts the thumb there and drags it while the
  button is held; the arrow keys move it by one, Page Up and Page Down
  by PageStep, Home and End to the ends; the wheel steps too. Tick marks
  under the groove show the steps (every TickStep; none if 0). Each
  change is announced (OnChange, NotifyChanged); Tracking tells whether
  the thumb is being dragged, so a program can wait for it to be let go
  before doing something slow, which OnRelease tells.
}
unit Controls.Slider;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base;

type
  TSlider = class(TControl)
  private
    FMinimum: LongInt;
    FMaximum: LongInt;
    FPosition: LongInt;
    FPageStep: LongInt;
    FTickStep: LongInt;
    FTracking: Boolean;
    FOnRelease: TControlEvent;
    procedure SetPosition(Value: LongInt);
    function ThumbWidth: LongInt;
    function ThumbHeight: LongInt;
    { The pixels the thumb's middle travels between. }
    function TrackStart: LongInt;
    function TrackLength: LongInt;
    function ThumbMiddle: LongInt;
    function GrooveTop: LongInt;
    function PositionAt(X: LongInt): LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure FocusChanged; override;
  public
    constructor Create(AParent: TControl); override;
    function PreferredSize: TSize; override;
    procedure SetRange(Minimum, Maximum: LongInt);
    { The thumb's middle at Value, in the control's pixels: where a click
      sets that value. }
    function PixelOfValue(Value: LongInt): LongInt;
    property Minimum: LongInt read FMinimum;
    property Maximum: LongInt read FMaximum;
    property Position: LongInt read FPosition write SetPosition;
    property PageStep: LongInt read FPageStep write FPageStep;
    property TickStep: LongInt read FTickStep write FTickStep;
    property Tracking: Boolean read FTracking;
    property OnRelease: TControlEvent read FOnRelease write FOnRelease;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Buttons,
  Controls.LayoutRules;

const
  { Logical units. }
  ThumbLogicalWidth = 11;
  ThumbLogicalHeight = 20;
  GrooveLogicalHeight = 4;
  TickLogicalLength = 4;

constructor TSlider.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FMaximum := 100;
  FPageStep := 10;
  FTickStep := 10;
end;

const
  DefaultSliderWidth = 150;

{ As wide as it is (or a default); the thumb, and the ticks under it. }
function TSlider.PreferredSize: TSize;
var
  Width: LongInt;
begin
  Width := RectangleWidth(Bounds);
  if Width <= 0 then
    Width := DefaultSliderWidth;
  Result := MakeSize(Width, ThumbLogicalHeight + 2 + TickLogicalLength + 2);
end;

procedure TSlider.SetRange(Minimum, Maximum: LongInt);
begin
  if Maximum < Minimum then
    Maximum := Minimum;
  FMinimum := Minimum;
  FMaximum := Maximum;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TSlider.SetPosition(Value: LongInt);
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

function TSlider.ThumbWidth: LongInt;
begin
  Result := Scaled(ThumbLogicalWidth);
end;

function TSlider.ThumbHeight: LongInt;
begin
  Result := Scaled(ThumbLogicalHeight);
  if Result > RectangleHeight(PixelBounds) then
    Result := RectangleHeight(PixelBounds);
end;

function TSlider.TrackStart: LongInt;
begin
  Result := ThumbWidth div 2 + Scaled(2);
end;

function TSlider.TrackLength: LongInt;
begin
  Result := RectangleWidth(PixelBounds) - 2 * TrackStart;
  if Result < 1 then
    Result := 1;
end;

function TSlider.PixelOfValue(Value: LongInt): LongInt;
begin
  Result := TrackStart;
  if FMaximum > FMinimum then
    Result := Result + Int64(TrackLength) * (Value - FMinimum) div (FMaximum - FMinimum);
end;

function TSlider.ThumbMiddle: LongInt;
begin
  Result := PixelOfValue(FPosition);
end;

function TSlider.GrooveTop: LongInt;
begin
  Result := ThumbHeight div 2 - Scaled(GrooveLogicalHeight) div 2;
end;

function TSlider.PositionAt(X: LongInt): LongInt;
begin
  if FMaximum = FMinimum then
    Exit(FMinimum);
  { To the nearest value. }
  Result := FMinimum + (Int64(X - TrackStart) * (FMaximum - FMinimum) * 2 + TrackLength) div (2 * TrackLength);
end;

procedure TSlider.Paint(var Canvas: TCanvas);
var
  Groove: TRectangle;
  Thumb: TRectangle;
  Value: LongInt;
  TickTop: LongInt;
  TickX: LongInt;
begin
  Groove := MakeRectangle(TrackStart - Scaled(2), GrooveTop, TrackLength + Scaled(4), Scaled(GrooveLogicalHeight));
  FillRectangle(Canvas, Groove, Theme.Field);
  DrawBevel(Canvas, Groove, SunkenThemeBevel);
  if (FTickStep > 0) and (FMaximum > FMinimum) then
  begin
    TickTop := ThumbHeight + Scaled(2);
    Value := FMinimum;
    while Value <= FMaximum do
    begin
      TickX := PixelOfValue(Value);
      FillRectangle(Canvas, MakeRectangle(TickX, TickTop, 1, Scaled(TickLogicalLength)), Theme.Shadow);
      Value := Value + FTickStep;
    end;
  end;
  Thumb := MakeRectangle(ThumbMiddle - ThumbWidth div 2, 0, ThumbWidth, ThumbHeight);
  DrawButtonFace(Canvas, Thumb, False, False);
  if Focused then
    DrawFocusFrame(Canvas, InflateRectangle(Thumb, -Scaled(3)), Theme.FaceText);
end;

procedure TSlider.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if (Button <> ButtonLeft) or not Enabled then
    Exit;
  SetFocus;
  FTracking := True;
  Position := PositionAt(X);
end;

procedure TSlider.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if FTracking then
    Position := PositionAt(X);
end;

procedure TSlider.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if not FTracking then
    Exit;
  FTracking := False;
  if Assigned(FOnRelease) then
    FOnRelease(Self);
end;

procedure TSlider.Wheel(Steps: LongInt);
begin
  Position := FPosition + Steps;
  if Assigned(FOnRelease) then
    FOnRelease(Self);
end;

function TSlider.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  case Code of
    KeyArrowLeft, KeyArrowDown: Position := FPosition - 1;
    KeyArrowRight, KeyArrowUp: Position := FPosition + 1;
    KeyPageUp: Position := FPosition + FPageStep;
    KeyPageDown: Position := FPosition - FPageStep;
    KeyHome: Position := FMinimum;
    KeyEnd: Position := FMaximum;
  else
    Exit(False);
  end;
  if Assigned(FOnRelease) then
    FOnRelease(Self);
end;

procedure TSlider.FocusChanged;
begin
  inherited FocusChanged;
  Invalidate;
end;

end.
