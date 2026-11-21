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
  A document's origin (HTML Standard 7.1.1): its URL's, unless the
  document was given another - an about:blank or srcdoc document has
  its creator's, a document in a frame sandboxed without
  allow-same-origin an opaque one of its own. The DOM keeps such an
  origin as text (TDocument.OriginText: the serialization, or
  "null#<identity>" for an opaque origin, so two opaque origins stay
  apart); this unit turns it into a TUrlOrigin and back.
}
unit Web.Origins;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records,
  Url.Origins,
  Web.Dom;

function DocumentOrigin(Document: TDocument): TUrlOrigin;
procedure SetDocumentOrigin(Document: TDocument; constref Origin: TUrlOrigin);
{ Whether two documents are same origin (opaque origins only with
  themselves). }
function DocumentsSameOrigin(First, Second: TDocument): Boolean;
{ The document's origin serialized ("null" for an opaque one). }
function DocumentOriginText(Document: TDocument): string;

implementation

uses
  SysUtils,
  Url.Parser;

const
  OpaquePrefix = 'null#';

function DocumentOrigin(Document: TDocument): TUrlOrigin;
var
  Text: string;
  Url: TUrlRecord;
begin
  Text := Document.OriginText;
  if Copy(Text, 1, Length(OpaquePrefix)) = OpaquePrefix then
  begin
    Result := NewOpaqueOrigin;
    Result.OpaqueIdentity := StrToInt64Def(Copy(Text, Length(OpaquePrefix) + 1, MaxInt), 0);
    Exit;
  end;
  if Text <> '' then
  begin
    if ParseUrl(Text + '/', Url) then
      Exit(OriginOfUrl(Url));
    Exit(NewOpaqueOrigin);
  end;
  if (Document.Url <> '') and ParseUrl(Document.Url, Url) then
    Result := OriginOfUrl(Url)
  else
    Result := NewOpaqueOrigin;
  { An opaque origin stays the document's from now on (so its frames
    can be given the same one). }
  if Result.Opaque then
    SetDocumentOrigin(Document, Result);
end;

procedure SetDocumentOrigin(Document: TDocument; constref Origin: TUrlOrigin);
begin
  if Origin.Opaque then
    Document.OriginText := OpaquePrefix + IntToStr(Origin.OpaqueIdentity)
  else
    Document.OriginText := SerializeOrigin(Origin);
end;

function DocumentsSameOrigin(First, Second: TDocument): Boolean;
var
  FirstOrigin, SecondOrigin: TUrlOrigin;
begin
  if First = Second then
    Exit(True);
  if (First = nil) or (Second = nil) then
    Exit(False);
  FirstOrigin := DocumentOrigin(First);
  SecondOrigin := DocumentOrigin(Second);
  Result := SameOrigin(FirstOrigin, SecondOrigin);
end;

function DocumentOriginText(Document: TDocument): string;
var
  Origin: TUrlOrigin;
begin
  Origin := DocumentOrigin(Document);
  Result := SerializeOrigin(Origin);
end;

end.
