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
  Web.Dom: Element. Names, id and classes, template contents, the
  element side of attributes (the compact records and the change
  steps), cloning and equality.
}

destructor TElement.Destroy;
begin
  inherited Destroy;
end;

function TElement.IsHtml: Boolean;
begin
  Result := (FNamespaceId = NamespaceHtml) or (Web.Namespaces.NamespaceUri(FNamespaceId) = AtomHtmlNamespace);
end;

function TElement.IsHtmlElement(Name: TAtom): Boolean;
begin
  Result := (FLocalName = Name) and IsHtml;
end;

function TElement.NamespaceAtom: TAtom;
begin
  Result := Web.Namespaces.NamespaceUri(FNamespaceId);
end;

function TElement.GetLocalName: string;
begin
  Result := NameOfAtom(FLocalName);
end;

function TElement.GetNamespaceUri: string;
begin
  Result := NameOfAtom(NamespaceAtom);
end;

function TElement.GetPrefix: string;
begin
  Result := NameOfAtom(NamespacePrefix(FNamespaceId));
end;

function QualifiedNameOf(LocalAtom: TAtom; Namespace: TNamespaceId): string;
var
  PrefixAtom: TAtom;
begin
  PrefixAtom := NamespacePrefix(Namespace);
  if PrefixAtom = AtomNone then
    Result := NameOfAtom(LocalAtom)
  else
    Result := NameOfAtom(PrefixAtom) + ':' + NameOfAtom(LocalAtom);
end;

function TElement.GetTagName: string;
begin
  Result := QualifiedNameOf(FLocalName, FNamespaceId);
  if IsHtml and FOwnerDocument.FIsHtmlDocument then
    Result := AsciiUpperCase(Result);
end;

function TElement.GetNodeName: string;
begin
  Result := GetTagName;
end;

function TElement.GetTextContent: string;
begin
  Result := DescendantTextContent(Self);
end;

procedure TElement.SetTextContent(const Value: string);
begin
  StringReplaceAll(Self, Value);
end;

function TElement.GetId: string;
begin
  Result := AttributeValueOf(AtomId);
end;

procedure TElement.SetId(const Value: string);
begin
  SetAttributeAtom(AtomId, NamespaceNone, Value);
end;

function TElement.GetClassValue: string;
begin
  Result := AttributeValueOf(AtomClass);
end;

procedure TElement.SetClassValue(const Value: string);
begin
  SetAttributeAtom(AtomClass, NamespaceNone, Value);
end;

function TElement.GetClassList: TDomTokenList;
begin
  if RareData.ClassList = nil then
    RareData.ClassList := TDomTokenList.Create(Self, AtomClass);
  Result := RareData.ClassList;
end;

{ Splits on ASCII whitespace (an ordered set when Unique). }
function SplitTokens(const Text: string; Unique: Boolean): TStringArray;
var
  Index, Start, Count, Existing: Integer;
  Token: string;
  Duplicate: Boolean;
begin
  Result := nil;
  Count := 0;
  Index := 1;
  while Index <= System.Length(Text) do
  begin
    while (Index <= System.Length(Text)) and (Text[Index] in [#9, #10, #12, #13, ' ']) do
      Inc(Index);
    if Index > System.Length(Text) then
      Break;
    Start := Index;
    while (Index <= System.Length(Text)) and not (Text[Index] in [#9, #10, #12, #13, ' ']) do
      Inc(Index);
    Token := Copy(Text, Start, Index - Start);
    Duplicate := False;
    if Unique then
      for Existing := 1 to Count do
        if Result[Existing - 1] = Token then
        begin
          Duplicate := True;
          Break;
        end;
    if Duplicate then
      Continue;
    if Count >= System.Length(Result) then
      SetLength(Result, Count * 2 + 4);
    Result[Count] := Token;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function TElement.ClassAtoms: TAtomArray;
var
  Tokens: TStringArray;
  Index: Integer;
  Source: string;
begin
  Result := nil;
  if (FFlags and NodeFlagHasClass) = 0 then
    Exit;
  Source := AttributeValueOf(AtomClass);
  if (FRareData <> nil) and FRareData.ClassAtomsValid and (Pointer(FRareData.ClassSource) = Pointer(Source)) then
    Exit(FRareData.ClassAtoms);
  Tokens := SplitTokens(Source, True);
  SetLength(Result, System.Length(Tokens));
  for Index := 1 to System.Length(Tokens) do
    Result[Index - 1] := Atomize(Tokens[Index - 1]);
  RareData.ClassAtoms := Result;
  FRareData.ClassSource := Source;
  FRareData.ClassAtomsValid := True;
end;

function TElement.HasClass(ClassAtom: TAtom): Boolean;
var
  Atoms: TAtomArray;
  Index: Integer;
begin
  Atoms := ClassAtoms;
  for Index := 1 to System.Length(Atoms) do
    if Atoms[Index - 1] = ClassAtom then
      Exit(True);
  Result := False;
end;

function TElement.GetTemplateContent: TDocumentFragment;
var
  Content: TDocumentFragment;
begin
  if (FRareData <> nil) and (FRareData.TemplateContent <> nil) then
    Exit(FRareData.TemplateContent);
  Content := TDocumentFragment.Create;
  InitializeNode(Content, NodeTypeDocumentFragment, FOwnerDocument.TemplateContentsOwner);
  Content.FHost := Self;
  RareData.TemplateContent := Content;
  Result := Content;
end;

function TElement.GetElementState: Word;
begin
  if FRareData = nil then
    Result := 0
  else
    Result := FRareData.ElementState;
end;

procedure TElement.SetElementState(Value: Word);
begin
  if (Value <> 0) or (FRareData <> nil) then
    RareData.ElementState := Value;
end;

function TElement.Closest(Name: TAtom): TElement;
var
  Node: TNode;
begin
  Node := Self;
  while Node <> nil do
  begin
    if (Node.FNodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(Name) then
      Exit(TElement(Node));
    Node := Node.FParent;
  end;
  Result := nil;
end;

{ The compact attribute records. }

function TElement.GetAttributeCount: Integer;
begin
  Result := System.Length(FAttributes);
end;

function TElement.HasAttributes: Boolean;
begin
  Result := System.Length(FAttributes) > 0;
end;

function TElement.AttributeAt(Index: Integer): PAttributeRecord;
begin
  Result := @FAttributes[Index];
end;

function TElement.AttributeIndexOf(LocalAtom: TAtom; Namespace: TNamespaceId): Integer;
var
  Index: Integer;
  WantedUri: TAtom;
begin
  WantedUri := Web.Namespaces.NamespaceUri(Namespace);
  for Index := 1 to System.Length(FAttributes) do
    if (FAttributes[Index - 1].LocalName = LocalAtom) and
      ((FAttributes[Index - 1].NamespaceId = Namespace) or
      (Web.Namespaces.NamespaceUri(FAttributes[Index - 1].NamespaceId) = WantedUri)) then
      Exit(Index - 1);
  Result := -1;
end;

function TElement.AttributeValueOf(LocalAtom: TAtom; Namespace: TNamespaceId): string;
var
  Index: Integer;
begin
  Index := AttributeIndexOf(LocalAtom, Namespace);
  if Index < 0 then
    Result := ''
  else
    Result := FAttributes[Index].Value;
end;

function TElement.HasAttributeAtom(LocalAtom: TAtom; Namespace: TNamespaceId): Boolean;
begin
  Result := AttributeIndexOf(LocalAtom, Namespace) >= 0;
end;

procedure TElement.AttributeChangeSteps(LocalAtom: TAtom; Namespace: TNamespaceId; const OldValue: string;
  HadValue: Boolean);
var
  Index: Integer;
begin
  BumpDomVersion;
  if Web.Namespaces.NamespaceUri(Namespace) = AtomNone then
  begin
    Index := AttributeIndexOf(LocalAtom, NamespaceNone);
    if LocalAtom = AtomId then
    begin
      if HadValue and ((FFlags and NodeFlagConnected) <> 0) then
        FOwnerDocument.UnregisterId(Self, OldValue);
      if Index >= 0 then
      begin
        FFlags := FFlags or NodeFlagHasId;
        if (FFlags and NodeFlagConnected) <> 0 then
          FOwnerDocument.RegisterId(Self, FAttributes[Index].Value);
      end
      else
        FFlags := FFlags and not NodeFlagHasId;
    end
    else if LocalAtom = AtomClass then
    begin
      if Index >= 0 then
        FFlags := FFlags or NodeFlagHasClass
      else
        FFlags := FFlags and not NodeFlagHasClass;
      if FRareData <> nil then
        FRareData.ClassAtomsValid := False;
    end;
  end;
  if DocumentHasObservers(FOwnerDocument) then
    FOwnerDocument.NotifyAttributeChanged(Self, LocalAtom, Namespace, OldValue, HadValue);
end;

procedure TElement.ChangeAttributeValue(Index: Integer; const Value: string);
var
  OldValue: string;
begin
  OldValue := FAttributes[Index].Value;
  FAttributes[Index].Value := Value;
  AttributeChangeSteps(FAttributes[Index].LocalName, FAttributes[Index].NamespaceId, OldValue, True);
end;

procedure TElement.AppendAttributeRecord(LocalAtom: TAtom; Namespace: TNamespaceId; const Value: string);
var
  Count: Integer;
begin
  Count := System.Length(FAttributes);
  SetLength(FAttributes, Count + 1);
  FAttributes[Count].LocalName := LocalAtom;
  FAttributes[Count].NamespaceId := Namespace;
  FAttributes[Count].Value := Value;
  if (FRareData <> nil) and (FRareData.AttrNodes <> nil) then
    SetLength(FRareData.AttrNodes, Count + 1);
end;

procedure TElement.AddAttributeFromParser(LocalAtom: TAtom; Namespace: TNamespaceId; const Value: string);
begin
  AppendAttributeRecord(LocalAtom, Namespace, Value);
  if Namespace = NamespaceNone then
    if LocalAtom = AtomId then
      FFlags := FFlags or NodeFlagHasId
    else if LocalAtom = AtomClass then
      FFlags := FFlags or NodeFlagHasClass;
end;

procedure TElement.RemoveAttributeAt(Index: Integer);
var
  OldValue: string;
  LocalAtom: TAtom;
  Namespace: TNamespaceId;
  Count, Position: Integer;
begin
  DetachAttrNode(Index);
  OldValue := FAttributes[Index].Value;
  LocalAtom := FAttributes[Index].LocalName;
  Namespace := FAttributes[Index].NamespaceId;
  Count := System.Length(FAttributes);
  for Position := Index + 1 to Count - 1 do
    FAttributes[Position - 1] := FAttributes[Position];
  SetLength(FAttributes, Count - 1);
  if (FRareData <> nil) and (FRareData.AttrNodes <> nil) then
  begin
    for Position := Index + 1 to Count - 1 do
      FRareData.AttrNodes[Position - 1] := FRareData.AttrNodes[Position];
    SetLength(FRareData.AttrNodes, Count - 1);
  end;
  AttributeChangeSteps(LocalAtom, Namespace, OldValue, True);
end;

procedure TElement.SetAttributeAtom(LocalAtom: TAtom; Namespace: TNamespaceId; const Value: string);
var
  Index: Integer;
begin
  Index := AttributeIndexOf(LocalAtom, Namespace);
  if Index >= 0 then
    ChangeAttributeValue(Index, Value)
  else
  begin
    AppendAttributeRecord(LocalAtom, Namespace, Value);
    AttributeChangeSteps(LocalAtom, Namespace, '', False);
  end;
end;

procedure TElement.RemoveAttributeAtom(LocalAtom: TAtom; Namespace: TNamespaceId);
var
  Index: Integer;
begin
  Index := AttributeIndexOf(LocalAtom, Namespace);
  if Index >= 0 then
    RemoveAttributeAt(Index);
end;

function TElement.CloneSelf(Document: TDocument): TNode;
var
  Copy: TElement;
  Index: Integer;
begin
  Copy := Document.NewElement(FLocalName, FNamespaceId);
  SetLength(Copy.FAttributes, System.Length(FAttributes));
  for Index := 1 to System.Length(FAttributes) do
    Copy.FAttributes[Index - 1] := FAttributes[Index - 1];
  Copy.FFlags := Copy.FFlags or (FFlags and (NodeFlagHasId or NodeFlagHasClass));
  Result := Copy;
end;

function TElement.IsEqualSelf(Other: TNode): Boolean;
var
  OtherElement: TElement;
  Index, Match: Integer;
begin
  if Other.FNodeType <> NodeTypeElement then
    Exit(False);
  OtherElement := TElement(Other);
  if (OtherElement.FLocalName <> FLocalName) or (OtherElement.NamespaceAtom <> NamespaceAtom) or
    (NamespacePrefix(OtherElement.FNamespaceId) <> NamespacePrefix(FNamespaceId)) or
    (System.Length(OtherElement.FAttributes) <> System.Length(FAttributes)) then
    Exit(False);
  for Index := 1 to System.Length(FAttributes) do
  begin
    Match := OtherElement.AttributeIndexOf(FAttributes[Index - 1].LocalName, FAttributes[Index - 1].NamespaceId);
    if (Match < 0) or (OtherElement.FAttributes[Match].Value <> FAttributes[Index - 1].Value) then
      Exit(False);
  end;
  Result := True;
end;
