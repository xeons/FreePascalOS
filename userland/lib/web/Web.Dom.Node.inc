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
  Web.Dom: Node. Tree navigation and order, cloning and equality,
  normalize, text content, namespace lookups, the observer base class
  and the rare data.
}

procedure TDocumentObserver.TreeMutated(Target: TNode; const Added, Removed: TNodeArray;
  PreviousSibling, NextSibling: TNode);
begin
end;

procedure TDocumentObserver.ChildrenChanged(Parent: TNode);
begin
end;

procedure TDocumentObserver.NodeConnected(Node: TNode);
begin
end;

procedure TDocumentObserver.NodeDisconnected(Node: TNode);
begin
end;

procedure TDocumentObserver.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
begin
end;

procedure TDocumentObserver.CharacterDataChanged(Node: TCharacterData; const OldValue: string);
begin
end;

procedure TDocumentObserver.ControlStateChanged(Element: TElement);
begin
end;

procedure TDocumentObserver.FocusChanged(Old, New: TElement);
begin
end;

destructor TNodeRareData.Destroy;
var
  Index: Integer;
begin
  FormState.Free;
  ImageRequest.Free;
  Listeners.Free;
  ChildNodeList.Free;
  if ChildrenCollection <> nil then
  begin
    ChildrenCollection.FOwnedByRoot := False;
    ChildrenCollection.FRoot := nil;
    ChildrenCollection.Free;
  end;
  ClassList.Free;
  AttributeMap.Free;
  for Index := 1 to Length(AttrNodes) do
    if AttrNodes[Index - 1] <> nil then
    begin
      AttrNodes[Index - 1].FOwnerElement := nil;
      AttrNodes[Index - 1].Free;
    end;
  if TemplateContent <> nil then
  begin
    TemplateContent.FHost := nil;
    if SubtreeCount(TemplateContent) = 0 then
      FreeTree(TemplateContent);
  end;
  inherited Destroy;
end;

destructor TNode.Destroy;
begin
  UnlistFromCollection(Self);
  FreeAndNil(FRareData);
  Dec(NodeObjectCount);
  inherited Destroy;
end;

destructor TContainerNode.Destroy;
var
  Child: TNode;
begin
  while FFirstChild <> nil do
  begin
    Child := FFirstChild;
    FFirstChild := Child.FNextSibling;
    Child.FParent := nil;
    Child.FPreviousSibling := nil;
    Child.FNextSibling := nil;
    FreeTree(Child);
  end;
  FLastChild := nil;
  inherited Destroy;
end;

function TNode.GetRareData: TNodeRareData;
begin
  if FRareData = nil then
    FRareData := TNodeRareData.Create;
  Result := FRareData;
end;

function TNode.FormStateObject: TObject;
begin
  if FRareData = nil then
    Exit(nil);
  Result := FRareData.FormState;
end;

function TNode.ImageRequestObject: TObject;
begin
  if FRareData = nil then
    Exit(nil);
  Result := FRareData.ImageRequest;
end;

procedure TNode.SetImageRequestObject(Value: TObject);
begin
  if (Value = nil) and (FRareData = nil) then
    Exit;
  if RareData.ImageRequest <> Value then
    RareData.ImageRequest.Free;
  RareData.ImageRequest := Value;
end;

procedure TNode.SetFormStateObject(Value: TObject);
begin
  if (Value = nil) and (FRareData = nil) then
    Exit;
  if RareData.FormState <> Value then
    RareData.FormState.Free;
  RareData.FormState := Value;
end;

function TNode.GetSubtreeReferences: LongWord;
begin
  Result := SubtreeCount(Self);
end;

function TNode.GetScriptWrapper: Pointer;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.ScriptWrapper;
end;

procedure TNode.SetScriptWrapper(Value: Pointer);
begin
  if (Value <> nil) or (FRareData <> nil) then
    RareData.ScriptWrapper := Value;
end;

function TNode.GetFirstChild: TNode;
begin
  if (FFlags and NodeFlagContainer) <> 0 then
    Result := TContainerNode(Self).FFirstChild
  else
    Result := nil;
end;

function TNode.GetLastChild: TNode;
begin
  if (FFlags and NodeFlagContainer) <> 0 then
    Result := TContainerNode(Self).FLastChild
  else
    Result := nil;
end;

function TNode.IsContainer: Boolean;
begin
  Result := (FFlags and NodeFlagContainer) <> 0;
end;

function TNode.IsElement: Boolean;
begin
  Result := FNodeType = NodeTypeElement;
end;

function TNode.IsText: Boolean;
begin
  Result := FNodeType in [NodeTypeText, NodeTypeCDataSection];
end;

function TNode.HasChildNodes: Boolean;
begin
  Result := GetFirstChild <> nil;
end;

function TNode.GetParentElement: TElement;
begin
  if (FParent <> nil) and (FParent.FNodeType = NodeTypeElement) then
    Result := TElement(FParent)
  else
    Result := nil;
end;

function TNode.GetIsConnected: Boolean;
begin
  Result := (FFlags and NodeFlagConnected) <> 0;
end;

function TNode.GetOwnerDocumentForScript: TDocument;
begin
  if FNodeType = NodeTypeDocument then
    Result := nil
  else
    Result := FOwnerDocument;
end;

function TNode.GetChildNodes: TNodeList;
begin
  if RareData.ChildNodeList = nil then
    RareData.ChildNodeList := TChildNodeList.Create(Self);
  Result := RareData.ChildNodeList;
end;

function TNode.GetPreviousElementSibling: TElement;
var
  Node: TNode;
begin
  Node := FPreviousSibling;
  while (Node <> nil) and (Node.FNodeType <> NodeTypeElement) do
    Node := Node.FPreviousSibling;
  Result := TElement(Node);
end;

function TNode.GetNextElementSibling: TElement;
var
  Node: TNode;
begin
  Node := FNextSibling;
  while (Node <> nil) and (Node.FNodeType <> NodeTypeElement) do
    Node := Node.FNextSibling;
  Result := TElement(Node);
end;

function TNode.GetListenerList(CreateIfMissing: Boolean): TEventListenerList;
begin
  if FRareData <> nil then
    Result := FRareData.Listeners
  else
    Result := nil;
  if (Result = nil) and CreateIfMissing then
  begin
    RareData.Listeners := TEventListenerList.Create;
    Result := FRareData.Listeners;
  end;
end;

function TNode.GetTheParent(Event: TEvent): TEventTarget;
begin
  { A document's parent is its window, which comes with the browsing
    context in a later phase. }
  Result := FParent;
end;

function TNode.GetNodeValue: string;
begin
  Result := '';
end;

procedure TNode.SetNodeValue(const Value: string);
begin
end;

function TNode.GetTextContent: string;
begin
  Result := '';
end;

procedure TNode.SetTextContent(const Value: string);
begin
end;

function TNode.IsEqualSelf(Other: TNode): Boolean;
begin
  Result := Other.FNodeType = FNodeType;
end;

function TNode.GetRootNode: TNode;
begin
  Result := Self;
  while Result.FParent <> nil do
    Result := Result.FParent;
end;

function TNode.IsInclusiveAncestorOf(Other: TNode): Boolean;
begin
  while Other <> nil do
  begin
    if Other = Self then
      Exit(True);
    Other := Other.FParent;
  end;
  Result := False;
end;

function TNode.Contains(Other: TNode): Boolean;
begin
  Result := (Other <> nil) and IsInclusiveAncestorOf(Other);
end;

function TNode.IsSameNode(Other: TNode): Boolean;
begin
  Result := Other = Self;
end;

function TNode.ChildAt(Index: Integer): TNode;
begin
  Result := GetFirstChild;
  while (Result <> nil) and (Index > 0) do
  begin
    Result := Result.FNextSibling;
    Dec(Index);
  end;
end;

function TNode.ChildCount: Integer;
var
  Child: TNode;
begin
  Result := 0;
  Child := GetFirstChild;
  while Child <> nil do
  begin
    Inc(Result);
    Child := Child.FNextSibling;
  end;
end;

function TNode.IndexInParent: Integer;
var
  Node: TNode;
begin
  Result := 0;
  Node := FPreviousSibling;
  while Node <> nil do
  begin
    Inc(Result);
    Node := Node.FPreviousSibling;
  end;
end;

function TNode.NextInTree(Root: TNode): TNode;
var
  Child: TNode;
begin
  Child := GetFirstChild;
  if Child <> nil then
    Exit(Child);
  Result := NextInTreeSkippingChildren(Root);
end;

function TNode.NextInTreeSkippingChildren(Root: TNode): TNode;
var
  Node: TNode;
begin
  Node := Self;
  while Node <> Root do
  begin
    if Node.FNextSibling <> nil then
      Exit(Node.FNextSibling);
    Node := Node.FParent;
    if Node = nil then
      Break;
  end;
  Result := nil;
end;

function TNode.PreviousInTree: TNode;
var
  Node: TNode;
begin
  if FPreviousSibling = nil then
    Exit(FParent);
  Node := FPreviousSibling;
  while Node.GetLastChild <> nil do
    Node := Node.GetLastChild;
  Result := Node;
end;

{ Whether First comes before Second in tree order (same root). }
function PrecedesInTree(First, Second: TNode): Boolean;
var
  FirstChain, SecondChain: TNodeArray;
  FirstDepth, SecondDepth: Integer;
  Node: TNode;
begin
  FirstChain := nil;
  SecondChain := nil;
  Node := First;
  while Node <> nil do
  begin
    SetLength(FirstChain, Length(FirstChain) + 1);
    FirstChain[High(FirstChain)] := Node;
    Node := Node.FParent;
  end;
  Node := Second;
  while Node <> nil do
  begin
    SetLength(SecondChain, Length(SecondChain) + 1);
    SecondChain[High(SecondChain)] := Node;
    Node := Node.FParent;
  end;
  FirstDepth := High(FirstChain);
  SecondDepth := High(SecondChain);
  { Walk down from the root while the chains agree. }
  while (FirstDepth > 0) and (SecondDepth > 0) and (FirstChain[FirstDepth - 1] = SecondChain[SecondDepth - 1]) do
  begin
    Dec(FirstDepth);
    Dec(SecondDepth);
  end;
  if FirstDepth = 0 then
    Exit(True);
  if SecondDepth = 0 then
    Exit(False);
  Node := FirstChain[FirstDepth - 1].FNextSibling;
  while Node <> nil do
  begin
    if Node = SecondChain[SecondDepth - 1] then
      Exit(True);
    Node := Node.FNextSibling;
  end;
  Result := False;
end;

function AttributeIndexOfAttr(Attr: TAttr): Integer;
begin
  Result := Attr.FOwnerElement.AttributeIndexOf(Attr.FLocalName, Attr.FNamespaceId);
end;

function TNode.CompareDocumentPosition(Other: TNode): Word;
var
  Node1, Node2: TNode;
  Attr1, Attr2: TAttr;
  Index1, Index2: Integer;
begin
  if Other = Self then
    Exit(0);
  Node1 := Other;
  Node2 := Self;
  Attr1 := nil;
  Attr2 := nil;
  if Node1.FNodeType = NodeTypeAttribute then
  begin
    Attr1 := TAttr(Node1);
    Node1 := Attr1.FOwnerElement;
  end;
  if Node2.FNodeType = NodeTypeAttribute then
  begin
    Attr2 := TAttr(Node2);
    Node2 := Attr2.FOwnerElement;
    if (Attr1 <> nil) and (Node1 <> nil) and (Node2 = Node1) then
    begin
      Index1 := AttributeIndexOfAttr(Attr1);
      Index2 := AttributeIndexOfAttr(Attr2);
      if Index1 < Index2 then
        Exit(DocumentPositionImplementationSpecific or DocumentPositionPreceding)
      else
        Exit(DocumentPositionImplementationSpecific or DocumentPositionFollowing);
    end;
  end;
  if (Node1 = nil) or (Node2 = nil) or (Node1.GetRootNode <> Node2.GetRootNode) then
  begin
    Result := DocumentPositionDisconnected or DocumentPositionImplementationSpecific;
    if PtrUInt(Node1) < PtrUInt(Node2) then
      Result := Result or DocumentPositionPreceding
    else
      Result := Result or DocumentPositionFollowing;
    Exit;
  end;
  if ((Node1 <> Node2) and Node1.IsInclusiveAncestorOf(Node2) and (Attr1 = nil)) or
    ((Node1 = Node2) and (Attr2 <> nil)) then
    Exit(DocumentPositionContains or DocumentPositionPreceding);
  if ((Node1 <> Node2) and Node2.IsInclusiveAncestorOf(Node1) and (Attr2 = nil)) or
    ((Node1 = Node2) and (Attr1 <> nil)) then
    Exit(DocumentPositionContainedBy or DocumentPositionFollowing);
  if PrecedesInTree(Node1, Node2) then
    Result := DocumentPositionPreceding
  else
    Result := DocumentPositionFollowing;
end;

{ Appends Node to Parent's children: only for trees being built that
  nothing else can see yet (clones). }
procedure AppendChildRaw(Parent: TContainerNode; Node: TNode);
begin
  Node.FParent := Parent;
  Node.FPreviousSibling := Parent.FLastChild;
  Node.FNextSibling := nil;
  if Parent.FLastChild <> nil then
    Parent.FLastChild.FNextSibling := Node
  else
    Parent.FFirstChild := Node;
  Parent.FLastChild := Node;
end;

procedure CloneTemplateContents(Source, Copy: TElement); forward;

{ Clones Source (and with Deep its descendants) into Document. The
  copy is a detached root, not listed. }
function CloneTree(Source: TNode; Document: TDocument; Deep: Boolean): TNode;
var
  SourceNode, Copy: TNode;
  CopyParent: TNode;
begin
  if Document = nil then
    Document := Source.FOwnerDocument;
  Result := Source.CloneSelf(Document);
  if not Deep then
    Exit;
  if (Source.FNodeType = NodeTypeElement) and (TElement(Source).IsHtmlElement(AtomTemplate)) then
    CloneTemplateContents(TElement(Source), TElement(Result));
  SourceNode := Source.GetFirstChild;
  CopyParent := Result;
  while SourceNode <> nil do
  begin
    Copy := SourceNode.CloneSelf(Document);
    AppendChildRaw(TContainerNode(CopyParent), Copy);
    if (SourceNode.FNodeType = NodeTypeElement) and TElement(SourceNode).IsHtmlElement(AtomTemplate) then
      CloneTemplateContents(TElement(SourceNode), TElement(Copy));
    if SourceNode.GetFirstChild <> nil then
    begin
      CopyParent := Copy;
      SourceNode := SourceNode.GetFirstChild;
      Continue;
    end;
    while (SourceNode <> Source) and (SourceNode.FNextSibling = nil) do
    begin
      SourceNode := SourceNode.FParent;
      CopyParent := CopyParent.FParent;
    end;
    if SourceNode = Source then
      Break;
    SourceNode := SourceNode.FNextSibling;
  end;
end;

procedure CloneTemplateContents(Source, Copy: TElement);
var
  Child: TNode;
  Content: TDocumentFragment;
begin
  if (Source.FRareData = nil) or (Source.FRareData.TemplateContent = nil) then
    Exit;
  Content := Copy.TemplateContent;
  Child := Source.FRareData.TemplateContent.FFirstChild;
  while Child <> nil do
  begin
    AppendChildRaw(Content, CloneTree(Child, Content.FOwnerDocument, True));
    Child := Child.FNextSibling;
  end;
end;

function TNode.CloneNode(Deep: Boolean): TNode;
begin
  Result := CloneTree(Self, nil, Deep);
  if Result.FNodeType <> NodeTypeDocument then
    ListForCollection(Result);
end;

function TNode.IsEqualNode(Other: TNode): Boolean;
var
  A, B: TNode;
begin
  if Other = nil then
    Exit(False);
  A := Self;
  B := Other;
  while True do
  begin
    if not A.IsEqualSelf(B) then
      Exit(False);
    if (A.GetFirstChild = nil) <> (B.GetFirstChild = nil) then
      Exit(False);
    if A.GetFirstChild <> nil then
    begin
      A := A.GetFirstChild;
      B := B.GetFirstChild;
      Continue;
    end;
    while (A <> Self) and (A.FNextSibling = nil) do
    begin
      if B.FNextSibling <> nil then
        Exit(False);
      A := A.FParent;
      B := B.FParent;
    end;
    if A = Self then
      Exit(True);
    if B.FNextSibling = nil then
      Exit(False);
    A := A.FNextSibling;
    B := B.FNextSibling;
  end;
end;

function IsExclusiveText(Node: TNode): Boolean; inline;
begin
  Result := (Node <> nil) and (Node.FNodeType = NodeTypeText);
end;

procedure TNode.Normalize;
var
  Node, Next, Sibling: TNode;
  Combined: string;
  Length: Integer;
begin
  Node := GetFirstChild;
  while Node <> nil do
  begin
    if not IsExclusiveText(Node) then
    begin
      Node := Node.NextInTree(Self);
      Continue;
    end;
    if TText(Node).FData = '' then
    begin
      Next := Node.NextInTreeSkippingChildren(Self);
      Node.FParent.RemoveChild(Node);
      Node := Next;
      Continue;
    end;
    if Node.FOwnerDocument.FLiveRangeCount > 0 then
    begin
      { Each following Text joins in turn, so live ranges in it move
        into Node (DOM Standard normalize(), steps 6.4 to 6.6). }
      while IsExclusiveText(Node.FNextSibling) do
      begin
        Sibling := Node.FNextSibling;
        Length := TText(Node).GetLength;
        TText(Node).ReplaceData(Length, 0, TText(Sibling).FData);
        Node.FOwnerDocument.RangesTextMerged(Sibling, Node, Length);
        Node.FParent.RemoveChild(Sibling);
      end;
      Node := Node.NextInTreeSkippingChildren(Self);
      Continue;
    end;
    Combined := TText(Node).FData;
    Sibling := Node.FNextSibling;
    while IsExclusiveText(Sibling) do
    begin
      Combined := Combined + TText(Sibling).FData;
      Sibling := Sibling.FNextSibling;
    end;
    if Combined <> TText(Node).FData then
      TText(Node).SetData(Combined);
    while IsExclusiveText(Node.FNextSibling) do
      Node.FParent.RemoveChild(Node.FNextSibling);
    Node := Node.NextInTreeSkippingChildren(Self);
  end;
end;

function DescendantTextContent(Node: TNode): string;
var
  Current: TNode;
  Total: SizeInt;
  Position: SizeInt;
begin
  Total := 0;
  Current := Node.GetFirstChild;
  while Current <> nil do
  begin
    if Current.IsText then
      Inc(Total, System.Length(TCharacterData(Current).FData));
    Current := Current.NextInTree(Node);
  end;
  Result := '';
  SetLength(Result, Total);
  Position := 1;
  Current := Node.GetFirstChild;
  while Current <> nil do
  begin
    if Current.IsText and (TCharacterData(Current).FData <> '') then
    begin
      Move(TCharacterData(Current).FData[1], Result[Position], System.Length(TCharacterData(Current).FData));
      Inc(Position, System.Length(TCharacterData(Current).FData));
    end;
    Current := Current.NextInTree(Node);
  end;
end;

{ Namespace lookups (locate a namespace, locate a namespace prefix). }

function LocateNamespace(Node: TNode; const PrefixText: string): string; forward;

function LocateNamespaceOfElement(Element: TElement; const PrefixText: string): string;
var
  Index: Integer;
  Attribute: PAttributeRecord;
begin
  if PrefixText = 'xml' then
    Exit(NameOfAtom(AtomXmlNamespace));
  if PrefixText = 'xmlns' then
    Exit(NameOfAtom(AtomXmlnsNamespace));
  if (Element.NamespaceAtom <> AtomNone) and (NameOfAtom(NamespacePrefix(Element.FNamespaceId)) = PrefixText) then
    Exit(NameOfAtom(Element.NamespaceAtom));
  for Index := 1 to System.Length(Element.FAttributes) do
  begin
    Attribute := @Element.FAttributes[Index - 1];
    if NamespaceUri(Attribute^.NamespaceId) <> AtomXmlnsNamespace then
      Continue;
    if ((NamespacePrefix(Attribute^.NamespaceId) = AtomXmlns) and (NameOfAtom(Attribute^.LocalName) = PrefixText)) or
      ((PrefixText = '') and (NamespacePrefix(Attribute^.NamespaceId) = AtomNone) and
      (Attribute^.LocalName = AtomXmlns)) then
      Exit(Attribute^.Value);
  end;
  if Element.GetParentElement = nil then
    Exit('');
  Result := LocateNamespaceOfElement(Element.GetParentElement, PrefixText);
end;

function LocateNamespace(Node: TNode; const PrefixText: string): string;
begin
  case Node.FNodeType of
    NodeTypeElement:
      Result := LocateNamespaceOfElement(TElement(Node), PrefixText);
    NodeTypeDocument:
      if TDocument(Node).GetDocumentElement = nil then
        Result := ''
      else
        Result := LocateNamespaceOfElement(TDocument(Node).GetDocumentElement, PrefixText);
    NodeTypeDocumentType, NodeTypeDocumentFragment:
      Result := '';
    NodeTypeAttribute:
      if TAttr(Node).FOwnerElement = nil then
        Result := ''
      else
        Result := LocateNamespaceOfElement(TAttr(Node).FOwnerElement, PrefixText);
  else
    if Node.GetParentElement = nil then
      Result := ''
    else
      Result := LocateNamespaceOfElement(Node.GetParentElement, PrefixText);
  end;
end;

function LocatePrefix(Element: TElement; const Namespace: string): string;
var
  Index: Integer;
  Attribute: PAttributeRecord;
begin
  if (NameOfAtom(Element.NamespaceAtom) = Namespace) and (NamespacePrefix(Element.FNamespaceId) <> AtomNone) then
    Exit(NameOfAtom(NamespacePrefix(Element.FNamespaceId)));
  for Index := 1 to System.Length(Element.FAttributes) do
  begin
    Attribute := @Element.FAttributes[Index - 1];
    if (NamespacePrefix(Attribute^.NamespaceId) = AtomXmlns) and (Attribute^.Value = Namespace) then
      Exit(NameOfAtom(Attribute^.LocalName));
  end;
  if Element.GetParentElement = nil then
    Exit('');
  Result := LocatePrefix(Element.GetParentElement, Namespace);
end;

function TNode.LookupPrefix(const Namespace: string): string;
begin
  Result := '';
  if Namespace = '' then
    Exit;
  case FNodeType of
    NodeTypeElement:
      Result := LocatePrefix(TElement(Self), Namespace);
    NodeTypeDocument:
      if TDocument(Self).GetDocumentElement <> nil then
        Result := LocatePrefix(TDocument(Self).GetDocumentElement, Namespace);
    NodeTypeDocumentType, NodeTypeDocumentFragment:
      Result := '';
    NodeTypeAttribute:
      if TAttr(Self).FOwnerElement <> nil then
        Result := LocatePrefix(TAttr(Self).FOwnerElement, Namespace);
  else
    if GetParentElement <> nil then
      Result := LocatePrefix(GetParentElement, Namespace);
  end;
end;

function TNode.LookupNamespaceUri(const PrefixText: string): string;
begin
  Result := LocateNamespace(Self, PrefixText);
end;

function TNode.IsDefaultNamespace(const Namespace: string): Boolean;
begin
  Result := LocateNamespace(Self, '') = Namespace;
end;

{ ParentNode and ChildNode }

function TNode.FirstElementChild: TElement;
var
  Child: TNode;
begin
  Child := GetFirstChild;
  while (Child <> nil) and (Child.FNodeType <> NodeTypeElement) do
    Child := Child.FNextSibling;
  Result := TElement(Child);
end;

function TNode.LastElementChild: TElement;
var
  Child: TNode;
begin
  Child := GetLastChild;
  while (Child <> nil) and (Child.FNodeType <> NodeTypeElement) do
    Child := Child.FPreviousSibling;
  Result := TElement(Child);
end;

function TNode.ChildElementCount: Integer;
var
  Child: TNode;
begin
  Result := 0;
  Child := GetFirstChild;
  while Child <> nil do
  begin
    if Child.FNodeType = NodeTypeElement then
      Inc(Result);
    Child := Child.FNextSibling;
  end;
end;
