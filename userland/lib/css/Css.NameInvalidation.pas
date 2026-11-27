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
  What must be styled again when an element's classes, id or another
  attribute change: from the selectors that name them, gathered once
  per rule index (the invalidation maps of Servo's style system, by
  name only).

  Each class, id and attribute name a selector has is kept with where
  it sits in its selector: in the subject compound (the element itself
  is affected), left of descendant or child combinators only (its
  descendants), or left of a sibling combinator (its later siblings and
  their descendants). A name no selector has asks for nothing.

  The answer may be too much, never too little: a name in a complex
  selector inside :is(), :not(), :where() or a nested rule's '&' counts
  for all three places, and one inside :has(), an :nth-*(... of S) or
  the shadow tree functions asks for everything around to be styled
  again.
}
unit Css.NameInvalidation;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Selectors, Css.RuleIndex, Css.PointerMaps;

type
  TCssSelectorNameKind = (snClass, snId, snAttribute);

  TCssNameInvalidationPart = (niSelf, niDescendants, niSiblings,
    { The ancestors, earlier siblings and the rest too (:has()). }
    niEverywhere);
  TCssNameInvalidation = set of TCssNameInvalidationPart;

  TCssNameDependencies = class
  private
    { Lowercase name atom to a TCssNameInvalidation bit mask. }
    FMaps: array[TCssSelectorNameKind] of TCssPointerMap;
    procedure AddName(Kind: TCssSelectorNameKind; Name: TCssAtom; Parts: TCssNameInvalidation);
    procedure AddCompound(constref Compound: TCssCompoundSelector; Parts: TCssNameInvalidation; Depth: Integer);
    procedure AddSelector(Selector: TCssComplexSelector; Nested: Boolean; OuterParts: TCssNameInvalidation;
      Depth: Integer);
    procedure AddList(List: TCssSelectorList; Nested: Boolean; OuterParts: TCssNameInvalidation; Depth: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Build(Index: TCssRuleIndex);
    { Rules were appended to the index from entry First on. }
    procedure AddEntries(Index: TCssRuleIndex; First: Integer);
    { What a change of Name (any case) on an element asks to be styled
      again. }
    function Invalidation(Kind: TCssSelectorNameKind; Name: TCssAtom): TCssNameInvalidation;
  end;

implementation

const
  MaximumNestingDepth = 16;
  AllParts = [niSelf, niDescendants, niSiblings];

function PartsToMask(Parts: TCssNameInvalidation): PtrInt;
var
  Part: TCssNameInvalidationPart;
begin
  Result := 0;
  for Part := Low(TCssNameInvalidationPart) to High(TCssNameInvalidationPart) do
    if Part in Parts then
      Result := Result or (PtrInt(1) shl Ord(Part));
end;

function MaskToParts(Mask: PtrInt): TCssNameInvalidation;
var
  Part: TCssNameInvalidationPart;
begin
  Result := [];
  for Part := Low(TCssNameInvalidationPart) to High(TCssNameInvalidationPart) do
    if (Mask and (PtrInt(1) shl Ord(Part))) <> 0 then
      Include(Result, Part);
end;

constructor TCssNameDependencies.Create;
var
  Kind: TCssSelectorNameKind;
begin
  inherited Create;
  for Kind := Low(TCssSelectorNameKind) to High(TCssSelectorNameKind) do
    FMaps[Kind] := TCssPointerMap.Create;
end;

destructor TCssNameDependencies.Destroy;
var
  Kind: TCssSelectorNameKind;
begin
  for Kind := Low(TCssSelectorNameKind) to High(TCssSelectorNameKind) do
    FMaps[Kind].Free;
  inherited Destroy;
end;

procedure TCssNameDependencies.AddName(Kind: TCssSelectorNameKind; Name: TCssAtom; Parts: TCssNameInvalidation);
var
  Mask: PtrInt;
begin
  if Name = NoAtom then
    Exit;
  if not FMaps[Kind].TryGet(Pointer(PtrUInt(Name)), Mask) then
    Mask := 0;
  FMaps[Kind].Put(Pointer(PtrUInt(Name)), Mask or PartsToMask(Parts));
end;

{ The names of one compound, which affect Parts. }
procedure TCssNameDependencies.AddCompound(constref Compound: TCssCompoundSelector; Parts: TCssNameInvalidation;
  Depth: Integer);
var
  Index: Integer;
  Simple: ^TCssSimpleSelector;
begin
  for Index := 0 to High(Compound.Simples) do
  begin
    Simple := @Compound.Simples[Index];
    case Simple^.Kind of
      skClass: AddName(snClass, Simple^.LowerName, Parts);
      skId: AddName(snId, Simple^.LowerName, Parts);
      skAttribute: AddName(snAttribute, Simple^.LowerName, Parts);
    end;
    if Simple^.Arguments <> nil then
    begin
      { Arguments that look at other elements (:has(), the siblings an
        :nth-*(... of S) counts, hosts and slots) reach everywhere. }
      if Simple^.PseudoClass in [pcIs, pcWhere, pcNot] then
        AddList(Simple^.Arguments, True, Parts, Depth + 1)
      else
        AddList(Simple^.Arguments, True, [niEverywhere], Depth + 1);
    end;
    if Simple^.NestingParent <> nil then
      AddList(Simple^.NestingParent, True, Parts, Depth + 1);
  end;
end;

{ Nested: Selector is an argument whose subject is an element affecting
  OuterParts. }
procedure TCssNameDependencies.AddSelector(Selector: TCssComplexSelector; Nested: Boolean;
  OuterParts: TCssNameInvalidation; Depth: Integer);
var
  CompoundIndex: Integer;
  Parts: TCssNameInvalidation;
begin
  if Depth > MaximumNestingDepth then
    Exit;
  for CompoundIndex := 0 to High(Selector.Compounds) do
  begin
    if niEverywhere in OuterParts then
      Parts := [niEverywhere]
    else if CompoundIndex = 0 then
    begin
      if Nested then
        Parts := OuterParts
      else
        Parts := [niSelf];
    end
    else if Nested then
      Parts := AllParts
    else if Selector.Compounds[CompoundIndex - 1].Combinator in [cmNextSibling, cmSubsequentSibling] then
      Parts := [niSiblings]
    else
      Parts := [niDescendants];
    AddCompound(Selector.Compounds[CompoundIndex], Parts, Depth);
  end;
end;

procedure TCssNameDependencies.AddList(List: TCssSelectorList; Nested: Boolean; OuterParts: TCssNameInvalidation;
  Depth: Integer);
var
  Index: Integer;
begin
  if (List = nil) or (Depth > MaximumNestingDepth) then
    Exit;
  for Index := 0 to List.Count - 1 do
    AddSelector(List.Items[Index], Nested, OuterParts, Depth);
end;

procedure TCssNameDependencies.Build(Index: TCssRuleIndex);
var
  Kind: TCssSelectorNameKind;
begin
  for Kind := Low(TCssSelectorNameKind) to High(TCssSelectorNameKind) do
    FMaps[Kind].Clear;
  AddEntries(Index, 0);
end;

procedure TCssNameDependencies.AddEntries(Index: TCssRuleIndex; First: Integer);
var
  Entry: Integer;
begin
  for Entry := First to Index.Count - 1 do
    AddSelector(Index.Entry(Entry)^.Selector, False, [], 0);
end;

function TCssNameDependencies.Invalidation(Kind: TCssSelectorNameKind; Name: TCssAtom): TCssNameInvalidation;
var
  Mask: PtrInt;
begin
  Result := [];
  if Name = NoAtom then
    Exit;
  if FMaps[Kind].TryGet(Pointer(PtrUInt(LowercaseAtom(Name))), Mask) then
    Result := MaskToParts(Mask);
end;

end.
