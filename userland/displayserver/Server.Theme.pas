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
  The theme: the system's colours and metrics.

  Metrics are in logical units (1/96 inch) and become pixels with the
  display's scale (ScaledMetric), so a frame is as wide and a title bar
  as tall on every display; the 3D edges stay one pixel per line, as
  edges look sharpest that way, but their count grows with the scale.
  Font sizes are in points (tenths).
}
unit Server.Theme;

{$mode objfpc}

interface

uses
  Drawing.Colors;

type
  TTheme = record
    Desktop: TColor;
    Face: TColor;
    Highlight: TColor;
    Light: TColor;
    Shadow: TColor;
    DarkShadow: TColor;
    ActiveTitleStart: TColor;
    ActiveTitleEnd: TColor;
    InactiveTitleStart: TColor;
    InactiveTitleEnd: TColor;
    ActiveTitleText: TColor;
    InactiveTitleText: TColor;
    ButtonText: TColor;
    { Logical units. }
    BorderWidth: LongInt;
    TitleHeight: LongInt;
    TitleButtonWidth: LongInt;
    TitleButtonHeight: LongInt;
    TitleTextIndent: LongInt;
    MinimumWidth: LongInt;
    MinimumHeight: LongInt;
    { Points, in tenths. }
    TitlePoints: LongWord;
  end;

var
  Theme: TTheme;
  { The display's scale in percent. }
  ScalePercent: LongWord;
  Dpi: LongWord;

procedure LoadDefaultTheme;
{ A metric (logical units) in pixels. }
function ScaledMetric(Value: LongInt): LongInt;

implementation

uses
  Windowing.Protocol;

procedure LoadDefaultTheme;
begin
  Theme.Desktop := $FF2F5F7A;
  Theme.Face := $FFCBC6BD;
  Theme.Highlight := $FFFFFFFF;
  Theme.Light := $FFE2DED6;
  Theme.Shadow := $FF7E7A72;
  Theme.DarkShadow := $FF35322D;
  Theme.ActiveTitleStart := $FF17375E;
  Theme.ActiveTitleEnd := $FF6A97C9;
  Theme.InactiveTitleStart := $FF7C7A76;
  Theme.InactiveTitleEnd := $FFB9B6B0;
  Theme.ActiveTitleText := $FFFFFFFF;
  Theme.InactiveTitleText := $FFDCD9D3;
  Theme.ButtonText := $FF000000;
  Theme.BorderWidth := 4;
  Theme.TitleHeight := 18;
  Theme.TitleButtonWidth := 16;
  Theme.TitleButtonHeight := 14;
  Theme.TitleTextIndent := 4;
  Theme.MinimumWidth := 112;
  Theme.MinimumHeight := 27;
  Theme.TitlePoints := 90;
end;

function ScaledMetric(Value: LongInt): LongInt;
begin
  Result := LogicalToPixels(Value, ScalePercent);
end;

end.
