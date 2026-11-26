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
  Web.Dom: what the DOM keeps of custom elements (DOM Standard 4.9): an
  element's custom element state, is value and definition, and the
  points where the mutation algorithms enqueue reactions. The registry,
  constructors, upgrades and callbacks are the script bindings'
  (Web.Bindings.CustomElements, through CustomElementHost); the DOM
  calls them only for elements flagged NodeFlagCustomCandidate (a name
  with a hyphen, or an is value), so other elements cost nothing.

  Also here: the observer hooks' defaults for shadow trees and custom
  elements, and Element.part.
}

function IsValidCustomElementName(const Name: string): Boolean;
var
  Index: Integer;
  HasHyphen: Boolean;
begin
  Result := False;
  if (Name = '') or not (Name[1] in ['a'..'z']) then
    Exit;
  HasHyphen := False;
  for Index := 2 to System.Length(Name) do
    case Name[Index] of
      '-':
        HasHyphen := True;
      'A'..'Z', #0..#44, '/', ':'..'@', '['..'^', '`', '{'..#127:
        if not (Name[Index] in ['.', '_']) then
          Exit;
    end;
  if not HasHyphen then
    Exit;
  case Name of
    'annotation-xml', 'color-profile', 'font-face', 'font-face-src', 'font-face-uri', 'font-face-format',
    'font-face-name', 'missing-glyph':
      Exit;
  end;
  Result := True;
end;

function IsCustomElementNameAtom(Atom: TAtom): Boolean;
var
  Name: string;
begin
  Name := NameOfAtom(Atom);
  Result := (Pos('-', Name) > 0) and IsValidCustomElementName(Name);
end;

procedure TDocumentObserver.ShadowRootAttached(Host: TElement);
begin
end;

procedure TDocumentObserver.SlotChangeSignaled(Slot: TElement);
begin
end;

procedure TDocumentObserver.SlotAssignmentChanged(Slot: TElement);
begin
end;

procedure TDocumentObserver.CustomElementStateChanged(Element: TElement);
begin
end;

function TElement.CustomElementState: TCustomElementState;
begin
  if FRareData = nil then
    Result := CustomElementUncustomized
  else
    Result := FRareData.CustomState;
end;

procedure TElement.SetCustomElementState(Value: TCustomElementState);
begin
  if CustomElementState = Value then
    Exit;
  RareData.CustomState := Value;
  if Value <> CustomElementUncustomized then
    FFlags := FFlags or NodeFlagCustomCandidate;
  FOwnerDocument.NotifyCustomElementStateChanged(Self);
end;

function TElement.IsValue: string;
begin
  if FRareData = nil then
    Result := ''
  else
    Result := FRareData.IsValue;
end;

procedure TElement.SetIsValue(const Value: string);
begin
  if (Value = '') and (FRareData = nil) then
    Exit;
  RareData.IsValue := Value;
  if Value <> '' then
    FFlags := FFlags or NodeFlagCustomCandidate;
end;

function TElement.CustomElementDefinition: TObject;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.CustomDefinition;
end;

procedure TElement.SetCustomElementDefinition(Definition: TObject);
var
  Old: TObject;
begin
  Old := CustomElementDefinition;
  if Old = Definition then
    Exit;
  RareData.CustomDefinition := Definition;
  if (Old <> nil) and (CustomElementHost <> nil) then
    CustomElementHost.ReleaseDefinition(Old);
end;

function TElement.CustomElementData: TObject;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.CustomData;
end;

procedure TElement.SetCustomElementData(Data: TObject);
begin
  if (Data = nil) and (FRareData = nil) then
    Exit;
  if RareData.CustomData <> Data then
    RareData.CustomData.Free;
  RareData.CustomData := Data;
end;

function TElement.IsDefinedElement: Boolean;
begin
  Result := CustomElementState in [CustomElementUncustomized, CustomElementCustom];
end;

function TElement.HasCustomState(const Name: string): Boolean;
var
  Index: Integer;
begin
  if FRareData <> nil then
    for Index := 0 to High(FRareData.CustomStates) do
      if FRareData.CustomStates[Index] = Name then
        Exit(True);
  Result := False;
end;

function TElement.CustomStates: TStringArray;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := Copy(FRareData.CustomStates);
end;

procedure TElement.SetCustomStates(const States: TStringArray);
begin
  if (System.Length(States) = 0) and ((FRareData = nil) or (FRareData.CustomStates = nil)) then
    Exit;
  RareData.CustomStates := Copy(States);
  FOwnerDocument.NotifyCustomElementStateChanged(Self);
end;

function TElement.GetAnimationEffects: TObject;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.AnimationEffects;
end;

procedure TElement.SetAnimationEffects(Value: TObject);
begin
  if (Value = nil) and (FRareData = nil) then
    Exit;
  if RareData.AnimationEffects <> Value then
    RareData.AnimationEffects.Free;
  RareData.AnimationEffects := Value;
end;

function TElement.PartList: TDomTokenList;
begin
  if RareData.PartList = nil then
    RareData.PartList := TDomTokenList.Create(Self, AtomPart);
  Result := RareData.PartList;
end;

procedure TDocument.NotifyCustomElementStateChanged(Element: TElement);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].CustomElementStateChanged(Element);
end;

{ Root and its shadow-including descendants became connected. }
procedure CustomReactionsConnected(Root: TNode);
var
  Node: TNode;
begin
  Node := Root;
  while (Node <> nil) and (CustomElementHost <> nil) do
  begin
    if (Node.FFlags and NodeFlagCustomCandidate) <> 0 then
      CustomElementHost.ElementConnected(TElement(Node));
    Node := Node.NextInShadowIncludingTree(Root);
  end;
end;

procedure CustomReactionsDisconnected(Root: TNode);
var
  Node: TNode;
begin
  Node := Root;
  while (Node <> nil) and (CustomElementHost <> nil) do
  begin
    if (Node.FFlags and NodeFlagCustomCandidate) <> 0 then
      CustomElementHost.ElementDisconnected(TElement(Node));
    Node := Node.NextInShadowIncludingTree(Root);
  end;
end;

procedure CustomReactionsAdopted(Root: TNode; OldDocument, NewDocument: TDocument);
var
  Node: TNode;
begin
  if OldDocument = NewDocument then
    Exit;
  Node := Root;
  while (Node <> nil) and (CustomElementHost <> nil) do
  begin
    if (Node.FFlags and NodeFlagCustomCandidate) <> 0 then
      CustomElementHost.ElementAdopted(TElement(Node), OldDocument, NewDocument);
    Node := Node.NextInShadowIncludingTree(Root);
  end;
end;
