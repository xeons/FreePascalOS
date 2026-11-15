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
  Labels: a line of text, aligned within the label, on the face colour.
}
unit Controls.Labels;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Text;

type
  TLabel = class(TControl)
  private
    FAlignment: THorizontalAlignment;
    procedure SetAlignment(Value: THorizontalAlignment);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    property Alignment: THorizontalAlignment read FAlignment write SetAlignment;
  end;

implementation

uses
  Drawing.Rectangles,
  Windowing.Theme;

procedure TLabel.SetAlignment(Value: THorizontalAlignment);
begin
  FAlignment := Value;
  Invalidate;
end;

procedure TLabel.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Enabled then
    DrawTextInBox(Canvas, ControlFace, Text, Box, FAlignment, Theme.FaceText)
  else
    DrawDisabledText(Canvas, ControlFace, Text, 0, (RectangleHeight(Box) - TextHeight(ControlFace)) div 2);
end;

end.
