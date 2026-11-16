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
  window with a folder and colour discs) and the task manager (a window
  with a graph of how busy the processors are). Each is drawn with shapes on
  the design grid (Controls.PictureGrid), at any size.
}
unit Desktop.ProgramPictures;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Desktop.Programs;

procedure DrawProgramPicture(const Canvas: TCanvas; Picture: TProgramPicture; const Box: TRectangle);

implementation

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Controls.PictureGrid;

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

procedure DrawProgramPicture(const Canvas: TCanvas; Picture: TProgramPicture; const Box: TRectangle);
var
  Grid: TPictureGrid;
begin
  Grid := GridFor(Box);
  case Picture of
    PictureFiles:
      DrawFiles(Canvas, Grid);
    PictureTerminal:
      DrawTerminal(Canvas, Grid);
    PictureNotepad:
      DrawNotepad(Canvas, Grid);
    PictureControls:
      DrawControls(Canvas, Grid);
    PictureSwatches:
      DrawSwatches(Canvas, Grid);
    PictureDialogs:
      DrawDialogs(Canvas, Grid);
    PictureTaskManager:
      DrawTaskManager(Canvas, Grid);
  end;
end;

end.
