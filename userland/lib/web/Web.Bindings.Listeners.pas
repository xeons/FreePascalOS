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
  The event listener objects the bindings put in the DOM's listener
  lists, and the event targets that are not nodes.

  TScriptEventListener holds a JavaScript callback (a function or an
  object with handleEvent). It holds no reference the collector sees:
  the wrapper of its target traces it (TBindingWrapper.Trace), and when
  that wrapper dies the listener is disabled (the target is then out of
  every script's reach). TEventHandlerListener is the one listener an
  event handler (onclick ...) of a target registers; the handler itself
  is kept in the target's wrapper (Web.Script.EventHandlers).

  Both call into their context through TBindingListenerOwner, which the
  context implements; a listener whose context has gone does nothing.
}
unit Web.Bindings.Listeners;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Web.Atoms,
  Web.Dom.Events;

type
  { What listeners need from their context. }
  TBindingListenerOwner = class
  public
    procedure InvokeListener(Callback: TJsValue; Event: TEvent); virtual; abstract;
    procedure InvokeEventHandler(EventType: TAtom; Event: TEvent); virtual; abstract;
  end;

  TScriptEventListener = class(TEventListener)
  public
    Owner: TBindingListenerOwner;
    Callback: TJsValue;
    Dead: Boolean;
    constructor Create(AOwner: TBindingListenerOwner; ACallback: TJsValue);
    procedure HandleEvent(Event: TEvent); override;
    function IsSameCallback(Other: TEventListener): Boolean; override;
  end;

  TEventHandlerListener = class(TEventListener)
  public
    Owner: TBindingListenerOwner;
    EventType: TAtom;
    Dead: Boolean;
    constructor Create(AOwner: TBindingListenerOwner; AEventType: TAtom);
    procedure HandleEvent(Event: TEvent); override;
  end;

  { An event target with listeners of its own: new EventTarget(), the
    window. }
  TStandaloneEventTarget = class(TEventTarget)
  private
    FListeners: TEventListenerList;
  protected
    function GetListenerList(CreateIfMissing: Boolean): TEventListenerList; override;
    function GetTheParent(Event: TEvent): TEventTarget; override;
  public
    ScriptWrapper: Pointer;
    { Where events go after this target (a platform script's targets:
      an IndexedDB request's transaction, a transaction's database);
      whoever sets it keeps the parent alive as long as this target. }
    EventParent: TEventTarget;
    destructor Destroy; override;
    property Listeners: TEventListenerList read FListeners;
  end;

  { The window: an event target whose wrapper is the global object. }
  TWindowTarget = class(TStandaloneEventTarget);

{ Marks the callbacks of the script listeners in List. }
procedure TraceListeners(List: TEventListenerList; Tracer: TJsTracer);
{ Disables every listener of List that belongs to Owner (its target's
  wrapper died, or the context goes). }
procedure DisableListeners(List: TEventListenerList; Owner: TBindingListenerOwner);
{ Whether List already has the event handler listener for EventType. }
function FindEventHandlerListener(List: TEventListenerList; EventType: TAtom): TEventHandlerListener;

{ Contexts that are alive: listeners check before calling. }
procedure RegisterListenerOwner(Owner: TBindingListenerOwner);
procedure UnregisterListenerOwner(Owner: TBindingListenerOwner);
function ListenerOwnerIsAlive(Owner: TBindingListenerOwner): Boolean;

implementation

var
  LiveOwners: array of TBindingListenerOwner;

procedure RegisterListenerOwner(Owner: TBindingListenerOwner);
begin
  SetLength(LiveOwners, Length(LiveOwners) + 1);
  LiveOwners[High(LiveOwners)] := Owner;
end;

procedure UnregisterListenerOwner(Owner: TBindingListenerOwner);
var
  Index: Integer;
begin
  for Index := 0 to High(LiveOwners) do
    if LiveOwners[Index] = Owner then
    begin
      LiveOwners[Index] := LiveOwners[High(LiveOwners)];
      SetLength(LiveOwners, High(LiveOwners));
      Exit;
    end;
end;

function ListenerOwnerIsAlive(Owner: TBindingListenerOwner): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(LiveOwners) do
    if LiveOwners[Index] = Owner then
      Exit(True);
  Result := False;
end;

constructor TScriptEventListener.Create(AOwner: TBindingListenerOwner; ACallback: TJsValue);
begin
  inherited Create;
  Owner := AOwner;
  Callback := ACallback;
end;

procedure TScriptEventListener.HandleEvent(Event: TEvent);
begin
  if Dead or not ListenerOwnerIsAlive(Owner) then
    Exit;
  Owner.InvokeListener(Callback, Event);
end;

function TScriptEventListener.IsSameCallback(Other: TEventListener): Boolean;
begin
  Result := (Other is TScriptEventListener) and not Dead and not TScriptEventListener(Other).Dead and
    (TScriptEventListener(Other).Callback = Callback);
end;

constructor TEventHandlerListener.Create(AOwner: TBindingListenerOwner; AEventType: TAtom);
begin
  inherited Create;
  Owner := AOwner;
  EventType := AEventType;
end;

procedure TEventHandlerListener.HandleEvent(Event: TEvent);
begin
  if Dead or not ListenerOwnerIsAlive(Owner) then
    Exit;
  Owner.InvokeEventHandler(EventType, Event);
end;

function TStandaloneEventTarget.GetListenerList(CreateIfMissing: Boolean): TEventListenerList;
begin
  if (FListeners = nil) and CreateIfMissing then
    FListeners := TEventListenerList.Create;
  Result := FListeners;
end;

function TStandaloneEventTarget.GetTheParent(Event: TEvent): TEventTarget;
begin
  Result := EventParent;
end;

destructor TStandaloneEventTarget.Destroy;
begin
  FListeners.Free;
  inherited Destroy;
end;

procedure TraceListeners(List: TEventListenerList; Tracer: TJsTracer);
var
  Index: Integer;
  Callback: TEventListener;
begin
  if List = nil then
    Exit;
  for Index := 1 to List.Count do
  begin
    Callback := List.EntryAt(Index - 1).Callback;
    if (Callback is TScriptEventListener) and not TScriptEventListener(Callback).Dead then
      Tracer.MarkValue(TScriptEventListener(Callback).Callback);
  end;
end;

procedure DisableListeners(List: TEventListenerList; Owner: TBindingListenerOwner);
var
  Index: Integer;
  Callback: TEventListener;
begin
  if List = nil then
    Exit;
  for Index := 1 to List.Count do
  begin
    Callback := List.EntryAt(Index - 1).Callback;
    if (Callback is TScriptEventListener) and (TScriptEventListener(Callback).Owner = Owner) then
    begin
      TScriptEventListener(Callback).Dead := True;
      TScriptEventListener(Callback).Callback := JsUndefined;
    end;
  end;
end;

function FindEventHandlerListener(List: TEventListenerList; EventType: TAtom): TEventHandlerListener;
var
  Index: Integer;
  Callback: TEventListener;
begin
  Result := nil;
  if List = nil then
    Exit;
  for Index := 1 to List.Count do
  begin
    Callback := List.EntryAt(Index - 1).Callback;
    if (Callback is TEventHandlerListener) and (TEventHandlerListener(Callback).EventType = EventType) and
      not TEventHandlerListener(Callback).Dead and not List.EntryAt(Index - 1).Removed then
      Exit(TEventHandlerListener(Callback));
  end;
end;

end.
