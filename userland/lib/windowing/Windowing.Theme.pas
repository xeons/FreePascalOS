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
  The theme: the system's colours and metrics, the same for the display
  server (window frames) and for programs (controls).

  Metrics are in logical units (1/96 inch) and become pixels with the
  display's scale; the 3D edges stay one pixel per line, as edges look
  sharpest that way. Font sizes are in points (tenths).
}
unit Windowing.Theme;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Bevels;

type
  TTheme = record
    Desktop: TColor;
    { Controls and frames. }
    Face: TColor;
    Highlight: TColor;
    Light: TColor;
    Shadow: TColor;
    DarkShadow: TColor;
    FaceText: TColor;
    DisabledText: TColor;
    { Where text is typed and lists are: a field's background and text. }
    Field: TColor;
    FieldText: TColor;
    { The selection (in lists, edits, menus). }
    Selection: TColor;
    SelectionText: TColor;
    ActiveTitleStart: TColor;
    ActiveTitleEnd: TColor;
    InactiveTitleStart: TColor;
    InactiveTitleEnd: TColor;
    ActiveTitleText: TColor;
    InactiveTitleText: TColor;
    { Logical units. }
    BorderWidth: LongInt;
    TitleHeight: LongInt;
    TitleButtonWidth: LongInt;
    TitleButtonHeight: LongInt;
    TitleTextIndent: LongInt;
    MinimumWidth: LongInt;
    MinimumHeight: LongInt;
    ScrollBarWidth: LongInt;
    MenuBarHeight: LongInt;
    MenuItemHeight: LongInt;
    { Points, in tenths. }
    TitlePoints: LongWord;
    TextPoints: LongWord;
    { The font families (directories in /lib/fonts): the interface's
      text and title, and monospaced text (where columns must line up,
      as in a multi-line edit box). }
    TextFamily: PChar;
    FixedFamily: PChar;
  end;

var
  Theme: TTheme;

procedure LoadDefaultTheme;
function RaisedThemeBevel: TBevelColors;
function SunkenThemeBevel: TBevelColors;

implementation

procedure LoadDefaultTheme;
begin
  Theme.Desktop := $FF2F5F7A;
  Theme.Face := $FFCBC6BD;
  Theme.Highlight := $FFFFFFFF;
  Theme.Light := $FFE2DED6;
  Theme.Shadow := $FF7E7A72;
  Theme.DarkShadow := $FF35322D;
  Theme.FaceText := $FF000000;
  Theme.DisabledText := $FF7E7A72;
  Theme.Field := $FFFFFFFF;
  Theme.FieldText := $FF000000;
  Theme.Selection := $FF17375E;
  Theme.SelectionText := $FFFFFFFF;
  Theme.ActiveTitleStart := $FF17375E;
  Theme.ActiveTitleEnd := $FF6A97C9;
  Theme.InactiveTitleStart := $FF7C7A76;
  Theme.InactiveTitleEnd := $FFB9B6B0;
  Theme.ActiveTitleText := $FFFFFFFF;
  Theme.InactiveTitleText := $FFDCD9D3;
  Theme.BorderWidth := 4;
  Theme.TitleHeight := 18;
  Theme.TitleButtonWidth := 16;
  Theme.TitleButtonHeight := 14;
  Theme.TitleTextIndent := 4;
  Theme.MinimumWidth := 112;
  Theme.MinimumHeight := 27;
  Theme.ScrollBarWidth := 16;
  Theme.MenuBarHeight := 19;
  Theme.MenuItemHeight := 18;
  Theme.TitlePoints := 90;
  Theme.TextPoints := 90;
  Theme.TextFamily := 'dejavu-sans';
  Theme.FixedFamily := 'terminus';
end;

function RaisedThemeBevel: TBevelColors;
begin
  Result := RaisedBevel(Theme.Highlight, Theme.Light, Theme.Shadow, Theme.DarkShadow);
end;

function SunkenThemeBevel: TBevelColors;
begin
  Result := SunkenBevel(Theme.Highlight, Theme.Light, Theme.Shadow, Theme.DarkShadow);
end;

initialization
  LoadDefaultTheme;
end.
