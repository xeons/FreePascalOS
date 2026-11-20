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
  Selectors (Selectors Level 4): the parsed form, specificity and
  serialization.

  A complex selector keeps its compound selectors from right to left,
  the order matching walks them: Compounds[0] is the subject, and
  Compounds[I].Combinator says how Compounds[I + 1] (to its left)
  relates to it. A relative selector (inside :has) ends with an anchor
  compound standing for the :has element.

  Selector lists are classes that own their selectors; a simple
  selector's Arguments (the lists of :is, :where, :not, :has and
  :nth-child(An+B of S)) belong to it. The nesting selector '&' points
  at its parent rule's list, which outlives it.
}
unit Css.Selectors;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms;

type
  TCssCombinator = (cmNone, cmDescendant, cmChild, cmNextSibling, cmSubsequentSibling);

  TCssSimpleKind = (skType, skUniversal, skId, skClass, skAttribute, skPseudoClass,
    skPseudoElement, skNesting, skHasAnchor);

  { Which namespace a type or attribute selector asks for. }
  TCssNamespaceKind = (
    { No prefix: the default namespace if one is declared (types only). }
    nkDefault,
    { '*|' }
    nkAny,
    { '|' }
    nkNone,
    { 'prefix|', resolved to Namespace }
    nkSpecific);

  TCssAttributeOperator = (aoExists, aoEquals, aoIncludes, aoDashMatch, aoPrefix, aoSuffix,
    aoSubstring);
  TCssAttributeCase = (acDefault, acInsensitive, acSensitive);

  TCssPseudoClass = (pcNone,
    { element states (TCssElementState) }
    pcHover, pcActive, pcFocus, pcFocusVisible, pcFocusWithin, pcLink, pcVisited, pcAnyLink,
    pcTarget, pcTargetWithin, pcChecked, pcIndeterminate, pcDisabled, pcEnabled, pcRequired,
    pcOptional, pcReadOnly, pcReadWrite, pcPlaceholderShown, pcDefault, pcValid, pcInvalid,
    pcInRange, pcOutOfRange, pcAutofill, pcUserValid, pcUserInvalid, pcOpen, pcModal,
    pcPopoverOpen, pcFullscreen, pcPlaying, pcPaused, pcDefined,
    { tree structure }
    pcScope, pcRoot, pcEmpty, pcFirstChild, pcLastChild, pcOnlyChild, pcFirstOfType,
    pcLastOfType, pcOnlyOfType, pcNthChild, pcNthLastChild, pcNthOfType, pcNthLastOfType,
    { logical and linguistic }
    pcIs, pcWhere, pcNot, pcHas, pcLang, pcDir);

  TCssPseudoElement = (peNone, peBefore, peAfter, peMarker, pePlaceholder, peSelection,
    peFirstLine, peFirstLetter, peBackdrop, peFileSelectorButton,
    { a ::-webkit- pseudo-element nobody knows: valid, never matches }
    peUnknownPrefixed);

  TCssSelectorList = class;
  TCssComplexSelector = class;

  TCssSimpleSelector = record
    Kind: TCssSimpleKind;
    PseudoClass: TCssPseudoClass;
    PseudoElement: TCssPseudoElement;
    NamespaceKind: TCssNamespaceKind;
    AttributeOperator: TCssAttributeOperator;
    AttributeCase: TCssAttributeCase;
    { Type, id, class and attribute names as written, and lowercased. }
    Name: TCssAtom;
    LowerName: TCssAtom;
    Namespace: TCssAtom;
    { The namespace prefix as written (for serialization). }
    NamespacePrefix: TCssAtom;
    { The attribute value; the :dir direction; the prefixed pseudo-element's name. }
    Value: string;
    { The :lang ranges. }
    Languages: array of string;
    NthA, NthB: Integer;
    { :is, :where, :not, :has, :nth-*(An+B of S); owned. }
    Arguments: TCssSelectorList;
    { '&': the parent rule's selectors (not owned; nil at the top level). }
    NestingParent: TCssSelectorList;
  end;
  TCssSimpleSelectorArray = array of TCssSimpleSelector;

  TCssCompoundSelector = record
    Simples: TCssSimpleSelectorArray;
    { How the next compound (to the left) relates to this one. }
    Combinator: TCssCombinator;
  end;

  TCssComplexSelector = class
  public
    Compounds: array of TCssCompoundSelector;
    { (a shl 20) or (b shl 10) or c, each part at most 1023. }
    Specificity: LongWord;
    PseudoElement: TCssPseudoElement;
    { Hashes of names every match must find among the ancestors (the
      bloom filter's quick rejection); 0 ends the list. }
    AncestorHashes: array[0..3] of LongWord;
    IsRelative: Boolean;
    destructor Destroy; override;
    { Specificity and ancestor hashes, once the compounds are in place. }
    procedure Finish;
    function Serialize: string;
  end;

  TCssSelectorList = class
  public
    Items: array of TCssComplexSelector;
    destructor Destroy; override;
    procedure Add(Selector: TCssComplexSelector);
    function Count: Integer;
    function MaxSpecificity: LongWord;
    function Serialize: string;
  end;

const
  { The specificity of one id, class and type selector. }
  SpecificityId = 1 shl 20;
  SpecificityClass = 1 shl 10;
  SpecificityType = 1;

function AddSpecificity(Left, Right: LongWord): LongWord;
function SpecificityOfCompound(const Compound: TCssCompoundSelector): LongWord;
function PseudoClassName(PseudoClass: TCssPseudoClass): string;
function PseudoClassByName(const LowerName: string): TCssPseudoClass;
function PseudoElementName(PseudoElement: TCssPseudoElement): string;
function PseudoElementByName(const LowerName: string): TCssPseudoElement;
function SerializeAnPlusB(A, B: Integer): string;
function SerializeCompound(const Compound: TCssCompoundSelector): string;

implementation

uses
  SysUtils, TypInfo, Css.Serialization;

function AddSpecificity(Left, Right: LongWord): LongWord;
var
  A, B, C: LongWord;
begin
  A := (Left shr 20) + (Right shr 20);
  B := ((Left shr 10) and 1023) + ((Right shr 10) and 1023);
  C := (Left and 1023) + (Right and 1023);
  if A > 1023 then A := 1023;
  if B > 1023 then B := 1023;
  if C > 1023 then C := 1023;
  Result := (A shl 20) or (B shl 10) or C;
end;

function ListSpecificity(List: TCssSelectorList): LongWord;
begin
  if List = nil then
    Result := 0
  else
    Result := List.MaxSpecificity;
end;

function SpecificityOfSimple(const Simple: TCssSimpleSelector): LongWord;
begin
  case Simple.Kind of
    skType: Result := SpecificityType;
    skId: Result := SpecificityId;
    skClass, skAttribute: Result := SpecificityClass;
    skPseudoElement: Result := SpecificityType;
    skNesting: Result := ListSpecificity(Simple.NestingParent);
    skPseudoClass:
      case Simple.PseudoClass of
        pcWhere: Result := 0;
        pcIs, pcNot, pcHas: Result := ListSpecificity(Simple.Arguments);
        pcNthChild, pcNthLastChild:
          Result := AddSpecificity(SpecificityClass, ListSpecificity(Simple.Arguments));
      else
        Result := SpecificityClass;
      end;
  else
    Result := 0;
  end;
end;

function SpecificityOfCompound(const Compound: TCssCompoundSelector): LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Compound.Simples) do
    Result := AddSpecificity(Result, SpecificityOfSimple(Compound.Simples[Index]));
end;

function EnumToCssName(const Identifier: string; PrefixLength: Integer): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '';
  for Index := PrefixLength + 1 to Length(Identifier) do
  begin
    Character := Identifier[Index];
    if Character in ['A'..'Z'] then
    begin
      if Result <> '' then
        Result := Result + '-';
      Result := Result + Chr(Ord(Character) + 32);
    end
    else
      Result := Result + Character;
  end;
end;

function PseudoClassName(PseudoClass: TCssPseudoClass): string;
begin
  Result := EnumToCssName(GetEnumName(TypeInfo(TCssPseudoClass), Ord(PseudoClass)), 2);
end;

function PseudoClassByName(const LowerName: string): TCssPseudoClass;
var
  Candidate: TCssPseudoClass;
begin
  for Candidate := Succ(pcNone) to High(TCssPseudoClass) do
    if PseudoClassName(Candidate) = LowerName then
      Exit(Candidate);
  { Older spellings. }
  if LowerName = '-webkit-any-link' then
    Exit(pcAnyLink);
  if LowerName = '-webkit-autofill' then
    Exit(pcAutofill);
  Result := pcNone;
end;

function PseudoElementName(PseudoElement: TCssPseudoElement): string;
begin
  Result := EnumToCssName(GetEnumName(TypeInfo(TCssPseudoElement), Ord(PseudoElement)), 2);
end;

function PseudoElementByName(const LowerName: string): TCssPseudoElement;
var
  Candidate: TCssPseudoElement;
begin
  for Candidate := Succ(peNone) to Pred(peUnknownPrefixed) do
    if PseudoElementName(Candidate) = LowerName then
      Exit(Candidate);
  if Copy(LowerName, 1, 8) = '-webkit-' then
    Exit(peUnknownPrefixed);
  Result := peNone;
end;

function SerializeAnPlusB(A, B: Integer): string;
begin
  if A = 0 then
    Exit(IntToStr(B));
  if A = 1 then
    Result := 'n'
  else if A = -1 then
    Result := '-n'
  else
    Result := IntToStr(A) + 'n';
  if B > 0 then
    Result := Result + '+' + IntToStr(B)
  else if B < 0 then
    Result := Result + IntToStr(B);
end;

function SerializeNamespacePrefix(const Simple: TCssSimpleSelector): string;
begin
  case Simple.NamespaceKind of
    nkAny: Result := '*|';
    nkNone: Result := '|';
    nkSpecific: Result := SerializeIdentifier(AtomText(Simple.NamespacePrefix)) + '|';
  else
    Result := '';
  end;
end;

function SerializeSimple(const Simple: TCssSimpleSelector): string;
const
  Operators: array[TCssAttributeOperator] of string = ('', '=', '~=', '|=', '^=', '$=', '*=');
var
  Index: Integer;
begin
  case Simple.Kind of
    skType: Result := SerializeNamespacePrefix(Simple) + SerializeIdentifier(AtomText(Simple.Name));
    skUniversal: Result := SerializeNamespacePrefix(Simple) + '*';
    skId: Result := '#' + SerializeIdentifier(AtomText(Simple.Name));
    skClass: Result := '.' + SerializeIdentifier(AtomText(Simple.Name));
    skAttribute:
      begin
        Result := '[' + SerializeNamespacePrefix(Simple) + SerializeIdentifier(AtomText(Simple.Name));
        if Simple.AttributeOperator <> aoExists then
        begin
          Result := Result + Operators[Simple.AttributeOperator] + SerializeString(Simple.Value);
          if Simple.AttributeCase = acInsensitive then
            Result := Result + ' i'
          else if Simple.AttributeCase = acSensitive then
            Result := Result + ' s';
        end;
        Result := Result + ']';
      end;
    skNesting: Result := '&';
    skHasAnchor: Result := '';
    skPseudoElement:
      if Simple.PseudoElement = peUnknownPrefixed then
        Result := '::' + SerializeIdentifier(Simple.Value)
      else
        Result := '::' + PseudoElementName(Simple.PseudoElement);
    skPseudoClass:
      begin
        Result := ':' + PseudoClassName(Simple.PseudoClass);
        case Simple.PseudoClass of
          pcIs, pcWhere, pcNot, pcHas:
            Result := Result + '(' + Simple.Arguments.Serialize + ')';
          pcNthChild, pcNthLastChild, pcNthOfType, pcNthLastOfType:
            begin
              Result := Result + '(' + SerializeAnPlusB(Simple.NthA, Simple.NthB);
              if Simple.Arguments <> nil then
                Result := Result + ' of ' + Simple.Arguments.Serialize;
              Result := Result + ')';
            end;
          pcLang:
            begin
              Result := Result + '(';
              for Index := 0 to High(Simple.Languages) do
              begin
                if Index > 0 then
                  Result := Result + ', ';
                Result := Result + SerializeIdentifier(Simple.Languages[Index]);
              end;
              Result := Result + ')';
            end;
          pcDir:
            Result := Result + '(' + Simple.Value + ')';
        end;
      end;
  else
    Result := '';
  end;
end;

function SerializeCompound(const Compound: TCssCompoundSelector): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Compound.Simples) do
    Result := Result + SerializeSimple(Compound.Simples[Index]);
end;

function CombinatorText(Combinator: TCssCombinator): string;
begin
  case Combinator of
    cmDescendant: Result := ' ';
    cmChild: Result := ' > ';
    cmNextSibling: Result := ' + ';
    cmSubsequentSibling: Result := ' ~ ';
  else
    Result := '';
  end;
end;

destructor TCssComplexSelector.Destroy;
var
  CompoundIndex, SimpleIndex: Integer;
begin
  for CompoundIndex := 0 to High(Compounds) do
    for SimpleIndex := 0 to High(Compounds[CompoundIndex].Simples) do
      FreeAndNil(Compounds[CompoundIndex].Simples[SimpleIndex].Arguments);
  inherited Destroy;
end;

procedure TCssComplexSelector.Finish;
var
  Index, SimpleIndex, HashCount: Integer;
  Simple: ^TCssSimpleSelector;
  Hash: LongWord;
begin
  Specificity := 0;
  PseudoElement := peNone;
  for Index := 0 to High(Compounds) do
    Specificity := AddSpecificity(Specificity, SpecificityOfCompound(Compounds[Index]));
  if Length(Compounds) > 0 then
    for SimpleIndex := 0 to High(Compounds[0].Simples) do
      if Compounds[0].Simples[SimpleIndex].Kind = skPseudoElement then
        PseudoElement := Compounds[0].Simples[SimpleIndex].PseudoElement;
  FillChar(AncestorHashes, SizeOf(AncestorHashes), 0);
  HashCount := 0;
  { A compound joined to its right neighbour by a child or descendant
    combinator stands for an ancestor of the subject. }
  for Index := 1 to High(Compounds) do
  begin
    if not (Compounds[Index - 1].Combinator in [cmChild, cmDescendant]) then
      Continue;
    for SimpleIndex := 0 to High(Compounds[Index].Simples) do
    begin
      if HashCount > High(AncestorHashes) then
        Exit;
      Simple := @Compounds[Index].Simples[SimpleIndex];
      case Simple^.Kind of
        skType: Hash := AtomHash(Simple^.LowerName);
        skId, skClass: Hash := AtomHash(LowercaseAtom(Simple^.Name));
      else
        Continue;
      end;
      if Hash = 0 then
        Hash := 1;
      AncestorHashes[HashCount] := Hash;
      Inc(HashCount);
    end;
  end;
end;

function TCssComplexSelector.Serialize: string;
var
  Index, Last: Integer;
begin
  Result := '';
  Last := High(Compounds);
  if IsRelative then
  begin
    { The anchor compound is left out; its combinator leads. }
    Dec(Last);
    if (Last >= 0) and (Compounds[Last].Combinator <> cmDescendant) then
      Result := Trim(CombinatorText(Compounds[Last].Combinator)) + ' ';
  end;
  for Index := Last downto 0 do
  begin
    Result := Result + SerializeCompound(Compounds[Index]);
    if Index > 0 then
      Result := Result + CombinatorText(Compounds[Index - 1].Combinator);
  end;
end;

destructor TCssSelectorList.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Items) do
    Items[Index].Free;
  inherited Destroy;
end;

procedure TCssSelectorList.Add(Selector: TCssComplexSelector);
begin
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := Selector;
end;

function TCssSelectorList.Count: Integer;
begin
  Result := Length(Items);
end;

function TCssSelectorList.MaxSpecificity: LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Items) do
    if Items[Index].Specificity > Result then
      Result := Items[Index].Specificity;
end;

function TCssSelectorList.Serialize: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Items) do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + Items[Index].Serialize;
  end;
end;

end.
