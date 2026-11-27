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
  What new style rules can change: a rule styles only the elements its
  selectors' subjects match, so when sheets are added or a rule is
  appended (pages that build their styles from script do this over and
  over) the elements whose id, class or type a subject compound names
  are styled again, and the rest keeps its style. Their descendants
  follow when an inherited value changed, as for any restyle. This is
  what Servo's style system does for added sheets.

  A rule that cannot be followed this way (an at-rule other than the
  grouping ones, a subject naming none of these, such as '*' or ':hover'
  alone, or a rule reaching into shadow trees) asks for everything to be
  styled again.
}
unit Web.Style.SheetChanges;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.Atoms, Css.Selectors, Css.Stylesheets, Css.ElementAdapter, Css.PointerMaps;

type
  { What new rules may style, gathered as they come (by the names their
    subjects have, lowercase), until the styler marks it dirty. }
  TStyleRuleTargets = class
  private
    FIds, FClasses, FTypes: TCssPointerMap;
    FRoot: Boolean;
    FEverything: Boolean;
    FEmpty: Boolean;
    procedure AddName(Map: TCssPointerMap; Name: TCssAtom);
    function AddSubject(constref Compound: TCssCompoundSelector): Boolean;
    function AddSelectors(List: TCssSelectorList): Boolean;
    function AddRuleSubjects(Rule: TCssRule; Depth: Integer): Boolean;
    function IsTarget(Adapter: TCssElementAdapter; Element: TElement): Boolean;
    procedure Clear;
  public
    constructor Create;
    destructor Destroy; override;
    { A rule is now in effect. }
    procedure AddRule(Rule: TCssRule);
    { Sheets are now in effect. }
    procedure AddSheets(const Sheets: array of TCssStyleSheet);
    { Everything must be styled again (what else changed cannot be
      followed by subjects). }
    procedure AddEverything;
    { Marks the elements of Document the rules may style (all of them
      when one could not be followed) and starts over. }
    procedure MarkDirty(Document: TDocument; Adapter: TCssElementAdapter);
    property Empty: Boolean read FEmpty;
  end;

implementation

uses
  Web.Style.NodeData;

const
  MaximumNestingDepth = 16;

constructor TStyleRuleTargets.Create;
begin
  inherited Create;
  FIds := TCssPointerMap.Create;
  FClasses := TCssPointerMap.Create;
  FTypes := TCssPointerMap.Create;
  FEmpty := True;
end;

destructor TStyleRuleTargets.Destroy;
begin
  FIds.Free;
  FClasses.Free;
  FTypes.Free;
  inherited Destroy;
end;

procedure TStyleRuleTargets.Clear;
begin
  FIds.Clear;
  FClasses.Clear;
  FTypes.Clear;
  FRoot := False;
  FEverything := False;
  FEmpty := True;
end;

procedure TStyleRuleTargets.AddName(Map: TCssPointerMap; Name: TCssAtom);
begin
  Map.Put(Pointer(PtrUInt(Name)), 1);
end;

{ The best key of a subject compound: its id, else a class, else its
  type, else :root. False when it names none of them. }
function TStyleRuleTargets.AddSubject(constref Compound: TCssCompoundSelector): Boolean;
var
  Index: Integer;
  ClassKey, TypeKey: TCssAtom;
  IsRoot: Boolean;
begin
  ClassKey := NoAtom;
  TypeKey := NoAtom;
  IsRoot := False;
  for Index := 0 to High(Compound.Simples) do
    case Compound.Simples[Index].Kind of
      skId:
        begin
          AddName(FIds, Compound.Simples[Index].LowerName);
          Exit(True);
        end;
      skClass:
        if ClassKey = NoAtom then
          ClassKey := Compound.Simples[Index].LowerName;
      skType:
        TypeKey := Compound.Simples[Index].LowerName;
      skPseudoClass:
        if Compound.Simples[Index].PseudoClass = pcRoot then
          IsRoot := True;
    end;
  Result := True;
  if ClassKey <> NoAtom then
    AddName(FClasses, ClassKey)
  else if TypeKey <> NoAtom then
    AddName(FTypes, TypeKey)
  else if IsRoot then
    FRoot := True
  else
    Result := False;
end;

function TStyleRuleTargets.AddSelectors(List: TCssSelectorList): Boolean;
var
  Index: Integer;
  Selector: TCssComplexSelector;
begin
  if List = nil then
    Exit(False);
  for Index := 0 to List.Count - 1 do
  begin
    Selector := List.Items[Index];
    { ::slotted() and ::part() style elements of other trees. }
    if (Length(Selector.Compounds) = 0) or (Selector.PseudoElement in [peSlotted, pePart]) then
      Exit(False);
    if not AddSubject(Selector.Compounds[0]) then
      Exit(False);
  end;
  Result := True;
end;

function TStyleRuleTargets.AddRuleSubjects(Rule: TCssRule; Depth: Integer): Boolean;
var
  Index: Integer;
begin
  if Depth > MaximumNestingDepth then
    Exit(False);
  case Rule.Kind of
    rkStyle:
      if not AddSelectors(TCssStyleRule(Rule).Selectors) then
        Exit(False);
    rkMedia, rkSupports, rkContainer, rkLayerBlock, rkNestedDeclarations: ;
    rkNamespace: Exit(True);
  else
    { Imports, layer orders, fonts, keyframes, registered properties ... }
    Exit(False);
  end;
  if Rule is TCssGroupingRule then
    for Index := 0 to High(TCssGroupingRule(Rule).Rules) do
      if not AddRuleSubjects(TCssGroupingRule(Rule).Rules[Index], Depth + 1) then
        Exit(False);
  Result := True;
end;

procedure TStyleRuleTargets.AddRule(Rule: TCssRule);
begin
  FEmpty := False;
  if not FEverything and not AddRuleSubjects(Rule, 0) then
    FEverything := True;
end;

procedure TStyleRuleTargets.AddSheets(const Sheets: array of TCssStyleSheet);
var
  SheetIndex, Index: Integer;
begin
  for SheetIndex := 0 to High(Sheets) do
    for Index := 0 to High(Sheets[SheetIndex].Rules) do
    begin
      if FEverything then
        Exit;
      AddRule(Sheets[SheetIndex].Rules[Index]);
    end;
end;

procedure TStyleRuleTargets.AddEverything;
begin
  FEmpty := False;
  FEverything := True;
end;

function HasName(Map: TCssPointerMap; Name: TCssAtom): Boolean; inline;
var
  Value: PtrInt;
begin
  Result := (Map.Count > 0) and (Name <> NoAtom) and Map.TryGet(Pointer(PtrUInt(Name)), Value);
end;

function TStyleRuleTargets.IsTarget(Adapter: TCssElementAdapter; Element: TElement): Boolean;
var
  Index, ClassCount: Integer;
  ClassList: PCssAtom;
begin
  if HasName(FIds, LowercaseAtom(Adapter.Id(Element))) then
    Exit(True);
  if FClasses.Count > 0 then
  begin
    ClassList := Adapter.Classes(Element, ClassCount);
    for Index := 0 to ClassCount - 1 do
      if HasName(FClasses, LowercaseAtom(ClassList[Index])) then
        Exit(True);
  end;
  if HasName(FTypes, LowercaseAtom(Adapter.LocalName(Element))) then
    Exit(True);
  Result := FRoot and Adapter.IsRoot(Element);
end;

procedure TStyleRuleTargets.MarkDirty(Document: TDocument; Adapter: TCssElementAdapter);
var
  Node: TNode;
begin
  if FEmpty then
    Exit;
  if FEverything then
    MarkSubtreeStyleDirty(Document)
  else
  begin
    { Document rules do not reach into shadow trees (their hosts, styled
      again, carry inherited changes down). }
    Node := Document.FirstChild;
    while Node <> nil do
    begin
      if Node.IsElement and IsTarget(Adapter, TElement(Node)) then
        MarkStyleDirty(Node);
      Node := Node.NextInTree(Document);
    end;
  end;
  Clear;
end;

end.
