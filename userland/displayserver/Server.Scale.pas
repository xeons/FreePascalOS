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
  Each screen's scale, and changing it (or the screen's size) while
  windows are open; windows moving from one screen to another.

  A screen's scale starts as the display's own (from its DPI). A program
  may ask for another (RequestSetScale, `displayscale`): as if the
  display were that much denser, the DPI goes with it. Everything the
  server draws on that screen in logical units follows: the frames and
  their title font, the pointer's arrow.

  When a screen changes (its scale here, its mode in Server.Modes) the
  screens are laid out again. Every window keeps its place on its own
  screen: its offset from the screen's top left, in that screen's
  logical units (so on the changed screen its pixels move if the scale
  did, and on the screens to its right it moves with its screen). Each
  window on the changed screen is told its new scale (EventScaleChanged
  for it) so its program gives it a surface of the same logical size,
  laid out and drawn again; a maximized one is maximized again, and
  after a new mode the others are moved onto the screen if they would
  hang off it. Every program is told where its windows are now (their
  logical places may have moved with the screens' logical layout), and
  when display 0 changed, about that (EventScaleChanged for window 0).

  A window dragged (or moved by its program) onto another screen takes
  that screen's scale: its frame at once, its program when told.
}
unit Server.Scale;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Server.Screen,
  Server.Windows;

const
  MinimumScalePercent = 100;
  MaximumScalePercent = 400;

{ Loads the title's font and picks it for every screen's DPI. }
procedure SetUpScales;
{ Changes Screen's scale to NewPercent (between the limits; else
  ignored). }
procedure ChangeScale(Screen: PScreen; NewPercent: LongWord);
{ Puts the window on the screen the middle of its frame is on, telling
  its program if that changes its scale. }
procedure SettleWindowOnScreen(Window: PServerWindow);

{ For Server.Modes: what a change to a screen needs. Places are taken
  before the change and given back after it. }
type
  TWindowPlace = record
    ScreenNumber: LongInt;
    { The client area's and its restored bounds' offsets from the
      screen's top left, in pixels. }
    OffsetX: LongInt;
    OffsetY: LongInt;
    RestoreOffset: TRectangle;
  end;
  TWindowPlaces = array[0..MaximumWindows - 1] of TWindowPlace;

  TScreenState = record
    ScalePercent: LongWord;
    Dpi: LongWord;
  end;

procedure RememberWindowPlaces(out Places: TWindowPlaces);
function RememberScreenState(Screen: PScreen): TScreenState;
{ Lays everything out again after Changed changed (from Before), and
  tells the programs. ModeChanged: its size changed too. }
procedure FinishScreenChange(Changed: PScreen; const Before: TScreenState; const Places: TWindowPlaces;
  ModeChanged: Boolean);

implementation

uses
  Font.Text,
  Font.Files,
  Windowing.Protocol,
  Windowing.Theme,
  Server.Desktop,
  Server.Cursor,
  Server.Composer,
  Server.Actions,
  Server.Clients,
  Server.Input;

var
  Fonts: TFontSet;
  FontsLoaded: Boolean;

procedure PickTitleFace(Screen: PScreen);
begin
  if FontsLoaded then
    Screen^.TitleFace := SelectFace(Fonts, Theme.TitlePoints, Screen^.Dpi, True);
end;

procedure SetUpScales;
var
  Index: LongInt;
begin
  FontsLoaded := LoadSystemFonts(Fonts);
  for Index := 0 to ScreenCount - 1 do
    PickTitleFace(@Screens[Index]);
end;

{ --- Windows on screens ----------------------------------------------------- }

function ScaleDiffers(Window: PServerWindow; ScalePercent, Dpi: LongWord): Boolean;
var
  Screen: PScreen;
begin
  Screen := WindowScreen(Window);
  Result := (Screen^.ScalePercent <> ScalePercent) or (Screen^.Dpi <> Dpi);
end;

procedure SettleWindowOnScreen(Window: PServerWindow);
var
  Target: PScreen;
  Previous: PScreen;
begin
  Target := ScreenUnderWindow(Window);
  if Target^.Number = Window^.ScreenNumber then
    Exit;
  Previous := WindowScreen(Window);
  if Window^.Visible then
    DamageWindow(Window);
  Window^.ScreenNumber := Target^.Number;
  if Window^.Visible then
    DamageWindow(Window);
  if ScaleDiffers(Window, Previous^.ScalePercent, Previous^.Dpi) then
    TellWindowScale(Window);
end;

{ --- A screen changing -------------------------------------------------------- }

procedure RememberWindowPlaces(out Places: TWindowPlaces);
var
  Index: LongInt;
  Window: PServerWindow;
  Origin: TRectangle;
begin
  for Index := 0 to WindowCount - 1 do
  begin
    Window := Windows[Index];
    Origin := WindowScreen(Window)^.Bounds;
    Places[Index].ScreenNumber := WindowScreen(Window)^.Number;
    Places[Index].OffsetX := Window^.ClientLeft - Origin.Left;
    Places[Index].OffsetY := Window^.ClientTop - Origin.Top;
    Places[Index].RestoreOffset := OffsetRectangle(Window^.RestoreBounds, -Origin.Left, -Origin.Top);
  end;
end;

function RememberScreenState(Screen: PScreen): TScreenState;
begin
  Result.ScalePercent := Screen^.ScalePercent;
  Result.Dpi := Screen^.Dpi;
end;

{ A length in pixels at OldPercent, the same in logical units at
  NewPercent. }
function Rescaled(Pixels: LongInt; OldPercent, NewPercent: LongWord): LongInt;
begin
  Result := LogicalToPixels(PixelsToLogical(Pixels, OldPercent), NewPercent);
end;

function RescaledRectangle(const Rectangle: TRectangle; OldPercent, NewPercent: LongWord): TRectangle;
begin
  Result := MakeRectangle(Rescaled(Rectangle.Left, OldPercent, NewPercent),
    Rescaled(Rectangle.Top, OldPercent, NewPercent), Rescaled(RectangleWidth(Rectangle), OldPercent, NewPercent),
    Rescaled(RectangleHeight(Rectangle), OldPercent, NewPercent));
end;

{ Moves the window so its frame is on Screen, as far as it fits. }
procedure KeepWindowOnScreen(Window: PServerWindow; Screen: PScreen);
var
  Frame: TRectangle;
  DeltaX: LongInt;
  DeltaY: LongInt;
begin
  Frame := FrameRectangle(Window);
  DeltaX := 0;
  DeltaY := 0;
  if Frame.Right > Screen^.Bounds.Right then
    DeltaX := Screen^.Bounds.Right - Frame.Right;
  if Frame.Left + DeltaX < Screen^.Bounds.Left then
    DeltaX := Screen^.Bounds.Left - Frame.Left;
  if Frame.Bottom > Screen^.Bounds.Bottom then
    DeltaY := Screen^.Bounds.Bottom - Frame.Bottom;
  if Frame.Top + DeltaY < Screen^.Bounds.Top then
    DeltaY := Screen^.Bounds.Top - Frame.Top;
  MoveWindowTo(Window, Window^.ClientLeft + DeltaX, Window^.ClientTop + DeltaY);
end;

procedure MaximizeAgain(Window: PServerWindow);
var
  Restore: TRectangle;
begin
  { The screen or the title bar is another size now. }
  Window^.Maximized := False;
  Restore := Window^.RestoreBounds;
  ToggleMaximized(Window);
  Window^.RestoreBounds := Restore;
end;

procedure TellEveryProgramAboutFirstScreen;
var
  Message: TWindowMessage;
  Index: LongInt;
begin
  Message := NewMessage(EventScaleChanged, 0);
  Message.Width := Screens[0].Device.Width;
  Message.Height := Screens[0].Device.Height;
  Message.Value := Screens[0].Dpi;
  Message.Code := Screens[0].ScalePercent;
  for Index := 0 to ClientCount - 1 do
    SendToClient(Clients[Index], Message);
end;

procedure PlaceWindowAgain(Window: PServerWindow; const Place: TWindowPlace; Changed: PScreen;
  const Before: TScreenState; ModeChanged: Boolean);
var
  Screen: PScreen;
  OffsetX: LongInt;
  OffsetY: LongInt;
  Restore: TRectangle;
begin
  Screen := ScreenByNumber(Place.ScreenNumber);
  OffsetX := Place.OffsetX;
  OffsetY := Place.OffsetY;
  Restore := Place.RestoreOffset;
  if (Screen = Changed) and (Before.ScalePercent <> Changed^.ScalePercent) then
  begin
    OffsetX := Rescaled(OffsetX, Before.ScalePercent, Changed^.ScalePercent);
    OffsetY := Rescaled(OffsetY, Before.ScalePercent, Changed^.ScalePercent);
    Restore := RescaledRectangle(Restore, Before.ScalePercent, Changed^.ScalePercent);
  end;
  Window^.RestoreBounds := OffsetRectangle(Restore, Screen^.Bounds.Left, Screen^.Bounds.Top);
  MoveWindowTo(Window, Screen^.Bounds.Left + OffsetX, Screen^.Bounds.Top + OffsetY);
  if Screen = Changed then
  begin
    { The program hears its scale first, so a maximized window's new size
      comes after it. }
    if (Before.ScalePercent <> Changed^.ScalePercent) or (Before.Dpi <> Changed^.Dpi) then
      TellWindowScale(Window);
    if Window^.Maximized then
      MaximizeAgain(Window)
    else if ModeChanged then
      KeepWindowOnScreen(Window, Changed);
  end;
  { Its logical place may have moved with the screens' layout. }
  TellWindowPlace(Window);
end;

procedure FinishScreenChange(Changed: PScreen; const Before: TScreenState; const Places: TWindowPlaces;
  ModeChanged: Boolean);
var
  Index: LongInt;
begin
  PickTitleFace(Changed);
  { A drag's outline and starting point were in the old pixels. }
  CancelDrag;
  ArrangeScreens;
  if Changed^.Number = 0 then
    TellEveryProgramAboutFirstScreen;
  for Index := 0 to WindowCount - 1 do
    PlaceWindowAgain(Windows[Index], Places[Index], Changed, Before, ModeChanged);
  FollowPointerScreen;
  AddDamage(DesktopBounds);
end;

procedure ChangeScale(Screen: PScreen; NewPercent: LongWord);
var
  Places: TWindowPlaces;
  Before: TScreenState;
begin
  if (NewPercent < MinimumScalePercent) or (NewPercent > MaximumScalePercent) or
     (NewPercent = Screen^.ScalePercent) then
    Exit;
  RememberWindowPlaces(Places);
  Before := RememberScreenState(Screen);
  Screen^.ScalePercent := NewPercent;
  Screen^.Dpi := (Screen^.NativeDpi * NewPercent + Screen^.NativeScalePercent div 2) div Screen^.NativeScalePercent;
  FinishScreenChange(Screen, Before, Places, False);
end;

end.
