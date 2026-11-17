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
  Scroll bars: a value between Minimum and Maximum - PageSize, shown as
  a thumb in a track between two arrow buttons.

  The arrows move by one step, a click in the track by a page, dragging
  the thumb anywhere in between; the wheel over it steps too. Each
  change is announced (OnChange, NotifyChanged).
}
unit Controls.ScrollBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base;

type
  TScrollBarKind = (ScrollVertical, ScrollHorizontal);

  TScrollBar = class(TControl)
  private
    FKind: TScrollBarKind;
    FMinimum: LongInt;
    FMaximum: LongInt;
    FPageSize: LongInt;
    FPosition: LongInt;
    FStep: LongInt;
    FDragging: Boolean;
    FDragOffset: LongInt;
    procedure SetPosition(Value: LongInt);
    function Length: LongInt;
    function Breadth: LongInt;
    function ArrowLength: LongInt;
    function TrackLength: LongInt;
    function ThumbLength: LongInt;
    function ThumbStart: LongInt;
    { Along the bar, from the top (or left), in pixels. }
    function Along(X, Y: LongInt): LongInt;
    function SpanRectangle(Start, Size: LongInt): TRectangle;
    procedure DrawArrow(const Canvas: TCanvas; const Box: TRectangle; Backward: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
  public
    constructor Create(AParent: TControl); override;
    procedure SetRange(Minimum, Maximum, PageSize: LongInt);
    property Kind: TScrollBarKind read FKind write FKind;
    property Minimum: LongInt read FMinimum;
    property Maximum: LongInt read FMaximum;
    property PageSize: LongInt read FPageSize;
    property Step: LongInt read FStep write FStep;
    property Position: LongInt read FPosition write SetPosition;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Buttons,
  Controls.Painting;

constructor TScrollBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FMaximum := 100;
  FPageSize := 10;
  FStep := 1;
end;

procedure TScrollBar.SetRange(Minimum, Maximum, PageSize: LongInt);
begin
  FMinimum := Minimum;
  FMaximum := Maximum;
  if PageSize < 1 then
    PageSize := 1;
  FPageSize := PageSize;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TScrollBar.SetPosition(Value: LongInt);
var
  Highest: LongInt;
begin
  Highest := FMaximum - FPageSize;
  if Value > Highest then
    Value := Highest;
  if Value < FMinimum then
    Value := FMinimum;
  if Value = FPosition then
    Exit;
  FPosition := Value;
  Invalidate;
  Changed;
end;

function TScrollBar.Length: LongInt;
begin
  if FKind = ScrollVertical then
    Result := RectangleHeight(PixelBounds)
  else
    Result := RectangleWidth(PixelBounds);
end;

function TScrollBar.Breadth: LongInt;
begin
  if FKind = ScrollVertical then
    Result := RectangleWidth(PixelBounds)
  else
    Result := RectangleHeight(PixelBounds);
end;

function TScrollBar.ArrowLength: LongInt;
begin
  Result := Breadth;
  if 2 * Result > Length then
    Result := Length div 2;
end;

function TScrollBar.TrackLength: LongInt;
begin
  Result := Length - 2 * ArrowLength;
end;

function TScrollBar.ThumbLength: LongInt;
var
  Range: LongInt;
begin
  Range := FMaximum - FMinimum;
  if Range <= 0 then
    Exit(TrackLength);
  Result := Int64(TrackLength) * FPageSize div Range;
  if Result < Scaled(8) then
    Result := Scaled(8);
  if Result > TrackLength then
    Result := TrackLength;
end;

function TScrollBar.ThumbStart: LongInt;
var
  Room: LongInt;
begin
  Room := FMaximum - FMinimum - FPageSize;
  Result := ArrowLength;
  if Room > 0 then
    Result := Result + Int64(TrackLength - ThumbLength) * (FPosition - FMinimum) div Room;
end;

function TScrollBar.Along(X, Y: LongInt): LongInt;
begin
  if FKind = ScrollVertical then
    Result := Y
  else
    Result := X;
end;

function TScrollBar.SpanRectangle(Start, Size: LongInt): TRectangle;
begin
  if FKind = ScrollVertical then
    Result := MakeRectangle(0, Start, Breadth, Size)
  else
    Result := MakeRectangle(Start, 0, Size, Breadth);
end;

procedure TScrollBar.DrawArrow(const Canvas: TCanvas; const Box: TRectangle; Backward: Boolean);
var
  Points: array[0..2] of TPoint;
  CentreX: LongInt;
  CentreY: LongInt;
  Size: LongInt;
begin
  DrawButtonFace(Canvas, Box, False, False);
  CentreX := Box.Left + RectangleWidth(Box) div 2;
  CentreY := Box.Top + RectangleHeight(Box) div 2;
  Size := RectangleWidth(Box) div 4;
  if FKind = ScrollVertical then
  begin
    if Backward then
    begin
      Points[0] := MakePoint(CentreX - Size, CentreY + Size div 2);
      Points[1] := MakePoint(CentreX + Size, CentreY + Size div 2);
      Points[2] := MakePoint(CentreX, CentreY - Size div 2 - 1);
    end
    else
    begin
      Points[0] := MakePoint(CentreX - Size, CentreY - Size div 2);
      Points[1] := MakePoint(CentreX + Size, CentreY - Size div 2);
      Points[2] := MakePoint(CentreX, CentreY + Size div 2 + 1);
    end;
  end
  else if Backward then
  begin
    Points[0] := MakePoint(CentreX + Size div 2, CentreY - Size);
    Points[1] := MakePoint(CentreX + Size div 2, CentreY + Size);
    Points[2] := MakePoint(CentreX - Size div 2 - 1, CentreY);
  end
  else
  begin
    Points[0] := MakePoint(CentreX - Size div 2, CentreY - Size);
    Points[1] := MakePoint(CentreX - Size div 2, CentreY + Size);
    Points[2] := MakePoint(CentreX + Size div 2 + 1, CentreY);
  end;
  FillPolygon(Canvas, Points, Theme.FaceText);
end;

procedure TScrollBar.Paint(var Canvas: TCanvas);
begin
  { The track: lighter than the face. }
  FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)),
    Theme.ScrollTrack);
  DrawArrow(Canvas, SpanRectangle(0, ArrowLength), True);
  DrawArrow(Canvas, SpanRectangle(Length - ArrowLength, ArrowLength), False);
  if Enabled and (FMaximum - FMinimum > FPageSize) then
    DrawButtonFace(Canvas, SpanRectangle(ThumbStart, ThumbLength), False, False);
end;

procedure TScrollBar.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Point: LongInt;
begin
  if Button <> ButtonLeft then
    Exit;
  Point := Along(X, Y);
  if Point < ArrowLength then
    Position := FPosition - FStep
  else if Point >= Length - ArrowLength then
    Position := FPosition + FStep
  else if Point < ThumbStart then
    Position := FPosition - FPageSize
  else if Point >= ThumbStart + ThumbLength then
    Position := FPosition + FPageSize
  else
  begin
    FDragging := True;
    FDragOffset := Point - ThumbStart;
  end;
end;

procedure TScrollBar.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Room: LongInt;
  Travel: LongInt;
begin
  if not FDragging then
    Exit;
  Travel := TrackLength - ThumbLength;
  Room := FMaximum - FMinimum - FPageSize;
  if Travel <= 0 then
    Exit;
  Position := FMinimum + Int64(Along(X, Y) - FDragOffset - ArrowLength) * Room div Travel;
end;

procedure TScrollBar.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  FDragging := False;
end;

procedure TScrollBar.Wheel(Steps: LongInt);
begin
  Position := FPosition - Steps * 3 * FStep;
end;

end.
