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
  Web.Dom: NodeList (live children and fixed lists), live
  HTMLCollection (children, getElementsByTagName, getElementsByTagNameNS,
  getElementsByClassName) and DOMTokenList. Live lists recompute when
  the global DOM version has moved since they last looked; a child list
  remembers where it last was, so walking it in order is linear.
}

constructor TStaticNodeList.Create(const Nodes: TNodeArray);
var
  Index: Integer;
begin
  inherited Create;
  FNodes := Copy(Nodes);
  for Index := 1 to System.Length(FNodes) do
    FNodes[Index - 1].Retain;
end;

destructor TStaticNodeList.Destroy;
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FNodes) do
    FNodes[Index - 1].Release;
  inherited Destroy;
end;

function TStaticNodeList.GetLength: Integer;
begin
  Result := System.Length(FNodes);
end;

function TStaticNodeList.Item(Index: Integer): TNode;
begin
  if (Index < 0) or (Index >= System.Length(FNodes)) then
    Result := nil
  else
    Result := FNodes[Index];
end;

constructor TChildNodeList.Create(Parent: TNode);
begin
  inherited Create;
  FParent := Parent;
  FVersion := GlobalDomVersion - 1;
end;

procedure TChildNodeList.Refresh;
begin
  if FVersion = GlobalDomVersion then
    Exit;
  FVersion := GlobalDomVersion;
  FCachedLength := FParent.ChildCount;
  FCursorIndex := 0;
  FCursorNode := FParent.GetFirstChild;
end;

function TChildNodeList.GetLength: Integer;
begin
  Refresh;
  Result := FCachedLength;
end;

function TChildNodeList.Item(Index: Integer): TNode;
begin
  Refresh;
  if (Index < 0) or (Index >= FCachedLength) then
    Exit(nil);
  if (FCursorNode = nil) or (Index < FCursorIndex div 2) then
  begin
    FCursorIndex := 0;
    FCursorNode := FParent.GetFirstChild;
  end;
  while FCursorIndex < Index do
  begin
    FCursorNode := FCursorNode.FNextSibling;
    Inc(FCursorIndex);
  end;
  while FCursorIndex > Index do
  begin
    FCursorNode := FCursorNode.FPreviousSibling;
    Dec(FCursorIndex);
  end;
  Result := FCursorNode;
end;

constructor THtmlCollection.Create(Root: TNode; OwnedByRoot: Boolean);
begin
  inherited Create;
  FRoot := Root;
  FOwnedByRoot := OwnedByRoot;
  if not OwnedByRoot then
    FRoot.Retain;
end;

destructor THtmlCollection.Destroy;
begin
  if (FRoot <> nil) and not FOwnedByRoot then
    FRoot.Release;
  inherited Destroy;
end;

function THtmlCollection.ChildrenOnly: Boolean;
begin
  Result := False;
end;

procedure THtmlCollection.Refresh;
var
  Node: TNode;
begin
  if FValid and (FVersion = GlobalDomVersion) then
    Exit;
  FVersion := GlobalDomVersion;
  FValid := True;
  FCount := 0;
  Node := FRoot.GetFirstChild;
  while Node <> nil do
  begin
    if (Node.FNodeType = NodeTypeElement) and Matches(TElement(Node)) then
    begin
      if FCount >= System.Length(FElements) then
        SetLength(FElements, FCount * 2 + 8);
      FElements[FCount] := TElement(Node);
      Inc(FCount);
    end;
    if ChildrenOnly then
      Node := Node.FNextSibling
    else
      Node := Node.NextInTree(FRoot);
  end;
end;

function THtmlCollection.GetLength: Integer;
begin
  Refresh;
  Result := FCount;
end;

function THtmlCollection.Item(Index: Integer): TElement;
begin
  Refresh;
  if (Index < 0) or (Index >= FCount) then
    Result := nil
  else
    Result := FElements[Index];
end;

function THtmlCollection.NamedItem(const Name: string): TElement;
var
  Index: Integer;
  Element: TElement;
begin
  Result := nil;
  if Name = '' then
    Exit;
  Refresh;
  for Index := 1 to FCount do
  begin
    Element := FElements[Index - 1];
    if (Element.AttributeValueOf(AtomId) = Name) or
      (Element.IsHtml and (Element.AttributeValueOf(AtomName) = Name)) then
      Exit(Element);
  end;
end;

type
  TChildrenCollection = class(THtmlCollection)
  protected
    function Matches(Element: TElement): Boolean; override;
    function ChildrenOnly: Boolean; override;
  end;

  TAllElementsCollection = class(THtmlCollection)
  protected
    function Matches(Element: TElement): Boolean; override;
  end;

  { getElementsByTagName in an HTML document: HTML elements by the lower
    case name, others by the name as given. }
  TTagNameCollection = class(THtmlCollection)
  private
    FLowerName: string;
    FName: string;
    FHtmlDocument: Boolean;
  protected
    function Matches(Element: TElement): Boolean; override;
  end;

  TTagNameNSCollection = class(THtmlCollection)
  private
    FAnyNamespace: Boolean;
    FNamespace: TAtom;
    FAnyName: Boolean;
    FLocalName: TAtom;
  protected
    function Matches(Element: TElement): Boolean; override;
  end;

  TClassNameCollection = class(THtmlCollection)
  private
    FClasses: TAtomArray;
    FClassTexts: TStringArray;
    FQuirks: Boolean;
  protected
    function Matches(Element: TElement): Boolean; override;
  end;

function TChildrenCollection.Matches(Element: TElement): Boolean;
begin
  Result := True;
end;

function TChildrenCollection.ChildrenOnly: Boolean;
begin
  Result := True;
end;

function TAllElementsCollection.Matches(Element: TElement): Boolean;
begin
  Result := True;
end;

function TTagNameCollection.Matches(Element: TElement): Boolean;
var
  Name: string;
begin
  Name := QualifiedNameOf(Element.FLocalName, Element.FNamespaceId);
  if FHtmlDocument and Element.IsHtml then
    Result := Name = FLowerName
  else
    Result := Name = FName;
end;

function TTagNameNSCollection.Matches(Element: TElement): Boolean;
begin
  Result := (FAnyNamespace or (Element.NamespaceAtom = FNamespace)) and (FAnyName or (Element.FLocalName = FLocalName));
end;

function TClassNameCollection.Matches(Element: TElement): Boolean;
var
  Index, Have: Integer;
  Atoms: TAtomArray;
  Found: Boolean;
begin
  if System.Length(FClasses) = 0 then
    Exit(False);
  Atoms := Element.ClassAtoms;
  for Index := 1 to System.Length(FClasses) do
  begin
    Found := False;
    for Have := 1 to System.Length(Atoms) do
      if (Atoms[Have - 1] = FClasses[Index - 1]) or
        (FQuirks and (AsciiLowerCase(NameOfAtom(Atoms[Have - 1])) = FClassTexts[Index - 1])) then
      begin
        Found := True;
        Break;
      end;
    if not Found then
      Exit(False);
  end;
  Result := True;
end;

function TNode.Children: THtmlCollection;
begin
  if RareData.ChildrenCollection = nil then
  begin
    { Owned by the node: no reference back, which would keep it alive. }
    FRareData.ChildrenCollection := TChildrenCollection.Create(Self, True);
  end;
  Result := FRareData.ChildrenCollection;
end;

function TNode.GetElementsByTagName(const QualifiedName: string): THtmlCollection;
var
  Collection: TTagNameCollection;
begin
  if QualifiedName = '*' then
    Exit(TAllElementsCollection.Create(Self));
  Collection := TTagNameCollection.Create(Self);
  Collection.FName := QualifiedName;
  Collection.FLowerName := AsciiLowerCase(QualifiedName);
  Collection.FHtmlDocument := FOwnerDocument.FIsHtmlDocument;
  Result := Collection;
end;

function TNode.GetElementsByTagNameNS(const Namespace, LocalNameText: string): THtmlCollection;
var
  Collection: TTagNameNSCollection;
begin
  Collection := TTagNameNSCollection.Create(Self);
  Collection.FAnyNamespace := Namespace = '*';
  Collection.FNamespace := Atomize(Namespace);
  Collection.FAnyName := LocalNameText = '*';
  Collection.FLocalName := Atomize(LocalNameText);
  Result := Collection;
end;

function TNode.GetElementsByClassName(const ClassNames: string): THtmlCollection;
var
  Collection: TClassNameCollection;
  Tokens: TStringArray;
  Index: Integer;
begin
  Collection := TClassNameCollection.Create(Self);
  Tokens := SplitTokens(ClassNames, True);
  Collection.FQuirks := FOwnerDocument.FMode = DocumentModeQuirks;
  SetLength(Collection.FClasses, System.Length(Tokens));
  SetLength(Collection.FClassTexts, System.Length(Tokens));
  for Index := 1 to System.Length(Tokens) do
  begin
    Collection.FClasses[Index - 1] := Atomize(Tokens[Index - 1]);
    Collection.FClassTexts[Index - 1] := AsciiLowerCase(Tokens[Index - 1]);
  end;
  Result := Collection;
end;

{ DOMTokenList }

constructor TDomTokenList.Create(Element: TElement; AttributeName: TAtom);
begin
  inherited Create;
  FElement := Element;
  FAttributeName := AttributeName;
end;

procedure TDomTokenList.Update;
var
  Current: string;
begin
  Current := FElement.AttributeValueOf(FAttributeName);
  if FParsed and (Pointer(Current) = Pointer(FSource)) then
    Exit;
  FSource := Current;
  FTokens := SplitTokens(Current, True);
  FParsed := True;
end;

procedure TDomTokenList.WriteBack;
var
  Text: string;
  Index: Integer;
begin
  if not FElement.HasAttributeAtom(FAttributeName) and (System.Length(FTokens) = 0) then
    Exit;
  Text := '';
  for Index := 1 to System.Length(FTokens) do
  begin
    if Index > 1 then
      Text := Text + ' ';
    Text := Text + FTokens[Index - 1];
  end;
  FElement.SetAttributeAtom(FAttributeName, NamespaceNone, Text);
  FSource := FElement.AttributeValueOf(FAttributeName);
end;

function TDomTokenList.GetValue: string;
begin
  Result := FElement.AttributeValueOf(FAttributeName);
end;

procedure TDomTokenList.SetValue(const NewValue: string);
begin
  FElement.SetAttributeAtom(FAttributeName, NamespaceNone, NewValue);
end;

function TDomTokenList.GetLength: Integer;
begin
  Update;
  Result := System.Length(FTokens);
end;

function TDomTokenList.Item(Index: Integer): string;
begin
  Update;
  if (Index < 0) or (Index >= System.Length(FTokens)) then
    Result := ''
  else
    Result := FTokens[Index];
end;

function TokenIndex(const Tokens: TStringArray; const Token: string): Integer;
var
  Index: Integer;
begin
  for Index := 1 to System.Length(Tokens) do
    if Tokens[Index - 1] = Token then
      Exit(Index - 1);
  Result := -1;
end;

procedure ValidateToken(const Token: string);
begin
  if Token = '' then
    RaiseDomError(SyntaxError, 'the token is empty');
  if ContainsAnyOf(Token, [#9, #10, #12, #13, ' ']) then
    RaiseDomError(InvalidCharacterError, 'the token contains whitespace');
end;

procedure DeleteToken(var Tokens: TStringArray; Index: Integer);
var
  Position: Integer;
begin
  for Position := Index + 1 to High(Tokens) do
    Tokens[Position - 1] := Tokens[Position];
  SetLength(Tokens, System.Length(Tokens) - 1);
end;

function TDomTokenList.Contains(const Token: string): Boolean;
begin
  Update;
  Result := TokenIndex(FTokens, Token) >= 0;
end;

procedure TDomTokenList.Add(const Tokens: array of string);
var
  Index: Integer;
begin
  for Index := 0 to High(Tokens) do
    ValidateToken(Tokens[Index]);
  Update;
  for Index := 0 to High(Tokens) do
    if TokenIndex(FTokens, Tokens[Index]) < 0 then
    begin
      SetLength(FTokens, System.Length(FTokens) + 1);
      FTokens[High(FTokens)] := Tokens[Index];
    end;
  WriteBack;
end;

procedure TDomTokenList.Remove(const Tokens: array of string);
var
  Index, Found: Integer;
begin
  for Index := 0 to High(Tokens) do
    ValidateToken(Tokens[Index]);
  Update;
  for Index := 0 to High(Tokens) do
  begin
    Found := TokenIndex(FTokens, Tokens[Index]);
    if Found >= 0 then
      DeleteToken(FTokens, Found);
  end;
  WriteBack;
end;

function TDomTokenList.Toggle(const Token: string; Force: Integer): Boolean;
var
  Found: Integer;
begin
  ValidateToken(Token);
  Update;
  Found := TokenIndex(FTokens, Token);
  if Found >= 0 then
  begin
    if Force <> 1 then
    begin
      DeleteToken(FTokens, Found);
      WriteBack;
      Exit(False);
    end;
    Exit(True);
  end;
  if Force <> 0 then
  begin
    SetLength(FTokens, System.Length(FTokens) + 1);
    FTokens[High(FTokens)] := Token;
    WriteBack;
    Exit(True);
  end;
  Result := False;
end;

function TDomTokenList.Replace(const Token, NewToken: string): Boolean;
var
  Index: Integer;
  Placed: Boolean;
begin
  ValidateToken(Token);
  ValidateToken(NewToken);
  Update;
  if TokenIndex(FTokens, Token) < 0 then
    Exit(False);
  Placed := False;
  Index := 0;
  while Index < System.Length(FTokens) do
  begin
    if (FTokens[Index] = Token) or (FTokens[Index] = NewToken) then
    begin
      if not Placed then
      begin
        FTokens[Index] := NewToken;
        Placed := True;
        Inc(Index);
      end
      else
        DeleteToken(FTokens, Index);
    end
    else
      Inc(Index);
  end;
  WriteBack;
  Result := True;
end;
