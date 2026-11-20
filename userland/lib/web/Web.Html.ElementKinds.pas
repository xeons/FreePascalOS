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
  The element categories the tree builder decides by: special elements,
  formatting elements, those with implied end tags, scope boundaries,
  integration points, void elements. HTML names are looked up in a
  table indexed by atom (all of them are well-known atoms).
}
unit Web.Html.ElementKinds;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms,
  Web.Namespaces,
  Web.Dom;

const
  KindSpecial = $0001;
  KindFormatting = $0002;
  KindImpliedEndTag = $0004;
  KindImpliedEndTagThorough = $0008;
  KindScopeBoundary = $0010;
  KindVoid = $0020;
  KindHeading = $0040;

type
  TScope = (ScopeDefault, ScopeListItem, ScopeButton, ScopeTable, ScopeSelect);

function HtmlKinds(Name: TAtom): Word; inline;
function IsSpecialElement(Element: TElement): Boolean;
function IsFormattingName(Name: TAtom): Boolean; inline;
function IsHeadingName(Name: TAtom): Boolean; inline;
{ Whether an element ends a search for Name-like elements in a scope. }
function IsScopeBoundary(Element: TElement; Scope: TScope): Boolean;
function IsMathMlTextIntegrationPoint(Element: TElement): Boolean;
function IsHtmlIntegrationPoint(Element: TElement): Boolean;
{ Void elements and those that serialize as void. }
function SerializesAsVoid(Element: TElement): Boolean;

implementation

var
  KindTable: array[0..WellKnownAtomCount] of Word;

function HtmlKinds(Name: TAtom): Word;
begin
  if Name <= WellKnownAtomCount then
    Result := KindTable[Name]
  else
    Result := 0;
end;

function IsElementIn(Element: TElement; Namespace: TAtom; Name: TAtom): Boolean; inline;
begin
  Result := (Element.LocalNameAtom = Name) and (Element.NamespaceAtom = Namespace);
end;

function IsSpecialElement(Element: TElement): Boolean;
var
  Namespace: TAtom;
  Name: TAtom;
begin
  Namespace := Element.NamespaceAtom;
  Name := Element.LocalNameAtom;
  if Namespace = AtomHtmlNamespace then
    Result := (HtmlKinds(Name) and KindSpecial) <> 0
  else if Namespace = AtomMathMlNamespace then
    Result := (Name = AtomMi) or (Name = AtomMo) or (Name = AtomMn) or (Name = AtomMs) or (Name = AtomMtext) or
      (Name = AtomAnnotationXml)
  else if Namespace = AtomSvgNamespace then
    Result := (Name = AtomForeignObject) or (Name = AtomDesc) or (Name = AtomTitle)
  else
    Result := False;
end;

function IsFormattingName(Name: TAtom): Boolean;
begin
  Result := (HtmlKinds(Name) and KindFormatting) <> 0;
end;

function IsHeadingName(Name: TAtom): Boolean;
begin
  Result := (HtmlKinds(Name) and KindHeading) <> 0;
end;

function IsScopeBoundary(Element: TElement; Scope: TScope): Boolean;
var
  Namespace: TAtom;
  Name: TAtom;
begin
  Namespace := Element.NamespaceAtom;
  Name := Element.LocalNameAtom;
  case Scope of
    ScopeTable:
      Exit((Namespace = AtomHtmlNamespace) and ((Name = AtomHtml) or (Name = AtomTable) or (Name = AtomTemplate)));
    ScopeSelect:
      Exit(not ((Namespace = AtomHtmlNamespace) and ((Name = AtomOptgroup) or (Name = AtomOption))));
  end;
  if Namespace = AtomHtmlNamespace then
  begin
    if (HtmlKinds(Name) and KindScopeBoundary) <> 0 then
      Exit(True);
    if (Scope = ScopeListItem) and ((Name = AtomOl) or (Name = AtomUl)) then
      Exit(True);
    if (Scope = ScopeButton) and (Name = AtomButton) then
      Exit(True);
    Exit(False);
  end;
  if Namespace = AtomMathMlNamespace then
    Exit((Name = AtomMi) or (Name = AtomMo) or (Name = AtomMn) or (Name = AtomMs) or (Name = AtomMtext) or
      (Name = AtomAnnotationXml));
  if Namespace = AtomSvgNamespace then
    Exit((Name = AtomForeignObject) or (Name = AtomDesc) or (Name = AtomTitle));
  Result := False;
end;

function IsMathMlTextIntegrationPoint(Element: TElement): Boolean;
var
  Name: TAtom;
begin
  if Element.NamespaceAtom <> AtomMathMlNamespace then
    Exit(False);
  Name := Element.LocalNameAtom;
  Result := (Name = AtomMi) or (Name = AtomMo) or (Name = AtomMn) or (Name = AtomMs) or (Name = AtomMtext);
end;

function IsHtmlIntegrationPoint(Element: TElement): Boolean;
var
  Encoding: string;
  Name: TAtom;
begin
  Name := Element.LocalNameAtom;
  if Element.NamespaceAtom = AtomMathMlNamespace then
  begin
    if Name <> AtomAnnotationXml then
      Exit(False);
    Encoding := AsciiLowerCase(Element.AttributeValueOf(AtomEncoding));
    Exit((Encoding = 'text/html') or (Encoding = 'application/xhtml+xml'));
  end;
  if Element.NamespaceAtom = AtomSvgNamespace then
    Exit((Name = AtomForeignObject) or (Name = AtomDesc) or (Name = AtomTitle));
  Result := False;
end;

function SerializesAsVoid(Element: TElement): Boolean;
begin
  Result := Element.IsHtml and ((HtmlKinds(Element.LocalNameAtom) and KindVoid) <> 0);
end;

procedure Mark(const Names: array of TAtom; Kind: Word);
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    KindTable[Names[Index]] := KindTable[Names[Index]] or Kind;
end;

initialization
  FillChar(KindTable, SizeOf(KindTable), 0);
  Mark([AtomAddress, AtomApplet, AtomArea, AtomArticle, AtomAside, AtomBase, AtomBasefont, AtomBgsound,
    AtomBlockquote, AtomBody, AtomBr, AtomButton, AtomCaption, AtomCenter, AtomCol, AtomColgroup, AtomDd,
    AtomDetails, AtomDir, AtomDiv, AtomDl, AtomDt, AtomEmbed, AtomFieldset, AtomFigcaption, AtomFigure,
    AtomFooter, AtomForm, AtomFrame, AtomFrameset, AtomH1, AtomH2, AtomH3, AtomH4, AtomH5, AtomH6, AtomHead,
    AtomHeader, AtomHgroup, AtomHr, AtomHtml, AtomIframe, AtomImg, AtomInput, AtomKeygen, AtomLi, AtomLink,
    AtomListing, AtomMain, AtomMarquee, AtomMenu, AtomMeta, AtomNav, AtomNoembed, AtomNoframes, AtomNoscript,
    AtomObject, AtomOl, AtomP, AtomParam, AtomPlaintext, AtomPre, AtomScript, AtomSearch, AtomSection,
    AtomSelect, AtomSource, AtomStyle, AtomSummary, AtomTable, AtomTbody, AtomTd, AtomTemplate, AtomTextarea,
    AtomTfoot, AtomTh, AtomThead, AtomTitle, AtomTr, AtomTrack, AtomUl, AtomWbr, AtomXmp], KindSpecial);
  Mark([AtomA, AtomB, AtomBig, AtomCode, AtomEm, AtomFont, AtomI, AtomNobr, AtomS, AtomSmall, AtomStrike,
    AtomStrong, AtomTt, AtomU], KindFormatting);
  Mark([AtomDd, AtomDt, AtomLi, AtomOptgroup, AtomOption, AtomP, AtomRb, AtomRp, AtomRt, AtomRtc],
    KindImpliedEndTag or KindImpliedEndTagThorough);
  Mark([AtomCaption, AtomColgroup, AtomTbody, AtomTd, AtomTfoot, AtomTh, AtomThead, AtomTr],
    KindImpliedEndTagThorough);
  Mark([AtomApplet, AtomCaption, AtomHtml, AtomTable, AtomTd, AtomTh, AtomMarquee, AtomObject, AtomTemplate],
    KindScopeBoundary);
  Mark([AtomArea, AtomBase, AtomBasefont, AtomBgsound, AtomBr, AtomCol, AtomEmbed, AtomFrame, AtomHr, AtomImg,
    AtomInput, AtomKeygen, AtomLink, AtomMeta, AtomParam, AtomSource, AtomTrack, AtomWbr], KindVoid);
  Mark([AtomH1, AtomH2, AtomH3, AtomH4, AtomH5, AtomH6], KindHeading);
end.
