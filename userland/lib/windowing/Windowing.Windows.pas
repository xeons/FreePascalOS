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
  Windows for programs, and the message loop.

  A TWindow is a window on the display server. A program makes its own
  kind by overriding the handlers: Paint draws (into the window's
  surface, clipped to what needs it), the others hear about keys, the
  pointer, the wheel, a new size, activation, closing and timers.
  Positions and sizes given to a window are in logical units; what it
  is told (pointer positions, its surface) is in pixels, as that is
  what is drawn. Scaled and Unscaled convert.

  Invalidate marks what needs painting; the message loop paints it
  before waiting again, then tells the server what changed. A new size
  from the server gets a new surface: painted whole before the server
  sees it, so nothing half drawn shows.

  A window may have an owner, another window of the program (a dialog's
  is the window it asks for): the server keeps it above its owner. A
  disabled window (Enabled False) is never activated by the server and
  gets no input; a click on it brings forward the window it owns.

  When the display's scale changes, every window gets a surface of the
  same logical size at the new scale (ScaleChanged, then Resized, then
  painted whole), so what is laid out in logical units looks the same.

  RunMessageLoop serves every window until QuitMessageLoop, or until the
  last window is gone (if QuitWhenLastWindowCloses). RunModal serves
  them until a flag is set, with one window modal: the program's other
  windows are disabled meanwhile, except for windows that take input
  anyway (pop-ups of the modal window). It also delivers messages posted
  to any receiver (Windowing.Messages): a window is one, and so is every
  control.
}
unit Windowing.Windows;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces,
  Drawing.Canvas,
  Windowing.Protocol,
  Windowing.Messages;

type
  TWindow = class(TMessageReceiver)
  private
    FId: LongWord;
    FFlags: LongWord;
    FTitle: string;
    FSection: Int64;
    FSurface: TSurface;
    FInvalid: TRegion;
    FVisible: Boolean;
    FActive: Boolean;
    FLeft: LongInt;
    FTop: LongInt;
    FOwner: TWindow;
    FEnabled: Boolean;
    { The client area's size in logical units: what it keeps when the
      scale changes. }
    FLogicalWidth: LongInt;
    FLogicalHeight: LongInt;
    function CreateSurface(Width, Height: LongInt; out Section: Int64; out Surface: TSurface): Boolean;
    procedure ReleaseSurface;
    procedure TakeNewSize(Width, Height: LongInt; ScaleWasChanged: Boolean);
    procedure TakeNewScale;
    procedure SetTitle(const Value: string);
    procedure SetEnabled(Value: Boolean);
    function GetClientWidth: LongInt;
    function GetClientHeight: LongInt;
  protected
    { Draws Area (surface pixels; the canvas is clipped to what needs it).
      The default fills with the theme's face colour. }
    procedure Paint(var Canvas: TCanvas; const Area: TRectangle); virtual;
    procedure KeyDown(Code, Character, Modifiers: LongWord); virtual;
    procedure KeyUp(Code, Modifiers: LongWord); virtual;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); virtual;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); virtual;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); virtual;
    procedure PointerLeave; virtual;
    procedure Wheel(Steps: LongInt); virtual;
    { The surface has a new size (Width x Height pixels): lay out again.
      Everything is invalid already. }
    procedure Resized; virtual;
    { The display's scale changed (DisplayScale and DisplayDpi are the new
      ones) and the window has a new surface for its logical size; Resized
      and painting follow. Anything kept in pixels is picked again here. }
    procedure ScaleChanged; virtual;
    procedure ActiveChanged; virtual;
    { The close button (or Alt+F4). The default frees the window. }
    procedure CloseRequested; virtual;
    procedure TimerFired(Id: LongWord); virtual;
    { True if it takes input while another window is modal (pop-ups). }
    function AcceptsInputWhileModal: Boolean; virtual;
  public
    { Left, Top: where the client area goes; Width, Height: its size; all
      in logical units. Flags: Window* (framed and resizable by default).
      AOwner: the window it belongs to and stays above (nil: none).
      Hidden until Show. }
    constructor Create(const ATitle: string; Left, Top, Width, Height: LongInt;
      AFlags: LongWord = WindowFramed or WindowResizable; AOwner: TWindow = nil);
    destructor Destroy; override;
    procedure Show;
    procedure Hide;
    procedure Activate;
    { Moves the client area to (Left, Top), logical units. }
    procedure MoveTo(Left, Top: LongInt);
    procedure Invalidate;
    procedure InvalidateRectangle(const Area: TRectangle);
    { Paints what is invalid now (the loop does this before waiting). }
    procedure PaintNow;
    procedure SetCapture(Capture: Boolean);
    { Calls TimerFired(Id) every Milliseconds until StopTimer. }
    procedure StartTimer(Id: LongWord; Milliseconds: LongWord);
    procedure StopTimer(Id: LongWord);
    property Id: LongWord read FId;
    property Title: string read FTitle write SetTitle;
    property Surface: TSurface read FSurface;
    { The client area in pixels, and in logical units. }
    property PixelWidth: LongInt read FSurface.Width;
    property PixelHeight: LongInt read FSurface.Height;
    property ClientWidth: LongInt read GetClientWidth;
    property ClientHeight: LongInt read GetClientHeight;
    property Visible: Boolean read FVisible;
    property Active: Boolean read FActive;
    property Owner: TWindow read FOwner;
    { A disabled window is not activated and gets no input (the server
      sees to it). }
    property Enabled: Boolean read FEnabled write SetEnabled;
    { Where the client area is on the screen (logical units). }
    property ScreenLeft: LongInt read FLeft;
    property ScreenTop: LongInt read FTop;
  end;

var
  QuitWhenLastWindowCloses: Boolean = True;
  { The window whose modal loop runs (RunModal), or nil. }
  ModalWindow: TWindow;

{ Serves the windows; returns the code given to QuitMessageLoop (0 when
  the last window closed, 1 if the display server went away). }
function RunMessageLoop: LongInt;
procedure QuitMessageLoop(Code: LongInt);
function WindowById(Id: LongWord): TWindow;
{ Serves the windows until Done is set (or the window or the server is
  gone), Window modal meanwhile: the program's other windows are disabled
  until it ends. }
procedure RunModal(Window: TWindow; var Done: Boolean);
{ The modifiers (ModifierShift, ModifierControl, ...) held at the newest
  key or pointer event: what a click was made with (a Ctrl+click). }
function HeldModifiers: LongWord;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Windowing.Theme,
  Windowing.Connection;

const
  MaximumProgramWindows = 64;
  MaximumTimers = 32;
  ReplyTimeout = 5000;

type
  TTimerEntry = record
    Window: TWindow;
    Id: LongWord;
    Handle: Int64;
  end;

var
  WindowList: array[0..MaximumProgramWindows - 1] of TWindow;
  WindowListCount: LongInt;
  Timers: array[0..MaximumTimers - 1] of TTimerEntry;
  TimerCount: LongInt;
  QuitRequested: Boolean;
  QuitCode: LongInt;
  { The flag that ends the innermost modal loop (RunModal), or nil. }
  ModalDone: ^Boolean;
  NewestModifiers: LongWord;

function HeldModifiers: LongWord;
begin
  Result := NewestModifiers;
end;

function WindowById(Id: LongWord): TWindow;
var
  Index: LongInt;
begin
  for Index := 0 to WindowListCount - 1 do
    if WindowList[Index].FId = Id then
      Exit(WindowList[Index]);
  Result := nil;
end;

procedure AddToList(Window: TWindow);
begin
  if WindowListCount < MaximumProgramWindows then
  begin
    WindowList[WindowListCount] := Window;
    Inc(WindowListCount);
  end;
end;

procedure RemoveFromList(Window: TWindow);
var
  Index: LongInt;
begin
  for Index := 0 to WindowListCount - 1 do
    if WindowList[Index] = Window then
    begin
      WindowList[Index] := WindowList[WindowListCount - 1];
      Dec(WindowListCount);
      Exit;
    end;
end;

{ --- TWindow ------------------------------------------------------------------ }

constructor TWindow.Create(const ATitle: string; Left, Top, Width, Height: LongInt; AFlags: LongWord;
  AOwner: TWindow);
var
  Message: TWindowMessage;
begin
  inherited Create;
  FTitle := ATitle;
  FFlags := AFlags;
  FSection := -1;
  FLeft := Left;
  FTop := Top;
  FOwner := AOwner;
  FEnabled := True;
  FLogicalWidth := Width;
  FLogicalHeight := Height;
  ClearRegion(FInvalid);
  if ConnectToDisplay <> ErrorNone then
    raise EInOutError.Create('no display server');
  if not CreateSurface(Scaled(Width), Scaled(Height), FSection, FSurface) then
    raise EOutOfMemory.Create('no memory for a window surface');
  Invalidate;
  PaintNow;
  Message := NewMessage(RequestCreateWindow, 0);
  Message.Left := Left;
  Message.Top := Top;
  Message.SurfaceWidth := FSurface.Width;
  Message.SurfaceHeight := FSurface.Height;
  Message.Flags := FFlags;
  if FOwner <> nil then
    Message.Code := FOwner.FId;
  SetMessageText(Message, PChar(FTitle));
  SendRequest(Message, FSection);
  if not WaitForEvent(EventWindowCreated, ReplyTimeout, Message) then
    raise EInOutError.Create('the display server did not create the window');
  FId := Message.Window;
  AddToList(Self);
end;

destructor TWindow.Destroy;
var
  Message: TWindowMessage;
  Index: LongInt;
begin
  for Index := TimerCount - 1 downto 0 do
    if Timers[Index].Window = Self then
      StopTimer(Timers[Index].Id);
  if FId <> 0 then
  begin
    Message := NewMessage(RequestDestroyWindow, FId);
    SendRequest(Message, -1);
  end;
  RemoveFromList(Self);
  { The server forgets the owner too; the windows it owned stay. }
  for Index := 0 to WindowListCount - 1 do
    if WindowList[Index].FOwner = Self then
      WindowList[Index].FOwner := nil;
  ReleaseSurface;
  inherited Destroy;
end;

function TWindow.CreateSurface(Width, Height: LongInt; out Section: Int64; out Surface: TSurface): Boolean;
var
  Pixels: Pointer;
begin
  Result := False;
  if Width < 1 then
    Width := 1;
  if Height < 1 then
    Height := 1;
  Section := Sys.Objects.CreateSection(QWord(Width) * QWord(Height) * 4);
  if Section < 0 then
    Exit;
  Pixels := MapSection(Section, 0, QWord(Width) * QWord(Height) * 4);
  if Pixels = nil then
  begin
    CloseHandle(Section);
    Section := -1;
    Exit;
  end;
  Surface := SurfaceOnPixels(Pixels, Width, Height, Width * 4);
  Result := True;
end;

procedure TWindow.ReleaseSurface;
begin
  if FSurface.Pixels <> nil then
    UnmapSection(FSurface.Pixels);
  FSurface.Pixels := nil;
  if FSection >= 0 then
    CloseHandle(FSection);
  FSection := -1;
end;

procedure TWindow.TakeNewSize(Width, Height: LongInt; ScaleWasChanged: Boolean);
var
  NewSection: Int64;
  NewSurface: TSurface;
  Message: TWindowMessage;
begin
  if not CreateSurface(Width, Height, NewSection, NewSurface) then
    Exit;
  ReleaseSurface;
  FSection := NewSection;
  FSurface := NewSurface;
  { A size the server gave (the frame dragged) is the logical size from
    now on; a new scale keeps the one there was. }
  if not ScaleWasChanged then
  begin
    FLogicalWidth := Unscaled(Width);
    FLogicalHeight := Unscaled(Height);
  end;
  Invalidate;
  if ScaleWasChanged then
    ScaleChanged;
  Resized;
  { Painted whole before the server shows it; then no damage is due. }
  PaintNow;
  Message := NewMessage(RequestSetSurface, FId);
  Message.SurfaceWidth := FSurface.Width;
  Message.SurfaceHeight := FSurface.Height;
  SendRequest(Message, FSection);
end;

procedure TWindow.TakeNewScale;
begin
  TakeNewSize(Scaled(FLogicalWidth), Scaled(FLogicalHeight), True);
end;

function TWindow.GetClientWidth: LongInt;
begin
  Result := Unscaled(FSurface.Width);
end;

function TWindow.GetClientHeight: LongInt;
begin
  Result := Unscaled(FSurface.Height);
end;

procedure TWindow.SetTitle(const Value: string);
var
  Message: TWindowMessage;
begin
  FTitle := Value;
  if FId = 0 then
    Exit;
  Message := NewMessage(RequestSetTitle, FId);
  SetMessageText(Message, PChar(FTitle));
  SendRequest(Message, -1);
end;

procedure TWindow.SetEnabled(Value: Boolean);
var
  Message: TWindowMessage;
begin
  if FEnabled = Value then
    Exit;
  FEnabled := Value;
  Message := NewMessage(RequestEnableWindow, FId);
  Message.Value := Ord(Value);
  SendRequest(Message, -1);
end;

procedure TWindow.Show;
var
  Message: TWindowMessage;
begin
  PaintNow;
  Message := NewMessage(RequestShowWindow, FId);
  Message.Value := 1;
  SendRequest(Message, -1);
  FVisible := True;
end;

procedure TWindow.Hide;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestShowWindow, FId);
  SendRequest(Message, -1);
  FVisible := False;
end;

procedure TWindow.Activate;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestActivate, FId);
  SendRequest(Message, -1);
end;

procedure TWindow.MoveTo(Left, Top: LongInt);
var
  Message: TWindowMessage;
begin
  FLeft := Left;
  FTop := Top;
  Message := NewMessage(RequestMoveWindow, FId);
  Message.Left := Left;
  Message.Top := Top;
  SendRequest(Message, -1);
end;

procedure TWindow.Invalidate;
begin
  InvalidateRectangle(SurfaceBounds(FSurface));
end;

procedure TWindow.InvalidateRectangle(const Area: TRectangle);
var
  OnSurface: TRectangle;
begin
  if IntersectRectangles(Area, SurfaceBounds(FSurface), OnSurface) then
    AddRectangleToRegion(FInvalid, OnSurface);
end;

procedure TWindow.PaintNow;
var
  Canvas: TCanvas;
  Bounds: TRectangle;
  Message: TWindowMessage;
begin
  if RegionIsEmpty(FInvalid) or (FSurface.Pixels = nil) then
    Exit;
  Bounds := RegionBounds(FInvalid);
  BeginCanvas(Canvas, FSurface);
  SetCanvasClip(Canvas, FInvalid);
  Paint(Canvas, Bounds);
  ClearRegion(FInvalid);
  if FId = 0 then
    Exit;
  Message := NewMessage(RequestDamage, FId);
  Message.Left := Bounds.Left;
  Message.Top := Bounds.Top;
  Message.Width := RectangleWidth(Bounds);
  Message.Height := RectangleHeight(Bounds);
  SendRequest(Message, -1);
end;

procedure TWindow.SetCapture(Capture: Boolean);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestSetCapture, FId);
  Message.Value := Ord(Capture);
  SendRequest(Message, -1);
end;

procedure TWindow.StartTimer(Id: LongWord; Milliseconds: LongWord);
var
  Handle: Int64;
begin
  StopTimer(Id);
  if TimerCount = MaximumTimers then
    Exit;
  Handle := CreateTimer(False);
  if Handle < 0 then
    Exit;
  SetTimer(Handle, Milliseconds, Milliseconds);
  Timers[TimerCount].Window := Self;
  Timers[TimerCount].Id := Id;
  Timers[TimerCount].Handle := Handle;
  Inc(TimerCount);
end;

procedure TWindow.StopTimer(Id: LongWord);
var
  Index: LongInt;
begin
  for Index := 0 to TimerCount - 1 do
    if (Timers[Index].Window = Self) and (Timers[Index].Id = Id) then
    begin
      CloseHandle(Timers[Index].Handle);
      Timers[Index] := Timers[TimerCount - 1];
      Dec(TimerCount);
      Exit;
    end;
end;

procedure TWindow.Paint(var Canvas: TCanvas; const Area: TRectangle);
begin
  FillRectangle(Canvas, Area, Theme.Face);
end;

procedure TWindow.KeyDown(Code, Character, Modifiers: LongWord);
begin
end;

procedure TWindow.KeyUp(Code, Modifiers: LongWord);
begin
end;

procedure TWindow.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
end;

procedure TWindow.PointerDown(X, Y: LongInt; Button: LongWord);
begin
end;

procedure TWindow.PointerUp(X, Y: LongInt; Button: LongWord);
begin
end;

procedure TWindow.PointerLeave;
begin
end;

procedure TWindow.Wheel(Steps: LongInt);
begin
end;

procedure TWindow.Resized;
begin
end;

procedure TWindow.ScaleChanged;
begin
end;

procedure TWindow.ActiveChanged;
begin
end;

procedure TWindow.CloseRequested;
begin
  Free;
end;

procedure TWindow.TimerFired(Id: LongWord);
begin
end;

function TWindow.AcceptsInputWhileModal: Boolean;
begin
  Result := Self = ModalWindow;
end;

{ --- The message loop ------------------------------------------------------------ }

procedure QuitMessageLoop(Code: LongInt);
begin
  QuitRequested := True;
  QuitCode := Code;
end;

{ Every window takes the new scale (from a list taken first: a handler
  might close a window). }
procedure ChangeScale(const Message: TWindowMessage);
var
  Snapshot: array[0..MaximumProgramWindows - 1] of TWindow;
  Count: LongInt;
  Index: LongInt;
begin
  TakeScaleChange(Message);
  Count := WindowListCount;
  for Index := 0 to Count - 1 do
    Snapshot[Index] := WindowList[Index];
  for Index := 0 to Count - 1 do
    if WindowById(Snapshot[Index].FId) = Snapshot[Index] then
      Snapshot[Index].TakeNewScale;
end;

procedure Dispatch(const Message: TWindowMessage);
var
  Window: TWindow;
begin
  if Message.Kind = EventScaleChanged then
  begin
    ChangeScale(Message);
    Exit;
  end;
  if (Message.Kind = EventKey) or (Message.Kind = EventPointerMove) or (Message.Kind = EventPointerButton) then
    NewestModifiers := Message.Modifiers;
  Window := WindowById(Message.Window);
  if Window = nil then
    Exit;
  { The server sends nothing to a disabled window; this drops what was
    already on its way when the modal window started. }
  if (ModalWindow <> nil) and not Window.AcceptsInputWhileModal and
     ((Message.Kind = EventKey) or (Message.Kind = EventPointerMove) or (Message.Kind = EventPointerButton) or
      (Message.Kind = EventWheel)) then
    Exit;
  case Message.Kind of
    EventKey:
      if Message.Value <> 0 then
        Window.KeyDown(Message.Code, Message.Character, Message.Modifiers)
      else
        Window.KeyUp(Message.Code, Message.Modifiers);
    EventPointerMove:
      Window.PointerMove(Message.Left, Message.Top, Message.Code);
    EventPointerButton:
      if Message.Value <> 0 then
        Window.PointerDown(Message.Left, Message.Top, Message.Code)
      else
        Window.PointerUp(Message.Left, Message.Top, Message.Code);
    EventPointerLeave:
      Window.PointerLeave;
    EventWheel:
      Window.Wheel(Message.Value);
    EventResized:
      Window.TakeNewSize(Message.SurfaceWidth, Message.SurfaceHeight, False);
    EventActivated:
      begin
        Window.FActive := Message.Value <> 0;
        Window.ActiveChanged;
      end;
    EventCloseRequested:
      Window.CloseRequested;
    EventMoved:
      begin
        Window.FLeft := Message.Left;
        Window.FTop := Message.Top;
      end;
  end;
end;

procedure PaintInvalidWindows;
var
  Index: LongInt;
begin
  for Index := 0 to WindowListCount - 1 do
    WindowList[Index].PaintNow;
end;

{ True once what was just handled ended the loop being run: then it
  must not wait for more, as nothing more may ever come (OK clicked in a
  dialog is the last thing that happens to it). }
function LoopEnding: Boolean;
begin
  Result := QuitRequested or ((ModalDone <> nil) and ModalDone^) or
    (QuitWhenLastWindowCloses and (WindowListCount = 0));
end;

{ Delivers what has come, paints, and waits for more (once). }
procedure ServeOnce;
var
  Handles: array[0..MaximumTimers + 1] of Int64;
  Count: LongInt;
  Index: LongInt;
  Ready: Int64;
  Message: TWindowMessage;
  Window: TWindow;
  TimerId: LongWord;
begin
  DeliverPostedMessages;
  while NextEvent(Message) do
    Dispatch(Message);
  DeliverPostedMessages;
  if ConnectionBroken then
    Exit;
  PaintInvalidWindows;
  if LoopEnding then
    Exit;
  Handles[0] := DisplayChannel;
  Handles[1] := PostedMessageEvent;
  Count := 2;
  for Index := 0 to TimerCount - 1 do
  begin
    Handles[Count] := Timers[Index].Handle;
    Inc(Count);
  end;
  Ready := WaitForHandles(Slice(Handles, Count), InfiniteWait);
  if (Ready >= 2) and (Ready < Count) then
  begin
    Window := Timers[Ready - 2].Window;
    TimerId := Timers[Ready - 2].Id;
    Window.TimerFired(TimerId);
  end;
end;

function RunMessageLoop: LongInt;
begin
  QuitRequested := False;
  QuitCode := 0;
  repeat
    if ConnectionBroken then
      QuitMessageLoop(1);
    if QuitWhenLastWindowCloses and (WindowListCount = 0) then
      QuitRequested := True;
    if QuitRequested then
      Break;
    ServeOnce;
  until False;
  Result := QuitCode;
end;

function IsListed(Window: TWindow): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to WindowListCount - 1 do
    if WindowList[Index] = Window then
      Exit(True);
  Result := False;
end;

procedure RunModal(Window: TWindow; var Done: Boolean);
var
  Previous: TWindow;
  PreviousDone: ^Boolean;
  Disabled: array[0..MaximumProgramWindows - 1] of TWindow;
  DisabledCount: LongInt;
  Index: LongInt;
begin
  Previous := ModalWindow;
  PreviousDone := ModalDone;
  ModalWindow := Window;
  ModalDone := @Done;
  { The others are disabled for real: the server will not activate them
    or send them input, and a click on one brings this one forward. Only
    the ones disabled here are enabled again afterwards (an outer modal
    window's stay as they were). }
  DisabledCount := 0;
  for Index := 0 to WindowListCount - 1 do
    if WindowList[Index].Enabled and not WindowList[Index].AcceptsInputWhileModal then
    begin
      Disabled[DisabledCount] := WindowList[Index];
      Inc(DisabledCount);
    end;
  for Index := 0 to DisabledCount - 1 do
    Disabled[Index].Enabled := False;
  while not Done and not ConnectionBroken and not QuitRequested and (WindowById(Window.Id) = Window) do
    ServeOnce;
  for Index := 0 to DisabledCount - 1 do
    if IsListed(Disabled[Index]) then
      Disabled[Index].Enabled := True;
  ModalWindow := Previous;
  ModalDone := PreviousDone;
end;

end.
