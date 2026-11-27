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
  What must be styled again when an element's dynamic states change
  (:hover, :focus, :active ...): from the selectors that use those
  states, gathered once per rule index. Each compound with a state
  pseudo-class is kept with what an element must have for the compound
  to match (its type, id and classes) and where it sits in its selector: the
  subject (the element itself), left of descendant or child
  combinators only (its descendants), or left of a sibling combinator
  (its later siblings and their descendants).

  Moving the pointer changes :hover on a chain of elements; without
  this every one of them had its whole subtree styled again (all of a
  large page for the first move).

  The answer may be too much, never too little: a state inside :is(),
  :not(), :where() or a nested rule's '&' counts for any element in that
  compound's place, and one inside :has() styles everything around
  again.
}
unit Css.StateInvalidation;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms,
  Css.Selectors,
  Css.ElementAdapter,
  Css.RuleIndex;

type
  TCssStateInvalidationPart = (siSelf, siDescendants, siSiblings);
  TCssStateInvalidation = set of TCssStateInvalidationPart;

  TCssStateDependency = record
    States: TCssElementStates;
    Part: TCssStateInvalidationPart;
    { The type selector's lowercase name (0: any element). }
    TypeName: TCssAtom;
    Id: TCssAtom;
    Classes: array of TCssAtom;
  end;

  TCssStateDependencies = class
  private
    FItems: array of TCssStateDependency;
    FCount: Integer;
    FUnderHas: TCssElementStates;
    procedure AddSelector(Selector: TCssComplexSelector; Depth: Integer; InsideArgument: Boolean);
    procedure AddList(List: TCssSelectorList; Depth: Integer; InsideArgument: Boolean);
    procedure AddCompound(constref Compound: TCssCompoundSelector; States: TCssElementStates;
      Part: TCssStateInvalidationPart; Keyed: Boolean);
    function AddAlternatives(constref Compound: TCssCompoundSelector; List: TCssSelectorList;
      Part: TCssStateInvalidationPart): Boolean;
  public
    procedure Build(Index: TCssRuleIndex);
    { What changing Changed on Element asks to be styled again. }
    function Invalidation(Adapter: TCssElementAdapter; Element: TCssElement;
      Changed: TCssElementStates): TCssStateInvalidation;
    property Count: Integer read FCount;
  end;

{ The element states a pseudo-class reads (none for the others). }
function StatesOfPseudoClass(PseudoClass: TCssPseudoClass): TCssElementStates;

implementation

const
  MaximumNestingDepth = 16;

function StatesOfPseudoClass(PseudoClass: TCssPseudoClass): TCssElementStates;
begin
  case PseudoClass of
    pcHover: Result := [esHover];
    pcActive: Result := [esActive];
    pcFocus: Result := [esFocus];
    pcFocusVisible: Result := [esFocusVisible];
    pcFocusWithin: Result := [esFocusWithin];
    pcLink: Result := [esLink];
    pcVisited: Result := [esVisited];
    pcAnyLink: Result := [esLink, esVisited];
    pcTarget: Result := [esTarget];
    pcTargetWithin: Result := [esTargetWithin];
    pcChecked: Result := [esChecked];
    pcIndeterminate: Result := [esIndeterminate];
    pcDisabled: Result := [esDisabled];
    pcEnabled: Result := [esEnabled];
    pcRequired: Result := [esRequired];
    pcOptional: Result := [esOptional];
    pcReadOnly: Result := [esReadOnly];
    pcReadWrite: Result := [esReadWrite];
    pcPlaceholderShown: Result := [esPlaceholderShown];
    pcDefault: Result := [esDefault];
    pcValid: Result := [esValid];
    pcInvalid: Result := [esInvalid];
    pcInRange: Result := [esInRange];
    pcOutOfRange: Result := [esOutOfRange];
    pcAutofill: Result := [esAutofill];
    pcUserValid: Result := [esUserValid];
    pcUserInvalid: Result := [esUserInvalid];
    pcOpen: Result := [esOpen];
    pcModal: Result := [esModal];
    pcPopoverOpen: Result := [esPopoverOpen];
    pcFullscreen: Result := [esFullscreen];
    pcPlaying: Result := [esPlaying];
    pcPaused: Result := [esPaused];
    pcDefined: Result := [esDefined];
  else
    Result := [];
  end;
end;

{ Every state read anywhere in a list (arguments included). }
function StatesInList(List: TCssSelectorList; Depth: Integer): TCssElementStates;
var
  Item, CompoundIndex, SimpleIndex: Integer;
  Simple: ^TCssSimpleSelector;
begin
  Result := [];
  if (List = nil) or (Depth > MaximumNestingDepth) then
    Exit;
  for Item := 0 to List.Count - 1 do
    for CompoundIndex := 0 to High(List.Items[Item].Compounds) do
      for SimpleIndex := 0 to High(List.Items[Item].Compounds[CompoundIndex].Simples) do
      begin
        Simple := @List.Items[Item].Compounds[CompoundIndex].Simples[SimpleIndex];
        Result := Result + StatesOfPseudoClass(Simple^.PseudoClass);
        if Simple^.Arguments <> nil then
          Result := Result + StatesInList(Simple^.Arguments, Depth + 1);
        if Simple^.NestingParent <> nil then
          Result := Result + StatesInList(Simple^.NestingParent, Depth + 1);
      end;
end;

procedure TCssStateDependencies.AddCompound(constref Compound: TCssCompoundSelector; States: TCssElementStates;
  Part: TCssStateInvalidationPart; Keyed: Boolean);
var
  Item: ^TCssStateDependency;
  Index: Integer;
begin
  if FCount >= Length(FItems) then
    SetLength(FItems, FCount * 2 + 16);
  Item := @FItems[FCount];
  Inc(FCount);
  Item^.States := States;
  Item^.Part := Part;
  Item^.TypeName := 0;
  Item^.Id := 0;
  Item^.Classes := nil;
  if not Keyed then
    Exit;
  for Index := 0 to High(Compound.Simples) do
    case Compound.Simples[Index].Kind of
      skType:
        Item^.TypeName := Compound.Simples[Index].LowerName;
      skId:
        Item^.Id := Compound.Simples[Index].Name;
      skClass:
        begin
          SetLength(Item^.Classes, Length(Item^.Classes) + 1);
          Item^.Classes[High(Item^.Classes)] := Compound.Simples[Index].Name;
        end;
    end;
end;

{ :is() and :where() of compounds alone (":is(.a:hover, .b:focus)"):
  one record for each, keyed by its own and the outer compound's id and
  classes. False when the list has anything else (complex selectors). }
function TCssStateDependencies.AddAlternatives(constref Compound: TCssCompoundSelector; List: TCssSelectorList;
  Part: TCssStateInvalidationPart): Boolean;
var
  Item, SimpleIndex: Integer;
  Inner: ^TCssCompoundSelector;
  States: TCssElementStates;
  Combined: TCssCompoundSelector;
begin
  for Item := 0 to List.Count - 1 do
  begin
    if Length(List.Items[Item].Compounds) <> 1 then
      Exit(False);
    for SimpleIndex := 0 to High(List.Items[Item].Compounds[0].Simples) do
      if (List.Items[Item].Compounds[0].Simples[SimpleIndex].Arguments <> nil) or
         (List.Items[Item].Compounds[0].Simples[SimpleIndex].NestingParent <> nil) then
        Exit(False);
  end;
  for Item := 0 to List.Count - 1 do
  begin
    Inner := @List.Items[Item].Compounds[0];
    States := [];
    for SimpleIndex := 0 to High(Inner^.Simples) do
      States := States + StatesOfPseudoClass(Inner^.Simples[SimpleIndex].PseudoClass);
    if States = [] then
      Continue;
    Combined.Simples := Copy(Compound.Simples);
    for SimpleIndex := 0 to High(Inner^.Simples) do
    begin
      SetLength(Combined.Simples, Length(Combined.Simples) + 1);
      Combined.Simples[High(Combined.Simples)] := Inner^.Simples[SimpleIndex];
    end;
    Combined.Combinator := Compound.Combinator;
    AddCompound(Combined, States, Part, True);
  end;
  Result := True;
end;

procedure TCssStateDependencies.AddSelector(Selector: TCssComplexSelector; Depth: Integer; InsideArgument: Boolean);
var
  CompoundIndex, SimpleIndex: Integer;
  Simple: ^TCssSimpleSelector;
  Direct, Nested: TCssElementStates;
  Part: TCssStateInvalidationPart;
begin
  if Depth > MaximumNestingDepth then
    Exit;
  for CompoundIndex := 0 to High(Selector.Compounds) do
  begin
    Direct := [];
    Nested := [];
    for SimpleIndex := 0 to High(Selector.Compounds[CompoundIndex].Simples) do
    begin
      Simple := @Selector.Compounds[CompoundIndex].Simples[SimpleIndex];
      Direct := Direct + StatesOfPseudoClass(Simple^.PseudoClass);
      if Simple^.Arguments <> nil then
      begin
        if Simple^.PseudoClass = pcHas then
          FUnderHas := FUnderHas + StatesInList(Simple^.Arguments, Depth + 1)
        else
          Nested := Nested + StatesInList(Simple^.Arguments, Depth + 1);
      end;
      if Simple^.NestingParent <> nil then
        Nested := Nested + StatesInList(Simple^.NestingParent, Depth + 1);
    end;
    if Direct + Nested = [] then
      Continue;
    { Where the subject can be from this compound: the combinator just
      right of it says (whatever follows stays inside that). }
    if CompoundIndex = 0 then
      Part := siSelf
    else if Selector.Compounds[CompoundIndex - 1].Combinator in [cmNextSibling, cmSubsequentSibling] then
      Part := siSiblings
    else
      Part := siDescendants;
    { Inside an argument the selector's subject is the argument's
      element, which may be anywhere around: count it for siblings and
      descendants too. }
    if InsideArgument then
    begin
      AddCompound(Selector.Compounds[CompoundIndex], Direct + Nested, siSelf, False);
      AddCompound(Selector.Compounds[CompoundIndex], Direct + Nested, siDescendants, False);
      AddCompound(Selector.Compounds[CompoundIndex], Direct + Nested, siSiblings, False);
      Continue;
    end;
    if Direct <> [] then
      AddCompound(Selector.Compounds[CompoundIndex], Direct, Part, True);
    if Nested <> [] then
    begin
      Simple := nil;
      for SimpleIndex := 0 to High(Selector.Compounds[CompoundIndex].Simples) do
        if (Selector.Compounds[CompoundIndex].Simples[SimpleIndex].Arguments <> nil) or
           (Selector.Compounds[CompoundIndex].Simples[SimpleIndex].NestingParent <> nil) then
        begin
          { One argument list alone, of :is() or :where(), keys itself. }
          if Simple <> nil then
          begin
            Simple := nil;
            Break;
          end;
          Simple := @Selector.Compounds[CompoundIndex].Simples[SimpleIndex];
        end;
      if (Simple = nil) or (Simple^.Arguments = nil) or not (Simple^.PseudoClass in [pcIs, pcWhere]) or
         not AddAlternatives(Selector.Compounds[CompoundIndex], Simple^.Arguments, Part) then
        AddCompound(Selector.Compounds[CompoundIndex], Nested, Part, False);
    end;
  end;
end;

procedure TCssStateDependencies.AddList(List: TCssSelectorList; Depth: Integer; InsideArgument: Boolean);
var
  Index: Integer;
begin
  if List = nil then
    Exit;
  for Index := 0 to List.Count - 1 do
    AddSelector(List.Items[Index], Depth, InsideArgument);
end;

procedure TCssStateDependencies.Build(Index: TCssRuleIndex);
var
  Entry: Integer;
begin
  FItems := nil;
  FCount := 0;
  FUnderHas := [];
  for Entry := 0 to Index.Count - 1 do
    AddSelector(Index.Entry(Entry)^.Selector, 0, False);
end;

function HasClass(Adapter: TCssElementAdapter; Element: TCssElement; Name: TCssAtom): Boolean;
var
  Index, ClassCount: Integer;
  ClassList: PCssAtom;
begin
  ClassList := Adapter.Classes(Element, ClassCount);
  for Index := 0 to ClassCount - 1 do
    if ClassList[Index] = Name then
      Exit(True);
  Result := False;
end;

function TCssStateDependencies.Invalidation(Adapter: TCssElementAdapter; Element: TCssElement;
  Changed: TCssElementStates): TCssStateInvalidation;
var
  Index, ClassIndex: Integer;
  Item: ^TCssStateDependency;
  Keys: Boolean;
begin
  Result := [];
  if Changed = [] then
    Exit;
  if Changed * FUnderHas <> [] then
    Exit([siSelf, siDescendants, siSiblings]);
  { Ids and classes compare as written except in quirks mode. }
  Keys := Adapter.QuirksMode <> qmQuirks;
  for Index := 0 to FCount - 1 do
  begin
    Item := @FItems[Index];
    if (Item^.States * Changed = []) or (Item^.Part in Result) then
      Continue;
    if Keys then
    begin
      if (Item^.Id <> 0) and (Adapter.Id(Element) <> Item^.Id) then
        Continue;
      { Type names compare lowercased for HTML elements only. }
      if (Item^.TypeName <> 0) and Adapter.IsHtmlElementInHtmlDocument(Element) and
         (Adapter.LocalName(Element) <> Item^.TypeName) then
        Continue;
      ClassIndex := 0;
      while (ClassIndex <= High(Item^.Classes)) and HasClass(Adapter, Element, Item^.Classes[ClassIndex]) do
        Inc(ClassIndex);
      if ClassIndex <= High(Item^.Classes) then
        Continue;
    end;
    Include(Result, Item^.Part);
    if Result = [siSelf, siDescendants, siSiblings] then
      Exit;
  end;
end;

end.
