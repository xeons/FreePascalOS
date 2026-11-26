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
  event is dispatched behave as the standard says.

  Shadow trees: the path is a list of structs (DOM Standard 2.9), each
  with its invocation target, shadow-adjusted target, related target and
  the closed tree marks; listeners see the target and related target
  retargeted against their own tree, a shadow root passes an event on
  to its host only when the event is composed (or did not start in that
  tree), and composedPath() hides what is inside closed shadow trees
  from listeners outside them. The node specifics (roots, hosts,
  assigned slots) come through virtual methods of TEventTarget.

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

  { One struct of an event's path (DOM Standard 2.9, "append to an
    event path"). }
  TEventPathItem = record
    InvocationTarget: TEventTarget;
    ShadowAdjustedTarget: TEventTarget;
    RelatedTarget: TEventTarget;
    RootOfClosedTree: Boolean;
    SlotInClosedTree: Boolean;
  end;
  TEventPathItemArray = array of TEventPathItem;

  TEvent = class
  private
    FEventType: TAtom;
    FTarget: TEventTarget;
    FTargetHeld: Boolean;
    FCurrentTarget: TEventTarget;
    FRelatedTarget: TEventTarget;
    FRelatedTargetHeld: Boolean;
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
    FPath: TEventPathItemArray;
    FPathCount: Integer;
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
      the last (the script bindings hold one per wrapper). Native code
      always releases an event it dispatched, never frees it: a listener
      may have made a wrapper that outlives the dispatch. }
    procedure Retain;
    procedure Release;
    procedure StopPropagation;
    procedure StopImmediatePropagation;
    procedure PreventDefault;
    { The legacy initEvent: ignored while the event is dispatched. }
    procedure InitEvent(const TypeName: string; CanBubble, IsCancelable: Boolean);
    { composedPath(): the path as the current target may see it (closed
      shadow trees it is outside of left out) while the event is
      dispatched; empty otherwise. }
    function ComposedPath: TEventTargetArray;
    { The invocation target of the path's first struct while the event
      is dispatched (a shadow root's "get the parent"), else nil. }
    function FirstPathTarget: TEventTarget;
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
    { What dispatch needs to know of nodes (Web.Dom overrides these):
      whether the target is a node; its root; if it is a shadow root,
      its host (nil otherwise) and whether it is closed; whether it is a
      shadow-including inclusive ancestor of Other; the slot it is
      assigned to (slottables), nil if none. }
    function IsNodeTarget: Boolean; virtual;
    function TargetRoot: TEventTarget; virtual;
    function ShadowHostTarget: TEventTarget; virtual;
    function IsClosedShadowRoot: Boolean; virtual;
    function IsShadowIncludingInclusiveAncestorOf(Other: TEventTarget): Boolean; virtual;
    function AssignedSlotTarget: TEventTarget; virtual;
    procedure RetainTarget; virtual;
    procedure ReleaseTarget; virtual;
    { Whether events hold the target (RetainTarget and ReleaseTarget):
      nodes. Other targets (the window, XMLHttpRequest, AbortSignal ...)
      belong to their wrappers, which the event's wrapper keeps alive;
      an event never calls them back, since it may go after them when a
      heap is freed whole. }
    function HeldByEvents: Boolean; virtual;
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
var
  Held: Boolean;
begin
  if NewTarget = FTarget then
    Exit;
  Held := (NewTarget <> nil) and NewTarget.HeldByEvents;
  if Held then
    NewTarget.RetainTarget;
  if FTargetHeld then
    FTarget.ReleaseTarget;
  FTarget := NewTarget;
  FTargetHeld := Held;
end;

procedure TEvent.SetRelatedTarget(NewTarget: TEventTarget);
var
  Held: Boolean;
begin
  if NewTarget = FRelatedTarget then
    Exit;
  Held := (NewTarget <> nil) and NewTarget.HeldByEvents;
  if Held then
    NewTarget.RetainTarget;
  if FRelatedTargetHeld then
    FRelatedTarget.ReleaseTarget;
  FRelatedTarget := NewTarget;
  FRelatedTargetHeld := Held;
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

function TEvent.FirstPathTarget: TEventTarget;
begin
  if FPathCount = 0 then
    Result := nil
  else
    Result := FPath[0].InvocationTarget;
end;

{ DOM Standard: composedPath(). }
function TEvent.ComposedPath: TEventTargetArray;
var
  Count, CurrentTargetIndex, CurrentTargetHiddenLevel, CurrentHiddenLevel, MaxHiddenLevel, Index: Integer;
  Before: TEventTargetArray;
  BeforeCount: Integer;
begin
  Result := nil;
  if (FPathCount = 0) or (FCurrentTarget = nil) then
    Exit;
  CurrentTargetIndex := 0;
  CurrentTargetHiddenLevel := 0;
  Index := FPathCount - 1;
  while Index >= 0 do
  begin
    if FPath[Index].RootOfClosedTree then
      Inc(CurrentTargetHiddenLevel);
    if FPath[Index].InvocationTarget = FCurrentTarget then
    begin
      CurrentTargetIndex := Index;
      Break;
    end;
    if FPath[Index].SlotInClosedTree then
      Dec(CurrentTargetHiddenLevel);
    Dec(Index);
  end;
  { The current target and the structs before it, nearest first. }
  Before := nil;
  SetLength(Before, FPathCount);
  BeforeCount := 1;
  Before[0] := FCurrentTarget;
  CurrentHiddenLevel := CurrentTargetHiddenLevel;
  MaxHiddenLevel := CurrentTargetHiddenLevel;
  Index := CurrentTargetIndex - 1;
  while Index >= 0 do
  begin
    if FPath[Index].RootOfClosedTree then
      Inc(CurrentHiddenLevel);
    if CurrentHiddenLevel <= MaxHiddenLevel then
    begin
      Before[BeforeCount] := FPath[Index].InvocationTarget;
      Inc(BeforeCount);
    end;
    if FPath[Index].SlotInClosedTree then
    begin
      Dec(CurrentHiddenLevel);
      if CurrentHiddenLevel < MaxHiddenLevel then
        MaxHiddenLevel := CurrentHiddenLevel;
    end;
    Dec(Index);
  end;
  SetLength(Result, FPathCount);
  Count := 0;
  for Index := BeforeCount - 1 downto 0 do
  begin
    Result[Count] := Before[Index];
    Inc(Count);
  end;
  { The structs after the current target. }
  CurrentHiddenLevel := CurrentTargetHiddenLevel;
  MaxHiddenLevel := CurrentTargetHiddenLevel;
  Index := CurrentTargetIndex + 1;
  while Index < FPathCount do
  begin
    if FPath[Index].SlotInClosedTree then
      Inc(CurrentHiddenLevel);
    if CurrentHiddenLevel <= MaxHiddenLevel then
    begin
      Result[Count] := FPath[Index].InvocationTarget;
      Inc(Count);
    end;
    if FPath[Index].RootOfClosedTree then
    begin
      Dec(CurrentHiddenLevel);
      if CurrentHiddenLevel < MaxHiddenLevel then
        MaxHiddenLevel := CurrentHiddenLevel;
    end;
    Inc(Index);
  end;
  SetLength(Result, Count);
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

function TEventTarget.IsNodeTarget: Boolean;
begin
  Result := False;
end;

function TEventTarget.TargetRoot: TEventTarget;
begin
  Result := Self;
end;

function TEventTarget.ShadowHostTarget: TEventTarget;
begin
  Result := nil;
end;

function TEventTarget.IsClosedShadowRoot: Boolean;
begin
  Result := False;
end;

function TEventTarget.IsShadowIncludingInclusiveAncestorOf(Other: TEventTarget): Boolean;
begin
  Result := Other = Self;
end;

function TEventTarget.AssignedSlotTarget: TEventTarget;
begin
  Result := nil;
end;

procedure TEventTarget.RetainTarget;
begin
end;

procedure TEventTarget.ReleaseTarget;
begin
end;

function TEventTarget.HeldByEvents: Boolean;
begin
  Result := False;
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

{ DOM Standard: retarget A against B. }
function Retarget(A, B: TEventTarget): TEventTarget;
var
  Root: TEventTarget;
begin
  Result := A;
  while (Result <> nil) and Result.IsNodeTarget do
  begin
    Root := Result.TargetRoot;
    if (Root.ShadowHostTarget = nil) or ((B <> nil) and Root.IsShadowIncludingInclusiveAncestorOf(B)) then
      Exit;
    Result := Root.ShadowHostTarget;
  end;
end;

function IsShadowTreeNode(Target: TEventTarget): Boolean;
begin
  Result := (Target <> nil) and Target.IsNodeTarget and (Target.TargetRoot.ShadowHostTarget <> nil);
end;

{ "Append to an event path"; the path holds its targets. }
procedure AppendToEventPath(Event: TEvent; InvocationTarget, ShadowAdjustedTarget, RelatedTarget: TEventTarget;
  SlotInClosedTree: Boolean);
var
  Item: ^TEventPathItem;
begin
  if Event.FPathCount >= Length(Event.FPath) then
    SetLength(Event.FPath, Event.FPathCount * 2 + 8);
  Item := @Event.FPath[Event.FPathCount];
  Item^.InvocationTarget := InvocationTarget;
  Item^.ShadowAdjustedTarget := ShadowAdjustedTarget;
  Item^.RelatedTarget := RelatedTarget;
  Item^.RootOfClosedTree := InvocationTarget.IsClosedShadowRoot;
  Item^.SlotInClosedTree := SlotInClosedTree;
  Inc(Event.FPathCount);
  if InvocationTarget.HeldByEvents then
    InvocationTarget.RetainTarget;
  if (RelatedTarget <> nil) and RelatedTarget.HeldByEvents then
    RelatedTarget.RetainTarget;
end;

{ The standard's "invoke" for the path's struct at Index: the target is
  the nearest shadow-adjusted target at or before it. }
procedure InvokePathItem(Event: TEvent; Index: Integer; Phase: TListenerPhase);
var
  TargetIndex: Integer;
begin
  TargetIndex := Index;
  while (TargetIndex > 0) and (Event.FPath[TargetIndex].ShadowAdjustedTarget = nil) do
    Dec(TargetIndex);
  Event.SetTarget(Event.FPath[TargetIndex].ShadowAdjustedTarget);
  Event.SetRelatedTarget(Event.FPath[Index].RelatedTarget);
  InvokeListeners(Event.FPath[Index].InvocationTarget, Event, Phase);
end;

{ Builds the event path from Start (DOM Standard: dispatch, step 5). }
procedure BuildEventPath(Event: TEvent; Start, OriginalRelatedTarget: TEventTarget);
var
  Parent, Target, RelatedTarget, Slottable: TEventTarget;
  SlotInClosedTree: Boolean;
begin
  Target := Start;
  RelatedTarget := Retarget(OriginalRelatedTarget, Start);
  if (Start = RelatedTarget) and (Start <> OriginalRelatedTarget) then
    Exit;
  AppendToEventPath(Event, Start, Start, RelatedTarget, False);
  Slottable := nil;
  if Start.AssignedSlotTarget <> nil then
    Slottable := Start;
  SlotInClosedTree := False;
  Parent := Start.GetTheParent(Event);
  while Parent <> nil do
  begin
    if Slottable <> nil then
    begin
      Slottable := nil;
      if Parent.TargetRoot.IsClosedShadowRoot then
        SlotInClosedTree := True;
    end;
    if Parent.AssignedSlotTarget <> nil then
      Slottable := Parent;
    RelatedTarget := Retarget(OriginalRelatedTarget, Parent);
    if not Parent.IsNodeTarget or (Target.IsNodeTarget and
      Target.TargetRoot.IsShadowIncludingInclusiveAncestorOf(Parent)) then
      AppendToEventPath(Event, Parent, nil, RelatedTarget, SlotInClosedTree)
    else if Parent = RelatedTarget then
      Parent := nil
    else
    begin
      Target := Parent;
      AppendToEventPath(Event, Parent, Target, RelatedTarget, SlotInClosedTree);
    end;
    if Parent <> nil then
      Parent := Parent.GetTheParent(Event);
    SlotInClosedTree := False;
  end;
end;

function TEventTarget.DispatchEvent(Event: TEvent): Boolean;
var
  OriginalRelatedTarget, FinalTarget, FinalRelatedTarget: TEventTarget;
  ClearTargets: Boolean;
  Index, ClearIndex: Integer;
begin
  if Event.FDispatching or not Event.FInitialized then
    RaiseDomError(InvalidStateError, 'the event is being dispatched or was not initialized');
  Event.FDispatching := True;
  Event.FPath := nil;
  Event.FPathCount := 0;
  OriginalRelatedTarget := Event.FRelatedTarget;
  if (OriginalRelatedTarget <> nil) and OriginalRelatedTarget.HeldByEvents then
    OriginalRelatedTarget.RetainTarget;
  Event.SetTarget(Self);
  ClearTargets := False;
  try
    BuildEventPath(Event, Self, OriginalRelatedTarget);
    if Event.FPathCount > 0 then
    begin
      { Targets that would show a shadow tree are cleared afterwards. }
      ClearIndex := Event.FPathCount - 1;
      while (ClearIndex > 0) and (Event.FPath[ClearIndex].ShadowAdjustedTarget = nil) do
        Dec(ClearIndex);
      ClearTargets := IsShadowTreeNode(Event.FPath[ClearIndex].ShadowAdjustedTarget) or
        IsShadowTreeNode(Event.FPath[ClearIndex].RelatedTarget);
      { Capturing, from the top down (at a target: its capture listeners). }
      for Index := Event.FPathCount - 1 downto 0 do
      begin
        if Event.FPath[Index].ShadowAdjustedTarget <> nil then
          Event.FPhase := EventPhaseAtTarget
        else
          Event.FPhase := EventPhaseCapturing;
        InvokePathItem(Event, Index, ListenerPhaseCapturing);
      end;
      { The targets' other listeners, and bubbling back up. }
      for Index := 0 to Event.FPathCount - 1 do
      begin
        if Event.FPath[Index].ShadowAdjustedTarget <> nil then
          Event.FPhase := EventPhaseAtTarget
        else if Event.FBubbles then
          Event.FPhase := EventPhaseBubbling
        else
          Continue;
        InvokePathItem(Event, Index, ListenerPhaseBubbling);
      end;
    end;
  finally
    Event.FPhase := EventPhaseNone;
    Event.FCurrentTarget := nil;
    Event.FDispatching := False;
    Event.FStopPropagation := False;
    Event.FStopImmediatePropagation := False;
    { After dispatch the target is the one the outermost listeners saw. }
    FinalTarget := Self;
    FinalRelatedTarget := OriginalRelatedTarget;
    for Index := 0 to Event.FPathCount - 1 do
      if (Event.FPath[Index].ShadowAdjustedTarget <> nil) or Event.FBubbles then
      begin
        if Event.FPath[Index].ShadowAdjustedTarget <> nil then
          FinalTarget := Event.FPath[Index].ShadowAdjustedTarget;
        FinalRelatedTarget := Event.FPath[Index].RelatedTarget;
      end;
    if ClearTargets then
    begin
      Event.SetTarget(nil);
      Event.SetRelatedTarget(nil);
    end
    else
    begin
      Event.SetTarget(FinalTarget);
      Event.SetRelatedTarget(FinalRelatedTarget);
    end;
    for Index := 0 to Event.FPathCount - 1 do
    begin
      if Event.FPath[Index].InvocationTarget.HeldByEvents then
        Event.FPath[Index].InvocationTarget.ReleaseTarget;
      if (Event.FPath[Index].RelatedTarget <> nil) and Event.FPath[Index].RelatedTarget.HeldByEvents then
        Event.FPath[Index].RelatedTarget.ReleaseTarget;
    end;
    Event.FPath := nil;
    Event.FPathCount := 0;
    if (OriginalRelatedTarget <> nil) and OriginalRelatedTarget.HeldByEvents then
      OriginalRelatedTarget.ReleaseTarget;
  end;
  Result := not Event.FCanceled;
end;

end.
