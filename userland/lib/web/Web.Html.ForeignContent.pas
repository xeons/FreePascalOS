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
  SVG and MathML in HTML: the tag name and attribute adjustments the
  tree builder makes for foreign elements (the tokenizer lowercases
  names; SVG keeps camelCase ones) and the foreign attributes that get
  a namespace (xlink:href and friends).
}
unit Web.Html.ForeignContent;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms,
  Web.Namespaces,
  Web.Html.Tokens;

{ The SVG element name for a lower case tag name (clippath: clipPath). }
function AdjustSvgTagName(Name: TAtom): TAtom;
procedure AdjustSvgAttributes(var Token: TToken);
procedure AdjustMathMlAttributes(var Token: TToken);
procedure AdjustForeignAttributes(var Token: TToken);

implementation

type
  TAtomPair = record
    From: TAtom;
    Target: TAtom;
  end;

  TForeignAttribute = record
    Name: TAtom;
    LocalName: TAtom;
    NamespaceId: TNamespaceId;
  end;

const
  SvgTagNames: array[0..36] of string = (
    'altGlyph', 'altGlyphDef', 'altGlyphItem', 'animateColor', 'animateMotion', 'animateTransform', 'clipPath',
    'feBlend', 'feColorMatrix', 'feComponentTransfer', 'feComposite', 'feConvolveMatrix', 'feDiffuseLighting',
    'feDisplacementMap', 'feDistantLight', 'feDropShadow', 'feFlood', 'feFuncA', 'feFuncB', 'feFuncG', 'feFuncR',
    'feGaussianBlur', 'feImage', 'feMerge', 'feMergeNode', 'feMorphology', 'feOffset', 'fePointLight',
    'feSpecularLighting', 'feSpotLight', 'feTile', 'feTurbulence', 'foreignObject', 'glyphRef', 'linearGradient',
    'radialGradient', 'textPath');

  SvgAttributeNames: array[0..57] of string = (
    'attributeName', 'attributeType', 'baseFrequency', 'baseProfile', 'calcMode', 'clipPathUnits',
    'diffuseConstant', 'edgeMode', 'filterUnits', 'glyphRef', 'gradientTransform', 'gradientUnits', 'kernelMatrix',
    'kernelUnitLength', 'keyPoints', 'keySplines', 'keyTimes', 'lengthAdjust', 'limitingConeAngle', 'markerHeight',
    'markerUnits', 'markerWidth', 'maskContentUnits', 'maskUnits', 'numOctaves', 'pathLength',
    'patternContentUnits', 'patternTransform', 'patternUnits', 'pointsAtX', 'pointsAtY', 'pointsAtZ',
    'preserveAlpha', 'preserveAspectRatio', 'primitiveUnits', 'refX', 'refY', 'repeatCount', 'repeatDur',
    'requiredExtensions', 'requiredFeatures', 'specularConstant', 'specularExponent', 'spreadMethod',
    'startOffset', 'stdDeviation', 'stitchTiles', 'surfaceScale', 'systemLanguage', 'tableValues', 'targetX',
    'targetY', 'textLength', 'viewBox', 'viewTarget', 'xChannelSelector', 'yChannelSelector', 'zoomAndPan');

var
  SvgTagPairs: array of TAtomPair;
  SvgAttributePairs: array of TAtomPair;
  ForeignAttributes: array of TForeignAttribute;

function LookUpPair(const Pairs: array of TAtomPair; Name: TAtom; out Target: TAtom): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Pairs) do
    if Pairs[Index].From = Name then
    begin
      Target := Pairs[Index].Target;
      Exit(True);
    end;
  Target := Name;
  Result := False;
end;

function AdjustSvgTagName(Name: TAtom): TAtom;
begin
  LookUpPair(SvgTagPairs, Name, Result);
end;

procedure AdjustSvgAttributes(var Token: TToken);
var
  Index: Integer;
  Target: TAtom;
begin
  for Index := 1 to Token.AttributeCount do
    if LookUpPair(SvgAttributePairs, Token.Attributes[Index - 1].LocalName, Target) then
      Token.Attributes[Index - 1].LocalName := Target;
end;

procedure AdjustMathMlAttributes(var Token: TToken);
var
  Index: Integer;
begin
  for Index := 1 to Token.AttributeCount do
    if Token.Attributes[Index - 1].LocalName = AtomDefinitionUrlLowerCase then
      Token.Attributes[Index - 1].LocalName := AtomDefinitionUrl;
end;

procedure AdjustForeignAttributes(var Token: TToken);
var
  Index, Entry: Integer;
begin
  for Index := 1 to Token.AttributeCount do
    for Entry := 0 to High(ForeignAttributes) do
      if Token.Attributes[Index - 1].Name = ForeignAttributes[Entry].Name then
      begin
        Token.Attributes[Index - 1].LocalName := ForeignAttributes[Entry].LocalName;
        Token.Attributes[Index - 1].NamespaceId := ForeignAttributes[Entry].NamespaceId;
        Break;
      end;
end;

procedure BuildPairs(const Names: array of string; var Pairs: array of TAtomPair);
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
  begin
    Pairs[Index].From := Atomize(AsciiLowerCase(Names[Index]));
    Pairs[Index].Target := Atomize(Names[Index]);
  end;
end;

procedure AddForeignAttribute(const Name, LocalName: string; Namespace: TNamespaceId);
begin
  SetLength(ForeignAttributes, Length(ForeignAttributes) + 1);
  ForeignAttributes[High(ForeignAttributes)].Name := Atomize(Name);
  ForeignAttributes[High(ForeignAttributes)].LocalName := Atomize(LocalName);
  ForeignAttributes[High(ForeignAttributes)].NamespaceId := Namespace;
end;

initialization
  SetLength(SvgTagPairs, Length(SvgTagNames));
  BuildPairs(SvgTagNames, SvgTagPairs);
  SetLength(SvgAttributePairs, Length(SvgAttributeNames));
  BuildPairs(SvgAttributeNames, SvgAttributePairs);
  AddForeignAttribute('xlink:actuate', 'actuate', NamespaceXLink);
  AddForeignAttribute('xlink:arcrole', 'arcrole', NamespaceXLink);
  AddForeignAttribute('xlink:href', 'href', NamespaceXLink);
  AddForeignAttribute('xlink:role', 'role', NamespaceXLink);
  AddForeignAttribute('xlink:show', 'show', NamespaceXLink);
  AddForeignAttribute('xlink:title', 'title', NamespaceXLink);
  AddForeignAttribute('xlink:type', 'type', NamespaceXLink);
  AddForeignAttribute('xml:lang', 'lang', NamespaceXml);
  AddForeignAttribute('xml:space', 'space', NamespaceXml);
  AddForeignAttribute('xmlns', 'xmlns', NamespaceXmlns);
  AddForeignAttribute('xmlns:xlink', 'xlink', NamespaceXmlnsPrefixed);
end.
