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
  bindings/CustomElements.webidl: CustomElementRegistry (define, get,
  getName, whenDefined, upgrade), window.customElements, the
  [HTMLConstructor] steps every HTML element interface's constructor
  shares, attachInternals and ElementInternals (form-associated custom
  elements: form value and state, validity, labels, the form owner;
  custom states; ARIA values), ValidityState and CustomStateSet. The
  registry, reactions and upgrades are Web.Bindings.CustomElementRegistry.
}
unit Web.Bindings.CustomElements;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Web.Dom,
  Web.Bindings.Types;

{$I Web.Bindings.CustomElements.Members.inc}

{ For the form code (Web.Bindings.HtmlElements): a form-associated
  custom element's entries, validity, and reset. }
procedure CustomElementFormEntries(Element: TElement; var Names, Values: TStringArray);
function CustomElementValid(Element: TElement): Boolean;
procedure CustomElementFormReset(Element: TElement);

implementation

uses
  Js.Objects,
  Js.Functions,
  Js.Operations,
  Js.Promises,
  Js.Runtime,
  Js.Conversions,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Events,
  Web.Dom.Exceptions,
  Web.Dom.FormControls,
  Web.Bindings.Context,
  Web.Bindings.CustomElementRegistry;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function ThisRegistry(const Call: TBindingCall): TCustomElementRegistry; inline;
begin
  Result := TCustomElementRegistry(Call.Target);
end;

function Pending: TJsValue;
begin
  raise EBindingPendingException.Create('');
  Result := JsException;
end;

{ Get(Value, Name), script exceptions passed on. }
function GetValue(const Call: TBindingCall; Target: TJsValue; const Name: string): TJsValue;
begin
  Result := GetProperty(Call.Realm, Target, Call.Realm.Intern(Name));
  if Result = JsException then
    Result := Pending;
end;

{ A sequence<DOMString> from an iterable (through Array.from). }
function StringSequence(const Call: TBindingCall; Value: TJsValue): TStringArray;
var
  ArrayConstructor, FromFunction, Items, Count: TJsValue;
  Index, Length_: Integer;
begin
  Result := nil;
  if Value = JsUndefined then
    Exit;
  ArrayConstructor := GetValue(Call, JsObjectValue(Context(Call).Engine.GlobalObject), 'Array');
  FromFunction := GetValue(Call, ArrayConstructor, 'from');
  Items := Call.Realm.Call(FromFunction, ArrayConstructor, @Value, 1);
  if Items = JsException then
    Pending;
  Count := GetValue(Call, Items, 'length');
  Length_ := Trunc(Context(Call).Engine.ToNumber(Count));
  SetLength(Result, Length_);
  for Index := 0 to Length_ - 1 do
    Result[Index] := ValueToText(Call.Realm, GetValue(Call, Items, IntToStr(Index)));
end;

function SequenceContains(const Items: TStringArray; const Item: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Items) do
    if Items[Index] = Item then
      Exit(True);
  Result := False;
end;

{ The element interface (by the binding tables) of an HTML local name;
  HTMLUnknownElement for one that has none. }
function ElementInterfaceOf(Context: TBindingContext; const LocalName: string): Integer;
var
  Atom: TAtom;
begin
  Atom := FindAtom(LocalName);
  if (Atom <> AtomNone) and (Atom < LongWord(Length(Context.ElementInterfaces))) and
    (Context.ElementInterfaces[Atom] >= 0) then
    Result := Context.ElementInterfaces[Atom]
  else
    Result := InterfaceHTMLUnknownElement;
end;

const
  LifecycleNames: array[TCustomElementCallback] of string = ('connectedCallback', 'disconnectedCallback',
    'adoptedCallback', 'attributeChangedCallback', 'formAssociatedCallback', 'formResetCallback',
    'formDisabledCallback', 'formStateRestoreCallback');

{ Reads the definition's callbacks and options from the constructor
  (HTML: define(), step 14). }
procedure ReadDefinition(const Call: TBindingCall; Definition: TCustomElementDefinition);
var
  Callback: TCustomElementCallback;
  Value: TJsValue;
  Disabled: TStringArray;
begin
  Definition.Prototype := GetValue(Call, Definition.Constructor_, 'prototype');
  if not JsIsObject(Definition.Prototype) then
    raise EBindingTypeError.Create('the custom element constructor''s prototype is not an object');
  for Callback := CallbackConnected to CallbackAttributeChanged do
  begin
    Value := GetValue(Call, Definition.Prototype, LifecycleNames[Callback]);
    if (Value <> JsUndefined) and not JsIsCallable(Value) then
      raise EBindingTypeError.Create(LifecycleNames[Callback] + ' is not a function');
    Definition.Callbacks[Callback] := Value;
  end;
  if Definition.Callbacks[CallbackAttributeChanged] <> JsUndefined then
    Definition.ObservedAttributes := StringSequence(Call, GetValue(Call, Definition.Constructor_,
      'observedAttributes'));
  Disabled := StringSequence(Call, GetValue(Call, Definition.Constructor_, 'disabledFeatures'));
  Definition.DisableInternals := SequenceContains(Disabled, 'internals');
  Definition.DisableShadow := SequenceContains(Disabled, 'shadow');
  Definition.FormAssociated := Js.Conversions.ToBoolean(GetValue(Call, Definition.Constructor_, 'formAssociated'));
  if Definition.FormAssociated then
    for Callback := CallbackFormAssociated to CallbackFormStateRestore do
    begin
      Value := GetValue(Call, Definition.Prototype, LifecycleNames[Callback]);
      if (Value <> JsUndefined) and not JsIsCallable(Value) then
        raise EBindingTypeError.Create(LifecycleNames[Callback] + ' is not a function');
      Definition.Callbacks[Callback] := Value;
    end;
end;

{ The elements define() upgrades: the document's shadow-including
  descendants of the definition's name, in shadow-including order. }
procedure UpgradeCandidates(Document: TDocument; Definition: TCustomElementDefinition);
var
  Node: TNode;
  Element: TElement;
begin
  Node := Document;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      if (Element.LocalNameAtom = Definition.LocalNameAtom) and (Element.NamespaceId = NamespaceHtml) and
        (Definition.IsAutonomous or (Element.IsValue = Definition.Name)) and
        (Element.CustomElementState in [CustomElementUndefined, CustomElementUncustomized]) then
        EnqueueUpgradeReaction(Element, Definition);
    end;
    Node := Node.NextInShadowIncludingTree(Document);
  end;
end;

{ CustomElementRegistry }

function CustomElementRegistry_define(var Call: TBindingCall): TJsValue;
var
  Registry: TCustomElementRegistry;
  Name, LocalName, Extends: string;
  Constructor_, Promise: TJsValue;
  Definition: TCustomElementDefinition;
  Options: PBindingValue;
begin
  Registry := ThisRegistry(Call);
  Name := Call.Text(0);
  Constructor_ := Call.Script(1);
  if not JsIsConstructor(Constructor_) then
    raise EBindingTypeError.Create('the custom element constructor is not a constructor');
  if not IsValidCustomElementName(Name) then
    RaiseDomError(SyntaxError, '"' + Name + '" is not a valid custom element name');
  if Registry.FindByName(Name) <> nil then
    RaiseDomError(NotSupportedError, '"' + Name + '" has already been defined');
  if Registry.FindByConstructor(Constructor_) <> nil then
    RaiseDomError(NotSupportedError, 'the constructor has already been used to define a custom element');
  LocalName := Name;
  Options := @Call.Arguments[2];
  if Options^.Items[ElementDefinitionOptions_extends].Kind = bvString then
  begin
    Extends := Options^.Items[ElementDefinitionOptions_extends].Text;
    if IsValidCustomElementName(Extends) then
      RaiseDomError(NotSupportedError, 'a custom element cannot extend another custom element');
    if ElementInterfaceOf(Context(Call), Extends) = InterfaceHTMLUnknownElement then
      RaiseDomError(NotSupportedError, '"' + Extends + '" is not an HTML element that can be extended');
    LocalName := Extends;
  end;
  if Registry.DefinitionRunning then
    RaiseDomError(NotSupportedError, 'a custom element definition is already running');
  Definition := TCustomElementDefinition.Create;
  try
    Definition.Name := Name;
    Definition.LocalName := LocalName;
    Definition.LocalNameAtom := Atomize(LocalName);
    Definition.Constructor_ := Constructor_;
    Registry.DefinitionRunning := True;
    try
      ReadDefinition(Call, Definition);
    finally
      Registry.DefinitionRunning := False;
    end;
  except
    Definition.Release;
    raise;
  end;
  Registry.Add(Definition);
  UpgradeCandidates(Context(Call).Document, Definition);
  Promise := Registry.TakePendingPromise(Name);
  if JsIsObject(Promise) then
    FulfillPromise(Call.Realm, TJsPromise(JsAsObject(Promise)), Constructor_);
  Result := JsUndefined;
end;

function CustomElementRegistry_get(var Call: TBindingCall): TJsValue;
var
  Definition: TCustomElementDefinition;
begin
  Definition := ThisRegistry(Call).FindByName(Call.Text(0));
  if Definition = nil then
    Result := JsUndefined
  else
    Result := Definition.Constructor_;
end;

function CustomElementRegistry_getName(var Call: TBindingCall): TJsValue;
var
  Definition: TCustomElementDefinition;
begin
  Definition := ThisRegistry(Call).FindByConstructor(Call.Script(0));
  if Definition = nil then
    Result := JsNull
  else
    Result := Context(Call).TextValue(Definition.Name);
end;

function CustomElementRegistry_whenDefined(var Call: TBindingCall): TJsValue;
var
  Registry: TCustomElementRegistry;
  Name: string;
  Definition: TCustomElementDefinition;
  Promise: TJsPromise;
begin
  Registry := ThisRegistry(Call);
  Name := Call.Text(0);
  Promise := NewPromise(Call.Realm);
  Result := JsObjectValue(Promise);
  if not IsValidCustomElementName(Name) then
  begin
    RejectPromise(Call.Realm, Promise, Context(Call).NewDomException(SyntaxError,
      '"' + Name + '" is not a valid custom element name'));
    Exit;
  end;
  Definition := Registry.FindByName(Name);
  if Definition <> nil then
  begin
    FulfillPromise(Call.Realm, Promise, Definition.Constructor_);
    Exit;
  end;
  if JsIsObject(Registry.PendingPromise(Name)) then
    Exit(Registry.PendingPromise(Name));
  Registry.SetPendingPromise(Name, Result);
end;

function CustomElementRegistry_upgrade(var Call: TBindingCall): TJsValue;
var
  Root, Node: TNode;
begin
  Root := TNode(Call.Native(0));
  Node := Root;
  while Node <> nil do
  begin
    if Node.IsElement then
      TryToUpgrade(TElement(Node));
    Node := Node.NextInShadowIncludingTree(Root);
  end;
  Result := JsUndefined;
end;

function Window_get_customElements(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(RegistryOf(Context(Call)), InterfaceCustomElementRegistry, False, JsUndefined);
end;

{ [HTMLConstructor] (HTML 3.2.3): new MyElement() makes an element of
  its definition; inside an upgrade it gives the element being upgraded
  its prototype. }
function HTMLConstructor_construct(var Call: TBindingCall): TJsValue;
var
  Registry: TCustomElementRegistry;
  Definition: TCustomElementDefinition;
  Prototype: TJsObject;
  Element: TElement;
  Top: Integer;
begin
  Registry := ExistingRegistryOf(Context(Call));
  if JsIsObject(Call.NewTarget) and
    (Call.NewTarget = JsObjectValue(Context(Call).HostClassOf(Call.InterfaceId).Constructor_)) then
    raise EBindingTypeError.Create('Illegal constructor');
  Definition := nil;
  if Registry <> nil then
    Definition := Registry.FindByConstructor(Call.NewTarget);
  if Definition = nil then
    raise EBindingTypeError.Create('Illegal constructor: the class is not a defined custom element');
  if Definition.IsAutonomous then
  begin
    if Call.InterfaceId <> InterfaceHTMLElement then
      raise EBindingTypeError.Create('an autonomous custom element must extend HTMLElement');
  end
  else if ElementInterfaceOf(Context(Call), Definition.LocalName) <> Call.InterfaceId then
    raise EBindingTypeError.Create('the custom element extends another element interface');
  Prototype := Context(Call).PrototypeForConstruct(Call);
  Top := High(Definition.ConstructionStack);
  if Top < 0 then
  begin
    Element := Context(Call).Document.NewElement(Definition.LocalNameAtom, NamespaceHtml);
    Definition.Retain;
    Element.SetCustomElementDefinition(Definition);
    if not Definition.IsAutonomous then
      Element.SetIsValue(Definition.Name);
    if Definition.FormAssociated then
      Element.ElementState := Element.ElementState or ElementStateFormAssociatedCustom;
    Element.SetCustomElementState(CustomElementCustom);
    Result := Context(Call).WrapNode(Element);
  end
  else
  begin
    Element := Definition.ConstructionStack[Top];
    if Element = nil then
      raise EBindingTypeError.Create('the custom element has already been constructed');
    Result := Context(Call).WrapNode(Element);
    Definition.ConstructionStack[Top] := nil;
  end;
  if JsAsObject(Result).Proto <> Prototype then
    JsAsObject(Result).SetPrototype(Call.Realm, Prototype);
end;

{ attachInternals and ElementInternals }

function HTMLElement_attachInternals(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Definition: TCustomElementDefinition;
  Data: TCustomElementData;
begin
  Element := TElement(Call.Target);
  if Element.IsValue <> '' then
    RaiseDomError(NotSupportedError, 'customized built-in elements have no internals');
  Definition := LookUpDefinition(Element.NodeDocument, Element.NamespaceId, Element.LocalNameAtom, '');
  if Definition = nil then
    RaiseDomError(NotSupportedError, 'the element is not a defined custom element');
  if Definition.DisableInternals then
    RaiseDomError(NotSupportedError, 'the custom element disables internals');
  Data := CustomDataOf(Element);
  if Data.AttachedInternals then
    RaiseDomError(NotSupportedError, 'attachInternals() was already called');
  if not (Element.CustomElementState in [CustomElementPrecustomized, CustomElementCustom]) then
    RaiseDomError(NotSupportedError, 'the element is not custom yet');
  Data.AttachedInternals := True;
  if Data.Internals = nil then
  begin
    Data.Internals := TElementInternalsData.Create;
    Data.Internals.Element := Element;
  end;
  Result := Context(Call).WrapObject(Data.Internals, InterfaceElementInternals, False, Call.This);
end;

function ThisInternals(const Call: TBindingCall): TElementInternalsData; inline;
begin
  Result := TElementInternalsData(Call.Target);
end;

{ The form-associated operations throw for other custom elements. }
function FormInternals(const Call: TBindingCall): TElementInternalsData;
begin
  Result := ThisInternals(Call);
  if not IsFormAssociatedCustomElement(Result.Element) then
    RaiseDomError(NotSupportedError, 'the custom element is not form-associated');
end;

function ElementInternals_get_shadowRoot(var Call: TBindingCall): TJsValue;
var
  Shadow: TShadowRoot;
begin
  Shadow := ThisInternals(Call).Element.ShadowRoot;
  if (Shadow = nil) or not Shadow.AvailableToElementInternals then
    Result := JsNull
  else
    Result := Context(Call).WrapNode(Shadow);
end;

{ A FormData's entries (name, value; a File as its name). }
procedure ReadFormDataEntries(const Call: TBindingCall; Value: TJsValue; Internals: TElementInternalsData);
var
  ArrayConstructor, FromFunction, Items, Entry, EntryValue: TJsValue;
  Index, Count: Integer;
begin
  ArrayConstructor := GetValue(Call, JsObjectValue(Context(Call).Engine.GlobalObject), 'Array');
  FromFunction := GetValue(Call, ArrayConstructor, 'from');
  Items := Call.Realm.Call(FromFunction, ArrayConstructor, @Value, 1);
  if Items = JsException then
    Pending;
  Count := Trunc(Context(Call).Engine.ToNumber(GetValue(Call, Items, 'length')));
  SetLength(Internals.EntryNames, Count);
  SetLength(Internals.EntryValues, Count);
  for Index := 0 to Count - 1 do
  begin
    Entry := GetValue(Call, Items, IntToStr(Index));
    Internals.EntryNames[Index] := ValueToText(Call.Realm, GetValue(Call, Entry, '0'));
    EntryValue := GetValue(Call, Entry, '1');
    if JsIsObject(EntryValue) then
      EntryValue := GetValue(Call, EntryValue, 'name');
    Internals.EntryValues[Index] := ValueToText(Call.Realm, EntryValue);
  end;
end;

function ElementInternals_setFormValue(var Call: TBindingCall): TJsValue;
var
  Internals: TElementInternalsData;
  Value: TJsValue;
begin
  Internals := FormInternals(Call);
  Value := Call.Script(0);
  Internals.EntryNames := nil;
  Internals.EntryValues := nil;
  Internals.UsesElementName := False;
  Internals.HasValue := not (Value = JsNull) and not (Value = JsUndefined);
  if Internals.HasValue then
  begin
    if JsIsObject(Value) and JsIsCallable(GetValue(Call, Value, 'entries')) and
      (GetValue(Call, Value, 'size') = JsUndefined) then
      ReadFormDataEntries(Call, Value, Internals)
    else
    begin
      if JsIsObject(Value) then
        Value := GetValue(Call, Value, 'name');
      Internals.UsesElementName := True;
      Internals.EntryValues := [ValueToText(Call.Realm, Value)];
      Internals.EntryNames := [''];
    end;
  end;
  if Call.Present(1) and (Call.Script(1) <> JsNull) and not JsIsObject(Call.Script(1)) then
    Internals.State := ValueToText(Call.Realm, Call.Script(1))
  else if Internals.UsesElementName then
    Internals.State := Internals.EntryValues[0];
  Result := JsUndefined;
end;

function ElementInternals_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(FormOwner(FormInternals(Call).Element));
end;

function ElementInternals_setValidity(var Call: TBindingCall): TJsValue;
const
  FlagMembers: array[0..9] of Integer = (ValidityStateFlags_valueMissing, ValidityStateFlags_typeMismatch,
    ValidityStateFlags_patternMismatch, ValidityStateFlags_tooLong, ValidityStateFlags_tooShort,
    ValidityStateFlags_rangeUnderflow, ValidityStateFlags_rangeOverflow, ValidityStateFlags_stepMismatch,
    ValidityStateFlags_badInput, ValidityStateFlags_customError);
var
  Internals: TElementInternalsData;
  Flags: Word;
  Index: Integer;
begin
  Internals := FormInternals(Call);
  Flags := 0;
  for Index := 0 to High(FlagMembers) do
    if Call.Arguments[0].Items[FlagMembers[Index]].Flag then
      Flags := Flags or (1 shl Index);
  if (Flags <> 0) and (not Call.Present(1) or (Call.Text(1) = '')) then
    raise EBindingTypeError.Create('setValidity() needs a message when a flag is set');
  Internals.ValidityFlags := Flags;
  if Flags = 0 then
    Internals.ValidationMessage := ''
  else
    Internals.ValidationMessage := Call.Text(1);
  Internals.Element.NodeDocument.NotifyControlStateChanged(Internals.Element);
  Result := JsUndefined;
end;

{ A form-associated custom element is barred from constraint validation
  when it is disabled. }
function WillValidate(Internals: TElementInternalsData): Boolean;
begin
  Result := not Internals.Element.HasAttributeAtom(AtomDisabled);
end;

function ElementInternals_get_willValidate(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(WillValidate(FormInternals(Call)));
end;

function ElementInternals_get_validity(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(FormInternals(Call), InterfaceValidityState, False, Call.This);
end;

function ElementInternals_get_validationMessage(var Call: TBindingCall): TJsValue;
var
  Internals: TElementInternalsData;
begin
  Internals := FormInternals(Call);
  if WillValidate(Internals) and (Internals.ValidityFlags <> 0) then
    Result := Context(Call).TextValue(Internals.ValidationMessage)
  else
    Result := Context(Call).TextValue('');
end;

function CheckInternalsValidity(Internals: TElementInternalsData): Boolean;
var
  Event: TEvent;
begin
  Result := not WillValidate(Internals) or (Internals.ValidityFlags = 0);
  if Result then
    Exit;
  Event := TEvent.Create('invalid', False, True);
  try
    Event.IsTrusted := True;
    Internals.Element.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

function ElementInternals_checkValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckInternalsValidity(FormInternals(Call)));
end;

function ElementInternals_reportValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckInternalsValidity(FormInternals(Call)));
end;

{ The labels of the element: label elements whose labeled control it is. }
function ElementInternals_get_labels(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Node: TNode;
  Labels: TNodeArray;
  Id: string;

  function LabelsElement(LabelElement: TElement): Boolean;
  begin
    if LabelElement.HasAttributeAtom(AtomFor) then
      Result := (Id <> '') and (LabelElement.AttributeValueOf(AtomFor) = Id)
    else
      Result := LabelElement.Contains(Element);
  end;

begin
  Element := FormInternals(Call).Element;
  Id := Element.AttributeValueOf(AtomId);
  Labels := nil;
  Node := Element.GetRootNode;
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).IsHtmlElement(AtomLabel) and LabelsElement(TElement(Node)) then
    begin
      SetLength(Labels, Length(Labels) + 1);
      Labels[High(Labels)] := Node;
    end;
    Node := Node.NextInTree(Element.GetRootNode);
  end;
  Result := Context(Call).WrapObject(TStaticNodeList.Create(Labels), InterfaceNodeList, True, JsUndefined);
end;

function ElementInternals_get_states(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisInternals(Call), InterfaceCustomStateSet, False, Call.This);
end;

{ ARIA values, kept by name. }
function AriaValue(const Call: TBindingCall; const Name: string): TJsValue;
var
  Internals: TElementInternalsData;
  Index: Integer;
begin
  Internals := ThisInternals(Call);
  for Index := 0 to High(Internals.AriaNames) do
    if Internals.AriaNames[Index] = Name then
      Exit(Context(Call).TextValue(Internals.AriaValues[Index]));
  Result := JsNull;
end;

function SetAriaValue(const Call: TBindingCall; const Name: string): TJsValue;
var
  Internals: TElementInternalsData;
  Index, Position: Integer;
begin
  Internals := ThisInternals(Call);
  for Index := 0 to High(Internals.AriaNames) do
    if Internals.AriaNames[Index] = Name then
    begin
      if Call.IsNull(0) then
      begin
        for Position := Index + 1 to High(Internals.AriaNames) do
        begin
          Internals.AriaNames[Position - 1] := Internals.AriaNames[Position];
          Internals.AriaValues[Position - 1] := Internals.AriaValues[Position];
        end;
        SetLength(Internals.AriaNames, Length(Internals.AriaNames) - 1);
        SetLength(Internals.AriaValues, Length(Internals.AriaValues) - 1);
      end
      else
        Internals.AriaValues[Index] := Call.Text(0);
      Exit(JsUndefined);
    end;
  if not Call.IsNull(0) then
  begin
    Internals.AriaNames := Concat(Internals.AriaNames, [Name]);
    Internals.AriaValues := Concat(Internals.AriaValues, [Call.Text(0)]);
  end;
  Result := JsUndefined;
end;

function ElementInternals_get_role(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'role');
end;

function ElementInternals_set_role(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'role');
end;

function ElementInternals_get_ariaLabel(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaLabel');
end;

function ElementInternals_set_ariaLabel(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaLabel');
end;

function ElementInternals_get_ariaChecked(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaChecked');
end;

function ElementInternals_set_ariaChecked(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaChecked');
end;

function ElementInternals_get_ariaDisabled(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaDisabled');
end;

function ElementInternals_set_ariaDisabled(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaDisabled');
end;

function ElementInternals_get_ariaExpanded(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaExpanded');
end;

function ElementInternals_set_ariaExpanded(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaExpanded');
end;

function ElementInternals_get_ariaHidden(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaHidden');
end;

function ElementInternals_set_ariaHidden(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaHidden');
end;

function ElementInternals_get_ariaPressed(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaPressed');
end;

function ElementInternals_set_ariaPressed(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaPressed');
end;

function ElementInternals_get_ariaSelected(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaSelected');
end;

function ElementInternals_set_ariaSelected(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaSelected');
end;

function ElementInternals_get_ariaValueNow(var Call: TBindingCall): TJsValue;
begin
  Result := AriaValue(Call, 'ariaValueNow');
end;

function ElementInternals_set_ariaValueNow(var Call: TBindingCall): TJsValue;
begin
  Result := SetAriaValue(Call, 'ariaValueNow');
end;

{ ValidityState (over a custom element's internals) }

function ValidityFlag(const Call: TBindingCall; Flag: Word): TJsValue;
begin
  Result := JsBoolean((TElementInternalsData(Call.Target).ValidityFlags and Flag) <> 0);
end;

function ValidityState_get_valueMissing(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityValueMissing);
end;

function ValidityState_get_typeMismatch(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityTypeMismatch);
end;

function ValidityState_get_patternMismatch(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityPatternMismatch);
end;

function ValidityState_get_tooLong(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityTooLong);
end;

function ValidityState_get_tooShort(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityTooShort);
end;

function ValidityState_get_rangeUnderflow(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityRangeUnderflow);
end;

function ValidityState_get_rangeOverflow(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityRangeOverflow);
end;

function ValidityState_get_stepMismatch(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityStepMismatch);
end;

function ValidityState_get_badInput(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityBadInput);
end;

function ValidityState_get_customError(var Call: TBindingCall): TJsValue;
begin
  Result := ValidityFlag(Call, ValidityCustomError);
end;

function ValidityState_get_valid(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(TElementInternalsData(Call.Target).ValidityFlags = 0);
end;

{ CustomStateSet (the states live with the element, for :state()) }

function StatesOf(const Call: TBindingCall): TElement; inline;
begin
  Result := TElementInternalsData(Call.Target).Element;
end;

function CurrentStates(Element: TElement): TStringArray;
begin
  Result := Element.CustomStates;
end;

function CustomStateSet_get_size(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Length(CurrentStates(StatesOf(Call))));
end;

function CustomStateSet_add(var Call: TBindingCall): TJsValue;
var
  States: TStringArray;
begin
  States := CurrentStates(StatesOf(Call));
  if not SequenceContains(States, Call.Text(0)) then
    StatesOf(Call).SetCustomStates(Concat(States, [Call.Text(0)]));
  Result := Call.This;
end;

function CustomStateSet_delete(var Call: TBindingCall): TJsValue;
var
  States, Kept: TStringArray;
  Index: Integer;
begin
  States := CurrentStates(StatesOf(Call));
  Kept := nil;
  for Index := 0 to High(States) do
    if States[Index] <> Call.Text(0) then
      Kept := Concat(Kept, [States[Index]]);
  Result := JsBoolean(Length(Kept) <> Length(States));
  if Length(Kept) <> Length(States) then
    StatesOf(Call).SetCustomStates(Kept);
end;

function CustomStateSet_has(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(StatesOf(Call).HasCustomState(Call.Text(0)));
end;

function CustomStateSet_clear(var Call: TBindingCall): TJsValue;
begin
  StatesOf(Call).SetCustomStates(nil);
  Result := JsUndefined;
end;

function StatesArray(const Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).StringArray(CurrentStates(StatesOf(Call)));
end;

function CustomStateSet_forEach(var Call: TBindingCall): TJsValue;
var
  States: TStringArray;
  Index: Integer;
  Callback, This, Item: TJsValue;
  Args: array[0..2] of TJsValue;
begin
  Callback := Call.Script(0);
  if not JsIsCallable(Callback) then
    raise EBindingTypeError.Create('forEach needs a function');
  This := Call.Script(1);
  States := CurrentStates(StatesOf(Call));
  for Index := 0 to High(States) do
  begin
    Item := Context(Call).TextValue(States[Index]);
    Args[0] := Item;
    Args[1] := Item;
    Args[2] := Call.This;
    if Call.Realm.Call(Callback, This, @Args[0], 3) = JsException then
      Pending;
  end;
  Result := JsUndefined;
end;

function ArrayIterator(const Call: TBindingCall; Items: TJsValue; const Method: string): TJsValue;
begin
  Result := Call.Realm.Call(GetValue(Call, Items, Method), Items, nil, 0);
  if Result = JsException then
    Pending;
end;

function CustomStateSet_values(var Call: TBindingCall): TJsValue;
begin
  Result := ArrayIterator(Call, StatesArray(Call), 'values');
end;

function CustomStateSet_keys(var Call: TBindingCall): TJsValue;
begin
  Result := ArrayIterator(Call, StatesArray(Call), 'values');
end;

{ A set's entries are [value, value]. }
function CustomStateSet_entries(var Call: TBindingCall): TJsValue;
var
  States: TStringArray;
  Pairs: array of TJsValue;
  Index: Integer;
  Item: TJsValue;
begin
  States := CurrentStates(StatesOf(Call));
  Pairs := nil;
  SetLength(Pairs, Length(States));
  for Index := 0 to High(States) do
  begin
    Item := Context(Call).TextValue(States[Index]);
    Pairs[Index] := Context(Call).NewArray([Item, Item]);
  end;
  Result := ArrayIterator(Call, Context(Call).NewArray(Pairs), 'values');
end;

{ The form code's view }

function InternalsOf(Element: TElement): TElementInternalsData;
var
  Data: TCustomElementData;
begin
  Data := TCustomElementData(Element.CustomElementData);
  if Data = nil then
    Result := nil
  else
    Result := Data.Internals;
end;

procedure CustomElementFormEntries(Element: TElement; var Names, Values: TStringArray);
var
  Internals: TElementInternalsData;
  Index: Integer;
  Name: string;
begin
  Internals := InternalsOf(Element);
  if (Internals = nil) or not Internals.HasValue then
    Exit;
  Name := Element.AttributeValueOf(AtomName);
  for Index := 0 to High(Internals.EntryValues) do
  begin
    if Internals.UsesElementName then
    begin
      if Name = '' then
        Continue;
      Names := Concat(Names, [Name]);
    end
    else
      Names := Concat(Names, [Internals.EntryNames[Index]]);
    Values := Concat(Values, [Internals.EntryValues[Index]]);
  end;
end;

function CustomElementValid(Element: TElement): Boolean;
var
  Internals: TElementInternalsData;
begin
  Internals := InternalsOf(Element);
  Result := (Internals = nil) or CheckInternalsValidity(Internals);
end;

procedure CustomElementFormReset(Element: TElement);
begin
  if IsFormAssociatedCustomElement(Element) then
    EnqueueCallbackReaction(Element, CallbackFormReset, [], []);
end;

end.
