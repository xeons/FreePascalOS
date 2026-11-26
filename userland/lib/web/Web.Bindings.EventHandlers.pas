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
  chain (libjavascript has no with statement) and onbeforeunload's
  return value. Body and frameset elements' window-reflecting handlers
  are the window's (HandlerTarget).
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
  Web.Fetch.Requests,
  Web.Fetch.CspChecks,
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
  { CSP: an event handler attribute is inline script ('script-src-attr'). }
  if CspBlocksInline(TFetchClient(Element.NodeDocument.SecurityPolicy), CspInlineScriptAttribute, Body, '', Element,
    DocumentUrlText(Element.NodeDocument)) then
    Exit(JsNull);
  Source := '(function on' + EventType + '(event) {' + LineEnding + Body + LineEnding + '})';
  if not Context.Engine.TryEvaluate(Source, DocumentUrlText(Element.NodeDocument) + ' (on' + EventType + ')',
    Result, ErrorText) then
  begin
    Context.Console('error', 'Uncaught ' + ErrorText);
    Result := JsNull;
  end;
end;

const
  { The window-reflecting body element event handler set and
    WindowEventHandlers (HTML Standard 8.1.8.2): on body and frameset
    elements these are the window's handlers. }
  WindowReflectingTypes: array[0..23] of string = ('afterprint', 'beforeprint', 'beforeunload', 'blur', 'error',
    'focus', 'hashchange', 'languagechange', 'load', 'message', 'messageerror', 'offline', 'online', 'pagehide',
    'pagereveal', 'pageshow', 'pageswap', 'popstate', 'rejectionhandled', 'resize', 'scroll', 'storage',
    'unhandledrejection', 'unload');

function IsWindowReflectingType(const EventType: string): Boolean;
var
  Index: Integer;
begin
  for Index := Low(WindowReflectingTypes) to High(WindowReflectingTypes) do
    if WindowReflectingTypes[Index] = EventType then
      Exit(True);
  Result := False;
end;

function IsBodyOrFrameset(Target: TEventTarget): Boolean;
begin
  Result := (Target is TElement) and (TElement(Target).IsHtmlElement(AtomBody) or
    TElement(Target).IsHtmlElement(AtomFrameset));
end;

{ Whose handler Target's is: a body or frameset element's window-reflecting
  handlers are its window's (nil when its document has no window here). }
function HandlerTarget(Context: TBindingContext; Target: TEventTarget; const EventType: string): TEventTarget;
begin
  Result := Target;
  if not IsBodyOrFrameset(Target) or not IsWindowReflectingType(EventType) then
    Exit;
  if (TElement(Target).NodeDocument = Context.Document) and (Context.Window <> nil) then
    Result := Context.Window
  else
    Result := nil;
end;

{ The element whose content attribute gives Target's handler: Target, or
  for the window's reflected handlers its document's body (or frameset). }
function AttributeElement(Context: TBindingContext; Target: TEventTarget; const EventType: string): TElement;
var
  Body: TElement;
begin
  if Target is TElement then
    Exit(TElement(Target));
  Result := nil;
  if (Target <> Context.Window) or (Context.Document = nil) or not IsWindowReflectingType(EventType) then
    Exit;
  Body := Context.Document.Body;
  if IsBodyOrFrameset(Body) then
    Result := Body;
end;

function GetEventHandler(Context: TBindingContext; Target: TEventTarget; const EventType: string): TJsValue;
var
  Map: TJsObject;
  Key: TJsValue;
  Element: TElement;
  AttributeName: TAtom;
begin
  Target := HandlerTarget(Context, Target, EventType);
  if Target = nil then
    Exit(JsNull);
  Map := Context.EventHandlerMap(Target, False);
  Key := Context.Engine.Realm.Intern(EventType);
  if Map <> nil then
  begin
    Result := Map.GetValue(Context.Engine.Realm, Key);
    if Result <> JsUndefined then
      Exit;
  end;
  Result := JsNull;
  Element := AttributeElement(Context, Target, EventType);
  if Element = nil then
    Exit;
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
  Target := HandlerTarget(Context, Target, EventType);
  if Target = nil then
    Exit;
  if not JsIsCallable(Value) then
    Value := JsNull;
  Map := Context.EventHandlerMap(Target, True);
  if Map = nil then
    Exit;
  Map.Put(Context.Engine.Realm, Context.Engine.Realm.Intern(EventType), Value);
  if Value <> JsNull then
    EnsureHandlerListener(Context, Target, EventType);
end;

function EventField(Context: TBindingContext; EventValue: TJsValue; const Name: string): TJsValue;
begin
  Result := Context.Engine.GetProperty(EventValue, Name);
  if Result = JsException then
  begin
    Context.Engine.Runtime.TakeException;
    Result := JsUndefined;
  end;
end;

{ An ErrorEvent (the platform's, platform/00-base.js): it has a filename. }
function IsErrorEvent(Context: TBindingContext; EventValue: TJsValue): Boolean;
var
  Constructor_: TJsValue;
begin
  Constructor_ := Context.Engine.GetProperty(JsObjectValue(Context.Engine.GlobalObject), 'ErrorEvent');
  if Constructor_ = JsException then
  begin
    Context.Engine.Runtime.TakeException;
    Exit(False);
  end;
  Result := JsIsObject(Constructor_) and (EventField(Context, EventValue, 'filename') <> JsUndefined);
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
    if (NameOfAtom(EventType) = 'error') and (Event.CurrentTarget = Context.Window) and IsErrorEvent(Context, EventValue) then
    begin
      { The window's onerror: (message, source, lineno, colno, error);
        returning true cancels the event. }
      if Context.CallFunction(Handler, ThisValue, [EventField(Context, EventValue, 'message'),
        EventField(Context, EventValue, 'filename'), EventField(Context, EventValue, 'lineno'),
        EventField(Context, EventValue, 'colno'), EventField(Context, EventValue, 'error')], ReturnValue,
        'onerror') and (ReturnValue = JsTrue) then
        Event.PreventDefault;
    end
    else if Context.CallFunction(Handler, ThisValue, [EventValue], ReturnValue, 'on' + NameOfAtom(EventType)) and
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
  Target: TEventTarget;
begin
  EventType := Copy(NameOfAtom(LocalName), 3, MaxInt);
  Target := HandlerTarget(Context, Element, EventType);
  if Target = nil then
    Exit;
  if (Target <> Element) or (Element.ScriptWrapper <> nil) then
  begin
    Map := Context.EventHandlerMap(Target, False);
    if Map <> nil then
      Map.DeleteProperty(Context.Engine.Realm, Context.Engine.Realm.Intern(EventType));
  end;
  if Element.HasAttributeAtom(LocalName) then
    EnsureHandlerListener(Context, Target, EventType);
end;

procedure ActivateEventHandlerAttributes(Context: TBindingContext; Element: TElement);
var
  Index: Integer;
  Attribute: PAttributeRecord;
  Name: string;
  Target: TEventTarget;
begin
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    if Attribute^.NamespaceId <> NamespaceNone then
      Continue;
    Name := NameOfAtom(Attribute^.LocalName);
    if not IsEventHandlerAttribute(Name) then
      Continue;
    Target := HandlerTarget(Context, Element, Copy(Name, 3, MaxInt));
    if Target <> nil then
      EnsureHandlerListener(Context, Target, Copy(Name, 3, MaxInt));
  end;
end;

end.
