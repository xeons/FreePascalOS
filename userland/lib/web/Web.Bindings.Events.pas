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
  bindings/Events.webidl: EventTarget (listeners are TScriptEventListener
  objects in the DOM's lists), Event, CustomEvent (its detail in the
  wrapper's cache), UIEvent, MouseEvent, KeyboardEvent, FocusEvent and
  InputEvent over Web.Dom.Events and Web.Dom.UiEvents; DataTransfer's
  string data and ClipboardEvent over Web.Dom.DataTransfer.
}
unit Web.Bindings.Events;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Bindings.Types;

{$I Web.Bindings.Events.Members.inc}

{ For the event kinds bound in other units (WheelEvent): a constructed
  event's EventInit members, and a MouseEventInit's (with the UIEventInit
  and EventModifierInit ones). }
function StartEvent(var Call: TBindingCall; Event: TEvent): TJsValue;
procedure ApplyMouseInit(Event: TMouseEvent; const Init: TBindingValue);

implementation

uses
  SysUtils,
  Js.Objects,
  Web.Atoms,
  Web.Dom.DataTransfer,
  Web.Dom.SecurityEvents,
  Web.Dom.Exceptions,
  Web.Navigation.Events,
  Web.Bindings.Context,
  Web.Bindings.Listeners;

const
  { The cache slot of a CustomEvent's detail (events have no
    [SameObject] attributes and no handlers). }
  CacheSlotDetail = 1;
  { A ClipboardEvent's clipboardData wrapper. }
  CacheSlotClipboardData = 1;
  { A constructed PopStateEvent's state. }
  CacheSlotPopState = 1;

function ThisEvent(const Call: TBindingCall): TEvent; inline;
begin
  Result := TEvent(Call.Target);
end;

function ThisTarget(const Call: TBindingCall): TEventTarget; inline;
begin
  Result := TEventTarget(Call.Target);
end;

{ EventTarget }

function EventTarget_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).ConstructedObject(Call, TStandaloneEventTarget.Create);
end;

procedure ReadListenerOptions(const Options: TBindingValue; out Capture, Once, Passive: Boolean);
begin
  Capture := False;
  Once := False;
  Passive := False;
  case Options.Kind of
    bvBoolean:
      Capture := Options.Flag;
    bvDictionary:
      begin
        Capture := Options.Items[0].Flag;
        if Length(Options.Items) > 1 then
        begin
          Once := Options.Items[AddEventListenerOptions_once].Flag;
          Passive := Options.Items[AddEventListenerOptions_passive].Flag;
        end;
      end;
  end;
end;

function EventTarget_addEventListener(var Call: TBindingCall): TJsValue;
var
  Options: TEventListenerOptions;
begin
  Result := JsUndefined;
  if Call.IsNull(1) then
    Exit;
  ReadListenerOptions(Call.Arguments[2], Options.Capture, Options.Once, Options.Passive);
  ThisTarget(Call).AddEventListener(Call.Text(0), TScriptEventListener.Create(CallContext(Call), Call.Script(1)),
    Options);
end;

function EventTarget_removeEventListener(var Call: TBindingCall): TJsValue;
var
  Capture, Once, Passive: Boolean;
  Probe: TScriptEventListener;
begin
  Result := JsUndefined;
  if Call.IsNull(1) then
    Exit;
  ReadListenerOptions(Call.Arguments[2], Capture, Once, Passive);
  Probe := TScriptEventListener.Create(CallContext(Call), Call.Script(1));
  try
    ThisTarget(Call).RemoveEventListener(Call.Text(0), Probe, Capture);
  finally
    Probe.Free;
  end;
end;

function EventTarget_dispatchEvent(var Call: TBindingCall): TJsValue;
var
  Event: TEvent;
begin
  Event := TEvent(Call.Native(0));
  Event.Retain;
  try
    { DOM 2.9: an event script dispatches is not trusted (the engine's
      own dispatches keep the flag their creator set). }
    if not Event.IsDispatching then
      Event.IsTrusted := False;
    Result := JsBoolean(ThisTarget(Call).DispatchEvent(Event));
  finally
    Event.Release;
  end;
end;

{ Event }

function StartEvent(var Call: TBindingCall; Event: TEvent): TJsValue;
begin
  Event.InitEvent(Call.Text(0), Call.Arguments[1].Items[EventInit_bubbles].Flag,
    Call.Arguments[1].Items[EventInit_cancelable].Flag);
  Event.Composed := Call.Arguments[1].Items[EventInit_composed].Flag;
  Event.TimeStamp := CallContext(Call).Now;
  Result := CallContext(Call).ConstructedEvent(Call, Event);
end;

function Event_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := StartEvent(Call, TEvent.Create(Call.Text(0)));
end;

function Event_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisEvent(Call).TypeName);
end;

function Event_get_target(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).WrapTarget(ThisEvent(Call).Target);
end;

function Event_get_srcElement(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).WrapTarget(ThisEvent(Call).Target);
end;

function Event_get_currentTarget(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).WrapTarget(ThisEvent(Call).CurrentTarget);
end;

function Event_composedPath(var Call: TBindingCall): TJsValue;
var
  Path: TEventTargetArray;
  Values: array of TJsValue;
  Index: Integer;
begin
  Path := ThisEvent(Call).ComposedPath;
  Values := nil;
  SetLength(Values, Length(Path));
  for Index := 0 to High(Path) do
    Values[Index] := CallContext(Call).WrapTarget(Path[Index]);
  Result := CallContext(Call).NewArray(Values);
end;

function Event_get_eventPhase(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Ord(ThisEvent(Call).EventPhase));
end;

function Event_stopPropagation(var Call: TBindingCall): TJsValue;
begin
  ThisEvent(Call).StopPropagation;
  Result := JsUndefined;
end;

function Event_get_cancelBubble(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).CancelBubble);
end;

function Event_set_cancelBubble(var Call: TBindingCall): TJsValue;
begin
  ThisEvent(Call).CancelBubble := Call.Flag(0);
  Result := JsUndefined;
end;

function Event_stopImmediatePropagation(var Call: TBindingCall): TJsValue;
begin
  ThisEvent(Call).StopImmediatePropagation;
  Result := JsUndefined;
end;

function Event_get_bubbles(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).Bubbles);
end;

function Event_get_cancelable(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).Cancelable);
end;

function Event_get_returnValue(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).ReturnValue);
end;

function Event_set_returnValue(var Call: TBindingCall): TJsValue;
begin
  ThisEvent(Call).ReturnValue := Call.Flag(0);
  Result := JsUndefined;
end;

function Event_preventDefault(var Call: TBindingCall): TJsValue;
begin
  ThisEvent(Call).PreventDefault;
  Result := JsUndefined;
end;

function Event_get_defaultPrevented(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).DefaultPrevented);
end;

function Event_get_composed(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).Composed);
end;

function Event_get_isTrusted(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisEvent(Call).IsTrusted);
end;

function Event_get_timeStamp(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisEvent(Call).TimeStamp);
end;

function Event_initEvent(var Call: TBindingCall): TJsValue;
begin
  ThisEvent(Call).InitEvent(Call.Text(0), Call.Flag(1), Call.Flag(2));
  Result := JsUndefined;
end;

{ CustomEvent }

function CustomEvent_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := StartEvent(Call, TCustomEvent.Create(Call.Text(0)));
  CallContext(Call).WrapperOf(Result).SetCachedValue(CacheSlotDetail,
    Call.Arguments[1].Items[CustomEventInit_detail].Script);
end;

function CustomEvent_get_detail(var Call: TBindingCall): TJsValue;
var
  Wrapper: TBindingWrapper;
begin
  Wrapper := TBindingWrapper(Call.Wrapper);
  Result := Wrapper.CachedValue(CacheSlotDetail);
  if Result = JsUndefined then
    Result := JsNull;
end;

function CustomEvent_initCustomEvent(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
  if ThisEvent(Call).IsDispatching then
    Exit;
  ThisEvent(Call).InitEvent(Call.Text(0), Call.Flag(1), Call.Flag(2));
  TBindingWrapper(Call.Wrapper).SetCachedValue(CacheSlotDetail, Call.Script(3));
end;

{ DataTransfer }

function ThisDataTransfer(const Call: TBindingCall): TDataTransfer; inline;
begin
  Result := TDataTransfer(Call.Target);
end;

function DataTransfer_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).ConstructedObject(Call, TDataTransfer.Create);
end;

function DataTransfer_get_dropEffect(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisDataTransfer(Call).DropEffect);
end;

function DataTransfer_set_dropEffect(var Call: TBindingCall): TJsValue;
var
  Value: string;
begin
  Value := Call.Text(0);
  if (Value = 'none') or (Value = 'copy') or (Value = 'link') or (Value = 'move') then
    ThisDataTransfer(Call).DropEffect := Value;
  Result := JsUndefined;
end;

function DataTransfer_get_effectAllowed(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisDataTransfer(Call).EffectAllowed);
end;

function DataTransfer_set_effectAllowed(var Call: TBindingCall): TJsValue;
var
  Value: string;
begin
  Value := Call.Text(0);
  if (Value = 'none') or (Value = 'copy') or (Value = 'copyLink') or (Value = 'copyMove') or (Value = 'link') or
    (Value = 'linkMove') or (Value = 'move') or (Value = 'all') or (Value = 'uninitialized') then
    ThisDataTransfer(Call).EffectAllowed := Value;
  Result := JsUndefined;
end;

function DataTransfer_get_types(var Call: TBindingCall): TJsValue;
var
  Types: TStringArray;
  Values: array of TJsValue;
  Index: Integer;
begin
  Values := nil;
  if ThisDataTransfer(Call).Mode <> DataTransferProtected then
  begin
    Types := ThisDataTransfer(Call).Types;
    SetLength(Values, Length(Types));
    for Index := 0 to High(Types) do
      Values[Index] := CallContext(Call).TextValue(Types[Index]);
  end;
  Result := CallContext(Call).NewArray(Values);
end;

function DataTransfer_getData(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisDataTransfer(Call).GetData(Call.Text(0)));
end;

function DataTransfer_setData(var Call: TBindingCall): TJsValue;
begin
  ThisDataTransfer(Call).SetData(Call.Text(0), Call.Text(1));
  Result := JsUndefined;
end;

function DataTransfer_clearData(var Call: TBindingCall): TJsValue;
begin
  if Call.Present(0) then
    ThisDataTransfer(Call).ClearData(Call.Text(0))
  else
    ThisDataTransfer(Call).ClearData('');
  Result := JsUndefined;
end;

{ ClipboardEvent: the data of an event made by script is the script's
  DataTransfer (its wrapper kept in the event's cache); the engine's
  own events own theirs. }

function ClipboardEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TClipboardEvent;
  Data: PBindingValue;
begin
  Event := TClipboardEvent.Create(Call.Text(0));
  Data := @Call.Arguments[1].Items[ClipboardEventInit_clipboardData];
  if Data^.Native is TDataTransfer then
    Event.ClipboardData := TDataTransfer(Data^.Native);
  Result := StartEvent(Call, Event);
  if Event.ClipboardData <> nil then
    CallContext(Call).WrapperOf(Result).SetCachedValue(CacheSlotClipboardData, Data^.Script);
end;

function ClipboardEvent_get_clipboardData(var Call: TBindingCall): TJsValue;
var
  Wrapper: TBindingWrapper;
  Event: TClipboardEvent;
begin
  Wrapper := TBindingWrapper(Call.Wrapper);
  Result := Wrapper.CachedValue(CacheSlotClipboardData);
  if Result <> JsUndefined then
    Exit;
  Event := TClipboardEvent(Call.Target);
  if Event.ClipboardData = nil then
    Exit(JsNull);
  Result := CallContext(Call).WrapObject(Event.ClipboardData, InterfaceDataTransfer, False, Call.This);
  Wrapper.SetCachedValue(CacheSlotClipboardData, Result);
end;

{ UIEvent and its kinds: the dictionaries are flattened, so the members
  inherited from EventInit and UIEventInit have the same indexes in all
  of them. }

procedure ApplyUiInit(Event: TUiEvent; const Init: TBindingValue);
begin
  Event.HasView := Init.Items[UIEventInit_view].Native <> nil;
  Event.Detail := Trunc(Init.Items[UIEventInit_detail].Number);
end;

procedure ApplyModifierInit(Event: TUiEvent; const Init: TBindingValue);
begin
  Event.Modifiers := [];
  if Init.Items[EventModifierInit_ctrlKey].Flag then
    Include(Event.Modifiers, ModifierControl);
  if Init.Items[EventModifierInit_shiftKey].Flag then
    Include(Event.Modifiers, ModifierShift);
  if Init.Items[EventModifierInit_altKey].Flag then
    Include(Event.Modifiers, ModifierAlt);
  if Init.Items[EventModifierInit_metaKey].Flag then
    Include(Event.Modifiers, ModifierMeta);
end;

procedure ApplyMouseInit(Event: TMouseEvent; const Init: TBindingValue);
begin
  ApplyUiInit(Event, Init);
  ApplyModifierInit(Event, Init);
  Event.ScreenX := Trunc(Init.Items[MouseEventInit_screenX].Number);
  Event.ScreenY := Trunc(Init.Items[MouseEventInit_screenY].Number);
  Event.ClientX := Trunc(Init.Items[MouseEventInit_clientX].Number);
  Event.ClientY := Trunc(Init.Items[MouseEventInit_clientY].Number);
  Event.Button := Trunc(Init.Items[MouseEventInit_button].Number);
  Event.Buttons := Trunc(Init.Items[MouseEventInit_buttons].Number);
  Event.MovementX := Init.Items[MouseEventInit_movementX].Number;
  Event.MovementY := Init.Items[MouseEventInit_movementY].Number;
  if Init.Items[MouseEventInit_relatedTarget].Native <> nil then
    Event.RelatedTarget := TEventTarget(Init.Items[MouseEventInit_relatedTarget].Native);
end;

function ThisUiEvent(const Call: TBindingCall): TUiEvent; inline;
begin
  Result := TUiEvent(Call.Target);
end;

function UIEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TUiEvent;
begin
  Event := TUiEvent.Create(Call.Text(0));
  ApplyUiInit(Event, Call.Arguments[1]);
  Result := StartEvent(Call, Event);
end;

function UIEvent_get_view(var Call: TBindingCall): TJsValue;
begin
  if ThisUiEvent(Call).HasView then
    Result := CallContext(Call).WrapTarget(CallContext(Call).Window)
  else
    Result := JsNull;
end;

function UIEvent_get_detail(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisUiEvent(Call).Detail);
end;

function UIEvent_get_which(var Call: TBindingCall): TJsValue;
begin
  if Call.Target is TKeyboardEvent then
    Result := JsNumber(TKeyboardEvent(Call.Target).KeyCode)
  else if Call.Target is TMouseEvent then
    Result := JsInteger(TMouseEvent(Call.Target).Button + 1)
  else
    Result := JsInteger(0);
end;

{ initUIEvent and initMouseEvent (legacy): nothing while the event is
  being dispatched, as initEvent. }
procedure InitUiFields(var Call: TBindingCall; Event: TUiEvent);
begin
  Event.InitEvent(Call.Text(0), Call.Flag(1), Call.Flag(2));
  Event.HasView := Call.Arguments[3].Native <> nil;
  Event.Detail := Trunc(Call.Arguments[4].Number);
end;

function UIEvent_initUIEvent(var Call: TBindingCall): TJsValue;
begin
  if not ThisUiEvent(Call).IsDispatching then
    InitUiFields(Call, ThisUiEvent(Call));
  Result := JsUndefined;
end;

function ThisMouseEvent(const Call: TBindingCall): TMouseEvent; inline;
begin
  Result := TMouseEvent(Call.Target);
end;

function MouseEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TMouseEvent;
  Init: PBindingValue;
begin
  Event := TMouseEvent.Create(Call.Text(0));
  Init := @Call.Arguments[1];
  ApplyMouseInit(Event, Init^);
  Result := StartEvent(Call, Event);
end;

function MouseEvent_initMouseEvent(var Call: TBindingCall): TJsValue;
var
  Event: TMouseEvent;
begin
  Result := JsUndefined;
  Event := ThisMouseEvent(Call);
  if Event.IsDispatching then
    Exit;
  InitUiFields(Call, Event);
  Event.ScreenX := Trunc(Call.Arguments[5].Number);
  Event.ScreenY := Trunc(Call.Arguments[6].Number);
  Event.ClientX := Trunc(Call.Arguments[7].Number);
  Event.ClientY := Trunc(Call.Arguments[8].Number);
  Event.Modifiers := [];
  if Call.Flag(9) then
    Include(Event.Modifiers, ModifierControl);
  if Call.Flag(10) then
    Include(Event.Modifiers, ModifierAlt);
  if Call.Flag(11) then
    Include(Event.Modifiers, ModifierShift);
  if Call.Flag(12) then
    Include(Event.Modifiers, ModifierMeta);
  Event.Button := Trunc(Call.Arguments[13].Number);
  Event.RelatedTarget := nil;
  if Call.Arguments[14].Native <> nil then
    Event.RelatedTarget := TEventTarget(Call.Arguments[14].Native);
end;

function MouseEvent_get_screenX(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ScreenX);
end;

function MouseEvent_get_screenY(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ScreenY);
end;

function MouseEvent_get_clientX(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ClientX);
end;

function MouseEvent_get_clientY(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ClientY);
end;

function MouseEvent_get_pageX(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ClientX + ThisMouseEvent(Call).ScrollX);
end;

function MouseEvent_get_pageY(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ClientY + ThisMouseEvent(Call).ScrollY);
end;

function MouseEvent_get_offsetX(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).OffsetX);
end;

function MouseEvent_get_offsetY(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).OffsetY);
end;

function MouseEvent_get_x(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ClientX);
end;

function MouseEvent_get_y(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).ClientY);
end;

function MouseEvent_get_ctrlKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierControl in ThisMouseEvent(Call).Modifiers);
end;

function MouseEvent_get_shiftKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierShift in ThisMouseEvent(Call).Modifiers);
end;

function MouseEvent_get_altKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierAlt in ThisMouseEvent(Call).Modifiers);
end;

function MouseEvent_get_metaKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierMeta in ThisMouseEvent(Call).Modifiers);
end;

function MouseEvent_get_button(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).Button);
end;

function MouseEvent_get_movementX(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisMouseEvent(Call).MovementX);
end;

function MouseEvent_get_movementY(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisMouseEvent(Call).MovementY);
end;

function MouseEvent_get_buttons(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMouseEvent(Call).Buttons);
end;

function MouseEvent_get_relatedTarget(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).WrapTarget(ThisMouseEvent(Call).RelatedTarget);
end;

function MouseEvent_getModifierState(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisMouseEvent(Call).ModifierState(Call.Text(0)));
end;

function ThisPointerEvent(const Call: TBindingCall): TPointerEvent; inline;
begin
  Result := TPointerEvent(Call.Target);
end;

function PointerEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TPointerEvent;
  Init: PBindingValue;
begin
  Event := TPointerEvent.Create(Call.Text(0));
  Init := @Call.Arguments[1];
  ApplyMouseInit(Event, Init^);
  Event.PointerId := Trunc(Init^.Items[PointerEventInit_pointerId].Number);
  Event.Width := Init^.Items[PointerEventInit_width].Number;
  Event.Height := Init^.Items[PointerEventInit_height].Number;
  Event.Pressure := Init^.Items[PointerEventInit_pressure].Number;
  Event.TangentialPressure := Init^.Items[PointerEventInit_tangentialPressure].Number;
  Event.TiltX := Trunc(Init^.Items[PointerEventInit_tiltX].Number);
  Event.TiltY := Trunc(Init^.Items[PointerEventInit_tiltY].Number);
  Event.Twist := Trunc(Init^.Items[PointerEventInit_twist].Number);
  Event.AltitudeAngle := Init^.Items[PointerEventInit_altitudeAngle].Number;
  Event.AzimuthAngle := Init^.Items[PointerEventInit_azimuthAngle].Number;
  Event.PointerType := Init^.Items[PointerEventInit_pointerType].Text;
  Event.IsPrimary := Init^.Items[PointerEventInit_isPrimary].Flag;
  Result := StartEvent(Call, Event);
end;

function PointerEvent_get_pointerId(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisPointerEvent(Call).PointerId);
end;

function PointerEvent_get_width(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisPointerEvent(Call).Width);
end;

function PointerEvent_get_height(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisPointerEvent(Call).Height);
end;

function PointerEvent_get_pressure(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(Single(ThisPointerEvent(Call).Pressure));
end;

function PointerEvent_get_tangentialPressure(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(Single(ThisPointerEvent(Call).TangentialPressure));
end;

function PointerEvent_get_tiltX(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisPointerEvent(Call).TiltX);
end;

function PointerEvent_get_tiltY(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisPointerEvent(Call).TiltY);
end;

function PointerEvent_get_twist(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisPointerEvent(Call).Twist);
end;

function PointerEvent_get_altitudeAngle(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisPointerEvent(Call).AltitudeAngle);
end;

function PointerEvent_get_azimuthAngle(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisPointerEvent(Call).AzimuthAngle);
end;

function PointerEvent_get_pointerType(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisPointerEvent(Call).PointerType);
end;

function PointerEvent_get_isPrimary(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisPointerEvent(Call).IsPrimary);
end;

{ The events coalesced into this one: a trusted pointermove is its own
  (moves are not merged), the others have none. }
function PointerEvent_getCoalescedEvents(var Call: TBindingCall): TJsValue;
var
  Values: array of TJsValue;
begin
  Values := nil;
  if ThisPointerEvent(Call).IsTrusted and (ThisPointerEvent(Call).TypeName = 'pointermove') then
  begin
    SetLength(Values, 1);
    Values[0] := Call.This;
  end;
  Result := CallContext(Call).NewArray(Values);
end;

{ No predicted positions are made. }
function PointerEvent_getPredictedEvents(var Call: TBindingCall): TJsValue;
var
  Values: array of TJsValue;
begin
  Values := nil;
  Result := CallContext(Call).NewArray(Values);
end;

function ThisKeyboardEvent(const Call: TBindingCall): TKeyboardEvent; inline;
begin
  Result := TKeyboardEvent(Call.Target);
end;

function KeyboardEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TKeyboardEvent;
  Init: PBindingValue;
begin
  Event := TKeyboardEvent.Create(Call.Text(0));
  Init := @Call.Arguments[1];
  ApplyUiInit(Event, Init^);
  ApplyModifierInit(Event, Init^);
  Event.Key := Init^.Items[KeyboardEventInit_key].Text;
  Event.Code := Init^.Items[KeyboardEventInit_code].Text;
  Event.Location := Trunc(Init^.Items[KeyboardEventInit_location].Number);
  Event.IsRepeat := Init^.Items[KeyboardEventInit_repeat].Flag;
  Event.IsComposing := Init^.Items[KeyboardEventInit_isComposing].Flag;
  Event.CharCode := Trunc(Init^.Items[KeyboardEventInit_charCode].Number);
  Event.KeyCode := Trunc(Init^.Items[KeyboardEventInit_keyCode].Number);
  Result := StartEvent(Call, Event);
end;

function KeyboardEvent_get_key(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisKeyboardEvent(Call).Key);
end;

function KeyboardEvent_get_code(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisKeyboardEvent(Call).Code);
end;

function KeyboardEvent_get_location(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisKeyboardEvent(Call).Location);
end;

function KeyboardEvent_get_ctrlKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierControl in ThisKeyboardEvent(Call).Modifiers);
end;

function KeyboardEvent_get_shiftKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierShift in ThisKeyboardEvent(Call).Modifiers);
end;

function KeyboardEvent_get_altKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierAlt in ThisKeyboardEvent(Call).Modifiers);
end;

function KeyboardEvent_get_metaKey(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ModifierMeta in ThisKeyboardEvent(Call).Modifiers);
end;

function KeyboardEvent_get_repeat(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisKeyboardEvent(Call).IsRepeat);
end;

function KeyboardEvent_get_isComposing(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisKeyboardEvent(Call).IsComposing);
end;

function KeyboardEvent_get_charCode(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisKeyboardEvent(Call).CharCode);
end;

function KeyboardEvent_get_keyCode(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisKeyboardEvent(Call).KeyCode);
end;

function KeyboardEvent_getModifierState(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisKeyboardEvent(Call).ModifierState(Call.Text(0)));
end;

function FocusEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TFocusEvent;
begin
  Event := TFocusEvent.Create(Call.Text(0));
  ApplyUiInit(Event, Call.Arguments[1]);
  if Call.Arguments[1].Items[FocusEventInit_relatedTarget].Native <> nil then
    Event.RelatedTarget := TEventTarget(Call.Arguments[1].Items[FocusEventInit_relatedTarget].Native);
  Result := StartEvent(Call, Event);
end;

function FocusEvent_get_relatedTarget(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).WrapTarget(ThisEvent(Call).RelatedTarget);
end;

function ThisInputEvent(const Call: TBindingCall): TInputEvent; inline;
begin
  Result := TInputEvent(Call.Target);
end;

function InputEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TInputEvent;
  Init: PBindingValue;
begin
  Event := TInputEvent.Create(Call.Text(0));
  Init := @Call.Arguments[1];
  ApplyUiInit(Event, Init^);
  Event.HasData := Init^.Items[InputEventInit_data].Kind = bvString;
  Event.Data := Init^.Items[InputEventInit_data].Text;
  Event.IsComposing := Init^.Items[InputEventInit_isComposing].Flag;
  Event.InputType := Init^.Items[InputEventInit_inputType].Text;
  Result := StartEvent(Call, Event);
end;

function InputEvent_get_data(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).NullableText(ThisInputEvent(Call).Data, not ThisInputEvent(Call).HasData);
end;

function InputEvent_get_isComposing(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisInputEvent(Call).IsComposing);
end;

function InputEvent_get_inputType(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisInputEvent(Call).InputType);
end;

{ CSS Animations and Transitions events }

function AnimationEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TAnimationEvent;
begin
  Event := TAnimationEvent.Create(Call.Text(0));
  Event.AnimationName := Call.Arguments[1].Items[AnimationEventInit_animationName].Text;
  Event.ElapsedTime := Call.Arguments[1].Items[AnimationEventInit_elapsedTime].Number;
  Event.PseudoElement := Call.Arguments[1].Items[AnimationEventInit_pseudoElement].Text;
  Result := StartEvent(Call, Event);
end;

function AnimationEvent_get_animationName(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(TAnimationEvent(Call.Target).AnimationName);
end;

function AnimationEvent_get_elapsedTime(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(TAnimationEvent(Call.Target).ElapsedTime);
end;

function AnimationEvent_get_pseudoElement(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(TAnimationEvent(Call.Target).PseudoElement);
end;

function TransitionEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TTransitionEvent;
begin
  Event := TTransitionEvent.Create(Call.Text(0));
  Event.PropertyName := Call.Arguments[1].Items[TransitionEventInit_propertyName].Text;
  Event.ElapsedTime := Call.Arguments[1].Items[TransitionEventInit_elapsedTime].Number;
  Event.PseudoElement := Call.Arguments[1].Items[TransitionEventInit_pseudoElement].Text;
  Result := StartEvent(Call, Event);
end;

function TransitionEvent_get_propertyName(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(TTransitionEvent(Call.Target).PropertyName);
end;

function TransitionEvent_get_elapsedTime(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(TTransitionEvent(Call.Target).ElapsedTime);
end;

function TransitionEvent_get_pseudoElement(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(TTransitionEvent(Call.Target).PseudoElement);
end;

{ SecurityPolicyViolationEvent (CSP 5.1). }

function ThisViolationEvent(const Call: TBindingCall): TSecurityPolicyViolationEvent; inline;
begin
  Result := TSecurityPolicyViolationEvent(Call.Target);
end;

function SecurityPolicyViolationEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TSecurityPolicyViolationEvent;
  Init: PBindingValue;
begin
  Event := TSecurityPolicyViolationEvent.Create(Call.Text(0));
  Init := @Call.Arguments[1];
  Event.DocumentUri := Init^.Items[SecurityPolicyViolationEventInit_documentURI].Text;
  Event.Referrer := Init^.Items[SecurityPolicyViolationEventInit_referrer].Text;
  Event.BlockedUri := Init^.Items[SecurityPolicyViolationEventInit_blockedURI].Text;
  Event.ViolatedDirective := Init^.Items[SecurityPolicyViolationEventInit_violatedDirective].Text;
  Event.EffectiveDirective := Init^.Items[SecurityPolicyViolationEventInit_effectiveDirective].Text;
  Event.OriginalPolicy := Init^.Items[SecurityPolicyViolationEventInit_originalPolicy].Text;
  Event.SourceFile := Init^.Items[SecurityPolicyViolationEventInit_sourceFile].Text;
  Event.Sample := Init^.Items[SecurityPolicyViolationEventInit_sample].Text;
  Event.Disposition := Init^.Items[SecurityPolicyViolationEventInit_disposition].Text;
  Event.StatusCode := Trunc(Init^.Items[SecurityPolicyViolationEventInit_statusCode].Number);
  Event.LineNumber := Trunc(Init^.Items[SecurityPolicyViolationEventInit_lineNumber].Number);
  Event.ColumnNumber := Trunc(Init^.Items[SecurityPolicyViolationEventInit_columnNumber].Number);
  Result := StartEvent(Call, Event);
end;

function SecurityPolicyViolationEvent_get_documentURI(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).DocumentUri);
end;

function SecurityPolicyViolationEvent_get_referrer(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).Referrer);
end;

function SecurityPolicyViolationEvent_get_blockedURI(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).BlockedUri);
end;

function SecurityPolicyViolationEvent_get_effectiveDirective(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).EffectiveDirective);
end;

function SecurityPolicyViolationEvent_get_violatedDirective(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).ViolatedDirective);
end;

function SecurityPolicyViolationEvent_get_originalPolicy(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).OriginalPolicy);
end;

function SecurityPolicyViolationEvent_get_sourceFile(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).SourceFile);
end;

function SecurityPolicyViolationEvent_get_sample(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).Sample);
end;

function SecurityPolicyViolationEvent_get_disposition(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(ThisViolationEvent(Call).Disposition);
end;

function SecurityPolicyViolationEvent_get_statusCode(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisViolationEvent(Call).StatusCode);
end;

function SecurityPolicyViolationEvent_get_lineNumber(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisViolationEvent(Call).LineNumber);
end;

function SecurityPolicyViolationEvent_get_columnNumber(var Call: TBindingCall): TJsValue;
begin
  Result := JsNumber(ThisViolationEvent(Call).ColumnNumber);
end;

{ The navigation events (Web.Navigation.Events). }

function HashChangeEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: THashChangeEvent;
begin
  Event := THashChangeEvent.Create(Call.Text(0));
  Event.OldUrl := Call.Arguments[1].Items[HashChangeEventInit_oldURL].Text;
  Event.NewUrl := Call.Arguments[1].Items[HashChangeEventInit_newURL].Text;
  Result := StartEvent(Call, Event);
end;

function HashChangeEvent_get_oldURL(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(THashChangeEvent(Call.Target).OldUrl);
end;

function HashChangeEvent_get_newURL(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(THashChangeEvent(Call.Target).NewUrl);
end;

function PageTransitionEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TPageTransitionEvent;
begin
  Event := TPageTransitionEvent.Create(Call.Text(0));
  Event.Persisted := Call.Arguments[1].Items[PageTransitionEventInit_persisted].Flag;
  Result := StartEvent(Call, Event);
end;

function PageTransitionEvent_get_persisted(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(TPageTransitionEvent(Call.Target).Persisted);
end;

function PopStateEvent_constructor(var Call: TBindingCall): TJsValue;
var
  Event: TPopStateEvent;
begin
  Event := TPopStateEvent.Create(Call.Text(0));
  Event.HasUaVisualTransition := Call.Arguments[1].Items[PopStateEventInit_hasUAVisualTransition].Flag;
  Result := StartEvent(Call, Event);
  CallContext(Call).WrapperOf(Result).SetCachedValue(CacheSlotPopState,
    Call.Arguments[1].Items[PopStateEventInit_state].Script);
end;

{ A constructed event's state, else (the user agent's) the history state
  the traversal restored. }
function PopStateEvent_get_state(var Call: TBindingCall): TJsValue;
begin
  Result := TBindingWrapper(Call.Wrapper).CachedValue(CacheSlotPopState);
  if Result = JsUndefined then
    Result := CallContext(Call).Singleton(SingletonHistoryState);
  if Result = JsUndefined then
    Result := JsNull;
end;

function PopStateEvent_get_hasUAVisualTransition(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(TPopStateEvent(Call.Target).HasUaVisualTransition);
end;

function BeforeUnloadEvent_get_returnValue(var Call: TBindingCall): TJsValue;
begin
  Result := CallContext(Call).TextValue(TBeforeUnloadEvent(Call.Target).UnloadReturnValue);
end;

function BeforeUnloadEvent_set_returnValue(var Call: TBindingCall): TJsValue;
begin
  TBeforeUnloadEvent(Call.Target).UnloadReturnValue := Call.Text(0);
  Result := JsUndefined;
end;

end.
