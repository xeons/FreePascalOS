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
  DOM events: Event, EventTarget and dispatch (DOM Standard section 2).

  A listener is a TEventListener object (the script bindings make one per
  JavaScript callback); the target's listener list owns the listeners
  added to it. Dispatch builds the event path through GetTheParent
  (nodes: their parent; the window comes later), then runs the capture
  listeners from the top down to the target, the target's capture and
  then other listeners, and, for bubbling events, the bubble listeners
  back up. stopPropagation, stopImmediatePropagation, preventDefault,
  once and passive listeners, and listeners added or removed while an
  event is dispatched behave as the standard says. Shadow trees (and so
  retargeting and composed) and activation behavior come later.

  Targets are kept alive while an event refers to them through the
  virtual RetainTarget/ReleaseTarget (nodes: Retain/Release).
}
unit Web.Dom.Events;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Atoms;

type
  TEventTarget = class;
  TEvent = class;

  TEventPhase = (EventPhaseNone, EventPhaseCapturing, EventPhaseAtTarget, EventPhaseBubbling);

  TEventListener = class
  public
    procedure HandleEvent(Event: TEvent); virtual; abstract;
    { Whether two listener objects stand for the same callback (the
      bindings compare the JavaScript functions); identity by default. }
    function IsSameCallback(Other: TEventListener): Boolean; virtual;
  end;

  TEventListenerOptions = record
    Capture: Boolean;
    Once: Boolean;
    Passive: Boolean;
  end;

  TListenerEntry = class
  public
    EventType: TAtom;
    Callback: TEventListener;
    Capture: Boolean;
    Once: Boolean;
    Passive: Boolean;
    Removed: Boolean;
  end;

  TListenerEntryArray = array of TListenerEntry;

  TEventListenerList = class
  private
    FEntries: TListenerEntryArray;
    FCount: Integer;
    FDispatchDepth: Integer;
    FHasRemovedEntries: Boolean;
    procedure Purge;
    function IsCallbackUsed(Callback: TEventListener; const Entries: TListenerEntryArray; Count: Integer): Boolean;
  public
    destructor Destroy; override;
    { Adds a listener; the list owns Callback from then on (a duplicate
      is freed at once). False for a duplicate. One callback object may
      serve several entries (other types, capture); it is freed once. }
    function Add(EventType: TAtom; Callback: TEventListener; const Options: TEventListenerOptions): Boolean;
    function Remove(EventType: TAtom; Callback: TEventListener; Capture: Boolean): Boolean;
    function HasListenersFor(EventType: TAtom): Boolean;
    { The entry at Index (0 based, below Count). }
    function EntryAt(Index: Integer): TListenerEntry; inline;
    property Count: Integer read FCount;
  end;

  TEventTargetArray = array of TEventTarget;

  TEvent = class
  private
    FEventType: TAtom;
    FTarget: TEventTarget;
    FCurrentTarget: TEventTarget;
    FRelatedTarget: TEventTarget;
    FPhase: TEventPhase;
    FBubbles: Boolean;
    FCancelable: Boolean;
    FComposed: Boolean;
    FIsTrusted: Boolean;
    FStopPropagation: Boolean;
    FStopImmediatePropagation: Boolean;
    FCanceled: Boolean;
    FInPassiveListener: Boolean;
    FDispatching: Boolean;
    FInitialized: Boolean;
    FTimeStamp: Double;
    FPath: TEventTargetArray;
    FReferenceCount: Integer;
    FScriptWrapper: Pointer;
    procedure SetTarget(NewTarget: TEventTarget);
    procedure SetRelatedTarget(NewTarget: TEventTarget);
    function GetEventTypeName: string;
    function GetCancelBubble: Boolean;
    procedure SetCancelBubble(Value: Boolean);
    function GetReturnValue: Boolean;
    procedure SetReturnValue(Value: Boolean);
  public
    constructor Create(const TypeName: string; CanBubble: Boolean = False; IsCancelable: Boolean = False);
    destructor Destroy; override;
    { References: the creator holds the first; Release frees the event at
      the last (the script bindings hold one per wrapper). Free still
      works for an event nothing else holds. }
    procedure Retain;
    procedure Release;
    procedure StopPropagation;
    procedure StopImmediatePropagation;
    procedure PreventDefault;
    { The legacy initEvent: ignored while the event is dispatched. }
    procedure InitEvent(const TypeName: string; CanBubble, IsCancelable: Boolean);
    { The path of the event while it is dispatched; empty otherwise. }
    function ComposedPath: TEventTargetArray;
    property EventType: TAtom read FEventType;
    property TypeName: string read GetEventTypeName;
    property Target: TEventTarget read FTarget;
    property CurrentTarget: TEventTarget read FCurrentTarget;
    property RelatedTarget: TEventTarget read FRelatedTarget write SetRelatedTarget;
    property EventPhase: TEventPhase read FPhase;
    property Bubbles: Boolean read FBubbles;
    property Cancelable: Boolean read FCancelable;
    property Composed: Boolean read FComposed write FComposed;
    property IsTrusted: Boolean read FIsTrusted write FIsTrusted;
    property DefaultPrevented: Boolean read FCanceled;
    property CancelBubble: Boolean read GetCancelBubble write SetCancelBubble;
    property ReturnValue: Boolean read GetReturnValue write SetReturnValue;
    property TimeStamp: Double read FTimeStamp write FTimeStamp;
    property IsDispatching: Boolean read FDispatching;
    { The script binding's wrapper (EventDestroyedHook tells it when the
      event goes). }
    property ScriptWrapper: Pointer read FScriptWrapper write FScriptWrapper;
  end;

  TEventTarget = class
  protected
    { The target's listeners, made on first use when CreateIfMissing. }
    function GetListenerList(CreateIfMissing: Boolean): TEventListenerList; virtual;
    { The standard's "get the parent". }
    function GetTheParent(Event: TEvent): TEventTarget; virtual;
    { An exception a listener raised (the bindings report it). }
    procedure ReportListenerException(Error: Exception); virtual;
  public
    procedure RetainTarget; virtual;
    procedure ReleaseTarget; virtual;
    function AddEventListener(const TypeName: string; Callback: TEventListener;
      const Options: TEventListenerOptions): Boolean; overload;
    function AddEventListener(const TypeName: string; Callback: TEventListener;
      UseCapture: Boolean = False): Boolean; overload;
    function RemoveEventListener(const TypeName: string; Callback: TEventListener;
      UseCapture: Boolean = False): Boolean;
    function HasEventListeners(const TypeName: string): Boolean;
    { The target's listener list (for the script bindings). }
    function ListenerList(CreateIfMissing: Boolean = False): TEventListenerList;
    { Dispatches an event: False if a listener canceled it. }
    function DispatchEvent(Event: TEvent): Boolean;
  end;

var
  { How many listener calls ended in an exception (for tests). }
  ListenerExceptionCount: Integer = 0;
  { Called when an event with a script wrapper is freed. }
  EventDestroyedHook: procedure(Event: TEvent) = nil;

implementation

uses
  Web.Dom.Exceptions;

function TEventListener.IsSameCallback(Other: TEventListener): Boolean;
begin
  Result := Other = Self;
end;

function TEventListenerList.IsCallbackUsed(Callback: TEventListener; const Entries: TListenerEntryArray;
  Count: Integer): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Count do
    if Entries[Index - 1].Callback = Callback then
      Exit(True);
  Result := False;
end;

destructor TEventListenerList.Destroy;
var
  Index: Integer;
begin
  { Each callback once: the first entry that has it frees it. }
  for Index := 1 to FCount do
    if not IsCallbackUsed(FEntries[Index - 1].Callback, FEntries, Index - 1) then
      FEntries[Index - 1].Callback.Free;
  for Index := 1 to FCount do
    FEntries[Index - 1].Free;
  inherited Destroy;
end;

function TEventListenerList.Add(EventType: TAtom; Callback: TEventListener;
  const Options: TEventListenerOptions): Boolean;
var
  Index: Integer;
  Entry: TListenerEntry;
begin
  for Index := 1 to FCount do
  begin
    Entry := FEntries[Index - 1];
    if not Entry.Removed and (Entry.EventType = EventType) and (Entry.Capture = Options.Capture) and
      Entry.Callback.IsSameCallback(Callback) then
    begin
      if not IsCallbackUsed(Callback, FEntries, FCount) then
        Callback.Free;
      Exit(False);
    end;
  end;
  Entry := TListenerEntry.Create;
  Entry.EventType := EventType;
  Entry.Callback := Callback;
  Entry.Capture := Options.Capture;
  Entry.Once := Options.Once;
  Entry.Passive := Options.Passive;
  if FCount >= Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 2);
  FEntries[FCount] := Entry;
  Inc(FCount);
  Result := True;
end;

function TEventListenerList.Remove(EventType: TAtom; Callback: TEventListener; Capture: Boolean): Boolean;
var
  Index: Integer;
  Entry: TListenerEntry;
begin
  for Index := 1 to FCount do
  begin
    Entry := FEntries[Index - 1];
    if not Entry.Removed and (Entry.EventType = EventType) and (Entry.Capture = Capture) and
      Entry.Callback.IsSameCallback(Callback) then
    begin
      Entry.Removed := True;
      FHasRemovedEntries := True;
      if FDispatchDepth = 0 then
        Purge;
      Exit(True);
    end;
  end;
  Result := False;
end;

procedure TEventListenerList.Purge;
var
  Source, Destination, RemovedCount, Index: Integer;
  Removed: TListenerEntryArray;
begin
  Removed := nil;
  SetLength(Removed, FCount);
  RemovedCount := 0;
  Destination := 0;
  for Source := 1 to FCount do
    if FEntries[Source - 1].Removed then
    begin
      Removed[RemovedCount] := FEntries[Source - 1];
      Inc(RemovedCount);
    end
    else
    begin
      FEntries[Destination] := FEntries[Source - 1];
      Inc(Destination);
    end;
  FCount := Destination;
  FHasRemovedEntries := False;
  { A callback goes when no remaining entry has it, once. }
  for Index := 1 to RemovedCount do
    if not IsCallbackUsed(Removed[Index - 1].Callback, FEntries, FCount) and
      not IsCallbackUsed(Removed[Index - 1].Callback, Removed, Index - 1) then
      Removed[Index - 1].Callback.Free;
  for Index := 1 to RemovedCount do
    Removed[Index - 1].Free;
end;

function TEventListenerList.EntryAt(Index: Integer): TListenerEntry;
begin
  Result := FEntries[Index];
end;

function TEventListenerList.HasListenersFor(EventType: TAtom): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to FCount do
    if not FEntries[Index - 1].Removed and (FEntries[Index - 1].EventType = EventType) then
      Exit(True);
  Result := False;
end;

constructor TEvent.Create(const TypeName: string; CanBubble: Boolean; IsCancelable: Boolean);
begin
  inherited Create;
  FEventType := Atomize(TypeName);
  FBubbles := CanBubble;
  FCancelable := IsCancelable;
  FInitialized := True;
  FReferenceCount := 1;
end;

destructor TEvent.Destroy;
begin
  if (FScriptWrapper <> nil) and Assigned(EventDestroyedHook) then
    EventDestroyedHook(Self);
  SetTarget(nil);
  SetRelatedTarget(nil);
  inherited Destroy;
end;

procedure TEvent.Retain;
begin
  Inc(FReferenceCount);
end;

procedure TEvent.Release;
begin
  Dec(FReferenceCount);
  if FReferenceCount <= 0 then
    Free;
end;

procedure TEvent.SetTarget(NewTarget: TEventTarget);
begin
  if NewTarget = FTarget then
    Exit;
  if NewTarget <> nil then
    NewTarget.RetainTarget;
  if FTarget <> nil then
    FTarget.ReleaseTarget;
  FTarget := NewTarget;
end;

procedure TEvent.SetRelatedTarget(NewTarget: TEventTarget);
begin
  if NewTarget = FRelatedTarget then
    Exit;
  if NewTarget <> nil then
    NewTarget.RetainTarget;
  if FRelatedTarget <> nil then
    FRelatedTarget.ReleaseTarget;
  FRelatedTarget := NewTarget;
end;

function TEvent.GetEventTypeName: string;
begin
  Result := NameOfAtom(FEventType);
end;

procedure TEvent.StopPropagation;
begin
  FStopPropagation := True;
end;

procedure TEvent.StopImmediatePropagation;
begin
  FStopPropagation := True;
  FStopImmediatePropagation := True;
end;

procedure TEvent.PreventDefault;
begin
  if FCancelable and not FInPassiveListener then
    FCanceled := True;
end;

function TEvent.GetCancelBubble: Boolean;
begin
  Result := FStopPropagation;
end;

procedure TEvent.SetCancelBubble(Value: Boolean);
begin
  if Value then
    FStopPropagation := True;
end;

function TEvent.GetReturnValue: Boolean;
begin
  Result := not FCanceled;
end;

procedure TEvent.SetReturnValue(Value: Boolean);
begin
  if not Value then
    PreventDefault;
end;

procedure TEvent.InitEvent(const TypeName: string; CanBubble, IsCancelable: Boolean);
begin
  if FDispatching then
    Exit;
  FInitialized := True;
  FStopPropagation := False;
  FStopImmediatePropagation := False;
  FCanceled := False;
  FIsTrusted := False;
  SetTarget(nil);
  FEventType := Atomize(TypeName);
  FBubbles := CanBubble;
  FCancelable := IsCancelable;
end;

function TEvent.ComposedPath: TEventTargetArray;
begin
  Result := Copy(FPath);
end;

function TEventTarget.GetListenerList(CreateIfMissing: Boolean): TEventListenerList;
begin
  Result := nil;
end;

function TEventTarget.GetTheParent(Event: TEvent): TEventTarget;
begin
  Result := nil;
end;

procedure TEventTarget.ReportListenerException(Error: Exception);
begin
end;

procedure TEventTarget.RetainTarget;
begin
end;

procedure TEventTarget.ReleaseTarget;
begin
end;

function TEventTarget.AddEventListener(const TypeName: string; Callback: TEventListener;
  const Options: TEventListenerOptions): Boolean;
var
  List: TEventListenerList;
begin
  if Callback = nil then
    Exit(False);
  List := GetListenerList(True);
  if List = nil then
  begin
    Callback.Free;
    Exit(False);
  end;
  Result := List.Add(Atomize(TypeName), Callback, Options);
end;

function TEventTarget.AddEventListener(const TypeName: string; Callback: TEventListener;
  UseCapture: Boolean): Boolean;
var
  Options: TEventListenerOptions;
begin
  Options.Capture := UseCapture;
  Options.Once := False;
  Options.Passive := False;
  Result := AddEventListener(TypeName, Callback, Options);
end;

function TEventTarget.RemoveEventListener(const TypeName: string; Callback: TEventListener;
  UseCapture: Boolean): Boolean;
var
  List: TEventListenerList;
begin
  List := GetListenerList(False);
  if (List = nil) or (Callback = nil) then
    Exit(False);
  Result := List.Remove(Atomize(TypeName), Callback, UseCapture);
end;

function TEventTarget.ListenerList(CreateIfMissing: Boolean): TEventListenerList;
begin
  Result := GetListenerList(CreateIfMissing);
end;

function TEventTarget.HasEventListeners(const TypeName: string): Boolean;
var
  List: TEventListenerList;
begin
  List := GetListenerList(False);
  Result := (List <> nil) and List.HasListenersFor(FindAtom(TypeName));
end;

type
  TListenerPhase = (ListenerPhaseCapturing, ListenerPhaseBubbling);

{ The standard's "inner invoke" over a clone of the target's listeners. }
procedure InvokeListeners(Target: TEventTarget; Event: TEvent; Phase: TListenerPhase);
var
  List: TEventListenerList;
  Snapshot: TListenerEntryArray;
  Index, Count: Integer;
  Entry: TListenerEntry;
begin
  if Event.FStopPropagation then
    Exit;
  List := Target.GetListenerList(False);
  if (List = nil) or (List.FCount = 0) then
    Exit;
  Count := List.FCount;
  Snapshot := Copy(List.FEntries, 0, Count);
  Event.FCurrentTarget := Target;
  Inc(List.FDispatchDepth);
  try
    for Index := 1 to Count do
    begin
      Entry := Snapshot[Index - 1];
      if Entry.Removed or (Entry.EventType <> Event.FEventType) then
        Continue;
      if (Phase = ListenerPhaseCapturing) <> Entry.Capture then
        Continue;
      if Entry.Once then
      begin
        Entry.Removed := True;
        List.FHasRemovedEntries := True;
      end;
      Event.FInPassiveListener := Entry.Passive;
      try
        Entry.Callback.HandleEvent(Event);
      except
        on Error: Exception do
        begin
          Inc(ListenerExceptionCount);
          Target.ReportListenerException(Error);
        end;
      end;
      Event.FInPassiveListener := False;
      if Event.FStopImmediatePropagation then
        Break;
    end;
  finally
    Dec(List.FDispatchDepth);
    if (List.FDispatchDepth = 0) and List.FHasRemovedEntries then
      List.Purge;
  end;
end;

function TEventTarget.DispatchEvent(Event: TEvent): Boolean;
var
  Path: TEventTargetArray;
  Parent: TEventTarget;
  Count, Index: Integer;
begin
  if Event.FDispatching or not Event.FInitialized then
    RaiseDomError(InvalidStateError, 'the event is being dispatched or was not initialized');
  Event.FIsTrusted := False;
  Event.FDispatching := True;
  Event.SetTarget(Self);
  Path := nil;
  Count := 0;
  Parent := Self;
  while Parent <> nil do
  begin
    if Count >= Length(Path) then
      SetLength(Path, Count * 2 + 8);
    Path[Count] := Parent;
    Parent.RetainTarget;
    Inc(Count);
    Parent := Parent.GetTheParent(Event);
  end;
  SetLength(Path, Count);
  Event.FPath := Path;
  try
    { Capturing: from the top down; at the target its capture listeners. }
    Index := Count;
    while Index >= 1 do
    begin
      if Index = 1 then
        Event.FPhase := EventPhaseAtTarget
      else
        Event.FPhase := EventPhaseCapturing;
      InvokeListeners(Path[Index - 1], Event, ListenerPhaseCapturing);
      Dec(Index);
    end;
    { The target's other listeners, then bubbling back up. }
    for Index := 1 to Count do
    begin
      if Index = 1 then
        Event.FPhase := EventPhaseAtTarget
      else if Event.FBubbles then
        Event.FPhase := EventPhaseBubbling
      else
        Break;
      InvokeListeners(Path[Index - 1], Event, ListenerPhaseBubbling);
    end;
  finally
    Event.FPhase := EventPhaseNone;
    Event.FCurrentTarget := nil;
    Event.FPath := nil;
    Event.FDispatching := False;
    Event.FStopPropagation := False;
    Event.FStopImmediatePropagation := False;
    for Index := 1 to Count do
      Path[Index - 1].ReleaseTarget;
  end;
  Result := not Event.FCanceled;
end;

end.
