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
  top edge (its children go inside: Inset is how far).
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
  end;

implementation

uses
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

procedure TGroupBox.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Frame: TRectangle;
  TextTop: LongInt;
  Indent: LongInt;
  Width: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  TextTop := TextHeight(ControlFace) div 2;
  { Etched: a shadow line with a highlight line just inside it. }
  Frame := MakeRectangle(0, TextTop, RectangleWidth(Box) - 1, RectangleHeight(Box) - TextTop - 1);
  DrawRectangleOutline(Canvas, Frame, Theme.Shadow);
  DrawRectangleOutline(Canvas, OffsetRectangle(Frame, 1, 1), Theme.Highlight);
  DrawRectangleOutline(Canvas, MakeRectangle(Frame.Left, Frame.Top, RectangleWidth(Frame) - 1,
    RectangleHeight(Frame) - 1), Theme.Shadow);
  if Text = '' then
    Exit;
  Indent := Scaled(8);
  Width := TextWidth(ControlFace, Text) + Scaled(4);
  FillRectangle(Canvas, MakeRectangle(Indent, 0, Width, TextHeight(ControlFace)), Theme.Face);
  DrawTextInBox(Canvas, ControlFace, Text, MakeRectangle(Indent + Scaled(2), 0, Width, TextHeight(ControlFace)),
    AlignTextLeft, Theme.FaceText);
end;

end.
