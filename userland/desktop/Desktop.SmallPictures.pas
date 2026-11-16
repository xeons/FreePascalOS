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
  The taskbar's small pictures: the Start button's mark (a sunrise over
  a hill), the window shown on a task button, and the notification
  icons' pictures (information, a warning, a loudspeaker for the volume,
  crossed out when it is muted, two linked screens for the network). Drawn with shapes on the design
  grid (Desktop.Shapes), usually 16 logical units square.
}
unit Desktop.SmallPictures;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

procedure DrawStartMark(const Canvas: TCanvas; const Box: TRectangle);
procedure DrawTaskWindowMark(const Canvas: TCanvas; const Box: TRectangle);
{ Picture: NotificationPicture* (Windowing.Protocol); an unknown one is
  drawn as information. }
procedure DrawNotificationPicture(const Canvas: TCanvas; Picture: LongWord; const Box: TRectangle);

implementation

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Windowing.Protocol,
  Desktop.Shapes;

const
  OutlineColor = $FF262A30;
  SunColor = $FFF5A623;
  HillColor = $FF2E7D5B;
  SkyColor = $FF2F6DB5;
  InformationColor = $FF2F6DB5;
  WarningColor = $FFF2C230;
  SpeakerColor = $FF4A5360;
  WaveColor = $FF2F6DB5;
  MutedColor = $FFC8323C;
  ScreenColor = $FF5B9BD5;

procedure DrawStartMark(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
begin
  Grid := GridFor(Box);
  DrawGridDisc(Canvas, Grid, 16, 16, 15, SkyColor);
  DrawGridDisc(Canvas, Grid, 16, 15, 7, SunColor);
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(2.5, 21), PrecisePoint(9, 16.5), PrecisePoint(15, 19),
    PrecisePoint(22, 14.5), PrecisePoint(29.5, 20), PrecisePoint(27, 25.5), PrecisePoint(21, 29.5),
    PrecisePoint(11, 29.5), PrecisePoint(5, 25.5)], HillColor, ColorTransparent, 0);
  DrawGridRing(Canvas, Grid, 16, 16, 15, 1.6, OutlineColor);
end;

procedure DrawTaskWindowMark(const Canvas: TCanvas; const Box: TRectangle);
var
  Grid: TPictureGrid;
begin
  Grid := GridFor(Box);
  DrawRoundedBox(Canvas, Grid, 3, 5, 29, 27, 2, $FFF4F2EE, OutlineColor, 2);
  DrawRoundedBox(Canvas, Grid, 4, 6, 28, 12, 1, $FF1F4E79, ColorTransparent, 0);
end;

procedure DrawInformation(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridDisc(Canvas, Grid, 16, 16, 14, InformationColor);
  DrawGridDisc(Canvas, Grid, 16, 9, 2.3, ColorWhite);
  DrawGridLine(Canvas, Grid, 16, 14, 16, 24, 4, ColorWhite);
end;

procedure DrawWarning(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(16, 2.5), PrecisePoint(30, 28.5), PrecisePoint(2, 28.5)],
    WarningColor, OutlineColor, 1.6);
  DrawGridLine(Canvas, Grid, 16, 11, 16, 19.5, 3.4, OutlineColor);
  DrawGridDisc(Canvas, Grid, 16, 24, 2, OutlineColor);
end;

procedure DrawVolume(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(3, 11), PrecisePoint(9, 11), PrecisePoint(16, 4),
    PrecisePoint(16, 28), PrecisePoint(9, 21), PrecisePoint(3, 21)], SpeakerColor, OutlineColor, 1.2);
  { The sound: two arcs, as short strokes bent round the speaker. }
  DrawGridLine(Canvas, Grid, 20, 11.5, 21.5, 16, 2.2, WaveColor);
  DrawGridLine(Canvas, Grid, 21.5, 16, 20, 20.5, 2.2, WaveColor);
  DrawGridLine(Canvas, Grid, 24, 7.5, 27, 16, 2.2, WaveColor);
  DrawGridLine(Canvas, Grid, 27, 16, 24, 24.5, 2.2, WaveColor);
end;

procedure DrawVolumeMuted(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridPolygon(Canvas, Grid, [PrecisePoint(3, 11), PrecisePoint(9, 11), PrecisePoint(16, 4),
    PrecisePoint(16, 28), PrecisePoint(9, 21), PrecisePoint(3, 21)], SpeakerColor, OutlineColor, 1.2);
  { No sound: a red cross where the waves were. }
  DrawGridLine(Canvas, Grid, 20, 11, 29, 21, 2.6, MutedColor);
  DrawGridLine(Canvas, Grid, 29, 11, 20, 21, 2.6, MutedColor);
end;

procedure DrawNetwork(const Canvas: TCanvas; const Grid: TPictureGrid);
begin
  DrawGridLine(Canvas, Grid, 10, 20, 22, 11, 2, OutlineColor);
  DrawRoundedBox(Canvas, Grid, 13, 2, 30, 13, 1.5, ScreenColor, OutlineColor, 1.6);
  DrawRoundedBox(Canvas, Grid, 2, 17, 19, 28, 1.5, ScreenColor, OutlineColor, 1.6);
end;

procedure DrawNotificationPicture(const Canvas: TCanvas; Picture: LongWord; const Box: TRectangle);
var
  Grid: TPictureGrid;
begin
  Grid := GridFor(Box);
  case Picture of
    NotificationPictureWarning:
      DrawWarning(Canvas, Grid);
    NotificationPictureVolume:
      DrawVolume(Canvas, Grid);
    NotificationPictureVolumeMuted:
      DrawVolumeMuted(Canvas, Grid);
    NotificationPictureNetwork:
      DrawNetwork(Canvas, Grid);
  else
    DrawInformation(Canvas, Grid);
  end;
end;

end.
