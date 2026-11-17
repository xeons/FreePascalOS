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
  Paint boxes: a place in a window that the program draws itself, in
  OnPaint (the canvas's origin at the box's top left, clipped to it;
  PixelWidth x PixelHeight pixels).

  A paint box never takes the focus and has no background of its own:
  what is behind it (its parent) shows through wherever OnPaint does
  not draw, unless Color is set (any colour with alpha), which fills it
  first. It is painted again whole whenever its size changes.
  Invalidate asks for painting when the message loop next gets to it;
  Repaint paints at once.
}
unit Controls.PaintBox;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Controls.Base;

type
  TPaintBox = class(TControl)
  private
    FColor: TColor;
    FPaintedWidth: LongInt;
    FPaintedHeight: LongInt;
    procedure SetColor(Value: TColor);
    function GetPixelWidth: LongInt;
    function GetPixelHeight: LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    { Invalidates the box and paints the window now. }
    procedure Repaint;
    { The background (transparent, the default: none). }
    property Color: TColor read FColor write SetColor;
    { Its size in pixels: what OnPaint draws in. }
    property PixelWidth: LongInt read GetPixelWidth;
    property PixelHeight: LongInt read GetPixelHeight;
  end;

implementation

uses
  Drawing.Rectangles,
  Windowing.Windows;

constructor TPaintBox.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := False;
  FColor := ColorTransparent;
end;

procedure TPaintBox.SetColor(Value: TColor);
begin
  if FColor = Value then
    Exit;
  FColor := Value;
  Invalidate;
end;

function TPaintBox.GetPixelWidth: LongInt;
begin
  Result := RectangleWidth(PixelBounds);
end;

function TPaintBox.GetPixelHeight: LongInt;
begin
  Result := RectangleHeight(PixelBounds);
end;

procedure TPaintBox.Paint(var Canvas: TCanvas);
begin
  if AlphaOf(FColor) <> 0 then
    FillRectangle(Canvas, MakeRectangle(0, 0, PixelWidth, PixelHeight), FColor);
end;

{ A new size: painted again whole (a drawing made for the old size would
  otherwise stay where it is not covered). }
procedure TPaintBox.Layout;
begin
  inherited Layout;
  if (PixelWidth = FPaintedWidth) and (PixelHeight = FPaintedHeight) then
    Exit;
  FPaintedWidth := PixelWidth;
  FPaintedHeight := PixelHeight;
  Invalidate;
end;

procedure TPaintBox.Repaint;
begin
  Invalidate;
  if (Host <> nil) and (Host.OwnerWindow is TWindow) then
    TWindow(Host.OwnerWindow).PaintNow;
end;

end.
