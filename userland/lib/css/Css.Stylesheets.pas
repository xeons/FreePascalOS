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
  Style sheets and their rules, the CSSOM's shape: style rules (with
  nested rules), @media, @supports, @container, @layer (blocks and
  statements), @import, @namespace, @font-face, @keyframes, @page,
  @property, and the nested declarations that follow nested rules.

  Rules own their children. Serialize gives CSSOM's text for each.
}
unit Css.Stylesheets;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Tokens, Css.Values, Css.Selectors, Css.SelectorParser, Css.Declarations,
  Css.MediaQueries;

type
  TCssOrigin = (coUserAgent, coUser, coAuthor);

  TCssRuleKind = (rkStyle, rkNestedDeclarations, rkMedia, rkSupports, rkContainer, rkLayerBlock,
    rkLayerStatement, rkImport, rkNamespace, rkFontFace, rkKeyframes, rkKeyframe, rkPage, rkProperty);

  TCssStyleSheet = class;
  TCssRule = class;
  TCssRuleArray = array of TCssRule;

  TCssRule = class
  public
    Kind: TCssRuleKind;
    Parent: TCssRule;
    Sheet: TCssStyleSheet;
    { The host's object for the rule (a CSSOM wrapper), told when the
      rule goes (CssHostDataFreed). }
    HostData: Pointer;
    constructor Create(AKind: TCssRuleKind);
    destructor Destroy; override;
    function Serialize(const Indent: string = ''): string; virtual; abstract;
  end;

  { A rule with child rules. }
  TCssGroupingRule = class(TCssRule)
  public
    Rules: TCssRuleArray;
    destructor Destroy; override;
    procedure AddRule(Rule: TCssRule);
    { CSSOM: Rule (parented here) at Index; the rule at Index taken out
      (the caller frees it). }
    procedure InsertRuleAt(Rule: TCssRule; Index: Integer);
    function ExtractRuleAt(Index: Integer): TCssRule;
    function SerializeChildren(const Indent: string): string;
  end;

  TCssStyleRule = class(TCssGroupingRule)
  public
    { nil for nested declarations (they take the parent's selectors). }
    Selectors: TCssSelectorList;
    Declarations: TCssDeclarationBlock;
    constructor Create(AKind: TCssRuleKind);
    destructor Destroy; override;
    { The style rule whose selectors this one's '&' refers to. }
    function ParentStyleRule: TCssStyleRule;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssMediaRule = class(TCssGroupingRule)
  public
    Media: TCssMediaQueryList;
    destructor Destroy; override;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssSupportsRule = class(TCssGroupingRule)
  public
    ConditionText: string;
    Matches: Boolean;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssContainerRule = class(TCssGroupingRule)
  public
    Name: string;
    Condition: TCssMediaCondition;
    destructor Destroy; override;
    function ConditionText: string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssLayerBlockRule = class(TCssGroupingRule)
  public
    { '' for an anonymous layer. }
    Name: string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssLayerStatementRule = class(TCssRule)
  public
    Names: array of string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssImportRule = class(TCssRule)
  public
    Url: string;
    HasLayer: Boolean;
    LayerName: string;
    SupportsText: string;
    SupportsMatches: Boolean;
    Media: TCssMediaQueryList;
    { The imported sheet, once the host has loaded it (owned). }
    StyleSheet: TCssStyleSheet;
    destructor Destroy; override;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssNamespaceRule = class(TCssRule)
  public
    Prefix: string;
    Uri: string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssDescriptor = record
    { Lowercase. }
    Name: string;
    { The value as written (unicode-range needs the source text). }
    Text: string;
    { A generic parse of the value, nil when it has none. }
    Value: TCssValue;
  end;

  TCssUnicodeRange = record
    First, Last: LongWord;
  end;

  TCssFontFaceRule = class(TCssRule)
  public
    Descriptors: array of TCssDescriptor;
    UnicodeRanges: array of TCssUnicodeRange;
    destructor Destroy; override;
    function Descriptor(const Name: string): TCssValue;
    function DescriptorText(const Name: string): string;
    function Family: string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssKeyframeRule = class(TCssRule)
  public
    { Offsets from 0 to 1. }
    Offsets: array of Double;
    Declarations: TCssDeclarationBlock;
    destructor Destroy; override;
    function KeyText: string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssKeyframesRule = class(TCssGroupingRule)
  public
    Name: string;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssPageRule = class(TCssRule)
  public
    SelectorText: string;
    Declarations: TCssDeclarationBlock;
    destructor Destroy; override;
    function Serialize(const Indent: string = ''): string; override;
  end;

  { @property: a registered custom property. }
  TCssPropertyRule = class(TCssRule)
  public
    Name: string;
    Syntax: string;
    Inherits: Boolean;
    HasInherits: Boolean;
    InitialValue: TCssTokenArray;
    HasInitialValue: Boolean;
    function Serialize(const Indent: string = ''): string; override;
  end;

  TCssStyleSheet = class
  public
    Origin: TCssOrigin;
    Href: string;
    Rules: TCssRuleArray;
    Namespaces: TCssNamespaces;
    Disabled: Boolean;
    { The media the sheet applies to (a link's media attribute), nil: all. }
    Media: TCssMediaQueryList;
    { The host's object for the sheet (a CSSOM wrapper), told when the
      sheet goes (CssHostDataFreed). }
    HostData: Pointer;
    constructor Create(AOrigin: TCssOrigin);
    destructor Destroy; override;
    procedure AddRule(Rule: TCssRule);
    procedure InsertRuleAt(Rule: TCssRule; Index: Integer);
    function ExtractRuleAt(Index: Integer): TCssRule;
    function Serialize: string;
  end;

var
  { Called with a rule's or sheet's HostData as it is freed. }
  CssHostDataFreed: procedure(HostData: Pointer) = nil;

{ Sets the sheet of Rule and of every rule inside it. }
procedure SetRuleSheet(Rule: TCssRule; Sheet: TCssStyleSheet);

implementation

uses
  SysUtils, Css.Serialization, Css.Keywords;

{ ---- rules ---- }

constructor TCssRule.Create(AKind: TCssRuleKind);
begin
  inherited Create;
  Kind := AKind;
end;

destructor TCssRule.Destroy;
begin
  if (HostData <> nil) and Assigned(CssHostDataFreed) then
    CssHostDataFreed(HostData);
  inherited Destroy;
end;

procedure SetRuleSheet(Rule: TCssRule; Sheet: TCssStyleSheet);
var
  Index: Integer;
begin
  Rule.Sheet := Sheet;
  if Rule is TCssGroupingRule then
    for Index := 0 to High(TCssGroupingRule(Rule).Rules) do
      SetRuleSheet(TCssGroupingRule(Rule).Rules[Index], Sheet);
end;

procedure InsertIntoArray(var Rules: TCssRuleArray; Rule: TCssRule; Index: Integer);
var
  Position: Integer;
begin
  SetLength(Rules, Length(Rules) + 1);
  Position := High(Rules);
  while Position > Index do
  begin
    Rules[Position] := Rules[Position - 1];
    Dec(Position);
  end;
  Rules[Index] := Rule;
end;

function ExtractFromArray(var Rules: TCssRuleArray; Index: Integer): TCssRule;
var
  Position: Integer;
begin
  Result := Rules[Index];
  for Position := Index to High(Rules) - 1 do
    Rules[Position] := Rules[Position + 1];
  SetLength(Rules, Length(Rules) - 1);
end;

procedure TCssGroupingRule.InsertRuleAt(Rule: TCssRule; Index: Integer);
begin
  Rule.Parent := Self;
  SetRuleSheet(Rule, Sheet);
  InsertIntoArray(Rules, Rule, Index);
end;

function TCssGroupingRule.ExtractRuleAt(Index: Integer): TCssRule;
begin
  Result := ExtractFromArray(Rules, Index);
end;

destructor TCssGroupingRule.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Rules) do
    Rules[Index].Free;
  inherited Destroy;
end;

procedure TCssGroupingRule.AddRule(Rule: TCssRule);
begin
  Rule.Parent := Self;
  Rule.Sheet := Sheet;
  SetLength(Rules, Length(Rules) + 1);
  Rules[High(Rules)] := Rule;
end;

function TCssGroupingRule.SerializeChildren(const Indent: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Rules) do
    Result := Result + Indent + '  ' + Rules[Index].Serialize(Indent + '  ') + #10;
end;

constructor TCssStyleRule.Create(AKind: TCssRuleKind);
begin
  inherited Create(AKind);
  Declarations := TCssDeclarationBlock.Create;
end;

destructor TCssStyleRule.Destroy;
begin
  { Children first: their '&' refers to these selectors. }
  inherited Destroy;
  Selectors.Free;
  Declarations.Free;
end;

function TCssStyleRule.ParentStyleRule: TCssStyleRule;
var
  Rule: TCssRule;
begin
  Rule := Parent;
  while (Rule <> nil) and not ((Rule is TCssStyleRule) and (Rule.Kind = rkStyle)) do
    Rule := Rule.Parent;
  Result := TCssStyleRule(Rule);
end;

function TCssStyleRule.Serialize(const Indent: string): string;
var
  Text: string;
  Index: Integer;
begin
  Text := Declarations.Serialize;
  if Kind = rkNestedDeclarations then
    Exit(Text);
  Result := Selectors.Serialize + ' {';
  if Text <> '' then
    Result := Result + ' ' + Text;
  if Length(Rules) = 0 then
    Exit(Result + ' }');
  Result := Result + #10;
  for Index := 0 to High(Rules) do
    Result := Result + Indent + '  ' + Rules[Index].Serialize(Indent + '  ') + #10;
  Result := Result + Indent + '}';
end;

destructor TCssMediaRule.Destroy;
begin
  inherited Destroy;
  Media.Free;
end;

function TCssMediaRule.Serialize(const Indent: string): string;
begin
  Result := '@media ' + Media.Serialize + ' {' + #10 + SerializeChildren(Indent) + Indent + '}';
end;

function TCssSupportsRule.Serialize(const Indent: string): string;
begin
  Result := '@supports ' + ConditionText + ' {' + #10 + SerializeChildren(Indent) + Indent + '}';
end;

destructor TCssContainerRule.Destroy;
begin
  inherited Destroy;
  Condition.Free;
end;

function TCssContainerRule.ConditionText: string;
begin
  Result := '';
  if Condition <> nil then
    Result := Condition.Serialize(True);
end;

function TCssContainerRule.Serialize(const Indent: string): string;
begin
  Result := '@container ';
  if Name <> '' then
    Result := Result + SerializeIdentifier(Name) + ' ';
  Result := Result + ConditionText + ' {' + #10 + SerializeChildren(Indent) + Indent + '}';
end;

function TCssLayerBlockRule.Serialize(const Indent: string): string;
begin
  Result := '@layer ';
  if Name <> '' then
    Result := Result + Name + ' ';
  Result := Result + '{' + #10 + SerializeChildren(Indent) + Indent + '}';
end;

function TCssLayerStatementRule.Serialize(const Indent: string): string;
var
  Index: Integer;
begin
  Result := '@layer ';
  for Index := 0 to High(Names) do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + Names[Index];
  end;
  Result := Result + ';';
end;

destructor TCssImportRule.Destroy;
begin
  Media.Free;
  StyleSheet.Free;
  inherited Destroy;
end;

function TCssImportRule.Serialize(const Indent: string): string;
var
  MediaText: string;
begin
  Result := '@import ' + SerializeUrl(Url);
  if HasLayer then
  begin
    if LayerName = '' then
      Result := Result + ' layer'
    else
      Result := Result + ' layer(' + LayerName + ')';
  end;
  if SupportsText <> '' then
    Result := Result + ' supports(' + SupportsText + ')';
  if Media <> nil then
  begin
    MediaText := Media.Serialize;
    if MediaText <> '' then
      Result := Result + ' ' + MediaText;
  end;
  Result := Result + ';';
end;

function TCssNamespaceRule.Serialize(const Indent: string): string;
begin
  Result := '@namespace ';
  if Prefix <> '' then
    Result := Result + SerializeIdentifier(Prefix) + ' ';
  Result := Result + SerializeUrl(Uri) + ';';
end;

destructor TCssFontFaceRule.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Descriptors) do
    ReleaseValue(Descriptors[Index].Value);
  inherited Destroy;
end;

function TCssFontFaceRule.Descriptor(const Name: string): TCssValue;
var
  Index: Integer;
begin
  for Index := High(Descriptors) downto 0 do
    if Descriptors[Index].Name = Name then
      Exit(Descriptors[Index].Value);
  Result := nil;
end;

function TCssFontFaceRule.DescriptorText(const Name: string): string;
var
  Index: Integer;
begin
  for Index := High(Descriptors) downto 0 do
    if Descriptors[Index].Name = Name then
      Exit(Descriptors[Index].Text);
  Result := '';
end;

function TCssFontFaceRule.Family: string;
var
  Value: TCssValue;
begin
  Value := Descriptor('font-family');
  if Value = nil then
    Result := ''
  else if Value.Kind in [vkString, vkCustomIdent] then
    Result := Value.Text
  else
    Result := Value.Serialize;
end;

function TCssFontFaceRule.Serialize(const Indent: string): string;
var
  Index: Integer;
  Text: string;
begin
  Result := '@font-face {';
  for Index := 0 to High(Descriptors) do
  begin
    if Descriptors[Index].Value <> nil then
      Text := Descriptors[Index].Value.Serialize
    else
      Text := Descriptors[Index].Text;
    Result := Result + ' ' + Descriptors[Index].Name + ': ' + Text + ';';
  end;
  Result := Result + ' }';
end;

destructor TCssKeyframeRule.Destroy;
begin
  Declarations.Free;
  inherited Destroy;
end;

function TCssKeyframeRule.KeyText: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Offsets) do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + SerializeNumber(Offsets[Index] * 100) + '%';
  end;
end;

function TCssKeyframeRule.Serialize(const Indent: string): string;
var
  Text: string;
begin
  Text := Declarations.Serialize;
  Result := KeyText + ' {';
  if Text <> '' then
    Result := Result + ' ' + Text;
  Result := Result + ' }';
end;

function TCssKeyframesRule.Serialize(const Indent: string): string;
begin
  Result := '@keyframes ' + SerializeIdentifier(Name) + ' {' + #10 + SerializeChildren(Indent) + Indent + '}';
end;

destructor TCssPageRule.Destroy;
begin
  Declarations.Free;
  inherited Destroy;
end;

function TCssPageRule.Serialize(const Indent: string): string;
var
  Text: string;
begin
  Result := '@page ';
  if SelectorText <> '' then
    Result := Result + SelectorText + ' ';
  Text := Declarations.Serialize;
  Result := Result + '{';
  if Text <> '' then
    Result := Result + ' ' + Text;
  Result := Result + ' }';
end;

function TCssPropertyRule.Serialize(const Indent: string): string;
begin
  Result := '@property ' + Name + ' {';
  if Syntax <> '' then
    Result := Result + ' syntax: ' + SerializeString(Syntax) + ';';
  if HasInherits then
  begin
    if Inherits then
      Result := Result + ' inherits: true;'
    else
      Result := Result + ' inherits: false;';
  end;
  if HasInitialValue then
    Result := Result + ' initial-value: ' + SerializeTokenArray(InitialValue) + ';';
  Result := Result + ' }';
end;

{ ---- style sheets ---- }

constructor TCssStyleSheet.Create(AOrigin: TCssOrigin);
begin
  inherited Create;
  Origin := AOrigin;
  Namespaces := TCssNamespaces.Create;
end;

destructor TCssStyleSheet.Destroy;
var
  Index: Integer;
begin
  if (HostData <> nil) and Assigned(CssHostDataFreed) then
    CssHostDataFreed(HostData);
  for Index := 0 to High(Rules) do
    Rules[Index].Free;
  Namespaces.Free;
  Media.Free;
  inherited Destroy;
end;

procedure TCssStyleSheet.InsertRuleAt(Rule: TCssRule; Index: Integer);
begin
  Rule.Parent := nil;
  SetRuleSheet(Rule, Self);
  InsertIntoArray(Rules, Rule, Index);
end;

function TCssStyleSheet.ExtractRuleAt(Index: Integer): TCssRule;
begin
  Result := ExtractFromArray(Rules, Index);
end;

procedure TCssStyleSheet.AddRule(Rule: TCssRule);
begin
  Rule.Sheet := Self;
  Rule.Parent := nil;
  SetLength(Rules, Length(Rules) + 1);
  Rules[High(Rules)] := Rule;
end;

function TCssStyleSheet.Serialize: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Rules) do
    Result := Result + Rules[Index].Serialize('') + #10;
end;

end.
