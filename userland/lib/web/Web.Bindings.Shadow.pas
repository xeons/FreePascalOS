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
  bindings/Shadow.webidl: ShadowRoot, attachShadow and shadowRoot,
  Element.part, the Slottable mixin (assignedSlot), the slot element's
  assignedNodes, assignedElements and assign, and getHTML and
  setHTMLUnsafe of shadow roots and elements, over Web.Dom's shadow
  trees. A closed shadow root is never given out by shadowRoot or
  assignedSlot; retargeting (activeElement) keeps closed trees hidden.
}
unit Web.Bindings.Shadow;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Dom,
  Web.Bindings.Types;

{$I Web.Bindings.Shadow.Members.inc}

{ The DOM Standard's "retarget A against B" for nodes. }
function RetargetNode(A, B: TNode): TNode;

implementation

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Exceptions,
  Web.Html.Parser,
  Web.Html.Serializer,
  Web.Bindings.Context,
  Web.Bindings.CustomElementRegistry;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function ThisShadowRoot(const Call: TBindingCall): TShadowRoot; inline;
begin
  Result := TShadowRoot(Call.Target);
end;

function ThisElement(const Call: TBindingCall): TElement; inline;
begin
  Result := TElement(Call.Target);
end;

function RetargetNode(A, B: TNode): TNode;
var
  Root: TNode;
begin
  Result := A;
  while Result <> nil do
  begin
    Root := Result.GetRootNode;
    if not (Root is TShadowRoot) or (TShadowRoot(Root).Host = nil) or Root.IsShadowIncludingInclusiveAncestorOfNode(B) then
      Exit;
    Result := TShadowRoot(Root).Host;
  end;
end;

{ Replaces Target's children with Markup parsed in the context of
  Context (setHTMLUnsafe allows declarative shadow roots). }
procedure ReplaceWithParsedMarkup(Target: TNode; ContextElement: TElement; const Markup: string;
  AllowDeclarativeShadowRoots: Boolean);
var
  Fragment: TDocumentFragment;
begin
  Fragment := ParseHtmlFragment(ContextElement, Markup, AllowDeclarativeShadowRoots);
  if (Target.NodeType = NodeTypeElement) and TElement(Target).IsHtmlElement(AtomTemplate) then
    Target := TElement(Target).TemplateContent;
  Target.ReplaceChildren([Fragment]);
end;

{ ShadowRoot }

function ShadowRoot_get_mode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisShadowRoot(Call).ModeText);
end;

function ShadowRoot_get_delegatesFocus(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisShadowRoot(Call).DelegatesFocus);
end;

function ShadowRoot_get_slotAssignment(var Call: TBindingCall): TJsValue;
begin
  if ThisShadowRoot(Call).SlotAssignment = SlotAssignmentManual then
    Result := Context(Call).TextValue('manual')
  else
    Result := Context(Call).TextValue('named');
end;

function ShadowRoot_get_clonable(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisShadowRoot(Call).Clonable);
end;

function ShadowRoot_get_serializable(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisShadowRoot(Call).Serializable);
end;

function ShadowRoot_get_host(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisShadowRoot(Call).Host);
end;

{ DocumentOrShadowRoot's activeElement: the focused element retargeted
  against the shadow root, if that lands in this tree. }
function ShadowRoot_get_activeElement(var Call: TBindingCall): TJsValue;
var
  Candidate: TNode;
begin
  Result := JsNull;
  Candidate := RetargetNode(ThisShadowRoot(Call).NodeDocument.FocusedElement, ThisShadowRoot(Call));
  if (Candidate <> nil) and (Candidate.GetRootNode = ThisShadowRoot(Call)) then
    Result := Context(Call).WrapNode(Candidate);
end;

function ShadowRoot_get_innerHTML(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(SerializeChildren(ThisShadowRoot(Call)));
end;

function ShadowRoot_set_innerHTML(var Call: TBindingCall): TJsValue;
begin
  ReplaceWithParsedMarkup(ThisShadowRoot(Call), ThisShadowRoot(Call).Host, Call.Text(0), False);
  Result := JsUndefined;
end;

function ShadowRoot_setHTMLUnsafe(var Call: TBindingCall): TJsValue;
begin
  ReplaceWithParsedMarkup(ThisShadowRoot(Call), ThisShadowRoot(Call).Host, Call.Text(0), True);
  Result := JsUndefined;
end;

function ShadowRoot_getHTML(var Call: TBindingCall): TJsValue;
var
  Serializable: Boolean;
begin
  Serializable := Call.Arguments[0].Items[GetHTMLOptions_serializableShadowRoots].Flag;
  Result := Context(Call).TextValue(SerializeChildrenWithShadowRoots(ThisShadowRoot(Call), Serializable));
end;

{ Element }

function Element_attachShadow(var Call: TBindingCall): TJsValue;
var
  Init: PBindingValue;
  Mode: TShadowRootMode;
  Assignment: TSlotAssignmentMode;
  Shadow: TShadowRoot;
begin
  Init := @Call.Arguments[0];
  if Init^.Items[ShadowRootInit_mode].Text = 'closed' then
    Mode := ShadowRootClosed
  else
    Mode := ShadowRootOpen;
  if Init^.Items[ShadowRootInit_slotAssignment].Text = 'manual' then
    Assignment := SlotAssignmentManual
  else
    Assignment := SlotAssignmentNamed;
  if ShadowDisabledFor(ThisElement(Call)) then
    RaiseDomError(NotSupportedError, 'the custom element disables shadow roots');
  Shadow := ThisElement(Call).AttachShadow(Mode, Init^.Items[ShadowRootInit_clonable].Flag,
    Init^.Items[ShadowRootInit_serializable].Flag, Init^.Items[ShadowRootInit_delegatesFocus].Flag, Assignment);
  if ThisElement(Call).CustomElementState in [CustomElementPrecustomized, CustomElementCustom] then
    Shadow.AvailableToElementInternals := True;
  Result := Context(Call).WrapNode(Shadow);
end;

function Element_get_shadowRoot(var Call: TBindingCall): TJsValue;
var
  Shadow: TShadowRoot;
begin
  Shadow := ThisElement(Call).ShadowRoot;
  if (Shadow = nil) or (Shadow.Mode = ShadowRootClosed) then
    Result := JsNull
  else
    Result := Context(Call).WrapNode(Shadow);
end;

function Element_get_part(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call).PartList, InterfaceDOMTokenList, False, Call.This);
end;

function Element_setHTMLUnsafe(var Call: TBindingCall): TJsValue;
begin
  ReplaceWithParsedMarkup(ThisElement(Call), ThisElement(Call), Call.Text(0), True);
  Result := JsUndefined;
end;

{ Slottable: the assigned slot, found only in open shadow trees. }
function Slottable_get_assignedSlot(var Call: TBindingCall): TJsValue;
var
  Node: TNode;
  Slot: TElement;
  Shadow: TShadowRoot;
begin
  Node := TNode(Call.Target);
  Slot := Node.AssignedSlot;
  Result := JsNull;
  if Slot = nil then
    Exit;
  Shadow := Slot.ContainingShadowRoot;
  if (Shadow <> nil) and (Shadow.Mode = ShadowRootOpen) then
    Result := Context(Call).WrapNode(Slot);
end;

{ HTMLSlotElement }

function SlotNodes(const Call: TBindingCall): TNodeArray;
begin
  if Call.Arguments[0].Items[AssignedNodesOptions_flatten].Flag then
    Result := ThisElement(Call).FlattenedAssignedNodes
  else
    Result := ThisElement(Call).AssignedNodes;
end;

function HTMLSlotElement_assignedNodes(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NodeArray(SlotNodes(Call));
end;

function HTMLSlotElement_assignedElements(var Call: TBindingCall): TJsValue;
var
  Nodes, Elements: TNodeArray;
  Index, Count: Integer;
begin
  Nodes := SlotNodes(Call);
  Elements := nil;
  SetLength(Elements, Length(Nodes));
  Count := 0;
  for Index := 0 to High(Nodes) do
    if Nodes[Index].IsElement then
    begin
      Elements[Count] := Nodes[Index];
      Inc(Count);
    end;
  SetLength(Elements, Count);
  Result := Context(Call).NodeArray(Elements);
end;

function HTMLSlotElement_assign(var Call: TBindingCall): TJsValue;
var
  Nodes: TNodeArray;
  Index: Integer;
begin
  Nodes := nil;
  SetLength(Nodes, Call.Count);
  for Index := 0 to Call.Count - 1 do
    Nodes[Index] := TNode(Call.Arguments[Index].Native);
  ThisElement(Call).AssignNodesManually(Nodes);
  Result := JsUndefined;
end;

end.
