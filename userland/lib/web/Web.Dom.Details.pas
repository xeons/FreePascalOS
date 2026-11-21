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
  The summary element's activation behavior (HTML 4.11.2): a click on a
  details element's summary (its first summary child), not on a link or
  control inside it, opens or closes the details. Installed as the DOM's
  activation behavior when the program uses Web.Dom.
}
unit Web.Dom.Details;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Web.Dom.Events;

{ The details element a click through Path toggles; nil if none. }
function DetailsToggledBy(const Path: TEventTargetArray): TElement;

implementation

uses
  Web.Atoms;

function IsInteractive(Element: TElement): Boolean;
begin
  Result := (Element.IsHtmlElement(AtomA) and Element.HasAttribute('href')) or Element.IsHtmlElement(AtomButton) or
    Element.IsHtmlElement(AtomInput) or Element.IsHtmlElement(AtomSelect) or Element.IsHtmlElement(AtomTextarea) or
    (Element.IsHtml and (Element.LocalName = 'label'));
end;

function IsSummaryForItsParent(Element: TElement): Boolean;
var
  Child: TNode;
begin
  Result := False;
  if not Element.IsHtmlElement(AtomSummary) or (Element.ParentElement = nil) or
    not Element.ParentElement.IsHtmlElement(AtomDetails) then
    Exit;
  Child := Element.ParentElement.FirstChild;
  while Child <> nil do
  begin
    if Child.IsElement and TElement(Child).IsHtmlElement(AtomSummary) then
      Exit(Child = Element);
    Child := Child.NextSibling;
  end;
end;

function DetailsToggledBy(const Path: TEventTargetArray): TElement;
var
  Index: Integer;
  Element: TElement;
begin
  Result := nil;
  for Index := 0 to High(Path) do
  begin
    if not (Path[Index] is TElement) then
      Continue;
    Element := TElement(Path[Index]);
    if IsSummaryForItsParent(Element) then
      Exit(Element.ParentElement);
    if IsInteractive(Element) then
      Exit;
  end;
end;

procedure SummaryActivation(Event: TEvent; const Path: TEventTargetArray);
var
  Details: TElement;
begin
  Details := DetailsToggledBy(Path);
  if Details = nil then
    Exit;
  if Details.HasAttribute('open') then
    Details.RemoveAttribute('open')
  else
    Details.SetAttribute('open', '');
end;

initialization
  ActivationBehavior := @SummaryActivation;
end.
