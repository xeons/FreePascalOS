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
  Panels and group boxes: controls that hold others.

  A panel fills itself with the face colour and may have a raised or
  sunken edge; a group box draws an etched frame with its text in the
  top edge (its children go inside: Inset is how far). A group box's
  mnemonic focuses the first control in it (or after it) that takes
  the focus.
}
unit Controls.Panels;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TPanelEdge = (PanelFlat, PanelRaised, PanelSunken);

  TPanel = class(TControl)
  private
    FEdge: TPanelEdge;
    procedure SetEdge(Value: TPanelEdge);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    property Edge: TPanelEdge read FEdge write SetEdge;
  end;

  TGroupBox = class(TControl)
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
  end;

implementation

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

procedure TPanel.SetEdge(Value: TPanelEdge);
begin
  FEdge := Value;
  Invalidate;
end;

procedure TPanel.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  case FEdge of
    PanelRaised: DrawEdge(Canvas, Box, Theme.Highlight, Theme.Shadow);
    PanelSunken: DrawEdge(Canvas, Box, Theme.Shadow, Theme.Highlight);
  end;
end;

function TGroupBox.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := TextMatchesMnemonic(Character);
end;

procedure TGroupBox.ActivateMnemonic(Character: LongWord);
begin
  if Host <> nil then
    Host.FocusControlAfter(Self);
end;

{ The outline of Rectangle, Thickness pixels wide inside it. }
procedure DrawThickOutline(const Canvas: TCanvas; const Rectangle: TRectangle; Thickness: LongInt; Color: TColor);
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := RectangleWidth(Rectangle);
  Height := RectangleHeight(Rectangle);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, Width, Thickness), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Bottom - Thickness, Width, Thickness), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, Thickness, Height), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Right - Thickness, Rectangle.Top, Thickness, Height), Color);
end;

procedure TGroupBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  ShadowFrame: TRectangle;
  HighlightFrame: TRectangle;
  LineWidth: LongInt;
  TextTop: LongInt;
  Indent: LongInt;
  Width: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  TextTop := TextHeight(ControlFace) div 2;
  LineWidth := Scaled(1);
  if LineWidth < 1 then
    LineWidth := 1;
  { Etched (a groove): a highlight outline a line down and right of a
    shadow outline, the shadow drawn over it. The shadow's right and
    bottom lines fall inside the highlight's, so the groove turns each
    corner cleanly; the outer corners at the top right and bottom left
    stay the face. }
  ShadowFrame := MakeRectangle(0, TextTop, RectangleWidth(Box) - LineWidth,
    RectangleHeight(Box) - TextTop - LineWidth);
  HighlightFrame := OffsetRectangle(ShadowFrame, LineWidth, LineWidth);
  DrawThickOutline(Canvas, HighlightFrame, LineWidth, Theme.Highlight);
  DrawThickOutline(Canvas, ShadowFrame, LineWidth, Theme.Shadow);
  if Text = '' then
    Exit;
  Indent := Scaled(8);
  Width := MnemonicTextWidth(ControlFace, Text) + Scaled(4);
  FillRectangle(Canvas, MakeRectangle(Indent, 0, Width, TextHeight(ControlFace)), Theme.Face);
  DrawMnemonicTextInBox(Canvas, ControlFace, Text, MakeRectangle(Indent + Scaled(2), 0, Width, TextHeight(ControlFace)),
    AlignTextLeft, Theme.FaceText);
end;

end.
