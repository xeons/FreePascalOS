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

{ WebView.Control: the content process's frames on the screen, and the
  input sent to it. While the renderer is busy (input it has not
  handled for a while), the wheel moves the last frame itself, within
  the document, and the renderer's next frame takes over. }

const
  { Input unanswered this long: the renderer is busy. }
  BusyAfterMilliseconds = 120;
  { CSS pixels per wheel step (as WebView.Engine scrolls). }
  WheelStepCss = 60;

procedure TWebView.Paint(var Canvas: TCanvas);
begin
  if FEngine <> nil then
    Exit;
  FFrames.Paint(Canvas, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
end;

procedure TWebView.Layout;
begin
  inherited Layout;
  SendGeometryIfChanged;
end;

function TWebView.RendererBusy: Boolean;
begin
  Result := (FProcess <> nil) and (FInputSequence <> FFrames.Info.InputHandled) and
    (GetTickCount64 - FInputSentAt >= BusyAfterMilliseconds);
end;

procedure TWebView.SendInput(var Input: TIpcInputEvent);
begin
  if (FProcess = nil) or (FCrashPanel <> nil) then
    Exit;
  SendGeometryIfChanged;
  Inc(FInputSequence);
  Input.Sequence := FInputSequence;
  if FInputSequence - 1 = FFrames.Info.InputHandled then
    FInputSentAt := GetTickCount64;
  SendToProcess(IpcInput, EncodeInputEvent(Input));
end;

{ Moves the last frame by Pixels (down the page for positive), kept
  within the document as the last frame measured it. }
procedure TWebView.ShiftLastFrame(Pixels: Double);
begin
  if FFrames.Shift(Pixels, FInputSequence) then
    Invalidate;
end;

procedure TWebView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Input: TIpcInputEvent;
begin
  SetFocus;
  Input := Default(TIpcInputEvent);
  Input.Kind := InputPointerDown;
  Input.X := X;
  Input.Y := Y;
  Input.Button := Button;
  Input.Modifiers := HeldModifiers;
  SendInput(Input);
end;

procedure TWebView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Input: TIpcInputEvent;
begin
  Input := Default(TIpcInputEvent);
  Input.Kind := InputPointerMove;
  Input.X := X;
  Input.Y := Y;
  Input.Button := Buttons;
  Input.Modifiers := HeldModifiers;
  SendInput(Input);
end;

procedure TWebView.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Input: TIpcInputEvent;
begin
  Input := Default(TIpcInputEvent);
  Input.Kind := InputPointerUp;
  Input.X := X;
  Input.Y := Y;
  Input.Button := Button;
  Input.Modifiers := HeldModifiers;
  SendInput(Input);
end;

procedure TWebView.PointerLeave;
var
  Input: TIpcInputEvent;
begin
  Input := Default(TIpcInputEvent);
  Input.Kind := InputPointerLeave;
  SendInput(Input);
end;

procedure TWebView.Wheel(Steps: LongInt);
var
  Input: TIpcInputEvent;
  Modifiers: LongWord;
begin
  Modifiers := HeldModifiers;
  if RendererBusy and ((Modifiers and (ModifierControl or ModifierShift)) = 0) then
    ShiftLastFrame(-Steps * WheelStepCss * DisplayScale / 100 * FZoom);
  Input := Default(TIpcInputEvent);
  Input.Kind := InputWheel;
  Input.Steps := Steps;
  Input.Modifiers := Modifiers;
  SendInput(Input);
end;

function TWebView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Input: TIpcInputEvent;
begin
  if (FEngine <> nil) or (FProcess = nil) or (FCrashPanel <> nil) then
    Exit(inherited KeyDown(Code, Character, Modifiers));
  Input := Default(TIpcInputEvent);
  Input.Kind := InputKeyDown;
  Input.Code := Code;
  Input.Character := Character;
  Input.Modifiers := Modifiers;
  SendInput(Input);
  Result := True;
end;

procedure TWebView.KeyUp(Code, Modifiers: LongWord);
var
  Input: TIpcInputEvent;
begin
  Input := Default(TIpcInputEvent);
  Input.Kind := InputKeyUp;
  Input.Code := Code;
  Input.Modifiers := Modifiers;
  SendInput(Input);
end;

procedure TWebView.FocusChanged;
begin
  inherited FocusChanged;
  if FEngine <> nil then
  begin
    if Focused then
      FEngine.SetFocus;
    Exit;
  end;
  if (FProcess <> nil) and (Focused <> FSentFocused) then
  begin
    FSentFocused := Focused;
    SendToProcess(IpcSetFocus, EncodeFlag(Focused));
  end;
end;

procedure TWebView.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Input: TIpcInputEvent;
begin
  if FEngine <> nil then
    Exit;
  Input := Default(TIpcInputEvent);
  Input.Kind := InputContextMenu;
  Input.X := X;
  Input.Y := Y;
  Input.FromKeyboard := FromKeyboard;
  SendInput(Input);
end;
