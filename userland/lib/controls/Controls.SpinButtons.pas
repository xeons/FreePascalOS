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
  Spin buttons: an up and a down button, one above the other, beside a
  box whose value they step (a numeric up/down box, a time picker).

  A press on either half steps once (OnStep, +1 for up, -1 for down)
  and, held, again and again (Controls.AutoRepeat) while the pointer
  stays on that half. They never take the focus: the box beside them
  keeps it.
}
unit Controls.SpinButtons;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.AutoRepeat;

type
  TStepEvent = procedure(Sender: TControl; Steps: LongInt) of object;

  TSpinButtons = class(TControl)
  private
    { The half held: +1 up, -1 down, 0 none; whether the pointer is
      still on it. }
    FHeld: LongInt;
    FPointerOnHeld: Boolean;
    FRepeat: TAutoRepeat;
    FOnStep: TStepEvent;
    function HalfAt(X, Y: LongInt): LongInt;
    function HalfBounds(Half: LongInt): TRectangle;
    procedure Repeated(Sender: TControl);
    procedure Release;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure EnabledChanged; override;
    procedure Step(Steps: LongInt); virtual;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    property OnStep: TStepEvent read FOnStep write FOnStep;
  end;

{ A small solid triangle pointing up (or down) in the middle of Box. }
procedure DrawSpinArrow(const Canvas: TCanvas; const Box: TRectangle; Up, Enabled: Boolean);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Buttons;

procedure DrawSpinArrow(const Canvas: TCanvas; const Box: TRectangle; Up, Enabled: Boolean);
var
  Arrow: array[0..2] of TPoint;
  CentreX: LongInt;
  CentreY: LongInt;
  Size: LongInt;
  Color: TColor;
begin
  CentreX := Box.Left + RectangleWidth(Box) div 2;
  CentreY := Box.Top + RectangleHeight(Box) div 2;
  Size := Scaled(3);
  if Size > RectangleHeight(Box) div 2 then
    Size := RectangleHeight(Box) div 2;
  if Up then
  begin
    Arrow[0] := MakePoint(CentreX - Size, CentreY + Size div 2 + 1);
    Arrow[1] := MakePoint(CentreX + Size + 1, CentreY + Size div 2 + 1);
    Arrow[2] := MakePoint(CentreX, CentreY - Size div 2 - 1);
  end
  else
  begin
    Arrow[0] := MakePoint(CentreX - Size, CentreY - Size div 2);
    Arrow[1] := MakePoint(CentreX + Size + 1, CentreY - Size div 2);
    Arrow[2] := MakePoint(CentreX, CentreY + Size div 2 + 2);
  end;
  if Enabled then
    Color := Theme.FaceText
  else
    Color := Theme.DisabledText;
  FillPolygon(Canvas, Arrow, Color);
end;

constructor TSpinButtons.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FRepeat := TAutoRepeat.Create(Self, @Repeated);
end;

destructor TSpinButtons.Destroy;
begin
  FRepeat.Free;
  inherited Destroy;
end;

function TSpinButtons.HalfBounds(Half: LongInt): TRectangle;
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := RectangleWidth(PixelBounds);
  Height := RectangleHeight(PixelBounds);
  if Half > 0 then
    Result := MakeRectangle(0, 0, Width, Height div 2)
  else
    Result := MakeRectangle(0, Height div 2, Width, Height - Height div 2);
end;

function TSpinButtons.HalfAt(X, Y: LongInt): LongInt;
begin
  if (X < 0) or (X >= RectangleWidth(PixelBounds)) or (Y < 0) or (Y >= RectangleHeight(PixelBounds)) then
    Exit(0);
  if Y < RectangleHeight(PixelBounds) div 2 then
    Result := 1
  else
    Result := -1;
end;

procedure TSpinButtons.Step(Steps: LongInt);
begin
  if Assigned(FOnStep) then
    FOnStep(Self, Steps);
end;

procedure TSpinButtons.Repeated(Sender: TControl);
begin
  if (FHeld <> 0) and FPointerOnHeld and Enabled then
    Step(FHeld);
end;

procedure TSpinButtons.Release;
begin
  FRepeat.Stop;
  FHeld := 0;
  Invalidate;
end;

procedure TSpinButtons.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FHeld := HalfAt(X, Y);
  if FHeld = 0 then
    Exit;
  FPointerOnHeld := True;
  Invalidate;
  Step(FHeld);
  FRepeat.Start;
end;

procedure TSpinButtons.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  OnHeld: Boolean;
begin
  if FHeld = 0 then
    Exit;
  OnHeld := HalfAt(X, Y) = FHeld;
  if OnHeld <> FPointerOnHeld then
  begin
    FPointerOnHeld := OnHeld;
    Invalidate;
  end;
end;

procedure TSpinButtons.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if Button = ButtonLeft then
    Release;
end;

procedure TSpinButtons.EnabledChanged;
begin
  Release;
end;

procedure TSpinButtons.Paint(var Canvas: TCanvas);
var
  Half: LongInt;
  Box: TRectangle;
  Pressed: Boolean;
  Shift: LongInt;
begin
  Half := 1;
  while Half >= -1 do
  begin
    Box := HalfBounds(Half);
    Pressed := (FHeld = Half) and FPointerOnHeld;
    DrawButtonFace(Canvas, Box, Pressed, False);
    Shift := 0;
    if Pressed then
      Shift := 1;
    DrawSpinArrow(Canvas, OffsetRectangle(Box, Shift, Shift), Half > 0, Enabled);
    Half := Half - 2;
  end;
end;

end.
