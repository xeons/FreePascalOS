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
  Controls: the parts of a window a user works with, and the base every
  control is made from, the library's and a program's own alike.

  A control has a parent (another control, or the window's root), its
  children, and bounds in logical units within its parent (or a side to
  dock to: Align). It draws itself in Paint, on a canvas whose origin is
  its own top left (pixels) and which is clipped to it; it hears about
  the pointer (in its own pixels), keys (while it has the focus), focus,
  and its size. A new kind of control overrides those; code that only
  wants to know what happens hooks the On... events instead. A control
  tells its parent what happened through a message (MessageNotify, with
  a code of its own), which also reaches OnNotify.

  Sizes in pixels come from the display's scale (Scaled), so controls
  are the same size on every display.

  A control whose caption can carry a mnemonic ("&OK", Controls.Text)
  says whether a character picks it (MatchesMnemonic) and what picking
  it does (ActivateMnemonic); the window asks them on Alt and a letter.
}
unit Controls.Base;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Messages;

type
  TControl = class;

  TAlign = (AlignNone, AlignTop, AlignBottom, AlignLeft, AlignRight, AlignClient);

  TControlEvent = procedure(Sender: TControl) of object;
  TPointerEvent = procedure(Sender: TControl; X, Y: LongInt; Button: LongWord) of object;
  TKeyEvent = procedure(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean) of object;
  TPaintEvent = procedure(Sender: TControl; var Canvas: TCanvas) of object;
  TNotifyEvent = procedure(Sender: TControl; Child: TControl; Code: LongWord) of object;

  { What a control needs of the window it is in (Controls.Window). }
  TControlHost = class(TMessageReceiver)
  public
    procedure InvalidatePixels(const Area: TRectangle); virtual; abstract;
    procedure FocusControl(Control: TControl); virtual; abstract;
    function FocusedControl: TControl; virtual; abstract;
    procedure CapturePointer(Control: TControl); virtual; abstract;
    procedure ControlRemoved(Control: TControl); virtual; abstract;
    { Focuses the first control after Control (in the order they were
      made) that takes the focus: what a label's mnemonic does. }
    procedure FocusControlAfter(Control: TControl); virtual; abstract;
    { The window the controls are in (to post messages to, say). }
    function OwnerWindow: TMessageReceiver; virtual; abstract;
  end;

  TControl = class(TMessageReceiver)
  private
    FParent: TControl;
    FHost: TControlHost;
    FChildren: TList;
    FBounds: TRectangle;
    FPixelBounds: TRectangle;
    FAlign: TAlign;
    FVisible: Boolean;
    FEnabled: Boolean;
    FCanFocus: Boolean;
    FText: string;
    FTag: PtrInt;
    FOnClick: TControlEvent;
    FOnChange: TControlEvent;
    FOnPointerDown: TPointerEvent;
    FOnKeyDown: TKeyEvent;
    FOnPaint: TPaintEvent;
    FOnNotify: TNotifyEvent;
    FOnFocusChanged: TControlEvent;
    FOnResize: TControlEvent;
    function GetChild(Index: LongInt): TControl;
    function GetChildCount: LongInt;
    procedure SetVisible(Value: Boolean);
    procedure SetEnabled(Value: Boolean);
    procedure SetText(const Value: string);
    procedure SetAlign(Value: TAlign);
    function GetFocused: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); virtual;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); virtual;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); virtual;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); virtual;
    procedure PointerEnter; virtual;
    procedure PointerLeave; virtual;
    procedure Wheel(Steps: LongInt); virtual;
    { True if the key was used (else it goes to the parent). }
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; virtual;
    procedure KeyUp(Code, Modifiers: LongWord); virtual;
    procedure FocusChanged; virtual;
    procedure EnabledChanged; virtual;
    procedure TextChanged; virtual;
    { The size changed: place the children (the default docks those with
      an Align, in order). }
    procedure Layout; virtual;
    { Tells the parent (MessageNotify) and OnNotify listeners. }
    procedure Notify(Code: LongWord);
    procedure Click; virtual;
    procedure Changed; virtual;
    { Whether Character is the mnemonic in this control's Text: for the
      controls whose text is a caption to override MatchesMnemonic with. }
    function TextMatchesMnemonic(Character: LongWord): Boolean;
  public
    constructor Create(AParent: TControl); virtual;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Selects the scale of the window it is in. }
    procedure PrepareToReceive; override;
    { Logical units, within the parent. }
    procedure SetBounds(Left, Top, Width, Height: LongInt);
    { The same without asking the parent to lay out again: for a parent's
      own Layout, placing its children (which it then lays out). }
    procedure AssignBounds(Left, Top, Width, Height: LongInt);
    { The root's place, in pixels (the window's whole surface). }
    procedure SetPixelBounds(const Area: TRectangle);
    procedure Invalidate;
    procedure SetFocus;
    { The child at (X, Y) of this control's pixels, deepest first; Self if
      none. }
    function ControlAt(X, Y: LongInt): TControl;
    { Places itself (pixels) within the parent's pixels, then lays out its
      children. }
    procedure UpdatePixelBounds;
    { Draws itself and its children (the window calls this). }
    procedure PaintAll(var Canvas: TCanvas);
    { The window's handlers call these. }
    procedure HandlePointerDown(X, Y: LongInt; Button: LongWord);
    procedure HandlePointerMove(X, Y: LongInt; Buttons: LongWord);
    procedure HandlePointerUp(X, Y: LongInt; Button: LongWord);
    procedure HandlePointerEnter;
    procedure HandlePointerLeave;
    procedure HandleWheel(Steps: LongInt);
    function HandleKeyDown(Code, Character, Modifiers: LongWord): Boolean;
    { Whether Character (typed with Alt) picks this control; none does
      unless it says so. }
    function MatchesMnemonic(Character: LongWord): Boolean; virtual;
    { Picked by its mnemonic: the default focuses it. }
    procedure ActivateMnemonic(Character: LongWord); virtual;
    procedure HandleKeyUp(Code, Modifiers: LongWord);
    procedure HandleFocusChanged;
    property Parent: TControl read FParent;
    property Host: TControlHost read FHost;
    property ChildCount: LongInt read GetChildCount;
    property Children[Index: LongInt]: TControl read GetChild;
    property Bounds: TRectangle read FBounds;
    { Where it is in the window's surface. }
    property PixelBounds: TRectangle read FPixelBounds;
    property Align: TAlign read FAlign write SetAlign;
    property Visible: Boolean read FVisible write SetVisible;
    property Enabled: Boolean read FEnabled write SetEnabled;
    property CanFocus: Boolean read FCanFocus write FCanFocus;
    property Focused: Boolean read GetFocused;
    property Text: string read FText write SetText;
    { The program's own, for anything. }
    property Tag: PtrInt read FTag write FTag;
    property OnClick: TControlEvent read FOnClick write FOnClick;
    property OnChange: TControlEvent read FOnChange write FOnChange;
    property OnPointerDown: TPointerEvent read FOnPointerDown write FOnPointerDown;
    property OnKeyDown: TKeyEvent read FOnKeyDown write FOnKeyDown;
    property OnPaint: TPaintEvent read FOnPaint write FOnPaint;
    property OnNotify: TNotifyEvent read FOnNotify write FOnNotify;
    property OnFocusChanged: TControlEvent read FOnFocusChanged write FOnFocusChanged;
    property OnResize: TControlEvent read FOnResize write FOnResize;
  end;

  TControlClass = class of TControl;

const
  { What a control's notification says (Message.Parameter2). }
  NotifyClicked = 1;
  NotifyChanged = 2;

{ The root of a window's controls: covers its client area. }
function CreateRootControl(Host: TControlHost): TControl;
{ The control's place on the canvas of the window: the canvas's origin
  moved to its top left and its clip narrowed to it. }
procedure EnterControl(var Canvas: TCanvas; Control: TControl);

implementation

uses
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

{ --- TControl ----------------------------------------------------------------- }

constructor TControl.Create(AParent: TControl);
begin
  inherited Create;
  FChildren := TList.Create;
  FVisible := True;
  FEnabled := True;
  FParent := AParent;
  if FParent <> nil then
  begin
    FHost := FParent.FHost;
    FParent.FChildren.Add(Self);
  end;
end;

destructor TControl.Destroy;
begin
  while FChildren.Count > 0 do
    TControl(FChildren[FChildren.Count - 1]).Free;
  if FHost <> nil then
    FHost.ControlRemoved(Self);
  if FParent <> nil then
  begin
    FParent.FChildren.Remove(Self);
    FParent.Invalidate;
  end;
  FChildren.Free;
  inherited Destroy;
end;

function TControl.GetChild(Index: LongInt): TControl;
begin
  Result := TControl(FChildren[Index]);
end;

function TControl.GetChildCount: LongInt;
begin
  Result := FChildren.Count;
end;

procedure TControl.SetBounds(Left, Top, Width, Height: LongInt);
begin
  if FParent <> nil then
    FParent.Invalidate;
  FBounds := MakeRectangle(Left, Top, Width, Height);
  if FParent <> nil then
    FParent.UpdatePixelBounds;
  Invalidate;
end;

procedure TControl.AssignBounds(Left, Top, Width, Height: LongInt);
begin
  FBounds := MakeRectangle(Left, Top, Width, Height);
end;

procedure TControl.SetPixelBounds(const Area: TRectangle);
begin
  FPixelBounds := Area;
  FBounds := MakeRectangle(0, 0, Unscaled(RectangleWidth(Area)), Unscaled(RectangleHeight(Area)));
  Layout;
  if Assigned(FOnResize) then
    FOnResize(Self);
  Invalidate;
end;

procedure TControl.UpdatePixelBounds;
var
  Origin: TRectangle;
begin
  { The root keeps the pixels it was given. }
  if FParent = nil then
  begin
    Layout;
    Exit;
  end;
  Origin := FParent.FPixelBounds;
  if FAlign = AlignNone then
    FPixelBounds := MakeRectangle(Origin.Left + Scaled(FBounds.Left), Origin.Top + Scaled(FBounds.Top),
      Scaled(RectangleWidth(FBounds)), Scaled(RectangleHeight(FBounds)));
  { (Docked controls were placed by the parent's Layout.) }
  Layout;
  if Assigned(FOnResize) then
    FOnResize(Self);
end;

procedure TControl.Layout;
var
  Index: LongInt;
  Child: TControl;
  Remaining: TRectangle;
  Size: LongInt;
begin
  Remaining := FPixelBounds;
  for Index := 0 to FChildren.Count - 1 do
  begin
    Child := TControl(FChildren[Index]);
    if not Child.FVisible then
      Continue;
    case Child.FAlign of
      AlignTop:
        begin
          Size := Scaled(RectangleHeight(Child.FBounds));
          Child.FPixelBounds := MakeRectangle(Remaining.Left, Remaining.Top, RectangleWidth(Remaining), Size);
          Remaining.Top := Remaining.Top + Size;
        end;
      AlignBottom:
        begin
          Size := Scaled(RectangleHeight(Child.FBounds));
          Child.FPixelBounds := MakeRectangle(Remaining.Left, Remaining.Bottom - Size, RectangleWidth(Remaining), Size);
          Remaining.Bottom := Remaining.Bottom - Size;
        end;
      AlignLeft:
        begin
          Size := Scaled(RectangleWidth(Child.FBounds));
          Child.FPixelBounds := MakeRectangle(Remaining.Left, Remaining.Top, Size, RectangleHeight(Remaining));
          Remaining.Left := Remaining.Left + Size;
        end;
      AlignRight:
        begin
          Size := Scaled(RectangleWidth(Child.FBounds));
          Child.FPixelBounds := MakeRectangle(Remaining.Right - Size, Remaining.Top, Size, RectangleHeight(Remaining));
          Remaining.Right := Remaining.Right - Size;
        end;
      AlignClient:
        Child.FPixelBounds := Remaining;
    end;
  end;
  for Index := 0 to FChildren.Count - 1 do
    TControl(FChildren[Index]).UpdatePixelBounds;
end;

procedure TControl.SetAlign(Value: TAlign);
begin
  FAlign := Value;
  if FParent <> nil then
    FParent.UpdatePixelBounds;
  Invalidate;
end;

procedure TControl.SetVisible(Value: Boolean);
begin
  if FVisible = Value then
    Exit;
  FVisible := Value;
  if FParent <> nil then
  begin
    FParent.UpdatePixelBounds;
    FParent.Invalidate;
  end;
end;

procedure TControl.SetEnabled(Value: Boolean);
begin
  if FEnabled = Value then
    Exit;
  FEnabled := Value;
  EnabledChanged;
  Invalidate;
end;

procedure TControl.SetText(const Value: string);
begin
  if FText = Value then
    Exit;
  FText := Value;
  TextChanged;
  Invalidate;
end;

function TControl.GetFocused: Boolean;
begin
  Result := (FHost <> nil) and (FHost.FocusedControl = Self);
end;

procedure TControl.Invalidate;
begin
  if FHost <> nil then
    FHost.InvalidatePixels(FPixelBounds);
end;

procedure TControl.SetFocus;
begin
  if (FHost <> nil) and FCanFocus and FEnabled and FVisible then
    FHost.FocusControl(Self);
end;

function TControl.ControlAt(X, Y: LongInt): TControl;
var
  Index: LongInt;
  Child: TControl;
begin
  { Last added on top. }
  for Index := FChildren.Count - 1 downto 0 do
  begin
    Child := TControl(FChildren[Index]);
    if Child.FVisible and RectangleContainsPoint(Child.FPixelBounds, X, Y) then
      Exit(Child.ControlAt(X, Y));
  end;
  Result := Self;
end;

procedure EnterControl(var Canvas: TCanvas; Control: TControl);
begin
  SetCanvasOrigin(Canvas, 0, 0);
  NarrowCanvasClip(Canvas, Control.FPixelBounds);
  SetCanvasOrigin(Canvas, Control.FPixelBounds.Left, Control.FPixelBounds.Top);
end;

procedure TControl.PaintAll(var Canvas: TCanvas);
var
  Own: TCanvas;
  Index: LongInt;
begin
  if not FVisible or RectangleIsEmpty(FPixelBounds) then
    Exit;
  Own := Canvas;
  EnterControl(Own, Self);
  if Own.Clip.Count = 0 then
    Exit;
  Paint(Own);
  if Assigned(FOnPaint) then
    FOnPaint(Self, Own);
  for Index := 0 to FChildren.Count - 1 do
    TControl(FChildren[Index]).PaintAll(Own);
end;

procedure TControl.ReceiveMessage(var Message: TPostedMessage);
begin
  if (Message.Code = MessageNotify) and Assigned(FOnNotify) then
    FOnNotify(Self, TControl(Message.Parameter1), LongWord(Message.Parameter2));
end;

procedure TControl.PrepareToReceive;
begin
  if (FHost <> nil) and (FHost.OwnerWindow <> nil) then
    FHost.OwnerWindow.PrepareToReceive;
end;

procedure TControl.Notify(Code: LongWord);
begin
  if FParent <> nil then
    DeliverMessage(FParent, MessageNotify, PtrInt(Self), Code);
end;

procedure TControl.Click;
begin
  if Assigned(FOnClick) then
    FOnClick(Self);
  Notify(NotifyClicked);
end;

procedure TControl.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
  Notify(NotifyChanged);
end;

{ The defaults: a plain control draws nothing and ignores input. }

procedure TControl.Paint(var Canvas: TCanvas);
begin
end;

procedure TControl.PointerDown(X, Y: LongInt; Button: LongWord);
begin
end;

procedure TControl.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
end;

procedure TControl.PointerUp(X, Y: LongInt; Button: LongWord);
begin
end;

procedure TControl.PointerEnter;
begin
end;

procedure TControl.PointerLeave;
begin
end;

procedure TControl.Wheel(Steps: LongInt);
begin
  if FParent <> nil then
    FParent.Wheel(Steps);
end;

function TControl.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := False;
end;

procedure TControl.KeyUp(Code, Modifiers: LongWord);
begin
end;

procedure TControl.FocusChanged;
begin
  Invalidate;
end;

procedure TControl.EnabledChanged;
begin
end;

procedure TControl.TextChanged;
begin
end;

{ The handlers translate to the control's own pixels and fire events. }

procedure TControl.HandlePointerDown(X, Y: LongInt; Button: LongWord);
begin
  if not FEnabled then
    Exit;
  if FCanFocus then
    SetFocus;
  if Assigned(FOnPointerDown) then
    FOnPointerDown(Self, X - FPixelBounds.Left, Y - FPixelBounds.Top, Button);
  PointerDown(X - FPixelBounds.Left, Y - FPixelBounds.Top, Button);
end;

procedure TControl.HandlePointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if FEnabled then
    PointerMove(X - FPixelBounds.Left, Y - FPixelBounds.Top, Buttons);
end;

procedure TControl.HandlePointerUp(X, Y: LongInt; Button: LongWord);
begin
  if FEnabled then
    PointerUp(X - FPixelBounds.Left, Y - FPixelBounds.Top, Button);
end;

procedure TControl.HandlePointerEnter;
begin
  if FEnabled then
    PointerEnter;
end;

procedure TControl.HandlePointerLeave;
begin
  PointerLeave;
end;

procedure TControl.HandleWheel(Steps: LongInt);
begin
  if FEnabled then
    Wheel(Steps);
end;

function TControl.HandleKeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := False;
  if Assigned(FOnKeyDown) then
    FOnKeyDown(Self, Code, Character, Modifiers, Result);
  if not Result and FEnabled then
    Result := KeyDown(Code, Character, Modifiers);
end;

function TControl.TextMatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := MnemonicMatches(FText, Character);
end;

function TControl.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := False;
end;

procedure TControl.ActivateMnemonic(Character: LongWord);
begin
  SetFocus;
end;

procedure TControl.HandleKeyUp(Code, Modifiers: LongWord);
begin
  KeyUp(Code, Modifiers);
end;

procedure TControl.HandleFocusChanged;
begin
  FocusChanged;
  if Assigned(FOnFocusChanged) then
    FOnFocusChanged(Self);
end;

{ --- The root ------------------------------------------------------------------- }

type
  TRootControl = class(TControl)
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

procedure TRootControl.Paint(var Canvas: TCanvas);
begin
  FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)), Theme.Face);
end;

function CreateRootControl(Host: TControlHost): TControl;
begin
  Result := TRootControl.Create(nil);
  Result.FHost := Host;
end;

end.
