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
  bindings/MutationObservers.webidl: MutationObserver and MutationRecord
  (DOM Standard 4.3) over the document observer's records.

  TMutationObservers (one per context) keeps the registrations (an
  observer, a node it retains, the options; transient registrations
  for removed nodes of observed subtrees) and queues records as the
  document observer reports changes: for each inclusive ancestor of the
  target, the registrations interested in the change, one record per
  observer with the old value if one of them asked. The first record
  queues the mutation observer microtask (a libjavascript job), which
  calls each observer with its records.

  Observers with registrations or records are kept alive by the
  context's heap (a root provider), as nodes keep their observers in
  the standard; disconnect() lets one go.
}
unit Web.Bindings.MutationObservers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Dom.Events,
  Web.Bindings.Types,
  Web.Bindings.Context;

{$I Web.Bindings.MutationObservers.Members.inc}

type
  TMutationObserverData = class;

  TMutationRecordData = class
  public
    Kind: string;
    Target: TNode;
    Added: TNodeArray;
    Removed: TNodeArray;
    PreviousSibling: TNode;
    NextSibling: TNode;
    AttributeName: string;
    HasAttributeName: Boolean;
    AttributeNamespace: string;
    OldValue: string;
    HasOldValue: Boolean;
    constructor Create(const AKind: string; ATarget: TNode);
    destructor Destroy; override;
  end;

  TMutationRegistration = record
    Observer: TMutationObserverData;
    Node: TNode;
    ChildList: Boolean;
    Attributes: Boolean;
    CharacterData: Boolean;
    Subtree: Boolean;
    AttributeOldValue: Boolean;
    CharacterDataOldValue: Boolean;
    HasFilter: Boolean;
    AttributeFilter: TStringArray;
    { A transient registration: the registration whose subtree the
      removed node was in. }
    Transient: Boolean;
  end;

  TMutationObserverData = class
  public
    Context: TBindingContext;
    Callback: TJsValue;
    Wrapper: TJsValue;
    Records: array of TMutationRecordData;
    destructor Destroy; override;
    procedure ClearRecords;
  end;

  TMutationObservers = class
  private
    FContext: TBindingContext;
    FObservers: array of TMutationObserverData;
    FRegistrations: array of TMutationRegistration;
    FMicrotaskQueued: Boolean;
    { The signal slots (DOM Standard): slotchange is due at each; held. }
    FSignalSlots: array of TElement;
    procedure MarkRoots(Tracer: TJsTracer);
    procedure FireSlotChanges(const Slots: array of TElement);
    procedure RemoveRegistrationAt(Index: Integer);
    procedure QueueRecordFor(Observer: TMutationObserverData; Template: TMutationRecordData; WithOldValue: Boolean);
    procedure QueueMicrotask;
  public
    constructor Create(Context: TBindingContext);
    destructor Destroy; override;
    procedure AddObserver(Observer: TMutationObserverData);
    procedure RemoveObserver(Observer: TMutationObserverData);
    procedure Observe(Observer: TMutationObserverData; const Registration: TMutationRegistration);
    procedure Disconnect(Observer: TMutationObserverData);
    function HasRegistrations: Boolean; inline;
    { The document observer's changes. }
    procedure TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling, NextSibling: TNode);
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean);
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string);
    { The mutation observer microtask. }
    procedure NotifyObservers;
    { "Signal a slot change": Slot joins the signal slots. }
    procedure SignalSlot(Slot: TElement);
  end;

{ The context's mutation observers, made on first use. }
function MutationObserversOf(Context: TBindingContext): TMutationObservers;

implementation

uses
  Js.Objects,
  Js.Runtime;

procedure RetainNode(Node: TNode); inline;
begin
  if Node <> nil then
    Node.Retain;
end;

procedure ReleaseNode(Node: TNode); inline;
begin
  if Node <> nil then
    Node.Release;
end;

{ TMutationRecordData }

constructor TMutationRecordData.Create(const AKind: string; ATarget: TNode);
begin
  inherited Create;
  Kind := AKind;
  Target := ATarget;
  RetainNode(Target);
end;

destructor TMutationRecordData.Destroy;
var
  Index: Integer;
begin
  ReleaseNode(Target);
  for Index := 0 to High(Added) do
    ReleaseNode(Added[Index]);
  for Index := 0 to High(Removed) do
    ReleaseNode(Removed[Index]);
  ReleaseNode(PreviousSibling);
  ReleaseNode(NextSibling);
  inherited Destroy;
end;

function CopyRecord(Template: TMutationRecordData; WithOldValue: Boolean): TMutationRecordData;
var
  Index: Integer;
begin
  Result := TMutationRecordData.Create(Template.Kind, Template.Target);
  Result.Added := Copy(Template.Added);
  for Index := 0 to High(Result.Added) do
    RetainNode(Result.Added[Index]);
  Result.Removed := Copy(Template.Removed);
  for Index := 0 to High(Result.Removed) do
    RetainNode(Result.Removed[Index]);
  Result.PreviousSibling := Template.PreviousSibling;
  RetainNode(Result.PreviousSibling);
  Result.NextSibling := Template.NextSibling;
  RetainNode(Result.NextSibling);
  Result.AttributeName := Template.AttributeName;
  Result.HasAttributeName := Template.HasAttributeName;
  Result.AttributeNamespace := Template.AttributeNamespace;
  if WithOldValue then
  begin
    Result.OldValue := Template.OldValue;
    Result.HasOldValue := Template.HasOldValue;
  end;
end;

{ TMutationObserverData }

destructor TMutationObserverData.Destroy;
begin
  ClearRecords;
  if (Context <> nil) and (Context.MutationObservers <> nil) then
    TMutationObservers(Context.MutationObservers).RemoveObserver(Self);
  inherited Destroy;
end;

procedure TMutationObserverData.ClearRecords;
var
  Index: Integer;
begin
  for Index := 0 to High(Records) do
    Records[Index].Free;
  Records := nil;
end;

{ TMutationObservers }

function MutationObserversOf(Context: TBindingContext): TMutationObservers;
begin
  if Context.MutationObservers = nil then
    Context.MutationObservers := TMutationObservers.Create(Context);
  Result := TMutationObservers(Context.MutationObservers);
end;

constructor TMutationObservers.Create(Context: TBindingContext);
begin
  inherited Create;
  FContext := Context;
  Context.Engine.Runtime.Heap.AddRootProvider(@MarkRoots);
end;

destructor TMutationObservers.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FRegistrations) do
    ReleaseNode(FRegistrations[Index].Node);
  FRegistrations := nil;
  for Index := 0 to High(FSignalSlots) do
    ReleaseNode(FSignalSlots[Index]);
  FSignalSlots := nil;
  for Index := 0 to High(FObservers) do
    FObservers[Index].Context := nil;
  if FContext.Engine <> nil then
    FContext.Engine.Runtime.Heap.RemoveRootProvider(@MarkRoots);
  inherited Destroy;
end;

procedure TMutationObservers.MarkRoots(Tracer: TJsTracer);
var
  Index: Integer;
begin
  for Index := 0 to High(FObservers) do
  begin
    Tracer.MarkValue(FObservers[Index].Callback);
    if Length(FObservers[Index].Records) > 0 then
      Tracer.MarkValue(FObservers[Index].Wrapper);
  end;
  for Index := 0 to High(FRegistrations) do
    Tracer.MarkValue(FRegistrations[Index].Observer.Wrapper);
end;

procedure TMutationObservers.AddObserver(Observer: TMutationObserverData);
begin
  SetLength(FObservers, Length(FObservers) + 1);
  FObservers[High(FObservers)] := Observer;
end;

procedure TMutationObservers.RemoveObserver(Observer: TMutationObserverData);
var
  Index: Integer;
begin
  Disconnect(Observer);
  for Index := 0 to High(FObservers) do
    if FObservers[Index] = Observer then
    begin
      if Index < High(FObservers) then
        Move(FObservers[Index + 1], FObservers[Index], (High(FObservers) - Index) * SizeOf(Pointer));
      SetLength(FObservers, High(FObservers));
      Exit;
    end;
end;

procedure TMutationObservers.RemoveRegistrationAt(Index: Integer);
begin
  ReleaseNode(FRegistrations[Index].Node);
  FRegistrations[Index] := FRegistrations[High(FRegistrations)];
  SetLength(FRegistrations, High(FRegistrations));
end;

procedure TMutationObservers.Observe(Observer: TMutationObserverData; const Registration: TMutationRegistration);
var
  Index, Transient: Integer;
begin
  for Index := 0 to High(FRegistrations) do
    if (FRegistrations[Index].Observer = Observer) and (FRegistrations[Index].Node = Registration.Node) and
      not FRegistrations[Index].Transient then
    begin
      { Observing a node again replaces the options; the observer's
        transient registrations go. }
      ReleaseNode(FRegistrations[Index].Node);
      FRegistrations[Index] := Registration;
      RetainNode(Registration.Node);
      Transient := High(FRegistrations);
      while Transient >= 0 do
      begin
        if (FRegistrations[Transient].Observer = Observer) and FRegistrations[Transient].Transient then
          RemoveRegistrationAt(Transient);
        Dec(Transient);
      end;
      Exit;
    end;
  SetLength(FRegistrations, Length(FRegistrations) + 1);
  FRegistrations[High(FRegistrations)] := Registration;
  RetainNode(Registration.Node);
end;

procedure TMutationObservers.Disconnect(Observer: TMutationObserverData);
var
  Index: Integer;
begin
  Index := High(FRegistrations);
  while Index >= 0 do
  begin
    if FRegistrations[Index].Observer = Observer then
      RemoveRegistrationAt(Index);
    Dec(Index);
  end;
  Observer.ClearRecords;
end;

function TMutationObservers.HasRegistrations: Boolean;
begin
  Result := Length(FRegistrations) > 0;
end;

procedure MutationObserverMicrotask(R: TJsRealm; const Values: array of TJsValue);
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  if (Context <> nil) and (Context.MutationObservers <> nil) then
    TMutationObservers(Context.MutationObservers).NotifyObservers;
end;

procedure TMutationObservers.QueueMicrotask;
begin
  if FMicrotaskQueued then
    Exit;
  FMicrotaskQueued := True;
  FContext.Engine.Realm.EnqueueJob(@MutationObserverMicrotask, JsUndefined, JsUndefined, JsUndefined, JsUndefined);
end;

procedure TMutationObservers.QueueRecordFor(Observer: TMutationObserverData; Template: TMutationRecordData;
  WithOldValue: Boolean);
begin
  SetLength(Observer.Records, Length(Observer.Records) + 1);
  Observer.Records[High(Observer.Records)] := CopyRecord(Template, WithOldValue);
  QueueMicrotask;
end;

function IsInclusiveAncestorFor(Ancestor, Node: TNode; Subtree: Boolean): Boolean;
var
  Walk: TNode;
begin
  if Ancestor = Node then
    Exit(True);
  if not Subtree then
    Exit(False);
  Walk := Node;
  while Walk <> nil do
  begin
    if Walk = Ancestor then
      Exit(True);
    if Walk.NodeType = NodeTypeAttribute then
      Walk := TAttr(Walk).OwnerElement
    else
      Walk := Walk.ParentNode;
  end;
  Result := False;
end;

function FilterAllows(const Registration: TMutationRegistration; const Name: string): Boolean;
var
  Index: Integer;
begin
  if not Registration.HasFilter then
    Exit(True);
  for Index := 0 to High(Registration.AttributeFilter) do
    if Registration.AttributeFilter[Index] = Name then
      Exit(True);
  Result := False;
end;

type
  TInterest = record
    Observer: TMutationObserverData;
    WithOldValue: Boolean;
  end;

{ The standard's "queue a mutation record": the interested observers
  of the registrations on the target's inclusive ancestors. }
procedure QueueTemplate(Manager: TMutationObservers; Template: TMutationRecordData;
  const Registrations: array of TMutationRegistration; Observers: array of TMutationObserverData);
var
  Interests: array of TInterest;
  Index, Found, Position: Integer;
  Registration: ^TMutationRegistration;
  Interested, WantsOld: Boolean;
begin
  Interests := nil;
  for Index := 0 to High(Registrations) do
  begin
    Registration := @Registrations[Index];
    if not IsInclusiveAncestorFor(Registration^.Node, Template.Target, Registration^.Subtree) then
      Continue;
    if (Registration^.Node <> Template.Target) and not Registration^.Subtree then
      Continue;
    if Template.Kind = 'attributes' then
      Interested := Registration^.Attributes and (not Registration^.HasFilter or
        (Template.AttributeNamespace = '') and FilterAllows(Registration^, Template.AttributeName))
    else if Template.Kind = 'characterData' then
      Interested := Registration^.CharacterData
    else
      Interested := Registration^.ChildList;
    if not Interested then
      Continue;
    if Template.Kind = 'attributes' then
      WantsOld := Registration^.AttributeOldValue
    else if Template.Kind = 'characterData' then
      WantsOld := Registration^.CharacterDataOldValue
    else
      WantsOld := False;
    Found := -1;
    for Position := 0 to High(Interests) do
      if Interests[Position].Observer = Registration^.Observer then
        Found := Position;
    if Found < 0 then
    begin
      SetLength(Interests, Length(Interests) + 1);
      Found := High(Interests);
      Interests[Found].Observer := Registration^.Observer;
      Interests[Found].WithOldValue := False;
    end;
    if WantsOld then
      Interests[Found].WithOldValue := True;
  end;
  for Index := 0 to High(Interests) do
    Manager.QueueRecordFor(Interests[Index].Observer, Template, Interests[Index].WithOldValue);
end;

procedure TMutationObservers.TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling,
  NextSibling: TNode);
var
  Template: TMutationRecordData;
  Index, Count, RemovedIndex: Integer;
  Transient: TMutationRegistration;
begin
  if Length(FRegistrations) = 0 then
    Exit;
  { Removed nodes of an observed subtree stay observed (transiently)
    until the observers are notified. }
  Count := Length(FRegistrations);
  for Index := 0 to Count - 1 do
    if FRegistrations[Index].Subtree and IsInclusiveAncestorFor(FRegistrations[Index].Node, Target, True) then
      for RemovedIndex := 0 to High(Removed) do
      begin
        Transient := FRegistrations[Index];
        Transient.Node := Removed[RemovedIndex];
        Transient.Transient := True;
        SetLength(FRegistrations, Length(FRegistrations) + 1);
        FRegistrations[High(FRegistrations)] := Transient;
        RetainNode(Transient.Node);
      end;
  Template := TMutationRecordData.Create('childList', Target);
  try
    Template.Added := Added;
    Template.Removed := Removed;
    Template.PreviousSibling := PreviousSibling;
    Template.NextSibling := NextSibling;
    for Index := 0 to High(Added) do
      RetainNode(Added[Index]);
    for Index := 0 to High(Removed) do
      RetainNode(Removed[Index]);
    RetainNode(PreviousSibling);
    RetainNode(NextSibling);
    QueueTemplate(Self, Template, FRegistrations, FObservers);
  finally
    Template.Free;
  end;
end;

procedure TMutationObservers.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
var
  Template: TMutationRecordData;
begin
  if Length(FRegistrations) = 0 then
    Exit;
  Template := TMutationRecordData.Create('attributes', Element);
  try
    Template.AttributeName := NameOfAtom(LocalName);
    Template.HasAttributeName := True;
    if NamespaceId <> NamespaceNone then
      Template.AttributeNamespace := NameOfAtom(NamespaceUri(NamespaceId));
    Template.OldValue := OldValue;
    Template.HasOldValue := HadValue;
    QueueTemplate(Self, Template, FRegistrations, FObservers);
  finally
    Template.Free;
  end;
end;

procedure TMutationObservers.CharacterDataChanged(Node: TCharacterData; const OldValue: string);
var
  Template: TMutationRecordData;
begin
  if Length(FRegistrations) = 0 then
    Exit;
  Template := TMutationRecordData.Create('characterData', Node);
  try
    Template.OldValue := OldValue;
    Template.HasOldValue := True;
    QueueTemplate(Self, Template, FRegistrations, FObservers);
  finally
    Template.Free;
  end;
end;

function RecordsArray(Context: TBindingContext; Observer: TMutationObserverData): TJsValue;
var
  Items: TJsValueList;
  Index, Mark: Integer;
begin
  Items := nil;
  SetLength(Items, Length(Observer.Records));
  Mark := Context.Engine.Runtime.PushRoot(JsUndefined);
  try
    for Index := 0 to High(Observer.Records) do
    begin
      Items[Index] := Context.WrapObject(Observer.Records[Index], InterfaceMutationRecord, True, JsUndefined);
      Context.Engine.Runtime.PushRoot(Items[Index]);
    end;
    { The wrappers own the records now. }
    Observer.Records := nil;
    Result := Context.NewArray(Items);
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

procedure TMutationObservers.SignalSlot(Slot: TElement);
var
  Index: Integer;
begin
  for Index := 0 to High(FSignalSlots) do
    if FSignalSlots[Index] = Slot then
      Exit;
  RetainNode(Slot);
  SetLength(FSignalSlots, Length(FSignalSlots) + 1);
  FSignalSlots[High(FSignalSlots)] := Slot;
  QueueMicrotask;
end;

{ The slotchange events of the signal slots taken (bubbling, at each
  slot in the order they were signaled). }
procedure TMutationObservers.FireSlotChanges(const Slots: array of TElement);
var
  Index: Integer;
  Event: TEvent;
begin
  for Index := 0 to High(Slots) do
  begin
    Event := TEvent.Create('slotchange', True, False);
    try
      Event.IsTrusted := True;
      Slots[Index].DispatchEvent(Event);
    finally
      Event.Release;
    end;
  end;
  for Index := 0 to High(Slots) do
    ReleaseNode(Slots[Index]);
end;

procedure TMutationObservers.NotifyObservers;
var
  Pending: array of TMutationObserverData;
  Index, Position: Integer;
  Observer: TMutationObserverData;
  Records, Ignored: TJsValue;
  Mark: Integer;
  SignalSet: array of TElement;
begin
  FMicrotaskQueued := False;
  Pending := Copy(FObservers);
  { The signal slots are taken now; their events fire after the
    observers' callbacks. }
  SignalSet := FSignalSlots;
  FSignalSlots := nil;
  for Index := 0 to High(Pending) do
  begin
    Observer := Pending[Index];
    Position := High(FRegistrations);
    while Position >= 0 do
    begin
      if (FRegistrations[Position].Observer = Observer) and FRegistrations[Position].Transient then
        RemoveRegistrationAt(Position);
      Dec(Position);
    end;
    if Length(Observer.Records) = 0 then
      Continue;
    Mark := FContext.Engine.Runtime.PushRoot(Observer.Wrapper);
    try
      Records := RecordsArray(FContext, Observer);
      FContext.Engine.Runtime.PushRoot(Records);
      FContext.CallFunction(Observer.Callback, Observer.Wrapper, [Records, Observer.Wrapper], Ignored,
        'mutation observer');
    finally
      FContext.Engine.Runtime.PopRoots(Mark);
    end;
  end;
  { Slots signaled while the callbacks ran have queued the next
    microtask. }
  FireSlotChanges(SignalSet);
end;

{ MutationObserver }

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function ThisObserver(const Call: TBindingCall): TMutationObserverData; inline;
begin
  Result := TMutationObserverData(Call.Target);
end;

function MutationObserver_constructor(var Call: TBindingCall): TJsValue;
var
  Observer: TMutationObserverData;
begin
  Observer := TMutationObserverData.Create;
  Observer.Context := Context(Call);
  Observer.Callback := Call.Script(0);
  Result := Context(Call).ConstructedObject(Call, Observer);
  Observer.Wrapper := Result;
  MutationObserversOf(Context(Call)).AddObserver(Observer);
end;

function MutationObserver_observe(var Call: TBindingCall): TJsValue;
var
  Options: PBindingValue;
  Registration: TMutationRegistration;
  Index: Integer;
begin
  Options := @Call.Arguments[1];
  Registration.Observer := ThisObserver(Call);
  Registration.Node := TNode(Call.Native(0));
  Registration.ChildList := Options^.Items[MutationObserverInit_childList].Flag;
  Registration.Subtree := Options^.Items[MutationObserverInit_subtree].Flag;
  Registration.AttributeOldValue := Options^.Items[MutationObserverInit_attributeOldValue].Flag;
  Registration.CharacterDataOldValue := Options^.Items[MutationObserverInit_characterDataOldValue].Flag;
  Registration.HasFilter := Options^.Items[MutationObserverInit_attributeFilter].Kind = bvSequence;
  Registration.AttributeFilter := nil;
  if Registration.HasFilter then
  begin
    SetLength(Registration.AttributeFilter, Length(Options^.Items[MutationObserverInit_attributeFilter].Items));
    for Index := 0 to High(Registration.AttributeFilter) do
      Registration.AttributeFilter[Index] := Options^.Items[MutationObserverInit_attributeFilter].Items[Index].Text;
  end;
  if Options^.Items[MutationObserverInit_attributes].Kind = bvBoolean then
    Registration.Attributes := Options^.Items[MutationObserverInit_attributes].Flag
  else
    Registration.Attributes := Registration.AttributeOldValue or Registration.HasFilter;
  if Options^.Items[MutationObserverInit_characterData].Kind = bvBoolean then
    Registration.CharacterData := Options^.Items[MutationObserverInit_characterData].Flag
  else
    Registration.CharacterData := Registration.CharacterDataOldValue;
  Registration.Transient := False;
  if not Registration.ChildList and not Registration.Attributes and not Registration.CharacterData then
    raise EBindingTypeError.Create('observe needs childList, attributes or characterData');
  if Registration.AttributeOldValue and not Registration.Attributes then
    raise EBindingTypeError.Create('attributeOldValue needs attributes');
  if Registration.HasFilter and not Registration.Attributes then
    raise EBindingTypeError.Create('attributeFilter needs attributes');
  if Registration.CharacterDataOldValue and not Registration.CharacterData then
    raise EBindingTypeError.Create('characterDataOldValue needs characterData');
  MutationObserversOf(Context(Call)).Observe(ThisObserver(Call), Registration);
  Result := JsUndefined;
end;

function MutationObserver_disconnect(var Call: TBindingCall): TJsValue;
begin
  MutationObserversOf(Context(Call)).Disconnect(ThisObserver(Call));
  Result := JsUndefined;
end;

function MutationObserver_takeRecords(var Call: TBindingCall): TJsValue;
begin
  Result := RecordsArray(Context(Call), ThisObserver(Call));
end;

{ MutationRecord }

function ThisRecord(const Call: TBindingCall): TMutationRecordData; inline;
begin
  Result := TMutationRecordData(Call.Target);
end;

function MutationRecord_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisRecord(Call).Kind);
end;

function MutationRecord_get_target(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisRecord(Call).Target);
end;

function MutationRecord_get_addedNodes(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(TStaticNodeList.Create(ThisRecord(Call).Added), InterfaceNodeList, True,
    JsUndefined);
end;

function MutationRecord_get_removedNodes(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(TStaticNodeList.Create(ThisRecord(Call).Removed), InterfaceNodeList, True,
    JsUndefined);
end;

function MutationRecord_get_previousSibling(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisRecord(Call).PreviousSibling);
end;

function MutationRecord_get_nextSibling(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisRecord(Call).NextSibling);
end;

function MutationRecord_get_attributeName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisRecord(Call).AttributeName, not ThisRecord(Call).HasAttributeName);
end;

function MutationRecord_get_attributeNamespace(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisRecord(Call).AttributeNamespace, ThisRecord(Call).AttributeNamespace = '');
end;

function MutationRecord_get_oldValue(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisRecord(Call).OldValue, not ThisRecord(Call).HasOldValue);
end;

end.
