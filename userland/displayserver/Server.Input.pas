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
  minimize hides the window as minimized: Server.WindowStates). The title button under the pointer looks hot, and
  pressed while held (Server.TitleButtons); a double click on a title
  bar maximizes the window or restores it (Server.DoubleClicks). A
  window dropped on another screen takes its scale. Keys go to the
  active window, but for the shell's keys for the whole desktop
  (Server.Hotkeys); Alt+F4 asks it to close. Pointer events carry the
  modifiers held (as the last key event said), so a program can tell a
  Ctrl+click or a Shift+click.

  While a program's drag of data goes on (Server.DataDrag) the pointer,
  its button 1 and the keys are the drag's: no window hears them.

  A mouse's motion goes through its settings (speed, acceleration) and
  its buttons may be swapped (left-handed: Server.MouseSettings). The
  pointer's shape follows what it is over (RefreshPointerShape:
  Server.PointerAreas), and a resize arrow stays while a border is
  dragged.

  While the screen is locked (Server.ScreenLock) only the lock screen's
  windows are under the pointer, capture it or get keys; the shell's
  keys are swallowed and Alt+F4 does nothing.

  A disabled window (the owner of a modal dialog) gets nothing: the
  pointer over it is over no window, and pressing a button on it (its
  frame too) brings its dialog forward instead (ActivateWindow).
}
unit Server.Input;

{$mode objfpc}
{$H+}

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
procedure SetPointerCapture(Window: TServerWindow; Capture: Boolean);
{ The window is going: no hover, capture or drag refers to it. }
procedure ForgetWindowInInput(Window: TServerWindow);
{ Ends a drag of a frame, if one goes on (the scale changed). }
procedure CancelDrag;
{ Ends any drag, capture and hover (the screen was locked or unlocked). }
procedure ReleasePointer;
{ Gives the pointer the shape for where it is now (call before
  composing: windows may have moved or changed their shapes). }
procedure RefreshPointerShape;
{ For a drag of data (Server.DataDrag): whether button 1 is held, the
  keyboard's modifiers, and the pointer let go by whatever window had
  captured it or was under it. }
function LeftButtonHeld: Boolean;
function CurrentKeyboardModifiers: LongWord;
procedure ReleasePointerForDrag;

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
  Server.Scale,
  Server.MouseSettings,
  Server.TitleButtons,
  Server.DoubleClicks,
  Server.PointerAreas,
  Server.WindowStates,
  Server.WindowMoves,
  Server.Hotkeys,
  Server.DataDrag,
  Server.ScreenLock;

const
  EventsPath: PChar = '/dev/events';
  ScanF4 = $3E;

type
  TDrag = (DragNone, DragMove, DragResize, DragButton);

var
  Captured: TServerWindow;
  Hovered: TServerWindow;
  ButtonsHeld: LongWord;
  { Shift, Ctrl, Alt and the locks, from the newest key event. }
  KeyboardModifiers: LongWord;
  Drag: TDrag;
  DragWindow: TServerWindow;
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

procedure SetPointerCapture(Window: TServerWindow; Capture: Boolean);
begin
  if Capture then
  begin
    if WindowUsable(Window) then
      Captured := Window;
  end
  else if Captured = Window then
    Captured := nil;
end;

function LeftButtonHeld: Boolean;
begin
  Result := (ButtonsHeld and (LongWord(1) shl ButtonLeft)) <> 0;
end;

function CurrentKeyboardModifiers: LongWord;
begin
  Result := KeyboardModifiers;
end;

procedure CancelDrag;
begin
  DragWindow := nil;
  Drag := DragNone;
  TrackTitleButton(nil, HitNothing, False);
  if OutlineVisible then
  begin
    AddDamage(Outline);
    OutlineVisible := False;
  end;
end;

procedure SendPointerEvent(Window: TServerWindow; Kind: LongWord; Code: LongWord; Value: LongInt); forward;

procedure ReleasePointer;
begin
  CancelDrag;
  CancelDataDrag;
  Captured := nil;
  if Hovered <> nil then
    SendPointerEvent(Hovered, EventPointerLeave, 0, 0);
  Hovered := nil;
end;

procedure ForgetWindowInInput(Window: TServerWindow);
begin
  if Captured = Window then
    Captured := nil;
  if Hovered = Window then
    Hovered := nil;
  if DragWindow = Window then
    CancelDrag;
  ForgetWindowInTitleButtons(Window);
  ForgetWindowInDoubleClicks(Window);
  ForgetWindowInDataDrag(Window);
end;

procedure SendPointerEvent(Window: TServerWindow; Kind: LongWord; Code: LongWord; Value: LongInt);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(Kind, Window.Id);
  Message.Left := PointerX - Window.ClientLeft;
  Message.Top := PointerY - Window.ClientTop;
  Message.Code := Code;
  Message.Value := Value;
  Message.Modifiers := KeyboardModifiers;
  SendToProgram(Window, Message);
end;

procedure ReleasePointerForDrag;
begin
  Captured := nil;
  if Hovered <> nil then
    SendPointerEvent(Hovered, EventPointerLeave, 0, 0);
  Hovered := nil;
end;

{ The window whose client area the pointer is over (or the captor). }
function PointerTarget: TServerWindow;
begin
  if Captured <> nil then
    Result := Captured
  else
  begin
    Result := WindowAt(PointerX, PointerY);
    if (Result <> nil) and (HitTest(Result, PointerX, PointerY) <> HitClient) then
      Result := nil;
  end;
  if (Result <> nil) and Result.Disabled then
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

procedure StartDrag(Window: TServerWindow; Area: THitArea);
begin
  DragWindow := Window;
  DragArea := Area;
  DragStartX := PointerX;
  DragStartY := PointerY;
  DragStartBounds := ClientRectangle(Window);
  case Area of
    HitTitle:
      if Window.Maximized then
        Drag := DragNone
      else
        Drag := DragMove;
    HitClose, HitMaximize, HitMinimize:
      begin
        Drag := DragButton;
        TrackTitleButton(Window, Area, True);
      end;
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
  Window: TServerWindow;
  Message: TWindowMessage;
begin
  Window := DragWindow;
  TrackTitleButton(nil, HitNothing, False);
  case Drag of
    DragMove:
      begin
        ReportMoveChecks;
        { Dropped on another screen: it takes that screen's scale. }
        SettleWindowOnScreen(Window);
      end;
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
              Message := NewMessage(EventCloseRequested, Window.Id);
              SendToProgram(Window, Message);
            end;
          HitMaximize:
            ToggleMaximized(Window);
          HitMinimize:
            MinimizeWindow(Window);
        end;
  end;
  Drag := DragNone;
  DragWindow := nil;
end;

{ --- Looks and shapes under the pointer --------------------------------------------- }

{ The title button under the pointer is hot (none while the pointer is
  captured or a frame is dragged); the one held is pressed while the
  pointer is over it. }
procedure TrackButtonUnderPointer;
var
  Window: TServerWindow;
begin
  if Drag = DragButton then
  begin
    if HitTest(DragWindow, PointerX, PointerY) = DragArea then
      TrackTitleButton(DragWindow, DragArea, True)
    else
      TrackTitleButton(nil, HitNothing, False);
    Exit;
  end;
  Window := nil;
  if (Drag = DragNone) and (Captured = nil) then
    Window := WindowAt(PointerX, PointerY);
  if (Window = nil) or Window.Disabled then
    TrackTitleButton(nil, HitNothing, False)
  else
    TrackTitleButton(Window, HitTest(Window, PointerX, PointerY), False);
end;

function PointerShapeHere: LongWord;
var
  Window: TServerWindow;
  Area: THitArea;
begin
  if DataDragActive then
    Exit(PointerArrow);
  case Drag of
    DragResize:
      Exit(FramePointerShape(DragArea));
    DragMove, DragButton:
      Exit(PointerArrow);
  end;
  Result := PointerArrow;
  Window := Captured;
  if Window = nil then
    Window := WindowAt(PointerX, PointerY);
  if (Window = nil) or Window.Disabled then
    Exit;
  Area := HitTest(Window, PointerX, PointerY);
  if Area = HitClient then
    Result := ClientPointerShape(Window, PointerX - Window.ClientLeft, PointerY - Window.ClientTop)
  else if Window <> Captured then
    Result := FramePointerShape(Area);
end;

procedure RefreshPointerShape;
var
  Shape: LongWord;
begin
  Shape := PointerShapeHere;
  if Shape = CursorShape then
    Exit;
  { Shown by Server.PointerPresenting: nothing to compose. }
  SetCursorShape(Shape);
end;

{ --- Events ---------------------------------------------------------------------- }

{ The pointer itself is shown after the events (Server.PointerPresenting). }
procedure PointerMoved;
var
  Target: TServerWindow;
begin
  if DataDragActive then
  begin
    DataDragPointerMoved(KeyboardModifiers);
    Exit;
  end;
  TrackButtonUnderPointer;
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

procedure ButtonChanged(Button: LongWord; Pressed: Boolean; Time: QWord);
var
  Window: TServerWindow;
  Area: THitArea;
begin
  Button := ButtonActingAs(Button);
  if Pressed then
    ButtonsHeld := ButtonsHeld or (LongWord(1) shl Button)
  else
    ButtonsHeld := ButtonsHeld and not (LongWord(1) shl Button);
  if DataDragActive then
  begin
    if not Pressed and (Button = ButtonLeft) then
      FinishDataDrag(KeyboardModifiers);
    Exit;
  end;
  if Drag <> DragNone then
  begin
    if not Pressed and (Button = ButtonLeft) then
    begin
      FinishDrag;
      TrackButtonUnderPointer;
    end;
    Exit;
  end;
  if Captured <> nil then
  begin
    if not Captured.Disabled then
      SendPointerEvent(Captured, EventPointerButton, Button, Ord(Pressed));
    Exit;
  end;
  Window := WindowAt(PointerX, PointerY);
  if Window = nil then
    Exit;
  if Window.Disabled then
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
  begin
    if Pressed then
      TitlePressIsDoubleClick(nil, PointerX, PointerY, Time);
    SendPointerEvent(Window, EventPointerButton, Button, Ord(Pressed));
    Exit;
  end;
  if not Pressed or (Button <> ButtonLeft) then
    Exit;
  if Area <> HitTitle then
  begin
    TitlePressIsDoubleClick(nil, PointerX, PointerY, Time);
    StartDrag(Window, Area);
  end
  else if TitlePressIsDoubleClick(Window, PointerX, PointerY, Time) and
     ((Window.Flags and WindowResizable) <> 0) then
    ToggleMaximized(Window)
  else
    StartDrag(Window, Area);
end;

{ The window a key goes to: the active one, unless a pop-up holds the
  pointer for a window that is never active (the taskbar's Start menu
  and other menus): then that window, which gives the key to its
  pop-up, so the menu can be used from the keyboard (Escape closes it). }
function KeyboardTarget: TServerWindow;
var
  Owner: TServerWindow;
begin
  Result := ActiveWindow;
  if Captured = nil then
    Exit;
  Owner := Captured.OwnerWindow;
  if (Owner <> nil) and Owner.Visible and not Owner.Disabled and ((Owner.Flags and WindowNoActivate) <> 0) then
    Result := Owner;
end;

procedure KeyChanged(const Event: TAbiInputEvent);
var
  Message: TWindowMessage;
  Target: TServerWindow;
begin
  { Kept whichever window has the keyboard, for the pointer's events. }
  KeyboardModifiers := Event.Modifiers;
  if DataDragActive then
  begin
    DataDragKey(Event.Code, Event.Value <> 0, KeyboardModifiers);
    Exit;
  end;
  { The shell's keys for the whole desktop come first, whatever window
    is active (Server.Hotkeys). }
  if TakeHotkeyEvent(Event) then
    Exit;
  Target := KeyboardTarget;
  if (Target = nil) or Target.Disabled or not WindowUsable(Target) then
    Exit;
  { Alt+F4 closes the active window (not the taskbar under its menu). }
  if (Target = ActiveWindow) and (Event.Code = ScanF4) and (Event.Value <> 0) and
     ((Event.Modifiers and ModifierAlt) <> 0) then
  begin
    { The lock screen is not closed. }
    if ScreenLocked then
      Exit;
    Message := NewMessage(EventCloseRequested, ActiveWindow.Id);
    SendToProgram(ActiveWindow, Message);
    Exit;
  end;
  Message := NewMessage(EventKey, Target.Id);
  Message.Code := Event.Code;
  Message.Value := Event.Value;
  Message.Character := Event.Character;
  Message.Modifiers := Event.Modifiers;
  SendToProgram(Target, Message);
end;

procedure WheelTurned(Steps: LongInt);
var
  Target: TServerWindow;
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
  DeltaX: LongInt;
  DeltaY: LongInt;
begin
  Got := KernelRead(InputHandle, @Events[0], SizeOf(Events));
  if Got <= 0 then
    Exit;
  NoteInput;
  for Index := 0 to Got div SizeOf(TAbiInputEvent) - 1 do
  begin
    case Events[Index].Kind of
      InputEventMotion:
        begin
          DeltaX := Events[Index].X;
          DeltaY := Events[Index].Y;
          AdjustMotion(DeltaX, DeltaY);
          MovePointerBy(DeltaX, DeltaY);
          PointerMoved;
        end;
      InputEventPosition:
        begin
          MovePointerToPosition(Events[Index].X, Events[Index].Y);
          PointerMoved;
        end;
      InputEventButton:
        ButtonChanged(Events[Index].Code, Events[Index].Value <> 0, Events[Index].Time);
      InputEventWheel:
        WheelTurned(Events[Index].Value);
      InputEventKey:
        KeyChanged(Events[Index]);
    end;
  end;
end;

end.
