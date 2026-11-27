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
  Suspending to RAM for the desktop (the Start menu's Suspend), which
  only root may ask of the kernel (CallSuspend): the session manager
  asks for the user at the screen, as it shuts the computer down for
  them.

  When the user's settings say so (Windowing.LockSettings) the screen
  is locked first, so it is locked when the computer wakes; the kernel
  is asked a moment later (LockSettleMilliseconds), once the lock screen
  is on the screen. Suspending returns when the computer wakes: then the
  display server draws every display again (their memory may not have
  kept the picture) and the desktop's clock catches up by itself.
}
unit Session.Suspend;

{$mode objfpc}
{$H+}

interface

uses
  Session.ScreenLock;

const
  LockSettleMilliseconds = 500;
  { Without the lock: time for the desktop to hear the answer. }
  AnswerSettleMilliseconds = 100;

{ Suspends the computer soon (after locking the screen if the user
  wants it locked on resume). }
procedure SuspendSoon(Lock: TScreenLock);

implementation

uses
  SysUtils,
  Sys.Kernel,
  Sys.Errors,
  Sys.Objects,
  Windowing.HandleWatches,
  Windowing.ScreenLock,
  Session.Report;

type
  TSuspender = class
  private
    FTimer: Int64;
    procedure TimerFired(Handle: Int64);
  public
    procedure Start(Delay: QWord);
  end;

var
  Suspender: TSuspender;

procedure SuspendNow;
var
  Status: Int64;
begin
  Say('suspending');
  Status := KernelSuspend;
  if Status < 0 then
    Say('cannot suspend: ' + string(ErrorMessage(ErrorCodeOf(Status))))
  else
    Say('resumed');
  RepaintDisplays;
end;

procedure TSuspender.Start(Delay: QWord);
begin
  if FTimer >= 0 then
    Exit;
  FTimer := CreateTimer(False);
  if FTimer < 0 then
  begin
    SuspendNow;
    Exit;
  end;
  SetTimer(FTimer, Delay, 0);
  WatchHandle(FTimer, @TimerFired);
end;

procedure TSuspender.TimerFired(Handle: Int64);
begin
  StopWatchingHandle(FTimer);
  CloseHandle(FTimer);
  FTimer := -1;
  SuspendNow;
end;

procedure SuspendSoon(Lock: TScreenLock);
var
  Delay: QWord;
begin
  if Suspender = nil then
  begin
    Suspender := TSuspender.Create;
    Suspender.FTimer := -1;
  end;
  Delay := AnswerSettleMilliseconds;
  if Lock.LocksOnResume and Lock.Lock('suspend') then
    Delay := LockSettleMilliseconds;
  Suspender.Start(Delay);
end;

end.
