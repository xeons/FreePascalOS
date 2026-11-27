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
  A home for controls without a window: the content process has no
  connection to the display server, yet its page engine is a control
  (WebView.Engine, with its scroll bars). The host keeps what a window
  would - the focus, the control the pointer was pressed on, the one it
  is over, what needs painting - and its "window" selects the browser's
  display scale for whatever runs (Controls.Base PrepareToReceive).
  The view (WebContent.Views) paints the controls into the frame
  surface and feeds them the input the browser sends, as a window would.
}
unit WebContent.Host;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Windowing.Messages,
  Controls.Base,
  Controls.DragData;

type
  { What a control's PrepareToReceive asks of its window: the scale. }
  TContentScale = class(TMessageReceiver)
  public
    ScalePercent: LongWord;
    Dpi: LongWord;
    procedure PrepareToReceive; override;
  end;

  TContentLockPointerEvent = procedure(Control: TControl; Lock: Boolean) of object;

  TContentControlHost = class(TControlHost)
  private
    FOnLockPointer: TContentLockPointerEvent;
    FScale: TContentScale;
    FFocused: TControl;
    FDamage: TRectangle;
    FHasDamage: Boolean;
  public
    Pressed: TControl;
    Hovered: TControl;
    constructor Create;
    destructor Destroy; override;
    procedure InvalidatePixels(const Area: TRectangle); override;
    procedure FocusControl(Control: TControl); override;
    function FocusedControl: TControl; override;
    procedure CapturePointer(Control: TControl); override;
    procedure ControlRemoved(Control: TControl); override;
    procedure FocusControlAfter(Control: TControl); override;
    function OwnerWindow: TMessageReceiver; override;
    function BeginDrag(Control: TControl; Data: TDragData): Boolean; override;
    { The pointer lock goes to the browser (OnLockPointer). }
    procedure LockPointer(Control: TControl; Lock: Boolean); override;
    property OnLockPointer: TContentLockPointerEvent read FOnLockPointer write FOnLockPointer;
    { What was invalidated since the last TakeDamage (False: nothing). }
    function TakeDamage(out Area: TRectangle): Boolean;
    procedure DamageAll(Width, Height: LongInt);
    property Scale: TContentScale read FScale;
  end;

implementation

uses
  Windowing.Connection;

procedure TContentScale.PrepareToReceive;
begin
  UseScale(ScalePercent, Dpi);
end;

constructor TContentControlHost.Create;
begin
  inherited Create;
  FScale := TContentScale.Create;
  FScale.ScalePercent := 100;
  FScale.Dpi := 96;
end;

destructor TContentControlHost.Destroy;
begin
  FScale.Free;
  inherited Destroy;
end;

procedure TContentControlHost.LockPointer(Control: TControl; Lock: Boolean);
begin
  if Assigned(FOnLockPointer) then
    FOnLockPointer(Control, Lock)
  else
    inherited LockPointer(Control, Lock);
end;

procedure TContentControlHost.InvalidatePixels(const Area: TRectangle);
begin
  if (RectangleWidth(Area) <= 0) or (RectangleHeight(Area) <= 0) then
    Exit;
  if FHasDamage then
    FDamage := BoundingRectangle(FDamage, Area)
  else
    FDamage := Area;
  FHasDamage := True;
end;

procedure TContentControlHost.DamageAll(Width, Height: LongInt);
begin
  InvalidatePixels(MakeRectangle(0, 0, Width, Height));
end;

function TContentControlHost.TakeDamage(out Area: TRectangle): Boolean;
begin
  Result := FHasDamage;
  Area := FDamage;
  FHasDamage := False;
end;

procedure TContentControlHost.FocusControl(Control: TControl);
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

function TContentControlHost.FocusedControl: TControl;
begin
  Result := FFocused;
end;

procedure TContentControlHost.CapturePointer(Control: TControl);
begin
  Pressed := Control;
end;

procedure TContentControlHost.ControlRemoved(Control: TControl);
begin
  if FFocused = Control then
    FFocused := nil;
  if Pressed = Control then
    Pressed := nil;
  if Hovered = Control then
    Hovered := nil;
end;

procedure TContentControlHost.FocusControlAfter(Control: TControl);
begin
end;

function TContentControlHost.OwnerWindow: TMessageReceiver;
begin
  Result := FScale;
end;

function TContentControlHost.BeginDrag(Control: TControl; Data: TDragData): Boolean;
begin
  Data.Free;
  Result := False;
end;

end.
