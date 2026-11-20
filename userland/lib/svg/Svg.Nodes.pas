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
  The SVG render tree's nodes: elements (a local name, a namespace,
  attributes) and the text inside them, as libsvg's XML parser reads
  them from a file or as an embedder copies them from its own document
  (libweb's inline <svg>).

  Every element knows its kind (TSvgElementKind, from its name when it
  is in the SVG namespace; anything else is SvgUnknown and is not
  drawn) and carries its computed style (libcss), set by whoever styles
  the tree: libsvg's own cascade (Svg.Styling) for a file, the
  embedder's for inline SVG. Host is the embedder's own node, for its
  style engine to restyle content a <use> instantiates.

  Attribute and CSS names are kept as libcss atoms too, so the style
  engine's element adapter (Svg.StyleAdapter) answers without work.
}
unit Svg.Nodes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.Atoms,
  Css.Declarations,
  Css.ComputedStyle;

const
  SvgNamespace = 'http://www.w3.org/2000/svg';
  XlinkNamespace = 'http://www.w3.org/1999/xlink';
  XmlNamespace = 'http://www.w3.org/XML/1998/namespace';
  XhtmlNamespace = 'http://www.w3.org/1999/xhtml';

type
  TSvgNodeKind = (SvgElementNode, SvgTextNode);

  TSvgElementKind = (SvgUnknown, SvgSvg, SvgG, SvgDefs, SvgUse, SvgSymbol, SvgRect, SvgCircle, SvgEllipse,
    SvgLine, SvgPolyline, SvgPolygon, SvgPath, SvgText, SvgTspan, SvgTextPath, SvgImage, SvgLinearGradient,
    SvgRadialGradient, SvgStop, SvgPattern, SvgClipPath, SvgMask, SvgStyle, SvgMarker, SvgSwitch, SvgAnchor,
    SvgTitle, SvgDesc, SvgMetadata, SvgForeignObject, SvgFilter);

  TSvgAttribute = record
    Name: string;
    NamespaceUri: string;
    Value: string;
    NameAtom: TCssAtom;
    NamespaceAtom: TCssAtom;
  end;

  TSvgNode = class
  private
    FKind: TSvgNodeKind;
    FLocalName: string;
    FNamespaceUri: string;
    FElementKind: TSvgElementKind;
    FText: string;
    FAttributes: array of TSvgAttribute;
    FAttributeCount: Integer;
    FParent: TSvgNode;
    FFirstChild: TSvgNode;
    FLastChild: TSvgNode;
    FNextSibling: TSvgNode;
    FPreviousSibling: TSvgNode;
    FStyle: TCssComputedStyle;
    FClassesKnown: Boolean;
    FClasses: TCssAtomArray;
    procedure SetStyle(Value: TCssComputedStyle);
    function GetAttribute(Index: Integer): TSvgAttribute;
  public
    LocalNameAtom: TCssAtom;
    NamespaceAtom: TCssAtom;
    { The parsed style attribute and presentation attributes (made by
      the styling, owned). }
    StyleDeclarations: TCssDeclarationBlock;
    PresentationHints: TCssDeclarationBlock;
    HintsParsed: Boolean;
    { The embedder's node, nil for a file's. }
    Host: Pointer;
    constructor CreateElement(const ANamespaceUri, ALocalName: string);
    constructor CreateText(const AText: string);
    { Frees the subtree. }
    destructor Destroy; override;
    procedure AppendChild(Child: TSvgNode);
    procedure SetAttribute(const ANamespaceUri, AName, AValue: string);
    function AttributeIndex(const AName: string; const ANamespaceUri: string = ''): Integer;
    { The attribute in no namespace, '' when absent. }
    function Attribute(const AName: string): string;
    function HasAttribute(const AName: string): Boolean;
    { href, or xlink:href when there is none. }
    function Href: string;
    function Id: string;
    function IsElement: Boolean; inline;
    { An SVG element of that kind. }
    function IsKind(Kind: TSvgElementKind): Boolean; inline;
    function FirstElementChild: TSvgNode;
    function NextElementSibling: TSvgNode;
    function PreviousElementSibling: TSvgNode;
    function LastElementChild: TSvgNode;
    function ClassAtoms: TCssAtomArray;
    { The text of the subtree (for <style>). }
    function TextContent: string;
    property Kind: TSvgNodeKind read FKind;
    property LocalName: string read FLocalName;
    property NamespaceUri: string read FNamespaceUri;
    property ElementKind: TSvgElementKind read FElementKind;
    property Text: string read FText write FText;
    property AttributeCount: Integer read FAttributeCount;
    property Attributes[Index: Integer]: TSvgAttribute read GetAttribute;
    property Parent: TSvgNode read FParent;
    property FirstChild: TSvgNode read FFirstChild;
    property LastChild: TSvgNode read FLastChild;
    property NextSibling: TSvgNode read FNextSibling;
    property PreviousSibling: TSvgNode read FPreviousSibling;
    { The computed style; the node holds a reference. }
    property Style: TCssComputedStyle read FStyle write SetStyle;
  end;

function ElementKindOf(const LocalName: string): TSvgElementKind;

implementation

const
  ElementNames: array[TSvgElementKind] of string = ('', 'svg', 'g', 'defs', 'use', 'symbol', 'rect', 'circle',
    'ellipse', 'line', 'polyline', 'polygon', 'path', 'text', 'tspan', 'textPath', 'image', 'linearGradient',
    'radialGradient', 'stop', 'pattern', 'clipPath', 'mask', 'style', 'marker', 'switch', 'a', 'title', 'desc',
    'metadata', 'foreignObject', 'filter');

function ElementKindOf(const LocalName: string): TSvgElementKind;
var
  Kind: TSvgElementKind;
begin
  for Kind := Succ(SvgUnknown) to High(TSvgElementKind) do
    if ElementNames[Kind] = LocalName then
      Exit(Kind);
  Result := SvgUnknown;
end;

constructor TSvgNode.CreateElement(const ANamespaceUri, ALocalName: string);
begin
  inherited Create;
  FKind := SvgElementNode;
  FLocalName := ALocalName;
  FNamespaceUri := ANamespaceUri;
  if ANamespaceUri = SvgNamespace then
    FElementKind := ElementKindOf(ALocalName)
  else
    FElementKind := SvgUnknown;
  LocalNameAtom := InternAtom(ALocalName);
  if ANamespaceUri <> '' then
    NamespaceAtom := InternAtom(ANamespaceUri)
  else
    NamespaceAtom := NoAtom;
end;

constructor TSvgNode.CreateText(const AText: string);
begin
  inherited Create;
  FKind := SvgTextNode;
  FText := AText;
end;

destructor TSvgNode.Destroy;
var
  Child, Next: TSvgNode;
begin
  Child := FFirstChild;
  while Child <> nil do
  begin
    Next := Child.FNextSibling;
    Child.Free;
    Child := Next;
  end;
  if FStyle <> nil then
    FStyle.Release;
  StyleDeclarations.Free;
  PresentationHints.Free;
  inherited Destroy;
end;

procedure TSvgNode.SetStyle(Value: TCssComputedStyle);
begin
  if Value = FStyle then
    Exit;
  if Value <> nil then
    Value.AddRef;
  if FStyle <> nil then
    FStyle.Release;
  FStyle := Value;
end;

function TSvgNode.GetAttribute(Index: Integer): TSvgAttribute;
begin
  Result := FAttributes[Index];
end;

procedure TSvgNode.AppendChild(Child: TSvgNode);
begin
  Child.FParent := Self;
  Child.FPreviousSibling := FLastChild;
  Child.FNextSibling := nil;
  if FLastChild <> nil then
    FLastChild.FNextSibling := Child
  else
    FFirstChild := Child;
  FLastChild := Child;
end;

procedure TSvgNode.SetAttribute(const ANamespaceUri, AName, AValue: string);
var
  Index: Integer;
begin
  Index := AttributeIndex(AName, ANamespaceUri);
  if Index >= 0 then
  begin
    FAttributes[Index].Value := AValue;
    Exit;
  end;
  if FAttributeCount = Length(FAttributes) then
    SetLength(FAttributes, 2 * FAttributeCount + 4);
  FAttributes[FAttributeCount].Name := AName;
  FAttributes[FAttributeCount].NamespaceUri := ANamespaceUri;
  FAttributes[FAttributeCount].Value := AValue;
  FAttributes[FAttributeCount].NameAtom := InternAtom(AName);
  if ANamespaceUri <> '' then
    FAttributes[FAttributeCount].NamespaceAtom := InternAtom(ANamespaceUri)
  else
    FAttributes[FAttributeCount].NamespaceAtom := NoAtom;
  Inc(FAttributeCount);
  FClassesKnown := False;
end;

function TSvgNode.AttributeIndex(const AName: string; const ANamespaceUri: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FAttributeCount - 1 do
    if (FAttributes[Index].Name = AName) and (FAttributes[Index].NamespaceUri = ANamespaceUri) then
      Exit(Index);
  Result := -1;
end;

function TSvgNode.Attribute(const AName: string): string;
var
  Index: Integer;
begin
  Index := AttributeIndex(AName);
  if Index >= 0 then
    Result := FAttributes[Index].Value
  else
    Result := '';
end;

function TSvgNode.HasAttribute(const AName: string): Boolean;
begin
  Result := AttributeIndex(AName) >= 0;
end;

function TSvgNode.Href: string;
var
  Index: Integer;
begin
  Index := AttributeIndex('href');
  if Index < 0 then
    Index := AttributeIndex('href', XlinkNamespace);
  if Index >= 0 then
    Result := Trim(FAttributes[Index].Value)
  else
    Result := '';
end;

function TSvgNode.Id: string;
begin
  Result := Attribute('id');
end;

function TSvgNode.IsElement: Boolean;
begin
  Result := FKind = SvgElementNode;
end;

function TSvgNode.IsKind(Kind: TSvgElementKind): Boolean;
begin
  Result := (FKind = SvgElementNode) and (FElementKind = Kind);
end;

function TSvgNode.FirstElementChild: TSvgNode;
begin
  Result := FFirstChild;
  while (Result <> nil) and not Result.IsElement do
    Result := Result.FNextSibling;
end;

function TSvgNode.LastElementChild: TSvgNode;
begin
  Result := FLastChild;
  while (Result <> nil) and not Result.IsElement do
    Result := Result.FPreviousSibling;
end;

function TSvgNode.NextElementSibling: TSvgNode;
begin
  Result := FNextSibling;
  while (Result <> nil) and not Result.IsElement do
    Result := Result.FNextSibling;
end;

function TSvgNode.PreviousElementSibling: TSvgNode;
begin
  Result := FPreviousSibling;
  while (Result <> nil) and not Result.IsElement do
    Result := Result.FPreviousSibling;
end;

function TSvgNode.ClassAtoms: TCssAtomArray;
var
  Value: string;
  Start, Index: Integer;
begin
  if not FClassesKnown then
  begin
    FClasses := nil;
    Value := Attribute('class');
    Index := 1;
    while Index <= Length(Value) do
    begin
      while (Index <= Length(Value)) and (Value[Index] in [' ', #9, #10, #12, #13]) do
        Inc(Index);
      Start := Index;
      while (Index <= Length(Value)) and not (Value[Index] in [' ', #9, #10, #12, #13]) do
        Inc(Index);
      if Index > Start then
      begin
        SetLength(FClasses, Length(FClasses) + 1);
        FClasses[High(FClasses)] := InternAtom(Copy(Value, Start, Index - Start));
      end;
    end;
    FClassesKnown := True;
  end;
  Result := FClasses;
end;

function TSvgNode.TextContent: string;
var
  Child: TSvgNode;
begin
  if FKind = SvgTextNode then
    Exit(FText);
  Result := '';
  Child := FFirstChild;
  while Child <> nil do
  begin
    Result := Result + Child.TextContent;
    Child := Child.FNextSibling;
  end;
end;

end.
