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
  Event handlers (HTML Standard 8.1.8): the onclick-style IDL attributes
  and content attributes.

  A target's handlers are kept in a small object in its wrapper (cache
  slot 0; the window's in the context), by event type: a function, or
  null for a handler that was deactivated. A content attribute's handler
  is compiled the first time it is needed (the map has no entry for the
  type then), with the attribute's value as the body of
  "function on<type>(event)", and compiled again after the attribute
  changes (the map entry is deleted). The first time a target gets a
  handler for a type, one TEventHandlerListener is added to its listener
  list, which keeps the handler's place among the listeners, as the
  standard says; it calls InvokeEventHandler.

  Not done: the element's form and the document in the handler's scope
  chain (libjavascript has no with statement), the special onerror
  signature and onbeforeunload's return value, and body/frameset handlers
  that forward to the window.
}
unit Web.Bindings.EventHandlers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Objects,
  Js.Functions,
  Js.Operations,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Events,
  Web.Dom,
  Web.Bindings.Types,
  Web.Bindings.Listeners,
  Web.Bindings.Context;

{ The handler of Target for the event type (JsNull when there is none). }
function GetEventHandler(Context: TBindingContext; Target: TEventTarget; const EventType: string): TJsValue;
{ Sets the handler (anything not callable deactivates it). }
procedure SetEventHandler(Context: TBindingContext; Target: TEventTarget; const EventType: string; Value: TJsValue);
{ Runs Target's handler for the event (the listener's callback). }
procedure RunEventHandler(Context: TBindingContext; EventType: TAtom; Event: TEvent);
{ An on* content attribute of Element was set or removed. }
procedure EventHandlerAttributeChanged(Context: TBindingContext; Element: TElement; LocalName: TAtom);
{ Element became connected: its on* content attributes get their
  listeners (the parser's elements, whose attributes were never
  "changed"). }
procedure ActivateEventHandlerAttributes(Context: TBindingContext; Element: TElement);
{ Whether an attribute name is an event handler content attribute. }
function IsEventHandlerAttribute(const Name: string): Boolean;

implementation

uses
  Web.Bindings.UrlResolution;

function IsEventHandlerAttribute(const Name: string): Boolean;
var
  Low, High, Middle: Integer;
begin
  if (Length(Name) <= 2) or (Name[1] <> 'o') or (Name[2] <> 'n') then
    Exit(False);
  Low := 0;
  High := System.High(EventHandlerNames);
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if EventHandlerNames[Middle] = Name then
      Exit(True);
    if EventHandlerNames[Middle] < Name then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := False;
end;

procedure EnsureHandlerListener(Context: TBindingContext; Target: TEventTarget; const EventType: string);
var
  TypeAtom: TAtom;
  List: TEventListenerList;
begin
  TypeAtom := Atomize(EventType);
  List := Target.ListenerList(False);
  if FindEventHandlerListener(List, TypeAtom) <> nil then
    Exit;
  Target.AddEventListener(EventType, TEventHandlerListener.Create(Context, TypeAtom), False);
end;

function CompileHandler(Context: TBindingContext; Element: TElement; const EventType, Body: string): TJsValue;
var
  Source, ErrorText: string;
begin
  Source := '(function on' + EventType + '(event) {' + LineEnding + Body + LineEnding + '})';
  if not Context.Engine.TryEvaluate(Source, DocumentUrlText(Element.NodeDocument) + ' (on' + EventType + ')',
    Result, ErrorText) then
  begin
    Context.Console('error', 'Uncaught ' + ErrorText);
    Result := JsNull;
  end;
end;

function GetEventHandler(Context: TBindingContext; Target: TEventTarget; const EventType: string): TJsValue;
var
  Map: TJsObject;
  Key: TJsValue;
  Element: TElement;
  AttributeName: TAtom;
begin
  Map := Context.EventHandlerMap(Target, False);
  Key := Context.Engine.Realm.Intern(EventType);
  if Map <> nil then
  begin
    Result := Map.GetValue(Context.Engine.Realm, Key);
    if Result <> JsUndefined then
      Exit;
  end;
  Result := JsNull;
  if not (Target is TElement) then
    Exit;
  Element := TElement(Target);
  AttributeName := FindAtom('on' + EventType);
  if (AttributeName = AtomNone) or not Element.HasAttributeAtom(AttributeName) then
    Exit;
  Result := CompileHandler(Context, Element, EventType, Element.AttributeValueOf(AttributeName));
  Map := Context.EventHandlerMap(Target, True);
  if Map <> nil then
    Map.Put(Context.Engine.Realm, Key, Result);
end;

procedure SetEventHandler(Context: TBindingContext; Target: TEventTarget; const EventType: string; Value: TJsValue);
var
  Map: TJsObject;
begin
  if not JsIsCallable(Value) then
    Value := JsNull;
  Map := Context.EventHandlerMap(Target, True);
  if Map = nil then
    Exit;
  Map.Put(Context.Engine.Realm, Context.Engine.Realm.Intern(EventType), Value);
  if Value <> JsNull then
    EnsureHandlerListener(Context, Target, EventType);
end;

procedure RunEventHandler(Context: TBindingContext; EventType: TAtom; Event: TEvent);
var
  Handler, EventValue, ThisValue, ReturnValue: TJsValue;
  Mark: Integer;
begin
  { A closed window's realm is not entered again. }
  if not Context.Engine.Realm.CanEnter then
    Exit;
  Handler := GetEventHandler(Context, Event.CurrentTarget, NameOfAtom(EventType));
  if not JsIsCallable(Handler) then
    Exit;
  EventValue := Context.WrapEvent(Event);
  Mark := Context.Engine.Runtime.PushRoot(EventValue);
  try
    Context.Engine.Runtime.PushRoot(Handler);
    ThisValue := Context.WrapTarget(Event.CurrentTarget);
    if Context.CallFunction(Handler, ThisValue, [EventValue], ReturnValue, 'on' + NameOfAtom(EventType)) and
      (ReturnValue = JsFalse) then
      Event.PreventDefault;
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

procedure EventHandlerAttributeChanged(Context: TBindingContext; Element: TElement; LocalName: TAtom);
var
  EventType: string;
  Map: TJsObject;
begin
  EventType := Copy(NameOfAtom(LocalName), 3, MaxInt);
  if Element.ScriptWrapper <> nil then
  begin
    Map := Context.EventHandlerMap(Element, False);
    if Map <> nil then
      Map.DeleteProperty(Context.Engine.Realm, Context.Engine.Realm.Intern(EventType));
  end;
  if Element.HasAttributeAtom(LocalName) then
    EnsureHandlerListener(Context, Element, EventType);
end;

procedure ActivateEventHandlerAttributes(Context: TBindingContext; Element: TElement);
var
  Index: Integer;
  Attribute: PAttributeRecord;
  Name: string;
begin
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    if Attribute^.NamespaceId <> NamespaceNone then
      Continue;
    Name := NameOfAtom(Attribute^.LocalName);
    if IsEventHandlerAttribute(Name) then
      EnsureHandlerListener(Context, Element, Copy(Name, 3, MaxInt));
  end;
end;

end.
