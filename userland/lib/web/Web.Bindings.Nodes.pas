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
  bindings/Nodes.webidl: Node, the ParentNode, ChildNode,
  NonElementParentNode and NonDocumentTypeChildNode mixins, and the
  node kinds but Document and Element, over Web.Dom.
}
unit Web.Bindings.Nodes;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Dom,
  Web.Bindings.Types;

{$I Web.Bindings.Nodes.Members.inc}

{ The nodes of a (Node or DOMString)... argument list: strings become
  Text nodes of Document. }
function NodesFromArguments(const Call: TBindingCall; Document: TDocument): TNodeArray;

implementation

uses
  SysUtils,
  Web.Atoms,
  Web.Bindings.Context,
  Web.Bindings.Selectors,
  Web.Bindings.UrlResolution;

function ThisNode(const Call: TBindingCall): TNode; inline;
begin
  Result := TNode(Call.Target);
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function NodesFromArguments(const Call: TBindingCall; Document: TDocument): TNodeArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Call.Count);
  for Index := 0 to Call.Count - 1 do
    if Call.Arguments[Index].Kind = bvNative then
      Result[Index] := TNode(Call.Arguments[Index].Native)
    else
      Result[Index] := Document.CreateTextNode(Call.Arguments[Index].Text);
end;

{ Node }

function Node_get_nodeType(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisNode(Call).NodeType);
end;

function Node_get_nodeName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisNode(Call).NodeName);
end;

function Node_get_baseURI(var Call: TBindingCall): TJsValue;
var
  Resolved: string;
begin
  if not ResolveUrlText(ThisNode(Call).NodeDocument, '', Resolved) then
    Resolved := DocumentUrlText(ThisNode(Call).NodeDocument);
  Result := Context(Call).TextValue(Resolved);
end;

function Node_get_isConnected(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisNode(Call).IsConnected);
end;

function Node_get_ownerDocument(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).OwnerDocument);
end;

function Node_getRootNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).GetRootNode);
end;

function Node_get_parentNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).ParentNode);
end;

function Node_get_parentElement(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).ParentElement);
end;

function Node_hasChildNodes(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisNode(Call).HasChildNodes);
end;

function Node_get_childNodes(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisNode(Call).ChildNodes, InterfaceNodeList, False, Call.This);
end;

function Node_get_firstChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).FirstChild);
end;

function Node_get_lastChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).LastChild);
end;

function Node_get_previousSibling(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).PreviousSibling);
end;

function Node_get_nextSibling(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).NextSibling);
end;

function HasNodeValue(Node: TNode): Boolean;
begin
  Result := Node.NodeType in [NodeTypeText, NodeTypeCDataSection, NodeTypeComment, NodeTypeProcessingInstruction,
    NodeTypeAttribute];
end;

function HasTextContent(Node: TNode): Boolean;
begin
  Result := not (Node.NodeType in [NodeTypeDocument, NodeTypeDocumentType]);
end;

function Node_get_nodeValue(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisNode(Call).NodeValue, not HasNodeValue(ThisNode(Call)));
end;

function Node_set_nodeValue(var Call: TBindingCall): TJsValue;
begin
  if HasNodeValue(ThisNode(Call)) then
    ThisNode(Call).NodeValue := Call.Text(0);
  Result := JsUndefined;
end;

function Node_get_textContent(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisNode(Call).TextContent, not HasTextContent(ThisNode(Call)));
end;

function Node_set_textContent(var Call: TBindingCall): TJsValue;
begin
  if HasTextContent(ThisNode(Call)) then
    ThisNode(Call).TextContent := Call.Text(0);
  Result := JsUndefined;
end;

function Node_normalize(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).Normalize;
  Result := JsUndefined;
end;

function Node_cloneNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).CloneNode(Call.Flag(0)));
end;

function Node_isEqualNode(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean((Call.Native(0) <> nil) and ThisNode(Call).IsEqualNode(TNode(Call.Native(0))));
end;

function Node_isSameNode(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(Call.Native(0) = Call.Target);
end;

function Node_compareDocumentPosition(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisNode(Call).CompareDocumentPosition(TNode(Call.Native(0))));
end;

function Node_contains(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean((Call.Native(0) <> nil) and ThisNode(Call).Contains(TNode(Call.Native(0))));
end;

function Node_lookupPrefix(var Call: TBindingCall): TJsValue;
var
  Prefix: string;
begin
  Prefix := ThisNode(Call).LookupPrefix(Call.Text(0));
  Result := Context(Call).NullableText(Prefix, Prefix = '');
end;

function Node_lookupNamespaceURI(var Call: TBindingCall): TJsValue;
var
  Namespace: string;
begin
  Namespace := ThisNode(Call).LookupNamespaceUri(Call.Text(0));
  Result := Context(Call).NullableText(Namespace, Namespace = '');
end;

function Node_isDefaultNamespace(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisNode(Call).IsDefaultNamespace(Call.Text(0)));
end;

function Node_insertBefore(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).InsertBefore(TNode(Call.Native(0)), TNode(Call.Native(1))));
end;

function Node_appendChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).AppendChild(TNode(Call.Native(0))));
end;

function Node_replaceChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).ReplaceChild(TNode(Call.Native(0)), TNode(Call.Native(1))));
end;

function Node_removeChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).RemoveChild(TNode(Call.Native(0))));
end;

{ ParentNode }

function ParentNode_get_children(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisNode(Call).Children, InterfaceHTMLCollection, False, Call.This);
end;

function ParentNode_get_firstElementChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).FirstElementChild);
end;

function ParentNode_get_lastElementChild(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).LastElementChild);
end;

function ParentNode_get_childElementCount(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisNode(Call).ChildElementCount);
end;

function ParentNode_prepend(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).Prepend(NodesFromArguments(Call, ThisNode(Call).NodeDocument));
  Result := JsUndefined;
end;

function ParentNode_append(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).Append(NodesFromArguments(Call, ThisNode(Call).NodeDocument));
  Result := JsUndefined;
end;

function ParentNode_replaceChildren(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).ReplaceChildren(NodesFromArguments(Call, ThisNode(Call).NodeDocument));
  Result := JsUndefined;
end;

function ParentNode_querySelector(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(QuerySelector(ThisNode(Call), Call.Text(0)));
end;

function ParentNode_querySelectorAll(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(TStaticNodeList.Create(QuerySelectorAll(ThisNode(Call), Call.Text(0))),
    InterfaceNodeList, True, JsUndefined);
end;

function NonElementParentNode_getElementById(var Call: TBindingCall): TJsValue;
var
  Node: TNode;
  IdValue: string;
begin
  if ThisNode(Call).NodeType = NodeTypeDocument then
    Exit(Context(Call).WrapNode(TDocument(ThisNode(Call)).GetElementById(Call.Text(0))));
  IdValue := Call.Text(0);
  Node := ThisNode(Call).FirstChild;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and (TElement(Node).Id = IdValue) then
      Exit(Context(Call).WrapNode(Node));
    Node := Node.NextInTree(ThisNode(Call));
  end;
  Result := JsNull;
end;

function NonDocumentTypeChildNode_get_previousElementSibling(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).PreviousElementSibling);
end;

function NonDocumentTypeChildNode_get_nextElementSibling(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisNode(Call).NextElementSibling);
end;

{ ChildNode }

function ChildNode_before(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).Before(NodesFromArguments(Call, ThisNode(Call).NodeDocument));
  Result := JsUndefined;
end;

function ChildNode_after(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).After(NodesFromArguments(Call, ThisNode(Call).NodeDocument));
  Result := JsUndefined;
end;

function ChildNode_replaceWith(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).ReplaceWith(NodesFromArguments(Call, ThisNode(Call).NodeDocument));
  Result := JsUndefined;
end;

function ChildNode_remove(var Call: TBindingCall): TJsValue;
begin
  ThisNode(Call).Remove;
  Result := JsUndefined;
end;

{ DocumentFragment, DocumentType }

function DocumentFragment_constructor(var Call: TBindingCall): TJsValue;
var
  Fragment: TDocumentFragment;
begin
  Fragment := Context(Call).Document.CreateDocumentFragment;
  Result := Context(Call).WrapNode(Fragment);
  Context(Call).AdjustConstructedPrototype(Result, Call);
end;

function DocumentType_get_name(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TDocumentType(Call.Target).Name);
end;

function DocumentType_get_publicId(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TDocumentType(Call.Target).PublicId);
end;

function DocumentType_get_systemId(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TDocumentType(Call.Target).SystemId);
end;

{ CharacterData }

function ThisData(const Call: TBindingCall): TCharacterData; inline;
begin
  Result := TCharacterData(Call.Target);
end;

function CharacterData_get_data(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisData(Call).Data);
end;

function CharacterData_set_data(var Call: TBindingCall): TJsValue;
begin
  ThisData(Call).Data := Call.Text(0);
  Result := JsUndefined;
end;

function CharacterData_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisData(Call).Length);
end;

function CharacterData_substringData(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisData(Call).SubstringData(Call.Int(0), Call.Int(1)));
end;

function CharacterData_appendData(var Call: TBindingCall): TJsValue;
begin
  ThisData(Call).AppendData(Call.Text(0));
  Result := JsUndefined;
end;

function CharacterData_insertData(var Call: TBindingCall): TJsValue;
begin
  ThisData(Call).InsertData(Call.Int(0), Call.Text(1));
  Result := JsUndefined;
end;

function CharacterData_deleteData(var Call: TBindingCall): TJsValue;
begin
  ThisData(Call).DeleteData(Call.Int(0), Call.Int(1));
  Result := JsUndefined;
end;

function CharacterData_replaceData(var Call: TBindingCall): TJsValue;
begin
  ThisData(Call).ReplaceData(Call.Int(0), Call.Int(1), Call.Text(2));
  Result := JsUndefined;
end;

{ Text, Comment, ProcessingInstruction }

function Text_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(Context(Call).Document.CreateTextNode(Call.Text(0)));
  Context(Call).AdjustConstructedPrototype(Result, Call);
end;

function Text_splitText(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(TText(Call.Target).SplitText(Call.Int(0)));
end;

function Text_get_wholeText(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TText(Call.Target).WholeText);
end;

function Comment_constructor(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(Context(Call).Document.CreateComment(Call.Text(0)));
  Context(Call).AdjustConstructedPrototype(Result, Call);
end;

function ProcessingInstruction_get_target(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TProcessingInstruction(Call.Target).Target);
end;

{ Attr }

function ThisAttr(const Call: TBindingCall): TAttr; inline;
begin
  Result := TAttr(Call.Target);
end;

function Attr_get_namespaceURI(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisAttr(Call).NamespaceUri, ThisAttr(Call).NamespaceUri = '');
end;

function Attr_get_prefix(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).NullableText(ThisAttr(Call).Prefix, ThisAttr(Call).Prefix = '');
end;

function Attr_get_localName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisAttr(Call).LocalName);
end;

function Attr_get_name(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisAttr(Call).Name);
end;

function Attr_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisAttr(Call).Value);
end;

function Attr_set_value(var Call: TBindingCall): TJsValue;
begin
  ThisAttr(Call).Value := Call.Text(0);
  Result := JsUndefined;
end;

function Attr_get_ownerElement(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisAttr(Call).OwnerElement);
end;

function Attr_get_specified(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

end.
