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
  Namespace ids: a node keeps its namespace and prefix together as one
  16 bit id into a process-wide table of (namespace, prefix) pairs, so an
  element or attribute needs two bytes for both. The common pairs have
  fixed ids (NamespaceHtml, NamespaceSvg, ...); others are added when
  first used.
}
unit Web.Namespaces;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms;

type
  TNamespaceId = Word;

const
  { No namespace, no prefix. }
  NamespaceNone = 0;
  NamespaceHtml = 1;
  NamespaceSvg = 2;
  NamespaceMathMl = 3;
  { The XLink namespace with the prefix "xlink". }
  NamespaceXLink = 4;
  { The XML namespace with the prefix "xml". }
  NamespaceXml = 5;
  { The XMLNS namespace with the prefix "xmlns" ("xmlns:xlink"). }
  NamespaceXmlnsPrefixed = 6;
  { The XMLNS namespace without a prefix (the attribute "xmlns"). }
  NamespaceXmlns = 7;

function NamespaceUri(Id: TNamespaceId): TAtom; inline;
function NamespacePrefix(Id: TNamespaceId): TAtom; inline;
{ The id of a (namespace, prefix) pair, added if new. }
function NamespaceIdOf(Uri, Prefix: TAtom): TNamespaceId;

implementation

uses
  SysUtils;

type
  TNamespacePair = record
    Uri: TAtom;
    Prefix: TAtom;
  end;

var
  Pairs: array of TNamespacePair;
  PairCount: Integer;

function NamespaceUri(Id: TNamespaceId): TAtom;
begin
  Result := Pairs[Id].Uri;
end;

function NamespacePrefix(Id: TNamespaceId): TAtom;
begin
  Result := Pairs[Id].Prefix;
end;

function NamespaceIdOf(Uri, Prefix: TAtom): TNamespaceId;
var
  Index: Integer;
begin
  for Index := 1 to PairCount do
    if (Pairs[Index - 1].Uri = Uri) and (Pairs[Index - 1].Prefix = Prefix) then
      Exit(Index - 1);
  if PairCount > High(TNamespaceId) then
    raise Exception.Create('Too many namespace and prefix pairs');
  if PairCount >= Length(Pairs) then
    SetLength(Pairs, Length(Pairs) * 2);
  Pairs[PairCount].Uri := Uri;
  Pairs[PairCount].Prefix := Prefix;
  Result := PairCount;
  Inc(PairCount);
end;

procedure AddPair(Uri, Prefix: TAtom);
begin
  Pairs[PairCount].Uri := Uri;
  Pairs[PairCount].Prefix := Prefix;
  Inc(PairCount);
end;

initialization
  SetLength(Pairs, 32);
  PairCount := 0;
  AddPair(AtomNone, AtomNone);
  AddPair(AtomHtmlNamespace, AtomNone);
  AddPair(AtomSvgNamespace, AtomNone);
  AddPair(AtomMathMlNamespace, AtomNone);
  AddPair(AtomXLinkNamespace, AtomXlink);
  AddPair(AtomXmlNamespace, AtomXml);
  AddPair(AtomXmlnsNamespace, AtomXmlns);
  AddPair(AtomXmlnsNamespace, AtomNone);
end.
