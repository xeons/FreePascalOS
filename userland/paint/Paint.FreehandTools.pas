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
  The tools that draw where the pointer goes while a button is held
  (Paint.Brushes makes their marks): the pencil, the brush, the eraser
  (always the secondary colour, or the primary with the right button)
  and the airbrush. A stroke, from press to release, is one edit.
}
unit Paint.FreehandTools;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Paint.Tools;

type
  TFreehandTool = class(TPaintTool)
  private
    FButton: LongWord;
    FLastX: Double;
    FLastY: Double;
  protected
    { A mark from (FromX, FromY) to (ToX, ToY) (image coordinates). }
    procedure DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor); virtual; abstract;
    function StrokeColor(Button: LongWord): TColor; virtual;
  public
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); override;
    procedure PointerUp(X, Y: Double; Button, Modifiers: LongWord); override;
  end;

  TPencilTool = class(TFreehandTool)
  protected
    procedure DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor); override;
  end;

  TBrushTool = class(TFreehandTool)
  protected
    procedure DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor); override;
  end;

  TEraserTool = class(TFreehandTool)
  protected
    procedure DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor); override;
    function StrokeColor(Button: LongWord): TColor; override;
  end;

  TAirbrushTool = class(TFreehandTool)
  private
    FSeed: LongWord;
  protected
    procedure DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor); override;
  end;

implementation

uses
  Math,
  Drawing.Rectangles,
  Paint.ToolKinds,
  Paint.ShapeGeometry,
  Paint.Brushes;

function TFreehandTool.StrokeColor(Button: LongWord): TColor;
begin
  Result := ColorFor(Button);
end;

procedure TFreehandTool.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
begin
  if Editing then
    Exit;
  FButton := Button;
  BeginEdit;
  FLastX := X;
  FLastY := Y;
  DrawSegment(X, Y, X, Y, StrokeColor(Button));
end;

procedure TFreehandTool.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
begin
  if not Editing then
    Exit;
  DrawSegment(FLastX, FLastY, X, Y, StrokeColor(FButton));
  FLastX := X;
  FLastY := Y;
end;

procedure TFreehandTool.PointerUp(X, Y: Double; Button, Modifiers: LongWord);
begin
  if Editing and (Button = FButton) then
    CommitEdit('Draw');
end;

procedure TPencilTool.DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor);
var
  Ends: array[0..1] of TPoint;
begin
  Ends[0] := MakePoint(PixelOf(FromX), PixelOf(FromY));
  Ends[1] := MakePoint(PixelOf(ToX), PixelOf(ToY));
  DrawPencilLine(ImageCanvas, Ends[0].X, Ends[0].Y, Ends[1].X, Ends[1].Y, Color);
  Touch(StrokeExtent(Ends, 1));
end;

procedure TBrushTool.DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor);
var
  Size: LongInt;
  Ends: array[0..1] of TPoint;
begin
  Size := FSession.ToolSize(ToolBrush);
  { Centre coordinates: the middle of pixel P is P. }
  DrawBrushLine(ImageCanvas, FromX - 0.5, FromY - 0.5, ToX - 0.5, ToY - 0.5, Size, Color);
  Ends[0] := MakePoint(PixelOf(FromX), PixelOf(FromY));
  Ends[1] := MakePoint(PixelOf(ToX), PixelOf(ToY));
  Touch(StrokeExtent(Ends, Size + 1));
end;

function TEraserTool.StrokeColor(Button: LongWord): TColor;
begin
  Result := OtherColorFor(Button);
end;

procedure TEraserTool.DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor);
var
  Size: LongInt;
  FromPixel: TPoint;
  ToPixel: TPoint;
begin
  Size := FSession.ToolSize(ToolEraser);
  FromPixel := MakePoint(PixelOf(FromX), PixelOf(FromY));
  ToPixel := MakePoint(PixelOf(ToX), PixelOf(ToY));
  DrawEraserLine(ImageCanvas, FromPixel.X, FromPixel.Y, ToPixel.X, ToPixel.Y, Size, Color);
  Touch(BoundingRectangle(EraserSquare(FromPixel.X, FromPixel.Y, Size), EraserSquare(ToPixel.X, ToPixel.Y, Size)));
end;

procedure TAirbrushTool.DrawSegment(FromX, FromY, ToX, ToY: Double; Color: TColor);
var
  Size: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  Size := FSession.ToolSize(ToolAirbrush);
  if FSeed = 0 then
    FSeed := LongWord(Abs(Round(ToX * 7919 + ToY * 104729)) and $7FFFFFFF) or 1;
  X := PixelOf(ToX);
  Y := PixelOf(ToY);
  SprayAirbrush(ImageCanvas, X, Y, Size, Color, FSeed);
  Touch(AirbrushExtent(X, Y, Size));
end;

end.
