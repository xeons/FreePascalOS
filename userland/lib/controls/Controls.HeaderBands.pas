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
  A header band: a heading across the top of a window, pop-up or page,
  in the theme's band colours - the gold of the title bars
  (HeaderBandStart, HeaderBandEnd, HeaderBandEdge, HeaderBandText) or
  the navy variant (NavyBand...) - a gradient from top to bottom, an
  edge line along its bottom and the text in bold, indented.

  Where the theme does not band its panels (TTheme.BandedGroupBoxes
  off, as in Classic) it is a plain label instead: the text in the
  ordinary face and colour, drawn as a TLabel would, so a window laid
  out for both looks as it always did there.
}
unit Controls.HeaderBands;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  THeaderBandStyle = (HeaderBandGold, HeaderBandNavy);

  THeaderBand = class(TControl)
  private
    FText: string;
    FStyle: THeaderBandStyle;
    procedure SetText(const Value: string);
  public
    procedure Paint(var Canvas: TCanvas); override;
    { Whether the theme draws the band (else the plain label). }
    class function ThemeBands: Boolean;
    property Text: string read FText write SetText;
    property Style: THeaderBandStyle read FStyle write FStyle;
  end;

implementation

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

const
  { Logical units: the text's indent in the band. }
  BandIndent = 8;

class function THeaderBand.ThemeBands: Boolean;
begin
  Result := Theme.BandedGroupBoxes;
end;

procedure THeaderBand.SetText(const Value: string);
begin
  if Value = FText then
    Exit;
  FText := Value;
  Invalidate;
end;

procedure THeaderBand.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  StartColor: TColor;
  EndColor: TColor;
  EdgeColor: TColor;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if not ThemeBands then
  begin
    DrawTextInBox(Canvas, ControlFace, FText, Box, AlignTextLeft, Theme.FaceText);
    Exit;
  end;
  if FStyle = HeaderBandNavy then
  begin
    StartColor := Theme.NavyBandStart;
    EndColor := Theme.NavyBandEnd;
    EdgeColor := Theme.NavyBandEdge;
    TextColor := Theme.NavyBandText;
  end
  else
  begin
    StartColor := Theme.HeaderBandStart;
    EndColor := Theme.HeaderBandEnd;
    EdgeColor := Theme.HeaderBandEdge;
    TextColor := Theme.HeaderBandText;
  end;
  FillVerticalGradient(Canvas, Box, StartColor, EndColor);
  DrawHorizontalLine(Canvas, Box.Left, Box.Right, Box.Bottom - 1, EdgeColor);
  Box.Left := Box.Left + Scaled(BandIndent);
  DrawTextInBox(Canvas, ControlBoldFace, FText, Box, AlignTextLeft, TextColor);
end;

end.
