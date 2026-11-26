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
  An img's current image request (HTML Standard 4.8.4.1): its state
  (unavailable, completely available, broken), the URL it is for and
  the density-corrected natural size of its image. The element owns it
  (TNode.ImageRequestObject); the image loader (Web.Loading.Images)
  fills it as the image loads, inside or outside the document, and the
  script bindings read it for naturalWidth, naturalHeight, complete,
  currentSrc and the width and height of an image not rendered.
}
unit Web.Dom.ImageRequests;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

type
  TImageRequestState = (ImageRequestUnavailable, ImageRequestCompletelyAvailable, ImageRequestBroken);

  TImageRequest = class
  public
    State: TImageRequestState;
    { The request's URL (the source chosen from srcset and src). }
    CurrentUrl: string;
    { In CSS pixels: the image's size divided by its density. }
    NaturalWidth: Double;
    NaturalHeight: Double;
    { The loader is fetching or decoding for it. }
    Loading: Boolean;
  end;

{ The element's request, or nil when it never had one. }
function FindImageRequest(Element: TElement): TImageRequest;
{ The element's request, made when missing. }
function ImageRequestOf(Element: TElement): TImageRequest;
{ The img's complete attribute: no source to load, or the request's
  outcome known (available or broken) and nothing loading. }
function ImageComplete(Element: TElement): Boolean;

implementation

uses
  Web.Atoms;

function FindImageRequest(Element: TElement): TImageRequest;
begin
  Result := TImageRequest(Element.ImageRequestObject);
end;

function ImageRequestOf(Element: TElement): TImageRequest;
begin
  Result := FindImageRequest(Element);
  if Result = nil then
  begin
    Result := TImageRequest.Create;
    Element.SetImageRequestObject(Result);
  end;
end;

function ImageComplete(Element: TElement): Boolean;
var
  Request: TImageRequest;
begin
  if not Element.HasAttributeAtom(AtomSrcset) and
     (not Element.HasAttributeAtom(AtomSrc) or (Element.AttributeValueOf(AtomSrc) = '')) then
    Exit(True);
  Request := FindImageRequest(Element);
  if Request = nil then
    Exit(False);
  Result := not Request.Loading and (Request.State in [ImageRequestCompletelyAvailable, ImageRequestBroken]);
end;

end.
