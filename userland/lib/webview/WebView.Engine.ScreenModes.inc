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
  WebView.Engine: the page's fullscreen and pointer lock (the Fullscreen
  and Pointer Lock APIs, platform/78-screen-modes.js). Both need a user
  gesture (an input event in the last moments); fullscreen is the host's
  (OnFullscreenRequest: the browser window fills the screen), the
  pointer lock the window's (Controls: RequestPointerLock, the display
  server's lock), whose motion becomes mousemove events with movementX
  and movementY at the pointer lock element. Escape leaves the lock,
  else fullscreen; a host that leaves by itself tells FullscreenEnded,
  a lock that ends PointerLockChanged.
}

function TWebEngineView.ScriptScreenMode(Kind: TScreenModeKind; Enter: Boolean): TScriptPermission;
begin
  if Kind = ScreenModeFullscreen then
  begin
    if not Assigned(FOnFullscreenRequest) then
      Exit(ScriptPermissionUnsupported);
    if not Enter then
    begin
      FOnFullscreenRequest(Self, False);
      Exit(ScriptPermissionGranted);
    end;
    if not HasUserGesture then
      Exit(ScriptPermissionDenied);
    { One gesture, one fullscreen. }
    FLastUserGesture := 0;
    if FOnFullscreenRequest(Self, True) then
      Result := ScriptPermissionGranted
    else
      Result := ScriptPermissionDenied;
    Exit;
  end;
  if not Enter then
  begin
    FPointerLockWanted := False;
    RequestPointerLock(False);
    Exit(ScriptPermissionGranted);
  end;
  if not HasUserGesture then
    Exit(ScriptPermissionDenied);
  { Granted now; the window's answer comes as PointerLockChanged (a
    refusal ends the lock the page was told of). }
  FPointerLockWanted := True;
  RequestPointerLock(True);
  Result := ScriptPermissionGranted;
end;

procedure TWebEngineView.MoveLockedPointer(DeltaX, DeltaY: LongInt; Buttons: LongWord);
var
  Target: TElement;
  Scale: Double;
begin
  if FDocument = nil then
    Exit;
  Target := FDocument.PointerLockElement;
  if Target = nil then
    Exit;
  Scale := DeviceScale;
  FMovementX := DeltaX / Scale;
  FMovementY := DeltaY / Scale;
  Target.Retain;
  try
    FireMouse(Target, 'mousemove', 0, 0);
  finally
    Target.Release;
  end;
  FMovementX := 0;
  FMovementY := 0;
end;

procedure TWebEngineView.PointerMoveLocked(DeltaX, DeltaY: LongInt; Buttons: LongWord);
begin
  MoveLockedPointer(DeltaX, DeltaY, Buttons);
end;

procedure TWebEngineView.PointerLockEnded;
begin
  FPointerLockWanted := False;
  if (FExecutor <> nil) and (FDocument <> nil) and (FDocument.PointerLockElement <> nil) then
    TPageScriptExecutor(FExecutor).ScreenModeEnded(ScreenModePointerLock);
  PostWake;
end;

procedure TWebEngineView.PointerLockChanged(Locked: Boolean);
begin
  if not Locked then
    PointerLockEnded;
end;

procedure TWebEngineView.FullscreenEnded;
begin
  if FExecutor <> nil then
    TPageScriptExecutor(FExecutor).ScreenModeEnded(ScreenModeFullscreen);
  PostWake;
end;

function TWebEngineView.LeaveScreenModeByKey: Boolean;
begin
  Result := False;
  if FDocument = nil then
    Exit;
  if FDocument.PointerLockElement <> nil then
  begin
    RequestPointerLock(False);
    PointerLockEnded;
    Exit(True);
  end;
  if (FDocument.FullscreenElement <> nil) and Assigned(FOnFullscreenRequest) then
  begin
    FOnFullscreenRequest(Self, False);
    FullscreenEnded;
    Exit(True);
  end;
end;
