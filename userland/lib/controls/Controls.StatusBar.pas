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
  Status bars: a strip along the bottom of a window, in panels, each a
  sunken box with a text, or (Theme.StatusBarEtched) one sunken strip
  with the panels separated by etched lines and a size grip at the
  right. Panel widths are logical units; the last one takes what is
  left.
}
unit Controls.StatusBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TStatusBar = class(TControl)
  private
    FTexts: array of string;
    FWidths: array of LongInt;
    function GetPanelText(Index: LongInt): string;
    procedure SetPanelText(Index: LongInt; const Value: string);
    procedure PaintSunkenPanels(var Canvas: TCanvas);
    procedure PaintEtched(var Canvas: TCanvas);
    function PanelWidth(Index, Left: LongInt): LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    { Panels of these widths (the last one's is ignored). }
    procedure SetPanels(const Widths: array of LongInt);
    function PreferredSize: TSize; override;
    property PanelText[Index: LongInt]: string read GetPanelText write SetPanelText;
  end;

implementation

uses
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text,
  Controls.LayoutRules,
  Controls.Painting;

constructor TStatusBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  SetBounds(0, 0, 0, 20);
  Align := AlignBottom;
  SetPanels([0]);
end;

const
  { Logical units: the bar's height at least, room around a panel's text,
    the width the last panel needs at least. }
  MinimumStatusHeight = 20;
  StatusRoomDown = 6;
  LastPanelWidth = 100;

{ Every panel at its width (the last at what its text needs); a line of
  text high. }
function TStatusBar.PreferredSize: TSize;
var
  Index: LongInt;
  Width: LongInt;
  Height: LongInt;
  Last: LongInt;
begin
  Width := 0;
  for Index := 0 to High(FWidths) - 1 do
    Width := Width + FWidths[Index];
  Last := LastPanelWidth;
  if High(FTexts) >= 0 then
    if PixelsToLogicalCeiling(TextWidth(ControlFace, FTexts[High(FTexts)])) + StatusRoomDown > Last then
      Last := PixelsToLogicalCeiling(TextWidth(ControlFace, FTexts[High(FTexts)])) + StatusRoomDown;
  Height := PixelsToLogicalCeiling(TextHeight(ControlFace)) + StatusRoomDown;
  if Height < MinimumStatusHeight then
    Height := MinimumStatusHeight;
  Result := MakeSize(Width + Last, Height);
end;

procedure TStatusBar.SetPanels(const Widths: array of LongInt);
var
  Index: LongInt;
begin
  SetLength(FWidths, System.Length(Widths));
  SetLength(FTexts, System.Length(Widths));
  for Index := 0 to High(Widths) do
    FWidths[Index] := Widths[Index];
  Invalidate;
end;

function TStatusBar.GetPanelText(Index: LongInt): string;
begin
  if (Index < 0) or (Index > High(FTexts)) then
    Exit('');
  Result := FTexts[Index];
end;

procedure TStatusBar.SetPanelText(Index: LongInt; const Value: string);
begin
  if (Index < 0) or (Index > High(FTexts)) then
    Exit;
  FTexts[Index] := Value;
  Invalidate;
end;

procedure TStatusBar.Paint(var Canvas: TCanvas);
begin
  FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)), Theme.Face);
  if Theme.StatusBarEtched then
    PaintEtched(Canvas)
  else
    PaintSunkenPanels(Canvas);
end;

{ Each panel sunken on its own, a gap after it. }
procedure TStatusBar.PaintSunkenPanels(var Canvas: TCanvas);
var
  Index: LongInt;
  Left: LongInt;
  Width: LongInt;
  Panel: TRectangle;
  Gap: LongInt;
begin
  Gap := Scaled(2);
  Left := 0;
  for Index := 0 to High(FWidths) do
  begin
    Width := PanelWidth(Index, Left);
    Panel := MakeRectangle(Left, Gap, Width - Gap, RectangleHeight(PixelBounds) - Gap);
    DrawSunkenEdge(Canvas, Panel);
    DrawTextInBox(Canvas, ControlFace, FTexts[Index], InflateRectangle(Panel, -Scaled(3)), AlignTextLeft,
      Theme.FaceText);
    Left := Left + Width;
  end;
end;

{ One sunken strip, the panels in it separated by etched lines, and the
  size grip in the bottom right corner. }
procedure TStatusBar.PaintEtched(var Canvas: TCanvas);
var
  Strip: TRectangle;
  Index: LongInt;
  Left: LongInt;
  Width: LongInt;
  Panel: TRectangle;
  Grip: LongInt;
begin
  Strip := MakeRectangle(0, Scaled(2), RectangleWidth(PixelBounds), RectangleHeight(PixelBounds) - Scaled(2));
  DrawSunkenEdge(Canvas, Strip);
  Grip := Scaled(14);
  Left := 0;
  for Index := 0 to High(FWidths) do
  begin
    Width := PanelWidth(Index, Left);
    Panel := MakeRectangle(Left, Strip.Top, Width, RectangleHeight(Strip));
    if Index = High(FWidths) then
      Panel.Right := Panel.Right - Grip;
    if Index > 0 then
      DrawEtchedVerticalLine(Canvas, Left, Strip.Top + Scaled(3), Strip.Bottom - Scaled(3));
    DrawTextInBox(Canvas, ControlFace, FTexts[Index], MakeRectangle(Panel.Left + Scaled(5), Panel.Top,
      RectangleWidth(Panel) - Scaled(8), RectangleHeight(Panel)), AlignTextLeft, Theme.FaceText);
    Left := Left + Width;
  end;
  DrawSizeGrip(Canvas, InflateRectangle(Strip, -BevelLine));
end;

{ Pixels: panel Index's width, starting at Left (the last takes the
  rest). }
function TStatusBar.PanelWidth(Index, Left: LongInt): LongInt;
begin
  if Index = High(FWidths) then
    Result := RectangleWidth(PixelBounds) - Left
  else
    Result := Scaled(FWidths[Index]);
end;

end.
