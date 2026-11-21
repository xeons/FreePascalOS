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
  The document loader's eyes on the tree: a document observer that
  turns elements becoming connected or disconnected and their attribute
  and child changes into calls on whoever loads for them (style sheet
  and icon links, preload links, images and picture sources, scripts,
  base, meta, title, iframes and frames). It only dispatches; TLoadingEvents is implemented
  by the document loader.
}
unit Web.Loading.Observers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom;

type
  TLoadingEvents = class
  public
    procedure LinkChanged(Element: TElement); virtual; abstract;
    procedure LinkRemoved(Element: TElement); virtual; abstract;
    procedure ImageChanged(Element: TElement); virtual; abstract;
    procedure ImageRemoved(Element: TElement); virtual; abstract;
    procedure ScriptChanged(Element: TElement); virtual; abstract;
    procedure BaseChanged; virtual; abstract;
    procedure MetaInserted(Element: TElement); virtual; abstract;
    procedure TitleMayHaveChanged; virtual; abstract;
    { An iframe or frame became connected (Inserted), had an attribute
      that matters change (src, srcdoc, name, ...: Attribute), or left. }
    procedure FrameInserted(Element: TElement); virtual; abstract;
    procedure FrameAttributeChanged(Element: TElement; Attribute: TAtom); virtual; abstract;
    procedure FrameRemoved(Element: TElement); virtual; abstract;
  end;

  TLoadingObserver = class(TDocumentObserver)
  private
    FEvents: TLoadingEvents;
    procedure PictureChanged(Picture: TElement);
  public
    constructor Create(Events: TLoadingEvents);
    procedure ChildrenChanged(Parent: TNode); override;
    procedure NodeConnected(Node: TNode); override;
    procedure NodeDisconnected(Node: TNode); override;
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean); override;
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string); override;
  end;

implementation

constructor TLoadingObserver.Create(Events: TLoadingEvents);
begin
  inherited Create;
  FEvents := Events;
end;

function InTitle(Node: TNode): Boolean;
var
  Parent: TElement;
begin
  Parent := Node.ParentElement;
  Result := (Parent <> nil) and Parent.IsHtmlElement(AtomTitle);
end;

procedure TLoadingObserver.PictureChanged(Picture: TElement);
var
  Node: TNode;
begin
  Node := Picture.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).IsHtmlElement(AtomImg) then
      FEvents.ImageChanged(TElement(Node));
    Node := Node.NextSibling;
  end;
end;

procedure TLoadingObserver.ChildrenChanged(Parent: TNode);
begin
  if not Parent.IsElement then
    Exit;
  if TElement(Parent).IsHtmlElement(AtomTitle) then
    FEvents.TitleMayHaveChanged
  else if TElement(Parent).IsHtmlElement(AtomScript) and Parent.IsConnected then
    FEvents.ScriptChanged(TElement(Parent));
end;

procedure TLoadingObserver.NodeConnected(Node: TNode);
var
  Element: TElement;
  Parent: TElement;
begin
  if not Node.IsElement then
  begin
    if InTitle(Node) then
      FEvents.TitleMayHaveChanged;
    Exit;
  end;
  Element := TElement(Node);
  if not Element.IsHtml then
    Exit;
  case Element.LocalNameAtom of
    AtomLink: FEvents.LinkChanged(Element);
    AtomImg: FEvents.ImageChanged(Element);
    AtomScript: FEvents.ScriptChanged(Element);
    AtomBase: FEvents.BaseChanged;
    AtomMeta: FEvents.MetaInserted(Element);
    AtomTitle: FEvents.TitleMayHaveChanged;
    AtomIframe, AtomFrame: FEvents.FrameInserted(Element);
    AtomSource:
      begin
        Parent := Element.ParentElement;
        if (Parent <> nil) and Parent.IsHtmlElement(AtomPicture) then
          PictureChanged(Parent);
      end;
  end;
end;

procedure TLoadingObserver.NodeDisconnected(Node: TNode);
var
  Element: TElement;
begin
  if not Node.IsElement then
    Exit;
  Element := TElement(Node);
  if not Element.IsHtml then
    Exit;
  case Element.LocalNameAtom of
    AtomLink: FEvents.LinkRemoved(Element);
    AtomImg: FEvents.ImageRemoved(Element);
    AtomBase: FEvents.BaseChanged;
    AtomTitle: FEvents.TitleMayHaveChanged;
    AtomIframe, AtomFrame: FEvents.FrameRemoved(Element);
  end;
end;

procedure TLoadingObserver.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
var
  Parent: TElement;
begin
  if not Element.IsHtml or not Element.IsConnected or (NamespaceId <> NamespaceNone) then
    Exit;
  case Element.LocalNameAtom of
    AtomLink:
      if (LocalName = AtomRel) or (LocalName = AtomHref) or (LocalName = AtomMedia) or
         (LocalName = AtomDisabled) or (LocalName = AtomCrossorigin) or (LocalName = AtomSizes) or
         (LocalName = AtomType) then
        FEvents.LinkChanged(Element);
    AtomImg:
      if (LocalName = AtomSrc) or (LocalName = AtomSrcset) or (LocalName = AtomSizes) or
         (LocalName = AtomCrossorigin) or (LocalName = AtomLoading) then
        FEvents.ImageChanged(Element);
    AtomSource:
      begin
        Parent := Element.ParentElement;
        if (Parent <> nil) and Parent.IsHtmlElement(AtomPicture) then
          PictureChanged(Parent);
      end;
    AtomScript:
      if LocalName = AtomSrc then
        FEvents.ScriptChanged(Element);
    AtomBase:
      if LocalName = AtomHref then
        FEvents.BaseChanged;
    AtomIframe, AtomFrame:
      if (LocalName = AtomSrc) or (LocalName = AtomSrcdoc) or (LocalName = AtomName) then
        FEvents.FrameAttributeChanged(Element, LocalName);
  end;
end;

procedure TLoadingObserver.CharacterDataChanged(Node: TCharacterData; const OldValue: string);
begin
  if InTitle(Node) then
    FEvents.TitleMayHaveChanged;
end;

end.
