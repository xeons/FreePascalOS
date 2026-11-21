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
  Styling an SVG file with libcss: the element adapter over libsvg's
  nodes, the document's <style> sheets (type text/css or none; @import
  is not followed) and the cascade, which gives every element its
  computed style (TSvgNode.Style).

  Presentation attributes are the presentational hints, the style
  attribute the inline declarations, as libcss's cascade expects. No
  user agent sheet is used: what SVG's would say (overflow on nested
  viewports, display of resources) the renderer knows itself.

  The styler stays with the document: content a <use> instantiates is
  styled again under the <use> element (ResolveStyle with the use's
  style as the parent), as SVG 2's shadow trees inherit from their use.
}
unit Svg.Styling;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.Atoms,
  Css.Declarations,
  Css.ElementAdapter,
  Css.Stylesheets,
  Css.ComputedStyle,
  Css.StyleEngine,
  Css.MediaQueries,
  Svg.Nodes;

type
  TSvgStyleAdapter = class(TCssElementAdapter)
  private
    FRoot: TSvgNode;
  public
    constructor Create(Root: TSvgNode);
    function LocalName(Element: TCssElement): TCssAtom; override;
    function NamespaceUri(Element: TCssElement): TCssAtom; override;
    function IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean; override;
    function Id(Element: TCssElement): TCssAtom; override;
    function ClassCount(Element: TCssElement): Integer; override;
    function ClassAt(Element: TCssElement; Index: Integer): TCssAtom; override;
    function FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom;
      out Value: string): Boolean; override;
    function AttributeCount(Element: TCssElement): Integer; override;
    procedure AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace, AttributeName: TCssAtom;
      out Value: string); override;
    function Parent(Element: TCssElement): TCssElement; override;
    function PreviousSibling(Element: TCssElement): TCssElement; override;
    function NextSibling(Element: TCssElement): TCssElement; override;
    function FirstChild(Element: TCssElement): TCssElement; override;
    function LastChild(Element: TCssElement): TCssElement; override;
    function IsEmpty(Element: TCssElement): Boolean; override;
    function IsRoot(Element: TCssElement): Boolean; override;
    function States(Element: TCssElement): TCssElementStates; override;
    function Language(Element: TCssElement): string; override;
    function StyleAttribute(Element: TCssElement): TCssDeclarationBlock; override;
    function PresentationalHints(Element: TCssElement): TCssDeclarationBlock; override;
  end;

  { Restyles nodes under another parent (for <use>); an embedder that
    styles the tree itself provides its own. }
  TSvgStyleResolver = class
  public
    { A new reference: Node's style with ParentStyle as its parent's. }
    function ResolveStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle; virtual; abstract;
  end;

  TSvgStyler = class(TSvgStyleResolver)
  private
    FAdapter: TSvgStyleAdapter;
    FEngine: TCssStyleEngine;
    FSheets: array of TCssStyleSheet;
    procedure CollectSheets(Node: TSvgNode);
    procedure StyleSubtree(Node: TSvgNode; ParentStyle: TCssComputedStyle);
  public
    constructor Create(Root: TSvgNode);
    destructor Destroy; override;
    { Computes every element's style; RootParentStyle is what the root
      inherits from (nil: initial values). }
    procedure StyleDocument(Root: TSvgNode; RootParentStyle: TCssComputedStyle);
    function ResolveStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle; override;
  end;

{ The node's presentation attributes as one declaration block (nil when
  it has none). }
function BuildPresentationHints(Node: TSvgNode): TCssDeclarationBlock;

implementation

uses
  Css.Parser,
  Svg.Presentation;

function BuildPresentationHints(Node: TSvgNode): TCssDeclarationBlock;
var
  Index: Integer;
  Text: string;
begin
  Result := nil;
  Text := '';
  for Index := 0 to Node.AttributeCount - 1 do
    if Node.Attributes[Index].NamespaceUri = '' then
      Text := Text + PresentationDeclaration(Node.Attributes[Index].Name, Node.Attributes[Index].Value);
  if Text <> '' then
    Result := ParseStyleAttribute(Text);
end;

{ ---- the adapter ---- }

constructor TSvgStyleAdapter.Create(Root: TSvgNode);
begin
  inherited Create;
  FRoot := Root;
end;

function TSvgStyleAdapter.LocalName(Element: TCssElement): TCssAtom;
begin
  Result := TSvgNode(Element).LocalNameAtom;
end;

function TSvgStyleAdapter.NamespaceUri(Element: TCssElement): TCssAtom;
begin
  Result := TSvgNode(Element).NamespaceAtom;
end;

function TSvgStyleAdapter.IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean;
begin
  Result := False;
end;

function TSvgStyleAdapter.Id(Element: TCssElement): TCssAtom;
var
  Value: string;
begin
  Value := TSvgNode(Element).Id;
  if Value = '' then
    Result := NoAtom
  else
    Result := InternAtom(Value);
end;

function TSvgStyleAdapter.ClassCount(Element: TCssElement): Integer;
begin
  Result := Length(TSvgNode(Element).ClassAtoms);
end;

function TSvgStyleAdapter.ClassAt(Element: TCssElement; Index: Integer): TCssAtom;
begin
  Result := TSvgNode(Element).ClassAtoms[Index];
end;

function TSvgStyleAdapter.FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom;
  out Value: string): Boolean;
var
  Node: TSvgNode;
  Index: Integer;
begin
  Node := TSvgNode(Element);
  for Index := 0 to Node.AttributeCount - 1 do
    if (Node.Attributes[Index].NameAtom = AttributeName) and
       (Node.Attributes[Index].NamespaceAtom = AttributeNamespace) then
    begin
      Value := Node.Attributes[Index].Value;
      Exit(True);
    end;
  Value := '';
  Result := False;
end;

function TSvgStyleAdapter.AttributeCount(Element: TCssElement): Integer;
begin
  Result := TSvgNode(Element).AttributeCount;
end;

procedure TSvgStyleAdapter.AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace,
  AttributeName: TCssAtom; out Value: string);
begin
  AttributeNamespace := TSvgNode(Element).Attributes[Index].NamespaceAtom;
  AttributeName := TSvgNode(Element).Attributes[Index].NameAtom;
  Value := TSvgNode(Element).Attributes[Index].Value;
end;

function TSvgStyleAdapter.Parent(Element: TCssElement): TCssElement;
begin
  Result := TSvgNode(Element).Parent;
end;

function TSvgStyleAdapter.PreviousSibling(Element: TCssElement): TCssElement;
begin
  Result := TSvgNode(Element).PreviousElementSibling;
end;

function TSvgStyleAdapter.NextSibling(Element: TCssElement): TCssElement;
begin
  Result := TSvgNode(Element).NextElementSibling;
end;

function TSvgStyleAdapter.FirstChild(Element: TCssElement): TCssElement;
begin
  Result := TSvgNode(Element).FirstElementChild;
end;

function TSvgStyleAdapter.LastChild(Element: TCssElement): TCssElement;
begin
  Result := TSvgNode(Element).LastElementChild;
end;

function TSvgStyleAdapter.IsEmpty(Element: TCssElement): Boolean;
begin
  Result := TSvgNode(Element).FirstChild = nil;
end;

function TSvgStyleAdapter.IsRoot(Element: TCssElement): Boolean;
begin
  Result := TSvgNode(Element) = FRoot;
end;

function TSvgStyleAdapter.States(Element: TCssElement): TCssElementStates;
begin
  Result := [];
end;

function TSvgStyleAdapter.Language(Element: TCssElement): string;
var
  Node: TSvgNode;
  Index: Integer;
begin
  Node := TSvgNode(Element);
  while Node <> nil do
  begin
    Index := Node.AttributeIndex('lang', XmlNamespace);
    if Index < 0 then
      Index := Node.AttributeIndex('lang');
    if Index >= 0 then
      Exit(Node.Attributes[Index].Value);
    Node := Node.Parent;
  end;
  Result := '';
end;

function TSvgStyleAdapter.StyleAttribute(Element: TCssElement): TCssDeclarationBlock;
var
  Node: TSvgNode;
  Index: Integer;
begin
  Node := TSvgNode(Element);
  if Node.StyleDeclarations = nil then
  begin
    Index := Node.AttributeIndex('style');
    if Index >= 0 then
      Node.StyleDeclarations := ParseStyleAttribute(Node.Attributes[Index].Value);
  end;
  Result := Node.StyleDeclarations;
end;

function TSvgStyleAdapter.PresentationalHints(Element: TCssElement): TCssDeclarationBlock;
var
  Node: TSvgNode;
begin
  Node := TSvgNode(Element);
  if not Node.HintsParsed then
  begin
    Node.PresentationHints := BuildPresentationHints(Node);
    Node.HintsParsed := True;
  end;
  Result := Node.PresentationHints;
end;

{ ---- the styler ---- }

constructor TSvgStyler.Create(Root: TSvgNode);
begin
  inherited Create;
  FAdapter := TSvgStyleAdapter.Create(Root);
  FEngine := TCssStyleEngine.Create(FAdapter, False);
  FEngine.SetEnvironment(DefaultMediaEnvironment);
  CollectSheets(Root);
end;

destructor TSvgStyler.Destroy;
var
  Index: Integer;
begin
  FEngine.Free;
  for Index := 0 to High(FSheets) do
    FSheets[Index].Free;
  FAdapter.Free;
  inherited Destroy;
end;

procedure TSvgStyler.CollectSheets(Node: TSvgNode);
var
  Child: TSvgNode;
  StyleType: string;
  Sheet: TCssStyleSheet;
begin
  if Node.IsKind(SvgStyle) then
  begin
    StyleType := LowerCase(Trim(Node.Attribute('type')));
    if (StyleType = '') or (StyleType = 'text/css') then
    begin
      Sheet := ParseStyleSheet(Node.TextContent, coAuthor);
      SetLength(FSheets, Length(FSheets) + 1);
      FSheets[High(FSheets)] := Sheet;
      FEngine.AddStyleSheet(Sheet);
    end;
    Exit;
  end;
  Child := Node.FirstElementChild;
  while Child <> nil do
  begin
    CollectSheets(Child);
    Child := Child.NextElementSibling;
  end;
end;

procedure TSvgStyler.StyleSubtree(Node: TSvgNode; ParentStyle: TCssComputedStyle);
var
  Style: TCssComputedStyle;
  Child: TSvgNode;
begin
  Style := FEngine.ResolveStyle(Node, ParentStyle);
  Node.Style := Style;
  Style.Release;
  FEngine.PushAncestor(Node);
  try
    Child := Node.FirstElementChild;
    while Child <> nil do
    begin
      StyleSubtree(Child, Node.Style);
      Child := Child.NextElementSibling;
    end;
  finally
    FEngine.PopAncestor;
  end;
end;

procedure TSvgStyler.StyleDocument(Root: TSvgNode; RootParentStyle: TCssComputedStyle);
begin
  FEngine.ResetAncestors;
  StyleSubtree(Root, RootParentStyle);
  FEngine.ResetAncestors;
end;

function TSvgStyler.ResolveStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  Result := FEngine.ResolveStyle(Node, ParentStyle);
end;

end.
