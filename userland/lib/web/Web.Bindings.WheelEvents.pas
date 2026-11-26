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
  UI Events: WheelEvent (bindings/WheelEvents.webidl), a mouse event
  with the wheel's deltas. Pages construct them (and feature-test the
  constructor); the deltas are what the event was made with.
}
unit Web.Bindings.WheelEvents;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.WheelEvents.Members.inc}

implementation

uses
  Web.Dom.UiEvents,
  Web.Bindings.Events;

function ThisWheelEvent(const Call: TBindingCall): TWheelEvent; inline;
begin
  Result := TWheelEvent(Call.Target);
end;

function WheelEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TWheelEvent;
  Init: PBindingValue;
begin
  Event := TWheelEvent.Create(Call.Text(0));
  Init := @Call.Arguments[1];
  ApplyMouseInit(Event, Init^);
  Event.DeltaX := Init^.Items[WheelEventInit_deltaX].Number;
  Event.DeltaY := Init^.Items[WheelEventInit_deltaY].Number;
  Event.DeltaZ := Init^.Items[WheelEventInit_deltaZ].Number;
  Event.DeltaMode := Trunc(Init^.Items[WheelEventInit_deltaMode].Number);
  Result := StartEvent(Call, Event);
end;

function WheelEvent_get_deltaX(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisWheelEvent(Call).DeltaX);
end;

function WheelEvent_get_deltaY(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisWheelEvent(Call).DeltaY);
end;

function WheelEvent_get_deltaZ(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisWheelEvent(Call).DeltaZ);
end;

function WheelEvent_get_deltaMode(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisWheelEvent(Call).DeltaMode);
end;

end.
