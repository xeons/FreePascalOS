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
  The Classic theme: the look the system had first, kept as it was -
  a warm grey face, a navy-to-blue title bar running across, plain face
  title buttons, a solid navy selection and a dark teal wallpaper.
  Colours of parts that look did not have (header bands, the tray's
  own colours) are the nearest of its own, so a control using them
  still looks Classic; the style flags keep those parts drawn the old
  way.
}
unit Windowing.ClassicTheme;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Theme;

function ClassicThemeValues: TTheme;

implementation

uses
  Drawing.Colors;

procedure SetClassicColors(var Values: TTheme);
begin
  Values.Desktop := $FF2F5F7A;
  Values.WallpaperTop := $FF0F2C42;
  Values.WallpaperBottom := $FF3F7E95;
  Values.WallpaperGlow := $38F4F1E6;
  Values.WallpaperWaveFar := $3C9CC9D8;
  Values.WallpaperWaveMiddle := $70204F66;
  Values.WallpaperWaveNear := $A0102E40;
  Values.DesktopIconText := $FFFFFFFF;
  Values.DesktopIconTextShadow := $FF000000;

  Values.Face := $FFCBC6BD;
  Values.Highlight := $FFFFFFFF;
  Values.Light := $FFE2DED6;
  Values.Shadow := $FF7E7A72;
  Values.DarkShadow := $FF35322D;
  Values.FaceText := $FF000000;
  Values.DisabledText := $FF7E7A72;
  Values.DisabledTextEmboss := $FFFFFFFF;
  Values.Focus := $FF000000;

  Values.Field := $FFFFFFFF;
  Values.FieldText := $FF000000;
  Values.Selection := $FF17375E;
  Values.SelectionText := $FFFFFFFF;
  Values.Link := $FF17375E;
  Values.Error := $FFC0302C;
  Values.ErrorMark := $FFFFFFFF;

  Values.Tooltip := $FFF4EFD8;
  Values.TooltipText := $FF000000;

  Values.MenuBar := $FFCBC6BD;
  Values.MenuBarText := $FF000000;
  Values.Menu := $FFCBC6BD;
  Values.MenuText := $FF000000;
  Values.MenuSelection := $FF17375E;
  Values.MenuSelectionText := $FFFFFFFF;
end;

procedure SetClassicFrameColors(var Values: TTheme);
begin
  Values.ActiveTitleStart := $FF17375E;
  Values.ActiveTitleEnd := $FF6A97C9;
  Values.ActiveTitleEdge := ColorTransparent;
  Values.ActiveTitleText := $FFFFFFFF;
  Values.InactiveTitleStart := $FF7C7A76;
  Values.InactiveTitleEnd := $FFB9B6B0;
  Values.InactiveTitleEdge := ColorTransparent;
  Values.InactiveTitleText := $FFDCD9D3;
  Values.TitleButtonFace := $FFCBC6BD;
  Values.TitleButtonHotFace := $FFE2DED6;
  Values.TitleButtonPressedFace := $FFCBC6BD;
  Values.TitleButtonHighlight := $FFFFFFFF;
  Values.TitleButtonShadow := $FF7E7A72;
  Values.TitleButtonFrame := ColorTransparent;
  Values.TitleButtonGlyph := $FF000000;
  Values.InactiveTitleButtonFace := $FFCBC6BD;
  Values.InactiveTitleButtonGlyph := $FF000000;
  Values.DragOutlineDark := $FF35322D;
  Values.DragOutlineLight := $FFFFFFFF;
end;

procedure SetClassicShellColors(var Values: TTheme);
begin
  Values.TaskbarFace := $FFCBC6BD;
  Values.TaskbarText := $FF000000;
  Values.TaskButtonActiveFace := $FFE2DED6;
  Values.StartButtonStart := $FFCBC6BD;
  Values.StartButtonEnd := $FFCBC6BD;
  Values.StartButtonText := $FF000000;
  Values.StartMenuBandStart := $FF17375E;
  Values.StartMenuBandEnd := $FF6A97C9;
  Values.StartMenuBandText := $FFFFFFFF;
  Values.TrayFace := $FFCBC6BD;
  Values.TrayText := $FF000000;

  Values.LockTop := $FF0E2236;
  Values.LockBottom := $FF27465E;
  Values.LockText := $FFFFFFFF;
  Values.LockDimText := $FFC8D4DE;
  Values.LockWarningText := $FFFFB0A8;
  Values.LockedBackground := $FF0B1724;
end;

procedure SetClassicStyle(var Values: TTheme);
begin
  Values.TitleGradientVertical := False;
  Values.TitleIcon := False;
  Values.TintedTitleButtons := False;
  Values.StartMenuBand := False;
  Values.TintedStartButton := False;
end;

procedure SetClassicMetrics(var Values: TTheme);
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
  Values.StartMenuBandWidth := 0;
  Values.TitlePoints := 90;
  Values.TextPoints := 90;
  Values.TextFamily := 'dejavu-sans';
  Values.FixedFamily := 'terminus';
end;

{ Every control painting value as the controls were painted before the
  new look. }
procedure SetClassicControlLook(var Values: TTheme);
begin
  Values.ScaledBevelLines := False;
  Values.HotButtonFace := $FFCBC6BD;
  Values.PressedButtonFace := $FFCBC6BD;
  Values.DefaultButtonOutline := 1;
  Values.HeaderBandsShown := False;
  Values.HeaderBandTop := $FFCBC6BD;
  Values.HeaderBandBottom := $FFCBC6BD;
  Values.HeaderBandEdge := $FF7E7A72;
  Values.HeaderBandText := $FF000000;
  Values.SectionBandTop := $FFCBC6BD;
  Values.SectionBandBottom := $FFCBC6BD;
  Values.SectionBandEdge := $FF7E7A72;
  Values.SectionBandText := $FF000000;
  Values.BandedGroupBody := $FFCBC6BD;
  Values.ProgressTrough := $FFCBC6BD;
  Values.ProgressBlock := $FF17375E;
  Values.ProgressBlockLight := $FF17375E;
  Values.MarqueeStripe := $FF17375E;
  Values.MarqueeBackground := $FFCBC6BD;
  Values.MenuIconColumnShown := False;
  Values.MenuIconColumn := $FFCBC6BD;
  Values.CalendarHeaderFilled := False;
  Values.CalendarHeader := $FFCBC6BD;
  Values.CalendarHeaderText := $FF000000;
  Values.TooltipBorder := $FF35322D;
  Values.StatusBarEtched := False;
  Values.SplitterGrip := False;
  { Half way between the face and the highlight. }
  Values.ScrollTrack := $FFE5E3DE;
end;

function ClassicThemeValues: TTheme;
begin
  Result := Default(TTheme);
  Result.Key := ClassicThemeKey;
  Result.DisplayName := 'Classic';
  SetClassicColors(Result);
  SetClassicFrameColors(Result);
  SetClassicShellColors(Result);
  SetClassicStyle(Result);
  SetClassicMetrics(Result);
  SetClassicControlLook(Result);
end;

end.
