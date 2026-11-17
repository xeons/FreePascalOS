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
  The Sunrise theme, the default: classic-modern, warm and crisp.
  Golden title bars deepening from light yellow to amber, with gold
  bevelled title buttons and heavy black glyphs; a cool lavender-grey
  face with honest raised and sunken bevels; gold header bands on group
  boxes (and a navy variant for section headers); a royal navy
  selection with white text; segmented green progress; a cream
  tooltip; a lavender taskbar with a gold Start button and a navy band
  down the Start menu; a calm blue-violet wallpaper.
}
unit Windowing.SunriseTheme;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Theme;

function SunriseThemeValues: TTheme;

implementation

const
  { The gold of title bars, header bands and the Start button. }
  GoldTop = $FFFFE88A;
  GoldBottom = $FFF2AE16;
  GoldEdge = $FFAE7A06;
  { The navy of the selection and the navy bands. }
  Navy = $FF1F3C9C;
  NavyTop = $FF3A5CC0;
  NavyBottom = $FF1A2F86;
  NavyEdge = $FF101C58;
  { The lavender-grey face. }
  Lavender = $FFD8D8E7;

procedure SetSunriseColors(var Values: TTheme);
begin
  Values.Desktop := $FF6C78B4;
  Values.WallpaperTop := $FF4A5A9E;
  Values.WallpaperBottom := $FFAEB4DA;
  Values.DesktopIconText := $FFFFFFFF;
  Values.DesktopIconTextShadow := $FF1C1E3A;

  Values.Face := Lavender;
  Values.Highlight := $FFFFFFFF;
  Values.Light := $FFEBEBF4;
  Values.Shadow := $FF8C8CA6;
  Values.DarkShadow := $FF3A3A52;
  Values.FaceText := $FF000000;
  Values.DisabledText := $FF8C8CA6;
  Values.DisabledTextEmboss := $FFFFFFFF;
  Values.HotFace := $FFE6E6F1;
  Values.PressedFace := $FFC8C8DB;
  Values.DefaultButtonFrame := $FF1E1E34;
  Values.Focus := $FF000000;
  Values.PanelBody := $FFE3E3EF;

  Values.Field := $FFFFFFFF;
  Values.FieldText := $FF000000;
  Values.Selection := Navy;
  Values.SelectionText := $FFFFFFFF;
  Values.Link := $FF1A3CC8;
  Values.Error := $FFD3201E;
  Values.ErrorMark := $FFFFFFFF;

  Values.Tooltip := $FFFFF7D2;
  Values.TooltipText := $FF000000;
  Values.TooltipBorder := $FF4A4636;

  Values.MenuBar := Lavender;
  Values.MenuBarText := $FF000000;
  Values.Menu := $FFEEEEF6;
  Values.MenuText := $FF000000;
  Values.MenuIconColumnFace := $FFDEDEEC;
  Values.MenuSelection := Navy;
  Values.MenuSelectionText := $FFFFFFFF;
end;

procedure SetSunriseFrameColors(var Values: TTheme);
begin
  Values.ActiveTitleStart := GoldTop;
  Values.ActiveTitleEnd := GoldBottom;
  Values.ActiveTitleEdge := GoldEdge;
  Values.ActiveTitleText := $FF141008;
  Values.InactiveTitleStart := $FFF4F0E0;
  Values.InactiveTitleEnd := $FFD9D2BA;
  Values.InactiveTitleEdge := $FFA9A28C;
  Values.InactiveTitleText := $FF5E5948;
  Values.TitleButtonFace := $FFFFD650;
  Values.TitleButtonHotFace := $FFFFEA9A;
  Values.TitleButtonPressedFace := $FFE0A214;
  Values.TitleButtonHighlight := $FFFFF6CC;
  Values.TitleButtonShadow := $FFB27C04;
  Values.TitleButtonFrame := $FF4A3404;
  Values.TitleButtonGlyph := $FF000000;
  Values.InactiveTitleButtonFace := $FFEDE8D4;
  Values.InactiveTitleButtonGlyph := $FF5E5948;
  Values.DragOutlineDark := $FF3A3A52;
  Values.DragOutlineLight := $FFFFE88A;

  Values.HeaderBandStart := GoldTop;
  Values.HeaderBandEnd := GoldBottom;
  Values.HeaderBandEdge := GoldEdge;
  Values.HeaderBandText := $FF141008;
  Values.NavyBandStart := NavyTop;
  Values.NavyBandEnd := NavyBottom;
  Values.NavyBandEdge := NavyEdge;
  Values.NavyBandText := $FFFFFFFF;
end;

procedure SetSunriseShellColors(var Values: TTheme);
begin
  Values.ProgressTrough := $FFF4F4F9;
  Values.ProgressSegment := $FF2EA83A;
  Values.ProgressSegmentLight := $FF86DE7E;
  Values.ProgressSegmentDark := $FF1A7424;
  Values.MarqueeStripe := $FF4C74DA;
  Values.MarqueeStripeGap := $FFC4D2F4;
  Values.ScrollTrough := $FFE9E9F3;

  Values.TaskbarFace := Lavender;
  Values.TaskbarText := $FF000000;
  Values.TaskButtonActiveFace := $FFEDEDF6;
  Values.StartButtonStart := GoldTop;
  Values.StartButtonEnd := GoldBottom;
  Values.StartButtonText := $FF141008;
  Values.StartMenuBandStart := NavyTop;
  Values.StartMenuBandEnd := NavyBottom;
  Values.StartMenuBandText := $FFFFFFFF;
  Values.TrayFace := $FFCFCFE0;
  Values.TrayText := $FF000000;

  Values.LockTop := $FF1E2656;
  Values.LockBottom := $FF5462A2;
  Values.LockText := $FFFFFFFF;
  Values.LockDimText := $FFD6DAF0;
  Values.LockWarningText := $FFFFC0B4;
  Values.LockedBackground := $FF141A3C;
end;

procedure SetSunriseStyle(var Values: TTheme);
begin
  Values.TitleGradientVertical := True;
  Values.TitleIcon := True;
  Values.TintedTitleButtons := True;
  Values.DottedFocus := True;
  Values.SegmentedProgress := True;
  Values.BandedGroupBoxes := True;
  Values.MenuIconColumn := True;
  Values.StartMenuBand := True;
  Values.TintedStartButton := True;
end;

procedure SetSunriseMetrics(var Values: TTheme);
begin
  Values.BorderWidth := 4;
  Values.TitleHeight := 22;
  Values.TitleButtonWidth := 20;
  Values.TitleButtonHeight := 18;
  Values.TitleButtonGap := 2;
  Values.TitleTextIndent := 4;
  Values.MinimumWidth := 112;
  Values.MinimumHeight := 27;
  Values.ScrollBarWidth := 16;
  Values.MenuBarHeight := 19;
  Values.MenuItemHeight := 18;
  Values.MenuIconColumnWidth := 22;
  Values.HeaderBandHeight := 20;
  Values.ProgressSegmentWidth := 9;
  Values.ProgressSegmentGap := 2;
  Values.MarqueeStripeWidth := 8;
  Values.StartMenuBandWidth := 26;
  Values.TitlePoints := 90;
  Values.TextPoints := 90;
  Values.TextFamily := 'dejavu-sans';
  Values.FixedFamily := 'terminus';
end;

function SunriseThemeValues: TTheme;
begin
  Result := Default(TTheme);
  Result.Key := SunriseThemeKey;
  Result.DisplayName := 'Sunrise';
  SetSunriseColors(Result);
  SetSunriseFrameColors(Result);
  SetSunriseShellColors(Result);
  SetSunriseStyle(Result);
  SetSunriseMetrics(Result);
end;

end.
