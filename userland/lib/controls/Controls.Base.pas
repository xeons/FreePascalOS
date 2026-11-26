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

  Layout: a control's place comes from its parent. Docked (Align) it
  takes a strip along a side of what is left of the parent, in
  DockOrder, its Margins kept clear; otherwise it is where its Bounds put
  it within the parent's client area (inside the parent's ContentPadding), and
  its Anchors keep its distances to those edges as the parent resizes.
  A control with AutoSize takes its PreferredSize; minimum and maximum
  sizes are kept by every way of placing it. Containers of their own
  (Controls.FlowPanel, Controls.TablePanel, Controls.SplitContainer)
  place their children themselves (PlaceChildren). A change asks for a
  layout (RequestLayout) rather than doing one: it is done once, before
  the window paints or anyone reads a place, so many changes cost one
  layout and nothing is painted half laid out. Everything is in logical
  units and laid out again in pixels when the scale changes.

  A control whose caption can carry a mnemonic ("&OK", Controls.Text)
  says whether a character picks it (MatchesMnemonic) and what picking
  it does (ActivateMnemonic); the window asks them on Alt and a letter.

  The pointer takes a control's PointerShape over it (the arrow unless
  it says otherwise: a text beam over the edit boxes).

  A right click, when the button is let go, or Shift+F10 or the menu
  key while it has the focus, asks a control for its context menu
  (ContextMenu, OnContextMenu): at the pointer, or at the place the
  control picks for the keyboard (KeyboardContextPoint).

  Dragging with the mouse: a control starts a drag of some data
  (BeginDrag, Controls.DragData) while a button is held; the window
  then asks the control under the pointer, and its parents in turn
  until one answers, what a drop there would do (DragOver,
  OnDragOver), tells it when the pointer leaves it (DragLeave), and
  hands it the data when the button is let go over it (DragDrop,
  OnDragDrop). Escape ends the drag without a drop.

  Hints: a control's Hint shows in a tooltip while the pointer rests on
  it (Controls.Hints times it), if ShowHint; one without a hint shows
  its parent's. A control whose parts have hints of their own says
  which at a point (HintAt).
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
  Windowing.Messages,
  Controls.DragData,
  Controls.LayoutRules;

type
  TControl = class;

  { The layout types (Controls.LayoutRules), here too so a program needs
    only this unit to use them. }
  TAlign = Controls.LayoutRules.TAlign;
  TAnchorKind = Controls.LayoutRules.TAnchorKind;
  TAnchors = Controls.LayoutRules.TAnchors;
  TSpacing = Controls.LayoutRules.TSpacing;
  TSizeConstraints = Controls.LayoutRules.TSizeConstraints;
  TSize = Controls.LayoutRules.TSize;

const
  AlignNone = Controls.LayoutRules.AlignNone;
  AlignTop = Controls.LayoutRules.AlignTop;
  AlignBottom = Controls.LayoutRules.AlignBottom;
  AlignLeft = Controls.LayoutRules.AlignLeft;
  AlignRight = Controls.LayoutRules.AlignRight;
  AlignClient = Controls.LayoutRules.AlignClient;
  akLeft = Controls.LayoutRules.akLeft;
  akTop = Controls.LayoutRules.akTop;
  akRight = Controls.LayoutRules.akRight;
  akBottom = Controls.LayoutRules.akBottom;

type

  TControlEvent = procedure(Sender: TControl) of object;
  TPointerEvent = procedure(Sender: TControl; X, Y: LongInt; Button: LongWord) of object;
  TKeyEvent = procedure(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean) of object;
  TPaintEvent = procedure(Sender: TControl; var Canvas: TCanvas) of object;
  TNotifyEvent = procedure(Sender: TControl; Child: TControl; Code: LongWord) of object;
  { (X, Y): the control's own pixels; FromKeyboard: Shift+F10 or the menu
    key rather than a right click. }
  TContextMenuEvent = procedure(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean) of object;
  { Effect starts as what the control itself would do; the handler may
    change it. }
  TDragOverEvent = procedure(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
    var Effect: TDropEffect) of object;
  TDragDropEvent = procedure(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect) of object;

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
    { Control starts dragging Data (the host owns it from now on). False
      if no drag can start now (no button is held). }
    function BeginDrag(Control: TControl; Data: TDragData): Boolean; virtual; abstract;
    { Locks the pointer to the window for Control (its motion goes to
      Control's PointerMoveLocked) or lets it go; Control hears
      PointerLockChanged. By default there is no lock (refused). }
    procedure LockPointer(Control: TControl; Lock: Boolean); virtual;
  private
    FRoot: TControl;
    FLayoutPending: Boolean;
    FLayingOut: Boolean;
  public
    { Places whatever asked to be laid out again (RequestLayout) since the
      last time: the window calls this before painting and before it
      looks for the control under the pointer, and reading a control's
      Bounds or PixelBounds does it too, so they are always up to date. }
    procedure PerformPendingLayout;
    property LayoutPending: Boolean read FLayoutPending;
  end;

  TControl = class(TMessageReceiver)
  private
    FParent: TControl;
    FHost: TControlHost;
    FChildren: TList;
    FBounds: TRectangle;
    FPixelBounds: TRectangle;
    FAlign: TAlign;
    FDockOrder: LongInt;
    FAnchors: TAnchors;
    FMargin: TSpacing;
    FPadding: TSpacing;
    FConstraints: TSizeConstraints;
    FAutoSize: Boolean;
    { The parent's client area (logical units, and pixels at the scale
      then) that Bounds were given for: what anchors keep distances to. }
    FHasAnchorReference: Boolean;
    FAnchorReference: TSize;
    FAnchorReferencePixels: TSize;
    FAnchorReferenceScale: LongWord;
    FLayoutPending: Boolean;
    FChildLayoutPending: Boolean;
    { Set once every constructor has run: until then Layout would see a
      subclass's fields before its constructor makes them. }
    FConstructed: Boolean;
    { Set before any destructor runs: a subclass's destructor frees its
      fields before TControl.Destroy frees the children, so a layout
      started meanwhile (a child reading its place as it goes) must not
      reach it. }
    FDestroying: Boolean;
    FVisible: Boolean;
    FEnabled: Boolean;
    FCanFocus: Boolean;
    FText: string;
    FTag: PtrInt;
    FPointerShape: LongWord;
    FHint: string;
    FShowHint: Boolean;
    FOnClick: TControlEvent;
    FOnChange: TControlEvent;
    FOnPointerDown: TPointerEvent;
    FOnKeyDown: TKeyEvent;
    FOnPaint: TPaintEvent;
    FOnNotify: TNotifyEvent;
    FOnFocusChanged: TControlEvent;
    FOnResize: TControlEvent;
    FOnContextMenu: TContextMenuEvent;
    FOnDragOver: TDragOverEvent;
    FOnDragLeave: TControlEvent;
    FOnDragDrop: TDragDropEvent;
    function GetChild(Index: LongInt): TControl;
    function GetChildCount: LongInt;
    procedure SetVisible(Value: Boolean);
    procedure SetEnabled(Value: Boolean);
    procedure SetText(const Value: string);
    procedure SetAlign(Value: TAlign);
    procedure SetDockOrder(Value: LongInt);
    procedure SetAnchors(Value: TAnchors);
    procedure SetMargin(const Value: TSpacing);
    procedure SetPadding(const Value: TSpacing);
    procedure SetAutoSize(Value: Boolean);
    procedure SetMinWidth(Value: LongInt);
    procedure SetMinHeight(Value: LongInt);
    procedure SetMaxWidth(Value: LongInt);
    procedure SetMaxHeight(Value: LongInt);
    function GetBounds: TRectangle;
    function GetPixelBounds: TRectangle;
    function GetFocused: Boolean;
    procedure ArrangeContents;
    procedure ArrangePending;
    procedure ApplyAutoSize;
    procedure BakeAnchoredPlace;
    function AnchoredPlacement(Child: TControl; const Area: TRectangle): TRectangle;
  protected
    procedure Paint(var Canvas: TCanvas); virtual;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); virtual;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); virtual;
    { While the pointer is locked for this control (RequestPointerLock):
      its motion in pixels; and the lock beginning, ending or refused. }
    procedure PointerMoveLocked(DeltaX, DeltaY: LongInt; Buttons: LongWord); virtual;
    procedure PointerLockChanged(Locked: Boolean); virtual;
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
    { The size changed: place the children (PlaceChildren, in the client
      area), then lay each of them out in turn. }
    procedure Layout; virtual;
    { Where the children go: the control's pixels, less its ContentPadding (a
      scrolling panel less its scroll bars). }
    function ClientPixelArea: TRectangle; virtual;
    { Places the children in Area (pixels). The default docks those with
      an Align to a side, in DockOrder (lower first, the outermost; equal
      ones in the order they were made), each with its Margins kept clear,
      gives what is left to those aligned to the client area, and puts
      the rest where their Bounds and Anchors say (relative to Area; a
      margin does not move them). AutoSize children take their
      PreferredSize first; every child's constraints are kept. }
    procedure PlaceChildren(const Area: TRectangle); virtual;
    { Places one child that is not docked again (UpdatePixelBounds): by
      default by its anchors; a container arranging its children itself
      places them all again. }
    procedure PlaceOneChild(Child: TControl); virtual;
    { Puts Child at Rectangle (window pixels): for PlaceChildren. }
    procedure PlaceChild(Child: TControl; const Rectangle: TRectangle);
    { The size a child wants when laid out (logical units): its
      PreferredSize if AutoSize (taken into its Bounds), else its Bounds',
      within its constraints. }
    function ChildSize(Child: TControl): TSize;
    { What the children need (logical units, ContentPadding included): the
      furthest right and bottom of those placed by bounds, and the strips
      of the docked ones around the largest client one. }
    function ChildrenExtent: TSize;
    { Whether Child counts in ChildrenExtent (all visible ones by default;
      not a scrolling panel's own scroll bars). }
    function CountsInExtent(Child: TControl): Boolean; virtual;
    { Moves Child to the end of the children: drawn last, found first
      under the pointer (a scrolling panel's bars stay over its content). }
    procedure KeepChildOnTop(Child: TControl);
    { Tells the parent (MessageNotify) and OnNotify listeners. }
    procedure Notify(Code: LongWord);
    procedure Click; virtual;
    procedure Changed; virtual;
    { Whether Character is the mnemonic in this control's Text: for the
      controls whose text is a caption to override MatchesMnemonic with. }
    function TextMatchesMnemonic(Character: LongWord): Boolean;
    { A context menu is wanted at (X, Y), own pixels: the default calls
      OnContextMenu. }
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); virtual;
    { What dropping Data at (X, Y) would do; the default takes nothing. }
    function DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect; virtual;
    procedure DragLeave; virtual;
    procedure DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect); virtual;
  public
    constructor Create(AParent: TControl); virtual;
    { Lays out what was asked for while the constructors ran. }
    procedure AfterConstruction; override;
    { Marks the control as going away (no more layouts of it). }
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    { True from the start of its or an ancestor's destruction. }
    function Destroying: Boolean;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Selects the scale of the window it is in. }
    procedure PrepareToReceive; override;
    { Logical units, within the parent's client area (inside its
      ContentPadding); where anchors keep the control as the parent resizes. }
    procedure SetBounds(Left, Top, Width, Height: LongInt);
    { The same without asking the parent to lay out again: for a parent's
      own Layout, placing its children (which it then lays out). }
    procedure AssignBounds(Left, Top, Width, Height: LongInt);
    { The root's place, in pixels (the window's whole surface). }
    procedure SetPixelBounds(const Area: TRectangle);
    procedure Invalidate;
    { Asks for the pointer to be locked to this control's window and its
      motion given to PointerMoveLocked (games, the Pointer Lock API), or
      lets it go; PointerLockChanged says how it went. }
    procedure RequestPointerLock(Lock: Boolean);
    procedure SetFocus;
    { The child at (X, Y) of this control's pixels, deepest first; Self if
      none. }
    function ControlAt(X, Y: LongInt): TControl;
    { Places itself (pixels) within the parent's pixels, then lays out its
      children, now. }
    procedure UpdatePixelBounds;
    { Its children are to be placed again: done once, before the window
      next paints or someone looks at a place (coalesced: any number of
      changes, one layout). A control with AutoSize asks its parent too,
      as its own size may change with its children. Changing Bounds,
      Align, Visible, Anchors, Margins, ContentPadding, constraints or AutoSize
      asks for this already. }
    procedure RequestLayout;
    { The size the control would like, in logical units: what its
      content needs (a caption's text and the frame around it, a
      container's children). The default is its size now. AutoSize makes
      the control take it. }
    function PreferredSize: TSize; virtual;
    { A descendant got the focus (the window tells each of its ancestors,
      nearest first): a scrolling panel brings it into view. }
    procedure DescendantFocused(Control: TControl); virtual;
    { Margins and ContentPadding in pixels at the scale now. }
    function ScaledMargin: TSpacing;
    function ScaledPadding: TSpacing;
    function ScaledConstraints: TSizeConstraints;
    { Draws itself and its children (the window calls this). }
    procedure PaintAll(var Canvas: TCanvas);
    { The window's handlers call these. }
    procedure HandlePointerDown(X, Y: LongInt; Button: LongWord);
    procedure HandlePointerMove(X, Y: LongInt; Buttons: LongWord);
    procedure HandlePointerMoveLocked(DeltaX, DeltaY: LongInt; Buttons: LongWord);
    procedure HandlePointerLockChanged(Locked: Boolean);
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
    { Where a context menu asked for from the keyboard opens (own
      pixels): the middle, unless the control knows better (a list's
      focused item). }
    function KeyboardContextPoint: TPoint; virtual;
    { (X, Y) in the window's pixels; the window calls these. }
    procedure HandleContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
    function HandleDragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
    procedure HandleDragLeave;
    procedure HandleDragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
    { Starts dragging Data from this control while a button is held (the
      window owns Data from now on, and frees it if the drag cannot
      start). }
    function BeginDrag(Data: TDragData): Boolean;
    { The hint for (X, Y) of its own pixels ('' for none) and the part
      of it (own pixels) the hint is about: the default is Hint, about
      the whole control, if ShowHint. }
    function HintAt(X, Y: LongInt; out Area: TRectangle): string; virtual;
    property Parent: TControl read FParent;
    property Host: TControlHost read FHost;
    property ChildCount: LongInt read GetChildCount;
    property Children[Index: LongInt]: TControl read GetChild;
    property Bounds: TRectangle read GetBounds;
    { Where it is in the window's surface. }
    property PixelBounds: TRectangle read GetPixelBounds;
    property Align: TAlign read FAlign write SetAlign;
    { Among the docked children of a parent: lower docks first (nearer the
      parent's edge); equal ones in the order they were made. }
    property DockOrder: LongInt read FDockOrder write SetDockOrder;
    { The parent's edges it keeps its distance to ([akLeft, akTop] unless
      set): left and right together stretch it, neither keeps its middle
      at the same share of the parent. Only when not docked. }
    property Anchors: TAnchors read FAnchors write SetAnchors;
    { Logical units kept clear around it when docked, flowed or in a
      table cell (Margins and ContentPadding rather than Margin and
      Padding: many controls have constants of those names). }
    property Margins: TSpacing read FMargin write SetMargin;
    { Logical units inside it that its children keep clear of. }
    property ContentPadding: TSpacing read FPadding write SetPadding;
    { Takes its PreferredSize (again whenever its text, its children or
      the display's scale change). }
    property AutoSize: Boolean read FAutoSize write SetAutoSize;
    { Logical units; a maximum of 0 is none. Every layout keeps them. }
    property MinWidth: LongInt read FConstraints.MinWidth write SetMinWidth;
    property MinHeight: LongInt read FConstraints.MinHeight write SetMinHeight;
    property MaxWidth: LongInt read FConstraints.MaxWidth write SetMaxWidth;
    property MaxHeight: LongInt read FConstraints.MaxHeight write SetMaxHeight;
    property Constraints: TSizeConstraints read FConstraints;
    property Visible: Boolean read FVisible write SetVisible;
    property Enabled: Boolean read FEnabled write SetEnabled;
    property CanFocus: Boolean read FCanFocus write FCanFocus;
    property Focused: Boolean read GetFocused;
    property Text: string read FText write SetText;
    { The program's own, for anything. }
    property Tag: PtrInt read FTag write FTag;
    { The pointer's shape over it (Pointer* in Windowing.Protocol; the
      arrow unless set). }
    property PointerShape: LongWord read FPointerShape write FPointerShape;
    { Shown in a tooltip while the pointer rests on it (line breaks
      start new lines). }
    property Hint: string read FHint write FHint;
    { Whether its hints show (True unless set). }
    property ShowHint: Boolean read FShowHint write FShowHint;
    property OnClick: TControlEvent read FOnClick write FOnClick;
    property OnChange: TControlEvent read FOnChange write FOnChange;
    property OnPointerDown: TPointerEvent read FOnPointerDown write FOnPointerDown;
    property OnKeyDown: TKeyEvent read FOnKeyDown write FOnKeyDown;
    property OnPaint: TPaintEvent read FOnPaint write FOnPaint;
    property OnNotify: TNotifyEvent read FOnNotify write FOnNotify;
    property OnFocusChanged: TControlEvent read FOnFocusChanged write FOnFocusChanged;
    property OnResize: TControlEvent read FOnResize write FOnResize;
    property OnContextMenu: TContextMenuEvent read FOnContextMenu write FOnContextMenu;
    property OnDragOver: TDragOverEvent read FOnDragOver write FOnDragOver;
    property OnDragLeave: TControlEvent read FOnDragLeave write FOnDragLeave;
    property OnDragDrop: TDragDropEvent read FOnDragDrop write FOnDragDrop;
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
{ Logical units for Pixels, rounded up (a text's width, so it fits). }
function PixelsToLogicalCeiling(Pixels: LongInt): LongInt;

implementation

uses
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

const
  { Layouts that ask for more layout (a scroll bar shown as the content
    grew) are run again, this many times at most. }
  MaximumLayoutRounds = 4;

function PixelsToLogicalCeiling(Pixels: LongInt): LongInt;
begin
  Result := Unscaled(Pixels);
  while Scaled(Result) < Pixels do
    Inc(Result);
end;

{ --- TControlHost --------------------------------------------------------------- }

procedure TControlHost.LockPointer(Control: TControl; Lock: Boolean);
begin
  if Lock then
    Control.HandlePointerLockChanged(False);
end;

procedure TControlHost.PerformPendingLayout;
var
  Rounds: LongInt;
begin
  if FLayingOut or not FLayoutPending then
    Exit;
  if FRoot = nil then
  begin
    FLayoutPending := False;
    Exit;
  end;
  FLayingOut := True;
  try
    Rounds := 0;
    while FLayoutPending and (Rounds < MaximumLayoutRounds) do
    begin
      FLayoutPending := False;
      FRoot.ArrangePending;
      Inc(Rounds);
    end;
  finally
    FLayingOut := False;
  end;
  { Layouts that keep asking for more wait for the next change rather
    than being run (and painted) again and again. }
  FLayoutPending := False;
end;

{ --- TControl ----------------------------------------------------------------- }

constructor TControl.Create(AParent: TControl);
begin
  inherited Create;
  FChildren := TList.Create;
  FVisible := True;
  FEnabled := True;
  FAnchors := DefaultAnchors;
  FShowHint := True;
  FParent := AParent;
  if FParent <> nil then
  begin
    FHost := FParent.FHost;
    FParent.FChildren.Add(Self);
    FParent.RequestLayout;
  end;
end;

procedure TControl.AfterConstruction;
begin
  inherited AfterConstruction;
  FConstructed := True;
  if not FLayoutPending then
    Exit;
  if FHost = nil then
    UpdatePixelBounds
  else
    RequestLayout;
end;

procedure TControl.BeforeDestruction;
begin
  FDestroying := True;
  inherited BeforeDestruction;
end;

function TControl.Destroying: Boolean;
var
  Control: TControl;
begin
  Control := Self;
  while Control <> nil do
  begin
    if Control.FDestroying then
      Exit(True);
    Control := Control.FParent;
  end;
  Result := False;
end;

destructor TControl.Destroy;
begin
  while FChildren.Count > 0 do
    TControl(FChildren[FChildren.Count - 1]).Free;
  if FHost <> nil then
  begin
    FHost.ControlRemoved(Self);
    if FHost.FRoot = Self then
      FHost.FRoot := nil;
  end;
  if FParent <> nil then
  begin
    FParent.FChildren.Remove(Self);
    FParent.Invalidate;
    FParent.RequestLayout;
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

function TControl.GetBounds: TRectangle;
begin
  if (FHost <> nil) and FHost.FLayoutPending then
    FHost.PerformPendingLayout;
  Result := FBounds;
end;

function TControl.GetPixelBounds: TRectangle;
begin
  if (FHost <> nil) and FHost.FLayoutPending then
    FHost.PerformPendingLayout;
  Result := FPixelBounds;
end;

procedure TControl.SetBounds(Left, Top, Width, Height: LongInt);
begin
  FBounds := MakeRectangle(Left, Top, Width, Height);
  FHasAnchorReference := False;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.AssignBounds(Left, Top, Width, Height: LongInt);
begin
  FBounds := MakeRectangle(Left, Top, Width, Height);
  FHasAnchorReference := False;
end;

procedure TControl.SetPixelBounds(const Area: TRectangle);
begin
  FPixelBounds := Area;
  FBounds := MakeRectangle(0, 0, Unscaled(RectangleWidth(Area)), Unscaled(RectangleHeight(Area)));
  ArrangeContents;
  Invalidate;
end;

procedure TControl.UpdatePixelBounds;
begin
  { The root keeps the pixels it was given; docked controls were placed
    by the parent's Layout. }
  if (FParent <> nil) and (FAlign = AlignNone) then
    FParent.PlaceOneChild(Self);
  ArrangeContents;
end;

{ Lays out the children (now) and says the size may have changed. }
procedure TControl.ArrangeContents;
var
  Outermost: Boolean;
begin
  { Children made in a constructor read and set places before the rest
    of the constructor has run; the layout waits for AfterConstruction. }
  if not FConstructed then
  begin
    FLayoutPending := True;
    Exit;
  end;
  { Being freed: its fields may be gone already. }
  if Destroying then
    Exit;
  FLayoutPending := False;
  FChildLayoutPending := False;
  { A layout started directly (the window resized) is not interrupted by
    the pending ones (reading a place while laying out). }
  Outermost := (FHost <> nil) and not FHost.FLayingOut;
  if Outermost then
    FHost.FLayingOut := True;
  try
    Layout;
  finally
    if Outermost then
      FHost.FLayingOut := False;
  end;
  if Assigned(FOnResize) then
    FOnResize(Self);
end;

{ The parts of the tree that asked for layout, laid out now. }
procedure TControl.ArrangePending;
var
  Index: LongInt;
begin
  if FDestroying then
    Exit;
  if FLayoutPending then
  begin
    Invalidate;
    ArrangeContents;
    Invalidate;
  end
  else if FChildLayoutPending then
  begin
    FChildLayoutPending := False;
    Index := 0;
    while Index < FChildren.Count do
    begin
      TControl(FChildren[Index]).ArrangePending;
      Inc(Index);
    end;
  end;
end;

procedure TControl.RequestLayout;
var
  Ancestor: TControl;
begin
  if FHost = nil then
  begin
    UpdatePixelBounds;
    Exit;
  end;
  FLayoutPending := True;
  FHost.FLayoutPending := True;
  Ancestor := FParent;
  while (Ancestor <> nil) and not Ancestor.FChildLayoutPending do
  begin
    Ancestor.FChildLayoutPending := True;
    Ancestor := Ancestor.FParent;
  end;
  { Its size follows its children: its parent places it again. }
  if FAutoSize and (FParent <> nil) and not FParent.FLayoutPending then
    FParent.RequestLayout;
end;

function TControl.ScaledMargin: TSpacing;
begin
  Result := MakeSpacing(Scaled(FMargin.Left), Scaled(FMargin.Top), Scaled(FMargin.Right), Scaled(FMargin.Bottom));
end;

function TControl.ScaledPadding: TSpacing;
begin
  Result := MakeSpacing(Scaled(FPadding.Left), Scaled(FPadding.Top), Scaled(FPadding.Right),
    Scaled(FPadding.Bottom));
end;

function TControl.ScaledConstraints: TSizeConstraints;
begin
  Result := MakeConstraints(Scaled(FConstraints.MinWidth), Scaled(FConstraints.MinHeight),
    Scaled(FConstraints.MaxWidth), Scaled(FConstraints.MaxHeight));
end;

function TControl.ClientPixelArea: TRectangle;
begin
  Result := DeflateBySpacing(FPixelBounds, ScaledPadding);
end;

function TControl.PreferredSize: TSize;
begin
  Result := MakeSize(RectangleWidth(FBounds), RectangleHeight(FBounds));
end;

procedure TControl.DescendantFocused(Control: TControl);
begin
end;

{ An AutoSize control takes its preferred size; anchored to the right
  (bottom) only, it grows to the left (upwards). }
procedure TControl.ApplyAutoSize;
var
  Size: TSize;
  Left: LongInt;
  Top: LongInt;
begin
  if not FAutoSize then
    Exit;
  Size := ConstrainSize(PreferredSize, FConstraints);
  Left := FBounds.Left;
  Top := FBounds.Top;
  if (akRight in FAnchors) and not (akLeft in FAnchors) then
    Left := FBounds.Right - Size.cx;
  if (akBottom in FAnchors) and not (akTop in FAnchors) then
    Top := FBounds.Bottom - Size.cy;
  FBounds := MakeRectangle(Left, Top, Size.cx, Size.cy);
end;

function TControl.ChildSize(Child: TControl): TSize;
begin
  Child.ApplyAutoSize;
  Result := ConstrainSize(MakeSize(RectangleWidth(Child.FBounds), RectangleHeight(Child.FBounds)),
    Child.FConstraints);
end;

function TControl.ChildrenExtent: TSize;
var
  Index: LongInt;
  Child: TControl;
  Size: TSize;
  Placed: TSize;
  Sides: TSize;
  Inner: TSize;
begin
  Placed := MakeSize(0, 0);
  Sides := MakeSize(0, 0);
  Inner := MakeSize(0, 0);
  for Index := 0 to FChildren.Count - 1 do
  begin
    Child := TControl(FChildren[Index]);
    if not Child.FVisible or not CountsInExtent(Child) then
      Continue;
    Size := ChildSize(Child);
    if Child.FAlign = AlignNone then
    begin
      if Child.FBounds.Left + Size.cx > Placed.cx then
        Placed.cx := Child.FBounds.Left + Size.cx;
      if Child.FBounds.Top + Size.cy > Placed.cy then
        Placed.cy := Child.FBounds.Top + Size.cy;
      Continue;
    end;
    Size := MakeSize(Size.cx + SpacingWidth(Child.FMargin), Size.cy + SpacingHeight(Child.FMargin));
    case Child.FAlign of
      AlignTop, AlignBottom:
        begin
          Sides.cy := Sides.cy + Size.cy;
          if Size.cx > Inner.cx then
            Inner.cx := Size.cx;
        end;
      AlignLeft, AlignRight:
        begin
          Sides.cx := Sides.cx + Size.cx;
          if Size.cy > Inner.cy then
            Inner.cy := Size.cy;
        end;
    else
      begin
        if Size.cx > Inner.cx then
          Inner.cx := Size.cx;
        if Size.cy > Inner.cy then
          Inner.cy := Size.cy;
      end;
    end;
  end;
  Result := MakeSize(Sides.cx + Inner.cx, Sides.cy + Inner.cy);
  if Placed.cx > Result.cx then
    Result.cx := Placed.cx;
  if Placed.cy > Result.cy then
    Result.cy := Placed.cy;
  Result := MakeSize(Result.cx + SpacingWidth(FPadding), Result.cy + SpacingHeight(FPadding));
end;

function TControl.CountsInExtent(Child: TControl): Boolean;
begin
  Result := True;
end;

procedure TControl.PlaceChild(Child: TControl; const Rectangle: TRectangle);
begin
  Child.FPixelBounds := Rectangle;
end;

procedure TControl.KeepChildOnTop(Child: TControl);
var
  Index: LongInt;
begin
  Index := FChildren.IndexOf(Child);
  if (Index >= 0) and (Index <> FChildren.Count - 1) then
    FChildren.Move(Index, FChildren.Count - 1);
end;

{ Where a child that is not docked goes in Area: by its anchors, from the
  client area it was placed in (captured the first time the area has a
  size). }
function TControl.AnchoredPlacement(Child: TControl; const Area: TRectangle): TRectangle;
var
  ClientWidth: LongInt;
  ClientHeight: LongInt;
  Size: TSize;
  Placed: TRectangle;
  ReferenceWidth: LongInt;
  ReferenceHeight: LongInt;
begin
  ClientWidth := RectangleWidth(Area);
  ClientHeight := RectangleHeight(Area);
  Size := ChildSize(Child);
  if not Child.FHasAnchorReference and (ClientWidth > 0) and (ClientHeight > 0) then
  begin
    Child.FHasAnchorReference := True;
    Child.FAnchorReference := MakeSize(Unscaled(ClientWidth), Unscaled(ClientHeight));
    Child.FAnchorReferencePixels := MakeSize(ClientWidth, ClientHeight);
    Child.FAnchorReferenceScale := DisplayScale;
  end;
  Placed := MakeRectangle(Scaled(Child.FBounds.Left), Scaled(Child.FBounds.Top), Scaled(Size.cx), Scaled(Size.cy));
  if not Child.FHasAnchorReference then
    Exit(OffsetRectangle(Placed, Area.Left, Area.Top));
  if Child.FAnchorReferenceScale = DisplayScale then
  begin
    ReferenceWidth := Child.FAnchorReferencePixels.cx;
    ReferenceHeight := Child.FAnchorReferencePixels.cy;
  end
  else
  begin
    ReferenceWidth := Scaled(Child.FAnchorReference.cx);
    ReferenceHeight := Scaled(Child.FAnchorReference.cy);
  end;
  Result := OffsetRectangle(AnchoredRectangle(Child.FAnchors, Placed, ReferenceWidth, ReferenceHeight, ClientWidth,
    ClientHeight, Child.ScaledConstraints), Area.Left, Area.Top);
end;

{ The children docked to a side, in the order they dock: by DockOrder,
  then as made. }
function DockingOrder(Children: TList): TList;
var
  Index: LongInt;
  Position: LongInt;
  Child: TControl;
begin
  Result := TList.Create;
  for Index := 0 to Children.Count - 1 do
  begin
    Child := TControl(Children[Index]);
    if not Child.Visible or (Child.Align = AlignNone) or (Child.Align = AlignClient) then
      Continue;
    Position := Result.Count;
    while (Position > 0) and (TControl(Result[Position - 1]).DockOrder > Child.DockOrder) do
      Dec(Position);
    Result.Insert(Position, Child);
  end;
end;

procedure TControl.PlaceChildren(const Area: TRectangle);
var
  Index: LongInt;
  Child: TControl;
  Remaining: TRectangle;
  Docked: TList;
  Size: TSize;
begin
  Remaining := Area;
  Docked := DockingOrder(FChildren);
  try
    for Index := 0 to Docked.Count - 1 do
    begin
      Child := TControl(Docked[Index]);
      Size := ChildSize(Child);
      Child.FPixelBounds := DockRectangle(Child.FAlign, Remaining, Child.ScaledMargin,
        MakeSize(Scaled(Size.cx), Scaled(Size.cy)), Child.ScaledConstraints);
    end;
  finally
    Docked.Free;
  end;
  for Index := 0 to FChildren.Count - 1 do
  begin
    Child := TControl(FChildren[Index]);
    if Child.FVisible and (Child.FAlign = AlignClient) then
      Child.FPixelBounds := DockRectangle(AlignClient, Remaining, Child.ScaledMargin, MakeSize(0, 0),
        Child.ScaledConstraints)
    else if Child.FAlign = AlignNone then
      Child.FPixelBounds := AnchoredPlacement(Child, Area);
  end;
end;

procedure TControl.PlaceOneChild(Child: TControl);
begin
  Child.FPixelBounds := AnchoredPlacement(Child, ClientPixelArea);
end;

procedure TControl.Layout;
var
  Index: LongInt;
begin
  PlaceChildren(ClientPixelArea);
  for Index := 0 to FChildren.Count - 1 do
    TControl(FChildren[Index]).ArrangeContents;
end;

procedure TControl.SetAlign(Value: TAlign);
begin
  if FAlign = Value then
    Exit;
  FAlign := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetDockOrder(Value: LongInt);
begin
  if FDockOrder = Value then
    Exit;
  FDockOrder := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

{ Where it is now becomes its Bounds, for new anchors to keep distances
  from (rather than from where it was first put). }
procedure TControl.BakeAnchoredPlace;
var
  Area: TRectangle;
begin
  if not FHasAnchorReference or (FParent = nil) or (FAlign <> AlignNone) then
    Exit;
  Area := FParent.ClientPixelArea;
  FBounds := MakeRectangle(Unscaled(FPixelBounds.Left - Area.Left), Unscaled(FPixelBounds.Top - Area.Top),
    Unscaled(RectangleWidth(FPixelBounds)), Unscaled(RectangleHeight(FPixelBounds)));
  FHasAnchorReference := False;
end;

procedure TControl.SetAnchors(Value: TAnchors);
begin
  if FAnchors = Value then
    Exit;
  if (FHost <> nil) and FHost.FLayoutPending then
    FHost.PerformPendingLayout;
  BakeAnchoredPlace;
  FAnchors := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetMargin(const Value: TSpacing);
begin
  if SpacingsAreEqual(FMargin, Value) then
    Exit;
  FMargin := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetPadding(const Value: TSpacing);
begin
  if SpacingsAreEqual(FPadding, Value) then
    Exit;
  FPadding := Value;
  RequestLayout;
end;

procedure TControl.SetAutoSize(Value: Boolean);
begin
  if FAutoSize = Value then
    Exit;
  FAutoSize := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetMinWidth(Value: LongInt);
begin
  FConstraints.MinWidth := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetMinHeight(Value: LongInt);
begin
  FConstraints.MinHeight := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetMaxWidth(Value: LongInt);
begin
  FConstraints.MaxWidth := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetMaxHeight(Value: LongInt);
begin
  FConstraints.MaxHeight := Value;
  if FParent <> nil then
    FParent.RequestLayout;
end;

procedure TControl.SetVisible(Value: Boolean);
begin
  if FVisible = Value then
    Exit;
  FVisible := Value;
  if FParent <> nil then
  begin
    FParent.RequestLayout;
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
  { Its preferred size follows its text. }
  if FAutoSize and (FParent <> nil) then
    FParent.RequestLayout;
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
  if (FParent = nil) and (FHost <> nil) and FHost.FLayoutPending then
    FHost.PerformPendingLayout;
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

procedure TControl.PointerMoveLocked(DeltaX, DeltaY: LongInt; Buttons: LongWord);
begin
end;

procedure TControl.PointerLockChanged(Locked: Boolean);
begin
end;

procedure TControl.HandlePointerMoveLocked(DeltaX, DeltaY: LongInt; Buttons: LongWord);
begin
  PointerMoveLocked(DeltaX, DeltaY, Buttons);
end;

procedure TControl.HandlePointerLockChanged(Locked: Boolean);
begin
  PointerLockChanged(Locked);
end;

procedure TControl.RequestPointerLock(Lock: Boolean);
begin
  if FHost <> nil then
    FHost.LockPointer(Self, Lock)
  else if Lock then
    PointerLockChanged(False);
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

{ --- Context menus and dragging ------------------------------------------------- }

procedure TControl.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
begin
  if Assigned(FOnContextMenu) then
    FOnContextMenu(Self, X, Y, FromKeyboard);
end;

function TControl.KeyboardContextPoint: TPoint;
begin
  Result := MakePoint(RectangleWidth(FPixelBounds) div 2, RectangleHeight(FPixelBounds) div 2);
end;

function TControl.DragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
begin
  Result := DropNone;
end;

procedure TControl.DragLeave;
begin
end;

procedure TControl.DragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
begin
end;

procedure TControl.HandleContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
begin
  if FEnabled then
    ContextMenu(X - FPixelBounds.Left, Y - FPixelBounds.Top, FromKeyboard);
end;

function TControl.HandleDragOver(Data: TDragData; X, Y: LongInt; Modifiers: LongWord): TDropEffect;
begin
  if not FEnabled then
    Exit(DropNone);
  Result := DragOver(Data, X - FPixelBounds.Left, Y - FPixelBounds.Top, Modifiers);
  if Assigned(FOnDragOver) then
    FOnDragOver(Self, Data, X - FPixelBounds.Left, Y - FPixelBounds.Top, Modifiers, Result);
end;

procedure TControl.HandleDragLeave;
begin
  DragLeave;
  if Assigned(FOnDragLeave) then
    FOnDragLeave(Self);
end;

procedure TControl.HandleDragDrop(Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
begin
  DragDrop(Data, X - FPixelBounds.Left, Y - FPixelBounds.Top, Effect);
  if Assigned(FOnDragDrop) then
    FOnDragDrop(Self, Data, X - FPixelBounds.Left, Y - FPixelBounds.Top, Effect);
end;

function TControl.BeginDrag(Data: TDragData): Boolean;
begin
  if FHost = nil then
  begin
    Data.Free;
    Exit(False);
  end;
  Result := FHost.BeginDrag(Self, Data);
end;

function TControl.HintAt(X, Y: LongInt; out Area: TRectangle): string;
begin
  Area := MakeRectangle(0, 0, RectangleWidth(FPixelBounds), RectangleHeight(FPixelBounds));
  Result := '';
  if FShowHint then
    Result := FHint;
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
  if Host <> nil then
    Host.FRoot := Result;
end;

end.
