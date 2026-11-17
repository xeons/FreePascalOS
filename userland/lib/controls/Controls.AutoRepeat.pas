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
  Auto-repeat: what a button held down does again and again (the arrows
  of a numeric up/down box), as a held key repeats: once a delay has
  passed, then at a steady rate, until it is let go.

  It runs on a kernel timer the message loop waits on along with the
  windows (Windowing.HandleWatches), so it needs no window of its own;
  the control it belongs to is prepared (its window's scale) before each
  repeat.
}
unit Controls.AutoRepeat;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base;

const
  AutoRepeatDelay = 400;
  AutoRepeatInterval = 60;

type
  TAutoRepeat = class
  private
    FControl: TControl;
    FOnRepeat: TControlEvent;
    FTimer: Int64;
    procedure TimerReady(Handle: Int64);
  public
    { OnRepeat is called with Control as the sender. }
    constructor Create(Control: TControl; OnRepeat: TControlEvent);
    destructor Destroy; override;
    { Starts repeating (after AutoRepeatDelay, then every
      AutoRepeatInterval); again from the start if running. }
    procedure Start;
    procedure Stop;
    function Running: Boolean;
  end;

implementation

uses
  Sys.Objects,
  Windowing.HandleWatches;

constructor TAutoRepeat.Create(Control: TControl; OnRepeat: TControlEvent);
begin
  inherited Create;
  FControl := Control;
  FOnRepeat := OnRepeat;
  FTimer := -1;
end;

destructor TAutoRepeat.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TAutoRepeat.Running: Boolean;
begin
  Result := FTimer >= 0;
end;

procedure TAutoRepeat.Start;
begin
  Stop;
  FTimer := CreateTimer(False);
  if FTimer < 0 then
    Exit;
  SetTimer(FTimer, AutoRepeatDelay, AutoRepeatInterval);
  if not WatchHandle(FTimer, @TimerReady) then
  begin
    CloseHandle(FTimer);
    FTimer := -1;
  end;
end;

procedure TAutoRepeat.Stop;
begin
  if FTimer < 0 then
    Exit;
  StopWatchingHandle(FTimer);
  CloseHandle(FTimer);
  FTimer := -1;
end;

procedure TAutoRepeat.TimerReady(Handle: Int64);
begin
  { (The wait took the timer's signal: it is ready again next period.) }
  if Handle <> FTimer then
    Exit;
  FControl.PrepareToReceive;
  if Assigned(FOnRepeat) then
    FOnRepeat(FControl);
end;

end.
