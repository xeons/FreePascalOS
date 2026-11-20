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
  How the style engine sees a document: the element adapter.

  libcss knows nothing of the DOM. A host (libweb) implements one
  TCssElementAdapter for its document model; the engine then refers to
  elements by opaque handles (TCssElement, a pointer the host chooses,
  usually its node object) and asks the adapter about them. Nothing is
  allocated per element on the engine's side for this.

  Names are atoms of Css.Atoms. The cheapest arrangement, the one
  libweb uses, is for the DOM to intern its element names, attribute
  names, ids and classes in that same table, so the adapter returns
  stored integers. A host with its own atoms keeps one mapping per
  distinct name.

  Navigation is over elements only: Parent returns the parent element
  (nil at the root, or above it), the sibling and child functions skip
  text and comments.
}
unit Css.ElementAdapter;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Declarations;

type
  TCssElement = Pointer;

  { The element states the dynamic pseudo-classes test. }
  TCssElementState = (
    esHover, esActive, esFocus, esFocusVisible, esFocusWithin, esLink, esVisited, esTarget,
    esTargetWithin, esChecked, esIndeterminate, esDisabled, esEnabled, esRequired, esOptional,
    esReadOnly, esReadWrite, esPlaceholderShown, esDefault, esValid, esInvalid, esInRange,
    esOutOfRange, esAutofill, esUserValid, esUserInvalid, esOpen, esModal, esPopoverOpen,
    esFullscreen, esPlaying, esPaused, esDefined);
  TCssElementStates = set of TCssElementState;

  TCssQuirksMode = (qmNoQuirks, qmLimitedQuirks, qmQuirks);

  TCssDirection = (dirLeftToRight, dirRightToLeft);

  TCssElementAdapter = class
  public
    { The element's local name as an atom; for HTML elements the
      lowercase name the HTML parser stores. }
    function LocalName(Element: TCssElement): TCssAtom; virtual; abstract;
    { The namespace URI's atom (NoAtom for none). }
    function NamespaceUri(Element: TCssElement): TCssAtom; virtual; abstract;
    { An HTML element in an HTML document: type and attribute names
      match without regard to ASCII case, and some attribute values too. }
    function IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean; virtual; abstract;
    { The id attribute's atom, NoAtom if there is none. }
    function Id(Element: TCssElement): TCssAtom; virtual; abstract;
    function ClassCount(Element: TCssElement): Integer; virtual; abstract;
    function ClassAt(Element: TCssElement; Index: Integer): TCssAtom; virtual; abstract;
    { The attribute in namespace NamespaceUri (NoAtom: none) with local
      name LocalName (lowercase for HTML elements in HTML documents). }
    function FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom;
      out Value: string): Boolean; virtual; abstract;
    { All attributes, for [*|name]. }
    function AttributeCount(Element: TCssElement): Integer; virtual; abstract;
    procedure AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace, AttributeName: TCssAtom;
      out Value: string); virtual; abstract;

    function Parent(Element: TCssElement): TCssElement; virtual; abstract;
    function PreviousSibling(Element: TCssElement): TCssElement; virtual; abstract;
    function NextSibling(Element: TCssElement): TCssElement; virtual; abstract;
    function FirstChild(Element: TCssElement): TCssElement; virtual; abstract;
    function LastChild(Element: TCssElement): TCssElement; virtual; abstract;
    { No element children and no text (comments and processing
      instructions do not count), for :empty. }
    function IsEmpty(Element: TCssElement): Boolean; virtual; abstract;
    { The document element. }
    function IsRoot(Element: TCssElement): Boolean; virtual;

    function States(Element: TCssElement): TCssElementStates; virtual; abstract;
    { The element's language (its own lang attribute or the nearest
      ancestor's, or the document's), '' when unknown. }
    function Language(Element: TCssElement): string; virtual; abstract;
    { The directionality :dir() tests. }
    function Direction(Element: TCssElement): TCssDirection; virtual;
    function QuirksMode: TCssQuirksMode; virtual;
    { The parsed style attribute (the host keeps it; Css.Parser's
      ParseStyleAttribute makes one), nil when there is none. }
    function StyleAttribute(Element: TCssElement): TCssDeclarationBlock; virtual;
    { Presentational hints (HTML's mapped attributes such as width,
      bgcolor, align): author origin declarations with specificity 0,
      before every author rule. nil when there are none. }
    function PresentationalHints(Element: TCssElement): TCssDeclarationBlock; virtual;
  end;

implementation

function TCssElementAdapter.IsRoot(Element: TCssElement): Boolean;
begin
  Result := Parent(Element) = nil;
end;

function TCssElementAdapter.Direction(Element: TCssElement): TCssDirection;
begin
  Result := dirLeftToRight;
end;

function TCssElementAdapter.QuirksMode: TCssQuirksMode;
begin
  Result := qmNoQuirks;
end;

function TCssElementAdapter.StyleAttribute(Element: TCssElement): TCssDeclarationBlock;
begin
  Result := nil;
end;

function TCssElementAdapter.PresentationalHints(Element: TCssElement): TCssDeclarationBlock;
begin
  Result := nil;
end;

end.
