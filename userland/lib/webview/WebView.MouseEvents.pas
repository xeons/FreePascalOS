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
  end;

{ Fires a trusted MouseEvent of EventType at Target; False when a
  listener cancelled it. mouseenter and mouseleave do not bubble and
  cannot be cancelled, the others bubble; mousemove, mousedown, mouseup,
  click, dblclick, contextmenu, mouseover and mouseout are cancelable. }
function DispatchMouseEvent(Target: TNode; const EventType: string; constref Init: TMouseEventInit): Boolean;

implementation

uses
  Web.Dom.Events,
  Web.Dom.UiEvents;

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

function DispatchMouseEvent(Target: TNode; const EventType: string; constref Init: TMouseEventInit): Boolean;
var
  Event: TMouseEvent;
  Boundary: Boolean;
begin
  Result := True;
  if (Target = nil) or not Target.IsConnected then
    Exit;
  Boundary := (EventType = 'mouseenter') or (EventType = 'mouseleave');
  Event := TMouseEvent.Create(EventType, not Boundary, not Boundary);
  try
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
    Result := Target.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

end.
