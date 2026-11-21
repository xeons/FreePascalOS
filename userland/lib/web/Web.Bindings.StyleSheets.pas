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
  bindings/StyleSheets.webidl: the CSSOM's sheets and rules over
  libcss's TCssStyleSheet and TCssRule, the very objects the style
  engine indexes (Web.Style.DocumentSheets shares them with styling).

  A sheet or rule has one wrapper, kept in its HostData: the wrapper
  clears HostData when it is collected, and libcss tells the wrapper
  when its sheet or rule is freed (CssHostDataFreed), after which the
  wrapper has no native object (its members give nothing). A rule's
  wrapper keeps its sheet's wrapper alive, a sheet's wrapper its owner
  node's.

  Changes go to the document's sheets object: a rule inserted at the end
  of a sheet (RuleAppended: the style engine may index it at once, as
  CSS-in-JS libraries append one rule after another), anything else
  ContentsChanged (indexed again). Removed rules are retired there and
  freed after the engine indexed again.
}
unit Web.Bindings.StyleSheets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Web.Dom,
  Web.Bindings.Types,
  Web.Bindings.Context;

{$I Web.Bindings.StyleSheets.Members.inc}

implementation

uses
  Js.Objects,
  Css.Stylesheets,
  Css.MediaQueries,
  Css.Selectors,
  Css.SelectorParser,
  Css.Parser,
  Web.Atoms,
  Web.Dom.Exceptions,
  Web.Style.DocumentSheets,
  Web.Bindings.Style;

type
  { What a MediaList is the media of. }
  TMediaListData = class
  public
    Owner: TBindingWrapper;
    function List: TCssMediaQueryList;
    procedure SetList(Value: TCssMediaQueryList);
  end;

  { A sheet's or grouping rule's (or keyframes rule's) rules. }
  TRuleListData = class
  public
    Owner: TBindingWrapper;
    function Count: Integer;
    function Item(Index: Integer): TCssRule;
  end;

  { document.styleSheets. }
  TStyleSheetListData = class
  public
    Document: TDocument;
    function Sheets: TCssStyleSheetList;
  end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function Sheets(const Call: TBindingCall): TDocumentSheets; inline;
begin
  Result := DocumentSheetsOf(Context(Call).Document);
end;

{ ---- wrappers ---- }

procedure HostDataFreed(HostData: Pointer);
begin
  TBindingWrapper(HostData).NativeData := nil;
end;

function WrapSheet(Context: TBindingContext; Sheet: TCssStyleSheet): TJsValue;
var
  Owner: TElement;
  OwnerValue: TJsValue;
  Wrapper: TBindingWrapper;
begin
  if Sheet = nil then
    Exit(JsNull);
  if Sheet.HostData <> nil then
    Exit(JsObjectValue(TBindingWrapper(Sheet.HostData)));
  Owner := DocumentSheetsOf(Context.Document).OwnerOf(Sheet);
  OwnerValue := JsUndefined;
  if Owner <> nil then
    OwnerValue := Context.WrapNode(Owner);
  Result := Context.WrapObject(Sheet, InterfaceCSSStyleSheet, False, OwnerValue);
  Wrapper := TBindingWrapper(JsAsObject(Result));
  Wrapper.WrapperFlags := WrapperIsCssObject;
  Sheet.HostData := Wrapper;
end;

function RuleInterface(Rule: TCssRule): Integer;
begin
  case Rule.Kind of
    rkStyle: Result := InterfaceCSSStyleRule;
    rkMedia: Result := InterfaceCSSMediaRule;
    rkSupports: Result := InterfaceCSSSupportsRule;
    rkLayerBlock: Result := InterfaceCSSLayerBlockRule;
    rkImport: Result := InterfaceCSSImportRule;
    rkNamespace: Result := InterfaceCSSNamespaceRule;
    rkFontFace: Result := InterfaceCSSFontFaceRule;
    rkKeyframes: Result := InterfaceCSSKeyframesRule;
    rkKeyframe: Result := InterfaceCSSKeyframeRule;
    rkContainer: Result := InterfaceCSSConditionRule;
  else
    Result := InterfaceCSSRule;
  end;
end;

function WrapRule(Context: TBindingContext; Rule: TCssRule): TJsValue;
var
  OwnerValue: TJsValue;
  Wrapper: TBindingWrapper;
begin
  if Rule = nil then
    Exit(JsNull);
  if Rule.HostData <> nil then
    Exit(JsObjectValue(TBindingWrapper(Rule.HostData)));
  if Rule.Parent <> nil then
    OwnerValue := WrapRule(Context, Rule.Parent)
  else
    OwnerValue := WrapSheet(Context, Rule.Sheet);
  Result := Context.WrapObject(Rule, RuleInterface(Rule), False, OwnerValue);
  Wrapper := TBindingWrapper(JsAsObject(Result));
  Wrapper.WrapperFlags := WrapperIsCssObject;
  Rule.HostData := Wrapper;
end;

function ThisSheet(const Call: TBindingCall): TCssStyleSheet;
begin
  Result := TCssStyleSheet(Call.Target);
  if Result = nil then
    RaiseDomError(InvalidStateError, 'the style sheet is gone');
end;

function ThisRule(const Call: TBindingCall): TCssRule;
begin
  Result := TCssRule(Call.Target);
  if Result = nil then
    RaiseDomError(InvalidStateError, 'the rule is gone');
end;

{ ---- changing rules ---- }

function RulesOf(Owner: TObject): TCssRuleArray;
begin
  if Owner is TCssStyleSheet then
    Result := TCssStyleSheet(Owner).Rules
  else if Owner is TCssGroupingRule then
    Result := TCssGroupingRule(Owner).Rules
  else
    Result := nil;
end;

function SheetOf(Owner: TObject): TCssStyleSheet;
begin
  if Owner is TCssStyleSheet then
    Result := TCssStyleSheet(Owner)
  else
    Result := TCssRule(Owner).Sheet;
end;

{ The CSSOM's "insert a CSS rule" into a sheet or grouping rule. }
function InsertRule(const Call: TBindingCall; Owner: TObject; const Text: string; Index: Int64): Integer;
var
  Rules: TCssRuleArray;
  Rule: TCssRule;
  Sheet: TCssStyleSheet;
begin
  Rules := RulesOf(Owner);
  if (Index < 0) or (Index > Length(Rules)) then
    RaiseDomError(IndexSizeError, 'the index is past the end of the rules');
  Sheet := SheetOf(Owner);
  if Sheet <> nil then
    Rule := ParseSingleRule(Text, coAuthor, Sheet.Href)
  else
    Rule := ParseSingleRule(Text, coAuthor);
  if Rule = nil then
    RaiseDomError(SyntaxError, 'the rule cannot be parsed');
  if (Rule.Kind = rkImport) and ((Sheet = nil) or Sheets(Call).IsConstructed(Sheet)) then
  begin
    Rule.Free;
    RaiseDomError(SyntaxError, 'a constructed style sheet cannot have @import rules');
  end;
  if (Owner is TCssStyleRule) and not (Rule.Kind in [rkStyle, rkMedia, rkSupports, rkContainer, rkLayerBlock]) then
  begin
    Rule.Free;
    RaiseDomError(HierarchyRequestError, 'that rule cannot be nested in a style rule');
  end;
  if Owner is TCssStyleSheet then
    TCssStyleSheet(Owner).InsertRuleAt(Rule, Index)
  else
    TCssGroupingRule(Owner).InsertRuleAt(Rule, Index);
  Result := Index;
  if (Owner is TCssStyleSheet) and (Index = Length(TCssStyleSheet(Owner).Rules) - 1) then
    Sheets(Call).RuleAppended(TCssStyleSheet(Owner), Rule)
  else
    Sheets(Call).ContentsChanged(Sheet);
end;

procedure DeleteRule(const Call: TBindingCall; Owner: TObject; Index: Int64);
var
  Rules: TCssRuleArray;
  Rule: TCssRule;
begin
  Rules := RulesOf(Owner);
  if (Index < 0) or (Index >= Length(Rules)) then
    RaiseDomError(IndexSizeError, 'there is no rule at that index');
  if Owner is TCssStyleSheet then
    Rule := TCssStyleSheet(Owner).ExtractRuleAt(Index)
  else
    Rule := TCssGroupingRule(Owner).ExtractRuleAt(Index);
  Rule.Parent := nil;
  Sheets(Call).RetireRule(Rule);
  Sheets(Call).ContentsChanged(SheetOf(Owner));
end;

procedure RuleStyleChanged(Context: TBindingContext; Rule: TObject);
begin
  if Rule is TCssRule then
    DocumentSheetsOf(Context.Document).ContentsChanged(TCssRule(Rule).Sheet);
end;

{ ---- MediaList ---- }

function TMediaListData.List: TCssMediaQueryList;
var
  Native: TObject;
begin
  Result := nil;
  Native := TObject(Owner.NativeData);
  if Native is TCssStyleSheet then
    Result := TCssStyleSheet(Native).Media
  else if Native is TCssMediaRule then
    Result := TCssMediaRule(Native).Media
  else if Native is TCssImportRule then
    Result := TCssImportRule(Native).Media;
end;

procedure TMediaListData.SetList(Value: TCssMediaQueryList);
var
  Native: TObject;
begin
  Native := TObject(Owner.NativeData);
  if Native is TCssStyleSheet then
  begin
    TCssStyleSheet(Native).Media.Free;
    TCssStyleSheet(Native).Media := Value;
  end
  else if Native is TCssMediaRule then
  begin
    TCssMediaRule(Native).Media.Free;
    TCssMediaRule(Native).Media := Value;
  end
  else if Native is TCssImportRule then
  begin
    TCssImportRule(Native).Media.Free;
    TCssImportRule(Native).Media := Value;
  end
  else
    Value.Free;
end;

function ThisMedia(const Call: TBindingCall): TMediaListData; inline;
begin
  Result := TMediaListData(Call.Target);
end;

function MediaText(Data: TMediaListData): string;
var
  List: TCssMediaQueryList;
begin
  List := Data.List;
  if List = nil then
    Result := ''
  else
    Result := List.Serialize;
end;

{ Media of a sheet the engine reads: indexed again. }
procedure MediaChanged(const Call: TBindingCall; Data: TMediaListData);
var
  Native: TObject;
begin
  Native := TObject(Data.Owner.NativeData);
  if Native is TCssStyleSheet then
    Sheets(Call).ContentsChanged(TCssStyleSheet(Native))
  else if Native is TCssRule then
    Sheets(Call).ContentsChanged(TCssRule(Native).Sheet);
end;

function MediaList_get_mediaText(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(MediaText(ThisMedia(Call)));
end;

function MediaList_set_mediaText(var Call: TBindingCall): TJsValue;
begin
  if Trim(Call.Text(0)) = '' then
    ThisMedia(Call).SetList(nil)
  else
    ThisMedia(Call).SetList(ParseMediaQueryText(Call.Text(0)));
  MediaChanged(Call, ThisMedia(Call));
  Result := JsUndefined;
end;

function MediaList_get_length(var Call: TBindingCall): TJsValue;
var
  List: TCssMediaQueryList;
begin
  List := ThisMedia(Call).List;
  if List = nil then
    Result := JsInteger(0)
  else
    Result := JsInteger(List.Count);
end;

{ The text of one query: the list's text split at its top-level commas. }
function MediumTexts(Data: TMediaListData): TStringArray;
var
  Text, Piece: string;
  Index, Depth: Integer;
begin
  Result := nil;
  Text := MediaText(Data);
  Piece := '';
  Depth := 0;
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = '(' then
      Inc(Depth)
    else if Text[Index] = ')' then
      Dec(Depth);
    if (Text[Index] = ',') and (Depth = 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Trim(Piece);
      Piece := '';
    end
    else
      Piece := Piece + Text[Index];
  end;
  if Trim(Piece) <> '' then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Trim(Piece);
  end;
end;

function MediaList_item(var Call: TBindingCall): TJsValue;
var
  Texts: TStringArray;
begin
  Texts := MediumTexts(ThisMedia(Call));
  if (Call.Number(0) < 0) or (Call.Number(0) >= Length(Texts)) then
    Exit(JsNull);
  Result := Context(Call).TextValue(Texts[Trunc(Call.Number(0))]);
end;

procedure SetMedia(const Call: TBindingCall; const Texts: TStringArray);
var
  Joined: string;
  Index: Integer;
begin
  Joined := '';
  for Index := 0 to High(Texts) do
  begin
    if Joined <> '' then
      Joined := Joined + ', ';
    Joined := Joined + Texts[Index];
  end;
  if Joined = '' then
    ThisMedia(Call).SetList(nil)
  else
    ThisMedia(Call).SetList(ParseMediaQueryText(Joined));
  MediaChanged(Call, ThisMedia(Call));
end;

function MediaList_appendMedium(var Call: TBindingCall): TJsValue;
var
  Texts: TStringArray;
  Index: Integer;
begin
  Result := JsUndefined;
  Texts := MediumTexts(ThisMedia(Call));
  for Index := 0 to High(Texts) do
    if SameText(Texts[Index], Trim(Call.Text(0))) then
      Exit;
  SetLength(Texts, Length(Texts) + 1);
  Texts[High(Texts)] := Trim(Call.Text(0));
  SetMedia(Call, Texts);
end;

function MediaList_deleteMedium(var Call: TBindingCall): TJsValue;
var
  Texts, Kept: TStringArray;
  Index: Integer;
  Found: Boolean;
begin
  Texts := MediumTexts(ThisMedia(Call));
  Kept := nil;
  Found := False;
  for Index := 0 to High(Texts) do
    if SameText(Texts[Index], Trim(Call.Text(0))) then
      Found := True
    else
    begin
      SetLength(Kept, Length(Kept) + 1);
      Kept[High(Kept)] := Texts[Index];
    end;
  if not Found then
    RaiseDomError(NotFoundError, 'the medium is not in the list');
  SetMedia(Call, Kept);
  Result := JsUndefined;
end;

function NewMediaList(const Call: TBindingCall): TJsValue;
var
  Data: TMediaListData;
begin
  Data := TMediaListData.Create;
  Data.Owner := TBindingWrapper(Call.Wrapper);
  Result := Context(Call).WrapObject(Data, InterfaceMediaList, True, JsObjectValue(TBindingWrapper(Call.Wrapper)));
end;

{ ---- StyleSheet and CSSStyleSheet ---- }

function StyleSheet_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue('text/css');
end;

function StyleSheet_get_href(var Call: TBindingCall): TJsValue;
var
  Owner: TElement;
begin
  Owner := Sheets(Call).OwnerOf(ThisSheet(Call));
  if (Owner <> nil) and Owner.IsHtmlElement(AtomLink) then
    Result := Context(Call).TextValue(ThisSheet(Call).Href)
  else
    Result := JsNull;
end;

function StyleSheet_get_ownerNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(Sheets(Call).OwnerOf(ThisSheet(Call)));
end;

function StyleSheet_get_parentStyleSheet(var Call: TBindingCall): TJsValue;
begin
  Result := JsNull;
end;

function StyleSheet_get_title(var Call: TBindingCall): TJsValue;
var
  Owner: TElement;
begin
  Owner := Sheets(Call).OwnerOf(ThisSheet(Call));
  if (Owner = nil) or not Owner.HasAttributeAtom(AtomTitle) then
    Exit(JsNull);
  Result := Context(Call).TextValue(Owner.AttributeValueOf(AtomTitle));
end;

function StyleSheet_get_media(var Call: TBindingCall): TJsValue;
begin
  Result := NewMediaList(Call);
end;

function StyleSheet_get_disabled(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisSheet(Call).Disabled);
end;

function StyleSheet_set_disabled(var Call: TBindingCall): TJsValue;
begin
  if ThisSheet(Call).Disabled <> Call.Flag(0) then
  begin
    ThisSheet(Call).Disabled := Call.Flag(0);
    Sheets(Call).ContentsChanged(ThisSheet(Call));
  end;
  Result := JsUndefined;
end;

function CSSStyleSheet_constructor(var Call: TBindingCall): TJsValue;
var
  Options: PBindingValue;
  Sheet: TCssStyleSheet;
  BaseUrl: string;
  Wrapper: TBindingWrapper;
begin
  Options := @Call.Arguments[0];
  BaseUrl := Context(Call).Document.Url;
  if Options^.Items[CSSStyleSheetInit_baseURL].Kind = bvString then
    BaseUrl := Options^.Items[CSSStyleSheetInit_baseURL].Text;
  Sheet := Sheets(Call).NewConstructedSheet(BaseUrl);
  if Trim(Options^.Items[CSSStyleSheetInit_media].Text) <> '' then
    Sheet.Media := ParseMediaQueryText(Options^.Items[CSSStyleSheetInit_media].Text);
  Sheet.Disabled := Options^.Items[CSSStyleSheetInit_disabled].Flag;
  Result := Context(Call).WrapObjectWithPrototype(Sheet, InterfaceCSSStyleSheet, False,
    Context(Call).PrototypeForConstruct(Call));
  Wrapper := TBindingWrapper(JsAsObject(Result));
  Wrapper.WrapperFlags := WrapperIsCssObject;
  Sheet.HostData := Wrapper;
end;

function CSSStyleSheet_get_ownerRule(var Call: TBindingCall): TJsValue;
begin
  Result := JsNull;
end;

function NewRuleList(const Call: TBindingCall): TJsValue;
var
  Data: TRuleListData;
begin
  Data := TRuleListData.Create;
  Data.Owner := TBindingWrapper(Call.Wrapper);
  Result := Context(Call).WrapObject(Data, InterfaceCSSRuleList, True, JsObjectValue(TBindingWrapper(Call.Wrapper)));
end;

function CSSStyleSheet_get_cssRules(var Call: TBindingCall): TJsValue;
begin
  ThisSheet(Call);
  Result := NewRuleList(Call);
end;

function CSSStyleSheet_get_rules(var Call: TBindingCall): TJsValue;
begin
  ThisSheet(Call);
  Result := NewRuleList(Call);
end;

function CSSStyleSheet_insertRule(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(InsertRule(Call, ThisSheet(Call), Call.Text(0), Call.Int(1)));
end;

function CSSStyleSheet_deleteRule(var Call: TBindingCall): TJsValue;
begin
  DeleteRule(Call, ThisSheet(Call), Call.Int(0));
  Result := JsUndefined;
end;

function CSSStyleSheet_replaceSync(var Call: TBindingCall): TJsValue;
var
  Sheet, Parsed: TCssStyleSheet;
  Index: Integer;
begin
  Sheet := ThisSheet(Call);
  if not Sheets(Call).IsConstructed(Sheet) then
    RaiseDomError('NotAllowedError', 'only constructed style sheets can be replaced');
  while Length(Sheet.Rules) > 0 do
    Sheets(Call).RetireRule(Sheet.ExtractRuleAt(High(Sheet.Rules)));
  Parsed := ParseStyleSheet(Call.Text(0), coAuthor, Sheet.Href);
  try
    for Index := 0 to High(Parsed.Rules) do
      if Parsed.Rules[Index].Kind <> rkImport then
      begin
        Sheet.InsertRuleAt(Parsed.Rules[Index], Length(Sheet.Rules));
        Parsed.Rules[Index] := nil;
      end;
  finally
    Parsed.Free;
  end;
  Sheets(Call).ContentsChanged(Sheet);
  Result := JsUndefined;
end;

function CSSStyleSheet_addRule(var Call: TBindingCall): TJsValue;
var
  Index: Int64;
  Text: string;
begin
  Text := Call.Text(0) + ' { ';
  if Call.Text(1) <> '' then
    Text := Text + Call.Text(1) + ' ';
  Text := Text + '}';
  if Call.Present(2) then
    Index := Call.Int(2)
  else
    Index := Length(ThisSheet(Call).Rules);
  InsertRule(Call, ThisSheet(Call), Text, Index);
  Result := JsInteger(-1);
end;

function CSSStyleSheet_removeRule(var Call: TBindingCall): TJsValue;
begin
  DeleteRule(Call, ThisSheet(Call), Call.Int(0));
  Result := JsUndefined;
end;

{ ---- CSSRuleList ---- }

function TRuleListData.Count: Integer;
var
  Native: TObject;
begin
  Native := TObject(Owner.NativeData);
  if Native = nil then
    Exit(0);
  Result := Length(RulesOf(Native));
end;

function TRuleListData.Item(Index: Integer): TCssRule;
var
  Rules: TCssRuleArray;
begin
  Result := nil;
  if Owner.NativeData = nil then
    Exit;
  Rules := RulesOf(TObject(Owner.NativeData));
  if (Index >= 0) and (Index < Length(Rules)) then
    Result := Rules[Index];
end;

function CSSRuleList_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(TRuleListData(Call.Target).Count);
end;

function CSSRuleList_item(var Call: TBindingCall): TJsValue;
begin
  if (Call.Number(0) < 0) or (Call.Number(0) > High(Integer)) then
    Exit(JsNull);
  Result := WrapRule(Context(Call), TRuleListData(Call.Target).Item(Trunc(Call.Number(0))));
end;

{ ---- StyleSheetList and document ---- }

function TStyleSheetListData.Sheets: TCssStyleSheetList;
var
  Node: TNode;
  Element: TElement;
  Sheet: TCssStyleSheet;
  DocumentSheets: TDocumentSheets;
begin
  Result := nil;
  DocumentSheets := DocumentSheetsOf(Document);
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      Sheet := nil;
      if Element.IsHtmlElement(AtomStyle) then
        Sheet := DocumentSheets.StyleElementSheet(Element)
      else if Element.IsHtmlElement(AtomLink) then
        Sheet := DocumentSheets.LinkSheet(Element)
      else if Element.IsHtmlElement(AtomTemplate) then
      begin
        Node := Node.NextInTreeSkippingChildren(Document);
        Continue;
      end;
      if Sheet <> nil then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Sheet;
      end;
    end;
    Node := Node.NextInTree(Document);
  end;
end;

function Document_get_styleSheets(var Call: TBindingCall): TJsValue;
var
  Data: TStyleSheetListData;
begin
  Data := TStyleSheetListData.Create;
  Data.Document := TDocument(Call.Target);
  Result := Context(Call).WrapObject(Data, InterfaceStyleSheetList, True, JsObjectValue(TBindingWrapper(Call.Wrapper)));
end;

function StyleSheetList_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Length(TStyleSheetListData(Call.Target).Sheets));
end;

function StyleSheetList_item(var Call: TBindingCall): TJsValue;
var
  List: TCssStyleSheetList;
begin
  List := TStyleSheetListData(Call.Target).Sheets;
  if (Call.Number(0) < 0) or (Call.Number(0) >= Length(List)) then
    Exit(JsNull);
  Result := WrapSheet(Context(Call), List[Trunc(Call.Number(0))]);
end;

const
  { The document wrapper's cache slot for adoptedStyleSheets' array. }
  AdoptedSlot = 40;

function Document_get_adoptedStyleSheets(var Call: TBindingCall): TJsValue;
var
  Wrapper: TBindingWrapper;
  Adopted: TCssStyleSheetList;
  Values: array of TJsValue;
  Index: Integer;
begin
  Wrapper := TBindingWrapper(Call.Wrapper);
  Result := Wrapper.CachedValue(AdoptedSlot);
  if JsIsObject(Result) then
    Exit;
  Adopted := DocumentSheetsOf(TDocument(Call.Target)).AdoptedSheets;
  Values := nil;
  SetLength(Values, Length(Adopted));
  for Index := 0 to High(Adopted) do
    Values[Index] := WrapSheet(Context(Call), Adopted[Index]);
  Result := Context(Call).NewArray(Values);
  Wrapper.SetCachedValue(AdoptedSlot, Result);
end;

function Document_set_adoptedStyleSheets(var Call: TBindingCall): TJsValue;
var
  Value, Item: TJsValue;
  Count, Index: Integer;
  List: TCssStyleSheetList;
  Native: TObject;
  Values: array of TJsValue;
begin
  Value := Call.Script(0);
  if not JsIsObject(Value) then
    raise EBindingTypeError.Create('adoptedStyleSheets must be an array of CSSStyleSheet');
  Count := Trunc(Context(Call).Engine.ToNumber(Context(Call).Engine.GetProperty(Value, 'length')));
  List := nil;
  Values := nil;
  for Index := 0 to Count - 1 do
  begin
    Item := Context(Call).Engine.GetProperty(Value, IntToStr(Index));
    Native := Context(Call).Unwrap(Item, InterfaceCSSStyleSheet);
    if (Native = nil) or not Sheets(Call).IsConstructed(TCssStyleSheet(Native)) then
      RaiseDomError('NotAllowedError', 'only constructed style sheets can be adopted');
    SetLength(List, Length(List) + 1);
    List[High(List)] := TCssStyleSheet(Native);
    SetLength(Values, Length(Values) + 1);
    Values[High(Values)] := Item;
  end;
  DocumentSheetsOf(TDocument(Call.Target)).SetAdoptedSheets(List);
  TBindingWrapper(Call.Wrapper).SetCachedValue(AdoptedSlot, Context(Call).NewArray(Values));
  Result := JsUndefined;
end;

function HTMLStyleElement_get_sheet(var Call: TBindingCall): TJsValue;
begin
  Result := WrapSheet(Context(Call), DocumentSheetsOf(TElement(Call.Target).NodeDocument).StyleElementSheet(
    TElement(Call.Target)));
end;

function HTMLLinkElement_get_sheet(var Call: TBindingCall): TJsValue;
begin
  Result := WrapSheet(Context(Call), DocumentSheetsOf(TElement(Call.Target).NodeDocument).LinkSheet(
    TElement(Call.Target)));
end;

{ ---- CSSRule ---- }

function CSSRule_get_cssText(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisRule(Call).Serialize);
end;

function CSSRule_set_cssText(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function CSSRule_get_parentRule(var Call: TBindingCall): TJsValue;
begin
  Result := WrapRule(Context(Call), ThisRule(Call).Parent);
end;

function CSSRule_get_parentStyleSheet(var Call: TBindingCall): TJsValue;
begin
  Result := WrapSheet(Context(Call), ThisRule(Call).Sheet);
end;

function CSSRule_get_type(var Call: TBindingCall): TJsValue;
begin
  case ThisRule(Call).Kind of
    rkStyle: Result := JsInteger(1);
    rkImport: Result := JsInteger(3);
    rkMedia: Result := JsInteger(4);
    rkFontFace: Result := JsInteger(5);
    rkPage: Result := JsInteger(6);
    rkKeyframes: Result := JsInteger(7);
    rkKeyframe: Result := JsInteger(8);
    rkNamespace: Result := JsInteger(10);
    rkSupports: Result := JsInteger(12);
  else
    Result := JsInteger(0);
  end;
end;

function CSSGroupingRule_get_cssRules(var Call: TBindingCall): TJsValue;
begin
  ThisRule(Call);
  Result := NewRuleList(Call);
end;

function CSSGroupingRule_insertRule(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(InsertRule(Call, ThisRule(Call), Call.Text(0), Call.Int(1)));
end;

function CSSGroupingRule_deleteRule(var Call: TBindingCall): TJsValue;
begin
  DeleteRule(Call, ThisRule(Call), Call.Int(0));
  Result := JsUndefined;
end;

function CSSStyleRule_get_selectorText(var Call: TBindingCall): TJsValue;
var
  Rule: TCssStyleRule;
begin
  Rule := TCssStyleRule(ThisRule(Call));
  if Rule.Selectors = nil then
    Exit(Context(Call).TextValue(''));
  Result := Context(Call).TextValue(Rule.Selectors.Serialize);
end;

function CSSStyleRule_set_selectorText(var Call: TBindingCall): TJsValue;
var
  Rule: TCssStyleRule;
  Parsed: TCssSelectorList;
  Namespaces: TCssNamespaces;
begin
  Result := JsUndefined;
  Rule := TCssStyleRule(ThisRule(Call));
  Namespaces := nil;
  if Rule.Sheet <> nil then
    Namespaces := Rule.Sheet.Namespaces;
  Parsed := ParseSelectorText(Call.Text(0), Namespaces);
  if (Parsed = nil) or (Parsed.Count = 0) then
  begin
    Parsed.Free;
    Exit;
  end;
  { The engine's index points at the old selectors until it indexes
    again: they are retired, not freed. }
  if Rule.Selectors <> nil then
    Sheets(Call).RetireObject(Rule.Selectors);
  Rule.Selectors := Parsed;
  Sheets(Call).ContentsChanged(Rule.Sheet);
end;

function CSSStyleRule_get_style(var Call: TBindingCall): TJsValue;
begin
  ThisRule(Call);
  Result := RuleStyleObject(Context(Call), TBindingWrapper(Call.Wrapper), @RuleStyleChanged);
end;

function CSSConditionRule_get_conditionText(var Call: TBindingCall): TJsValue;
var
  Rule: TCssRule;
begin
  Rule := ThisRule(Call);
  if (Rule is TCssMediaRule) and (TCssMediaRule(Rule).Media <> nil) then
    Result := Context(Call).TextValue(TCssMediaRule(Rule).Media.Serialize)
  else if Rule is TCssSupportsRule then
    Result := Context(Call).TextValue(TCssSupportsRule(Rule).ConditionText)
  else if Rule is TCssContainerRule then
    Result := Context(Call).TextValue(TCssContainerRule(Rule).ConditionText)
  else
    Result := Context(Call).TextValue('');
end;

function CSSMediaRule_get_media(var Call: TBindingCall): TJsValue;
begin
  ThisRule(Call);
  Result := NewMediaList(Call);
end;

function CSSMediaRule_get_matches(var Call: TBindingCall): TJsValue;
var
  Rule: TCssMediaRule;
begin
  Rule := TCssMediaRule(ThisRule(Call));
  Result := JsBoolean((Rule.Media = nil) or Rule.Media.Matches(DefaultMediaEnvironment));
end;

function CSSSupportsRule_get_matches(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(TCssSupportsRule(ThisRule(Call)).Matches);
end;

function CSSLayerBlockRule_get_name(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TCssLayerBlockRule(ThisRule(Call)).Name);
end;

function CSSImportRule_get_href(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TCssImportRule(ThisRule(Call)).Url);
end;

function CSSImportRule_get_media(var Call: TBindingCall): TJsValue;
begin
  ThisRule(Call);
  Result := NewMediaList(Call);
end;

function CSSImportRule_get_styleSheet(var Call: TBindingCall): TJsValue;
begin
  Result := WrapSheet(Context(Call), TCssImportRule(ThisRule(Call)).StyleSheet);
end;

function CSSImportRule_get_layerName(var Call: TBindingCall): TJsValue;
var
  Rule: TCssImportRule;
begin
  Rule := TCssImportRule(ThisRule(Call));
  if not Rule.HasLayer then
    Exit(JsNull);
  Result := Context(Call).TextValue(Rule.LayerName);
end;

function CSSImportRule_get_supportsText(var Call: TBindingCall): TJsValue;
var
  Rule: TCssImportRule;
begin
  Rule := TCssImportRule(ThisRule(Call));
  if Rule.SupportsText = '' then
    Exit(JsNull);
  Result := Context(Call).TextValue(Rule.SupportsText);
end;

function CSSNamespaceRule_get_namespaceURI(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TCssNamespaceRule(ThisRule(Call)).Uri);
end;

function CSSNamespaceRule_get_prefix(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TCssNamespaceRule(ThisRule(Call)).Prefix);
end;

{ ---- keyframes ---- }

function CSSKeyframeRule_get_keyText(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(TCssKeyframeRule(ThisRule(Call)).KeyText);
end;

function CSSKeyframeRule_set_keyText(var Call: TBindingCall): TJsValue;
var
  Rule: TCssKeyframeRule;
  Parsed: TCssRule;
begin
  Result := JsUndefined;
  Rule := TCssKeyframeRule(ThisRule(Call));
  Parsed := ParseSingleRule('@keyframes x { ' + Call.Text(0) + ' {} }', coAuthor);
  try
    if (Parsed = nil) or (Length(TCssKeyframesRule(Parsed).Rules) <> 1) then
      RaiseDomError(SyntaxError, 'the key text cannot be parsed');
    Rule.Offsets := Copy(TCssKeyframeRule(TCssKeyframesRule(Parsed).Rules[0]).Offsets);
  finally
    Parsed.Free;
  end;
  Sheets(Call).ContentsChanged(Rule.Sheet);
end;

function CSSKeyframeRule_get_style(var Call: TBindingCall): TJsValue;
begin
  ThisRule(Call);
  Result := RuleStyleObject(Context(Call), TBindingWrapper(Call.Wrapper), @RuleStyleChanged);
end;

function ThisKeyframes(const Call: TBindingCall): TCssKeyframesRule; inline;
begin
  Result := TCssKeyframesRule(ThisRule(Call));
end;

function CSSKeyframesRule_get_name(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisKeyframes(Call).Name);
end;

function CSSKeyframesRule_set_name(var Call: TBindingCall): TJsValue;
begin
  ThisKeyframes(Call).Name := Call.Text(0);
  Sheets(Call).ContentsChanged(ThisKeyframes(Call).Sheet);
  Result := JsUndefined;
end;

function CSSKeyframesRule_get_cssRules(var Call: TBindingCall): TJsValue;
begin
  ThisRule(Call);
  Result := NewRuleList(Call);
end;

function CSSKeyframesRule_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Length(ThisKeyframes(Call).Rules));
end;

function CSSKeyframesRule_item(var Call: TBindingCall): TJsValue;
var
  Rule: TCssKeyframesRule;
begin
  Rule := ThisKeyframes(Call);
  if (Call.Number(0) < 0) or (Call.Number(0) >= Length(Rule.Rules)) then
    Exit(JsNull);
  Result := WrapRule(Context(Call), Rule.Rules[Trunc(Call.Number(0))]);
end;

function FindKeyframe(Rule: TCssKeyframesRule; const Select: string): Integer;
var
  Parsed: TCssRule;
  Wanted: string;
  Index: Integer;
begin
  Result := -1;
  Parsed := ParseSingleRule('@keyframes x { ' + Select + ' {} }', coAuthor);
  try
    if (Parsed = nil) or (Length(TCssKeyframesRule(Parsed).Rules) <> 1) then
      Exit;
    Wanted := TCssKeyframeRule(TCssKeyframesRule(Parsed).Rules[0]).KeyText;
  finally
    Parsed.Free;
  end;
  for Index := High(Rule.Rules) downto 0 do
    if TCssKeyframeRule(Rule.Rules[Index]).KeyText = Wanted then
      Exit(Index);
end;

function CSSKeyframesRule_appendRule(var Call: TBindingCall): TJsValue;
var
  Rule: TCssKeyframesRule;
  Parsed: TCssRule;
  Keyframe: TCssRule;
begin
  Rule := ThisKeyframes(Call);
  Parsed := ParseSingleRule('@keyframes x { ' + Call.Text(0) + ' }', coAuthor);
  try
    if (Parsed = nil) or (Length(TCssKeyframesRule(Parsed).Rules) <> 1) then
      RaiseDomError(SyntaxError, 'the keyframe cannot be parsed');
    Keyframe := TCssKeyframesRule(Parsed).ExtractRuleAt(0);
  finally
    Parsed.Free;
  end;
  Rule.InsertRuleAt(Keyframe, Length(Rule.Rules));
  Sheets(Call).ContentsChanged(Rule.Sheet);
  Result := JsUndefined;
end;

function CSSKeyframesRule_deleteRule(var Call: TBindingCall): TJsValue;
var
  Rule: TCssKeyframesRule;
  Index: Integer;
begin
  Result := JsUndefined;
  Rule := ThisKeyframes(Call);
  Index := FindKeyframe(Rule, Call.Text(0));
  if Index < 0 then
    Exit;
  Sheets(Call).RetireRule(Rule.ExtractRuleAt(Index));
  Sheets(Call).ContentsChanged(Rule.Sheet);
end;

function CSSKeyframesRule_findRule(var Call: TBindingCall): TJsValue;
var
  Rule: TCssKeyframesRule;
  Index: Integer;
begin
  Rule := ThisKeyframes(Call);
  Index := FindKeyframe(Rule, Call.Text(0));
  if Index < 0 then
    Exit(JsNull);
  Result := WrapRule(Context(Call), Rule.Rules[Index]);
end;

initialization
  CssHostDataFreed := @HostDataFreed;
end.
