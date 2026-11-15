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
  The display's scale, and changing it while windows are open.

  The scale starts as the display's own (from its DPI). A program may
  ask for another (RequestSetScale, `displayscale`): as if the display
  were that much denser, the DPI goes with it. Everything the server
  draws in logical units follows: the frames and their title font, the
  pointer's arrow. Windows keep their places in logical units (their
  pixels move), and every program is told (EventScaleChanged) so it can
  give its windows surfaces of the same logical size, laid out and
  drawn again at the new scale. A maximized window is maximized again.

  With one display there is one scale. With several, each display will
  have its own, and a window moved onto another display will be told the
  same way.
}
unit Server.Scale;

{$mode objfpc}

interface

const
  MinimumScalePercent = 100;
  MaximumScalePercent = 400;

{ The display's own scale and DPI, at start (loads the title's font). }
procedure SetUpScale(DisplayScalePercent, DisplayDpi: LongWord);
{ Changes the scale to NewPercent (between the limits; else ignored). }
procedure ChangeScale(NewPercent: LongWord);

implementation

uses
  Drawing.Rectangles,
  Font.Text,
  Font.Files,
  Windowing.Protocol,
  Windowing.Theme,
  Server.Theme,
  Server.Screen,
  Server.Cursor,
  Server.Windows,
  Server.Frames,
  Server.Composer,
  Server.Actions,
  Server.Clients,
  Server.Input;

var
  Fonts: TFontSet;
  FontsLoaded: Boolean;
  { What the display itself has: other scales are against these. }
  NativeScalePercent: LongWord;
  NativeDpi: LongWord;

procedure PickTitleFace;
begin
  if FontsLoaded then
    TitleFace := SelectFace(Fonts, Theme.TitlePoints, Dpi, True);
end;

procedure SetUpScale(DisplayScalePercent, DisplayDpi: LongWord);
begin
  NativeScalePercent := DisplayScalePercent;
  NativeDpi := DisplayDpi;
  ScalePercent := DisplayScalePercent;
  Dpi := DisplayDpi;
  FontsLoaded := LoadSystemFonts(Fonts);
  PickTitleFace;
end;

{ A length in pixels at OldPercent, the same in logical units at the
  current scale. }
function Rescaled(Pixels: LongInt; OldPercent: LongWord): LongInt;
begin
  Result := LogicalToPixels(PixelsToLogical(Pixels, OldPercent), ScalePercent);
end;

procedure RescaleWindow(Window: PServerWindow; OldPercent: LongWord);
var
  Restore: TRectangle;
begin
  Restore := Window^.RestoreBounds;
  Window^.RestoreBounds := MakeRectangle(Rescaled(Restore.Left, OldPercent), Rescaled(Restore.Top, OldPercent),
    Rescaled(RectangleWidth(Restore), OldPercent), Rescaled(RectangleHeight(Restore), OldPercent));
  if Window^.Maximized then
  begin
    { Maximized again: the screen is the same, the title bar is not. }
    Window^.Maximized := False;
    Restore := Window^.RestoreBounds;
    ToggleMaximized(Window);
    Window^.RestoreBounds := Restore;
  end
  else
    MoveWindowTo(Window, Rescaled(Window^.ClientLeft, OldPercent), Rescaled(Window^.ClientTop, OldPercent));
end;

procedure TellEveryProgram;
var
  Message: TWindowMessage;
  Index: LongInt;
begin
  Message := NewMessage(EventScaleChanged, 0);
  Message.Width := Display.Width;
  Message.Height := Display.Height;
  Message.Value := Dpi;
  Message.Code := ScalePercent;
  for Index := 0 to ClientCount - 1 do
    SendToClient(Clients[Index], Message);
end;

procedure ChangeScale(NewPercent: LongWord);
var
  OldPercent: LongWord;
  Index: LongInt;
begin
  if (NewPercent < MinimumScalePercent) or (NewPercent > MaximumScalePercent) or (NewPercent = ScalePercent) then
    Exit;
  OldPercent := ScalePercent;
  ScalePercent := NewPercent;
  Dpi := (NativeDpi * NewPercent + NativeScalePercent div 2) div NativeScalePercent;
  PickTitleFace;
  SetPointerScale(ScalePercent);
  { A drag's outline and starting point were in the old pixels. }
  CancelDrag;
  { The programs hear first, so a maximized window's new size comes
    after the new scale. }
  TellEveryProgram;
  for Index := 0 to WindowCount - 1 do
    RescaleWindow(Windows[Index], OldPercent);
  AddDamage(ScreenBounds);
end;

end.
