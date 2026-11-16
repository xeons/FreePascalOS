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
  The lock screen: a window without a frame over the whole first
  display, showing the clock, the date and whose session it is, and a
  password box with Unlock.

  Unlock (or Enter) hands the password - the password box's own buffer
  (Controls.PasswordBox), never a string - to OnUnlock, which says
  whether it was right. A wrong one empties the box and shows nothing
  for a moment (RefusalDelayMilliseconds, with the box and the button
  disabled), then says it was wrong: passwords cannot be tried quickly.
  The clock is looked at every second. The window cannot be closed.

  The display server keeps everything else off the screen while it is
  locked (Windowing.ScreenLock); this window is only what shows.
}
unit Session.LockWindow;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.Window,
  Controls.Buttons,
  Controls.PasswordBox;

const
  RefusalDelayMilliseconds = 1500;

type
  { True if Password is the session's user's. }
  TUnlockEvent = function(Password: PChar): Boolean of object;

  { Draws the background, the clock, the date and the texts; the
    password box and the button sit on its panel. }
  TLockFace = class(TControl)
  private
    FClock: string;
    FDate: string;
    FUserName: string;
    FMessage: string;
    { Where the panel is (pixels of the face). }
    FPanel: TRectangle;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

  TLockWindow = class(TControlWindow)
  private
    FFace: TLockFace;
    FPasswordBox: TPasswordBox;
    FUnlock: TButton;
    FOnUnlock: TUnlockEvent;
    { The panel's top left (logical units of the window). }
    FPanelLeft: LongInt;
    FPanelTop: LongInt;
    procedure UnlockClicked(Sender: TControl);
    procedure LayOut;
    procedure ShowTime;
    procedure TellPlaces;
  protected
    procedure CloseRequested; override;
    procedure TimerFired(TimerId: LongWord); override;
    procedure Resized; override;
  public
    constructor Create;
    { Shows it afresh over the first display, for UserName: an empty
      box with the keyboard. }
    procedure Present(const UserName: string);
    property OnUnlock: TUnlockEvent read FOnUnlock write FOnUnlock;
  end;

implementation

uses
  SysUtils,
  Drawing.Bevels,
  Sys.Time,
  Sys.LocalTime,
  Windowing.Protocol,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Fonts,
  Controls.Text,
  Session.Report;

const
  ClockTimer = 1;
  RefusalTimer = 2;
  ClockMilliseconds = 1000;
  { Logical units. }
  PanelWidth = 330;
  PanelHeight = 48;
  BoxWidth = 220;
  ButtonWidth = 80;
  ControlHeight = 24;
  { The colours drawn over: a night sky, white text, a soft red. }
  SkyTop = $FF0E2236;
  SkyBottom = $FF27465E;
  LockText = $FFFFFFFF;
  DimText = $FFC8D4DE;
  WarningText = $FFFFB0A8;
  ClockPoints = 480;
  DatePoints = 140;
  NamePoints = 140;
  TextPoints = 100;

{ --- The face ------------------------------------------------------------- }

procedure TLockFace.Paint(var Canvas: TCanvas);
var
  Width: LongInt;
  Height: LongInt;
  Middle: LongInt;
  Line: LongInt;
  LineHeight: LongInt;
begin
  Width := RectangleWidth(PixelBounds);
  Height := RectangleHeight(PixelBounds);
  FillVerticalGradient(Canvas, MakeRectangle(0, 0, Width, Height), SkyTop, SkyBottom);
  Middle := Height div 2;
  { The clock and the date above the middle. }
  LineHeight := TextHeight(FontFace(ClockPoints, False));
  Line := Middle - Scaled(150);
  DrawTextInBox(Canvas, FontFace(ClockPoints, False), FClock, MakeRectangle(0, Line, Width, LineHeight),
    AlignTextCenter, LockText);
  Line := Line + LineHeight;
  LineHeight := TextHeight(FontFace(DatePoints, False));
  DrawTextInBox(Canvas, FontFace(DatePoints, False), FDate, MakeRectangle(0, Line, Width, LineHeight),
    AlignTextCenter, DimText);
  { Whose session it is, and what to do, just above the panel. }
  LineHeight := TextHeight(FontFace(NamePoints, True));
  Line := FPanel.Top - Scaled(8) - TextHeight(FontFace(TextPoints, False)) - LineHeight;
  DrawTextInBox(Canvas, FontFace(NamePoints, True), FUserName, MakeRectangle(0, Line, Width, LineHeight),
    AlignTextCenter, LockText);
  Line := Line + LineHeight;
  LineHeight := TextHeight(FontFace(TextPoints, False));
  DrawTextInBox(Canvas, FontFace(TextPoints, False), 'This computer is locked. Type your password to unlock it.',
    MakeRectangle(0, Line, Width, LineHeight), AlignTextCenter, DimText);
  { The panel the password box and the button sit on. }
  FillRectangle(Canvas, FPanel, Theme.Face);
  DrawBevel(Canvas, FPanel, RaisedThemeBevel);
  if FMessage <> '' then
    DrawTextInBox(Canvas, FontFace(TextPoints, False), FMessage, MakeRectangle(0, FPanel.Bottom + Scaled(10),
      Width, LineHeight), AlignTextCenter, WarningText);
end;

{ --- The window ------------------------------------------------------------ }

constructor TLockWindow.Create;
begin
  inherited Create('Locked', 0, 0, Unscaled(ScreenWidth), Unscaled(ScreenHeight), WindowTopmost);
  FFace := TLockFace.Create(Root);
  FFace.Align := AlignClient;
  FPasswordBox := TPasswordBox.Create(FFace);
  FUnlock := TButton.Create(FFace);
  FUnlock.Text := '&Unlock';
  FUnlock.IsDefault := True;
  FUnlock.OnClick := @UnlockClicked;
  DefaultControl := FUnlock;
  LayOut;
end;

{ The panel in the middle of the window, a little below its centre. }
procedure TLockWindow.LayOut;
begin
  FPanelLeft := (ClientWidth - PanelWidth) div 2;
  FPanelTop := ClientHeight div 2 + 10;
  FFace.FPanel := MakeRectangle(Scaled(FPanelLeft), Scaled(FPanelTop), Scaled(PanelWidth), Scaled(PanelHeight));
  FPasswordBox.SetBounds(FPanelLeft + 12, FPanelTop + 12, BoxWidth, ControlHeight);
  FUnlock.SetBounds(FPanelLeft + PanelWidth - 12 - ButtonWidth, FPanelTop + 12, ButtonWidth, ControlHeight);
  FFace.Invalidate;
end;

procedure TLockWindow.Resized;
begin
  inherited Resized;
  LayOut;
end;

procedure TLockWindow.ShowTime;
var
  Local: TLocalTime;
  Clock: string;
begin
  DecodeLocalTime(CurrentTime, Local);
  Clock := Format('%.2d:%.2d', [Local.DateTime.Hour, Local.DateTime.Minute]);
  FFace.FDate := Format('%s %d %s %d', [string(DayName(Local.DateTime.DayOfWeek)), Local.DateTime.Day,
    string(MonthName(Local.DateTime.Month)), Local.DateTime.Year]);
  if Clock = FFace.FClock then
    Exit;
  FFace.FClock := Clock;
  FFace.Invalidate;
  Say('lock clock ' + Clock);
end;

procedure TLockWindow.TellPlaces;
begin
  SayPlace('lock-password', Self, Scaled(FPanelLeft + 12 + BoxWidth div 2),
    Scaled(FPanelTop + 12 + ControlHeight div 2));
  SayPlace('lock-unlock', Self, Scaled(FPanelLeft + PanelWidth - 12 - ButtonWidth div 2),
    Scaled(FPanelTop + 12 + ControlHeight div 2));
end;

procedure TLockWindow.Present(const UserName: string);
begin
  if (ClientWidth <> Unscaled(ScreenWidth)) or (ClientHeight <> Unscaled(ScreenHeight)) then
    SetClientSize(Unscaled(ScreenWidth), Unscaled(ScreenHeight));
  MoveTo(0, 0);
  FFace.FUserName := UserName;
  FFace.FMessage := '';
  FPasswordBox.Clear;
  FPasswordBox.Enabled := True;
  FUnlock.Enabled := True;
  StopTimer(RefusalTimer);
  ShowTime;
  StartTimer(ClockTimer, ClockMilliseconds);
  LayOut;
  Show;
  Activate;
  FPasswordBox.SetFocus;
  TellPlaces;
end;

procedure TLockWindow.UnlockClicked(Sender: TControl);
var
  Right: Boolean;
begin
  if not FPasswordBox.Enabled then
    Exit;
  Right := Assigned(FOnUnlock) and FOnUnlock(FPasswordBox.Password);
  FPasswordBox.Clear;
  if Right then
  begin
    StopTimer(ClockTimer);
    Exit;
  end;
  { Nothing to try again with for a moment, then the refusal. }
  FFace.FMessage := '';
  FFace.Invalidate;
  FPasswordBox.Enabled := False;
  FUnlock.Enabled := False;
  StartTimer(RefusalTimer, RefusalDelayMilliseconds);
end;

procedure TLockWindow.TimerFired(TimerId: LongWord);
begin
  case TimerId of
    ClockTimer:
      ShowTime;
    RefusalTimer:
      begin
        StopTimer(RefusalTimer);
        FFace.FMessage := 'The password is not right. Try again.';
        FFace.Invalidate;
        FPasswordBox.Enabled := True;
        FUnlock.Enabled := True;
        FPasswordBox.SetFocus;
        Say('lock password refused');
      end;
  else
    inherited TimerFired(TimerId);
  end;
end;

procedure TLockWindow.CloseRequested;
begin
  { Nothing to close to: the window stays until the right password. }
end;

end.
