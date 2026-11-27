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
  The style engine: what a host (libweb) uses.

  It keeps the style sheets in effect (the user agent sheet for HTML
  and its quirks mode additions, user sheets and the document's author
  sheets), the media environment, the rule index built from them, the
  struct cache and the style sharing cache, and computes the style of
  an element (and of its pseudo-elements) through the element adapter.

  StyleTree styles a whole subtree top-down, keeping the ancestor bloom
  filter. Elements whose parents share a style and that match the same
  rules (with no style attribute) share one computed style without
  cascading again: the sharing cache is keyed by the parent's style and
  the matched rules.
}
unit Css.StyleEngine;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Selectors, Css.Declarations, Css.Stylesheets, Css.MediaQueries, Css.ElementAdapter,
  Css.BloomFilter, Css.SelectorMatching, Css.RuleIndex, Css.Cascade, Css.StyleStructs, Css.ComputedStyle,
  Css.StyleCompute, Css.PropertyIds, Css.StateInvalidation, Css.NameInvalidation, Css.TreeScopes;

type
  TCssStyleStatistics = record
    ElementsStyled: Int64;
    SharedStyles: Int64;
    StylesComputed: Int64;
    SelectorsTested: Int64;
    SelectorsMatched: Int64;
    FilterRejections: Int64;
  end;

  TCssMemoryReport = record
    Elements: Int64;
    UniqueStyles: Integer;
    LiveStructs: Integer;
    StructBytes: Int64;
    StyleBytes: Int64;
    { (style objects + structs) / elements }
    BytesPerElement: Double;
    { elements per distinct computed style }
    StyleSharingRatio: Double;
    { struct pointers held by distinct styles per distinct struct }
    StructSharingRatio: Double;
    { what one style would take with nothing shared }
    UnsharedBytesPerStyle: Int64;
  end;

  { Called for each element StyleTree styles; Style stays valid while
    the engine lives unless the visitor keeps a reference (AddRef). }
  TCssStyleVisitor = procedure(Element: TCssElement; Style: TCssComputedStyle; Data: Pointer);

  TCssStyleEngine = class
  private
    FAdapter: TCssElementAdapter;
    FMatcher: TCssSelectorMatcher;
    FFilter: TCssAncestorFilter;
    FIndex: TCssRuleIndex;
    FStateDependencies: TCssStateDependencies;
    FNameDependencies: TCssNameDependencies;
    FStructCache: TCssStructCache;
    FComputer: TCssStyleComputer;
    FSheets: array of TCssStyleSheet;
    FUseUserAgentSheet: Boolean;
    FEnvironment: TCssMediaEnvironment;
    FDirty: Boolean;
    FCandidates: TCssIntegerArray;
    FItems: TCssCascadeItemArray;
    FSignature: TCssIntegerArray;
    FRootStyle: TCssComputedStyle;
    FStatistics: TCssStyleStatistics;
    { The sharing cache. }
    FShareKeys: array of LongWord;
    FShareParents: array of TCssComputedStyle;
    FShareSignatures: array of TCssIntegerArray;
    FShareFlags: array of LongWord;
    FShareStyles: array of TCssComputedStyle;
    FShareCount: Integer;
    { The candidates of pseudo-element rules seen while resolving the
      style of FPseudoOwner (entry indexes and their pseudo-elements), for
      its pseudo-elements' styles right after. }
    FPseudoOwner: TCssElement;
    FPseudoEntries: TCssIntegerArray;
    FPseudoKinds: array of TCssPseudoElement;
    FPseudoCount: Integer;
    procedure EnsureIndex;
    procedure RecordPseudoCandidate(EntryIndex: Integer; PseudoElement: TCssPseudoElement);
    procedure RecordedPseudoCandidates(PseudoElement: TCssPseudoElement; out Count: Integer);
    procedure ClearSharing;
    function FindShared(Hash: LongWord; Parent: TCssComputedStyle; Flags: LongWord; Count: Integer): TCssComputedStyle;
    procedure AddShared(Hash: LongWord; Parent: TCssComputedStyle; Flags: LongWord; Count: Integer;
      Style: TCssComputedStyle);
    function Resolve(Element: TCssElement; Parent: TCssComputedStyle; PseudoElement: TCssPseudoElement;
      RequireMatch, AfterElement: Boolean): TCssComputedStyle;
    procedure MatchScopeRules(Index: TCssRuleIndex; Element: TCssElement; PseudoElement: TCssPseudoElement;
      ShadowHost: TCssElement; Depth: Integer; Target: TCssElement; AuthorOnly: Boolean; var ItemCount: Integer);
    procedure MatchShadowRules(Element: TCssElement; PseudoElement: TCssPseudoElement; ElementScope: TCssTreeScope;
      var ItemCount: Integer);
    procedure VisitSubtree(Element: TCssElement; Parent: TCssComputedStyle; Visitor: TCssStyleVisitor;
      Data: Pointer);
  public
    constructor Create(Adapter: TCssElementAdapter; UseUserAgentSheet: Boolean = True);
    destructor Destroy; override;
    { Sheets stay the host's; the engine reads them until removed. }
    procedure AddStyleSheet(Sheet: TCssStyleSheet);
    procedure RemoveStyleSheet(Sheet: TCssStyleSheet);
    { Style sheets or rules changed: rebuild before the next style. }
    procedure Invalidate;
    { Rule was just appended to Sheet: indexed at once when Sheet is the
      last sheet in effect (else False: Invalidate). The host restyles. }
    function AppendRule(Sheet: TCssStyleSheet; Rule: TCssRule): Boolean;
    { Builds the index now if it is out of date (after which the engine no
      longer refers to rules of sheets it was told were removed). }
    procedure Prepare;
    { The style one declaration block alone gives an element under
      Parent (a keyframe's values for an animation); a new reference. }
    function ComputeBlockStyle(Block: TCssDeclarationBlock; Parent: TCssComputedStyle): TCssComputedStyle;
    procedure SetEnvironment(const Environment: TCssMediaEnvironment);
    { The tree changed (elements moved, attributes or states changed):
      forget sibling positions and shared styles. }
    procedure TreeChanged;
    { The computed style of Element whose parent has ParentStyle (nil at
      the root). A new reference for the caller. }
    function ResolveStyle(Element: TCssElement; ParentStyle: TCssComputedStyle): TCssComputedStyle;
    { The style of a pseudo-element of Element (whose style is
      ElementStyle), or nil when no rule targets it. AfterElement: the
      caller resolved Element's style with ResolveStyle just before, with
      nothing changed since, so the pseudo-element rules seen then are
      the only candidates. }
    function ResolvePseudoStyle(Element: TCssElement; ElementStyle: TCssComputedStyle;
      PseudoElement: TCssPseudoElement; AfterElement: Boolean = False): TCssComputedStyle;
    { The style of an anonymous box under ParentStyle (inherited values
      from it, initial values for the rest); a new reference. }
    function AnonymousStyle(ParentStyle: TCssComputedStyle): TCssComputedStyle;
    { Styles Root and everything below it, top-down. }
    procedure StyleTree(Root: TCssElement; ParentStyle: TCssComputedStyle; Visitor: TCssStyleVisitor; Data: Pointer);
    { For hosts that walk the tree themselves: keep the ancestor filter
      in step (push an element before styling its children). }
    procedure PushAncestor(Element: TCssElement);
    procedure PopAncestor;
    procedure ResetAncestors;
    function MemoryReport(Elements: Int64; const Styles: array of TCssComputedStyle): TCssMemoryReport;
    function FindKeyframes(const Name: string): TCssKeyframesRule;
    property Statistics: TCssStyleStatistics read FStatistics;
    property Environment: TCssMediaEnvironment read FEnvironment;
    property Rules: TCssRuleIndex read FIndex;
    { What must be styled again when Element's states Changed (the
      selectors using them decide; Css.StateInvalidation). }
    function StateInvalidation(Element: TCssElement; Changed: TCssElementStates): TCssStateInvalidation;
    { What must be styled again when an element's class, id or attribute
      Name (Kind says which) is added, removed or changed (the selectors
      naming it decide; Css.NameInvalidation). }
    function NameInvalidation(Kind: TCssSelectorNameKind; Name: TCssAtom): TCssNameInvalidation;
    property Matcher: TCssSelectorMatcher read FMatcher;
    property StructCache: TCssStructCache read FStructCache;
  end;

implementation

uses
  SysUtils, Css.Properties, Css.Keywords, Css.ComputedValues, Css.UserAgentStyleSheet;

const
  SharingCacheLimit = 4096;
  FlagRoot = 1;
  FlagPseudoShift = 8;

constructor TCssStyleEngine.Create(Adapter: TCssElementAdapter; UseUserAgentSheet: Boolean);
begin
  inherited Create;
  FAdapter := Adapter;
  FMatcher := TCssSelectorMatcher.Create(Adapter);
  FFilter := TCssAncestorFilter.Create;
  FIndex := TCssRuleIndex.Create;
  FStateDependencies := TCssStateDependencies.Create;
  FNameDependencies := TCssNameDependencies.Create;
  FStructCache := TCssStructCache.Create;
  FUseUserAgentSheet := UseUserAgentSheet;
  FEnvironment := DefaultMediaEnvironment;
  FDirty := True;
end;

destructor TCssStyleEngine.Destroy;
begin
  ClearSharing;
  FRootStyle.Release;
  FComputer.Free;
  FStructCache.Free;
  FIndex.Free;
  FStateDependencies.Free;
  FNameDependencies.Free;
  FFilter.Free;
  FMatcher.Free;
  inherited Destroy;
end;

procedure TCssStyleEngine.AddStyleSheet(Sheet: TCssStyleSheet);
begin
  SetLength(FSheets, Length(FSheets) + 1);
  FSheets[High(FSheets)] := Sheet;
  Invalidate;
end;

procedure TCssStyleEngine.RemoveStyleSheet(Sheet: TCssStyleSheet);
var
  Index, Other: Integer;
begin
  for Index := 0 to High(FSheets) do
    if FSheets[Index] = Sheet then
    begin
      for Other := Index to High(FSheets) - 1 do
        FSheets[Other] := FSheets[Other + 1];
      SetLength(FSheets, Length(FSheets) - 1);
      Invalidate;
      Exit;
    end;
end;

procedure TCssStyleEngine.Invalidate;
begin
  FDirty := True;
  ClearSharing;
end;

procedure TCssStyleEngine.SetEnvironment(const Environment: TCssMediaEnvironment);
begin
  FEnvironment := Environment;
  Invalidate;
end;

procedure TCssStyleEngine.TreeChanged;
begin
  FMatcher.ResetCaches;
  FMatcher.Refresh;
  ClearSharing;
end;

procedure TCssStyleEngine.EnsureIndex;
var
  Sheets: array of TCssStyleSheet;
  Index, Count: Integer;
begin
  if not FDirty then
    Exit;
  Sheets := nil;
  SetLength(Sheets, Length(FSheets) + 2);
  Count := 0;
  if FUseUserAgentSheet then
  begin
    Sheets[Count] := UserAgentStyleSheet;
    Inc(Count);
    if FAdapter.QuirksMode = qmQuirks then
    begin
      Sheets[Count] := QuirksModeStyleSheet;
      Inc(Count);
    end;
  end;
  for Index := 0 to High(FSheets) do
  begin
    Sheets[Count] := FSheets[Index];
    Inc(Count);
  end;
  SetLength(Sheets, Count);
  FIndex.Build(Sheets, FEnvironment);
  FStateDependencies.Build(FIndex);
  FNameDependencies.Build(FIndex);
  ClearSharing;
  FreeAndNil(FComputer);
  FComputer := TCssStyleComputer.Create(FStructCache, FIndex, FEnvironment);
  FMatcher.Refresh;
  FDirty := False;
end;

procedure TCssStyleEngine.Prepare;
begin
  EnsureIndex;
end;

function TCssStyleEngine.AppendRule(Sheet: TCssStyleSheet; Rule: TCssRule): Boolean;
var
  First: Integer;
begin
  Result := False;
  if FDirty or (Length(FSheets) = 0) or (FSheets[High(FSheets)] <> Sheet) or (Sheet.Origin <> coAuthor) or
    Sheet.Disabled or (Rule.Parent <> nil) then
    Exit;
  if (Sheet.Media <> nil) and not Sheet.Media.Matches(FEnvironment) then
    Exit;
  if (Length(Sheet.Rules) = 0) or (Sheet.Rules[High(Sheet.Rules)] <> Rule) then
    Exit;
  First := FIndex.Count;
  if not FIndex.AppendAuthorRule(Rule) then
    Exit;
  FStateDependencies.Build(FIndex);
  FNameDependencies.AddEntries(FIndex, First);
  ClearSharing;
  FMatcher.Refresh;
  Result := True;
end;

{ ---- the sharing cache ---- }

procedure TCssStyleEngine.ClearSharing;
var
  Index: Integer;
begin
  for Index := 0 to High(FShareStyles) do
    if FShareStyles[Index] <> nil then
    begin
      FShareStyles[Index].Release;
      FShareParents[Index].Release;
    end;
  FShareKeys := nil;
  FShareParents := nil;
  FShareSignatures := nil;
  FShareFlags := nil;
  FShareStyles := nil;
  FShareCount := 0;
  { Entry indexes and the tree may change too. }
  FPseudoOwner := nil;
end;

function TCssStyleEngine.FindShared(Hash: LongWord; Parent: TCssComputedStyle; Flags: LongWord;
  Count: Integer): TCssComputedStyle;
var
  Slot, Mask: LongWord;
  Index, Item: Integer;
  Same: Boolean;
begin
  Result := nil;
  if Length(FShareKeys) = 0 then
    Exit;
  Mask := LongWord(Length(FShareKeys) - 1);
  Slot := Hash and Mask;
  while FShareStyles[Slot] <> nil do
  begin
    Index := Slot;
    if (FShareKeys[Index] = Hash) and (FShareParents[Index] = Parent) and (FShareFlags[Index] = Flags) and
      (Length(FShareSignatures[Index]) = Count) then
    begin
      Same := True;
      for Item := 0 to Count - 1 do
        if FShareSignatures[Index][Item] <> FSignature[Item] then
        begin
          Same := False;
          Break;
        end;
      if Same then
        Exit(FShareStyles[Index]);
    end;
    Slot := (Slot + 1) and Mask;
  end;
end;

procedure TCssStyleEngine.AddShared(Hash: LongWord; Parent: TCssComputedStyle; Flags: LongWord; Count: Integer;
  Style: TCssComputedStyle);
var
  Slot, Mask: LongWord;
  Item: Integer;
begin
  if FShareCount >= SharingCacheLimit then
    ClearSharing;
  if Length(FShareKeys) = 0 then
  begin
    SetLength(FShareKeys, SharingCacheLimit * 2);
    SetLength(FShareParents, SharingCacheLimit * 2);
    SetLength(FShareSignatures, SharingCacheLimit * 2);
    SetLength(FShareFlags, SharingCacheLimit * 2);
    SetLength(FShareStyles, SharingCacheLimit * 2);
  end;
  Mask := LongWord(Length(FShareKeys) - 1);
  Slot := Hash and Mask;
  while FShareStyles[Slot] <> nil do
    Slot := (Slot + 1) and Mask;
  FShareKeys[Slot] := Hash;
  FShareParents[Slot] := Parent.AddRef;
  FShareFlags[Slot] := Flags;
  SetLength(FShareSignatures[Slot], Count);
  for Item := 0 to Count - 1 do
    FShareSignatures[Slot][Item] := FSignature[Item];
  FShareStyles[Slot] := Style.AddRef;
  Inc(FShareCount);
end;

{ ---- resolving ---- }

procedure SortIntegers(var Values: TCssIntegerArray; Count: Integer);
var
  Index, Other, Value: Integer;
begin
  for Index := 1 to Count - 1 do
  begin
    Value := Values[Index];
    Other := Index - 1;
    while (Other >= 0) and (Values[Other] > Value) do
    begin
      Values[Other + 1] := Values[Other];
      Dec(Other);
    end;
    Values[Other + 1] := Value;
  end;
end;

function WritingModeOfStyle(Style: TCssComputedStyle): TCssWritingMode;
begin
  if Style = nil then
    Exit(wmHorizontalTb);
  case Style.Keyword(cpWritingMode) of
    kwVerticalRl: Result := wmVerticalRl;
    kwVerticalLr: Result := wmVerticalLr;
    kwSidewaysRl: Result := wmSidewaysRl;
    kwSidewaysLr: Result := wmSidewaysLr;
  else
    Result := wmHorizontalTb;
  end;
end;

function TCssStyleEngine.ComputeBlockStyle(Block: TCssDeclarationBlock; Parent: TCssComputedStyle): TCssComputedStyle;
var
  Items: TCssCascadeItemArray;
  ItemCount: Integer;
  Cascaded: TCssCascadedValues;
begin
  EnsureIndex;
  Items := nil;
  ItemCount := 0;
  AddCascadeBlock(Items, ItemCount, Block, coAuthor, False, 0, 0, 0);
  RunCascade(Items, ItemCount, WritingModeOfStyle(Parent), (Parent <> nil) and (Parent.Keyword(cpDirection) = kwRtl),
    Cascaded);
  Result := FComputer.Compute(Cascaded, Parent, FRootStyle, False);
end;

procedure TCssStyleEngine.RecordPseudoCandidate(EntryIndex: Integer; PseudoElement: TCssPseudoElement);
begin
  if FPseudoCount >= Length(FPseudoEntries) then
  begin
    SetLength(FPseudoEntries, FPseudoCount * 2 + 32);
    SetLength(FPseudoKinds, Length(FPseudoEntries));
  end;
  FPseudoEntries[FPseudoCount] := EntryIndex;
  FPseudoKinds[FPseudoCount] := PseudoElement;
  Inc(FPseudoCount);
end;

{ The recorded candidates for PseudoElement into FCandidates. }
procedure TCssStyleEngine.RecordedPseudoCandidates(PseudoElement: TCssPseudoElement; out Count: Integer);
var
  Index: Integer;
begin
  Count := 0;
  if Length(FCandidates) < FPseudoCount then
    SetLength(FCandidates, FPseudoCount);
  for Index := 0 to FPseudoCount - 1 do
    if FPseudoKinds[Index] = PseudoElement then
    begin
      FCandidates[Count] := FPseudoEntries[Index];
      Inc(Count);
    end;
end;

{ The rules of one index that match Element (as the originating element
  of PseudoElement) with ShadowHost featureless, added at Depth. For
  ::slotted() and ::part() (PseudoElement peSlotted, pePart) Element is
  the slot or the host and Target the element styled. }
procedure TCssStyleEngine.MatchScopeRules(Index: TCssRuleIndex; Element: TCssElement; PseudoElement: TCssPseudoElement;
  ShadowHost: TCssElement; Depth: Integer; Target: TCssElement; AuthorOnly: Boolean; var ItemCount: Integer);
var
  CandidateCount, Position: Integer;
  Entry: PCssRuleEntry;
  SavedHost: TCssElement;
begin
  Index.Candidates(FAdapter, Element, FCandidates, CandidateCount);
  SavedHost := FMatcher.ShadowHost;
  FMatcher.ShadowHost := ShadowHost;
  try
    for Position := 0 to CandidateCount - 1 do
    begin
      Entry := Index.Entry(FCandidates[Position]);
      Inc(FStatistics.SelectorsTested);
      if Entry^.Selector.PseudoElement <> PseudoElement then
        Continue;
      if AuthorOnly and (Entry^.Origin <> coAuthor) then
        Continue;
      if not FMatcher.Matches(Entry^.Selector, Element, PseudoElement) then
        Continue;
      if (PseudoElement = peSlotted) and not FMatcher.SlottedArgumentMatches(Entry^.Selector, Target) then
        Continue;
      if (PseudoElement = pePart) and not FMatcher.PartNamesMatch(Entry^.Selector, Target) then
        Continue;
      Inc(FStatistics.SelectorsMatched);
      AddCascadeBlock(FItems, ItemCount, Entry^.Block, Entry^.Origin, False, Entry^.LayerRank,
        Entry^.Specificity, Entry^.Order, Depth);
    end;
  finally
    FMatcher.ShadowHost := SavedHost;
  end;
end;

{ The shadow tree rules for Element: its own scope's, its shadow root's
  :host rules, the ::slotted() rules of the slots it is assigned to and
  the outer tree's ::part() rules. }
procedure TCssStyleEngine.MatchShadowRules(Element: TCssElement; PseudoElement: TCssPseudoElement;
  ElementScope: TCssTreeScope; var ItemCount: Integer);
var
  HostScope, SlotScope, OuterScope: TCssTreeScope;
  Slot, Host: TCssElement;
  SavedFilter: TCssAncestorFilter;
begin
  if ElementScope <> nil then
    MatchScopeRules(ElementScope.Rules(FEnvironment), Element, PseudoElement, ElementScope.Host, ElementScope.Depth,
      nil, False, ItemCount);
  SavedFilter := FMatcher.Filter;
  FMatcher.Filter := nil;
  try
    HostScope := TCssTreeScope(FAdapter.ShadowScope(Element));
    if HostScope <> nil then
      MatchScopeRules(HostScope.Rules(FEnvironment), Element, PseudoElement, Element, HostScope.Depth, nil, False,
        ItemCount);
    if PseudoElement <> peNone then
      Exit;
    Slot := FAdapter.AssignedSlot(Element);
    while Slot <> nil do
    begin
      SlotScope := TCssTreeScope(FAdapter.TreeScope(Slot));
      if SlotScope <> nil then
        MatchScopeRules(SlotScope.Rules(FEnvironment), Slot, peSlotted, SlotScope.Host, SlotScope.Depth, Element,
          False, ItemCount);
      Slot := FAdapter.AssignedSlot(Slot);
    end;
    if ElementScope <> nil then
    begin
      Host := ElementScope.Host;
      OuterScope := TCssTreeScope(FAdapter.TreeScope(Host));
      if OuterScope <> nil then
        MatchScopeRules(OuterScope.Rules(FEnvironment), Host, pePart, OuterScope.Host, OuterScope.Depth, Element,
          False, ItemCount)
      else
        MatchScopeRules(FIndex, Host, pePart, nil, 0, Element, True, ItemCount);
    end;
  finally
    FMatcher.Filter := SavedFilter;
  end;
end;

function TCssStyleEngine.Resolve(Element: TCssElement; Parent: TCssComputedStyle; PseudoElement: TCssPseudoElement;
  RequireMatch, AfterElement: Boolean): TCssComputedStyle;
var
  CandidateCount, ItemCount, SignatureCount, Index: Integer;
  Entry: PCssRuleEntry;
  Inline, Hints: TCssDeclarationBlock;
  Shareable, IsRoot: Boolean;
  Hash, Flags: LongWord;
  Cascaded: TCssCascadedValues;
  ElementScope: TCssTreeScope;
begin
  EnsureIndex;
  ElementScope := TCssTreeScope(FAdapter.TreeScope(Element));
  Inc(FStatistics.ElementsStyled);
  IsRoot := (PseudoElement = peNone) and FAdapter.IsRoot(Element);
  { The ancestor filter is good only while it holds this element's
    ancestors (its pseudo-elements' selectors match on it too). }
  if (FFilter.Depth > 0) and (FFilter.Top = FAdapter.Parent(Element)) then
    FMatcher.Filter := FFilter
  else if (FFilter.Depth = 0) and (FAdapter.Parent(Element) = nil) then
    FMatcher.Filter := FFilter
  else
    FMatcher.Filter := nil;
  { An element's own pass notes its pseudo-element candidates; a pass for
    one of its pseudo-elements right after takes them from there. }
  if (PseudoElement <> peNone) and AfterElement and (FPseudoOwner = Element) then
    RecordedPseudoCandidates(PseudoElement, CandidateCount)
  else
    FIndex.Candidates(FAdapter, Element, FCandidates, CandidateCount);
  if PseudoElement = peNone then
  begin
    FPseudoOwner := Element;
    FPseudoCount := 0;
  end
  else if FPseudoOwner <> Element then
    FPseudoOwner := nil;
  ItemCount := 0;
  SignatureCount := 0;
  Shareable := True;
  if Length(FSignature) < CandidateCount + 2 then
    SetLength(FSignature, CandidateCount + 2);
  for Index := 0 to CandidateCount - 1 do
  begin
    Entry := FIndex.Entry(FCandidates[Index]);
    Inc(FStatistics.SelectorsTested);
    if Entry^.Selector.PseudoElement <> PseudoElement then
    begin
      if PseudoElement = peNone then
        RecordPseudoCandidate(FCandidates[Index], Entry^.Selector.PseudoElement);
      Continue;
    end;
    { The document's author rules do not reach into shadow trees. }
    if (ElementScope <> nil) and (Entry^.Origin = coAuthor) then
      Continue;
    if not FMatcher.PassesFilter(Entry^.Selector) then
    begin
      Inc(FStatistics.FilterRejections);
      Continue;
    end;
    if not FMatcher.Matches(Entry^.Selector, Element, PseudoElement) then
      Continue;
    Inc(FStatistics.SelectorsMatched);
    AddCascadeBlock(FItems, ItemCount, Entry^.Block, Entry^.Origin, False, Entry^.LayerRank,
      Entry^.Specificity, Entry^.Order);
    FSignature[SignatureCount] := FCandidates[Index];
    Inc(SignatureCount);
    if Entry^.Block.UsesAttributes then
      Shareable := False;
  end;
  if (ElementScope <> nil) or (FAdapter.ShadowScope(Element) <> nil) or (FAdapter.AssignedSlot(Element) <> nil) then
  begin
    Shareable := False;
    { The shadow trees' rules are not in the index's candidates. }
    FPseudoOwner := nil;
    MatchShadowRules(Element, PseudoElement, ElementScope, ItemCount);
  end;
  FMatcher.Filter := nil;
  if RequireMatch and (ItemCount = 0) then
    Exit(nil);
  Inline := nil;
  Hints := nil;
  if PseudoElement = peNone then
  begin
    Hints := FAdapter.PresentationalHints(Element);
    Inline := FAdapter.StyleAttribute(Element);
  end;
  if Hints <> nil then
  begin
    AddCascadeBlock(FItems, ItemCount, Hints, coAuthor, False, 0, 0, -1);
    Shareable := False;
  end;
  if Inline <> nil then
  begin
    AddCascadeBlock(FItems, ItemCount, Inline, coAuthor, True, High(Word), 0, High(LongInt));
    Shareable := False;
  end;
  SortIntegers(FSignature, SignatureCount);
  Flags := LongWord(Ord(PseudoElement)) shl FlagPseudoShift;
  if IsRoot then
    Flags := Flags or FlagRoot;
  if Parent <> nil then
    Hash := LongWord((QWord(Parent.Serial) * 2654435761) and $FFFFFFFF) xor Flags
  else
    Hash := Flags;
  for Index := 0 to SignatureCount - 1 do
    Hash := LongWord((QWord(Hash xor LongWord(FSignature[Index])) * 16777619) and $FFFFFFFF);
  if Shareable then
  begin
    Result := FindShared(Hash, Parent, Flags, SignatureCount);
    if Result <> nil then
    begin
      Inc(FStatistics.SharedStyles);
      Exit(Result.AddRef);
    end;
  end;
  RunCascade(FItems, ItemCount, WritingModeOfStyle(Parent),
    (Parent <> nil) and (Parent.Keyword(cpDirection) = kwRtl), Cascaded);
  if IsRoot then
    Result := FComputer.Compute(Cascaded, Parent, nil, True)
  else
    Result := FComputer.Compute(Cascaded, Parent, FRootStyle, False);
  Result.PseudoElement := PseudoElement;
  Inc(FStatistics.StylesComputed);
  if IsRoot then
  begin
    FRootStyle.Release;
    FRootStyle := Result.AddRef;
  end;
  if Shareable then
    AddShared(Hash, Parent, Flags, SignatureCount, Result);
end;

function TCssStyleEngine.ResolveStyle(Element: TCssElement; ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  Result := Resolve(Element, ParentStyle, peNone, False, False);
end;

function TCssStyleEngine.ResolvePseudoStyle(Element: TCssElement; ElementStyle: TCssComputedStyle;
  PseudoElement: TCssPseudoElement; AfterElement: Boolean): TCssComputedStyle;
begin
  Result := Resolve(Element, ElementStyle, PseudoElement, True, AfterElement);
end;

function TCssStyleEngine.AnonymousStyle(ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  EnsureIndex;
  Result := FComputer.AnonymousStyle(ParentStyle);
end;

function TCssStyleEngine.StateInvalidation(Element: TCssElement; Changed: TCssElementStates): TCssStateInvalidation;
begin
  EnsureIndex;
  Result := FStateDependencies.Invalidation(FAdapter, Element, Changed);
end;

function TCssStyleEngine.NameInvalidation(Kind: TCssSelectorNameKind; Name: TCssAtom): TCssNameInvalidation;
begin
  EnsureIndex;
  Result := FNameDependencies.Invalidation(Kind, Name);
end;

procedure TCssStyleEngine.PushAncestor(Element: TCssElement);
begin
  FFilter.Push(FAdapter, Element);
end;

procedure TCssStyleEngine.PopAncestor;
begin
  FFilter.Pop;
end;

procedure TCssStyleEngine.ResetAncestors;
begin
  FFilter.Clear;
end;

procedure TCssStyleEngine.VisitSubtree(Element: TCssElement; Parent: TCssComputedStyle; Visitor: TCssStyleVisitor;
  Data: Pointer);
var
  Style: TCssComputedStyle;
  Child: TCssElement;
begin
  Style := ResolveStyle(Element, Parent);
  try
    Visitor(Element, Style, Data);
    Child := FAdapter.FirstChild(Element);
    if Child = nil then
      Exit;
    FFilter.Push(FAdapter, Element);
    try
      while Child <> nil do
      begin
        VisitSubtree(Child, Style, Visitor, Data);
        Child := FAdapter.NextSibling(Child);
      end;
    finally
      FFilter.Pop;
    end;
  finally
    Style.Release;
  end;
end;

procedure TCssStyleEngine.StyleTree(Root: TCssElement; ParentStyle: TCssComputedStyle; Visitor: TCssStyleVisitor;
  Data: Pointer);
begin
  EnsureIndex;
  FFilter.SetUpFor(FAdapter, Root);
  VisitSubtree(Root, ParentStyle, Visitor, Data);
  FFilter.Clear;
end;

function TCssStyleEngine.FindKeyframes(const Name: string): TCssKeyframesRule;
begin
  EnsureIndex;
  Result := FIndex.FindKeyframes(Name);
end;

function TCssStyleEngine.MemoryReport(Elements: Int64; const Styles: array of TCssComputedStyle): TCssMemoryReport;
var
  Distinct: array of TCssComputedStyle;
  Structs: array of PCssStyleStruct;
  Index, Other, StructReferences: Integer;
  Group: TCssStructGroup;
  Found: Boolean;
begin
  Result := Default(TCssMemoryReport);
  Result.Elements := Elements;
  Distinct := nil;
  Structs := nil;
  StructReferences := 0;
  for Index := 0 to High(Styles) do
  begin
    if Styles[Index] = nil then
      Continue;
    Found := False;
    for Other := 0 to High(Distinct) do
      if Distinct[Other] = Styles[Index] then
      begin
        Found := True;
        Break;
      end;
    if Found then
      Continue;
    SetLength(Distinct, Length(Distinct) + 1);
    Distinct[High(Distinct)] := Styles[Index];
    for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    begin
      Inc(StructReferences);
      Found := False;
      for Other := 0 to High(Structs) do
        if Structs[Other] = Styles[Index].Structs[Group] then
        begin
          Found := True;
          Break;
        end;
      if not Found then
      begin
        SetLength(Structs, Length(Structs) + 1);
        Structs[High(Structs)] := Styles[Index].Structs[Group];
      end;
    end;
  end;
  Result.UniqueStyles := Length(Distinct);
  Result.LiveStructs := Length(Structs);
  for Index := 0 to High(Structs) do
    Inc(Result.StructBytes, StructBytes(Structs[Index]^.Group));
  Result.StyleBytes := Int64(Length(Distinct)) * TCssComputedStyle.InstanceSize;
  if Elements > 0 then
    Result.BytesPerElement := (Result.StructBytes + Result.StyleBytes) / Elements;
  if Result.UniqueStyles > 0 then
    Result.StyleSharingRatio := Elements / Result.UniqueStyles;
  if Result.LiveStructs > 0 then
    Result.StructSharingRatio := StructReferences / Result.LiveStructs;
  Result.UnsharedBytesPerStyle := TCssComputedStyle.InstanceSize;
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    Inc(Result.UnsharedBytesPerStyle, StructBytes(Group));
end;

end.
