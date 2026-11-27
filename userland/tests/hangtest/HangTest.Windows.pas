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
  Getting stuck with a window on the display server: a window whose
  program serves it (window-idle, which ends when asked), and windows
  whose program stops serving them, as a program that has stopped
  responding does: their message loop runs (so the program takes
  requests to end), then a timer's handler never returns - sleeping
  (window-hung), spinning (window-spin) or waiting for a lock another
  thread keeps (window-lock). The display server keeps showing them;
  asking does nothing, only ending the program removes them.
}
unit HangTest.Windows;

{$mode objfpc}{$H+}

interface

{ Runs Mode if it is one of these and returns False otherwise. }
function RunWindowMode(const Mode: string): Boolean;

implementation

uses
  SysUtils,
  Sys.Locks,
  Sys.Processes,
  Drawing.Canvas,
  Drawing.Rectangles,
  Windowing.Windows,
  HangTest.Report;

type
  THangWindow = class(TWindow)
  private
    FMode: string;
  protected
    procedure Paint(var Canvas: TCanvas; const Area: TRectangle); override;
    procedure TimerFired(TimerId: LongWord); override;
  end;

const
  HangTimer = 1;
  HangAfterMilliseconds = 300;

var
  HeldLock: TLock;

procedure THangWindow.Paint(var Canvas: TCanvas; const Area: TRectangle);
begin
  FillRectangle(Canvas, Area, $FFC08040);
end;

function KeepLockThread(Argument: Pointer): LongInt;
begin
  AcquireLock(HeldLock);
  SleepForever;
  Result := 0;
end;

procedure THangWindow.TimerFired(TimerId: LongWord);
begin
  StopTimer(HangTimer);
  SayReady(FMode);
  if FMode = 'window-hung' then
    SleepForever
  else if FMode = 'window-spin' then
    SpinForever
  else if FMode = 'window-lock' then
    AcquireLock(HeldLock);
end;

function RunWindowMode(const Mode: string): Boolean;
var
  Window: THangWindow;
begin
  if (Mode <> 'window-idle') and (Mode <> 'window-hung') and (Mode <> 'window-spin') and
     (Mode <> 'window-lock') then
    Exit(False);
  Result := True;
  if Mode = 'window-lock' then
  begin
    InitializeLock(HeldLock);
    StartThreadOrGiveUp(@KeepLockThread, nil);
  end;
  Window := THangWindow.Create('hangtest ' + Mode, 200, 150, 320, 200);
  Window.FMode := Mode;
  Window.Show;
  if Mode = 'window-idle' then
    SayReady(Mode)
  else
    Window.StartTimer(HangTimer, HangAfterMilliseconds);
  RunMessageLoop;
end;

end.
