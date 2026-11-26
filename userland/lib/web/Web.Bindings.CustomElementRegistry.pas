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
  The custom element machinery of the HTML Standard (4.13) and the DOM
  Standard (4.9): each window's CustomElementRegistry and its
  definitions, the custom element reactions (the element queues of the
  reactions stack, the backup element queue, each element's reaction
  queue), upgrades, and "create an element" for definitions. It is the
  DOM's CustomElementHost: the mutation algorithms tell it about
  connected, disconnected and adopted elements and attribute changes of
  custom elements, and the parser asks it to create elements.

  Definitions are reference counted: the registry holds one, each
  element whose definition it is one, each pending upgrade one. A
  definition's script values are marked by its registry's root provider
  while the window lives; when the window goes the registry is freed and
  its definitions are marked dead (an element outliving its window keeps
  a definition nothing calls any more).

  [CEReactions]: the dispatcher (Web.Bindings.Dispatch) pushes an element
  queue around every operation and attribute setter while definitions
  exist (EnterReactionsScope, LeaveReactionsScope), so reactions run
  when the method returns; a script exception pending then is set aside
  while they run.
}
unit Web.Bindings.CustomElementRegistry;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Web.Atoms,
  Web.Dom,
  Web.Bindings.Context;

type
  TCustomElementCallback = (CallbackConnected, CallbackDisconnected, CallbackAdopted, CallbackAttributeChanged,
    CallbackFormAssociated, CallbackFormReset, CallbackFormDisabled, CallbackFormStateRestore);

  TCustomElementRegistry = class;

  TCustomElementDefinition = class
  private
    FReferences: Integer;
  public
    Registry: TCustomElementRegistry;
    Name: string;
    LocalName: string;
    LocalNameAtom: TAtom;
    Constructor_: TJsValue;
    Prototype: TJsValue;
    Callbacks: array[TCustomElementCallback] of TJsValue;
    ObservedAttributes: TStringArray;
    FormAssociated: Boolean;
    DisableInternals: Boolean;
    DisableShadow: Boolean;
    { The construction stack: elements being upgraded; nil stands for
      the "already constructed" marker. }
    ConstructionStack: TElementArray;
    constructor Create;
    procedure Retain;
    procedure Release;
    function IsAutonomous: Boolean;
    function Observes(const AttributeName: string): Boolean;
    function HasCallback(Callback: TCustomElementCallback): Boolean;
  end;

  TCustomElementDefinitionArray = array of TCustomElementDefinition;

  TCustomElementRegistry = class
  private
    FContext: TBindingContext;
    FDefinitions: TCustomElementDefinitionArray;
    FPendingNames: TStringArray;
    FPendingPromises: array of TJsValue;
    procedure MarkRoots(Tracer: TJsTracer);
  public
    DefinitionRunning: Boolean;
    constructor Create(Context: TBindingContext);
    destructor Destroy; override;
    function FindByName(const Name: string): TCustomElementDefinition;
    function FindByLocalName(const LocalName, IsValue: string): TCustomElementDefinition;
    function FindByConstructor(Constructor_: TJsValue): TCustomElementDefinition;
    procedure Add(Definition: TCustomElementDefinition);
    { whenDefined's promise for Name (made once, kept until defined). }
    function PendingPromise(const Name: string): TJsValue;
    procedure SetPendingPromise(const Name: string; Promise: TJsValue);
    { The promise waiting for Name, taken out (undefined if none). }
    function TakePendingPromise(const Name: string): TJsValue;
    property Context: TBindingContext read FContext;
    property Definitions: TCustomElementDefinitionArray read FDefinitions;
  end;

  TReactionKind = (ReactionUpgrade, ReactionCallback);

  TCustomElementReaction = record
    Kind: TReactionKind;
    Definition: TCustomElementDefinition;
    Callback: TCustomElementCallback;
    { attributeChangedCallback: name, old value, new value, namespace
      (a missing one is null). }
    Texts: array[0..3] of string;
    Present: array[0..3] of Boolean;
    { adoptedCallback's documents, formAssociatedCallback's form (held). }
    Nodes: array[0..1] of TNode;
    Flag: Boolean;
  end;

  { What an element of a form-associated custom element keeps for its
    ElementInternals. }
  TElementInternalsData = class
  public
    Element: TElement;
    { The submission value: name-value pairs (a string value has the
      element's name; a FormData its entries). }
    EntryNames: TStringArray;
    EntryValues: TStringArray;
    UsesElementName: Boolean;
    HasValue: Boolean;
    State: string;
    ValidityFlags: Word;
    ValidationMessage: string;
    AriaNames: TStringArray;
    AriaValues: TStringArray;
  end;

  { An element's custom element data (in the DOM node's slot, owned by
    the element): its reaction queue and internals. }
  TCustomElementData = class
  public
    Reactions: array of TCustomElementReaction;
    ReactionCount: Integer;
    AttachedInternals: Boolean;
    Internals: TElementInternalsData;
    { The form owner last told to formAssociatedCallback (compared only). }
    LastFormOwner: Pointer;
    HasLastFormOwner: Boolean;
    destructor Destroy; override;
  end;

const
  ValidityValueMissing = $001;
  ValidityTypeMismatch = $002;
  ValidityPatternMismatch = $004;
  ValidityTooLong = $008;
  ValidityTooShort = $010;
  ValidityRangeUnderflow = $020;
  ValidityRangeOverflow = $040;
  ValidityStepMismatch = $080;
  ValidityBadInput = $100;
  ValidityCustomError = $200;

  { ElementState flag of form-associated custom elements. }
  ElementStateFormAssociatedCustom = $0100;

{ The window's registry (made on first use), nil for none. }
function RegistryOf(Context: TBindingContext): TCustomElementRegistry;
function ExistingRegistryOf(Context: TBindingContext): TCustomElementRegistry;
{ "Look up a custom element definition" for a document. }
function LookUpDefinition(Document: TDocument; NamespaceId: Word; LocalNameAtom: TAtom;
  const IsValue: string): TCustomElementDefinition;
{ The element's data, made when missing. }
function CustomDataOf(Element: TElement): TCustomElementData;

{ Reactions. }
procedure EnterReactionsScope;
procedure LeaveReactionsScope(Context: TBindingContext);
procedure EnqueueCallbackReaction(Element: TElement; Callback: TCustomElementCallback;
  const Texts: array of string; const Present: array of Boolean; Node0: TNode = nil; Node1: TNode = nil;
  Flag: Boolean = False);
procedure EnqueueUpgradeReaction(Element: TElement; Definition: TCustomElementDefinition);
{ "Try to upgrade" an element. }
procedure TryToUpgrade(Element: TElement);
{ attachShadow's check: the element's definition disables shadow roots. }
function ShadowDisabledFor(Element: TElement): Boolean;
{ Whether any window has definitions (the quick check). }
function CustomElementsDefined: Boolean;

{ Form-associated custom elements. }
function IsFormAssociatedCustomElement(Element: TElement): Boolean;
{ The form owner changed or may have: formAssociatedCallback when it did. }
procedure CheckFormOwner(Element: TElement);

implementation

uses
  Js.Objects,
  Js.Functions,
  Js.Runtime,
  Js.Operations,
  Js.Promises,
  Web.Namespaces,
  Web.Dom.Exceptions,
  Web.Dom.FormControls,
  Web.Bindings.Types;

var
  Registries: array of TCustomElementRegistry;
  DefinitionCount: Integer;
  { The custom element reactions stack's element queues. }
  QueueStack: array of TElementArray;
  QueueCounts: array of Integer;
  StackDepth: Integer;
  BackupQueue: TElementArray;
  BackupCount: Integer;
  ProcessingBackupQueue: Boolean;

function CustomElementsDefined: Boolean;
begin
  Result := DefinitionCount > 0;
end;

{ TCustomElementDefinition }

constructor TCustomElementDefinition.Create;
var
  Callback: TCustomElementCallback;
begin
  inherited Create;
  FReferences := 1;
  Constructor_ := JsUndefined;
  Prototype := JsUndefined;
  for Callback := Low(TCustomElementCallback) to High(TCustomElementCallback) do
    Callbacks[Callback] := JsUndefined;
end;

procedure TCustomElementDefinition.Retain;
begin
  Inc(FReferences);
end;

procedure TCustomElementDefinition.Release;
begin
  Dec(FReferences);
  if FReferences <= 0 then
    Free;
end;

function TCustomElementDefinition.IsAutonomous: Boolean;
begin
  Result := Name = LocalName;
end;

function TCustomElementDefinition.Observes(const AttributeName: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(ObservedAttributes) do
    if ObservedAttributes[Index] = AttributeName then
      Exit(True);
  Result := False;
end;

function TCustomElementDefinition.HasCallback(Callback: TCustomElementCallback): Boolean;
begin
  Result := (Registry <> nil) and JsIsCallable(Callbacks[Callback]);
end;

{ TCustomElementRegistry }

constructor TCustomElementRegistry.Create(Context: TBindingContext);
begin
  inherited Create;
  FContext := Context;
  Context.Engine.Runtime.Heap.AddRootProvider(@MarkRoots);
  SetLength(Registries, Length(Registries) + 1);
  Registries[High(Registries)] := Self;
end;

destructor TCustomElementRegistry.Destroy;
var
  Index, Position: Integer;
begin
  for Index := 0 to High(Registries) do
    if Registries[Index] = Self then
    begin
      for Position := Index + 1 to High(Registries) do
        Registries[Position - 1] := Registries[Position];
      SetLength(Registries, Length(Registries) - 1);
      Break;
    end;
  if FContext.Engine <> nil then
    FContext.Engine.Runtime.Heap.RemoveRootProvider(@MarkRoots);
  for Index := 0 to High(FDefinitions) do
  begin
    FDefinitions[Index].Registry := nil;
    FDefinitions[Index].Release;
    Dec(DefinitionCount);
  end;
  FDefinitions := nil;
  inherited Destroy;
end;

procedure TCustomElementRegistry.MarkRoots(Tracer: TJsTracer);
var
  Index: Integer;
  Callback: TCustomElementCallback;
  Definition: TCustomElementDefinition;
begin
  for Index := 0 to High(FDefinitions) do
  begin
    Definition := FDefinitions[Index];
    Tracer.MarkValue(Definition.Constructor_);
    Tracer.MarkValue(Definition.Prototype);
    for Callback := Low(TCustomElementCallback) to High(TCustomElementCallback) do
      Tracer.MarkValue(Definition.Callbacks[Callback]);
  end;
  for Index := 0 to High(FPendingPromises) do
    Tracer.MarkValue(FPendingPromises[Index]);
end;

function TCustomElementRegistry.FindByName(const Name: string): TCustomElementDefinition;
var
  Index: Integer;
begin
  for Index := 0 to High(FDefinitions) do
    if FDefinitions[Index].Name = Name then
      Exit(FDefinitions[Index]);
  Result := nil;
end;

function TCustomElementRegistry.FindByLocalName(const LocalName, IsValue: string): TCustomElementDefinition;
var
  Index: Integer;
  Definition: TCustomElementDefinition;
begin
  for Index := 0 to High(FDefinitions) do
  begin
    Definition := FDefinitions[Index];
    if Definition.IsAutonomous then
    begin
      if Definition.LocalName = LocalName then
        Exit(Definition);
    end
    else if (Definition.LocalName = LocalName) and (Definition.Name = IsValue) then
      Exit(Definition);
  end;
  Result := nil;
end;

function TCustomElementRegistry.FindByConstructor(Constructor_: TJsValue): TCustomElementDefinition;
var
  Index: Integer;
begin
  for Index := 0 to High(FDefinitions) do
    if FDefinitions[Index].Constructor_ = Constructor_ then
      Exit(FDefinitions[Index]);
  Result := nil;
end;

procedure TCustomElementRegistry.Add(Definition: TCustomElementDefinition);
begin
  Definition.Registry := Self;
  SetLength(FDefinitions, Length(FDefinitions) + 1);
  FDefinitions[High(FDefinitions)] := Definition;
  Inc(DefinitionCount);
end;

function TCustomElementRegistry.PendingPromise(const Name: string): TJsValue;
var
  Index: Integer;
begin
  for Index := 0 to High(FPendingNames) do
    if FPendingNames[Index] = Name then
      Exit(FPendingPromises[Index]);
  Result := JsUndefined;
end;

procedure TCustomElementRegistry.SetPendingPromise(const Name: string; Promise: TJsValue);
begin
  SetLength(FPendingNames, Length(FPendingNames) + 1);
  SetLength(FPendingPromises, Length(FPendingPromises) + 1);
  FPendingNames[High(FPendingNames)] := Name;
  FPendingPromises[High(FPendingPromises)] := Promise;
end;

function TCustomElementRegistry.TakePendingPromise(const Name: string): TJsValue;
var
  Index, Position: Integer;
begin
  for Index := 0 to High(FPendingNames) do
    if FPendingNames[Index] = Name then
    begin
      Result := FPendingPromises[Index];
      for Position := Index + 1 to High(FPendingNames) do
      begin
        FPendingNames[Position - 1] := FPendingNames[Position];
        FPendingPromises[Position - 1] := FPendingPromises[Position];
      end;
      SetLength(FPendingNames, Length(FPendingNames) - 1);
      SetLength(FPendingPromises, Length(FPendingPromises) - 1);
      Exit;
    end;
  Result := JsUndefined;
end;

function ExistingRegistryOf(Context: TBindingContext): TCustomElementRegistry;
var
  Index: Integer;
begin
  for Index := 0 to High(Registries) do
    if Registries[Index].FContext = Context then
      Exit(Registries[Index]);
  Result := nil;
end;

function RegistryOf(Context: TBindingContext): TCustomElementRegistry;
begin
  Result := ExistingRegistryOf(Context);
  if (Result = nil) and (Context <> nil) and (Context.Engine <> nil) then
    Result := TCustomElementRegistry.Create(Context);
end;

procedure ContextGoing(Context: TBindingContext);
begin
  ExistingRegistryOf(Context).Free;
end;

{ The registry of the window whose document Document is. }
function RegistryOfDocument(Document: TDocument): TCustomElementRegistry;
var
  Index: Integer;
begin
  for Index := 0 to High(Registries) do
    if (Registries[Index].FContext.Document = Document) and not Registries[Index].FContext.Closed then
      Exit(Registries[Index]);
  Result := nil;
end;

function LookUpDefinition(Document: TDocument; NamespaceId: Word; LocalNameAtom: TAtom;
  const IsValue: string): TCustomElementDefinition;
var
  Registry: TCustomElementRegistry;
begin
  Result := nil;
  if (DefinitionCount = 0) or (Document = nil) then
    Exit;
  if Web.Namespaces.NamespaceUri(NamespaceId) <> AtomHtmlNamespace then
    Exit;
  Registry := RegistryOfDocument(Document);
  if Registry = nil then
    Exit;
  Result := Registry.FindByLocalName(NameOfAtom(LocalNameAtom), IsValue);
end;

{ TCustomElementData }

procedure ReleaseReaction(var Reaction: TCustomElementReaction);
var
  Index: Integer;
begin
  if Reaction.Definition <> nil then
    Reaction.Definition.Release;
  Reaction.Definition := nil;
  for Index := 0 to High(Reaction.Nodes) do
    if Reaction.Nodes[Index] <> nil then
    begin
      Reaction.Nodes[Index].Release;
      Reaction.Nodes[Index] := nil;
    end;
end;

destructor TCustomElementData.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to ReactionCount - 1 do
    ReleaseReaction(Reactions[Index]);
  Internals.Free;
  inherited Destroy;
end;

function CustomDataOf(Element: TElement): TCustomElementData;
begin
  Result := TCustomElementData(Element.CustomElementData);
  if Result = nil then
  begin
    Result := TCustomElementData.Create;
    Element.SetCustomElementData(Result);
  end;
end;

{ Element queues }

procedure AddToQueue(var Queue: TElementArray; var Count: Integer; Element: TElement);
begin
  if Count >= Length(Queue) then
    SetLength(Queue, Count * 2 + 8);
  Queue[Count] := Element;
  Inc(Count);
  Element.Retain;
end;

procedure InvokeReactions(const Queue: TElementArray; Count: Integer); forward;

procedure BackupQueueMicrotask(R: TJsRealm; const Values: array of TJsValue);
var
  Queue: TElementArray;
  Count: Integer;
begin
  Queue := BackupQueue;
  Count := BackupCount;
  BackupQueue := nil;
  BackupCount := 0;
  ProcessingBackupQueue := False;
  InvokeReactions(Queue, Count);
end;

{ "Enqueue an element on the appropriate element queue". }
procedure EnqueueElement(Element: TElement; Context: TBindingContext);
begin
  if StackDepth > 0 then
  begin
    AddToQueue(QueueStack[StackDepth - 1], QueueCounts[StackDepth - 1], Element);
    Exit;
  end;
  AddToQueue(BackupQueue, BackupCount, Element);
  if ProcessingBackupQueue or (Context = nil) or (Context.Engine = nil) then
    Exit;
  ProcessingBackupQueue := True;
  Context.Engine.Realm.EnqueueJob(@BackupQueueMicrotask, JsUndefined, JsUndefined, JsUndefined, JsUndefined);
end;

procedure AddReaction(Element: TElement; const Reaction: TCustomElementReaction);
var
  Data: TCustomElementData;
begin
  Data := CustomDataOf(Element);
  if Data.ReactionCount >= Length(Data.Reactions) then
    SetLength(Data.Reactions, Data.ReactionCount * 2 + 4);
  Data.Reactions[Data.ReactionCount] := Reaction;
  Inc(Data.ReactionCount);
end;

function DefinitionOf(Element: TElement): TCustomElementDefinition; inline;
begin
  Result := TCustomElementDefinition(Element.CustomElementDefinition);
end;

function ContextOfDefinition(Definition: TCustomElementDefinition): TBindingContext;
begin
  if (Definition = nil) or (Definition.Registry = nil) then
    Result := nil
  else
    Result := Definition.Registry.FContext;
end;

procedure EnqueueCallbackReaction(Element: TElement; Callback: TCustomElementCallback;
  const Texts: array of string; const Present: array of Boolean; Node0: TNode; Node1: TNode; Flag: Boolean);
var
  Definition: TCustomElementDefinition;
  Reaction: TCustomElementReaction;
  Index: Integer;
begin
  Definition := DefinitionOf(Element);
  if (Definition = nil) or not Definition.HasCallback(Callback) then
    Exit;
  Reaction := Default(TCustomElementReaction);
  Reaction.Kind := ReactionCallback;
  Reaction.Callback := Callback;
  for Index := 0 to High(Texts) do
  begin
    Reaction.Texts[Index] := Texts[Index];
    Reaction.Present[Index] := Present[Index];
  end;
  Reaction.Nodes[0] := Node0;
  Reaction.Nodes[1] := Node1;
  if Node0 <> nil then
    Node0.Retain;
  if Node1 <> nil then
    Node1.Retain;
  Reaction.Flag := Flag;
  AddReaction(Element, Reaction);
  EnqueueElement(Element, ContextOfDefinition(Definition));
end;

procedure EnqueueUpgradeReaction(Element: TElement; Definition: TCustomElementDefinition);
var
  Reaction: TCustomElementReaction;
begin
  Reaction := Default(TCustomElementReaction);
  Reaction.Kind := ReactionUpgrade;
  Reaction.Definition := Definition;
  Definition.Retain;
  AddReaction(Element, Reaction);
  EnqueueElement(Element, ContextOfDefinition(Definition));
end;

procedure TryToUpgrade(Element: TElement);
var
  Definition: TCustomElementDefinition;
begin
  if not (Element.CustomElementState in [CustomElementUndefined, CustomElementUncustomized]) then
    Exit;
  Definition := LookUpDefinition(Element.NodeDocument, Element.NamespaceId, Element.LocalNameAtom, Element.IsValue);
  if Definition <> nil then
    EnqueueUpgradeReaction(Element, Definition);
end;

function ShadowDisabledFor(Element: TElement): Boolean;
var
  Definition: TCustomElementDefinition;
begin
  Result := False;
  if (Element.Flags and NodeFlagCustomCandidate) = 0 then
    Exit;
  Definition := LookUpDefinition(Element.NodeDocument, Element.NamespaceId, Element.LocalNameAtom, Element.IsValue);
  Result := (Definition <> nil) and Definition.DisableShadow;
end;

function IsFormAssociatedCustomElement(Element: TElement): Boolean;
begin
  Result := ((Element.ElementState and ElementStateFormAssociatedCustom) <> 0) and
    (Element.CustomElementState = CustomElementCustom);
end;

procedure CheckFormOwner(Element: TElement);
var
  Data: TCustomElementData;
  Owner: TElement;
begin
  if not IsFormAssociatedCustomElement(Element) then
    Exit;
  Data := CustomDataOf(Element);
  if Element.IsConnected then
    Owner := FormOwner(Element)
  else
    Owner := nil;
  if Data.HasLastFormOwner and (Data.LastFormOwner = Pointer(Owner)) then
    Exit;
  if not Data.HasLastFormOwner and (Owner = nil) then
  begin
    Data.HasLastFormOwner := True;
    Data.LastFormOwner := nil;
    Exit;
  end;
  Data.HasLastFormOwner := True;
  Data.LastFormOwner := Owner;
  EnqueueCallbackReaction(Element, CallbackFormAssociated, [], [], Owner);
end;

{ Upgrades }

procedure ThrowPending(Context: TBindingContext);
begin
  raise EBindingPendingException.Create('');
end;

{ "Upgrade an element" (HTML 4.13.5); script exceptions come out as
  EBindingPendingException (still pending in the runtime). }
procedure UpgradeElement(Element: TElement; Definition: TCustomElementDefinition);
var
  Context: TBindingContext;
  Index: Integer;
  Attribute: PAttributeRecord;
  Wrapper, Result_: TJsValue;
  R: TJsRealm;
  Data: TCustomElementData;
begin
  if not (Element.CustomElementState in [CustomElementUndefined, CustomElementUncustomized]) then
    Exit;
  Context := ContextOfDefinition(Definition);
  if (Context = nil) or Context.Closed then
    Exit;
  R := Context.Engine.Realm;
  Definition.Retain;
  Element.SetCustomElementDefinition(Definition);
  Element.SetCustomElementState(CustomElementFailed);
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    if Definition.Observes(NameOfAtom(Attribute^.LocalName)) then
      EnqueueCallbackReaction(Element, CallbackAttributeChanged,
        [NameOfAtom(Attribute^.LocalName), '', Attribute^.Value, NameOfAtom(NamespaceUri(Attribute^.NamespaceId))],
        [True, False, True, Attribute^.NamespaceId <> NamespaceNone]);
  end;
  if Element.IsConnected then
    EnqueueCallbackReaction(Element, CallbackConnected, [], []);
  SetLength(Definition.ConstructionStack, Length(Definition.ConstructionStack) + 1);
  Definition.ConstructionStack[High(Definition.ConstructionStack)] := Element;
  try
    if Definition.DisableShadow and (Element.ShadowRoot <> nil) then
      RaiseDomError(NotSupportedError, 'the element has a shadow root and its definition disables them');
    Element.SetCustomElementState(CustomElementPrecustomized);
    Context.EnterScript;
    try
      Result_ := R.Construct(Definition.Constructor_, nil, 0, Definition.Constructor_);
    finally
      Context.LeaveScript;
    end;
    if Result_ = JsException then
      ThrowPending(Context);
    Wrapper := Context.WrapNode(Element);
    if Result_ <> Wrapper then
      raise EBindingTypeError.Create('the custom element constructor did not produce the element being upgraded');
  except
    SetLength(Definition.ConstructionStack, Length(Definition.ConstructionStack) - 1);
    Element.SetCustomElementDefinition(nil);
    Data := TCustomElementData(Element.CustomElementData);
    if Data <> nil then
    begin
      for Index := 0 to Data.ReactionCount - 1 do
        ReleaseReaction(Data.Reactions[Index]);
      Data.ReactionCount := 0;
    end;
    raise;
  end;
  SetLength(Definition.ConstructionStack, Length(Definition.ConstructionStack) - 1);
  if Definition.FormAssociated then
  begin
    Element.ElementState := Element.ElementState or ElementStateFormAssociatedCustom;
    Element.SetCustomElementState(CustomElementCustom);
    CheckFormOwner(Element);
    if Element.HasAttributeAtom(AtomDisabled) then
      EnqueueCallbackReaction(Element, CallbackFormDisabled, [], [], nil, nil, True);
  end
  else
    Element.SetCustomElementState(CustomElementCustom);
end;

{ Reports an exception an upgrade or a constructor left. }
procedure ReportThrown(Context: TBindingContext; Error: Exception);
var
  Value: TJsValue;
begin
  if Error is EBindingPendingException then
    Context.ReportPendingException('custom element')
  else
  begin
    Context.ThrowFromException(Error);
    Value := Context.Engine.Runtime.TakeException;
    Context.ReportException(Value, 'custom element');
  end;
end;

procedure RunCallback(Element: TElement; const Reaction: TCustomElementReaction);
var
  Definition: TCustomElementDefinition;
  Context: TBindingContext;
  Args: array of TJsValue;
  Index: Integer;
  Ignored: TJsValue;
begin
  Definition := DefinitionOf(Element);
  Context := ContextOfDefinition(Definition);
  if (Context = nil) or Context.Closed or not JsIsCallable(Definition.Callbacks[Reaction.Callback]) then
    Exit;
  Args := nil;
  case Reaction.Callback of
    CallbackAttributeChanged:
      begin
        SetLength(Args, 4);
        for Index := 0 to 3 do
          Args[Index] := Context.NullableText(Reaction.Texts[Index], not Reaction.Present[Index]);
      end;
    CallbackAdopted:
      Args := [Context.WrapNode(Reaction.Nodes[0]), Context.WrapNode(Reaction.Nodes[1])];
    CallbackFormAssociated:
      Args := [Context.WrapNode(Reaction.Nodes[0])];
    CallbackFormDisabled:
      Args := [JsBoolean(Reaction.Flag)];
    CallbackFormStateRestore:
      Args := [Context.TextValue(Reaction.Texts[0]), Context.TextValue(Reaction.Texts[1])];
  end;
  Context.CallFunction(Definition.Callbacks[Reaction.Callback], Context.WrapNode(Element), Args, Ignored,
    'custom element callback');
end;

{ "Invoke custom element reactions" of an element queue. }
procedure InvokeReactions(const Queue: TElementArray; Count: Integer);
var
  Index: Integer;
  Element: TElement;
  Data: TCustomElementData;
  Reaction: TCustomElementReaction;
  Context: TBindingContext;
begin
  for Index := 0 to Count - 1 do
  begin
    Element := Queue[Index];
    try
      Data := TCustomElementData(Element.CustomElementData);
      while (Data <> nil) and (Data.ReactionCount > 0) do
      begin
        Reaction := Data.Reactions[0];
        Data.Reactions[0] := Default(TCustomElementReaction);
        Move(Data.Reactions[1], Data.Reactions[0], (Data.ReactionCount - 1) * SizeOf(TCustomElementReaction));
        FillChar(Data.Reactions[Data.ReactionCount - 1], SizeOf(TCustomElementReaction), 0);
        Dec(Data.ReactionCount);
        try
          if Reaction.Kind = ReactionUpgrade then
          begin
            Context := ContextOfDefinition(Reaction.Definition);
            if Context <> nil then
              try
                UpgradeElement(Element, Reaction.Definition);
              except
                on Error: Exception do
                  ReportThrown(Context, Error);
              end;
          end
          else
            RunCallback(Element, Reaction);
        finally
          ReleaseReaction(Reaction);
        end;
        Data := TCustomElementData(Element.CustomElementData);
      end;
    finally
      Element.Release;
    end;
  end;
end;

procedure EnterReactionsScope;
begin
  if StackDepth >= Length(QueueStack) then
  begin
    SetLength(QueueStack, StackDepth * 2 + 8);
    SetLength(QueueCounts, Length(QueueStack));
  end;
  QueueCounts[StackDepth] := 0;
  Inc(StackDepth);
end;

{ Pops the current element queue and runs its reactions; an exception
  pending in Context's runtime waits meanwhile. }
procedure LeaveReactionsScope(Context: TBindingContext);
var
  Queue: TElementArray;
  Count, Mark: Integer;
  Runtime: TJsRuntime;
  Pending: Boolean;
  Thrown: TJsValue;
begin
  if StackDepth = 0 then
    Exit;
  Dec(StackDepth);
  Count := QueueCounts[StackDepth];
  if Count = 0 then
    Exit;
  Queue := QueueStack[StackDepth];
  QueueStack[StackDepth] := nil;
  QueueCounts[StackDepth] := 0;
  Runtime := nil;
  Pending := False;
  Thrown := JsUndefined;
  Mark := 0;
  if (Context <> nil) and (Context.Engine <> nil) then
  begin
    Runtime := Context.Engine.Runtime;
    Pending := Runtime.HasException;
    if Pending then
    begin
      Thrown := Runtime.TakeException;
      Mark := Runtime.PushRoot(Thrown);
    end;
  end;
  try
    InvokeReactions(Queue, Count);
  finally
    if Pending then
    begin
      Runtime.PopRoots(Mark);
      if Runtime.HasException then
        Runtime.TakeException;
      Runtime.Exception := Thrown;
      Runtime.HasException := True;
    end;
  end;
end;

{ The DOM's custom element host. }

type
  TRegistryHost = class(TCustomElementHost)
  public
    procedure ElementConnected(Element: TElement); override;
    procedure ElementDisconnected(Element: TElement); override;
    procedure ElementAdopted(Element: TElement; OldDocument, NewDocument: TDocument); override;
    procedure ElementAttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue, NewValue: string; HadOldValue, HasNewValue: Boolean); override;
    function CreateElement(Document: TDocument; LocalName: TAtom; NamespaceId: TNamespaceId;
      const IsValue: string; Synchronous: Boolean): TElement; override;
    function HasDefinitions(Document: TDocument): Boolean; override;
    procedure PushReactionsScope; override;
    procedure PopReactionsScope; override;
    procedure ReleaseDefinition(Definition: TObject); override;
  end;

procedure TRegistryHost.ElementConnected(Element: TElement);
begin
  if DefinitionCount = 0 then
    Exit;
  if Element.CustomElementState = CustomElementCustom then
  begin
    EnqueueCallbackReaction(Element, CallbackConnected, [], []);
    CheckFormOwner(Element);
  end
  else
    TryToUpgrade(Element);
end;

procedure TRegistryHost.ElementDisconnected(Element: TElement);
begin
  if Element.CustomElementState <> CustomElementCustom then
    Exit;
  EnqueueCallbackReaction(Element, CallbackDisconnected, [], []);
  CheckFormOwner(Element);
end;

procedure TRegistryHost.ElementAdopted(Element: TElement; OldDocument, NewDocument: TDocument);
begin
  if Element.CustomElementState = CustomElementCustom then
    EnqueueCallbackReaction(Element, CallbackAdopted, [], [], OldDocument, NewDocument);
end;

procedure TRegistryHost.ElementAttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue, NewValue: string; HadOldValue, HasNewValue: Boolean);
var
  Definition: TCustomElementDefinition;
begin
  Definition := DefinitionOf(Element);
  if Definition = nil then
    Exit;
  if Definition.Observes(NameOfAtom(LocalName)) then
    EnqueueCallbackReaction(Element, CallbackAttributeChanged,
      [NameOfAtom(LocalName), OldValue, NewValue, NameOfAtom(Web.Namespaces.NamespaceUri(NamespaceId))],
      [True, HadOldValue, HasNewValue, NamespaceId <> NamespaceNone]);
  if IsFormAssociatedCustomElement(Element) and (LocalName = AtomDisabled) and (NamespaceId = NamespaceNone) and
    (HadOldValue <> HasNewValue) then
    EnqueueCallbackReaction(Element, CallbackFormDisabled, [], [], nil, nil, HasNewValue);
end;

{ An element of Definition made without running its constructor (an
  upgrade follows). }
function NewUndefinedElement(Document: TDocument; LocalName: TAtom; NamespaceId: TNamespaceId;
  const IsValue: string): TElement;
begin
  Result := Document.NewElement(LocalName, NamespaceId);
  if IsValue <> '' then
    Result.SetIsValue(IsValue);
  Result.SetCustomElementState(CustomElementUndefined);
end;

{ The DOM Standard's "create an element" when a definition applies. }
function TRegistryHost.CreateElement(Document: TDocument; LocalName: TAtom; NamespaceId: TNamespaceId;
  const IsValue: string; Synchronous: Boolean): TElement;
var
  Definition: TCustomElementDefinition;
  Context: TBindingContext;
  Value: TJsValue;
  Native: TObject;
  Element: TElement;
begin
  Result := nil;
  Definition := LookUpDefinition(Document, NamespaceId, LocalName, IsValue);
  if Definition = nil then
    Exit;
  Context := ContextOfDefinition(Definition);
  if not Definition.IsAutonomous then
  begin
    Result := NewUndefinedElement(Document, LocalName, NamespaceId, Definition.Name);
    if Synchronous then
      try
        UpgradeElement(Result, Definition);
      except
        on Error: Exception do
          ReportThrown(Context, Error);
      end
    else
      EnqueueUpgradeReaction(Result, Definition);
    Exit;
  end;
  if not Synchronous then
  begin
    Result := NewUndefinedElement(Document, LocalName, NamespaceId, '');
    EnqueueUpgradeReaction(Result, Definition);
    Exit;
  end;
  { Synchronous: the constructor makes the element (HTMLConstructor with
    an empty construction stack), which must be a fresh element. }
  try
    Context.EnterScript;
    try
      Value := Context.Engine.Realm.Construct(Definition.Constructor_, nil, 0, Definition.Constructor_);
    finally
      Context.LeaveScript;
    end;
    if Value = JsException then
      raise EBindingPendingException.Create('');
    Native := Context.Unwrap(Value, InterfaceHTMLElement);
    if not (Native is TElement) then
      raise EBindingTypeError.Create('the custom element constructor did not return an HTMLElement');
    Element := TElement(Native);
    if (Element.AttributeCount > 0) or Element.HasChildNodes or (Element.ParentNode <> nil) or
      (Element.NodeDocument <> Document) or (Element.LocalNameAtom <> LocalName) or
      (Element.NamespaceId <> NamespaceId) then
      RaiseDomError(NotSupportedError, 'the custom element constructor returned an unsuitable element');
    Result := Element;
  except
    on Error: Exception do
    begin
      ReportThrown(Context, Error);
      Result := Document.NewElement(LocalName, NamespaceId);
      Result.SetCustomElementState(CustomElementFailed);
    end;
  end;
end;

function TRegistryHost.HasDefinitions(Document: TDocument): Boolean;
var
  Registry: TCustomElementRegistry;
begin
  if DefinitionCount = 0 then
    Exit(False);
  Registry := RegistryOfDocument(Document);
  Result := (Registry <> nil) and (Length(Registry.FDefinitions) > 0);
end;

procedure TRegistryHost.PushReactionsScope;
begin
  EnterReactionsScope;
end;

procedure TRegistryHost.PopReactionsScope;
begin
  LeaveReactionsScope(nil);
end;

procedure TRegistryHost.ReleaseDefinition(Definition: TObject);
begin
  TCustomElementDefinition(Definition).Release;
end;

initialization
  AddContextGoingHook(@ContextGoing);
  CustomElementHost := TRegistryHost.Create;
finalization
  FreeAndNil(CustomElementHost);
end.
