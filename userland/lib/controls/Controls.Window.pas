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
  Windows made of controls.

  A TControlWindow has a root control covering its client area; the
  program's controls are its children (and theirs). The window paints
  them (each clipped to itself and its parents), sends the pointer to
  the control under it (and, while a button is held, to the control it
  was pressed on, which gets the pointer captured), sends keys to the
  control with the focus (passing them up to its parents while nobody
  uses them), moves the focus with Tab and Shift+Tab through the
  controls that take it, in the order they were made, and presses the
  default button on Enter and the cancel button on Escape.
}
unit Controls.Window;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Base;

type
  TControlWindow = class(TWindow)
  private
    FRoot: TControl;
    FHost: TControlHost;
    FFocused: TControl;
    FHovered: TControl;
    FPressed: TControl;
    FDefaultControl: TControl;
    FCancelControl: TControl;
    procedure MoveFocus(Forward: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas; const Area: TRectangle); override;
    procedure KeyDown(Code, Character, Modifiers: LongWord); override;
    procedure KeyUp(Code, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure PointerLeave; override;
    procedure Wheel(Steps: LongInt); override;
    procedure Resized; override;
    procedure ActiveChanged; override;
  public
    constructor Create(const ATitle: string; Left, Top, Width, Height: LongInt;
      AFlags: LongWord = WindowFramed or WindowResizable);
    destructor Destroy; override;
    procedure FocusControl(Control: TControl);
    { The controls' parent. }
    property Root: TControl read FRoot;
    property FocusedControl: TControl read FFocused;
    { Clicked by Enter and Escape (buttons, usually). }
    property DefaultControl: TControl read FDefaultControl write FDefaultControl;
    property CancelControl: TControl read FCancelControl write FCancelControl;
  end;

implementation

uses
  Abi.SystemCalls,
  Windowing.Messages,
  Controls.Keys;

type
  { Forwards what controls ask of their host to the window. }
  TWindowHost = class(TControlHost)
  private
    FWindow: TControlWindow;
  public
    constructor Create(Window: TControlWindow);
    procedure InvalidatePixels(const Area: TRectangle); override;
    procedure FocusControl(Control: TControl); override;
    function FocusedControl: TControl; override;
    procedure CapturePointer(Control: TControl); override;
    procedure ControlRemoved(Control: TControl); override;
    function OwnerWindow: TMessageReceiver; override;
  end;

constructor TWindowHost.Create(Window: TControlWindow);
begin
  inherited Create;
  FWindow := Window;
end;

procedure TWindowHost.InvalidatePixels(const Area: TRectangle);
begin
  FWindow.InvalidateRectangle(Area);
end;

procedure TWindowHost.FocusControl(Control: TControl);
begin
  FWindow.FocusControl(Control);
end;

function TWindowHost.FocusedControl: TControl;
begin
  Result := FWindow.FFocused;
end;

procedure TWindowHost.CapturePointer(Control: TControl);
begin
  FWindow.FPressed := Control;
  FWindow.SetCapture(Control <> nil);
end;

function TWindowHost.OwnerWindow: TMessageReceiver;
begin
  Result := FWindow;
end;

procedure TWindowHost.ControlRemoved(Control: TControl);
begin
  if FWindow.FFocused = Control then
    FWindow.FFocused := nil;
  if FWindow.FHovered = Control then
    FWindow.FHovered := nil;
  if FWindow.FPressed = Control then
    FWindow.FPressed := nil;
  if FWindow.FDefaultControl = Control then
    FWindow.FDefaultControl := nil;
  if FWindow.FCancelControl = Control then
    FWindow.FCancelControl := nil;
end;

{ --- TControlWindow --------------------------------------------------------- }

constructor TControlWindow.Create(const ATitle: string; Left, Top, Width, Height: LongInt; AFlags: LongWord);
begin
  FHost := TWindowHost.Create(Self);
  FRoot := CreateRootControl(FHost);
  { The same size the window's surface will have. }
  FRoot.SetPixelBounds(MakeRectangle(0, 0, Scaled(Width), Scaled(Height)));
  inherited Create(ATitle, Left, Top, Width, Height, AFlags);
end;

destructor TControlWindow.Destroy;
begin
  FRoot.Free;
  FRoot := nil;
  inherited Destroy;
  FHost.Free;
end;

procedure TControlWindow.Paint(var Canvas: TCanvas; const Area: TRectangle);
begin
  if FRoot <> nil then
    FRoot.PaintAll(Canvas);
end;

procedure TControlWindow.Resized;
begin
  { In pixels exactly: through logical units a pixel might be lost. }
  FRoot.SetPixelBounds(MakeRectangle(0, 0, PixelWidth, PixelHeight));
  inherited Resized;
end;

procedure TControlWindow.FocusControl(Control: TControl);
var
  Previous: TControl;
begin
  if Control = FFocused then
    Exit;
  Previous := FFocused;
  FFocused := Control;
  if Previous <> nil then
    Previous.HandleFocusChanged;
  if Control <> nil then
    Control.HandleFocusChanged;
end;

procedure TControlWindow.ActiveChanged;
begin
  if FFocused <> nil then
    FFocused.Invalidate;
end;

{ Every visible, enabled control that takes the focus, in tree order. }
procedure CollectFocusable(Control: TControl; var List: array of TControl; var Count: LongInt);
var
  Index: LongInt;
begin
  if not Control.Visible or not Control.Enabled then
    Exit;
  if Control.CanFocus and (Count <= High(List)) then
  begin
    List[Count] := Control;
    Inc(Count);
  end;
  for Index := 0 to Control.ChildCount - 1 do
    CollectFocusable(Control.Children[Index], List, Count);
end;

procedure TControlWindow.MoveFocus(Forward: Boolean);
var
  List: array[0..255] of TControl;
  Count: LongInt;
  Index: LongInt;
  Current: LongInt;
begin
  Count := 0;
  CollectFocusable(FRoot, List, Count);
  if Count = 0 then
    Exit;
  Current := -1;
  for Index := 0 to Count - 1 do
    if List[Index] = FFocused then
      Current := Index;
  if Forward then
    Current := (Current + 1) mod Count
  else if Current <= 0 then
    Current := Count - 1
  else
    Current := Current - 1;
  FocusControl(List[Current]);
end;

procedure TControlWindow.KeyDown(Code, Character, Modifiers: LongWord);
var
  Control: TControl;
begin
  Control := FFocused;
  while Control <> nil do
  begin
    if Control.HandleKeyDown(Code, Character, Modifiers) then
      Exit;
    Control := Control.Parent;
  end;
  if Code = KeyTab then
    MoveFocus((Modifiers and ModifierShift) = 0)
  else if IsEnterKey(Code) and (FDefaultControl <> nil) and FDefaultControl.Enabled then
    FDefaultControl.HandleKeyDown(KeySpace, 32, 0)
  else if (Code = KeyEscape) and (FCancelControl <> nil) and FCancelControl.Enabled then
    FCancelControl.HandleKeyDown(KeySpace, 32, 0);
end;

procedure TControlWindow.KeyUp(Code, Modifiers: LongWord);
begin
  if FFocused <> nil then
    FFocused.HandleKeyUp(Code, Modifiers);
end;

procedure TControlWindow.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Target: TControl;
begin
  if FPressed <> nil then
  begin
    FPressed.HandlePointerMove(X, Y, Buttons);
    Exit;
  end;
  Target := FRoot.ControlAt(X, Y);
  if Target <> FHovered then
  begin
    if FHovered <> nil then
      FHovered.HandlePointerLeave;
    FHovered := Target;
    if Target <> nil then
      Target.HandlePointerEnter;
  end;
  if Target <> nil then
    Target.HandlePointerMove(X, Y, Buttons);
end;

procedure TControlWindow.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Target: TControl;
begin
  Target := FRoot.ControlAt(X, Y);
  if Target = nil then
    Exit;
  { It gets the pointer until the button is let go. }
  FPressed := Target;
  SetCapture(True);
  Target.HandlePointerDown(X, Y, Button);
end;

procedure TControlWindow.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Target: TControl;
begin
  Target := FPressed;
  FPressed := nil;
  SetCapture(False);
  if Target <> nil then
    Target.HandlePointerUp(X, Y, Button);
end;

procedure TControlWindow.PointerLeave;
begin
  if FHovered <> nil then
    FHovered.HandlePointerLeave;
  FHovered := nil;
end;

procedure TControlWindow.Wheel(Steps: LongInt);
begin
  if FHovered <> nil then
    FHovered.HandleWheel(Steps)
  else if FFocused <> nil then
    FFocused.HandleWheel(Steps);
end;

end.
