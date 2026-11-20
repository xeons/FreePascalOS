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
  The binding context: one JavaScript engine (one realm) and the window
  and document it scripts, the wrappers of native objects, and the
  conversions every implementation routine shares.

  Wrappers
  --------
  A wrapper is a TBindingWrapper (a libjavascript host object) whose
  NativeData is the native object. Its interface is found through its
  host class (TBindingClass, the data of the host class's tracer).
  How the native object lives depends on its kind:

  - Nodes: one wrapper per node, made the first time script sees the
    node and kept in the node's ScriptWrapper slot. The wrapper holds a
    reference to the node (Retain/Release), so the node lives at least as
    long as its wrapper.
  - Events: the same with TEvent's reference count and slot.
  - Objects a node owns (childNodes, children, classList, attributes):
    the wrapper's Owner is the node's wrapper, which keeps the node and
    thereby the object alive; [SameObject] caches keep their identity.
  - Objects of their own (a static NodeList, a URL, a TextDecoder): the
    wrapper owns and frees them.

  Wrapper lifetime and the node tree
  ----------------------------------
  The node's slot does not keep the wrapper alive (the collector cannot
  see it), and nodes keep wrappers alive only through groups: a node's
  group is the root of its tree (the document for a connected node, the
  root of a detached subtree; an Attr belongs to its element's group, a
  template's contents to the template's). While the collector marks, a
  weak processor (MarkLiveGroups) finds the groups that have a marked
  wrapper and marks every other wrapper of those groups, repeating until
  nothing more is marked. The window's document wrapper is a root, so
  every wrapper of a connected node lives, with its expando properties,
  event listeners and handlers, as long as its node stays in the
  document; and script never sees two wrappers for one node.

  Cycles are fine: a detached subtree whose wrappers only refer to each
  other (expandos, listeners closing over nodes) has no marked wrapper
  from outside, so the whole group dies in one collection. The wrappers'
  destructors release their nodes; the DOM's CollectGarbage (between
  tasks) frees the unreferenced detached subtrees. A wrapper that dies
  disables its node's script listeners (nothing can reach them), so the
  DOM never calls a dead JavaScript function.

  The JavaScript side of listeners (TScriptEventListener) and event
  handlers is marked by the wrapper of their target (Trace); the
  window's by the context's root provider.
}
unit Web.Bindings.Context;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  fgl,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Interpreter,
  Js.Engine,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Events,
  Web.Dom.Exceptions,
  Web.Dom,
  Web.Dom.UiEvents,
  Web.Bindings.Types,
  Web.Bindings.Strings,
  Web.Bindings.Listeners,
  Web.ScriptEnvironment;

const
  { TBindingWrapper.WrapperFlags }
  WrapperOwnsNative = 1;
  WrapperIsNode = 2;
  WrapperIsEvent = 4;

type
  TBindingContext = class;

  { A DOMException's native object. }
  TDomExceptionData = class
  public
    Name: string;
    Message: string;
  end;

  { One per interface and context: the host class's tracer data. }
  TBindingClass = class
  public
    Context: TBindingContext;
    InterfaceId: Integer;
    HostClass: TJsHostClass;
    Flags: Word;
    CacheSlotCount: Integer;
    procedure TraceNative(HostClass_: TJsHostClass; NativeData: Pointer; Tracer: TJsTracer);
  end;

  TBindingWrapper = class(TJsHostObject)
  public
    RegistryIndex: Integer;
    WrapperFlags: Byte;
    { [SameObject] values and event handlers (slot 0). }
    Cache: TJsValueList;
    { The wrapper whose native object owns this one's. }
    Owner: TJsValue;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    function Binding: TBindingClass; inline;
    function CachedValue(Slot: Integer): TJsValue;
    procedure SetCachedValue(Slot: Integer; Value: TJsValue);
  end;

  TBindingWrapperClass = class of TBindingWrapper;
  TBindingWrapperArray = array of TBindingWrapper;

  { Makes an interface's objects (Web.Bindings.Install does it the first
    time an interface is needed). }
  TInterfaceInstaller = procedure(Context: TBindingContext; InterfaceId: Integer);

  { The state of a form control that is not in its attributes (HTML
    Standard 4.10.17): value and checkedness with their dirty flags,
    selectedness of options, indeterminate, the custom validity message. }
  TFormControlState = class
  public
    Value: string;
    ValueDirty: Boolean;
    Checked: Boolean;
    CheckedDirty: Boolean;
    Selected: Boolean;
    SelectedDirty: Boolean;
    Indeterminate: Boolean;
    CustomValidity: string;
  end;

  { Objects a window has one of. }
  TWindowSingleton = (SingletonLocation, SingletonNavigator, SingletonHistory, SingletonHistoryState,
    SingletonScrollRestoration, SingletonWindowName, SingletonStructuredClone);

  { Where console messages go (Level: 'log', 'error'). }
  TConsoleMessageEvent = procedure(const Level, Text: string) of object;

  TFormStateMap = specialize TFPGMap<Pointer, TFormControlState>;

  TBindingContext = class(TBindingListenerOwner)
  private
    FEngine: TJsEngine;
    FDocument: TDocument;
    FWindow: TEventTarget;
    FOwnsWindow: Boolean;
    FEnvironment: TScriptEnvironment;
    FOwnsEnvironment: Boolean;
    FNodeWrappers: TBindingWrapperArray;
    FNodeWrapperCount: Integer;
    FEventWrappers: TBindingWrapperArray;
    FEventWrapperCount: Integer;
    FGroupRoots: array of TNode;
    FGroupRootsValid: Boolean;
    FLiveGroups: array of TNode;
    FLiveGroupCount: Integer;
    FCallDepth: Integer;
    FOnConsoleMessage: TConsoleMessageEvent;
    FDestroying: Boolean;
    FWindowHandlers: TJsValue;
    FCheckpointRunning: Boolean;
    FTimeOrigin: QWord;
    FSingletons: array[TWindowSingleton] of TJsValue;
    FCurrentScript: TElement;
    FFormStates: TFormStateMap;
    FParentContext: TBindingContext;
    FFrameElement: TElement;
    FChildFrames: array of TBindingContext;
    FClosed: Boolean;
    procedure FreeChildFrames;
    procedure MarkRoots(Tracer: TJsTracer);
    function MarkLiveGroups(Tracer: TJsTracer; Phase: Integer): Boolean;
    function GroupIsLive(Root: TNode): Boolean;
    procedure AddLiveGroup(Root: TNode);
    procedure RegisterWrapper(var List: TBindingWrapperArray; var Count: Integer; Wrapper: TBindingWrapper);
    procedure UnregisterWrapper(var List: TBindingWrapperArray; var Count: Integer; Wrapper: TBindingWrapper);
    procedure WriteConsole(const Text: string; IsError: Boolean);
    procedure FreeFormStates;
    function NewWrapper(WrapperClass: TBindingWrapperClass; Native: TObject; InterfaceId: Integer;
      Owned: Boolean; Prototype: TJsObject): TJsValue;
  protected
    FDocumentObserver: TDocumentObserver;
    { A node wrapper was made (the script context adds its observer). }
    procedure NodeWrapped(Node: TNode); virtual;
    { The wrapper of Node is going: its node keeps no script state. }
    procedure NodeWrapperDying(Node: TNode); virtual;
  public
    { Filled by the installer (Web.Bindings.Install): per interface its
      class and parent, the interface of each HTML element name by atom,
      and the wrapper class of legacy platform objects. }
    InterfaceClasses: array of TBindingClass;
    InterfaceParents: array of SmallInt;
    ElementInterfaces: array of SmallInt;
    IndexedWrapperClass: TBindingWrapperClass;
    InterfaceInstaller: TInterfaceInstaller;
    { The accessor functions of event handler attributes by name, shared
      by the interfaces that have them (the installer's); the prototypes
      keep them alive. }
    EventHandlerAccessors: TStringList;
    { The mutation observers' state (Web.Bindings.MutationObservers),
      freed after the engine. }
    MutationObservers: TObject;
    { The window's timers (Web.Script.Timers), freed after the engine. }
    Timers: TObject;
    { AWindow: the window event target the loader made (the navigable's
      TWebWindow, whose load event and timers it drives); nil makes one
      of the context's own. }
    constructor Create(ADocument: TDocument; AEnvironment: TScriptEnvironment; AWindow: TEventTarget = nil);
    { The window of a nested navigable (an iframe's): a realm in Parent's
      engine, so objects pass between the two. Parent frees it (after its
      engine). }
    constructor CreateFrame(ADocument: TDocument; AEnvironment: TScriptEnvironment; Parent: TBindingContext;
      AFrameElement: TElement);
    destructor Destroy; override;

    { Nested navigables (iframes) }
    { The window of a frame element's content, nil if none (or closed). }
    function FrameOf(Element: TElement): TBindingContext;
    { The live child windows in the order their elements were inserted. }
    function FrameCount: Integer;
    function FrameAt(Index: Integer): TBindingContext;
    { The frame element went from the document: its window closes (no
      longer reachable as contentWindow; its realm stops being a root). }
    procedure Close;
    { The top-level window's context. }
    function TopContext: TBindingContext;
    property ParentContext: TBindingContext read FParentContext;
    property FrameElement: TElement read FFrameElement;
    property Closed: Boolean read FClosed;

    { Interfaces }
    function IsInterface(InterfaceId, Ancestor: Integer): Boolean;
    { The interface's class, its objects made if they were not yet. }
    function EnsureInterface(InterfaceId: Integer): TBindingClass;
    function InterfaceForNode(Node: TNode): Integer;
    function HostClassOf(InterfaceId: Integer): TJsHostClass;
    function PrototypeOf(InterfaceId: Integer): TJsObject;

    { Wrappers }
    function WrapNode(Node: TNode): TJsValue;
    function WrapEvent(Event: TEvent): TJsValue;
    { A wrapper of an object: Owned (freed with the wrapper), or kept
      alive by OwnerWrapper. }
    function WrapObject(Native: TObject; InterfaceId: Integer; Owned: Boolean;
      OwnerWrapper: TJsValue): TJsValue;
    { A wrapper of a class of its own (an exotic object). }
    function WrapObjectAs(WrapperClass: TBindingWrapperClass; Native: TObject; InterfaceId: Integer;
      Owned: Boolean; OwnerWrapper: TJsValue): TJsValue;
    { A wrapper with an explicit prototype (constructors called through
      a subclass). }
    function WrapObjectWithPrototype(Native: TObject; InterfaceId: Integer; Owned: Boolean;
      Prototype: TJsObject): TJsValue;
    { An event target's wrapper: a node's, the window's (the global),
      a standalone target's. }
    function WrapTarget(Target: TEventTarget): TJsValue;
    { Value's native object when it is a wrapper of InterfaceId (or of a
      descendant), else nil. The global object is the window. }
    function Unwrap(Value: TJsValue; InterfaceId: Integer): TObject;
    function WrapperOf(Value: TJsValue): TBindingWrapper;
    function NodeWrapperCount: Integer;
    { The prototype a constructor called with NewTarget gives (a
      subclass's), else the interface's. }
    function PrototypeForConstruct(const Call: TBindingCall): TJsObject;
    { The wrapper a constructor returns for a new native object (owned). }
    function ConstructedObject(const Call: TBindingCall; Native: TObject): TJsValue;
    { The same for a new event: the wrapper takes the creator's reference. }
    function ConstructedEvent(const Call: TBindingCall; Event: TEvent): TJsValue;
    { Gives a node made by a constructor the prototype of a subclass's
      new.target. }
    procedure AdjustConstructedPrototype(Value: TJsValue; const Call: TBindingCall);
    { Milliseconds since the context was made (DOMHighResTimeStamp). }
    function Now: Double;

    { Results }
    function TextValue(const Text: string): TJsValue; inline;
    function NullableText(const Text: string; IsNull: Boolean): TJsValue;
    function NodeValue(Node: TNode): TJsValue;
    function NewArray(const Values: array of TJsValue): TJsValue;
    function StringArray(const Values: array of string): TJsValue;
    function NodeArray(const Nodes: TNodeArray): TJsValue;

    { Errors: a JavaScript exception from a Pascal one (JsException). }
    function ThrowFromException(Error: Exception): TJsValue;
    function NewDomException(const Name, Message: string): TJsValue;
    function ThrowDomException(const Name, Message: string): TJsValue;
    { Reports an uncaught exception value to the console. }
    procedure ReportException(Value: TJsValue; const Where: string = '');
    { Takes the pending exception and reports it. }
    procedure ReportPendingException(const Where: string = '');
    procedure Console(const Level, Text: string);

    { Calling script from native code. }
    procedure EnterScript;
    procedure LeaveScript;
    { Calls F; the exception is reported, False then. }
    function CallFunction(F, This: TJsValue; const Args: array of TJsValue; out Value: TJsValue;
      const Where: string = ''): Boolean;
    { Runs the microtasks (promise jobs, mutation observers). }
    procedure PerformMicrotaskCheckpoint; virtual;

    { A form control's state (made on first use, kept while the element
      has its wrapper), or nil if it has none. }
    function FormState(Element: TElement): TFormControlState;
    function FindFormState(Element: TElement): TFormControlState;

    { The window's objects (JsUndefined until set). }
    function Singleton(Kind: TWindowSingleton): TJsValue;
    procedure SetSingleton(Kind: TWindowSingleton; Value: TJsValue);

    { document.open, write and close: the script context's parser host
      does them (Web.Script.Context). }
    procedure DocumentOpen(Target: TDocument); virtual;
    procedure DocumentWrite(Target: TDocument; const Text: string); virtual;
    procedure DocumentClose(Target: TDocument); virtual;
    { document.readyState of a document. }
    function ReadyState(Target: TDocument): string; virtual;

    { Listeners (TBindingListenerOwner). }
    procedure InvokeListener(Callback: TJsValue; Event: TEvent); override;
    procedure InvokeEventHandler(EventType: TAtom; Event: TEvent); override;
    { Event handlers: the value for a target (JsNull if none). }
    function EventHandlerMap(Target: TEventTarget; CreateIfMissing: Boolean): TJsObject;

    property Engine: TJsEngine read FEngine;
    property Document: TDocument read FDocument;
    property Window: TEventTarget read FWindow;
    property Environment: TScriptEnvironment read FEnvironment write FEnvironment;
    { The context frees its environment. }
    property OwnsEnvironment: Boolean read FOwnsEnvironment write FOwnsEnvironment;
    property CallDepth: Integer read FCallDepth;
    property OnConsoleMessage: TConsoleMessageEvent read FOnConsoleMessage write FOnConsoleMessage;
    property Destroying: Boolean read FDestroying;
    { The script element whose script runs (document.currentScript). }
    property CurrentScript: TElement read FCurrentScript write FCurrentScript;
  end;

var
  { The first collection threshold of new contexts' engines in bytes (0:
    libjavascript's default); tests make it small to collect often. }
  ContextHeapThreshold: Int64 = 0;

{ The context of a realm (natives get the realm). }
function ContextOfRealm(R: TJsRealm): TBindingContext;
{ The script context of a call. }
function CallContext(const Call: TBindingCall): TBindingContext; inline;
{ The DOM text of a JavaScript string value (WTF-8). }
function ValueToText(R: TJsRealm; Value: TJsValue): string;

implementation

uses
  Js.Inspect;

var
  Contexts: array of TBindingContext;
  LastContext: TBindingContext;

function ContextOfRealm(R: TJsRealm): TBindingContext;
var
  Index: Integer;
begin
  if (LastContext <> nil) and (LastContext.FEngine.Realm = R) then
    Exit(LastContext);
  for Index := 0 to High(Contexts) do
    if Contexts[Index].FEngine.Realm = R then
    begin
      LastContext := Contexts[Index];
      Exit(LastContext);
    end;
  Result := nil;
end;

function CallContext(const Call: TBindingCall): TBindingContext;
begin
  Result := TBindingContext(Call.Context);
end;

function ValueToText(R: TJsRealm; Value: TJsValue): string;
var
  Text: TJsString;
begin
  Text := ToJsString(R, Value);
  if Text = nil then
    raise EBindingPendingException.Create('');
  Result := JsStringToText(R.Heap, Text);
end;

function EventInterfaceOf(Event: TEvent): Integer;
begin
  if Event is TMouseEvent then
    Result := InterfaceMouseEvent
  else if Event is TKeyboardEvent then
    Result := InterfaceKeyboardEvent
  else if Event is TFocusEvent then
    Result := InterfaceFocusEvent
  else if Event is TInputEvent then
    Result := InterfaceInputEvent
  else if Event is TUiEvent then
    Result := InterfaceUIEvent
  else if Event is TCustomEvent then
    Result := InterfaceCustomEvent
  else
    Result := InterfaceEvent;
end;

procedure EventGoing(Event: TEvent);
var
  Wrapper: TBindingWrapper;
begin
  Wrapper := TBindingWrapper(Event.ScriptWrapper);
  if Wrapper = nil then
    Exit;
  { The event is freed while its wrapper lives (a Free instead of a
    Release): the wrapper is left without a native object. }
  Wrapper.NativeData := nil;
  Event.ScriptWrapper := nil;
end;

{ TBindingClass }

procedure TBindingClass.TraceNative(HostClass_: TJsHostClass; NativeData: Pointer; Tracer: TJsTracer);
begin
end;

{ TBindingWrapper }

function TBindingWrapper.Binding: TBindingClass;
begin
  Result := TBindingClass(TMethod(HostClass.Tracer).Data);
end;

function TBindingWrapper.CachedValue(Slot: Integer): TJsValue;
begin
  if Slot < Length(Cache) then
    Result := Cache[Slot]
  else
    Result := JsUndefined;
end;

procedure TBindingWrapper.SetCachedValue(Slot: Integer; Value: TJsValue);
var
  Index, OldLength: Integer;
begin
  if Slot >= Length(Cache) then
  begin
    OldLength := Length(Cache);
    SetLength(Cache, Slot + 1);
    for Index := OldLength to Slot do
      Cache[Index] := JsUndefined;
  end;
  Cache[Slot] := Value;
end;

procedure TBindingWrapper.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  inherited Trace(Tracer);
  for Index := 0 to High(Cache) do
    Tracer.MarkValue(Cache[Index]);
  Tracer.MarkValue(Owner);
  if (NativeData <> nil) and (TObject(NativeData) is TEventTarget) then
    TraceListeners(TEventTarget(NativeData).ListenerList(False), Tracer);
end;

destructor TBindingWrapper.Destroy;
var
  Context: TBindingContext;
  Native: TObject;
begin
  Native := TObject(NativeData);
  Context := Binding.Context;
  if Native <> nil then
  begin
    if (WrapperFlags and WrapperIsNode) <> 0 then
    begin
      Context.UnregisterWrapper(Context.FNodeWrappers, Context.FNodeWrapperCount, Self);
      TNode(Native).ScriptWrapper := nil;
      Context.NodeWrapperDying(TNode(Native));
      DisableListeners(TNode(Native).ListenerList(False), Context);
      TNode(Native).Release;
    end
    else if (WrapperFlags and WrapperIsEvent) <> 0 then
    begin
      Context.UnregisterWrapper(Context.FEventWrappers, Context.FEventWrapperCount, Self);
      TEvent(Native).ScriptWrapper := nil;
      TEvent(Native).Release;
    end
    else
    begin
      if Native is TStandaloneEventTarget then
      begin
        TStandaloneEventTarget(Native).ScriptWrapper := nil;
        DisableListeners(TStandaloneEventTarget(Native).Listeners, Context);
      end;
      if (WrapperFlags and WrapperOwnsNative) <> 0 then
        Native.Free;
    end;
    NativeData := nil;
  end;
  inherited Destroy;
end;

{ TBindingContext }

constructor TBindingContext.Create(ADocument: TDocument; AEnvironment: TScriptEnvironment; AWindow: TEventTarget);
begin
  CreateFrame(ADocument, AEnvironment, nil, nil);
  if AWindow <> nil then
  begin
    { The loader's window replaces the context's own. }
    FDocument.DefaultView := nil;
    FWindow.Free;
    FWindow := AWindow;
    FOwnsWindow := False;
    FDocument.DefaultView := FWindow;
  end;
end;

constructor TBindingContext.CreateFrame(ADocument: TDocument; AEnvironment: TScriptEnvironment;
  Parent: TBindingContext; AFrameElement: TElement);
const
  FrameStackCapacity = 64 * 1024;
  FrameMaximumFrames = 2000;
var
  Singleton_: TWindowSingleton;
  Options: TJsEngineOptions;
  AWindow: TEventTarget;
begin
  inherited Create;
  AWindow := nil;
  Options := TJsEngine.DefaultOptions;
  if ContextHeapThreshold > 0 then
    Options.InitialHeapThreshold := ContextHeapThreshold;
  if Parent = nil then
    FEngine := TJsEngine.Create(Options)
  else
  begin
    Options.StackCapacity := FrameStackCapacity;
    Options.MaximumFrames := FrameMaximumFrames;
    FEngine := TJsEngine.CreateSharing(Parent.FEngine, Options);
    FParentContext := Parent;
    FFrameElement := AFrameElement;
    FFrameElement.Retain;
    SetLength(Parent.FChildFrames, Length(Parent.FChildFrames) + 1);
    Parent.FChildFrames[High(Parent.FChildFrames)] := Self;
  end;
  FDocument := ADocument;
  FDocument.Retain;
  FEnvironment := AEnvironment;
  if FEnvironment = nil then
  begin
    FEnvironment := TScriptEnvironment.Create;
    FOwnsEnvironment := True;
  end;
  FWindow := AWindow;
  FOwnsWindow := AWindow = nil;
  if FOwnsWindow then
    FWindow := TWindowTarget.Create;
  FDocument.DefaultView := FWindow;
  FWindowHandlers := JsUndefined;
  FTimeOrigin := GetTickCount64;
  for Singleton_ := Low(TWindowSingleton) to High(TWindowSingleton) do
    FSingletons[Singleton_] := JsUndefined;
  FEngine.Runtime.Heap.AddRootProvider(@MarkRoots);
  FEngine.Runtime.Heap.AddWeakProcessor(@MarkLiveGroups);
  FEngine.Realm.ConsoleWriter := @WriteConsole;
  IndexedWrapperClass := TBindingWrapper;
  SetLength(Contexts, Length(Contexts) + 1);
  Contexts[High(Contexts)] := Self;
  RegisterListenerOwner(Self);
  EventDestroyedHook := @EventGoing;
end;

destructor TBindingContext.Destroy;
var
  Index: Integer;
begin
  FDestroying := True;
  UnregisterListenerOwner(Self);
  if FWindow.ListenerList(False) <> nil then
    DisableListeners(FWindow.ListenerList(False), Self);
  { The engine's cells go first: the wrappers release their nodes (a
    frame's cells go with the top-level engine, before the frames). }
  FreeAndNil(FEngine);
  FreeChildFrames;
  if FFrameElement <> nil then
    FFrameElement.Release;
  FreeAndNil(MutationObservers);
  FreeAndNil(Timers);
  for Index := 0 to High(Contexts) do
    if Contexts[Index] = Self then
    begin
      Contexts[Index] := Contexts[High(Contexts)];
      SetLength(Contexts, High(Contexts));
      Break;
    end;
  if LastContext = Self then
    LastContext := nil;
  for Index := 0 to High(InterfaceClasses) do
    InterfaceClasses[Index].Free;
  EventHandlerAccessors.Free;
  if FOwnsWindow and (FDocument.DefaultView = FWindow) then
    FDocument.DefaultView := nil;
  if FDocumentObserver <> nil then
    FDocument.RemoveObserver(FDocumentObserver);
  FreeAndNil(FDocumentObserver);
  if FOwnsWindow then
    FWindow.Free;
  FreeFormStates;
  FDocument.Release;
  if FOwnsEnvironment then
    FEnvironment.Free;
  inherited Destroy;
end;

procedure TBindingContext.FreeChildFrames;
var
  Index: Integer;
begin
  for Index := 0 to High(FChildFrames) do
    FChildFrames[Index].Free;
  FChildFrames := nil;
end;

function TBindingContext.FrameOf(Element: TElement): TBindingContext;
var
  Index: Integer;
begin
  for Index := 0 to High(FChildFrames) do
    if (FChildFrames[Index].FFrameElement = Element) and not FChildFrames[Index].FClosed then
      Exit(FChildFrames[Index]);
  Result := nil;
end;

function TBindingContext.FrameCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(FChildFrames) do
    if not FChildFrames[Index].FClosed then
      Inc(Result);
end;

function TBindingContext.FrameAt(Index: Integer): TBindingContext;
var
  Walk: Integer;
begin
  for Walk := 0 to High(FChildFrames) do
    if not FChildFrames[Walk].FClosed then
    begin
      if Index = 0 then
        Exit(FChildFrames[Walk]);
      Dec(Index);
    end;
  Result := nil;
end;

procedure TBindingContext.Close;
var
  Index: Integer;
begin
  if FClosed or (FParentContext = nil) then
    Exit;
  FClosed := True;
  for Index := 0 to High(FChildFrames) do
    FChildFrames[Index].Close;
  FEngine.Runtime.Heap.RemoveRootProvider(@MarkRoots);
  FEngine.Detach;
end;

function TBindingContext.TopContext: TBindingContext;
begin
  Result := Self;
  while Result.FParentContext <> nil do
    Result := Result.FParentContext;
end;

procedure TBindingContext.FreeFormStates;
var
  Index: Integer;
begin
  if FFormStates = nil then
    Exit;
  for Index := 0 to FFormStates.Count - 1 do
    FFormStates.Data[Index].Free;
  FreeAndNil(FFormStates);
end;

procedure TBindingContext.NodeWrapped(Node: TNode);
begin
end;

procedure TBindingContext.NodeWrapperDying(Node: TNode);
var
  Index: Integer;
begin
  if (FFormStates <> nil) and FFormStates.Find(Node, Index) then
  begin
    FFormStates.Data[Index].Free;
    FFormStates.Delete(Index);
  end;
end;

function TBindingContext.FindFormState(Element: TElement): TFormControlState;
var
  Index: Integer;
begin
  Result := nil;
  if (FFormStates <> nil) and FFormStates.Find(Element, Index) then
    Result := FFormStates.Data[Index];
end;

function TBindingContext.FormState(Element: TElement): TFormControlState;
begin
  if FFormStates = nil then
  begin
    FFormStates := TFormStateMap.Create;
    FFormStates.Sorted := True;
  end;
  Result := FindFormState(Element);
  if Result = nil then
  begin
    Result := TFormControlState.Create;
    FFormStates.Add(Element, Result);
  end;
end;

procedure TBindingContext.WriteConsole(const Text: string; IsError: Boolean);
begin
  if IsError then
    Console('error', Text)
  else
    Console('log', Text);
end;

procedure TBindingContext.Console(const Level, Text: string);
begin
  if Assigned(FOnConsoleMessage) then
    FOnConsoleMessage(Level, Text)
  else if (Level = 'error') or (Level = 'warn') then
    WriteLn(StdErr, Text)
  else
    WriteLn(Text);
end;

procedure TBindingContext.MarkRoots(Tracer: TJsTracer);
var
  Index: Integer;
  Wrapper: TBindingWrapper;
  Kind: TWindowSingleton;
begin
  FGroupRootsValid := False;
  for Kind := Low(TWindowSingleton) to High(TWindowSingleton) do
    Tracer.MarkValue(FSingletons[Kind]);
  Tracer.MarkValue(FWindowHandlers);
  TraceListeners(FWindow.ListenerList(False), Tracer);
  { The window's document: every wrapper of a connected node lives. }
  if FDocument.ScriptWrapper <> nil then
    Tracer.MarkCell(TBindingWrapper(FDocument.ScriptWrapper));
  { Events being dispatched keep their wrappers (and expandos). }
  for Index := 0 to FEventWrapperCount - 1 do
  begin
    Wrapper := FEventWrappers[Index];
    if (Wrapper.NativeData <> nil) and TEvent(Wrapper.NativeData).IsDispatching then
      Tracer.MarkCell(Wrapper);
  end;
end;

function GroupRootOf(Node: TNode): TNode;
var
  Next: TNode;
begin
  Result := Node;
  while True do
  begin
    if Result.NodeType = NodeTypeAttribute then
      Next := TAttr(Result).OwnerElement
    else if (Result.NodeType = NodeTypeDocumentFragment) and (TDocumentFragment(Result).Host <> nil) then
      Next := TDocumentFragment(Result).Host
    else
      Next := Result.ParentNode;
    if Next = nil then
      Exit;
    Result := Next;
  end;
end;

{ The live groups are an open addressing set of tree roots, its
  capacity a power of two at least twice the wrapper count. }
function GroupSlot(Root: TNode; Mask: PtrUInt): PtrUInt; inline;
begin
  Result := ((PtrUInt(Root) shr 4) * PtrUInt(2654435761)) and Mask;
end;

function TBindingContext.GroupIsLive(Root: TNode): Boolean;
var
  Mask, Slot: PtrUInt;
begin
  Mask := PtrUInt(Length(FLiveGroups) - 1);
  Slot := GroupSlot(Root, Mask);
  while FLiveGroups[Slot] <> nil do
  begin
    if FLiveGroups[Slot] = Root then
      Exit(True);
    Slot := (Slot + 1) and Mask;
  end;
  Result := False;
end;

procedure TBindingContext.AddLiveGroup(Root: TNode);
var
  Mask, Slot: PtrUInt;
begin
  Mask := PtrUInt(Length(FLiveGroups) - 1);
  Slot := GroupSlot(Root, Mask);
  while FLiveGroups[Slot] <> nil do
  begin
    if FLiveGroups[Slot] = Root then
      Exit;
    Slot := (Slot + 1) and Mask;
  end;
  FLiveGroups[Slot] := Root;
  Inc(FLiveGroupCount);
end;

function TBindingContext.MarkLiveGroups(Tracer: TJsTracer; Phase: Integer): Boolean;
var
  Index, Capacity: Integer;
  Wrapper: TBindingWrapper;
begin
  Result := False;
  if Phase <> 0 then
  begin
    FGroupRootsValid := False;
    Exit;
  end;
  if not FGroupRootsValid then
  begin
    SetLength(FGroupRoots, FNodeWrapperCount);
    for Index := 0 to FNodeWrapperCount - 1 do
      FGroupRoots[Index] := GroupRootOf(TNode(FNodeWrappers[Index].NativeData));
    FGroupRootsValid := True;
  end;
  Capacity := 16;
  while Capacity < FNodeWrapperCount * 2 do
    Capacity := Capacity * 2;
  if Length(FLiveGroups) <> Capacity then
    SetLength(FLiveGroups, Capacity);
  FillChar(FLiveGroups[0], Capacity * SizeOf(TNode), 0);
  FLiveGroupCount := 0;
  for Index := 0 to FNodeWrapperCount - 1 do
    if FNodeWrappers[Index].Marked then
      AddLiveGroup(FGroupRoots[Index]);
  for Index := 0 to FNodeWrapperCount - 1 do
  begin
    Wrapper := FNodeWrappers[Index];
    if not Wrapper.Marked and GroupIsLive(FGroupRoots[Index]) then
    begin
      Tracer.MarkCell(Wrapper);
      Result := True;
    end;
  end;
end;

procedure TBindingContext.RegisterWrapper(var List: TBindingWrapperArray; var Count: Integer;
  Wrapper: TBindingWrapper);
begin
  if Count >= Length(List) then
    SetLength(List, Count * 2 + 16);
  List[Count] := Wrapper;
  Wrapper.RegistryIndex := Count;
  Inc(Count);
  FGroupRootsValid := False;
end;

procedure TBindingContext.UnregisterWrapper(var List: TBindingWrapperArray; var Count: Integer;
  Wrapper: TBindingWrapper);
var
  Index: Integer;
begin
  Index := Wrapper.RegistryIndex;
  if (Index < 0) or (Index >= Count) or (List[Index] <> Wrapper) then
    Exit;
  Dec(Count);
  List[Index] := List[Count];
  List[Index].RegistryIndex := Index;
  List[Count] := nil;
  Wrapper.RegistryIndex := -1;
  FGroupRootsValid := False;
end;

function TBindingContext.NodeWrapperCount: Integer;
begin
  Result := FNodeWrapperCount;
end;

function TBindingContext.IsInterface(InterfaceId, Ancestor: Integer): Boolean;
begin
  while InterfaceId >= 0 do
  begin
    if InterfaceId = Ancestor then
      Exit(True);
    InterfaceId := InterfaceParents[InterfaceId];
  end;
  Result := False;
end;

function TBindingContext.EnsureInterface(InterfaceId: Integer): TBindingClass;
begin
  Result := InterfaceClasses[InterfaceId];
  if Result.HostClass = nil then
    InterfaceInstaller(Self, InterfaceId);
end;

function TBindingContext.HostClassOf(InterfaceId: Integer): TJsHostClass;
begin
  Result := EnsureInterface(InterfaceId).HostClass;
end;

function TBindingContext.PrototypeOf(InterfaceId: Integer): TJsObject;
begin
  Result := EnsureInterface(InterfaceId).HostClass.Prototype;
end;

function IsCustomElementName(const Name: string): Boolean;
begin
  Result := (Pos('-', Name) > 0) and (Name <> '') and (Name[1] in ['a'..'z']);
end;

function TBindingContext.InterfaceForNode(Node: TNode): Integer;
var
  Atom: TAtom;
begin
  case Node.NodeType of
    NodeTypeElement:
      begin
        if not TElement(Node).IsHtml then
          Exit(InterfaceElement);
        Atom := Node.LocalNameAtom;
        if (Atom < LongWord(Length(ElementInterfaces))) and (ElementInterfaces[Atom] >= 0) then
          Exit(ElementInterfaces[Atom]);
        if IsCustomElementName(TElement(Node).LocalName) then
          Exit(InterfaceHTMLElement);
        Result := InterfaceHTMLUnknownElement;
      end;
    NodeTypeText:
      Result := InterfaceText;
    NodeTypeCDataSection:
      Result := InterfaceCDATASection;
    NodeTypeComment:
      Result := InterfaceComment;
    NodeTypeProcessingInstruction:
      Result := InterfaceProcessingInstruction;
    NodeTypeDocumentType:
      Result := InterfaceDocumentType;
    NodeTypeDocumentFragment:
      Result := InterfaceDocumentFragment;
    NodeTypeDocument:
      if TDocument(Node).IsHtmlDocument then
        Result := InterfaceHTMLDocument
      else
        Result := InterfaceDocument;
    NodeTypeAttribute:
      Result := InterfaceAttr;
  else
    Result := InterfaceNode;
  end;
end;

function TBindingContext.WrapObjectWithPrototype(Native: TObject; InterfaceId: Integer; Owned: Boolean;
  Prototype: TJsObject): TJsValue;
begin
  if (InterfaceClasses[InterfaceId].Flags and (InterfaceIndexed or InterfaceNamed)) <> 0 then
    Result := NewWrapper(IndexedWrapperClass, Native, InterfaceId, Owned, Prototype)
  else
    Result := NewWrapper(TBindingWrapper, Native, InterfaceId, Owned, Prototype);
end;

function TBindingContext.WrapObjectAs(WrapperClass: TBindingWrapperClass; Native: TObject; InterfaceId: Integer;
  Owned: Boolean; OwnerWrapper: TJsValue): TJsValue;
begin
  Result := NewWrapper(WrapperClass, Native, InterfaceId, Owned, PrototypeOf(InterfaceId));
  TBindingWrapper(JsAsObject(Result)).Owner := OwnerWrapper;
end;

function TBindingContext.NewWrapper(WrapperClass: TBindingWrapperClass; Native: TObject; InterfaceId: Integer;
  Owned: Boolean; Prototype: TJsObject): TJsValue;
var
  Wrapper: TBindingWrapper;
  Binding: TBindingClass;
begin
  Binding := EnsureInterface(InterfaceId);
  Wrapper := TBindingWrapper(FEngine.Realm.NewObjectOfClass(WrapperClass, Prototype, ocHost));
  if WrapperClass <> TBindingWrapper then
    Wrapper.ObjectFlags := Wrapper.ObjectFlags or ObjectExotic;
  Wrapper.HostClass := Binding.HostClass;
  Wrapper.NativeData := Native;
  Wrapper.RegistryIndex := -1;
  Wrapper.Owner := JsUndefined;
  if Owned then
    Wrapper.WrapperFlags := WrapperOwnsNative;
  if Native is TStandaloneEventTarget then
    TStandaloneEventTarget(Native).ScriptWrapper := Wrapper;
  Result := JsObjectValue(Wrapper);
end;

function TBindingContext.WrapObject(Native: TObject; InterfaceId: Integer; Owned: Boolean;
  OwnerWrapper: TJsValue): TJsValue;
begin
  if Native = nil then
    Exit(JsNull);
  Result := WrapObjectWithPrototype(Native, InterfaceId, Owned, PrototypeOf(InterfaceId));
  TBindingWrapper(JsAsObject(Result)).Owner := OwnerWrapper;
end;

function TBindingContext.WrapNode(Node: TNode): TJsValue;
var
  Wrapper: TBindingWrapper;
  InterfaceId: Integer;
begin
  if Node = nil then
    Exit(JsNull);
  if Node.ScriptWrapper <> nil then
    Exit(JsObjectValue(TBindingWrapper(Node.ScriptWrapper)));
  InterfaceId := InterfaceForNode(Node);
  Wrapper := TBindingWrapper(JsAsObject(WrapObjectWithPrototype(Node, InterfaceId, False,
    PrototypeOf(InterfaceId))));
  Wrapper.WrapperFlags := WrapperIsNode;
  Node.Retain;
  Node.ScriptWrapper := Wrapper;
  RegisterWrapper(FNodeWrappers, FNodeWrapperCount, Wrapper);
  NodeWrapped(Node);
  Result := JsObjectValue(Wrapper);
end;

function TBindingContext.WrapEvent(Event: TEvent): TJsValue;
var
  Wrapper: TBindingWrapper;
  InterfaceId: Integer;
begin
  if Event = nil then
    Exit(JsNull);
  if Event.ScriptWrapper <> nil then
    Exit(JsObjectValue(TBindingWrapper(Event.ScriptWrapper)));
  InterfaceId := EventInterfaceOf(Event);
  Wrapper := TBindingWrapper(JsAsObject(WrapObjectWithPrototype(Event, InterfaceId, False,
    PrototypeOf(InterfaceId))));
  Wrapper.WrapperFlags := WrapperIsEvent;
  Event.Retain;
  Event.ScriptWrapper := Wrapper;
  RegisterWrapper(FEventWrappers, FEventWrapperCount, Wrapper);
  Result := JsObjectValue(Wrapper);
end;

function TBindingContext.Singleton(Kind: TWindowSingleton): TJsValue;
begin
  Result := FSingletons[Kind];
end;

procedure TBindingContext.SetSingleton(Kind: TWindowSingleton; Value: TJsValue);
begin
  FSingletons[Kind] := Value;
end;

procedure TBindingContext.DocumentOpen(Target: TDocument);
begin
  RaiseDomError(InvalidStateError, 'document.open is not supported here');
end;

procedure TBindingContext.DocumentWrite(Target: TDocument; const Text: string);
begin
  RaiseDomError(InvalidStateError, 'document.write is not supported here');
end;

procedure TBindingContext.DocumentClose(Target: TDocument);
begin
end;

function TBindingContext.ReadyState(Target: TDocument): string;
begin
  Result := 'complete';
end;

function TBindingContext.Now: Double;
begin
  Result := GetTickCount64 - FTimeOrigin;
end;

function TBindingContext.PrototypeForConstruct(const Call: TBindingCall): TJsObject;
var
  Prototype: TJsValue;
begin
  Result := PrototypeOf(Call.InterfaceId);
  if not JsIsObject(Call.NewTarget) or (Call.NewTarget = JsObjectValue(HostClassOf(Call.InterfaceId).Constructor_)) then
    Exit;
  Prototype := JsAsObject(Call.NewTarget).GetValue(FEngine.Realm, FEngine.Realm.PrototypeKey);
  if Prototype = JsException then
    raise EBindingPendingException.Create('');
  if JsIsObject(Prototype) then
    Result := JsAsObject(Prototype);
end;

procedure TBindingContext.AdjustConstructedPrototype(Value: TJsValue; const Call: TBindingCall);
var
  Prototype: TJsObject;
begin
  Prototype := PrototypeForConstruct(Call);
  if JsAsObject(Value).Proto <> Prototype then
    JsAsObject(Value).SetPrototype(FEngine.Realm, Prototype);
end;

function TBindingContext.ConstructedObject(const Call: TBindingCall; Native: TObject): TJsValue;
begin
  try
    Result := WrapObjectWithPrototype(Native, Call.InterfaceId, True, PrototypeForConstruct(Call));
  except
    Native.Free;
    raise;
  end;
end;

function TBindingContext.ConstructedEvent(const Call: TBindingCall; Event: TEvent): TJsValue;
var
  Wrapper: TBindingWrapper;
begin
  try
    Result := WrapObjectWithPrototype(Event, Call.InterfaceId, False, PrototypeForConstruct(Call));
  except
    Event.Release;
    raise;
  end;
  Wrapper := TBindingWrapper(JsAsObject(Result));
  Wrapper.WrapperFlags := WrapperIsEvent;
  Event.ScriptWrapper := Wrapper;
  RegisterWrapper(FEventWrappers, FEventWrapperCount, Wrapper);
end;

function TBindingContext.WrapTarget(Target: TEventTarget): TJsValue;
begin
  if Target = nil then
    Result := JsNull
  else if Target is TNode then
    Result := WrapNode(TNode(Target))
  else if Target = FWindow then
    Result := JsObjectValue(FEngine.GlobalObject)
  else if (Target is TStandaloneEventTarget) and (TStandaloneEventTarget(Target).ScriptWrapper <> nil) then
    Result := JsObjectValue(TBindingWrapper(TStandaloneEventTarget(Target).ScriptWrapper))
  else
    Result := JsNull;
end;

function TBindingContext.WrapperOf(Value: TJsValue): TBindingWrapper;
var
  Target: TJsObject;
begin
  Result := nil;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  if Target is TBindingWrapper then
    Result := TBindingWrapper(Target);
end;

function TBindingContext.Unwrap(Value: TJsValue; InterfaceId: Integer): TObject;
var
  Wrapper: TBindingWrapper;
begin
  Result := nil;
  if (Value = JsObjectValue(FEngine.GlobalObject)) or JsIsNullish(Value) then
  begin
    if IsInterface(InterfaceWindow, InterfaceId) then
      Result := FWindow;
    Exit;
  end;
  Wrapper := WrapperOf(Value);
  if (Wrapper = nil) or (TMethod(Wrapper.HostClass.Tracer).Data = nil) then
    Exit;
  if Wrapper.Binding.Context <> Self then
    Exit;
  if IsInterface(Wrapper.Binding.InterfaceId, InterfaceId) then
    Result := TObject(Wrapper.NativeData);
end;

function TBindingContext.TextValue(const Text: string): TJsValue;
begin
  Result := TextToJsValue(FEngine.Runtime.Heap, Text);
end;

function TBindingContext.NullableText(const Text: string; IsNull: Boolean): TJsValue;
begin
  if IsNull then
    Result := JsNull
  else
    Result := TextValue(Text);
end;

function TBindingContext.NodeValue(Node: TNode): TJsValue;
begin
  Result := WrapNode(Node);
end;

function TBindingContext.NewArray(const Values: array of TJsValue): TJsValue;
begin
  Result := FEngine.NewArray(Values);
end;

function TBindingContext.StringArray(const Values: array of string): TJsValue;
var
  Items: TJsValueList;
  Index: Integer;
  Mark: Integer;
begin
  Items := nil;
  SetLength(Items, Length(Values));
  Mark := FEngine.Runtime.PushRoot(JsUndefined);
  for Index := 0 to High(Values) do
  begin
    Items[Index] := TextValue(Values[Index]);
    FEngine.Runtime.PushRoot(Items[Index]);
  end;
  Result := FEngine.NewArray(Items);
  FEngine.Runtime.PopRoots(Mark);
end;

function TBindingContext.NodeArray(const Nodes: TNodeArray): TJsValue;
var
  Items: TJsValueList;
  Index: Integer;
begin
  Items := nil;
  SetLength(Items, Length(Nodes));
  for Index := 0 to High(Nodes) do
    Items[Index] := WrapNode(Nodes[Index]);
  Result := FEngine.NewArray(Items);
end;

function TBindingContext.NewDomException(const Name, Message: string): TJsValue;
var
  Data: TDomExceptionData;
begin
  Data := TDomExceptionData.Create;
  Data.Name := Name;
  Data.Message := Message;
  Result := WrapObject(Data, InterfaceDOMException, True, JsUndefined);
end;

function TBindingContext.ThrowDomException(const Name, Message: string): TJsValue;
begin
  Result := FEngine.Realm.Throw(NewDomException(Name, Message));
end;

function TBindingContext.ThrowFromException(Error: Exception): TJsValue;
var
  R: TJsRealm;
  Message: string;
begin
  R := FEngine.Realm;
  if Error is EBindingPendingException then
  begin
    if not R.HasException then
      R.ThrowTypeError('script error');
    Exit(JsException);
  end;
  if R.HasException then
    FEngine.Runtime.TakeException;
  if Error is EDomException then
  begin
    Message := Error.Message;
    if Copy(Message, 1, Length(EDomException(Error).ErrorName) + 2) = EDomException(Error).ErrorName + ': ' then
      Delete(Message, 1, Length(EDomException(Error).ErrorName) + 2);
    Result := ThrowDomException(EDomException(Error).ErrorName, Message);
  end
  else if Error is EBindingTypeError then
    Result := R.ThrowTypeError(Error.Message)
  else if Error is EBindingRangeError then
    Result := R.ThrowRangeError(Error.Message)
  else if Error is EScriptEnvironmentUnsupported then
    Result := ThrowDomException(NotSupportedError, Error.Message)
  else if Error is EJsError then
    Result := R.ThrowError(ekError, Error.Message)
  else
    Result := R.ThrowError(ekError, Error.ClassName + ': ' + Error.Message);
end;

procedure TBindingContext.ReportException(Value: TJsValue; const Where: string);
var
  Text: string;
  Data: TObject;
begin
  Data := Unwrap(Value, InterfaceDOMException);
  if Data <> nil then
    Text := TDomExceptionData(Data).Name + ': ' + TDomExceptionData(Data).Message
  else
    Text := FEngine.ErrorText(Value);
  if Copy(Text, 1, 9) <> 'Uncaught ' then
    Text := 'Uncaught ' + Text;
  if Where <> '' then
    Text := Text + ' (' + Where + ')';
  Console('error', Text);
end;

procedure TBindingContext.ReportPendingException(const Where: string);
var
  Value: TJsValue;
begin
  if not FEngine.Runtime.HasException then
    Exit;
  Value := FEngine.Runtime.TakeException;
  FEngine.Runtime.Terminating := False;
  ReportException(Value, Where);
end;

procedure TBindingContext.EnterScript;
begin
  Inc(FCallDepth);
end;

procedure TBindingContext.LeaveScript;
begin
  Dec(FCallDepth);
  if FCallDepth = 0 then
    PerformMicrotaskCheckpoint;
end;

function TBindingContext.CallFunction(F, This: TJsValue; const Args: array of TJsValue; out Value: TJsValue;
  const Where: string): Boolean;
var
  Mark, Index: Integer;
  Runtime: TJsRuntime;
begin
  Runtime := FEngine.Runtime;
  Mark := Runtime.PushRoot(F);
  Runtime.PushRoot(This);
  for Index := 0 to High(Args) do
    Runtime.PushRoot(Args[Index]);
  EnterScript;
  try
    if Length(Args) = 0 then
      Value := FEngine.Realm.Call(F, This, nil, 0)
    else
      Value := FEngine.Realm.Call(F, This, @Args[0], Length(Args));
    Result := Value <> JsException;
    if not Result then
    begin
      Value := JsUndefined;
      ReportPendingException(Where);
    end;
  finally
    Runtime.PopRoots(Mark);
    LeaveScript;
  end;
end;

procedure TBindingContext.PerformMicrotaskCheckpoint;
var
  Index: Integer;
  Again: Boolean;
begin
  if FCheckpointRunning or FDestroying then
    Exit;
  FCheckpointRunning := True;
  try
    { The frames' realms share the event loop's microtask queue. }
    repeat
      Again := False;
      while FEngine.PendingJobs > 0 do
      begin
        if not FEngine.Realm.RunJobs then
          ReportPendingException;
      end;
      for Index := 0 to High(FChildFrames) do
        if not FChildFrames[Index].FClosed and (FChildFrames[Index].FEngine.PendingJobs > 0) then
        begin
          FChildFrames[Index].PerformMicrotaskCheckpoint;
          Again := True;
        end;
    until not Again;
  finally
    FCheckpointRunning := False;
  end;
end;

procedure TBindingContext.InvokeListener(Callback: TJsValue; Event: TEvent);
var
  EventValue, ThisValue, Handler, Value: TJsValue;
  Mark: Integer;
begin
  EventValue := WrapEvent(Event);
  Mark := FEngine.Runtime.PushRoot(EventValue);
  try
    ThisValue := WrapTarget(Event.CurrentTarget);
    if JsIsCallable(Callback) then
      CallFunction(Callback, ThisValue, [EventValue], Value, 'event listener')
    else if JsIsObject(Callback) then
    begin
      Handler := GetProperty(FEngine.Realm, Callback, FEngine.Realm.Intern('handleEvent'));
      if Handler = JsException then
        ReportPendingException('event listener')
      else if not JsIsCallable(Handler) then
        ReportException(JsObjectValue(FEngine.Realm.NewError(ekType, 'handleEvent is not a function')))
      else
        CallFunction(Handler, Callback, [EventValue], Value, 'event listener');
    end;
  finally
    FEngine.Runtime.PopRoots(Mark);
  end;
end;

function TBindingContext.EventHandlerMap(Target: TEventTarget; CreateIfMissing: Boolean): TJsObject;
var
  Wrapper: TBindingWrapper;
  Value: TJsValue;
begin
  Result := nil;
  if Target = FWindow then
  begin
    if JsIsObject(FWindowHandlers) then
      Exit(JsAsObject(FWindowHandlers));
    if not CreateIfMissing then
      Exit;
    Result := FEngine.Realm.NewObject(nil);
    FWindowHandlers := JsObjectValue(Result);
    Exit;
  end;
  Wrapper := WrapperOf(WrapTarget(Target));
  if Wrapper = nil then
    Exit;
  Value := Wrapper.CachedValue(CacheSlotEventHandlers);
  if JsIsObject(Value) then
    Exit(JsAsObject(Value));
  if not CreateIfMissing then
    Exit;
  Result := FEngine.Realm.NewObject(nil);
  Wrapper.SetCachedValue(CacheSlotEventHandlers, JsObjectValue(Result));
end;

procedure TBindingContext.InvokeEventHandler(EventType: TAtom; Event: TEvent);
begin
  { Web.Script.EventHandlers overrides this in the script context. }
end;

initialization
  EventDestroyedHook := @EventGoing;
end.
