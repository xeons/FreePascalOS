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
  InputEvent over Web.Dom.Events and Web.Dom.UiEvents.
}
unit Web.Bindings.Events;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Events.Members.inc}

implementation

uses
  SysUtils,
  Js.Objects,
  Web.Atoms,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Dom.Exceptions,
  Web.Bindings.Context,
  Web.Bindings.Listeners;

const
  { The cache slot of a CustomEvent's detail (events have no
    [SameObject] attributes and no handlers). }
  CacheSlotDetail = 1;

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
  ApplyUiInit(Event, Init^);
  ApplyModifierInit(Event, Init^);
  Event.ScreenX := Trunc(Init^.Items[MouseEventInit_screenX].Number);
  Event.ScreenY := Trunc(Init^.Items[MouseEventInit_screenY].Number);
  Event.ClientX := Trunc(Init^.Items[MouseEventInit_clientX].Number);
  Event.ClientY := Trunc(Init^.Items[MouseEventInit_clientY].Number);
  Event.Button := Trunc(Init^.Items[MouseEventInit_button].Number);
  Event.Buttons := Trunc(Init^.Items[MouseEventInit_buttons].Number);
  if Init^.Items[MouseEventInit_relatedTarget].Native <> nil then
    Event.RelatedTarget := TEventTarget(Init^.Items[MouseEventInit_relatedTarget].Native);
  Result := StartEvent(Call, Event);
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

end.
