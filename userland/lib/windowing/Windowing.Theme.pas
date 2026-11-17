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
  The theme: the system's colours, metrics and a few style flags, the
  same for the display server (window frames), the desktop shell and
  programs (controls). It is data: every built-in theme fills the same
  record (Windowing.SunriseTheme, the default, and Windowing.ClassicTheme,
  the look the system had first), and the one in use is chosen by the
  setting Appearance/Theme (Windowing.ThemeSettings), changeable while
  everything runs.

  Metrics are in logical units (1/96 inch) and become pixels with the
  display's scale; the 3D edges stay one pixel per line, as edges look
  sharpest that way. Font sizes are in points (tenths).

  Gradients go from a Start colour to an End colour; whether across or
  down is a style flag where both are possible (TitleGradientVertical),
  otherwise top to bottom. A gradient whose two colours are alike is a
  flat fill, which is how a theme without gradients says so.
}
unit Windowing.Theme;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Bevels;

type
  TTheme = record
    { The theme's setting value ("sunrise", "classic") and its name to
      show ("Sunrise", "Classic"). }
    Key: string;
    DisplayName: string;

    { --- The desktop --------------------------------------------------- }
    { The screen behind every window where nothing else is drawn (and
      the wallpaper's colour when it is one colour). }
    Desktop: TColor;
    { The drawn wallpaper: a gradient from top to bottom. }
    WallpaperTop: TColor;
    WallpaperBottom: TColor;
    { A desktop icon's label and the shadow under its letters. }
    DesktopIconText: TColor;
    DesktopIconTextShadow: TColor;

    { --- Controls and frames: the face and its 3D edges ---------------- }
    { The face of windows, dialogs, buttons and bars. }
    Face: TColor;
    { The bevel's lines: Highlight (outer, top-left), Light (inner,
      top-left), Shadow (inner, bottom-right), DarkShadow (outer,
      bottom-right). A raised edge is light above dark, a sunken one
      the other way round. }
    Highlight: TColor;
    Light: TColor;
    Shadow: TColor;
    DarkShadow: TColor;
    { Text on the face, and text (and glyphs) of what is disabled; the
      disabled text is embossed: drawn once in DisabledTextEmboss a
      pixel down and right, then in DisabledText. }
    FaceText: TColor;
    DisabledText: TColor;
    DisabledTextEmboss: TColor;
    { A button's face under the pointer (hot) and held down (pressed). }
    HotFace: TColor;
    PressedFace: TColor;
    { The extra outer border of the default button (the one Enter
      presses), and the focus frame's colour (dotted or solid as
      DottedFocus says). }
    DefaultButtonFrame: TColor;
    Focus: TColor;
    { A panel's lighter body: a group box's or section panel's inside,
      beside the plain face. }
    PanelBody: TColor;

    { --- Fields: where text is typed and lists are --------------------- }
    Field: TColor;
    FieldText: TColor;
    { The selection (in lists, trees, grids, edits) and its text; also
      the calendar's header bar. }
    Selection: TColor;
    SelectionText: TColor;
    { A link label's text. }
    Link: TColor;
    { The error provider: its round mark (with an Error-coloured border
      around the field) and the "!" in it. }
    Error: TColor;
    ErrorMark: TColor;

    { --- Tooltips ---------------------------------------------------- }
    Tooltip: TColor;
    TooltipText: TColor;
    TooltipBorder: TColor;

    { --- Menus ------------------------------------------------------- }
    { The menu bar's face and text. }
    MenuBar: TColor;
    MenuBarText: TColor;
    { A pop-up menu's face, text, the icon column at its left (when
      MenuIconColumn is set), and the selected item's bar and text. }
    Menu: TColor;
    MenuText: TColor;
    MenuIconColumnFace: TColor;
    MenuSelection: TColor;
    MenuSelectionText: TColor;

    { --- Window title bars (display server) ---------------------------- }
    { The active window's bar: a gradient from Start (left or top) to
      End (right or bottom), an Edge line around it (none when it is
      ColorTransparent) and the title's colour. }
    ActiveTitleStart: TColor;
    ActiveTitleEnd: TColor;
    ActiveTitleEdge: TColor;
    ActiveTitleText: TColor;
    { The same for every other window. }
    InactiveTitleStart: TColor;
    InactiveTitleEnd: TColor;
    InactiveTitleEdge: TColor;
    InactiveTitleText: TColor;
    { The title bar's minimize, maximize and close buttons: their face
      (plain, hot, pressed), bevel lines, outer frame (none when
      ColorTransparent) and glyph; on an inactive window, the plain
      face and glyph are the Inactive ones. }
    TitleButtonFace: TColor;
    TitleButtonHotFace: TColor;
    TitleButtonPressedFace: TColor;
    TitleButtonHighlight: TColor;
    TitleButtonShadow: TColor;
    TitleButtonFrame: TColor;
    TitleButtonGlyph: TColor;
    InactiveTitleButtonFace: TColor;
    InactiveTitleButtonGlyph: TColor;
    { The outline drawn while a window is moved or sized without its
      contents: two lines, Dark outside and Light inside. }
    DragOutlineDark: TColor;
    DragOutlineLight: TColor;

    { --- Header bands (group boxes, section panels) ------------------- }
    { The gold band across a banded group box's top (the title bar's
      look), its edge and its bold text. }
    HeaderBandStart: TColor;
    HeaderBandEnd: TColor;
    HeaderBandEdge: TColor;
    HeaderBandText: TColor;
    { The navy variant (section headers, e.g. the Control Panel's
      categories, the Start menu's side band). }
    NavyBandStart: TColor;
    NavyBandEnd: TColor;
    NavyBandEdge: TColor;
    NavyBandText: TColor;

    { --- Progress and scrolling ---------------------------------------- }
    { A progress bar's trough, and its blocks: a segment's body, its
      lighter top and darker bottom (alike for flat blocks). }
    ProgressTrough: TColor;
    ProgressSegment: TColor;
    ProgressSegmentLight: TColor;
    ProgressSegmentDark: TColor;
    { The marquee (progress of unknown length): diagonal stripes of
      Stripe on StripeGap. }
    MarqueeStripe: TColor;
    MarqueeStripeGap: TColor;
    { A scroll bar's trough. }
    ScrollTrough: TColor;

    { --- The taskbar and Start menu (desktop shell) -------------------- }
    { The taskbar's face and text; a task button's face when its window
      is the active one (drawn sunken). }
    TaskbarFace: TColor;
    TaskbarText: TColor;
    TaskButtonActiveFace: TColor;
    { The Start button: a gradient (top to bottom) and its text. }
    StartButtonStart: TColor;
    StartButtonEnd: TColor;
    StartButtonText: TColor;
    { The band down the Start menu's left side: a gradient (top to
      bottom) and the bold text on it. }
    StartMenuBandStart: TColor;
    StartMenuBandEnd: TColor;
    StartMenuBandText: TColor;
    { The notification area's (tray's) sunken face and the clock's
      text. }
    TrayFace: TColor;
    TrayText: TColor;

    { --- Login and lock screens ---------------------------------------- }
    { The background (a gradient from top to bottom), the large text,
      the quieter text and a warning. }
    LockTop: TColor;
    LockBottom: TColor;
    LockText: TColor;
    LockDimText: TColor;
    LockWarningText: TColor;
    { What the display server shows over everything while the screen
      is locked, before the lock window is up. }
    LockedBackground: TColor;

    { --- Style flags ------------------------------------------------- }
    { Title bars: the gradient runs down (else across), the window's
      icon is drawn at the left of the title, and the title buttons
      are drawn in their own colours with a frame (else as plain face
      buttons). }
    TitleGradientVertical: Boolean;
    TitleIcon: Boolean;
    TintedTitleButtons: Boolean;
    { Controls: the focus frame is dotted (else solid); progress is
      drawn as separate segments (else one bar); group boxes with a
      title get the gold header band (else they are etched); pop-up
      menus have an icon column. }
    DottedFocus: Boolean;
    SegmentedProgress: Boolean;
    BandedGroupBoxes: Boolean;
    MenuIconColumn: Boolean;
    { The Start menu has the band down its side; the Start button is
      drawn in its gradient (else as a face button). }
    StartMenuBand: Boolean;
    TintedStartButton: Boolean;

    { --- Metrics (logical units) --------------------------------------- }
    BorderWidth: LongInt;
    TitleHeight: LongInt;
    TitleButtonWidth: LongInt;
    TitleButtonHeight: LongInt;
    { The gap between title buttons and to the bar's right end. }
    TitleButtonGap: LongInt;
    TitleTextIndent: LongInt;
    MinimumWidth: LongInt;
    MinimumHeight: LongInt;
    ScrollBarWidth: LongInt;
    MenuBarHeight: LongInt;
    MenuItemHeight: LongInt;
    { The width of a pop-up menu's icon column (when MenuIconColumn). }
    MenuIconColumnWidth: LongInt;
    { A header band's height. }
    HeaderBandHeight: LongInt;
    { A progress segment's width and the gap between two; a marquee
      stripe's width. }
    ProgressSegmentWidth: LongInt;
    ProgressSegmentGap: LongInt;
    MarqueeStripeWidth: LongInt;
    { The Start menu's side band's width. }
    StartMenuBandWidth: LongInt;

    { --- Fonts -------------------------------------------------------- }
    { Points, in tenths. }
    TitlePoints: LongWord;
    TextPoints: LongWord;
    { The font families (directories in /lib/fonts): the interface's
      text and title, and monospaced text (where columns must line up,
      as in a multi-line edit box). }
    TextFamily: PChar;
    FixedFamily: PChar;
  end;

const
  { The built-in themes' keys (the values of Appearance/Theme). }
  SunriseThemeKey = 'sunrise';
  ClassicThemeKey = 'classic';
  DefaultThemeKey = SunriseThemeKey;

var
  { The theme in use. }
  Theme: TTheme;

{ Puts the default theme in Theme. }
procedure LoadDefaultTheme;
{ Puts the built-in theme Key in Theme; False (and the default theme)
  for a key there is no theme for. }
function LoadThemeByKey(const Key: string): Boolean;
{ The built-in themes: how many, and each one's values (to list or
  preview them without using them). }
function BuiltInThemeCount: LongInt;
function BuiltInTheme(Index: LongInt): TTheme;
{ The bevel colours of the theme's raised and sunken edges. }
function RaisedThemeBevel: TBevelColors;
function SunkenThemeBevel: TBevelColors;

implementation

uses
  Windowing.SunriseTheme,
  Windowing.ClassicTheme;

function BuiltInThemeCount: LongInt;
begin
  Result := 2;
end;

function BuiltInTheme(Index: LongInt): TTheme;
begin
  if Index = 1 then
    Result := ClassicThemeValues
  else
    Result := SunriseThemeValues;
end;

procedure LoadDefaultTheme;
begin
  Theme := SunriseThemeValues;
end;

function LoadThemeByKey(const Key: string): Boolean;
var
  Index: LongInt;
  Candidate: TTheme;
begin
  for Index := 0 to BuiltInThemeCount - 1 do
  begin
    Candidate := BuiltInTheme(Index);
    if Candidate.Key = Key then
    begin
      Theme := Candidate;
      Exit(True);
    end;
  end;
  LoadDefaultTheme;
  Result := False;
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
