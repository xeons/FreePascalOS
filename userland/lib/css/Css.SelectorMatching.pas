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
  Matching selectors against elements, right to left, through the
  element adapter.

  A complex selector is matched from its subject compound leftwards.
  Failures carry how far back matching has to restart (the scheme
  WebKit and Servo use), so a descendant combinator never retries
  ancestors that cannot help, and a hopeless selector stops at once:
  matching is linear in the tree depth for ordinary selectors.

  Before any of that, the ancestor bloom filter (when the caller keeps
  one for the element) rejects selectors whose ancestor names are
  absent. :has searches the subtree (or following siblings) of its
  element, which is slower and fine for the sizes pages use.

  Sibling positions for the :nth-* pseudo-classes are cached per
  element until ResetCaches (after the tree changes).
}
unit Css.SelectorMatching;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Selectors, Css.ElementAdapter, Css.BloomFilter, Css.PointerMaps;

type
  TCssSelectorMatcher = class
  private
    FAdapter: TCssElementAdapter;
    FQuirks: Boolean;
    FFilter: TCssAncestorFilter;
    FScope: TCssElement;
    FShadowHost: TCssElement;
    FShadowTrees: Boolean;
    FAnchors: array of TCssElement;
    FAnchorCount: Integer;
    FChildIndexes: TCssPointerMap;
    FLastChildIndexes: TCssPointerMap;
    FTypeIndexes: TCssPointerMap;
    FLastTypeIndexes: TCssPointerMap;
    function MatchCompound(const Compound: TCssCompoundSelector; Element: TCssElement): Boolean;
    function MatchSimple(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function MatchAttribute(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function MatchPseudoClass(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function MatchNth(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function MatchHas(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function MatchLanguage(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function SiblingIndex(Element: TCssElement; FromEnd, OfType: Boolean): Integer;
    function SameName(First, Second: TCssElement): Boolean;
    function MatchFeaturelessHost(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
    function MatchHostContext(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
  public
    { The parent combinators see: the tree parent, the host only as the
      parent of its shadow tree's top elements while matching that
      tree's rules, nothing above the featureless host. }
    function TreeParent(Element: TCssElement): TCssElement;
    constructor Create(Adapter: TCssElementAdapter);
    destructor Destroy; override;
    { Whether Selector matches Element (for PseudoElement, the
      originating element). The ancestor filter is used only when it
      holds exactly Element's ancestors. }
    function Matches(Selector: TCssComplexSelector; Element: TCssElement;
      PseudoElement: TCssPseudoElement = peNone): Boolean;
    function MatchesList(List: TCssSelectorList; Element: TCssElement): Boolean;
    { Whether every ancestor hash of Selector might be in the filter. }
    function PassesFilter(Selector: TCssComplexSelector): Boolean;
    { Forgets the cached sibling positions. }
    procedure ResetCaches;
    { Reads the document's quirks mode again. }
    procedure Refresh;
    property Adapter: TCssElementAdapter read FAdapter;
    { The ancestor filter, valid for the element matched (or nil). }
    property Filter: TCssAncestorFilter read FFilter write FFilter;
    { :scope (nil: the root). }
    property Scope: TCssElement read FScope write FScope;
    { The host of the shadow tree whose rules are matched (nil: the
      document's): it is featureless (only :host, :host() and
      :host-context() match it) and nothing above or beside it is seen. }
    property ShadowHost: TCssElement read FShadowHost write FShadowHost;
    { For a ::slotted() selector matched on a slot: whether its argument
      matches Element (the slotted element). }
    function SlottedArgumentMatches(Selector: TCssComplexSelector; Element: TCssElement): Boolean;
    { For a ::part() selector matched on a host: whether Element (in the
      host's shadow tree) has every part name it asks for. }
    function PartNamesMatch(Selector: TCssComplexSelector; Element: TCssElement): Boolean;
  end;

implementation

type
  TMatchResult = (mrMatched, mrRestartFromLaterSibling, mrRestartFromDescendant, mrNotMatchedGlobally);

var
  CaseInsensitiveValueAttributes: array of TCssAtom;

constructor TCssSelectorMatcher.Create(Adapter: TCssElementAdapter);
begin
  inherited Create;
  FAdapter := Adapter;
  FChildIndexes := TCssPointerMap.Create;
  FLastChildIndexes := TCssPointerMap.Create;
  FTypeIndexes := TCssPointerMap.Create;
  FLastTypeIndexes := TCssPointerMap.Create;
  Refresh;
end;

destructor TCssSelectorMatcher.Destroy;
begin
  FChildIndexes.Free;
  FLastChildIndexes.Free;
  FTypeIndexes.Free;
  FLastTypeIndexes.Free;
  inherited Destroy;
end;

procedure TCssSelectorMatcher.Refresh;
begin
  FQuirks := FAdapter.QuirksMode = qmQuirks;
end;

procedure TCssSelectorMatcher.ResetCaches;
begin
  FChildIndexes.Clear;
  FLastChildIndexes.Clear;
  FTypeIndexes.Clear;
  FLastTypeIndexes.Clear;
end;

function TCssSelectorMatcher.PassesFilter(Selector: TCssComplexSelector): Boolean;
var
  Index: Integer;
begin
  Result := True;
  if FFilter = nil then
    Exit;
  for Index := 0 to High(Selector.AncestorHashes) do
  begin
    if Selector.AncestorHashes[Index] = 0 then
      Exit;
    if not FFilter.MightContain(Selector.AncestorHashes[Index]) then
      Exit(False);
  end;
end;

function TCssSelectorMatcher.SameName(First, Second: TCssElement): Boolean;
begin
  Result := (FAdapter.LocalName(First) = FAdapter.LocalName(Second)) and
    (FAdapter.NamespaceUri(First) = FAdapter.NamespaceUri(Second));
end;

function TCssSelectorMatcher.SiblingIndex(Element: TCssElement; FromEnd, OfType: Boolean): Integer;
var
  Map: TCssPointerMap;
  Sibling: TCssElement;
  Count: Integer;
  Cached: PtrInt;
begin
  if FromEnd then
  begin
    if OfType then Map := FLastTypeIndexes else Map := FLastChildIndexes;
  end
  else if OfType then
    Map := FTypeIndexes
  else
    Map := FChildIndexes;
  if Map.TryGet(Element, Cached) then
    Exit(Cached);
  Count := 1;
  if FromEnd then
    Sibling := FAdapter.NextSibling(Element)
  else
    Sibling := FAdapter.PreviousSibling(Element);
  while Sibling <> nil do
  begin
    if not OfType or SameName(Sibling, Element) then
    begin
      { A sibling whose position is known ends the walk. }
      if Map.TryGet(Sibling, Cached) then
      begin
        Inc(Count, Cached);
        Break;
      end;
      Inc(Count);
    end;
    if FromEnd then
      Sibling := FAdapter.NextSibling(Sibling)
    else
      Sibling := FAdapter.PreviousSibling(Sibling);
  end;
  Map.Put(Element, Count);
  Result := Count;
end;

function NthMatches(A, B, Index: Integer): Boolean;
var
  Difference: Integer;
begin
  Difference := Index - B;
  if A = 0 then
    Result := Difference = 0
  else
    Result := (Difference div A >= 0) and (Difference mod A = 0);
end;

function TCssSelectorMatcher.MatchNth(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  Index: Integer;
  Sibling: TCssElement;
  FromEnd, OfType: Boolean;
begin
  FromEnd := Simple.PseudoClass in [pcNthLastChild, pcNthLastOfType];
  OfType := Simple.PseudoClass in [pcNthOfType, pcNthLastOfType];
  if Simple.Arguments <> nil then
  begin
    { "of S": count only the siblings matching S. }
    if not MatchesList(Simple.Arguments, Element) then
      Exit(False);
    Index := 1;
    if FromEnd then
      Sibling := FAdapter.NextSibling(Element)
    else
      Sibling := FAdapter.PreviousSibling(Element);
    while Sibling <> nil do
    begin
      if MatchesList(Simple.Arguments, Sibling) then
        Inc(Index);
      if FromEnd then
        Sibling := FAdapter.NextSibling(Sibling)
      else
        Sibling := FAdapter.PreviousSibling(Sibling);
    end;
  end
  else
    Index := SiblingIndex(Element, FromEnd, OfType);
  Result := NthMatches(Simple.NthA, Simple.NthB, Index);
end;

function IsCaseInsensitiveValueAttribute(Name: TCssAtom): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(CaseInsensitiveValueAttributes) do
    if CaseInsensitiveValueAttributes[Index] = Name then
      Exit(True);
  Result := False;
end;

function IsSpace(Character: Char): Boolean; inline;
begin
  Result := Character in [' ', #9, #10, #12, #13];
end;

function ValueMatches(const Simple: TCssSimpleSelector; const Value: string; Insensitive: Boolean): Boolean;
var
  Wanted, Actual: string;
  Position, Start, WantedLength: Integer;
begin
  if Insensitive then
  begin
    Wanted := AsciiLowercase(Simple.Value);
    Actual := AsciiLowercase(Value);
  end
  else
  begin
    Wanted := Simple.Value;
    Actual := Value;
  end;
  WantedLength := Length(Wanted);
  case Simple.AttributeOperator of
    aoExists: Result := True;
    aoEquals: Result := Actual = Wanted;
    aoDashMatch:
      Result := (Actual = Wanted) or ((Length(Actual) > WantedLength) and
        (Copy(Actual, 1, WantedLength) = Wanted) and (Actual[WantedLength + 1] = '-'));
    aoPrefix: Result := (WantedLength > 0) and (Copy(Actual, 1, WantedLength) = Wanted);
    aoSuffix:
      Result := (WantedLength > 0) and (Length(Actual) >= WantedLength) and
        (Copy(Actual, Length(Actual) - WantedLength + 1, WantedLength) = Wanted);
    aoSubstring: Result := (WantedLength > 0) and (Pos(Wanted, Actual) > 0);
    aoIncludes:
      begin
        Result := False;
        if WantedLength = 0 then
          Exit;
        for Position := 1 to WantedLength do
          if IsSpace(Wanted[Position]) then
            Exit;
        Position := 1;
        while Position <= Length(Actual) do
        begin
          while (Position <= Length(Actual)) and IsSpace(Actual[Position]) do
            Inc(Position);
          Start := Position;
          while (Position <= Length(Actual)) and not IsSpace(Actual[Position]) do
            Inc(Position);
          if (Position - Start = WantedLength) and (Copy(Actual, Start, WantedLength) = Wanted) then
            Exit(True);
        end;
      end;
  else
    Result := False;
  end;
end;

function TCssSelectorMatcher.MatchAttribute(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  IsHtml, Insensitive: Boolean;
  Name, Namespace, AttributeNamespace, AttributeName: TCssAtom;
  Value: string;
  Index: Integer;
begin
  IsHtml := FAdapter.IsHtmlElementInHtmlDocument(Element);
  if IsHtml then
    Name := Simple.LowerName
  else
    Name := Simple.Name;
  case Simple.AttributeCase of
    acInsensitive: Insensitive := True;
    acSensitive: Insensitive := False;
  else
    Insensitive := IsHtml and (Simple.NamespaceKind in [nkDefault, nkNone]) and
      IsCaseInsensitiveValueAttribute(Simple.LowerName);
  end;
  if Simple.NamespaceKind = nkAny then
  begin
    for Index := 0 to FAdapter.AttributeCount(Element) - 1 do
    begin
      FAdapter.AttributeAt(Element, Index, AttributeNamespace, AttributeName, Value);
      if (AttributeName = Name) and ValueMatches(Simple, Value, Insensitive) then
        Exit(True);
    end;
    Exit(False);
  end;
  if Simple.NamespaceKind = nkSpecific then
    Namespace := Simple.Namespace
  else
    Namespace := NoAtom;
  if not FAdapter.FindAttribute(Element, Namespace, Name, Value) then
    Exit(False);
  Result := ValueMatches(Simple, Value, Insensitive);
end;

function TCssSelectorMatcher.MatchLanguage(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  Language, Range: string;
  Index: Integer;
begin
  Language := AsciiLowercase(FAdapter.Language(Element));
  for Index := 0 to High(Simple.Languages) do
  begin
    Range := AsciiLowercase(Simple.Languages[Index]);
    if Range = '*' then
    begin
      if Language <> '' then
        Exit(True);
    end
    else if Copy(Range, 1, 2) = '*-' then
    begin
      if Pos(Copy(Range, 2, Length(Range)), Language) > 0 then
        Exit(True);
    end
    else if (Language = Range) or ((Length(Language) > Length(Range)) and
      (Copy(Language, 1, Length(Range)) = Range) and (Language[Length(Range) + 1] = '-')) then
      Exit(True);
  end;
  Result := False;
end;

function TCssSelectorMatcher.MatchHas(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  SelectorIndex, Depth: Integer;
  Selector: TCssComplexSelector;
  First: TCssCombinator;
  Candidate, Next, Sibling: TCssElement;
  SearchSubtrees, OnlyChildren: Boolean;
  SavedFilter: TCssAncestorFilter;

  function TryCandidate(Target: TCssElement): Boolean;
  begin
    Result := Matches(Selector, Target);
  end;

  { Every element of the subtree below Root (not Root itself). }
  function SearchBelow(Root: TCssElement; ChildrenOnly: Boolean): Boolean;
  begin
    Result := False;
    Candidate := FAdapter.FirstChild(Root);
    Depth := 0;
    while Candidate <> nil do
    begin
      if TryCandidate(Candidate) then
        Exit(True);
      Next := nil;
      if not ChildrenOnly then
        Next := FAdapter.FirstChild(Candidate);
      if Next <> nil then
      begin
        Inc(Depth);
        Candidate := Next;
        Continue;
      end;
      while Candidate <> nil do
      begin
        Next := FAdapter.NextSibling(Candidate);
        if Next <> nil then
        begin
          Candidate := Next;
          Break;
        end;
        if Depth = 0 then
        begin
          Candidate := nil;
          Break;
        end;
        Dec(Depth);
        Candidate := FAdapter.Parent(Candidate);
      end;
    end;
  end;

  function OnlyChildCombinators(Item: TCssComplexSelector): Boolean;
  var
    Index: Integer;
  begin
    for Index := 0 to High(Item.Compounds) - 1 do
      if Item.Compounds[Index].Combinator <> cmChild then
        Exit(False);
    Result := True;
  end;

  function HasDescendantPart(Item: TCssComplexSelector): Boolean;
  var
    Index: Integer;
  begin
    for Index := 0 to High(Item.Compounds) - 2 do
      if Item.Compounds[Index].Combinator in [cmChild, cmDescendant] then
        Exit(True);
    Result := False;
  end;

begin
  Result := False;
  if Simple.Arguments = nil then
    Exit;
  SavedFilter := FFilter;
  FFilter := nil;
  if FAnchorCount >= Length(FAnchors) then
    SetLength(FAnchors, FAnchorCount * 2 + 4);
  FAnchors[FAnchorCount] := Element;
  Inc(FAnchorCount);
  try
    for SelectorIndex := 0 to High(Simple.Arguments.Items) do
    begin
      Selector := Simple.Arguments.Items[SelectorIndex];
      if Length(Selector.Compounds) < 2 then
        Continue;
      First := Selector.Compounds[High(Selector.Compounds) - 1].Combinator;
      if First in [cmChild, cmDescendant] then
      begin
        OnlyChildren := OnlyChildCombinators(Selector) and (Length(Selector.Compounds) = 2);
        if SearchBelow(Element, OnlyChildren) then
          Exit(True);
      end
      else
      begin
        SearchSubtrees := HasDescendantPart(Selector);
        Sibling := FAdapter.NextSibling(Element);
        while Sibling <> nil do
        begin
          if TryCandidate(Sibling) then
            Exit(True);
          if SearchSubtrees and SearchBelow(Sibling, False) then
            Exit(True);
          if (First = cmNextSibling) and not SearchSubtrees and (Length(Selector.Compounds) = 2) then
            Break;
          Sibling := FAdapter.NextSibling(Sibling);
        end;
      end;
    end;
  finally
    Dec(FAnchorCount);
    FFilter := SavedFilter;
  end;
end;

{ :host-context(X): the host or one of its shadow-including ancestors
  matches X. }
function TCssSelectorMatcher.MatchHostContext(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  SavedHost, Current: TCssElement;
begin
  Result := False;
  SavedHost := FShadowHost;
  FShadowHost := nil;
  try
    Current := Element;
    while Current <> nil do
    begin
      if MatchesList(Simple.Arguments, Current) then
        Exit(True);
      Current := FAdapter.Parent(Current);
    end;
  finally
    FShadowHost := SavedHost;
  end;
end;

{ A simple selector against the featureless shadow host of the rules'
  shadow tree. }
function TCssSelectorMatcher.MatchFeaturelessHost(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  SavedHost: TCssElement;
begin
  Result := False;
  if Simple.Kind = skPseudoElement then
    Exit(True);
  if Simple.Kind <> skPseudoClass then
    Exit;
  case Simple.PseudoClass of
    pcHost:
      begin
        if Simple.Arguments = nil then
          Exit(True);
        SavedHost := FShadowHost;
        FShadowHost := nil;
        try
          Result := MatchesList(Simple.Arguments, Element);
        finally
          FShadowHost := SavedHost;
        end;
      end;
    pcHostContext:
      Result := MatchHostContext(Simple, Element);
    pcIs, pcWhere:
      Result := MatchesList(Simple.Arguments, Element);
    pcNot:
      Result := not MatchesList(Simple.Arguments, Element);
  end;
end;

function TCssSelectorMatcher.TreeParent(Element: TCssElement): TCssElement;
begin
  if (FShadowHost <> nil) and (Element = FShadowHost) then
    Exit(nil);
  Result := FAdapter.Parent(Element);
  if FShadowTrees and (Result <> nil) and (Result <> FShadowHost) and FAdapter.ParentIsShadowHost(Element) then
    Result := nil;
end;

function TCssSelectorMatcher.SlottedArgumentMatches(Selector: TCssComplexSelector; Element: TCssElement): Boolean;
var
  Index: Integer;
  SavedHost: TCssElement;
  SavedFilter: TCssAncestorFilter;
begin
  Result := False;
  if Length(Selector.Compounds) = 0 then
    Exit;
  for Index := 0 to High(Selector.Compounds[0].Simples) do
    if (Selector.Compounds[0].Simples[Index].Kind = skPseudoElement) and
      (Selector.Compounds[0].Simples[Index].PseudoElement = peSlotted) then
    begin
      SavedHost := FShadowHost;
      SavedFilter := FFilter;
      FShadowHost := nil;
      try
        Result := MatchesList(Selector.Compounds[0].Simples[Index].Arguments, Element);
      finally
        FShadowHost := SavedHost;
        FFilter := SavedFilter;
      end;
      Exit;
    end;
end;

function TCssSelectorMatcher.PartNamesMatch(Selector: TCssComplexSelector; Element: TCssElement): Boolean;
var
  Index, NameIndex: Integer;
  Simple: ^TCssSimpleSelector;
begin
  Result := False;
  if Length(Selector.Compounds) = 0 then
    Exit;
  for Index := 0 to High(Selector.Compounds[0].Simples) do
  begin
    Simple := @Selector.Compounds[0].Simples[Index];
    if (Simple^.Kind = skPseudoElement) and (Simple^.PseudoElement = pePart) then
    begin
      for NameIndex := 0 to High(Simple^.Languages) do
        if not FAdapter.HasPart(Element, Simple^.Languages[NameIndex]) then
          Exit(False);
      Exit(True);
    end;
  end;
end;

function TCssSelectorMatcher.MatchPseudoClass(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  States: TCssElementStates;
  Sibling: TCssElement;
begin
  case Simple.PseudoClass of
    pcHost, pcHostContext: Result := False;
    pcState: Result := FAdapter.HasCustomState(Element, Simple.Value);
    pcIs, pcWhere: Result := MatchesList(Simple.Arguments, Element);
    pcNot: Result := not MatchesList(Simple.Arguments, Element);
    pcHas: Result := MatchHas(Simple, Element);
    pcRoot: Result := FAdapter.IsRoot(Element);
    pcScope:
      if FScope <> nil then
        Result := Element = FScope
      else
        Result := FAdapter.IsRoot(Element);
    pcEmpty: Result := FAdapter.IsEmpty(Element);
    pcFirstChild: Result := FAdapter.PreviousSibling(Element) = nil;
    pcLastChild: Result := FAdapter.NextSibling(Element) = nil;
    pcOnlyChild: Result := (FAdapter.PreviousSibling(Element) = nil) and (FAdapter.NextSibling(Element) = nil);
    pcFirstOfType, pcLastOfType, pcOnlyOfType:
      begin
        Result := True;
        if Simple.PseudoClass <> pcLastOfType then
        begin
          Sibling := FAdapter.PreviousSibling(Element);
          while Sibling <> nil do
          begin
            if SameName(Sibling, Element) then
              Exit(False);
            Sibling := FAdapter.PreviousSibling(Sibling);
          end;
        end;
        if Simple.PseudoClass <> pcFirstOfType then
        begin
          Sibling := FAdapter.NextSibling(Element);
          while Sibling <> nil do
          begin
            if SameName(Sibling, Element) then
              Exit(False);
            Sibling := FAdapter.NextSibling(Sibling);
          end;
        end;
      end;
    pcNthChild, pcNthLastChild, pcNthOfType, pcNthLastOfType: Result := MatchNth(Simple, Element);
    pcLang: Result := MatchLanguage(Simple, Element);
    pcDir:
      if Simple.Value = 'rtl' then
        Result := FAdapter.Direction(Element) = dirRightToLeft
      else
        Result := FAdapter.Direction(Element) = dirLeftToRight;
  else
    begin
      States := FAdapter.States(Element);
      case Simple.PseudoClass of
        pcHover: Result := esHover in States;
        pcActive: Result := esActive in States;
        pcFocus: Result := esFocus in States;
        pcFocusVisible: Result := esFocusVisible in States;
        pcFocusWithin: Result := esFocusWithin in States;
        pcLink: Result := esLink in States;
        pcVisited: Result := esVisited in States;
        pcAnyLink: Result := (esLink in States) or (esVisited in States);
        pcTarget: Result := esTarget in States;
        pcTargetWithin: Result := esTargetWithin in States;
        pcChecked: Result := esChecked in States;
        pcIndeterminate: Result := esIndeterminate in States;
        pcDisabled: Result := esDisabled in States;
        pcEnabled: Result := esEnabled in States;
        pcRequired: Result := esRequired in States;
        pcOptional: Result := esOptional in States;
        pcReadOnly: Result := esReadOnly in States;
        pcReadWrite: Result := esReadWrite in States;
        pcPlaceholderShown: Result := esPlaceholderShown in States;
        pcDefault: Result := esDefault in States;
        pcValid: Result := esValid in States;
        pcInvalid: Result := esInvalid in States;
        pcInRange: Result := esInRange in States;
        pcOutOfRange: Result := esOutOfRange in States;
        pcAutofill: Result := esAutofill in States;
        pcUserValid: Result := esUserValid in States;
        pcUserInvalid: Result := esUserInvalid in States;
        pcOpen: Result := esOpen in States;
        pcModal: Result := esModal in States;
        pcPopoverOpen: Result := esPopoverOpen in States;
        pcFullscreen: Result := esFullscreen in States;
        pcPlaying: Result := esPlaying in States;
        pcPaused: Result := esPaused in States;
        pcDefined: Result := esDefined in States;
      else
        Result := False;
      end;
    end;
  end;
end;

function NamespaceMatches(const Simple: TCssSimpleSelector; Adapter: TCssElementAdapter; Element: TCssElement): Boolean;
begin
  case Simple.NamespaceKind of
    nkDefault: Result := (Simple.Namespace = NoAtom) or (Adapter.NamespaceUri(Element) = Simple.Namespace);
    nkAny: Result := True;
    nkNone: Result := Adapter.NamespaceUri(Element) = NoAtom;
  else
    Result := Adapter.NamespaceUri(Element) = Simple.Namespace;
  end;
end;

function TCssSelectorMatcher.MatchSimple(const Simple: TCssSimpleSelector; Element: TCssElement): Boolean;
var
  Index, ClassCount: Integer;
  Wanted: TCssAtom;
  ClassList: PCssAtom;
begin
  if (FShadowHost <> nil) and (Element = FShadowHost) then
    Exit(MatchFeaturelessHost(Simple, Element));
  case Simple.Kind of
    skType:
      begin
        if FAdapter.IsHtmlElementInHtmlDocument(Element) then
          Result := FAdapter.LocalName(Element) = Simple.LowerName
        else
          Result := FAdapter.LocalName(Element) = Simple.Name;
        if Result then
          Result := NamespaceMatches(Simple, FAdapter, Element);
      end;
    skUniversal: Result := NamespaceMatches(Simple, FAdapter, Element);
    skId:
      if FQuirks then
        Result := LowercaseAtom(FAdapter.Id(Element)) = Simple.LowerName
      else
        Result := FAdapter.Id(Element) = Simple.Name;
    skClass:
      begin
        Result := False;
        if FQuirks then
          Wanted := Simple.LowerName
        else
          Wanted := Simple.Name;
        ClassList := FAdapter.Classes(Element, ClassCount);
        if FQuirks then
        begin
          for Index := 0 to ClassCount - 1 do
            if LowercaseAtom(ClassList[Index]) = Wanted then
              Exit(True);
        end
        else
          for Index := 0 to ClassCount - 1 do
            if ClassList[Index] = Wanted then
              Exit(True);
      end;
    skAttribute: Result := MatchAttribute(Simple, Element);
    skPseudoClass: Result := MatchPseudoClass(Simple, Element);
    skPseudoElement: Result := True;
    skNesting:
      if Simple.NestingParent = nil then
        Result := FAdapter.IsRoot(Element)
      else
        Result := MatchesList(Simple.NestingParent, Element);
    skHasAnchor: Result := (FAnchorCount > 0) and (FAnchors[FAnchorCount - 1] = Element);
  else
    Result := False;
  end;
end;

function TCssSelectorMatcher.MatchCompound(const Compound: TCssCompoundSelector; Element: TCssElement): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Compound.Simples) do
    if not MatchSimple(Compound.Simples[Index], Element) then
      Exit(False);
  Result := True;
end;

function MatchFrom(Matcher: TCssSelectorMatcher; Selector: TCssComplexSelector; Index: Integer;
  Element: TCssElement): TMatchResult;
var
  Combinator: TCssCombinator;
  Next: TCssElement;
  Adapter: TCssElementAdapter;
  CandidateNotFound, Outcome: TMatchResult;
begin
  if not Matcher.MatchCompound(Selector.Compounds[Index], Element) then
    Exit(mrRestartFromLaterSibling);
  if Index = High(Selector.Compounds) then
    Exit(mrMatched);
  Adapter := Matcher.Adapter;
  Combinator := Selector.Compounds[Index].Combinator;
  if Combinator in [cmNextSibling, cmSubsequentSibling] then
  begin
    CandidateNotFound := mrRestartFromDescendant;
    if Element = Matcher.FShadowHost then
      Next := nil
    else
      Next := Adapter.PreviousSibling(Element);
  end
  else
  begin
    CandidateNotFound := mrNotMatchedGlobally;
    Next := Matcher.TreeParent(Element);
  end;
  repeat
    if Next = nil then
      Exit(CandidateNotFound);
    Outcome := MatchFrom(Matcher, Selector, Index + 1, Next);
    if (Outcome in [mrMatched, mrNotMatchedGlobally]) or (Combinator = cmNextSibling) then
      Exit(Outcome);
    if Combinator = cmChild then
      Exit(mrRestartFromDescendant);
    if (Outcome = mrRestartFromDescendant) and (Combinator = cmSubsequentSibling) then
      Exit(Outcome);
    if Combinator = cmSubsequentSibling then
      Next := Adapter.PreviousSibling(Next)
    else
      Next := Matcher.TreeParent(Next);
  until False;
end;

function TCssSelectorMatcher.Matches(Selector: TCssComplexSelector; Element: TCssElement;
  PseudoElement: TCssPseudoElement): Boolean;
begin
  if (Element = nil) or (Length(Selector.Compounds) = 0) then
    Exit(False);
  if Selector.PseudoElement <> PseudoElement then
    Exit(False);
  if Selector.PseudoElement = peUnknownPrefixed then
    Exit(False);
  if not PassesFilter(Selector) then
    Exit(False);
  FShadowTrees := FAdapter.HasShadowTrees;
  Result := MatchFrom(Self, Selector, 0, Element) = mrMatched;
end;

function TCssSelectorMatcher.MatchesList(List: TCssSelectorList; Element: TCssElement): Boolean;
var
  Index: Integer;
  SavedFilter: TCssAncestorFilter;
begin
  Result := False;
  if List = nil then
    Exit;
  { Nested lists may be matched against other elements: no filter. }
  SavedFilter := FFilter;
  FFilter := nil;
  try
    for Index := 0 to High(List.Items) do
      if Matches(List.Items[Index], Element) then
        Exit(True);
  finally
    FFilter := SavedFilter;
  end;
end;

procedure InitializeAttributeList;
const
  Names: array[0..44] of string = ('accept', 'accept-charset', 'align', 'alink', 'axis', 'bgcolor',
    'charset', 'checked', 'clear', 'codetype', 'color', 'compact', 'declare', 'defer', 'dir',
    'direction', 'disabled', 'enctype', 'face', 'frame', 'hreflang', 'http-equiv', 'lang',
    'language', 'link', 'media', 'method', 'multiple', 'nohref', 'noresize', 'noshade', 'nowrap',
    'readonly', 'rel', 'rev', 'rules', 'scope', 'scrolling', 'selected', 'shape', 'target',
    'text', 'type', 'valign', 'valuetype');
var
  Index: Integer;
begin
  SetLength(CaseInsensitiveValueAttributes, Length(Names) + 1);
  for Index := 0 to High(Names) do
    CaseInsensitiveValueAttributes[Index] := InternAtom(Names[Index]);
  CaseInsensitiveValueAttributes[High(CaseInsensitiveValueAttributes)] := InternAtom('vlink');
end;

initialization
  InitializeAttributeList;
end.
