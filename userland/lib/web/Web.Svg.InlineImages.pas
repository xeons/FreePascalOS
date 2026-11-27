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
  Inline <svg> in HTML documents: the element's subtree drawn by libsvg,
  as the image of its replaced box.

  The DOM's SVG elements are copied into libsvg's nodes (names,
  attributes, text) with the styles libweb computed for them (page
  sheets, presentation attributes as hints, inheritance from the page),
  so one renderer draws SVG files and inline SVG alike. libsvg asks
  back for what the copy lacks: styles of content a <use> instantiates
  (libweb's style engine, the use's style as the parent), glyphs for
  text (libweb's font matching), and elements a <use> or a paint names
  that are elsewhere in the page (a sprite sheet of symbols), which are
  found by id and copied too.

  The images are kept per element and made again when the subtree or
  any of its styles changed (a signature of its nodes, attributes, text
  and style objects), and drawn at the size and scale the page shows
  them (scalable images, drawn when painted). An image that was
  replaced lives until the next replacement, so a display list made
  before still finds it.
}
unit Web.Svg.InlineImages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Web.Dom,
  Web.Style.Resolver;

type
  TInlineSvgEntry = record
    Element: TElement;
    Signature: QWord;
    Image: TImage;
    Retired: TImage;
  end;

  TInlineSvgImages = class
  private
    FEntries: array of TInlineSvgEntry;
    FCount: Integer;
    FLookups: Integer;
    procedure DropDisconnected;
  public
    destructor Destroy; override;
    { The image for an outermost <svg> element (kept here), made again
      when its subtree changed; nil if it cannot be made. }
    function ImageFor(Element: TElement; Styler: TDocumentStyler): TImage;
  end;

{ An <svg> element in the SVG namespace whose parent is not SVG: one
  drawn as a replaced box. }
function IsOutermostSvgElement(Element: TElement): Boolean;

implementation

uses
  Font.Outlines,
  Css.ComputedStyle,
  Web.Atoms,
  Web.Namespaces,
  Web.Style.NodeData,
  Web.Text.Fonts,
  Web.Text.FontInstances,
  Svg.Nodes,
  Svg.Styling,
  Svg.Fonts,
  Svg.Document,
  Svg.Images;

type
  TWebSvgStyleResolver = class(TSvgStyleResolver)
  private
    FStyler: TDocumentStyler;
  public
    constructor Create(Styler: TDocumentStyler);
    function ResolveStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle; override;
  end;

  TWebSvgFontSource = class(TSvgFontSource)
  public
    function GlyphFor(Style: TCssComputedStyle; CodePoint: LongWord; out Font: TOutlineFont;
      out Glyph: LongWord): Boolean; override;
  end;

  { What a document built from the DOM keeps: its resolver, and where
    to look for elements outside the copied subtree. }
  TInlineSvgDocument = class(TSvgDocument)
  private
    FResolver: TWebSvgStyleResolver;
    FPage: TDocument;
    function FindExternal(Document: TSvgDocument; const Id: string): TSvgNode;
  public
    constructor CreateFor(RootNode: TSvgNode; Page: TDocument; Styler: TDocumentStyler);
    destructor Destroy; override;
  end;

var
  FontSource: TWebSvgFontSource;

const
  MaximumCopiedNodes = 200000;

function IsOutermostSvgElement(Element: TElement): Boolean;
var
  Parent: TElement;
begin
  Result := False;
  if (not Element.IsSvg) or (NameOfAtom(Element.LocalNameAtom) <> 'svg') then
    Exit;
  Parent := Element.ParentElement;
  Result := (Parent = nil) or (not Parent.IsSvg);
end;

{ ---- copying the DOM ---- }

function CopyElement(Element: TElement; var Budget: Integer): TSvgNode;
var
  Index: Integer;
  Attribute: PAttributeRecord;
  Child: TNode;
  ChildCopy: TSvgNode;
  NamespaceText: string;
begin
  Dec(Budget);
  Result := TSvgNode.CreateElement(Element.NamespaceUri, NameOfAtom(Element.LocalNameAtom));
  Result.Host := Element;
  Result.Style := StyleOf(Element);
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    if Attribute^.NamespaceId = NamespaceNone then
      NamespaceText := ''
    else
      NamespaceText := NameOfAtom(NamespaceUri(Attribute^.NamespaceId));
    Result.SetAttribute(NamespaceText, NameOfAtom(Attribute^.LocalName), Attribute^.Value);
  end;
  { What is inside foreignObject is HTML, which libsvg does not draw. }
  if Result.ElementKind = SvgForeignObject then
    Exit;
  Child := Element.FirstChild;
  while (Child <> nil) and (Budget > 0) do
  begin
    if Child.IsElement then
    begin
      if TElement(Child).IsSvg then
      begin
        ChildCopy := CopyElement(TElement(Child), Budget);
        Result.AppendChild(ChildCopy);
      end;
    end
    else if Child.IsText then
      Result.AppendChild(TSvgNode.CreateText(TCharacterData(Child).Data));
    Child := Child.NextSibling;
  end;
end;

function MixSignature(Signature, Value: QWord): QWord; inline;
begin
  Result := (Signature xor Value) * QWord(1099511628211);
end;

function TextSignature(const Text: string): QWord;
var
  Index: Integer;
begin
  Result := QWord(14695981039346656037);
  for Index := 1 to Length(Text) do
    Result := MixSignature(Result, Ord(Text[Index]));
end;

{ Changes when anything drawn could change: the nodes, attributes, text
  and computed styles of the subtree. }
function SubtreeSignature(Element: TElement; var Budget: Integer): QWord;
var
  Index: Integer;
  Attribute: PAttributeRecord;
  Child: TNode;
  Style: TCssComputedStyle;
begin
  Dec(Budget);
  Result := MixSignature(QWord(14695981039346656037), QWord(PtrUInt(Element)));
  Style := StyleOf(Element);
  if Style <> nil then
    Result := MixSignature(Result, Style.Serial);
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    Result := MixSignature(Result, Attribute^.LocalName);
    Result := MixSignature(Result, TextSignature(Attribute^.Value));
  end;
  Child := Element.FirstChild;
  while (Child <> nil) and (Budget > 0) do
  begin
    if Child.IsElement and (TElement(Child).IsSvg) then
      Result := MixSignature(Result, SubtreeSignature(TElement(Child), Budget))
    else if Child.IsText then
      Result := MixSignature(Result, TextSignature(TCharacterData(Child).Data));
    Child := Child.NextSibling;
  end;
end;

{ ---- what libsvg asks back ---- }

constructor TWebSvgStyleResolver.Create(Styler: TDocumentStyler);
begin
  inherited Create;
  FStyler := Styler;
end;

function TWebSvgStyleResolver.ResolveStyle(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  if (Node.Host = nil) or (FStyler = nil) then
  begin
    if Node.Style <> nil then
      Exit(Node.Style.AddRef);
    Exit(nil);
  end;
  Result := FStyler.ResolveStyleUnder(TElement(Node.Host), ParentStyle);
end;

function TWebSvgFontSource.GlyphFor(Style: TCssComputedStyle; CodePoint: LongWord; out Font: TOutlineFont;
  out Glyph: LongWord): Boolean;
var
  Face: TFontFaceEntry;
begin
  Font := nil;
  Glyph := 0;
  Face := TextFontOf(Style).FaceFor(CodePoint);
  if Face = nil then
    Exit(False);
  Font := Face.Font;
  if Font = nil then
    Exit(False);
  Glyph := Face.GlyphOf(CodePoint);
  Result := Glyph <> 0;
end;

constructor TInlineSvgDocument.CreateFor(RootNode: TSvgNode; Page: TDocument; Styler: TDocumentStyler);
begin
  inherited Create(RootNode);
  FPage := Page;
  FResolver := TWebSvgStyleResolver.Create(Styler);
  StyleResolver := FResolver;
  FontSource := Web.Svg.InlineImages.FontSource;
  OnFindExternal := @FindExternal;
end;

destructor TInlineSvgDocument.Destroy;
begin
  inherited Destroy;
  FResolver.Free;
end;

function TInlineSvgDocument.FindExternal(Document: TSvgDocument; const Id: string): TSvgNode;
var
  Element: TElement;
  Budget: Integer;
begin
  Result := nil;
  if FPage = nil then
    Exit;
  Element := FPage.GetElementById(Id);
  if (Element = nil) or (not Element.IsSvg) then
    Exit;
  Budget := MaximumCopiedNodes;
  Result := CopyElement(Element, Budget);
end;

{ ---- the cache ---- }

destructor TInlineSvgImages.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
  begin
    FEntries[Index].Image.Free;
    FEntries[Index].Retired.Free;
    FEntries[Index].Element.Release;
  end;
  inherited Destroy;
end;

procedure TInlineSvgImages.DropDisconnected;
var
  Index: Integer;
begin
  Index := 0;
  while Index < FCount do
  begin
    if not FEntries[Index].Element.IsConnected then
    begin
      FEntries[Index].Image.Free;
      FEntries[Index].Retired.Free;
      FEntries[Index].Element.Release;
      FEntries[Index] := FEntries[FCount - 1];
      Dec(FCount);
    end
    else
      Inc(Index);
  end;
end;

function BuildImage(Element: TElement; Styler: TDocumentStyler): TImage;
var
  Root: TSvgNode;
  Document: TInlineSvgDocument;
  Budget: Integer;
begin
  Result := nil;
  if StyleOf(Element) = nil then
    Exit;
  Budget := MaximumCopiedNodes;
  Root := CopyElement(Element, Budget);
  Document := TInlineSvgDocument.CreateFor(Root, Element.NodeDocument, Styler);
  try
    Result := TSvgImage.CreateDeferred(Document);
  except
    Document.Free;
    Result := nil;
  end;
end;

function TInlineSvgImages.ImageFor(Element: TElement; Styler: TDocumentStyler): TImage;
var
  Index: Integer;
  Signature: QWord;
  Budget: Integer;
begin
  Inc(FLookups);
  if (FLookups and 63) = 0 then
    DropDisconnected;
  Budget := MaximumCopiedNodes;
  Signature := SubtreeSignature(Element, Budget);
  for Index := 0 to FCount - 1 do
    if FEntries[Index].Element = Element then
    begin
      if FEntries[Index].Signature <> Signature then
      begin
        FEntries[Index].Retired.Free;
        FEntries[Index].Retired := FEntries[Index].Image;
        FEntries[Index].Image := BuildImage(Element, Styler);
        FEntries[Index].Signature := Signature;
      end;
      Exit(FEntries[Index].Image);
    end;
  if FCount = Length(FEntries) then
    SetLength(FEntries, 2 * FCount + 4);
  FEntries[FCount].Element := Element;
  Element.Retain;
  FEntries[FCount].Signature := Signature;
  FEntries[FCount].Image := BuildImage(Element, Styler);
  FEntries[FCount].Retired := nil;
  Result := FEntries[FCount].Image;
  Inc(FCount);
end;

initialization
  FontSource := TWebSvgFontSource.Create;

finalization
  FontSource.Free;

end.
