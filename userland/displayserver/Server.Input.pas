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
  Input: the keyboards and pointing devices (/dev/events).

  The pointer moves the arrow, and goes to the window under it (pointer
  events in its surface's pixels) or, while a window has captured it, to
  that window. Pressing a button on a window activates it; on its frame
  it starts dragging: the title bar moves the window as the pointer
  goes, a border or corner shows an outline of the new size and asks
  the program for it when the button is let go, and the title buttons
  act when let go over them (close asks the program, maximize toggles,
  minimize hides). A window dropped on another screen takes its scale.
  Keys go to the active window; Alt+F4 asks it to close. Pointer events
  carry the modifiers held (as the last key event said), so a program
  can tell a Ctrl+click or a Shift+click.

  A disabled window (the owner of a modal dialog) gets nothing: the
  pointer over it is over no window, and pressing a button on it (its
  frame too) brings its dialog forward instead (ActivateWindow).
}
unit Server.Input;

{$mode objfpc}

interface

uses
  Server.Windows;

var
  InputHandle: Int64;

{ ErrorNone or an error code. }
function OpenInput: LongInt;
procedure CloseInput;
{ Reads what has arrived and acts on it (call when the handle is
  signaled). }
procedure ProcessInput;
procedure SetPointerCapture(Window: PServerWindow; Capture: Boolean);
{ The window is going: no hover, capture or drag refers to it. }
procedure ForgetWindowInInput(Window: PServerWindow);
{ Ends a drag of a frame, if one goes on (the scale changed). }
procedure CancelDrag;

implementation

uses
  Windowing.Theme,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Theme,
  Server.Screen,
  Server.Cursor,
  Server.Frames,
  Server.Composer,
  Server.Actions,
  Server.Scale;

const
  EventsPath: PChar = '/dev/events';
  ScanF4 = $3E;

type
  TDrag = (DragNone, DragMove, DragResize, DragButton);

var
  Captured: PServerWindow;
  Hovered: PServerWindow;
  ButtonsHeld: LongWord;
  { Shift, Ctrl, Alt and the locks, from the newest key event. }
  KeyboardModifiers: LongWord;
  Drag: TDrag;
  DragWindow: PServerWindow;
  DragArea: THitArea;
  { Where the pointer was against the window when the drag started. }
  DragStartX: LongInt;
  DragStartY: LongInt;
  DragStartBounds: TRectangle;

function OpenInput: LongInt;
begin
  InputHandle := KernelOpen(EventsPath, OpenRead);
  if InputHandle < 0 then
    Exit(ErrorCodeOf(InputHandle));
  Result := ErrorNone;
end;

procedure CloseInput;
begin
  if InputHandle >= 0 then
    KernelClose(InputHandle);
  InputHandle := -1;
end;

procedure SetPointerCapture(Window: PServerWindow; Capture: Boolean);
begin
  if Capture then
    Captured := Window
  else if Captured = Window then
    Captured := nil;
end;

procedure CancelDrag;
begin
  DragWindow := nil;
  Drag := DragNone;
  if OutlineVisible then
  begin
    AddDamage(Outline);
    OutlineVisible := False;
  end;
end;

procedure ForgetWindowInInput(Window: PServerWindow);
begin
  if Captured = Window then
    Captured := nil;
  if Hovered = Window then
    Hovered := nil;
  if DragWindow = Window then
    CancelDrag;
end;

procedure SendPointerEvent(Window: PServerWindow; Kind: LongWord; Code: LongWord; Value: LongInt);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(Kind, Window^.Id);
  Message.Left := PointerX - Window^.ClientLeft;
  Message.Top := PointerY - Window^.ClientTop;
  Message.Code := Code;
  Message.Value := Value;
  Message.Modifiers := KeyboardModifiers;
  SendToProgram(Window, Message);
end;

{ The window whose client area the pointer is over (or the captor). }
function PointerTarget: PServerWindow;
begin
  if Captured <> nil then
    Result := Captured
  else
  begin
    Result := WindowAt(PointerX, PointerY);
    if (Result <> nil) and (HitTest(Result, PointerX, PointerY) <> HitClient) then
      Result := nil;
  end;
  if (Result <> nil) and Result^.Disabled then
    Result := nil;
end;

{ --- Dragging frames ------------------------------------------------------------ }

{ The client area a resize drag would give, kept to the minimum size. }
function ResizedBounds: TRectangle;
var
  DeltaX: LongInt;
  DeltaY: LongInt;
  MinimumWidth: LongInt;
  MinimumHeight: LongInt;
begin
  Result := DragStartBounds;
  DeltaX := PointerX - DragStartX;
  DeltaY := PointerY - DragStartY;
  if DragArea in [HitLeft, HitTopLeft, HitBottomLeft] then
    Result.Left := Result.Left + DeltaX;
  if DragArea in [HitRight, HitTopRight, HitBottomRight] then
    Result.Right := Result.Right + DeltaX;
  if DragArea in [HitTop, HitTopLeft, HitTopRight] then
    Result.Top := Result.Top + DeltaY;
  if DragArea in [HitBottom, HitBottomLeft, HitBottomRight] then
    Result.Bottom := Result.Bottom + DeltaY;
  MinimumWidth := WindowMetric(DragWindow, Theme.MinimumWidth);
  MinimumHeight := WindowMetric(DragWindow, Theme.MinimumHeight);
  if RectangleWidth(Result) < MinimumWidth then
    if DragArea in [HitLeft, HitTopLeft, HitBottomLeft] then
      Result.Left := Result.Right - MinimumWidth
    else
      Result.Right := Result.Left + MinimumWidth;
  if RectangleHeight(Result) < MinimumHeight then
    if DragArea in [HitTop, HitTopLeft, HitTopRight] then
      Result.Top := Result.Bottom - MinimumHeight
    else
      Result.Bottom := Result.Top + MinimumHeight;
end;

{ The outline: the frame around the client area Bounds. }
procedure ShowOutline(const Bounds: TRectangle);
var
  Border: LongInt;
begin
  if OutlineVisible then
    AddDamage(Outline);
  Border := WindowMetric(DragWindow, Theme.BorderWidth);
  Outline := Bounds;
  Outline.Left := Outline.Left - Border;
  Outline.Right := Outline.Right + Border;
  Outline.Bottom := Outline.Bottom + Border;
  Outline.Top := Outline.Top - Border - WindowMetric(DragWindow, Theme.TitleHeight);
  OutlineVisible := True;
  AddDamage(Outline);
end;

procedure StartDrag(Window: PServerWindow; Area: THitArea);
begin
  DragWindow := Window;
  DragArea := Area;
  DragStartX := PointerX;
  DragStartY := PointerY;
  DragStartBounds := ClientRectangle(Window);
  case Area of
    HitTitle:
      if Window^.Maximized then
        Drag := DragNone
      else
        Drag := DragMove;
    HitClose, HitMaximize, HitMinimize:
      Drag := DragButton;
    HitLeft, HitRight, HitTop, HitBottom, HitTopLeft, HitTopRight, HitBottomLeft, HitBottomRight:
      begin
        Drag := DragResize;
        ShowOutline(DragStartBounds);
      end;
  else
    Drag := DragNone;
  end;
end;

procedure FinishDrag;
var
  Window: PServerWindow;
  Message: TWindowMessage;
begin
  Window := DragWindow;
  case Drag of
    DragMove:
      { Dropped on another screen: it takes that screen's scale. }
      SettleWindowOnScreen(Window);
    DragResize:
      begin
        AddDamage(Outline);
        OutlineVisible := False;
        RequestResize(Window, ResizedBounds);
        SettleWindowOnScreen(Window);
      end;
    DragButton:
      if HitTest(Window, PointerX, PointerY) = DragArea then
        case DragArea of
          HitClose:
            begin
              Message := NewMessage(EventCloseRequested, Window^.Id);
              SendToProgram(Window, Message);
            end;
          HitMaximize:
            ToggleMaximized(Window);
          HitMinimize:
            ShowWindow(Window, False);
        end;
  end;
  Drag := DragNone;
  DragWindow := nil;
end;

{ --- Events ---------------------------------------------------------------------- }

procedure PointerMoved(OldCursor: TRectangle);
var
  Target: PServerWindow;
begin
  AddDamage(OldCursor);
  AddDamage(CursorRectangle);
  case Drag of
    DragMove:
      begin
        MoveWindowTo(DragWindow, DragStartBounds.Left + PointerX - DragStartX,
          DragStartBounds.Top + PointerY - DragStartY);
        Exit;
      end;
    DragResize:
      begin
        ShowOutline(ResizedBounds);
        Exit;
      end;
    DragButton:
      Exit;
  end;
  Target := PointerTarget;
  if (Hovered <> nil) and (Hovered <> Target) then
    SendPointerEvent(Hovered, EventPointerLeave, 0, 0);
  Hovered := Target;
  if Target <> nil then
    SendPointerEvent(Target, EventPointerMove, ButtonsHeld, 0);
end;

procedure ButtonChanged(Button: LongWord; Pressed: Boolean);
var
  Window: PServerWindow;
  Area: THitArea;
begin
  if Pressed then
    ButtonsHeld := ButtonsHeld or (LongWord(1) shl Button)
  else
    ButtonsHeld := ButtonsHeld and not (LongWord(1) shl Button);
  if Drag <> DragNone then
  begin
    if not Pressed and (Button = ButtonLeft) then
      FinishDrag;
    Exit;
  end;
  if Captured <> nil then
  begin
    if not Captured^.Disabled then
      SendPointerEvent(Captured, EventPointerButton, Button, Ord(Pressed));
    Exit;
  end;
  Window := WindowAt(PointerX, PointerY);
  if Window = nil then
    Exit;
  if Window^.Disabled then
  begin
    { Its dialog comes forward instead; it is not moved or resized. }
    if Pressed then
      ActivateWindow(Window);
    Exit;
  end;
  Area := HitTest(Window, PointerX, PointerY);
  if Pressed then
    ActivateWindow(Window);
  if Area = HitClient then
    SendPointerEvent(Window, EventPointerButton, Button, Ord(Pressed))
  else if Pressed and (Button = ButtonLeft) then
    StartDrag(Window, Area);
end;

procedure KeyChanged(const Event: TAbiInputEvent);
var
  Message: TWindowMessage;
begin
  { Kept whichever window has the keyboard, for the pointer's events. }
  KeyboardModifiers := Event.Modifiers;
  if (ActiveWindow = nil) or ActiveWindow^.Disabled then
    Exit;
  if (Event.Code = ScanF4) and (Event.Value <> 0) and ((Event.Modifiers and ModifierAlt) <> 0) then
  begin
    Message := NewMessage(EventCloseRequested, ActiveWindow^.Id);
    SendToProgram(ActiveWindow, Message);
    Exit;
  end;
  Message := NewMessage(EventKey, ActiveWindow^.Id);
  Message.Code := Event.Code;
  Message.Value := Event.Value;
  Message.Character := Event.Character;
  Message.Modifiers := Event.Modifiers;
  SendToProgram(ActiveWindow, Message);
end;

procedure WheelTurned(Steps: LongInt);
var
  Target: PServerWindow;
begin
  Target := PointerTarget;
  if Target <> nil then
    SendPointerEvent(Target, EventWheel, 0, Steps);
end;

procedure ProcessInput;
var
  Events: array[0..31] of TAbiInputEvent;
  Got: Int64;
  Index: LongInt;
  OldCursor: TRectangle;
begin
  Got := KernelRead(InputHandle, @Events[0], SizeOf(Events));
  if Got <= 0 then
    Exit;
  for Index := 0 to Got div SizeOf(TAbiInputEvent) - 1 do
  begin
    OldCursor := CursorRectangle;
    case Events[Index].Kind of
      InputEventMotion:
        begin
          MovePointerBy(Events[Index].X, Events[Index].Y);
          PointerMoved(OldCursor);
        end;
      InputEventPosition:
        begin
          MovePointerToPosition(Events[Index].X, Events[Index].Y);
          PointerMoved(OldCursor);
        end;
      InputEventButton:
        ButtonChanged(Events[Index].Code, Events[Index].Value <> 0);
      InputEventWheel:
        WheelTurned(Events[Index].Value);
      InputEventKey:
        KeyChanged(Events[Index]);
    end;
  end;
end;

end.
