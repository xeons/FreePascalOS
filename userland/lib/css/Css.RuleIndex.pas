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
  The rule index: every style rule selector of the active style sheets
  that applies in the current environment (its @media, @supports and
  @import conditions hold), with its cascade data (origin, cascade
  layer rank, specificity, order of appearance), hashed by the subject
  compound's id, class or type, so an element is matched only against
  rules that could apply to it.

  Cascade layers are ordered as Cascade 5 says: by first declaration,
  a layer's sublayers before the layer's own rules, unlayered rules
  last. Each origin has its own layer order.

  The index also collects @keyframes, @font-face and @property rules.
}
unit Css.RuleIndex;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Selectors, Css.Declarations, Css.Stylesheets, Css.MediaQueries, Css.ElementAdapter,
  Css.PointerMaps;

type
  TCssRuleEntry = record
    Selector: TCssComplexSelector;
    Block: TCssDeclarationBlock;
    Specificity: LongWord;
    Order: LongInt;
    Origin: TCssOrigin;
    { Higher wins for normal declarations; unlayered is the highest. }
    LayerRank: Word;
    { Index of the layer node until ranks are known. }
    LayerNode: LongInt;
  end;
  PCssRuleEntry = ^TCssRuleEntry;

  TCssIntegerArray = array of LongInt;

  TCssRegisteredProperty = record
    Name: TCssAtom;
    Inherits: Boolean;
    Rule: TCssPropertyRule;
  end;

  TCssRuleIndex = class
  private
    FEntries: array of TCssRuleEntry;
    FCount: Integer;
    FBucketMaps: array[0..2] of TCssPointerMap;
    FBuckets: array of TCssIntegerArray;
    FBucketCounts: array of Integer;
    FUniversal: TCssIntegerArray;
    FUniversalCount: Integer;
    FOrder: LongInt;
    { Layer trees, one root per origin. }
    FLayerNames: array of string;
    FLayerParents: array of LongInt;
    FLayerChildren: array of TCssIntegerArray;
    FLayerRanks: array of Word;
    FLayerRoots: array[TCssOrigin] of LongInt;
    FAnonymousLayers: Integer;
    FKeyframes: array of TCssKeyframesRule;
    FFontFaces: array of TCssFontFaceRule;
    FRegistered: array of TCssRegisteredProperty;
    FEnvironment: TCssMediaEnvironment;
    procedure AddToBucket(Kind: Integer; Key: TCssAtom; Entry: LongInt);
    procedure AddEntry(Selector: TCssComplexSelector; Block: TCssDeclarationBlock; Specificity: LongWord;
      Origin: TCssOrigin; Layer: LongInt);
    function LayerChild(Parent: LongInt; const Name: string): LongInt;
    function DeclareLayer(Current: LongInt; const Path: string): LongInt;
    procedure AddRules(const Rules: TCssRuleArray; Origin: TCssOrigin; Layer: LongInt);
    procedure AddRule(Rule: TCssRule; Origin: TCssOrigin; Layer: LongInt);
    procedure AddSheet(Sheet: TCssStyleSheet; Origin: TCssOrigin; Layer: LongInt);
    procedure RankLayers;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { Rebuilds the index from Sheets (in cascade order within each
      origin) for Environment. }
    procedure Build(const Sheets: array of TCssStyleSheet; const Environment: TCssMediaEnvironment);
    { A rule just appended to the last author sheet (CSSOM insertRule at
      the end, as CSS-in-JS libraries do): its selectors join the index
      after every other entry. False (nothing added) for rules that
      could change the layer order or need the host (@import, @layer,
      @font-face, @property, @namespace): Build again then. }
    function AppendAuthorRule(Rule: TCssRule): Boolean;
    { The entries that might match Element: its id's, classes', type's
      buckets and the universal one. }
    procedure Candidates(Adapter: TCssElementAdapter; Element: TCssElement; var List: TCssIntegerArray;
      out Count: Integer);
    function Entry(Index: Integer): PCssRuleEntry; inline;
    function FindKeyframes(const Name: string): TCssKeyframesRule;
    function FontFaceCount: Integer;
    function FontFace(Index: Integer): TCssFontFaceRule;
    function FindRegisteredProperty(Name: TCssAtom; out Registered: TCssRegisteredProperty): Boolean;
    function HasRegisteredProperties: Boolean;
    function RegisteredCount: Integer;
    function RegisteredAt(Index: Integer): TCssRegisteredProperty;
    property Count: Integer read FCount;
    function Bytes: PtrUInt;
  end;

implementation

uses
  SysUtils, Css.SelectorParser;

const
  BucketId = 0;
  BucketClass = 1;
  BucketType = 2;
  NoLayer = -1;

constructor TCssRuleIndex.Create;
var
  Kind: Integer;
begin
  inherited Create;
  for Kind := 0 to 2 do
    FBucketMaps[Kind] := TCssPointerMap.Create;
end;

destructor TCssRuleIndex.Destroy;
var
  Kind: Integer;
begin
  for Kind := 0 to 2 do
    FBucketMaps[Kind].Free;
  inherited Destroy;
end;

procedure TCssRuleIndex.Clear;
var
  Kind: Integer;
  Origin: TCssOrigin;
begin
  FEntries := nil;
  FCount := 0;
  for Kind := 0 to 2 do
    FBucketMaps[Kind].Clear;
  FBuckets := nil;
  FBucketCounts := nil;
  FUniversal := nil;
  FUniversalCount := 0;
  FOrder := 0;
  FLayerNames := nil;
  FLayerParents := nil;
  FLayerChildren := nil;
  FLayerRanks := nil;
  FAnonymousLayers := 0;
  for Origin := Low(TCssOrigin) to High(TCssOrigin) do
    FLayerRoots[Origin] := NoLayer;
  FKeyframes := nil;
  FFontFaces := nil;
  FRegistered := nil;
end;

function TCssRuleIndex.Entry(Index: Integer): PCssRuleEntry;
begin
  Result := @FEntries[Index];
end;

procedure TCssRuleIndex.AddToBucket(Kind: Integer; Key: TCssAtom; Entry: LongInt);
var
  Bucket: PtrInt;
begin
  if not FBucketMaps[Kind].TryGet(Pointer(PtrUInt(Key)), Bucket) then
  begin
    Bucket := Length(FBuckets);
    SetLength(FBuckets, Bucket + 1);
    SetLength(FBucketCounts, Bucket + 1);
    FBucketCounts[Bucket] := 0;
    FBucketMaps[Kind].Put(Pointer(PtrUInt(Key)), Bucket);
  end;
  if FBucketCounts[Bucket] >= Length(FBuckets[Bucket]) then
    SetLength(FBuckets[Bucket], FBucketCounts[Bucket] * 2 + 2);
  FBuckets[Bucket][FBucketCounts[Bucket]] := Entry;
  Inc(FBucketCounts[Bucket]);
end;

procedure TCssRuleIndex.AddEntry(Selector: TCssComplexSelector; Block: TCssDeclarationBlock;
  Specificity: LongWord; Origin: TCssOrigin; Layer: LongInt);
var
  Index, SimpleIndex: Integer;
  Simple: ^TCssSimpleSelector;
  KeyKind: Integer;
  Key: TCssAtom;
begin
  if (Block = nil) or (Block.Count = 0) or (Length(Selector.Compounds) = 0) then
    Exit;
  if FCount >= Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 64);
  Index := FCount;
  Inc(FCount);
  FEntries[Index].Selector := Selector;
  FEntries[Index].Block := Block;
  FEntries[Index].Specificity := Specificity;
  FEntries[Index].Order := FOrder;
  Inc(FOrder);
  FEntries[Index].Origin := Origin;
  FEntries[Index].LayerNode := Layer;
  FEntries[Index].LayerRank := 0;
  { The most selective key of the subject compound. }
  KeyKind := -1;
  Key := NoAtom;
  for SimpleIndex := 0 to High(Selector.Compounds[0].Simples) do
  begin
    Simple := @Selector.Compounds[0].Simples[SimpleIndex];
    case Simple^.Kind of
      skId:
        begin
          KeyKind := BucketId;
          Key := Simple^.LowerName;
          Break;
        end;
      skClass:
        if KeyKind <> BucketClass then
        begin
          KeyKind := BucketClass;
          Key := Simple^.LowerName;
        end;
      skType:
        if KeyKind < 0 then
        begin
          KeyKind := BucketType;
          Key := Simple^.LowerName;
        end;
    end;
  end;
  if (KeyKind >= 0) and (Key <> NoAtom) then
    AddToBucket(KeyKind, Key, Index)
  else
  begin
    if FUniversalCount >= Length(FUniversal) then
      SetLength(FUniversal, FUniversalCount * 2 + 16);
    FUniversal[FUniversalCount] := Index;
    Inc(FUniversalCount);
  end;
end;

{ ---- layers ---- }

function TCssRuleIndex.LayerChild(Parent: LongInt; const Name: string): LongInt;
var
  Index: Integer;
begin
  for Index := 0 to High(FLayerChildren[Parent]) do
    if FLayerNames[FLayerChildren[Parent][Index]] = Name then
      Exit(FLayerChildren[Parent][Index]);
  Result := Length(FLayerNames);
  SetLength(FLayerNames, Result + 1);
  SetLength(FLayerParents, Result + 1);
  SetLength(FLayerChildren, Result + 1);
  FLayerNames[Result] := Name;
  FLayerParents[Result] := Parent;
  FLayerChildren[Result] := nil;
  SetLength(FLayerChildren[Parent], Length(FLayerChildren[Parent]) + 1);
  FLayerChildren[Parent][High(FLayerChildren[Parent])] := Result;
end;

{ The layer Path ("a.b", or '' for an anonymous one) names inside Current. }
function TCssRuleIndex.DeclareLayer(Current: LongInt; const Path: string): LongInt;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Result := Current;
  if Path = '' then
  begin
    Inc(FAnonymousLayers);
    Exit(LayerChild(Current, #0 + IntToStr(FAnonymousLayers)));
  end;
  Parts := Path.Split(['.']);
  for Index := 0 to High(Parts) do
    Result := LayerChild(Result, Parts[Index]);
end;

procedure TCssRuleIndex.RankLayers;
var
  Next: Word;

  procedure Visit(Node: LongInt);
  var
    Index: Integer;
  begin
    for Index := 0 to High(FLayerChildren[Node]) do
      Visit(FLayerChildren[Node][Index]);
    FLayerRanks[Node] := Next;
    Inc(Next);
  end;

var
  Origin: TCssOrigin;
  Index: Integer;
begin
  SetLength(FLayerRanks, Length(FLayerNames));
  for Origin := Low(TCssOrigin) to High(TCssOrigin) do
    if FLayerRoots[Origin] <> NoLayer then
    begin
      { Ranks start at 1: presentational hints sit below every layer. }
      Next := 1;
      Visit(FLayerRoots[Origin]);
    end;
  for Index := 0 to FCount - 1 do
    FEntries[Index].LayerRank := FLayerRanks[FEntries[Index].LayerNode];
end;

{ ---- walking the style sheets ---- }

procedure TCssRuleIndex.AddRules(const Rules: TCssRuleArray; Origin: TCssOrigin; Layer: LongInt);
var
  Index: Integer;
begin
  for Index := 0 to High(Rules) do
    AddRule(Rules[Index], Origin, Layer);
end;

procedure TCssRuleIndex.AddRule(Rule: TCssRule; Origin: TCssOrigin; Layer: LongInt);
var
  StyleRule, ParentRule: TCssStyleRule;
  Index: Integer;
  Statement: TCssLayerStatementRule;
  Import: TCssImportRule;
  Target: LongInt;
  Registered: TCssRegisteredProperty;
begin
  case Rule.Kind of
    rkStyle:
      begin
        StyleRule := TCssStyleRule(Rule);
        for Index := 0 to StyleRule.Selectors.Count - 1 do
          AddEntry(StyleRule.Selectors.Items[Index], StyleRule.Declarations,
            StyleRule.Selectors.Items[Index].Specificity, Origin, Layer);
        AddRules(StyleRule.Rules, Origin, Layer);
      end;
    rkNestedDeclarations:
      begin
        { Like a rule of just '&': the parent's selectors and specificity. }
        StyleRule := TCssStyleRule(Rule);
        ParentRule := StyleRule.ParentStyleRule;
        if ParentRule <> nil then
          for Index := 0 to ParentRule.Selectors.Count - 1 do
            AddEntry(ParentRule.Selectors.Items[Index], StyleRule.Declarations,
              ParentRule.Selectors.MaxSpecificity, Origin, Layer);
      end;
    rkMedia:
      if TCssMediaRule(Rule).Media.Matches(FEnvironment) then
        AddRules(TCssGroupingRule(Rule).Rules, Origin, Layer);
    rkSupports:
      if TCssSupportsRule(Rule).Matches then
        AddRules(TCssGroupingRule(Rule).Rules, Origin, Layer);
    rkContainer:
      { Container queries are not evaluated yet: no container matches. };
    rkLayerBlock:
      AddRules(TCssGroupingRule(Rule).Rules, Origin, DeclareLayer(Layer, TCssLayerBlockRule(Rule).Name));
    rkLayerStatement:
      begin
        Statement := TCssLayerStatementRule(Rule);
        for Index := 0 to High(Statement.Names) do
          DeclareLayer(Layer, Statement.Names[Index]);
      end;
    rkImport:
      begin
        Import := TCssImportRule(Rule);
        if (Import.StyleSheet <> nil) and Import.SupportsMatches and
          ((Import.Media = nil) or Import.Media.Matches(FEnvironment)) then
        begin
          Target := Layer;
          if Import.HasLayer then
            Target := DeclareLayer(Layer, Import.LayerName);
          AddSheet(Import.StyleSheet, Origin, Target);
        end;
      end;
    rkKeyframes:
      begin
        SetLength(FKeyframes, Length(FKeyframes) + 1);
        FKeyframes[High(FKeyframes)] := TCssKeyframesRule(Rule);
      end;
    rkFontFace:
      begin
        SetLength(FFontFaces, Length(FFontFaces) + 1);
        FFontFaces[High(FFontFaces)] := TCssFontFaceRule(Rule);
      end;
    rkProperty:
      begin
        Registered.Name := InternAtom(TCssPropertyRule(Rule).Name);
        Registered.Inherits := TCssPropertyRule(Rule).Inherits;
        Registered.Rule := TCssPropertyRule(Rule);
        SetLength(FRegistered, Length(FRegistered) + 1);
        FRegistered[High(FRegistered)] := Registered;
      end;
  end;
end;

procedure TCssRuleIndex.AddSheet(Sheet: TCssStyleSheet; Origin: TCssOrigin; Layer: LongInt);
begin
  if Sheet.Disabled then
    Exit;
  if (Sheet.Media <> nil) and not Sheet.Media.Matches(FEnvironment) then
    Exit;
  AddRules(Sheet.Rules, Origin, Layer);
end;

procedure TCssRuleIndex.Build(const Sheets: array of TCssStyleSheet; const Environment: TCssMediaEnvironment);
var
  Index: Integer;
  Origin: TCssOrigin;
begin
  Clear;
  FEnvironment := Environment;
  for Origin := Low(TCssOrigin) to High(TCssOrigin) do
  begin
    FLayerRoots[Origin] := Length(FLayerNames);
    SetLength(FLayerNames, FLayerRoots[Origin] + 1);
    SetLength(FLayerParents, Length(FLayerNames));
    SetLength(FLayerChildren, Length(FLayerNames));
    FLayerNames[FLayerRoots[Origin]] := '';
    FLayerParents[FLayerRoots[Origin]] := NoLayer;
    FLayerChildren[FLayerRoots[Origin]] := nil;
  end;
  for Origin := Low(TCssOrigin) to High(TCssOrigin) do
    for Index := 0 to High(Sheets) do
      if (Sheets[Index] <> nil) and (Sheets[Index].Origin = Origin) then
        AddSheet(Sheets[Index], Origin, FLayerRoots[Origin]);
  RankLayers;
end;

function AppendableRule(Rule: TCssRule): Boolean;
var
  Index: Integer;
begin
  case Rule.Kind of
    rkStyle, rkMedia, rkSupports:
      begin
        for Index := 0 to High(TCssGroupingRule(Rule).Rules) do
          if not AppendableRule(TCssGroupingRule(Rule).Rules[Index]) then
            Exit(False);
        Result := True;
      end;
    rkNestedDeclarations, rkKeyframes, rkContainer:
      Result := True;
  else
    Result := False;
  end;
end;

function TCssRuleIndex.AppendAuthorRule(Rule: TCssRule): Boolean;
var
  First, Index: Integer;
begin
  Result := False;
  if (FLayerRoots[coAuthor] = NoLayer) or (Length(FLayerRanks) = 0) or not AppendableRule(Rule) then
    Exit;
  First := FCount;
  AddRule(Rule, coAuthor, FLayerRoots[coAuthor]);
  for Index := First to FCount - 1 do
    FEntries[Index].LayerRank := FLayerRanks[FEntries[Index].LayerNode];
  Result := True;
end;

procedure TCssRuleIndex.Candidates(Adapter: TCssElementAdapter; Element: TCssElement; var List: TCssIntegerArray;
  out Count: Integer);

  procedure AddBucket(Kind: Integer; Key: TCssAtom);
  var
    Bucket: PtrInt;
    Index: Integer;
  begin
    if (Key = NoAtom) or not FBucketMaps[Kind].TryGet(Pointer(PtrUInt(Key)), Bucket) then
      Exit;
    if Count + FBucketCounts[Bucket] > Length(List) then
      SetLength(List, Count + FBucketCounts[Bucket] + 64);
    for Index := 0 to FBucketCounts[Bucket] - 1 do
    begin
      List[Count] := FBuckets[Bucket][Index];
      Inc(Count);
    end;
  end;

var
  Index, Other, ClassCount: Integer;
  Atom: TCssAtom;
  Duplicate: Boolean;
begin
  Count := 0;
  AddBucket(BucketId, LowercaseAtom(Adapter.Id(Element)));
  ClassCount := Adapter.ClassCount(Element);
  for Index := 0 to ClassCount - 1 do
  begin
    Atom := LowercaseAtom(Adapter.ClassAt(Element, Index));
    Duplicate := False;
    for Other := 0 to Index - 1 do
      if LowercaseAtom(Adapter.ClassAt(Element, Other)) = Atom then
        Duplicate := True;
    if not Duplicate then
      AddBucket(BucketClass, Atom);
  end;
  AddBucket(BucketType, LowercaseAtom(Adapter.LocalName(Element)));
  if Count + FUniversalCount > Length(List) then
    SetLength(List, Count + FUniversalCount + 64);
  for Index := 0 to FUniversalCount - 1 do
  begin
    List[Count] := FUniversal[Index];
    Inc(Count);
  end;
end;

function TCssRuleIndex.FindKeyframes(const Name: string): TCssKeyframesRule;
var
  Index: Integer;
begin
  for Index := High(FKeyframes) downto 0 do
    if FKeyframes[Index].Name = Name then
      Exit(FKeyframes[Index]);
  Result := nil;
end;

function TCssRuleIndex.FontFaceCount: Integer;
begin
  Result := Length(FFontFaces);
end;

function TCssRuleIndex.FontFace(Index: Integer): TCssFontFaceRule;
begin
  Result := FFontFaces[Index];
end;

function TCssRuleIndex.FindRegisteredProperty(Name: TCssAtom; out Registered: TCssRegisteredProperty): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FRegistered) do
    if FRegistered[Index].Name = Name then
    begin
      Registered := FRegistered[Index];
      Exit(True);
    end;
  Registered := Default(TCssRegisteredProperty);
  Result := False;
end;

function TCssRuleIndex.HasRegisteredProperties: Boolean;
begin
  Result := Length(FRegistered) > 0;
end;

function TCssRuleIndex.RegisteredCount: Integer;
begin
  Result := Length(FRegistered);
end;

function TCssRuleIndex.RegisteredAt(Index: Integer): TCssRegisteredProperty;
begin
  Result := FRegistered[Index];
end;

function TCssRuleIndex.Bytes: PtrUInt;
var
  Index: Integer;
begin
  Result := InstanceSize + PtrUInt(Length(FEntries)) * SizeOf(TCssRuleEntry) +
    PtrUInt(Length(FUniversal)) * SizeOf(LongInt);
  for Index := 0 to High(FBuckets) do
    Inc(Result, PtrUInt(Length(FBuckets[Index])) * SizeOf(LongInt) + SizeOf(Pointer) * 2);
end;

end.
