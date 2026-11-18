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
  The programs' pictures, for the desktop's icons and the Start menu:
  the file manager (an open folder with papers in it), a terminal (a screen with a prompt), a notepad (a ruled page with a
  pencil), the controls (a small window with a check box, a button and
  a slider), swatches (a window with colour samples), the dialogs (a
  window with a folder and colour discs), the Control Panel (a window of
  three sliders, as on a mixing desk) and the task manager (a window
  with a graph of how busy the processors are), the image viewer (a
  framed landscape), the calculator (a display over keys) and the volume
  control (a loudspeaker sounding). Each is the program's own icon (in
  its folder) or the icon theme's picture of it (Controls.IconTheme)
  when there is one, else drawn here with shapes on the design grid
  (Controls.PictureGrid), at any size, chosen by the theme icon's name
  the program's description gives.
}
unit Desktop.ProgramPictures;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Desktop.Programs;

{ Draws Item's icon into Box: its folder's or the theme's, else the
  picture drawn here for its theme icon's name (a little window for a
  name without one). }
procedure DrawProgramPicture(const Canvas: TCanvas; const Item: TDesktopProgram; const Box: TRectangle);

implementation

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Controls.PictureGrid,
  Controls.IconTheme;

const
  OutlineColor = $FF262A30;
  WindowFaceColor = $FFD4D0C8;
  WindowTitleColor = $FF1F4E79;
  ScreenFrameColor = $FF3A4049;
  ScreenColor = $FF10201A;
  PromptColor = $FF6EE08C;
  PageColor = $FFFFFFFF;
  RuleColor = $FF7FA6D6;
  BindingColor = $FFC8553D;
  PencilColor = $FFF2C14E;
  PencilTipColor = $FF3B3226;
  CheckColor = $FF1E7B3A;
  FolderColor = $FFE9C153;
  FolderBackColor = $FFD9A93A;

{ A small window: frame, face and title bar; what is in it is drawn
  over its face (from row 11 down). }
procedure DrawLittleWindow(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawRoundedBox(Canvas, Grid, 3, 5, 29, 28, 1.5, WindowFaceColor, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 4, 6, 28, 10.5, 0.8, WindowTitleColor, ColorTransparent, 0);
  DrawGridDisc(Canvas, Grid, 25.6, 8.2, 1, $FFE0E4EA);
end;

procedure DrawFiles(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  { The folder's back with its tab, two papers standing in it, and its
    front leaning open towards the viewer. }
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(3, 8), PrecisePoint(11, 8), PrecisePoint(13.5, 10.5),
    PrecisePoint(28, 10.5), PrecisePoint(28, 27), PrecisePoint(3, 27)], FolderBackColor, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 7, 5, 22, 22, 0.6, PageColor, OutlineColor, 0.9);
  DrawRoundedBox(Canvas, Grid, 11, 7.5, 25, 23, 0.6, PageColor, OutlineColor, 0.9);
  DrawGridLine(Canvas, Grid, 14, 11.5, 22, 11.5, 0.9, RuleColor);
  DrawGridLine(Canvas, Grid, 14, 14.5, 22, 14.5, 0.9, RuleColor);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(5, 15), PrecisePoint(30.5, 15), PrecisePoint(28, 27),
    PrecisePoint(3, 27)], FolderColor, OutlineColor, 1);
end;

procedure DrawTerminal(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(12, 24), PrecisePoint(20, 24), PrecisePoint(23, 29),
    PrecisePoint(9, 29)], $FF6B737D, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 2, 4, 30, 25, 2.5, ScreenFrameColor, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 5, 7, 27, 22, 1, ScreenColor, ColorTransparent, 0);
  DrawGridLine(Canvas, Grid, 8, 10.5, 12, 13.5, 1.8, PromptColor);
  DrawGridLine(Canvas, Grid, 12, 13.5, 8, 16.5, 1.8, PromptColor);
  DrawGridLine(Canvas, Grid, 14, 17, 20, 17, 1.8, PromptColor);
end;

procedure DrawNotepad(const Canvas: TCanvas; const Grid: TPictureGrid);
var
  Row: LongInt;
begin
  DrawRoundedBox(Canvas, Grid, 6, 3, 25, 29, 1, PageColor, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 6, 3, 25, 7.5, 1, BindingColor, OutlineColor, 1);
  for Row := 0 to 4 do
    DrawGridLine(Canvas, Grid, 9, 11.5 + Row * 3.5, 22, 11.5 + Row * 3.5, 0.9, RuleColor);
  { The pencil, lying across the page's corner. }
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(26.5, 13), PrecisePoint(29.5, 16), PrecisePoint(19, 26.5),
    PrecisePoint(16, 23.5)], PencilColor, OutlineColor, 0.9);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(16, 23.5), PrecisePoint(19, 26.5), PrecisePoint(14.5, 28)],
    PencilTipColor, OutlineColor, 0.9);
end;

procedure DrawControls(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawLittleWindow(Canvas, Grid);
  DrawRoundedBox(Canvas, Grid, 7, 13.5, 12.5, 19, 0.5, PageColor, OutlineColor, 0.9);
  DrawGridLine(Canvas, Grid, 8.2, 16.3, 9.6, 17.7, 1.2, CheckColor);
  DrawGridLine(Canvas, Grid, 9.6, 17.7, 11.6, 14.7, 1.2, CheckColor);
  DrawRoundedBox(Canvas, Grid, 15, 13.5, 26, 19, 1, $FFEDEAE4, OutlineColor, 0.9);
  DrawGridLine(Canvas, Grid, 7, 23.5, 26, 23.5, 1, $FF7E7A72);
  DrawGridDisc(Canvas, Grid, 18, 23.5, 2.2, WindowTitleColor);
end;

procedure DrawSwatches(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawLittleWindow(Canvas, Grid);
  DrawRoundedBox(Canvas, Grid, 6.5, 13.5, 12.5, 19.5, 0.8, $FFD9534F, OutlineColor, 0.8);
  DrawRoundedBox(Canvas, Grid, 13.5, 13.5, 19.5, 19.5, 0.8, $FF30A040, OutlineColor, 0.8);
  DrawRoundedBox(Canvas, Grid, 20.5, 13.5, 26.5, 19.5, 0.8, $FF3B73C4, OutlineColor, 0.8);
  DrawGridLine(Canvas, Grid, 7, 23.5, 26, 23.5, 1, $FF7E7A72);
  DrawGridDisc(Canvas, Grid, 12, 23.5, 2.2, WindowTitleColor);
end;

procedure DrawDialogs(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawLittleWindow(Canvas, Grid);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(6, 14), PrecisePoint(10, 14), PrecisePoint(11.5, 15.5),
    PrecisePoint(16, 15.5), PrecisePoint(16, 24), PrecisePoint(6, 24)], FolderColor, OutlineColor, 0.9);
  DrawGridDisc(Canvas, Grid, 21, 16.5, 3, WithAlpha($FFD9534F, 220));
  DrawGridDisc(Canvas, Grid, 24.5, 21, 3, WithAlpha($FF30A040, 220));
  DrawGridDisc(Canvas, Grid, 19.5, 22, 3, WithAlpha($FF3B73C4, 220));
end;

procedure DrawControlPanel(const Canvas: TCanvas; const Grid: TPictureGrid);
const
  KnobRows: array[0..2] of Double = (16, 22.5, 18.5);
var
  Index: LongInt;
  Column: Double;
begin
  DrawLittleWindow(Canvas, Grid);
  for Index := 0 to 2 do
  begin
    Column := 9.5 + Index * 6.5;
    DrawGridLine(Canvas, Grid, Column, 13.5, Column, 25.5, 1.2, $FF7E7A72);
    DrawRoundedBox(Canvas, Grid, Column - 2.6, KnobRows[Index] - 1.6, Column + 2.6, KnobRows[Index] + 1.6, 0.6,
      WindowTitleColor, OutlineColor, 0.7);
  end;
end;

procedure DrawTaskManager(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawLittleWindow(Canvas, Grid);
  DrawRoundedBox(Canvas, Grid, 6, 13, 26, 25.5, 0.5, ScreenColor, OutlineColor, 0.8);
  DrawGridLine(Canvas, Grid, 6, 19.25, 26, 19.25, 0.4, $FF2E5A44);
  DrawGridLine(Canvas, Grid, 16, 13, 16, 25.5, 0.4, $FF2E5A44);
  DrawGridLine(Canvas, Grid, 7, 23, 10.5, 20, 1.2, PromptColor);
  DrawGridLine(Canvas, Grid, 10.5, 20, 13.5, 22, 1.2, PromptColor);
  DrawGridLine(Canvas, Grid, 13.5, 22, 18, 15.5, 1.2, PromptColor);
  DrawGridLine(Canvas, Grid, 18, 15.5, 21.5, 18.5, 1.2, PromptColor);
  DrawGridLine(Canvas, Grid, 21.5, 18.5, 25, 16, 1.2, PromptColor);
end;

procedure DrawImageViewer(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawRoundedBox(Canvas, Grid, 3, 6, 29, 27, 1, $FF8A6A44, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 5.5, 8.5, 26.5, 24.5, 0.3, $FF9CCBEF, ColorTransparent, 0);
  DrawGridDisc(Canvas, Grid, 21, 13, 2.4, PencilColor);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(5.5, 24.5), PrecisePoint(5.5, 20), PrecisePoint(11, 14.5),
    PrecisePoint(17, 20.5), PrecisePoint(20, 18), PrecisePoint(26.5, 23), PrecisePoint(26.5, 24.5)], $FF4E9A4A,
    ColorTransparent, 0);
end;

procedure DrawCalculator(const Canvas: TCanvas; const Grid: TPictureGrid);
var
  Row: LongInt;
  Column: LongInt;
  KeyColor: LongWord;
begin
  DrawRoundedBox(Canvas, Grid, 7, 3, 25, 29, 2, ScreenFrameColor, OutlineColor, 1);
  DrawRoundedBox(Canvas, Grid, 9.5, 5.5, 22.5, 11, 0.6, $FFBFD8B0, OutlineColor, 0.6);
  for Row := 0 to 3 do
    for Column := 0 to 2 do
    begin
      KeyColor := $FFE6E3DC;
      if Column = 2 then
        KeyColor := BindingColor;
      DrawRoundedBox(Canvas, Grid, 9.5 + Column * 4.5, 13 + Row * 3.9, 12.7 + Column * 4.5, 15.9 + Row * 3.9, 0.5,
        KeyColor, ColorTransparent, 0);
    end;
end;

procedure DrawVolumeControl(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(4, 12.5), PrecisePoint(9, 12.5), PrecisePoint(16, 6),
    PrecisePoint(16, 26), PrecisePoint(9, 19.5), PrecisePoint(4, 19.5)], ScreenFrameColor, OutlineColor, 1);
  DrawGridLine(Canvas, Grid, 19.5, 12.5, 20.5, 16, 1.4, WindowTitleColor);
  DrawGridLine(Canvas, Grid, 20.5, 16, 19.5, 19.5, 1.4, WindowTitleColor);
  DrawGridLine(Canvas, Grid, 23, 9.5, 25, 16, 1.4, WindowTitleColor);
  DrawGridLine(Canvas, Grid, 25, 16, 23, 22.5, 1.4, WindowTitleColor);
  DrawGridLine(Canvas, Grid, 26.5, 6.5, 29.5, 16, 1.4, WindowTitleColor);
  DrawGridLine(Canvas, Grid, 29.5, 16, 26.5, 25.5, 1.4, WindowTitleColor);
end;

procedure DrawProgramPicture(const Canvas: TCanvas; const Item: TDesktopProgram; const Box: TRectangle);
var
  Grid: TPictureGrid;
  Name: string;
begin
  if DrawThemeIcon(Canvas, Item.IconName, Box) then
    Exit;
  if (Item.ThemeIconName <> Item.IconName) and DrawThemeIcon(Canvas, Item.ThemeIconName, Box) then
    Exit;
  Grid := GridFor(Box);
  Name := Item.ThemeIconName;
  if Name = 'app-file-manager' then
    DrawFiles(Canvas, Grid)
  else if Name = 'app-terminal' then
    DrawTerminal(Canvas, Grid)
  else if (Name = 'app-text-editor') or (Name = 'app-notepad') then
    DrawNotepad(Canvas, Grid)
  else if Name = 'app-components' then
    DrawControls(Canvas, Grid)
  else if (Name = 'app-themes') or (Name = 'app-paint') then
    DrawSwatches(Canvas, Grid)
  else if Name = 'app-dialogs' then
    DrawDialogs(Canvas, Grid)
  else if Name = 'app-task-manager' then
    DrawTaskManager(Canvas, Grid)
  else if (Name = 'app-control-panel') or (Name = 'app-settings') then
    DrawControlPanel(Canvas, Grid)
  else if Name = 'app-image-viewer' then
    DrawImageViewer(Canvas, Grid)
  else if Name = 'app-calculator' then
    DrawCalculator(Canvas, Grid)
  else if Name = 'app-volume-control' then
    DrawVolumeControl(Canvas, Grid)
  else
    DrawLittleWindow(Canvas, Grid);
end;

end.
