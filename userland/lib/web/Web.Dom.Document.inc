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
  Web.Dom: Document and DocumentFragment. Making nodes, the id map,
  connecting and disconnecting subtrees, the observers, and the HTML
  document's head, body and title.
}

type
  { The elements of a document by id: each id keeps its connected
    elements (in no order) and the first of them in tree order, found
    by a walk when needed and kept until the id's elements change. }
  TIdEntry = class
  public
    Id: string;
    Elements: TElementArray;
    Count: Integer;
    First: TElement;
    Next: TIdEntry;
  end;

  TIdMap = class
  private
    FBuckets: array of TIdEntry;
    FEntryCount: Integer;
    function HashOf(const Id: string): LongWord;
    function Find(const Id: string): TIdEntry;
    procedure Grow;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(Element: TElement; const Id: string);
    procedure Remove(Element: TElement; const Id: string);
    function Lookup(Document: TDocument; const Id: string): TElement;
  end;

constructor TIdMap.Create;
begin
  inherited Create;
  SetLength(FBuckets, 64);
end;

destructor TIdMap.Destroy;
var
  Index: Integer;
  Entry, Next: TIdEntry;
begin
  for Index := 0 to High(FBuckets) do
  begin
    Entry := FBuckets[Index];
    while Entry <> nil do
    begin
      Next := Entry.Next;
      Entry.Free;
      Entry := Next;
    end;
  end;
  inherited Destroy;
end;

function TIdMap.HashOf(const Id: string): LongWord;
var
  Index: Integer;
  Hash: QWord;
begin
  Hash := 2166136261;
  for Index := 1 to System.Length(Id) do
    Hash := ((Hash xor Ord(Id[Index])) * 16777619) and $FFFFFFFF;
  Result := LongWord(Hash) and LongWord(High(FBuckets));
end;

function TIdMap.Find(const Id: string): TIdEntry;
begin
  Result := FBuckets[HashOf(Id)];
  while (Result <> nil) and (Result.Id <> Id) do
    Result := Result.Next;
end;

procedure TIdMap.Grow;
var
  OldBuckets: array of TIdEntry;
  Index: Integer;
  Entry, Next: TIdEntry;
  Bucket: LongWord;
begin
  OldBuckets := FBuckets;
  FBuckets := nil;
  SetLength(FBuckets, System.Length(OldBuckets) * 2);
  for Index := 0 to High(OldBuckets) do
  begin
    Entry := OldBuckets[Index];
    while Entry <> nil do
    begin
      Next := Entry.Next;
      Bucket := HashOf(Entry.Id);
      Entry.Next := FBuckets[Bucket];
      FBuckets[Bucket] := Entry;
      Entry := Next;
    end;
  end;
end;

procedure TIdMap.Add(Element: TElement; const Id: string);
var
  Entry: TIdEntry;
  Bucket: LongWord;
begin
  if Id = '' then
    Exit;
  Entry := Find(Id);
  if Entry = nil then
  begin
    if FEntryCount >= System.Length(FBuckets) then
      Grow;
    Entry := TIdEntry.Create;
    Entry.Id := Id;
    Bucket := HashOf(Id);
    Entry.Next := FBuckets[Bucket];
    FBuckets[Bucket] := Entry;
    Inc(FEntryCount);
  end;
  if Entry.Count >= System.Length(Entry.Elements) then
    SetLength(Entry.Elements, Entry.Count * 2 + 1);
  Entry.Elements[Entry.Count] := Element;
  Inc(Entry.Count);
  Entry.First := nil;
end;

procedure TIdMap.Remove(Element: TElement; const Id: string);
var
  Entry, Previous: TIdEntry;
  Index: Integer;
  Bucket: LongWord;
begin
  if Id = '' then
    Exit;
  Entry := Find(Id);
  if Entry = nil then
    Exit;
  for Index := 1 to Entry.Count do
    if Entry.Elements[Index - 1] = Element then
    begin
      Entry.Elements[Index - 1] := Entry.Elements[Entry.Count - 1];
      Dec(Entry.Count);
      Break;
    end;
  Entry.First := nil;
  if Entry.Count > 0 then
    Exit;
  Bucket := HashOf(Id);
  if FBuckets[Bucket] = Entry then
    FBuckets[Bucket] := Entry.Next
  else
  begin
    Previous := FBuckets[Bucket];
    while Previous.Next <> Entry do
      Previous := Previous.Next;
    Previous.Next := Entry.Next;
  end;
  Entry.Free;
  Dec(FEntryCount);
end;

function TIdMap.Lookup(Document: TDocument; const Id: string): TElement;
var
  Entry: TIdEntry;
  Node: TNode;
  Index: Integer;
begin
  Entry := Find(Id);
  if Entry = nil then
    Exit(nil);
  if Entry.Count = 1 then
    Exit(Entry.Elements[0]);
  if Entry.First = nil then
  begin
    { The first in tree order of several: walk the document. }
    Node := Document.GetFirstChild;
    while (Node <> nil) and (Entry.First = nil) do
    begin
      if (Node.FNodeType = NodeTypeElement) and ((Node.FFlags and NodeFlagHasId) <> 0) then
        for Index := 1 to Entry.Count do
          if Entry.Elements[Index - 1] = Node then
          begin
            Entry.First := TElement(Node);
            Break;
          end;
      Node := Node.NextInTree(Document);
    end;
  end;
  Result := Entry.First;
end;

constructor TDocument.CreateDocument(HtmlDocument: Boolean);
begin
  inherited Create;
  InitializeNode(Self, NodeTypeDocument, Self);
  FFlags := FFlags or NodeFlagConnected;
  FSubtreeReferences := 1;
  FIsHtmlDocument := HtmlDocument;
  if HtmlDocument then
    FContentType := 'text/html'
  else
    FContentType := 'application/xml';
  FCharacterSet := 'UTF-8';
  FUrl := 'about:blank';
  FMode := DocumentModeNoQuirks;
  FIdMap := TIdMap.Create;
end;

procedure FreeChildren(Parent: TContainerNode);
var
  Child: TNode;
begin
  while Parent.FFirstChild <> nil do
  begin
    Child := Parent.FFirstChild;
    Parent.FFirstChild := Child.FNextSibling;
    Child.FParent := nil;
    Child.FPreviousSibling := nil;
    Child.FNextSibling := nil;
    FreeTree(Child);
  end;
  Parent.FLastChild := nil;
end;

destructor TDocument.Destroy;
begin
  FreeListedNodes;
  FreeChildren(Self);
  FreeAndNil(FRareData);
  if (FTemplateContentsOwner <> nil) and (FTemplateContentsOwner <> Self) then
    FTemplateContentsOwner.Release;
  FIdMap.Free;
  inherited Destroy;
end;

function TDocument.GetNodeName: string;
begin
  Result := '#document';
end;

function TDocument.GetTextContent: string;
begin
  Result := '';
end;

procedure TDocument.SetTextContent(const Value: string);
begin
end;

function TDocument.CloneSelf(Document: TDocument): TNode;
var
  Copy: TDocument;
begin
  Copy := TDocument.CreateDocument(FIsHtmlDocument);
  Copy.FContentType := FContentType;
  Copy.FCharacterSet := FCharacterSet;
  Copy.FUrl := FUrl;
  Copy.FMode := FMode;
  Result := Copy;
end;

function TDocument.ElementClassFor(LocalAtom: TAtom; Namespace: TNamespaceId): TElementClass;
begin
  Result := TElement;
end;

function TDocument.NewElement(LocalAtom: TAtom; Namespace: TNamespaceId): TElement;
begin
  Result := ElementClassFor(LocalAtom, Namespace).Create;
  InitializeNode(Result, NodeTypeElement, Self);
  Result.FLocalName := LocalAtom;
  Result.FNamespaceId := Namespace;
end;

function TDocument.NewText(const Text: string): TText;
begin
  Result := TText.Create;
  InitializeNode(Result, NodeTypeText, Self);
  Result.FData := Text;
end;

function TDocument.NewComment(const Text: string): TComment;
begin
  Result := TComment.Create;
  InitializeNode(Result, NodeTypeComment, Self);
  Result.FData := Text;
end;

function TDocument.NewDocumentType(const DoctypeName, PublicIdText, SystemIdText: string): TDocumentType;
begin
  Result := TDocumentType.Create;
  InitializeNode(Result, NodeTypeDocumentType, Self);
  Result.FName := DoctypeName;
  Result.FPublicId := PublicIdText;
  Result.FSystemId := SystemIdText;
end;

function TDocument.CreateElement(const LocalNameText: string): TElement;
var
  Name: string;
  Namespace: TNamespaceId;
begin
  if not IsValidElementLocalName(LocalNameText) then
    RaiseDomError(InvalidCharacterError, 'the element name is not valid');
  Name := LocalNameText;
  if FIsHtmlDocument then
    Name := AsciiLowerCase(Name);
  if FIsHtmlDocument or (FContentType = 'application/xhtml+xml') then
    Namespace := NamespaceHtml
  else
    Namespace := NamespaceNone;
  Result := NewElement(Atomize(Name), Namespace);
  ListForCollection(Result);
end;

function TDocument.CreateElementNS(const Namespace, QualifiedName: string): TElement;
var
  QualifierId: TNamespaceId;
  NameAtom: TAtom;
begin
  ValidateAndExtract(Namespace, QualifiedName, NameContextElement, QualifierId, NameAtom);
  Result := NewElement(NameAtom, QualifierId);
  ListForCollection(Result);
end;

function TDocument.CreateDocumentFragment: TDocumentFragment;
begin
  Result := TDocumentFragment.Create;
  InitializeNode(Result, NodeTypeDocumentFragment, Self);
  ListForCollection(Result);
end;

function TDocument.CreateTextNode(const Text: string): TText;
begin
  Result := NewText(Text);
  ListForCollection(Result);
end;

function TDocument.CreateCDataSection(const Text: string): TCDataSection;
begin
  if FIsHtmlDocument then
    RaiseDomError(NotSupportedError, 'HTML documents have no CDATA sections');
  if Pos(']]>', Text) > 0 then
    RaiseDomError(InvalidCharacterError, 'the data contains "]]>"');
  Result := TCDataSection.Create;
  InitializeNode(Result, NodeTypeCDataSection, Self);
  Result.FData := Text;
  ListForCollection(Result);
end;

function TDocument.CreateComment(const Text: string): TComment;
begin
  Result := NewComment(Text);
  ListForCollection(Result);
end;

function TDocument.CreateProcessingInstruction(const TargetText, Text: string): TProcessingInstruction;
begin
  if not IsValidAttributeLocalName(TargetText) or ContainsAnyOf(TargetText, [':']) then
    RaiseDomError(InvalidCharacterError, 'the target is not a valid name');
  if Pos('?>', Text) > 0 then
    RaiseDomError(InvalidCharacterError, 'the data contains "?>"');
  Result := TProcessingInstruction.Create;
  InitializeNode(Result, NodeTypeProcessingInstruction, Self);
  Result.FTarget := TargetText;
  Result.FData := Text;
  ListForCollection(Result);
end;

function TDocument.CreateAttribute(const LocalNameText: string): TAttr;
var
  Name: string;
begin
  if not IsValidAttributeLocalName(LocalNameText) then
    RaiseDomError(InvalidCharacterError, 'the attribute name is not valid');
  Name := LocalNameText;
  if FIsHtmlDocument then
    Name := AsciiLowerCase(Name);
  Result := TAttr.Create;
  InitializeNode(Result, NodeTypeAttribute, Self);
  Result.FLocalName := Atomize(Name);
  ListForCollection(Result);
end;

function TDocument.CreateAttributeNS(const Namespace, QualifiedName: string): TAttr;
var
  QualifierId: TNamespaceId;
  NameAtom: TAtom;
begin
  ValidateAndExtract(Namespace, QualifiedName, NameContextAttribute, QualifierId, NameAtom);
  Result := TAttr.Create;
  InitializeNode(Result, NodeTypeAttribute, Self);
  Result.FLocalName := NameAtom;
  Result.FNamespaceId := QualifierId;
  ListForCollection(Result);
end;

function TDocument.CreateDocumentType(const QualifiedName, PublicIdText, SystemIdText: string): TDocumentType;
begin
  if not IsValidDoctypeName(QualifiedName) then
    RaiseDomError(InvalidCharacterError, 'the doctype name is not valid');
  Result := NewDocumentType(QualifiedName, PublicIdText, SystemIdText);
  ListForCollection(Result);
end;

function TDocument.ImportNode(Node: TNode; Deep: Boolean): TNode;
begin
  if Node.FNodeType = NodeTypeDocument then
    RaiseDomError(NotSupportedError, 'a document cannot be imported');
  Result := CloneTree(Node, Self, Deep);
  ListForCollection(Result);
end;

function TDocument.AdoptNode(Node: TNode): TNode;
begin
  if Node.FNodeType = NodeTypeDocument then
    RaiseDomError(NotSupportedError, 'a document cannot be adopted');
  Result := Node;
  if IsHostedRoot(Node) then
    Exit;
  if Node.FNodeType = NodeTypeAttribute then
  begin
    if TAttr(Node).FOwnerElement <> nil then
      TAttr(Node).FOwnerElement.RemoveAttributeNode(TAttr(Node));
    if Node.FOwnerDocument <> Self then
    begin
      RootChangedDocument(Node, Node.FOwnerDocument, Self);
      Node.FOwnerDocument := Self;
    end;
    Exit;
  end;
  AdoptInto(Node, Self);
end;

function TDocument.GetElementById(const IdValue: string): TElement;
begin
  if IdValue = '' then
    Exit(nil);
  Result := TIdMap(FIdMap).Lookup(Self, IdValue);
end;

procedure TDocument.RegisterId(Element: TElement; const IdValue: string);
begin
  TIdMap(FIdMap).Add(Element, IdValue);
end;

procedure TDocument.UnregisterId(Element: TElement; const IdValue: string);
begin
  TIdMap(FIdMap).Remove(Element, IdValue);
end;

function TDocument.TemplateContentsOwner: TDocument;
begin
  if FIsTemplateContentsOwner then
    Exit(Self);
  if FTemplateContentsOwner = nil then
  begin
    FTemplateContentsOwner := TDocument.CreateDocument(FIsHtmlDocument);
    FTemplateContentsOwner.FIsTemplateContentsOwner := True;
    FTemplateContentsOwner.FMode := FMode;
  end;
  Result := FTemplateContentsOwner;
end;

procedure TDocument.AddObserver(Observer: TDocumentObserver);
begin
  SetLength(FObservers, System.Length(FObservers) + 1);
  FObservers[High(FObservers)] := Observer;
end;

procedure TDocument.RemoveObserver(Observer: TDocumentObserver);
var
  Index, Position: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    if FObservers[Index - 1] = Observer then
    begin
      for Position := Index to High(FObservers) do
        FObservers[Position - 1] := FObservers[Position];
      SetLength(FObservers, System.Length(FObservers) - 1);
      Exit;
    end;
end;

procedure TDocument.NotifyTreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousNode,
  NextNode: TNode);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].TreeMutated(Target, Added, Removed, PreviousNode, NextNode);
end;

procedure TDocument.NotifyChildrenChanged(Parent: TNode);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].ChildrenChanged(Parent);
end;

procedure TDocument.NotifyAttributeChanged(Element: TElement; LocalAtom: TAtom; Namespace: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].AttributeChanged(Element, LocalAtom, Namespace, OldValue, HadValue);
end;

procedure TDocument.NotifyCharacterDataChanged(Node: TCharacterData; const OldValue: string);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].CharacterDataChanged(Node, OldValue);
end;

procedure TDocument.SubtreeConnected(Root: TNode);
var
  Node: TNode;
  Index: Integer;
begin
  Node := Root;
  while Node <> nil do
  begin
    Node.FFlags := Node.FFlags or NodeFlagConnected;
    if (Node.FFlags and NodeFlagHasId) <> 0 then
      RegisterId(TElement(Node), TElement(Node).AttributeValueOf(AtomId));
    for Index := 1 to System.Length(FObservers) do
      FObservers[Index - 1].NodeConnected(Node);
    Node := Node.NextInTree(Root);
  end;
end;

procedure TDocument.SubtreeDisconnected(Root: TNode);
var
  Node: TNode;
  Index: Integer;
begin
  Node := Root;
  while Node <> nil do
  begin
    Node.FFlags := Node.FFlags and not NodeFlagConnected;
    if (Node.FFlags and NodeFlagHasId) <> 0 then
      UnregisterId(TElement(Node), TElement(Node).AttributeValueOf(AtomId));
    for Index := 1 to System.Length(FObservers) do
      FObservers[Index - 1].NodeDisconnected(Node);
    Node := Node.NextInTree(Root);
  end;
end;

function TDocument.GetDocumentElement: TElement;
begin
  Result := FirstElementChild;
end;

function TDocument.GetDoctype: TDocumentType;
var
  Child: TNode;
begin
  Child := FFirstChild;
  while (Child <> nil) and (Child.FNodeType <> NodeTypeDocumentType) do
    Child := Child.FNextSibling;
  Result := TDocumentType(Child);
end;

function HtmlRootElement(Document: TDocument): TElement;
begin
  Result := Document.GetDocumentElement;
  if (Result <> nil) and not Result.IsHtmlElement(AtomHtml) then
    Result := nil;
end;

function TDocument.GetHead: TElement;
var
  Root: TElement;
  Child: TNode;
begin
  Result := nil;
  Root := HtmlRootElement(Self);
  if Root = nil then
    Exit;
  Child := Root.FFirstChild;
  while Child <> nil do
  begin
    if (Child.FNodeType = NodeTypeElement) and TElement(Child).IsHtmlElement(AtomHead) then
      Exit(TElement(Child));
    Child := Child.FNextSibling;
  end;
end;

function TDocument.GetBody: TElement;
var
  Root: TElement;
  Child: TNode;
begin
  Result := nil;
  Root := HtmlRootElement(Self);
  if Root = nil then
    Exit;
  Child := Root.FFirstChild;
  while Child <> nil do
  begin
    if (Child.FNodeType = NodeTypeElement) and (TElement(Child).IsHtmlElement(AtomBody) or
      TElement(Child).IsHtmlElement(AtomFrameset)) then
      Exit(TElement(Child));
    Child := Child.FNextSibling;
  end;
end;

function TDocument.GetCompatMode: string;
begin
  if FMode = DocumentModeQuirks then
    Result := 'BackCompat'
  else
    Result := 'CSS1Compat';
end;

{ Strips and collapses ASCII whitespace. }
function CollapseWhitespace(const Text: string): string;
var
  Index: Integer;
  PendingSpace: Boolean;
begin
  Result := '';
  PendingSpace := False;
  for Index := 1 to System.Length(Text) do
    if Text[Index] in [#9, #10, #12, #13, ' '] then
      PendingSpace := Result <> ''
    else
    begin
      if PendingSpace then
        Result := Result + ' ';
      PendingSpace := False;
      Result := Result + Text[Index];
    end;
end;

function TDocument.GetTitle: string;
var
  Node: TNode;
begin
  Node := FFirstChild;
  while Node <> nil do
  begin
    if (Node.FNodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomTitle) then
      Exit(CollapseWhitespace(DescendantTextContent(Node)));
    Node := Node.NextInTree(Self);
  end;
  Result := '';
end;

function TDocumentFragment.GetNodeName: string;
begin
  Result := '#document-fragment';
end;

function TDocumentFragment.GetTextContent: string;
begin
  Result := DescendantTextContent(Self);
end;

procedure TDocumentFragment.SetTextContent(const Value: string);
begin
  StringReplaceAll(Self, Value);
end;

function TDocumentFragment.CloneSelf(Document: TDocument): TNode;
var
  Copy: TDocumentFragment;
begin
  Copy := TDocumentFragment.Create;
  InitializeNode(Copy, NodeTypeDocumentFragment, Document);
  Result := Copy;
end;
