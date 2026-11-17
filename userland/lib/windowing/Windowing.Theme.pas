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
    { A tooltip's background and text. }
    Tooltip: TColor;
    TooltipText: TColor;
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
    { --- How controls are painted (libcontrols): style flags and the
      colours only some controls use. Both looks set all of them:
      LoadModernControlLook (the default) and LoadClassicControlLook
      (exactly the earlier look). --- }
    { Bevel and edge lines grow with the display scale (a line is
      BevelLineWidth pixels), rather than staying one pixel. }
    ScaledBevelLines: Boolean;
    { A push button's face under the pointer, and while held down. }
    HotButtonFace: TColor;
    PressedButtonFace: TColor;
    { Logical units: the dark outline of the default button. }
    DefaultButtonOutline: LongInt;
    { Group boxes may have a header band (HeaderBandsShown; otherwise
      every group box is etched): a golden band (header), and a navy one
      (section), each a vertical gradient with an edge and bold text,
      over a lighter body. }
    HeaderBandsShown: Boolean;
    HeaderBandTop: TColor;
    HeaderBandBottom: TColor;
    HeaderBandEdge: TColor;
    HeaderBandText: TColor;
    SectionBandTop: TColor;
    SectionBandBottom: TColor;
    SectionBandEdge: TColor;
    SectionBandText: TColor;
    BandedGroupBody: TColor;
    { A progress bar's well, its blocks (a gradient from Light at the
      top to the colour), and a marquee's stripes on their background. }
    ProgressTrough: TColor;
    ProgressBlock: TColor;
    ProgressBlockLight: TColor;
    MarqueeStripe: TColor;
    MarqueeBackground: TColor;
    { A pop-up menu's icon column, shaded (MenuIconColumnShown) in this
      colour with an etched line beside it. }
    MenuIconColumnShown: Boolean;
    MenuIconColumn: TColor;
    { The calendar's month bar (and the text and arrows on it), and
      whether it is a filled bar with button arrows. }
    CalendarHeaderFilled: Boolean;
    CalendarHeader: TColor;
    CalendarHeaderText: TColor;
    { The thin frame around a tooltip. }
    TooltipBorder: TColor;
    { The status bar: panels separated by etched lines and a size grip
      at the right (otherwise sunken panels side by side). }
    StatusBarEtched: Boolean;
    { A splitter shows a grip of dots in its middle. }
    SplitterGrip: Boolean;
    { A scroll bar's track. }
    ScrollTrack: TColor;
  end;

var
  Theme: TTheme;

procedure LoadDefaultTheme;
{ The control painting fields: the new look, and the earlier one. }
procedure LoadModernControlLook;
procedure LoadClassicControlLook;
{ Pixels: one line of a bevel or edge at the display's scale. }
function BevelLineWidth(ScalePercent: LongWord): LongInt;
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
  Theme.Tooltip := $FFF4EFD8;
  Theme.TooltipText := $FF000000;
  Theme.ActiveTitleStart := $FF17375E;
  Theme.ActiveTitleEnd := $FF6A97C9;
  Theme.InactiveTitleStart := $FF7C7A76;
  Theme.InactiveTitleEnd := $FFB9B6B0;
  Theme.ActiveTitleText := $FFFFFFFF;
  Theme.InactiveTitleText := $FFDCD9D3;
  Theme.BorderWidth := 4;
  Theme.TitleHeight := 22;
  Theme.TitleButtonWidth := 20;
  Theme.TitleButtonHeight := 18;
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
  LoadModernControlLook;
end;

procedure LoadModernControlLook;
begin
  Theme.ScaledBevelLines := True;
  Theme.HotButtonFace := $FFE6E5F0;
  Theme.PressedButtonFace := $FFBDBCCF;
  Theme.DefaultButtonOutline := 2;
  Theme.HeaderBandsShown := True;
  Theme.HeaderBandTop := $FFFFEA8C;
  Theme.HeaderBandBottom := $FFF0B424;
  Theme.HeaderBandEdge := $FFA87410;
  Theme.HeaderBandText := $FF141414;
  Theme.SectionBandTop := $FF4A64BE;
  Theme.SectionBandBottom := $FF1E3088;
  Theme.SectionBandEdge := $FF121E58;
  Theme.SectionBandText := $FFFFFFFF;
  Theme.BandedGroupBody := $FFE4E3EE;
  Theme.ProgressTrough := $FFF2F1F7;
  Theme.ProgressBlock := $FF2FA83A;
  Theme.ProgressBlockLight := $FF9BE69E;
  Theme.MarqueeStripe := $FF4F74D2;
  Theme.MarqueeBackground := $FFC4D2F2;
  Theme.MenuIconColumnShown := True;
  Theme.MenuIconColumn := $FFDCDBE8;
  Theme.CalendarHeaderFilled := True;
  Theme.CalendarHeader := $FF24409C;
  Theme.CalendarHeaderText := $FFFFFFFF;
  Theme.TooltipBorder := $FF2A2A38;
  Theme.StatusBarEtched := True;
  Theme.SplitterGrip := True;
  Theme.ScrollTrack := $FFE8E7F0;
end;

{ Every value as the controls were painted before the new look. }
procedure LoadClassicControlLook;
begin
  Theme.ScaledBevelLines := False;
  Theme.HotButtonFace := $FFCBC6BD;
  Theme.PressedButtonFace := $FFCBC6BD;
  Theme.DefaultButtonOutline := 1;
  Theme.HeaderBandsShown := False;
  Theme.HeaderBandTop := $FFCBC6BD;
  Theme.HeaderBandBottom := $FFCBC6BD;
  Theme.HeaderBandEdge := $FF7E7A72;
  Theme.HeaderBandText := $FF000000;
  Theme.SectionBandTop := $FFCBC6BD;
  Theme.SectionBandBottom := $FFCBC6BD;
  Theme.SectionBandEdge := $FF7E7A72;
  Theme.SectionBandText := $FF000000;
  Theme.BandedGroupBody := $FFCBC6BD;
  Theme.ProgressTrough := $FFCBC6BD;
  Theme.ProgressBlock := $FF17375E;
  Theme.ProgressBlockLight := $FF17375E;
  Theme.MarqueeStripe := $FF17375E;
  Theme.MarqueeBackground := $FFCBC6BD;
  Theme.MenuIconColumnShown := False;
  Theme.MenuIconColumn := $FFCBC6BD;
  Theme.CalendarHeaderFilled := False;
  Theme.CalendarHeader := $FFCBC6BD;
  Theme.CalendarHeaderText := $FF000000;
  Theme.TooltipBorder := $FF35322D;
  Theme.StatusBarEtched := False;
  Theme.SplitterGrip := False;
  { Half way between the face and the highlight. }
  Theme.ScrollTrack := $FFE5E3DE;
end;

function BevelLineWidth(ScalePercent: LongWord): LongInt;
begin
  Result := 1;
  { One pixel up to 150%, two from 175%, and so on. }
  if Theme.ScaledBevelLines then
    Result := (LongInt(ScalePercent) + 25) div 100;
  if Result < 1 then
    Result := 1;
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
