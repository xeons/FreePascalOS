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
  The selection tools, and the text tool, which places its text as a
  floating selection.

  A press inside the selection drags it: its pixels are lifted (their
  place takes the secondary colour; with Ctrl held they are copied and
  stay) and follow the pointer. A press elsewhere puts down what floats
  and starts a new selection: a rectangle dragged from corner to corner
  (Shift: a square), or with the free-form tool a line drawn round what
  is wanted (closed back to its start when the button is let go). A
  click without a drag selects nothing. The arrow keys move what is
  selected a pixel at a time (lifting it first); Escape puts it down and
  selects nothing; Delete clears it to the secondary colour.

  The text tool asks for its text where the picture is pressed (the
  window shows a dialog and draws the text in the primary colour) and
  floats it there, to be dragged into place; a press elsewhere puts it
  down.
}
unit Paint.SelectionTools;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Paint.ZoomMapping,
  Paint.ShapeGeometry,
  Paint.Tools;

type
  TSelectionToolBase = class(TPaintTool)
  private
    FMoving: Boolean;
    FLastPixel: TPoint;
    procedure MoveSelection(DeltaX, DeltaY: LongInt);
    procedure DeleteSelected;
  protected
    FSelecting: Boolean;
    { A press outside the selection, everything put down already. }
    procedure StartNew(const Pixel: TPoint; Modifiers: LongWord); virtual; abstract;
    procedure ContinueNew(const Pixel: TPoint; Modifiers: LongWord); virtual; abstract;
    procedure EndNew(const Pixel: TPoint); virtual; abstract;
  public
    procedure PointerDown(X, Y: Double; Button, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: Double; Buttons, Modifiers: LongWord); override;
    procedure PointerUp(X, Y: Double; Button, Modifiers: LongWord); override;
    function KeyDown(Code, Modifiers: LongWord): Boolean; override;
    procedure Finish; override;
    procedure Cancel; override;
    function Busy: Boolean; override;
  end;

  TRectangleSelectTool = class(TSelectionToolBase)
  private
    FStart: TPoint;
    procedure SelectTo(const Pixel: TPoint; Modifiers: LongWord);
  protected
    procedure StartNew(const Pixel: TPoint; Modifiers: LongWord); override;
    procedure ContinueNew(const Pixel: TPoint; Modifiers: LongWord); override;
    procedure EndNew(const Pixel: TPoint); override;
  end;

  TFreeFormSelectTool = class(TSelectionToolBase)
  private
    FPoints: TPointArray;
  protected
    procedure StartNew(const Pixel: TPoint; Modifiers: LongWord); override;
    procedure ContinueNew(const Pixel: TPoint; Modifiers: LongWord); override;
    procedure EndNew(const Pixel: TPoint); override;
  public
    procedure DrawOverlay(const Canvas: TCanvas; const Mapping: TViewMapping); override;
  end;

  TTextTool = class(TSelectionToolBase)
  protected
    procedure StartNew(const Pixel: TPoint; Modifiers: LongWord); override;
    procedure ContinueNew(const Pixel: TPoint; Modifiers: LongWord); override;
    procedure EndNew(const Pixel: TPoint); override;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Shapes,
  Image.Model,
  Controls.Keys;

{ --- Moving --------------------------------------------------------------------------------- }

procedure TSelectionToolBase.MoveSelection(DeltaX, DeltaY: LongInt);
var
  Before: TRectangle;
begin
  Before := FSession.Editor.Area;
  FSession.Editor.MoveBy(DeltaX, DeltaY);
  FSession.ImageChanged(BoundingRectangle(InflateRectangle(Before, 1), InflateRectangle(FSession.Editor.Area, 1)));
end;

{ Clears the selected pixels to the secondary colour (the Delete key). }
procedure TSelectionToolBase.DeleteSelected;
var
  Area: TRectangle;
begin
  Area := FSession.Editor.Area;
  FSession.Editor.DeleteSelected(FSession.SecondaryColor);
  FSession.ImageChanged(InflateRectangle(Area, 1));
end;

procedure TSelectionToolBase.PointerDown(X, Y: Double; Button, Modifiers: LongWord);
var
  Pixel: TPoint;
begin
  if FMoving or FSelecting then
    Exit;
  Pixel := MakePoint(PixelOf(X), PixelOf(Y));
  if (Button = ButtonLeft) and FSession.Editor.Selection.Contains(Pixel.X, Pixel.Y) then
  begin
    FSession.Editor.Lift((Modifiers and ModifierControl) <> 0, FSession.SecondaryColor);
    FSession.ImageChanged(InflateRectangle(FSession.Editor.Area, 1));
    FMoving := True;
    FLastPixel := Pixel;
    Exit;
  end;
  FSession.ImageChanged(InflateRectangle(FSession.Editor.Area, 1));
  FSession.Editor.Deselect;
  FSelecting := True;
  StartNew(Pixel, Modifiers);
end;

procedure TSelectionToolBase.PointerMove(X, Y: Double; Buttons, Modifiers: LongWord);
var
  Pixel: TPoint;
begin
  Pixel := MakePoint(PixelOf(X), PixelOf(Y));
  if FMoving then
  begin
    if (Pixel.X <> FLastPixel.X) or (Pixel.Y <> FLastPixel.Y) then
      MoveSelection(Pixel.X - FLastPixel.X, Pixel.Y - FLastPixel.Y);
    FLastPixel := Pixel;
  end
  else if FSelecting then
    ContinueNew(Pixel, Modifiers);
end;

procedure TSelectionToolBase.PointerUp(X, Y: Double; Button, Modifiers: LongWord);
var
  Pixel: TPoint;
begin
  Pixel := MakePoint(PixelOf(X), PixelOf(Y));
  if FMoving then
  begin
    PointerMove(X, Y, 0, Modifiers);
    FMoving := False;
  end
  else if FSelecting then
  begin
    FSelecting := False;
    EndNew(Pixel);
  end;
end;

function TSelectionToolBase.KeyDown(Code, Modifiers: LongWord): Boolean;
var
  DeltaX: LongInt;
  DeltaY: LongInt;
begin
  Result := False;
  if not FSession.Editor.Selection.Active or FMoving or FSelecting then
    Exit;
  DeltaX := 0;
  DeltaY := 0;
  case Code of
    KeyArrowLeft: DeltaX := -1;
    KeyArrowRight: DeltaX := 1;
    KeyArrowUp: DeltaY := -1;
    KeyArrowDown: DeltaY := 1;
    KeyEscape:
      begin
        Finish;
        Exit(True);
      end;
    KeyDelete:
      begin
        DeleteSelected;
        Exit(True);
      end;
  else
    Exit;
  end;
  FSession.Editor.Lift((Modifiers and ModifierControl) <> 0, FSession.SecondaryColor);
  MoveSelection(DeltaX, DeltaY);
  Result := True;
end;

procedure TSelectionToolBase.Finish;
begin
  FMoving := False;
  FSelecting := False;
  FSession.ImageChanged(InflateRectangle(FSession.Editor.Area, 1));
  FSession.Editor.Deselect;
end;

procedure TSelectionToolBase.Cancel;
begin
  Finish;
end;

function TSelectionToolBase.Busy: Boolean;
begin
  Result := FMoving or FSelecting or FSession.Editor.Selection.Active;
end;

{ --- Rectangles ------------------------------------------------------------------------------ }

procedure TRectangleSelectTool.SelectTo(const Pixel: TPoint; Modifiers: LongWord);
var
  Corner: TPoint;
  Before: TRectangle;
begin
  Corner := Pixel;
  if (Modifiers and ModifierShift) <> 0 then
    Corner := SquareCorner(FStart.X, FStart.Y, Pixel.X, Pixel.Y);
  Before := FSession.Editor.Area;
  FSession.Editor.SelectRectangle(RectangleFromCorners(FStart.X, FStart.Y, Corner.X, Corner.Y));
  FSession.ImageChanged(BoundingRectangle(InflateRectangle(Before, 1), InflateRectangle(FSession.Editor.Area, 1)));
end;

procedure TRectangleSelectTool.StartNew(const Pixel: TPoint; Modifiers: LongWord);
begin
  FStart := Pixel;
end;

procedure TRectangleSelectTool.ContinueNew(const Pixel: TPoint; Modifiers: LongWord);
begin
  SelectTo(Pixel, Modifiers);
end;

procedure TRectangleSelectTool.EndNew(const Pixel: TPoint);
begin
  { A click (no drag) selects nothing. }
  if (Pixel.X = FStart.X) and (Pixel.Y = FStart.Y) then
  begin
    FSession.ImageChanged(InflateRectangle(FSession.Editor.Area, 1));
    FSession.Editor.Deselect;
    Exit;
  end;
  SelectTo(Pixel, 0);
end;

{ --- Free-form ------------------------------------------------------------------------------- }

procedure TFreeFormSelectTool.StartNew(const Pixel: TPoint; Modifiers: LongWord);
begin
  SetLength(FPoints, 1);
  FPoints[0] := Pixel;
end;

procedure TFreeFormSelectTool.ContinueNew(const Pixel: TPoint; Modifiers: LongWord);
var
  Last: TPoint;
begin
  Last := FPoints[High(FPoints)];
  if (Last.X = Pixel.X) and (Last.Y = Pixel.Y) then
    Exit;
  SetLength(FPoints, Length(FPoints) + 1);
  FPoints[High(FPoints)] := Pixel;
  FSession.ImageChanged(StrokeExtent([Last, Pixel], 2));
end;

procedure TFreeFormSelectTool.EndNew(const Pixel: TPoint);
var
  Line: TRectangle;
begin
  Line := StrokeExtent(FPoints, 2);
  if Length(FPoints) >= 3 then
    FSession.Editor.SelectFreeForm(FPoints);
  FPoints := nil;
  FSession.ImageChanged(Line);
end;

procedure TFreeFormSelectTool.DrawOverlay(const Canvas: TCanvas; const Mapping: TViewMapping);
var
  Index: LongInt;
  FromX: LongInt;
  FromY: LongInt;
  ToX: LongInt;
  ToY: LongInt;
begin
  for Index := 1 to High(FPoints) do
  begin
    FromX := Round(ImageToViewX(Mapping, FPoints[Index - 1].X + 0.5));
    FromY := Round(ImageToViewY(Mapping, FPoints[Index - 1].Y + 0.5));
    ToX := Round(ImageToViewX(Mapping, FPoints[Index].X + 0.5));
    ToY := Round(ImageToViewY(Mapping, FPoints[Index].Y + 0.5));
    DrawLine(Canvas, FromX, FromY, ToX, ToY, ColorBlack);
  end;
end;

{ --- Text ------------------------------------------------------------------------------------ }

procedure TTextTool.StartNew(const Pixel: TPoint; Modifiers: LongWord);
begin
end;

procedure TTextTool.ContinueNew(const Pixel: TPoint; Modifiers: LongWord);
begin
end;

procedure TTextTool.EndNew(const Pixel: TPoint);
var
  Text: TImage;
begin
  Text := FSession.TextWanted;
  if Text = nil then
    Exit;
  FSession.Editor.PasteImage(Text, Pixel.X, Pixel.Y);
  FSession.ImageChanged(InflateRectangle(FSession.Editor.Area, 1));
end;

end.
