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
  The web view's mouse events (UI Events 3.4): trusted MouseEvents at an
  element with the pointer where its own document's viewport sees it
  (a frame's document: its frame's viewport), the page coordinates, the
  button that changed and the buttons held, the click count and the
  modifiers.

  Each mouse event that has a pointer event (Pointer Events 3) comes
  after it: pointerdown before mousedown (pointermove for a second
  button), pointerup before mouseup (pointermove while a button is still
  held), pointermove, pointerover, pointerout, pointerenter and
  pointerleave before theirs; the mouse is pointer 1, primary. A
  cancelled pointerdown keeps mousedown, mousemove and mouseup from
  firing until the pointer comes up. Before each pointer event the
  pending pointer capture (Web.Dom.PointerCapture) becomes the capture
  (lostpointercapture, gotpointercapture); while an element has it, the
  pointer's down, move and up events and their mouse events go to it
  and the boundary events wait; after pointerup it is released.
}
unit WebView.MouseEvents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

type
  TMouseEventInit = record
    { CSS px in the target document's viewport, and its scroll offset. }
    ClientX, ClientY: Double;
    ScrollX, ScrollY: Double;
    { CSS px from the target's border box (offsetX, offsetY). }
    OffsetX, OffsetY: Double;
    { Logical units on the screen. }
    ScreenX, ScreenY: LongInt;
    { 0 main, 1 middle (auxiliary), 2 secondary. }
    Button: SmallInt;
    { 1 main, 2 secondary, 4 auxiliary held. }
    Buttons: Word;
    Detail: LongInt;
    { The system's modifier bits (Windowing). }
    Modifiers: LongWord;
    { The motion since the last move (Pointer Lock's movementX/Y). }
    MovementX, MovementY: Double;
  end;

{ Fires a trusted MouseEvent of EventType at Target; False when a
  listener cancelled it. mouseenter and mouseleave do not bubble and
  cannot be cancelled, the others bubble; mousemove, mousedown, mouseup,
  click, dblclick, contextmenu, mouseover and mouseout are cancelable. }
function DispatchMouseEvent(Target: TNode; const EventType: string; constref Init: TMouseEventInit): Boolean;

implementation

uses
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Dom.PointerCapture;

var
  { A pointerdown was cancelled: no mousedown, mousemove or mouseup
    until the pointer comes up. }
  MouseEventsPrevented: Boolean = False;

const
  SystemShift = $01;
  SystemControl = $02;
  SystemAlt = $04;
  SystemSuper = $80;

function DomModifiers(Modifiers: LongWord): TModifierKeys;
begin
  Result := [];
  if (Modifiers and SystemShift) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierShift);
  if (Modifiers and SystemControl) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierControl);
  if (Modifiers and SystemAlt) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierAlt);
  if (Modifiers and SystemSuper) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierMeta);
end;

procedure FillMouseFields(Event: TMouseEvent; constref Init: TMouseEventInit);
begin
  Event.IsTrusted := True;
  Event.Composed := True;
  Event.HasView := True;
  Event.Detail := Init.Detail;
  Event.Modifiers := DomModifiers(Init.Modifiers);
  Event.ClientX := Round(Init.ClientX);
  Event.ClientY := Round(Init.ClientY);
  Event.ScrollX := Round(Init.ScrollX);
  Event.ScrollY := Round(Init.ScrollY);
  Event.OffsetX := Round(Init.OffsetX);
  Event.OffsetY := Round(Init.OffsetY);
  Event.ScreenX := Init.ScreenX;
  Event.ScreenY := Init.ScreenY;
  Event.Button := Init.Button;
  Event.Buttons := Init.Buttons;
  Event.MovementX := Init.MovementX;
  Event.MovementY := Init.MovementY;
end;

function IsBoundaryEvent(const EventType: string): Boolean;
begin
  Result := (EventType = 'mouseenter') or (EventType = 'mouseleave') or (EventType = 'pointerenter') or
    (EventType = 'pointerleave');
end;

function FirePointerEvent(Target: TNode; const EventType: string; constref Init: TMouseEventInit): Boolean;
var
  Event: TPointerEvent;
  Boundary, Capture: Boolean;
begin
  Result := True;
  if (Target = nil) or not Target.IsConnected then
    Exit;
  Boundary := IsBoundaryEvent(EventType);
  Capture := (EventType = 'gotpointercapture') or (EventType = 'lostpointercapture');
  Event := TPointerEvent.Create(EventType, not Boundary, not Boundary and not Capture);
  try
    FillMouseFields(Event, Init);
    Event.Detail := 0;
    Event.PointerId := MousePointerId;
    Event.Width := 1;
    Event.Height := 1;
    if Init.Buttons <> 0 then
      Event.Pressure := 0.5;
    Event.AltitudeAngle := Pi / 2;
    Event.PointerType := 'mouse';
    Event.IsPrimary := True;
    { A pointer event's button is -1 when no button changed. }
    if (EventType <> 'pointerdown') and (EventType <> 'pointerup') then
      Event.Button := -1;
    Result := Target.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

{ The pending pointer capture of Document becomes its capture. }
procedure ProcessPendingCapture(Document: TDocument; constref Init: TMouseEventInit);
var
  Old, New: TElement;
begin
  if (Document = nil) or (Document.PendingPointerCapture = Document.PointerCapture) then
    Exit;
  Old := Document.PointerCapture;
  New := Document.PendingPointerCapture;
  Document.PointerCapture := New;
  if Old <> nil then
  begin
    Old.Retain;
    try
      FirePointerEvent(Old, 'lostpointercapture', Init);
    finally
      Old.Release;
    end;
  end;
  if (New <> nil) and New.IsConnected then
  begin
    New.Retain;
    try
      FirePointerEvent(New, 'gotpointercapture', Init);
    finally
      New.Release;
    end;
  end;
end;

{ The pointer event a mouse event comes after ('' none). }
function PointerEventFor(const EventType: string; constref Init: TMouseEventInit): string;
var
  ButtonBit: Word;
begin
  Result := '';
  case Init.Button of
    0: ButtonBit := 1;
    1: ButtonBit := 4;
    2: ButtonBit := 2;
  else
    ButtonBit := 0;
  end;
  if EventType = 'mousedown' then
  begin
    { A second button pressed is a move of a pointer already down. }
    if (Init.Buttons and not ButtonBit) <> 0 then
      Result := 'pointermove'
    else
      Result := 'pointerdown';
  end
  else if EventType = 'mouseup' then
  begin
    if Init.Buttons <> 0 then
      Result := 'pointermove'
    else
      Result := 'pointerup';
  end
  else if EventType = 'mousemove' then
    Result := 'pointermove'
  else if EventType = 'mouseover' then
    Result := 'pointerover'
  else if EventType = 'mouseout' then
    Result := 'pointerout'
  else if EventType = 'mouseenter' then
    Result := 'pointerenter'
  else if EventType = 'mouseleave' then
    Result := 'pointerleave';
end;

function FireMouseEventOnly(Target: TNode; const EventType: string; constref Init: TMouseEventInit): Boolean;
var
  Event: TMouseEvent;
  Boundary: Boolean;
begin
  Result := True;
  if (Target = nil) or not Target.IsConnected then
    Exit;
  Boundary := IsBoundaryEvent(EventType);
  Event := TMouseEvent.Create(EventType, not Boundary, not Boundary);
  try
    FillMouseFields(Event, Init);
    Result := Target.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

function DispatchMouseEvent(Target: TNode; const EventType: string; constref Init: TMouseEventInit): Boolean;
var
  PointerType: string;
  Document: TDocument;
  Captured: TElement;
  Held: Boolean;
begin
  Result := True;
  if (Target = nil) or not Target.IsConnected then
    Exit;
  PointerType := PointerEventFor(EventType, Init);
  if PointerType = '' then
    Exit(FireMouseEventOnly(Target, EventType, Init));
  MouseButtonsHeld := Init.Buttons;
  Document := Target.OwnerDocument;
  Held := False;
  if Document <> nil then
  begin
    Document.Retain;
    Held := True;
  end;
  Target.Retain;
  try
    ProcessPendingCapture(Document, Init);
    Captured := nil;
    if Document <> nil then
      Captured := Document.PointerCapture;
    if (Captured <> nil) and Captured.IsConnected then
    begin
      { Captured: the boundary events wait, the others go to it. }
      if (PointerType = 'pointerover') or (PointerType = 'pointerout') or (PointerType = 'pointerenter') or
        (PointerType = 'pointerleave') then
        Exit;
      Target.Release;
      Target := Captured;
      Target.Retain;
    end;
    if not FirePointerEvent(Target, PointerType, Init) and (PointerType = 'pointerdown') then
      MouseEventsPrevented := True;
    if MouseEventsPrevented and ((EventType = 'mousedown') or (EventType = 'mousemove') or (EventType = 'mouseup')) then
      Result := True
    else
      Result := FireMouseEventOnly(Target, EventType, Init);
    if PointerType = 'pointerup' then
    begin
      MouseEventsPrevented := False;
      { The capture is released when the pointer comes up. }
      if Document <> nil then
      begin
        Document.PendingPointerCapture := nil;
        ProcessPendingCapture(Document, Init);
      end;
    end;
  finally
    Target.Release;
    if Held then
      Document.Release;
  end;
end;

end.
