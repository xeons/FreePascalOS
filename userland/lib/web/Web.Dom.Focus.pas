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
  Focus (HTML Standard 6.6): which elements are focusable areas, and the
  focusing and unfocusing steps - the old element gets blur and focusout,
  the new one focus and focusin (FocusEvents with the other as
  relatedTarget), and the document's FocusedElement changes, which its
  observers hear (the web view moves its caret and :focus with it). The
  script bindings (focus(), blur(), autofocus) and the web view (clicks,
  Tab) both go through here.
}
unit Web.Dom.Focus;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

{ A focusable area: links with href, enabled form controls (not hidden
  inputs), iframes, summary of a details, elements with a tabindex or
  contenteditable. }
function IsFocusableArea(Element: TElement): Boolean;
{ The focusing steps for Element (nothing if it is not focusable or not
  connected); events fire unless the focus does not move. }
procedure FocusElement(Element: TElement);
{ The unfocusing steps: the document's focus goes to its viewport. }
procedure UnfocusElement(Element: TElement);

implementation

uses
  SysUtils,
  Web.Atoms,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Dom.FormControls;

var
  AtomHrefName, AtomTabindexName, AtomContenteditableName, AtomDisabledName, AtomTypeName: TAtom;

function IsFocusableArea(Element: TElement): Boolean;
var
  Name: string;
begin
  Result := False;
  if (Element = nil) or not Element.IsConnected then
    Exit;
  if Element.HasAttributeAtom(AtomTabindexName) then
    Exit(True);
  if Element.HasAttributeAtom(AtomContenteditableName) and
    (LowerCase(Element.AttributeValueOf(AtomContenteditableName)) <> 'false') then
    Exit(True);
  if not Element.IsHtmlElement(Element.LocalNameAtom) then
    Exit;
  Name := Element.LocalName;
  if (Name = 'a') or (Name = 'area') then
    Exit(Element.HasAttributeAtom(AtomHrefName));
  if (Name = 'input') or (Name = 'select') or (Name = 'textarea') or (Name = 'button') then
  begin
    if Element.HasAttributeAtom(AtomDisabledName) then
      Exit(False);
    if (Name = 'input') and (InputType(Element) = 'hidden') then
      Exit(False);
    Exit(True);
  end;
  if (Name = 'iframe') or (Name = 'embed') or (Name = 'object') then
    Exit(True);
  if (Name = 'summary') and (Element.ParentElement <> nil) and (Element.ParentElement.LocalName = 'details') then
    Exit(True);
end;

procedure FireFocus(Target: TElement; const EventType: string; Bubbles: Boolean; Related: TElement);
var
  Event: TFocusEvent;
begin
  Event := TFocusEvent.Create(EventType, Bubbles, False);
  try
    Event.Composed := True;
    Event.HasView := True;
    Event.IsTrusted := True;
    Event.RelatedTarget := Related;
    Target.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

procedure FocusElement(Element: TElement);
var
  Document: TDocument;
  Old: TElement;
begin
  if not IsFocusableArea(Element) then
    Exit;
  Document := Element.NodeDocument;
  if (Document = nil) or (Document.FocusedElement = Element) then
    Exit;
  Old := Document.FocusedElement;
  if Old <> nil then
    Old.Retain;
  Element.Retain;
  try
    Document.SetFocusedElementOnly(Element);
    if (Old <> nil) and Old.IsConnected then
    begin
      FireFocus(Old, 'blur', False, Element);
      FireFocus(Old, 'focusout', True, Element);
    end;
    if Document.FocusedElement = Element then
    begin
      FireFocus(Element, 'focus', False, Old);
      FireFocus(Element, 'focusin', True, Old);
    end;
  finally
    Element.Release;
    if Old <> nil then
      Old.Release;
  end;
end;

procedure UnfocusElement(Element: TElement);
var
  Document: TDocument;
begin
  if Element = nil then
    Exit;
  Document := Element.NodeDocument;
  if (Document = nil) or (Document.FocusedElement <> Element) then
    Exit;
  Element.Retain;
  try
    Document.SetFocusedElementOnly(nil);
    FireFocus(Element, 'blur', False, nil);
    FireFocus(Element, 'focusout', True, nil);
  finally
    Element.Release;
  end;
end;

initialization
  AtomHrefName := Atomize('href');
  AtomTabindexName := Atomize('tabindex');
  AtomContenteditableName := Atomize('contenteditable');
  AtomDisabledName := Atomize('disabled');
  AtomTypeName := Atomize('type');
end.
