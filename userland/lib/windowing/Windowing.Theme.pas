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
    { The drawn wallpaper: a gradient from top to bottom, a glow (a
      moon or a low sun, laid over the sky with its own alpha, a fainter
      halo round it) high on the right, and
      three waves of hills across the bottom, far to near (colours with
      their own alpha, laid over what is behind). }
    WallpaperTop: TColor;
    WallpaperBottom: TColor;
    WallpaperGlow: TColor;
    WallpaperWaveFar: TColor;
    WallpaperWaveMiddle: TColor;
    WallpaperWaveNear: TColor;
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
    { The focus frame's colour (a dotted frame). }
    Focus: TColor;

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

    { --- Menus ------------------------------------------------------- }
    { The menu bar's face and text. }
    MenuBar: TColor;
    MenuBarText: TColor;
    { A pop-up menu's face and text, and the selected item's bar and
      text (its icon column is MenuIconColumn, below). }
    Menu: TColor;
    MenuText: TColor;
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

    { --- How controls are painted (libcontrols): style flags and the
      colours only some controls use. --- }
    { Bevel and edge lines grow with the display scale (a line is
      BevelLineWidth pixels), rather than staying one pixel. }
    ScaledBevelLines: Boolean;
    { A push button's face under the pointer, and while held down. }
    HotButtonFace: TColor;
    PressedButtonFace: TColor;
    { Logical units: the dark outline of the default button. }
    DefaultButtonOutline: LongInt;
    { Group boxes may have a header band (HeaderBandsShown; otherwise
      every group box is etched): a golden band (header, the title
      bars' look), and a navy one (section: the Control Panel's
      categories, taskbar pop-ups), each a vertical gradient with an
      edge and bold text, over a lighter body. Header bands elsewhere
      (Controls.HeaderBands, the login window, the lock panel's accent)
      follow HeaderBandsShown too. }
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
    { The thin frame around a tooltip (and the drag label). }
    TooltipBorder: TColor;
    { The status bar: panels separated by etched lines and a size grip
      at the right (otherwise sunken panels side by side). }
    StatusBarEtched: Boolean;
    { A splitter shows a grip of dots in its middle. }
    SplitterGrip: Boolean;
    { A scroll bar's track. }
    ScrollTrack: TColor;
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
{ Only the control painting fields (the block "How controls are
  painted") of Sunrise (the new look) or of Classic (exactly the
  earlier look) into Theme. }
procedure LoadModernControlLook;
procedure LoadClassicControlLook;
{ Pixels: one line of a bevel or edge at the display's scale. }
function BevelLineWidth(ScalePercent: LongWord): LongInt;
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

{ The control painting fields of Source into Target. }
procedure CopyControlLook(var Target: TTheme; const Source: TTheme);
begin
  Target.ScaledBevelLines := Source.ScaledBevelLines;
  Target.HotButtonFace := Source.HotButtonFace;
  Target.PressedButtonFace := Source.PressedButtonFace;
  Target.DefaultButtonOutline := Source.DefaultButtonOutline;
  Target.HeaderBandsShown := Source.HeaderBandsShown;
  Target.HeaderBandTop := Source.HeaderBandTop;
  Target.HeaderBandBottom := Source.HeaderBandBottom;
  Target.HeaderBandEdge := Source.HeaderBandEdge;
  Target.HeaderBandText := Source.HeaderBandText;
  Target.SectionBandTop := Source.SectionBandTop;
  Target.SectionBandBottom := Source.SectionBandBottom;
  Target.SectionBandEdge := Source.SectionBandEdge;
  Target.SectionBandText := Source.SectionBandText;
  Target.BandedGroupBody := Source.BandedGroupBody;
  Target.ProgressTrough := Source.ProgressTrough;
  Target.ProgressBlock := Source.ProgressBlock;
  Target.ProgressBlockLight := Source.ProgressBlockLight;
  Target.MarqueeStripe := Source.MarqueeStripe;
  Target.MarqueeBackground := Source.MarqueeBackground;
  Target.MenuIconColumnShown := Source.MenuIconColumnShown;
  Target.MenuIconColumn := Source.MenuIconColumn;
  Target.CalendarHeaderFilled := Source.CalendarHeaderFilled;
  Target.CalendarHeader := Source.CalendarHeader;
  Target.CalendarHeaderText := Source.CalendarHeaderText;
  Target.TooltipBorder := Source.TooltipBorder;
  Target.StatusBarEtched := Source.StatusBarEtched;
  Target.SplitterGrip := Source.SplitterGrip;
  Target.ScrollTrack := Source.ScrollTrack;
end;

procedure LoadModernControlLook;
begin
  CopyControlLook(Theme, SunriseThemeValues);
end;

procedure LoadClassicControlLook;
begin
  CopyControlLook(Theme, ClassicThemeValues);
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
