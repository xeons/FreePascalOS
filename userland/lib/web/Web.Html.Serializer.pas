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
  The HTML fragment serialization algorithm (innerHTML, outerHTML):
  elements by local name (qualified name outside HTML, SVG and MathML),
  attributes with their xml:, xmlns: and xlink: prefixes, void elements
  without end tags, template contents, raw text elements' text as it is,
  and the escaping of text and attribute values (attribute values also
  escape < and >, as the standard does since 2025). It walks the tree
  without recursion.
}
unit Web.Html.Serializer;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

{ The serialization of Node's children (a template's: its contents). }
function SerializeChildren(Node: TNode): string;
{ The serialization of Node itself (outerHTML). }
function SerializeNode(Node: TNode): string;
{ getHTML(): Node's children, with the shadow roots that are
  serializable as declarative shadow root templates when
  SerializableShadowRoots (HTML Standard: serializing HTML fragments). }
function SerializeChildrenWithShadowRoots(Node: TNode; SerializableShadowRoots: Boolean): string;

implementation

uses
  Web.Atoms,
  Web.Namespaces,
  Web.TextBuffers,
  Web.Html.ElementKinds;

procedure AppendEscaped(Output: TTextBuffer; const Text: string; AttributeMode: Boolean);
var
  Index, RunStart: SizeInt;
  Value: Char;
begin
  RunStart := 1;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Value := Text[Index];
    if (Value = '&') or (Value = '<') or (Value = '>') or (AttributeMode and (Value = '"')) or
      ((Value = #$C2) and (Index < Length(Text)) and (Text[Index + 1] = #$A0)) then
    begin
      Output.Append(@Text[RunStart], Index - RunStart);
      case Value of
        '&': Output.AppendString('&amp;');
        '<': Output.AppendString('&lt;');
        '>': Output.AppendString('&gt;');
        '"': Output.AppendString('&quot;');
      else
        begin
          Output.AppendString('&nbsp;');
          Inc(Index);
        end;
      end;
      Inc(Index);
      RunStart := Index;
      Continue;
    end;
    Inc(Index);
  end;
  if RunStart <= Length(Text) then
    Output.Append(@Text[RunStart], Length(Text) - RunStart + 1);
end;

function TagNameOf(Element: TElement): string;
var
  Namespace: TAtom;
begin
  Namespace := Element.NamespaceAtom;
  if (Namespace = AtomHtmlNamespace) or (Namespace = AtomSvgNamespace) or (Namespace = AtomMathMlNamespace) then
    Result := Element.LocalName
  else
    Result := Element.TagName;
end;

function SerializedAttributeName(const Attribute: TAttributeRecord): string;
var
  Namespace: TAtom;
  PrefixAtom: TAtom;
begin
  Namespace := NamespaceUri(Attribute.NamespaceId);
  if Namespace = AtomNone then
    Result := NameOfAtom(Attribute.LocalName)
  else if Namespace = AtomXmlNamespace then
    Result := 'xml:' + NameOfAtom(Attribute.LocalName)
  else if Namespace = AtomXmlnsNamespace then
  begin
    if Attribute.LocalName = AtomXmlns then
      Result := 'xmlns'
    else
      Result := 'xmlns:' + NameOfAtom(Attribute.LocalName);
  end
  else if Namespace = AtomXLinkNamespace then
    Result := 'xlink:' + NameOfAtom(Attribute.LocalName)
  else
  begin
    PrefixAtom := NamespacePrefix(Attribute.NamespaceId);
    if PrefixAtom = AtomNone then
      Result := NameOfAtom(Attribute.LocalName)
    else
      Result := NameOfAtom(PrefixAtom) + ':' + NameOfAtom(Attribute.LocalName);
  end;
end;

function IsRawTextParent(Node: TNode): Boolean;
var
  Element: TElement;
begin
  Result := False;
  if (Node = nil) or (Node.NodeType <> NodeTypeElement) then
    Exit;
  Element := TElement(Node);
  if not Element.IsHtml then
    Exit;
  case Element.LocalNameAtom of
    AtomStyle, AtomScript, AtomXmp, AtomIframe, AtomNoembed, AtomNoframes, AtomPlaintext:
      Result := True;
    AtomNoscript:
      Result := Element.NodeDocument.ScriptingEnabled;
  end;
end;

procedure AppendStartTag(Output: TTextBuffer; Element: TElement);
var
  Index: Integer;
begin
  Output.AppendChar('<');
  Output.AppendString(TagNameOf(Element));
  for Index := 1 to Element.AttributeCount do
  begin
    Output.AppendChar(' ');
    Output.AppendString(SerializedAttributeName(Element.AttributeAt(Index - 1)^));
    Output.AppendString('="');
    AppendEscaped(Output, Element.AttributeAt(Index - 1)^.Value, True);
    Output.AppendChar('"');
  end;
  { An element made with an is value keeps it (HTML: serializing). }
  if (Element.IsValue <> '') and not Element.HasAttributeAtom(AtomIs) then
  begin
    Output.AppendString(' is="');
    AppendEscaped(Output, Element.IsValue, True);
    Output.AppendChar('"');
  end;
  Output.AppendChar('>');
end;

{ The children to serialize: a template's are its contents'. }
function FirstSerializedChild(Node: TNode): TNode;
begin
  if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomTemplate) then
    Result := TElement(Node).TemplateContent.FirstChild
  else
    Result := Node.FirstChild;
end;

procedure AppendLeaf(Output: TTextBuffer; Node: TNode);
begin
  case Node.NodeType of
    NodeTypeText, NodeTypeCDataSection:
      if IsRawTextParent(Node.ParentNode) then
        Output.AppendString(TCharacterData(Node).Data)
      else
        AppendEscaped(Output, TCharacterData(Node).Data, False);
    NodeTypeComment:
      begin
        Output.AppendString('<!--');
        Output.AppendString(TCharacterData(Node).Data);
        Output.AppendString('-->');
      end;
    NodeTypeProcessingInstruction:
      begin
        Output.AppendString('<?');
        Output.AppendString(TProcessingInstruction(Node).Target);
        Output.AppendChar(' ');
        Output.AppendString(TCharacterData(Node).Data);
        Output.AppendChar('>');
      end;
    NodeTypeDocumentType:
      begin
        Output.AppendString('<!DOCTYPE ');
        Output.AppendString(TDocumentType(Node).Name);
        Output.AppendChar('>');
      end;
  end;
end;

procedure SerializeInto(Output: TTextBuffer; Root: TNode; IncludeRoot: Boolean;
  SerializableShadowRoots: Boolean = False); forward;

{ A host's serializable shadow root as a <template shadowrootmode>. }
procedure AppendShadowRoot(Output: TTextBuffer; Shadow: TShadowRoot);
begin
  Output.AppendString('<template shadowrootmode="');
  Output.AppendString(Shadow.ModeText);
  Output.AppendChar('"');
  if Shadow.DelegatesFocus then
    Output.AppendString(' shadowrootdelegatesfocus=""');
  if Shadow.Serializable then
    Output.AppendString(' shadowrootserializable=""');
  if Shadow.Clonable then
    Output.AppendString(' shadowrootclonable=""');
  Output.AppendChar('>');
  SerializeInto(Output, Shadow, False, True);
  Output.AppendString('</template>');
end;

{ Serializes the children of Root (or, with IncludeRoot, Root itself). }
procedure SerializeInto(Output: TTextBuffer; Root: TNode; IncludeRoot: Boolean;
  SerializableShadowRoots: Boolean);
var
  Node, Child, Parent: TNode;
  Stack: TNodeArray;
  Depth: Integer;

  procedure Enter(Element: TElement);
  begin
    AppendStartTag(Output, Element);
    if SerializableShadowRoots and (Element.ShadowRoot <> nil) and Element.ShadowRoot.Serializable then
      AppendShadowRoot(Output, Element.ShadowRoot);
  end;

  procedure Leave(Element: TElement);
  begin
    Output.AppendString('</');
    Output.AppendString(TagNameOf(Element));
    Output.AppendChar('>');
  end;

begin
  { An explicit stack of the elements entered, since a template's
    children are not its contents' parent's. }
  Stack := nil;
  Depth := 0;
  if IncludeRoot then
  begin
    if Root.NodeType <> NodeTypeElement then
    begin
      AppendLeaf(Output, Root);
      Exit;
    end;
    Enter(TElement(Root));
    if SerializesAsVoid(TElement(Root)) then
      Exit;
  end;
  SetLength(Stack, 16);
  Stack[0] := Root;
  Depth := 1;
  if not IncludeRoot and SerializableShadowRoots and (Root.NodeType = NodeTypeElement) and
    (TElement(Root).ShadowRoot <> nil) and TElement(Root).ShadowRoot.Serializable then
    AppendShadowRoot(Output, TElement(Root).ShadowRoot);
  Node := FirstSerializedChild(Root);
  while Depth > 0 do
  begin
    if Node = nil then
    begin
      { The children of Stack[Depth - 1] are done. }
      Dec(Depth);
      Parent := Stack[Depth];
      if (Depth > 0) or IncludeRoot then
        Leave(TElement(Parent));
      if Depth = 0 then
        Break;
      Node := Parent.NextSibling;
      Continue;
    end;
    if Node.NodeType = NodeTypeElement then
    begin
      Enter(TElement(Node));
      if not SerializesAsVoid(TElement(Node)) then
      begin
        Child := FirstSerializedChild(Node);
        if Depth >= Length(Stack) then
          SetLength(Stack, Depth * 2);
        Stack[Depth] := Node;
        Inc(Depth);
        Node := Child;
        Continue;
      end;
    end
    else
      AppendLeaf(Output, Node);
    Node := Node.NextSibling;
  end;
end;

function SerializeChildren(Node: TNode): string;
var
  Output: TTextBuffer;
begin
  Output := TTextBuffer.Create;
  try
    SerializeInto(Output, Node, False);
    Result := Output.TakeText;
  finally
    Output.Free;
  end;
end;

function SerializeChildrenWithShadowRoots(Node: TNode; SerializableShadowRoots: Boolean): string;
var
  Output: TTextBuffer;
begin
  Output := TTextBuffer.Create;
  try
    SerializeInto(Output, Node, False, SerializableShadowRoots);
    Result := Output.TakeText;
  finally
    Output.Free;
  end;
end;

function SerializeNode(Node: TNode): string;
var
  Output: TTextBuffer;
begin
  Output := TTextBuffer.Create;
  try
    SerializeInto(Output, Node, True);
    Result := Output.TakeText;
  finally
    Output.Free;
  end;
end;

end.
