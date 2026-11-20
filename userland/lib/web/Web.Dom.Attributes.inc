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
  Web.Dom: attributes by name (Element's getAttribute family), Attr
  nodes (made on demand, one per attribute, kept while the attribute
  is), NamedNodeMap, and the name checks with "validate and extract".
}

function ContainsAnyOf(const Name: string; const Characters: TSysCharSet): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to System.Length(Name) do
    if Name[Index] in Characters then
      Exit(True);
  Result := False;
end;

function IsValidElementLocalName(const Name: string): Boolean;
var
  Index: Integer;
begin
  if Name = '' then
    Exit(False);
  if Name[1] in ['a'..'z', 'A'..'Z'] then
    Exit(not ContainsAnyOf(Name, [#9, #10, #12, #13, ' ', #0, '/', '>']));
  { Otherwise the name starts with ":", "_" or a non-ASCII character and
    goes on with ASCII alphanumerics, "-", ".", ":", "_" or non-ASCII
    characters. }
  if not ((Name[1] in [':', '_']) or (Ord(Name[1]) >= $80)) then
    Exit(False);
  for Index := 2 to System.Length(Name) do
    if not ((Name[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', ':', '_']) or (Ord(Name[Index]) >= $80)) then
      Exit(False);
  Result := True;
end;

function IsValidAttributeLocalName(const Name: string): Boolean;
begin
  Result := (Name <> '') and not ContainsAnyOf(Name, [#9, #10, #12, #13, ' ', #0, '/', '=', '>']);
end;

function IsValidNamespacePrefix(const Name: string): Boolean;
begin
  Result := (Name <> '') and not ContainsAnyOf(Name, [#9, #10, #12, #13, ' ', #0, '/', '>']);
end;

function IsValidDoctypeName(const Name: string): Boolean;
begin
  Result := not ContainsAnyOf(Name, [#9, #10, #12, #13, ' ', #0, '>']);
end;

type
  TNameContext = (NameContextElement, NameContextAttribute);

{ "Validate and extract": the namespace id and local name atom of a
  qualified name in a namespace. }
procedure ValidateAndExtract(const Namespace, QualifiedName: string; Context: TNameContext;
  out NamespaceIdResult: TNamespaceId; out LocalNameResult: TAtom);
var
  PrefixText, LocalText: string;
  Colon: SizeInt;
  NamespaceAtomValue, PrefixAtom: TAtom;
begin
  PrefixText := '';
  LocalText := QualifiedName;
  Colon := Pos(':', QualifiedName);
  if Colon > 0 then
  begin
    PrefixText := Copy(QualifiedName, 1, Colon - 1);
    LocalText := Copy(QualifiedName, Colon + 1, MaxInt);
    if not IsValidNamespacePrefix(PrefixText) then
      RaiseDomError(InvalidCharacterError, 'the prefix is not valid');
  end;
  if (Context = NameContextAttribute) and not IsValidAttributeLocalName(LocalText) then
    RaiseDomError(InvalidCharacterError, 'the attribute name is not valid');
  if (Context = NameContextElement) and not IsValidElementLocalName(LocalText) then
    RaiseDomError(InvalidCharacterError, 'the element name is not valid');
  if (Colon > 0) and (Namespace = '') then
    RaiseDomError(NamespaceError, 'a prefix needs a namespace');
  if (PrefixText = 'xml') and (Namespace <> NameOfAtom(AtomXmlNamespace)) then
    RaiseDomError(NamespaceError, 'the prefix xml is for the XML namespace');
  if ((QualifiedName = 'xmlns') or (PrefixText = 'xmlns')) and (Namespace <> NameOfAtom(AtomXmlnsNamespace)) then
    RaiseDomError(NamespaceError, 'xmlns is for the XMLNS namespace');
  if (Namespace = NameOfAtom(AtomXmlnsNamespace)) and (QualifiedName <> 'xmlns') and (PrefixText <> 'xmlns') then
    RaiseDomError(NamespaceError, 'the XMLNS namespace is for xmlns');
  NamespaceAtomValue := Atomize(Namespace);
  PrefixAtom := Atomize(PrefixText);
  NamespaceIdResult := NamespaceIdOf(NamespaceAtomValue, PrefixAtom);
  LocalNameResult := Atomize(LocalText);
end;

function TElement.FindAttributeByQualifiedName(const QualifiedName: string): Integer;
var
  Name: string;
  NameAtom: TAtom;
  Index: Integer;
begin
  Name := QualifiedName;
  if IsHtml and FOwnerDocument.FIsHtmlDocument then
    Name := AsciiLowerCase(Name);
  NameAtom := FindAtom(Name);
  for Index := 1 to System.Length(FAttributes) do
  begin
    if NamespacePrefix(FAttributes[Index - 1].NamespaceId) = AtomNone then
    begin
      if (NameAtom <> AtomNone) and (FAttributes[Index - 1].LocalName = NameAtom) then
        Exit(Index - 1);
    end
    else if QualifiedNameOf(FAttributes[Index - 1].LocalName, FAttributes[Index - 1].NamespaceId) = Name then
      Exit(Index - 1);
  end;
  Result := -1;
end;

function NamespaceIdForUri(const Namespace: string): TNamespaceId;
begin
  if Namespace = '' then
    Result := NamespaceNone
  else
    Result := NamespaceIdOf(Atomize(Namespace), AtomNone);
end;

function TElement.GetAttributeNames: TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, System.Length(FAttributes));
  for Index := 1 to System.Length(FAttributes) do
    Result[Index - 1] := QualifiedNameOf(FAttributes[Index - 1].LocalName, FAttributes[Index - 1].NamespaceId);
end;

function TElement.GetAttribute(const QualifiedName: string): string;
var
  Index: Integer;
begin
  Index := FindAttributeByQualifiedName(QualifiedName);
  if Index < 0 then
    Result := ''
  else
    Result := FAttributes[Index].Value;
end;

function TElement.GetAttributeNS(const Namespace, LocalNameText: string): string;
var
  Index: Integer;
  NameAtom: TAtom;
begin
  Result := '';
  NameAtom := FindAtom(LocalNameText);
  if NameAtom = AtomNone then
    Exit;
  Index := AttributeIndexOf(NameAtom, NamespaceIdForUri(Namespace));
  if Index >= 0 then
    Result := FAttributes[Index].Value;
end;

function TElement.HasAttribute(const QualifiedName: string): Boolean;
begin
  Result := FindAttributeByQualifiedName(QualifiedName) >= 0;
end;

function TElement.HasAttributeNS(const Namespace, LocalNameText: string): Boolean;
var
  NameAtom: TAtom;
begin
  NameAtom := FindAtom(LocalNameText);
  Result := (NameAtom <> AtomNone) and (AttributeIndexOf(NameAtom, NamespaceIdForUri(Namespace)) >= 0);
end;

procedure TElement.SetAttribute(const QualifiedName, Value: string);
var
  Name: string;
  Index: Integer;
begin
  if not IsValidAttributeLocalName(QualifiedName) then
    RaiseDomError(InvalidCharacterError, 'the attribute name is not valid');
  Name := QualifiedName;
  if IsHtml and FOwnerDocument.FIsHtmlDocument then
    Name := AsciiLowerCase(Name);
  Index := FindAttributeByQualifiedName(Name);
  if Index >= 0 then
    ChangeAttributeValue(Index, Value)
  else
  begin
    AppendAttributeRecord(Atomize(Name), NamespaceNone, Value);
    AttributeChangeSteps(Atomize(Name), NamespaceNone, '', False);
  end;
end;

procedure TElement.SetAttributeNS(const Namespace, QualifiedName, Value: string);
var
  QualifierId: TNamespaceId;
  NameAtom: TAtom;
  Index: Integer;
begin
  ValidateAndExtract(Namespace, QualifiedName, NameContextAttribute, QualifierId, NameAtom);
  Index := AttributeIndexOf(NameAtom, QualifierId);
  if Index >= 0 then
    ChangeAttributeValue(Index, Value)
  else
  begin
    AppendAttributeRecord(NameAtom, QualifierId, Value);
    AttributeChangeSteps(NameAtom, QualifierId, '', False);
  end;
end;

procedure TElement.RemoveAttribute(const QualifiedName: string);
var
  Index: Integer;
begin
  Index := FindAttributeByQualifiedName(QualifiedName);
  if Index >= 0 then
    RemoveAttributeAt(Index);
end;

procedure TElement.RemoveAttributeNS(const Namespace, LocalNameText: string);
var
  NameAtom: TAtom;
begin
  NameAtom := FindAtom(LocalNameText);
  if NameAtom <> AtomNone then
    RemoveAttributeAtom(NameAtom, NamespaceIdForUri(Namespace));
end;

function TElement.ToggleAttribute(const QualifiedName: string; Force: Integer): Boolean;
var
  Name: string;
  Index: Integer;
begin
  if not IsValidAttributeLocalName(QualifiedName) then
    RaiseDomError(InvalidCharacterError, 'the attribute name is not valid');
  Name := QualifiedName;
  if IsHtml and FOwnerDocument.FIsHtmlDocument then
    Name := AsciiLowerCase(Name);
  Index := FindAttributeByQualifiedName(Name);
  if Index < 0 then
  begin
    if (Force = -1) or (Force = 1) then
    begin
      AppendAttributeRecord(Atomize(Name), NamespaceNone, '');
      AttributeChangeSteps(Atomize(Name), NamespaceNone, '', False);
      Exit(True);
    end;
    Exit(False);
  end;
  if (Force = -1) or (Force = 0) then
  begin
    RemoveAttributeAt(Index);
    Exit(False);
  end;
  Result := True;
end;

{ Attr nodes. }

function TElement.AttrNodeFor(Index: Integer; CreateIfMissing: Boolean): TAttr;
var
  Attr: TAttr;
begin
  Result := nil;
  if (FRareData <> nil) and (FRareData.AttrNodes <> nil) then
    Result := FRareData.AttrNodes[Index];
  if (Result <> nil) or not CreateIfMissing then
    Exit;
  if RareData.AttrNodes = nil then
    SetLength(FRareData.AttrNodes, System.Length(FAttributes));
  Attr := TAttr.Create;
  InitializeNode(Attr, NodeTypeAttribute, FOwnerDocument);
  Attr.FLocalName := FAttributes[Index].LocalName;
  Attr.FNamespaceId := FAttributes[Index].NamespaceId;
  Attr.FOwnerElement := Self;
  FRareData.AttrNodes[Index] := Attr;
  Result := Attr;
end;

procedure TElement.DetachAttrNode(Index: Integer);
var
  Attr: TAttr;
begin
  Attr := AttrNodeFor(Index, False);
  if Attr = nil then
    Exit;
  FRareData.AttrNodes[Index] := nil;
  Attr.FDetachedValue := FAttributes[Index].Value;
  Attr.FOwnerElement := nil;
  BecameRoot(Attr, Self);
end;

function TElement.GetAttributeNode(const QualifiedName: string): TAttr;
var
  Index: Integer;
begin
  Index := FindAttributeByQualifiedName(QualifiedName);
  if Index < 0 then
    Result := nil
  else
    Result := AttrNodeFor(Index, True);
end;

function TElement.GetAttributeNodeNS(const Namespace, LocalNameText: string): TAttr;
var
  NameAtom: TAtom;
  Index: Integer;
begin
  Result := nil;
  NameAtom := FindAtom(LocalNameText);
  if NameAtom = AtomNone then
    Exit;
  Index := AttributeIndexOf(NameAtom, NamespaceIdForUri(Namespace));
  if Index >= 0 then
    Result := AttrNodeFor(Index, True);
end;

function TElement.SetAttributeNode(Attr: TAttr): TAttr;
var
  OldIndex, NewIndex: Integer;
  OldValue: string;
  OldDocument: TDocument;
begin
  if (Attr.FOwnerElement <> nil) and (Attr.FOwnerElement <> Self) then
    RaiseDomError(InUseAttributeError, 'the attribute belongs to another element');
  OldIndex := AttributeIndexOf(Attr.FLocalName, Attr.FNamespaceId);
  if (OldIndex >= 0) and (AttrNodeFor(OldIndex, False) = Attr) then
    Exit(Attr);
  if Attr.FOwnerDocument <> FOwnerDocument then
  begin
    OldDocument := Attr.FOwnerDocument;
    Attr.FOwnerDocument := FOwnerDocument;
    RootChangedDocument(Attr, OldDocument, FOwnerDocument);
  end;
  Result := nil;
  if OldIndex >= 0 then
  begin
    { Replace: the old Attr leaves, the new one takes its place. }
    Result := AttrNodeFor(OldIndex, True);
    OldValue := FAttributes[OldIndex].Value;
    DetachAttrNode(OldIndex);
    FAttributes[OldIndex].Value := Attr.FDetachedValue;
    FAttributes[OldIndex].NamespaceId := Attr.FNamespaceId;
    NewIndex := OldIndex;
    if RareData.AttrNodes = nil then
      SetLength(FRareData.AttrNodes, System.Length(FAttributes));
    BecomingChild(Attr, Self);
    FRareData.AttrNodes[NewIndex] := Attr;
    Attr.FOwnerElement := Self;
    Attr.FDetachedValue := '';
    AttributeChangeSteps(Attr.FLocalName, Attr.FNamespaceId, OldValue, True);
    Exit;
  end;
  AppendAttributeRecord(Attr.FLocalName, Attr.FNamespaceId, Attr.FDetachedValue);
  NewIndex := High(FAttributes);
  if RareData.AttrNodes = nil then
    SetLength(FRareData.AttrNodes, System.Length(FAttributes));
  BecomingChild(Attr, Self);
  FRareData.AttrNodes[NewIndex] := Attr;
  Attr.FOwnerElement := Self;
  Attr.FDetachedValue := '';
  AttributeChangeSteps(Attr.FLocalName, Attr.FNamespaceId, '', False);
end;

function TElement.RemoveAttributeNode(Attr: TAttr): TAttr;
var
  Index: Integer;
begin
  Index := -1;
  if Attr.FOwnerElement = Self then
    Index := AttributeIndexOf(Attr.FLocalName, Attr.FNamespaceId);
  if Index < 0 then
    RaiseDomError(NotFoundError, 'the attribute is not this element''s');
  RemoveAttributeAt(Index);
  Result := Attr;
end;

function TAttr.GetValue: string;
var
  Index: Integer;
begin
  if FOwnerElement = nil then
    Exit(FDetachedValue);
  Index := FOwnerElement.AttributeIndexOf(FLocalName, FNamespaceId);
  Result := FOwnerElement.FAttributes[Index].Value;
end;

procedure TAttr.SetValue(const NewValue: string);
begin
  if FOwnerElement = nil then
    FDetachedValue := NewValue
  else
    FOwnerElement.ChangeAttributeValue(FOwnerElement.AttributeIndexOf(FLocalName, FNamespaceId), NewValue);
end;

function TAttr.GetLocalName: string;
begin
  Result := NameOfAtom(FLocalName);
end;

function TAttr.GetNamespaceUri: string;
begin
  Result := NameOfAtom(Web.Namespaces.NamespaceUri(FNamespaceId));
end;

function TAttr.GetPrefix: string;
begin
  Result := NameOfAtom(NamespacePrefix(FNamespaceId));
end;

function TAttr.GetName: string;
begin
  Result := QualifiedNameOf(FLocalName, FNamespaceId);
end;

function TAttr.GetNodeName: string;
begin
  Result := GetName;
end;

function TAttr.GetNodeValue: string;
begin
  Result := GetValue;
end;

procedure TAttr.SetNodeValue(const Value: string);
begin
  SetValue(Value);
end;

function TAttr.GetTextContent: string;
begin
  Result := GetValue;
end;

procedure TAttr.SetTextContent(const Value: string);
begin
  SetValue(Value);
end;

function TAttr.CloneSelf(Document: TDocument): TNode;
var
  Copy: TAttr;
begin
  Copy := TAttr.Create;
  InitializeNode(Copy, NodeTypeAttribute, Document);
  Copy.FLocalName := FLocalName;
  Copy.FNamespaceId := FNamespaceId;
  Copy.FDetachedValue := GetValue;
  Result := Copy;
end;

function TAttr.IsEqualSelf(Other: TNode): Boolean;
begin
  Result := (Other.FNodeType = NodeTypeAttribute) and (Other.FLocalName = FLocalName) and
    (Web.Namespaces.NamespaceUri(Other.FNamespaceId) = Web.Namespaces.NamespaceUri(FNamespaceId)) and (TAttr(Other).GetValue = GetValue);
end;

function TElement.GetAttributeMap: TNamedNodeMap;
begin
  if RareData.AttributeMap = nil then
    RareData.AttributeMap := TNamedNodeMap.Create(Self);
  Result := RareData.AttributeMap;
end;

constructor TNamedNodeMap.Create(Element: TElement);
begin
  inherited Create;
  FElement := Element;
end;

function TNamedNodeMap.GetLength: Integer;
begin
  Result := System.Length(FElement.FAttributes);
end;

function TNamedNodeMap.Item(Index: Integer): TAttr;
begin
  if (Index < 0) or (Index >= System.Length(FElement.FAttributes)) then
    Result := nil
  else
    Result := FElement.AttrNodeFor(Index, True);
end;

function TNamedNodeMap.GetNamedItem(const QualifiedName: string): TAttr;
begin
  Result := FElement.GetAttributeNode(QualifiedName);
end;

function TNamedNodeMap.GetNamedItemNS(const Namespace, LocalNameText: string): TAttr;
begin
  Result := FElement.GetAttributeNodeNS(Namespace, LocalNameText);
end;

function TNamedNodeMap.SetNamedItem(Attr: TAttr): TAttr;
begin
  Result := FElement.SetAttributeNode(Attr);
end;

function TNamedNodeMap.RemoveNamedItem(const QualifiedName: string): TAttr;
var
  Index: Integer;
begin
  Index := FElement.FindAttributeByQualifiedName(QualifiedName);
  if Index < 0 then
    RaiseDomError(NotFoundError, 'no such attribute');
  Result := FElement.AttrNodeFor(Index, True);
  FElement.RemoveAttributeAt(Index);
end;

function TNamedNodeMap.RemoveNamedItemNS(const Namespace, LocalNameText: string): TAttr;
begin
  Result := FElement.GetAttributeNodeNS(Namespace, LocalNameText);
  if Result = nil then
    RaiseDomError(NotFoundError, 'no such attribute');
  FElement.RemoveAttributeNode(Result);
end;
