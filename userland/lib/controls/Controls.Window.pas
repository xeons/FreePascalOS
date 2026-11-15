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
  default button on Enter and the cancel button on Escape. The pointer
  takes the shape of the control under it (or of the one pressed, while
  a button is held).

  Accelerators (AddAccelerator) are keys with modifiers that run a
  handler wherever the focus is (Ctrl+S to save, say): they are looked
  at before the focused control gets the key.

  Mnemonics come next: Alt with a character picks the first visible,
  enabled control (in the order they were made) whose caption has that
  mnemonic, a menu bar heading among them. A window with a menu bar
  (Controls.Menus) gives it the keyboard on F10, or on Alt pressed and
  let go with no other key between: the bar then has a heading picked
  and takes the keys until it lets go of them.
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
  TControlWindow = class;

  { What a window needs of its menu bar (Controls.Menus has the real one):
    the keyboard mode that F10 and Alt start. }
  TWindowMenuBar = class(TControl)
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { Picks the first heading; the bar takes the keys. }
    procedure EnterMenuMode; virtual; abstract;
    { Closes any open menu and picks no heading. }
    procedure LeaveMenuMode; virtual; abstract;
    { A heading picked or its menu open. }
    function InMenuMode: Boolean; virtual; abstract;
  end;

  TAcceleratorEvent = procedure(Sender: TControlWindow) of object;

  TAccelerator = record
    Code: LongWord;
    { Exactly these of Shift, Control and Alt held. }
    Modifiers: LongWord;
    Handler: TAcceleratorEvent;
  end;

  TControlWindow = class(TWindow)
  private
    FAccelerators: array of TAccelerator;
    FRoot: TControl;
    FHost: TControlHost;
    FFocused: TControl;
    FHovered: TControl;
    FPressed: TControl;
    FDefaultControl: TControl;
    FCancelControl: TControl;
    FPopup: TControlWindow;
    FMenuBar: TWindowMenuBar;
    { Alt is down and no other key has been since it went down. }
    FAltPressedAlone: Boolean;
    { The pointer shape the server was last asked for. }
    FShownPointerShape: LongWord;
    procedure ShowPointerShapeOf(Control: TControl);
    procedure MoveFocus(Forward: Boolean);
    function RunAccelerator(Code, Modifiers: LongWord): Boolean;
    function RunMnemonic(Character, Modifiers: LongWord): Boolean;
    procedure ToggleMenuMode;
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
    { As TWindow.Create; AOwner: the window it belongs to (nil: none). }
    constructor Create(const ATitle: string; Left, Top, Width, Height: LongInt;
      AFlags: LongWord = WindowFramed or WindowResizable; AOwner: TWindow = nil);
    destructor Destroy; override;
    procedure FocusControl(Control: TControl);
    procedure FocusControlAfter(Control: TControl);
    { Code (a key code, Controls.Keys) with Modifiers (ModifierShift,
      ModifierControl, ModifierAlt) runs Handler. }
    procedure AddAccelerator(Code, Modifiers: LongWord; Handler: TAcceleratorEvent);
    { The controls' parent. }
    property Root: TControl read FRoot;
    property FocusedControl: TControl read FFocused;
    { Clicked by Enter and Escape (buttons, usually). }
    property DefaultControl: TControl read FDefaultControl write FDefaultControl;
    property CancelControl: TControl read FCancelControl write FCancelControl;
    { An open pop-up (a menu, a dropped list): it gets this window's keys
      (Controls.Popups sets it). }
    property Popup: TControlWindow read FPopup write FPopup;
    { The window's menu bar, if it has one (it sets this itself). }
    property MenuBar: TWindowMenuBar read FMenuBar write FMenuBar;
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
    procedure FocusControlAfter(Control: TControl); override;
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

procedure TWindowHost.FocusControlAfter(Control: TControl);
begin
  FWindow.FocusControlAfter(Control);
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
  if FWindow.FMenuBar = Control then
    FWindow.FMenuBar := nil;
end;

{ --- TWindowMenuBar ---------------------------------------------------------- }

constructor TWindowMenuBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  if (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
    TControlWindow(Host.OwnerWindow).FMenuBar := Self;
end;

destructor TWindowMenuBar.Destroy;
begin
  if (Host <> nil) and (Host.OwnerWindow is TControlWindow) and (TControlWindow(Host.OwnerWindow).FMenuBar = Self) then
    TControlWindow(Host.OwnerWindow).FMenuBar := nil;
  inherited Destroy;
end;

{ --- TControlWindow --------------------------------------------------------- }

constructor TControlWindow.Create(const ATitle: string; Left, Top, Width, Height: LongInt; AFlags: LongWord;
  AOwner: TWindow);
begin
  FHost := TWindowHost.Create(Self);
  FRoot := CreateRootControl(FHost);
  { Connected first: until then the scale is not known, and the controls
    would be laid out for a surface of the wrong size (a program started
    at 150% filled only two thirds of its window). }
  ConnectToDisplay;
  FRoot.SetPixelBounds(MakeRectangle(0, 0, Scaled(Width), Scaled(Height)));
  inherited Create(ATitle, Left, Top, Width, Height, AFlags, AOwner);
  { The surface as made (at the scale of the display the window is on),
    exactly; painted whole before it is shown. }
  FRoot.SetPixelBounds(MakeRectangle(0, 0, PixelWidth, PixelHeight));
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
  { Keys that went to another window in between do not count. }
  FAltPressedAlone := False;
  if (FMenuBar <> nil) and FMenuBar.InMenuMode then
    FMenuBar.LeaveMenuMode;
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

{ The first control that takes the focus after Marker in tree order;
  Passed says whether Marker has been seen. }
function FindFocusableAfter(Control, Marker: TControl; var Passed: Boolean): TControl;
var
  Index: LongInt;
begin
  Result := nil;
  if not Control.Visible or not Control.Enabled then
    Exit;
  if Passed and Control.CanFocus then
    Exit(Control);
  if Control = Marker then
    Passed := True;
  for Index := 0 to Control.ChildCount - 1 do
  begin
    Result := FindFocusableAfter(Control.Children[Index], Marker, Passed);
    if Result <> nil then
      Exit;
  end;
end;

procedure TControlWindow.FocusControlAfter(Control: TControl);
var
  Passed: Boolean;
  Found: TControl;
begin
  Passed := False;
  Found := FindFocusableAfter(FRoot, Control, Passed);
  if Found <> nil then
    FocusControl(Found);
end;

{ The first visible, enabled control in tree order that Character picks. }
function FindMnemonicControl(Control: TControl; Character: LongWord): TControl;
var
  Index: LongInt;
begin
  Result := nil;
  if not Control.Visible or not Control.Enabled then
    Exit;
  if Control.MatchesMnemonic(Character) then
    Exit(Control);
  for Index := 0 to Control.ChildCount - 1 do
  begin
    Result := FindMnemonicControl(Control.Children[Index], Character);
    if Result <> nil then
      Exit;
  end;
end;

function TControlWindow.RunMnemonic(Character, Modifiers: LongWord): Boolean;
var
  Control: TControl;
begin
  Result := False;
  { Alt alone: Ctrl+Alt is how some layouts type characters (AltGr). }
  if (Character = 0) or ((Modifiers and ModifierAlt) = 0) or
     ((Modifiers and (ModifierControl or ModifierAltGr)) <> 0) then
    Exit;
  Control := FindMnemonicControl(FRoot, Character);
  if Control = nil then
    Exit;
  Control.ActivateMnemonic(Character);
  Result := True;
end;

procedure TControlWindow.ToggleMenuMode;
begin
  if FMenuBar = nil then
    Exit;
  if FMenuBar.InMenuMode then
    FMenuBar.LeaveMenuMode
  else if (FPopup = nil) and FMenuBar.Visible and FMenuBar.Enabled then
    FMenuBar.EnterMenuMode;
end;

procedure TControlWindow.AddAccelerator(Code, Modifiers: LongWord; Handler: TAcceleratorEvent);
begin
  SetLength(FAccelerators, Length(FAccelerators) + 1);
  FAccelerators[High(FAccelerators)].Code := Code;
  FAccelerators[High(FAccelerators)].Modifiers := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  FAccelerators[High(FAccelerators)].Handler := Handler;
end;

function TControlWindow.RunAccelerator(Code, Modifiers: LongWord): Boolean;
var
  Index: LongInt;
  Held: LongWord;
begin
  Held := Modifiers and (ModifierShift or ModifierControl or ModifierAlt);
  for Index := 0 to High(FAccelerators) do
    if (FAccelerators[Index].Code = Code) and (FAccelerators[Index].Modifiers = Held) then
    begin
      FAccelerators[Index].Handler(Self);
      Exit(True);
    end;
  Result := False;
end;

procedure TControlWindow.KeyDown(Code, Character, Modifiers: LongWord);
var
  Control: TControl;
begin
  { (Alt repeats while held: still alone.) }
  FAltPressedAlone := Code = KeyAlt;
  if (Code = KeyF10) and ((Modifiers and (ModifierShift or ModifierControl or ModifierAlt)) = 0) and
     (FMenuBar <> nil) then
  begin
    ToggleMenuMode;
    Exit;
  end;
  if FPopup <> nil then
  begin
    FPopup.KeyDown(Code, Character, Modifiers);
    Exit;
  end;
  if (FMenuBar <> nil) and FMenuBar.InMenuMode then
  begin
    FMenuBar.HandleKeyDown(Code, Character, Modifiers);
    Exit;
  end;
  if RunAccelerator(Code, Modifiers) then
    Exit;
  if RunMnemonic(Character, Modifiers) then
    Exit;
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
var
  AltAlone: Boolean;
begin
  { Alt let go with nothing pressed since it went down; a key let go
    in between (one the display server kept, Alt+F4's F4) spoils it. }
  AltAlone := FAltPressedAlone and (Code = KeyAlt);
  FAltPressedAlone := False;
  if AltAlone then
  begin
    ToggleMenuMode;
    Exit;
  end;
  if FFocused <> nil then
    FFocused.HandleKeyUp(Code, Modifiers);
end;

{ Asks the server for the shape the pointer has over Control (nil: the
  arrow), unless it has it already. }
procedure TControlWindow.ShowPointerShapeOf(Control: TControl);
var
  Shape: LongWord;
begin
  Shape := PointerArrow;
  if Control <> nil then
    Shape := Control.PointerShape;
  if Shape = FShownPointerShape then
    Exit;
  FShownPointerShape := Shape;
  SetPointerShape(Shape);
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
  ShowPointerShapeOf(Target);
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
  { A click is not a key: Alt held while clicking is not Alt alone, and
    a click ends the menu bar's keyboard mode. }
  FAltPressedAlone := False;
  if (FMenuBar <> nil) and FMenuBar.InMenuMode and (FPopup = nil) then
    FMenuBar.LeaveMenuMode;
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
