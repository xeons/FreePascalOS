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
  A tree in the html5lib tree-construction test format: one line per
  node, "| " and two spaces per level, elements as <name> (<svg name>,
  <math name> for foreign ones), attributes sorted by name under their
  element, text in quotes, comments as <!-- text -->, doctypes with
  their identifiers, and a template's contents under a "content" line.
  Used by htmldump and the tests.
}
unit Web.Html.TreeDump;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

{ The lines for the children of Node, each ending in a line feed. }
function DumpTree(Node: TNode): string;

implementation

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.TextBuffers;

function ElementLabel(Element: TElement): string;
var
  Namespace: TAtom;
begin
  Namespace := Element.NamespaceAtom;
  if Namespace = AtomSvgNamespace then
    Result := 'svg ' + Element.LocalName
  else if Namespace = AtomMathMlNamespace then
    Result := 'math ' + Element.LocalName
  else if (Namespace = AtomHtmlNamespace) or (Namespace = AtomNone) then
    Result := Element.LocalName
  else
    Result := NameOfAtom(Namespace) + ' ' + Element.LocalName;
end;

function AttributeLabel(const Attribute: TAttributeRecord): string;
var
  Namespace: TAtom;
begin
  Namespace := NamespaceUri(Attribute.NamespaceId);
  if Namespace = AtomXLinkNamespace then
    Result := 'xlink ' + NameOfAtom(Attribute.LocalName)
  else if Namespace = AtomXmlNamespace then
    Result := 'xml ' + NameOfAtom(Attribute.LocalName)
  else if Namespace = AtomXmlnsNamespace then
    Result := 'xmlns ' + NameOfAtom(Attribute.LocalName)
  else if Namespace = AtomNone then
    Result := NameOfAtom(Attribute.LocalName)
  else
    Result := NameOfAtom(Namespace) + ' ' + NameOfAtom(Attribute.LocalName);
end;

procedure AppendLine(Output: TTextBuffer; Depth: Integer; const Text: string);
var
  Index: Integer;
begin
  Output.AppendString('| ');
  for Index := 1 to Depth do
    Output.AppendString('  ');
  Output.AppendString(Text);
  Output.AppendChar(#10);
end;

procedure DumpChildren(Output: TTextBuffer; Parent: TNode; Depth: Integer); forward;

procedure DumpNode(Output: TTextBuffer; Node: TNode; Depth: Integer);
var
  Element: TElement;
  Labels, Lines: array of string;
  Index, Position: Integer;
  Doctype: TDocumentType;
  Text, SavedLabel, SavedLine: string;
begin
  case Node.NodeType of
    NodeTypeElement:
      begin
        Element := TElement(Node);
        AppendLine(Output, Depth, '<' + ElementLabel(Element) + '>');
        { Attributes sorted by name, byte by byte (an insertion sort: an
          element has few). }
        Labels := nil;
        Lines := nil;
        SetLength(Labels, Element.AttributeCount);
        SetLength(Lines, Element.AttributeCount);
        for Index := 1 to Element.AttributeCount do
        begin
          SavedLabel := AttributeLabel(Element.AttributeAt(Index - 1)^);
          SavedLine := SavedLabel + '="' + Element.AttributeAt(Index - 1)^.Value + '"';
          Position := Index - 1;
          while (Position > 0) and (CompareStr(Labels[Position - 1], SavedLabel) > 0) do
          begin
            Labels[Position] := Labels[Position - 1];
            Lines[Position] := Lines[Position - 1];
            Dec(Position);
          end;
          Labels[Position] := SavedLabel;
          Lines[Position] := SavedLine;
        end;
        for Index := 1 to Length(Lines) do
          AppendLine(Output, Depth + 1, Lines[Index - 1]);
        if Element.IsHtmlElement(AtomTemplate) then
        begin
          AppendLine(Output, Depth + 1, 'content');
          DumpChildren(Output, Element.TemplateContent, Depth + 2);
        end;
        DumpChildren(Output, Element, Depth + 1);
      end;
    NodeTypeText, NodeTypeCDataSection:
      AppendLine(Output, Depth, '"' + TCharacterData(Node).Data + '"');
    NodeTypeComment:
      AppendLine(Output, Depth, '<!-- ' + TCharacterData(Node).Data + ' -->');
    NodeTypeProcessingInstruction:
      AppendLine(Output, Depth, '<?' + TProcessingInstruction(Node).Target + ' ' + TCharacterData(Node).Data + '>');
    NodeTypeDocumentType:
      begin
        Doctype := TDocumentType(Node);
        Text := '<!DOCTYPE ' + Doctype.Name;
        if (Doctype.PublicId <> '') or (Doctype.SystemId <> '') then
          Text := Text + ' "' + Doctype.PublicId + '" "' + Doctype.SystemId + '"';
        AppendLine(Output, Depth, Text + '>');
      end;
  end;
end;

procedure DumpChildren(Output: TTextBuffer; Parent: TNode; Depth: Integer);
var
  Child: TNode;
begin
  Child := Parent.FirstChild;
  while Child <> nil do
  begin
    DumpNode(Output, Child, Depth);
    Child := Child.NextSibling;
  end;
end;

function DumpTree(Node: TNode): string;
var
  Output: TTextBuffer;
begin
  Output := TTextBuffer.Create;
  try
    DumpChildren(Output, Node, 0);
    Result := Output.TakeText;
  finally
    Output.Free;
  end;
end;

end.
