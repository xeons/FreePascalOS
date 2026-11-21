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
  What a browser's Page Info and context menu tell of a document: its
  address, title, referrer, type, encoding, rendering mode and
  Last-Modified; its meta elements; its media (images, backgrounds,
  icons, image buttons) with their sizes as laid out; how many forms and
  links it has; and the background image nearest an element. No
  controls: host tools use it as the web view does.
}
unit WebView.PageInfo;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.Layout.Document,
  WebView.Types;

{ Page Info of Document (its layout nil: no sizes, no backgrounds). }
function CollectPageInfo(Document: TDocument; Layout: TDocumentLayout): TWebPageInfo;
{ The URL of the first background-image of Element or its nearest
  ancestor that has one (resolved), '' none. }
function NearestBackgroundImageUrl(Layout: TDocumentLayout; Element: TElement): string;
{ The URL of Element's own first background-image (resolved), '' none. }
function BackgroundImageUrlOf(Layout: TDocumentLayout; Element: TElement): string;
{ Element's attribute resolved against its document's base URL ('' when
  it is missing or not a URL). }
function ResolvedAttribute(Element: TElement; const Name: string): string;
{ A text field, text area or an element in contenteditable content. }
function IsEditableElement(Element: TElement): Boolean;

implementation

uses
  SysUtils,
  Math,
  Css.ComputedStyle,
  Css.ComputedValues,
  Css.Values,
  Css.PropertyIds,
  Web.Layout.Boxes,
  Web.Bindings.UrlResolution,
  Web.Dom.FormControls,
  WebView.Elements;

const
  { Page Info lists at most this many media and meta items. }
  ItemLimit = 5000;

function ResolvedAttribute(Element: TElement; const Name: string): string;
var
  Value: string;
begin
  Result := '';
  if (Element = nil) or not Element.HasAttribute(Name) then
    Exit;
  Value := Trim(Element.GetAttribute(Name));
  if Value = '' then
    Exit;
  if not ResolveUrlText(Element.NodeDocument, Value, Result) then
    Result := '';
end;

function BackgroundImageUrlOf(Layout: TDocumentLayout; Element: TElement): string;
var
  Box: TLayoutBox;
  Images: PCssComputedValue;
  Item: TCssValue;
  Index, Count: Integer;
begin
  Result := '';
  if (Layout = nil) or (Element = nil) then
    Exit;
  Box := Layout.BoxOf(Element);
  if (Box = nil) or (Box.Style = nil) then
    Exit;
  Images := Box.Style.Value(cpBackgroundImage);
  if (Images^.Kind <> cvValue) or (Images^.Data = nil) then
    Exit;
  if Images^.Data.Kind = vkList then
    Count := Images^.Data.Count
  else
    Count := 1;
  for Index := 0 to Count - 1 do
  begin
    if Images^.Data.Kind = vkList then
      Item := Images^.Data.Items[Index]
    else
      Item := Images^.Data;
    if (Item <> nil) and (Item.Kind = vkUrl) and (Item.Text <> '') then
    begin
      if not ResolveUrlText(Element.NodeDocument, Item.Text, Result) then
        Result := Item.Text;
      Exit;
    end;
  end;
end;

function NearestBackgroundImageUrl(Layout: TDocumentLayout; Element: TElement): string;
begin
  Result := '';
  while Element <> nil do
  begin
    Result := BackgroundImageUrlOf(Layout, Element);
    if Result <> '' then
      Exit;
    Element := Element.ParentElement;
  end;
end;

function IsEditableElement(Element: TElement): Boolean;
var
  Value: string;
begin
  Result := False;
  if Element = nil then
    Exit;
  if FormControlKindOf(Element) in [FormControlText, FormControlPassword, FormControlTextArea] then
    Exit(True);
  while Element <> nil do
  begin
    if Element.HasAttribute('contenteditable') then
    begin
      Value := LowerCase(Trim(Element.GetAttribute('contenteditable')));
      Exit(Value <> 'false');
    end;
    Element := Element.ParentElement;
  end;
end;

procedure AddMedia(var Info: TWebPageInfo; var Count: Integer; const Url, Kind, AltText: string; Layout: TDocumentLayout;
  Element: TElement);
var
  X, Y, Width, Height: Single;
begin
  if (Url = '') or (Count >= ItemLimit) then
    Exit;
  if Count = Length(Info.Media) then
    SetLength(Info.Media, Count * 2 + 16);
  Info.Media[Count].Url := Url;
  Info.Media[Count].Kind := Kind;
  Info.Media[Count].AltText := AltText;
  Info.Media[Count].Width := 0;
  Info.Media[Count].Height := 0;
  if (Layout <> nil) and (Kind <> 'Icon') and Layout.NodeBounds(Element, X, Y, Width, Height) then
  begin
    Info.Media[Count].Width := Max(0, Round(Width));
    Info.Media[Count].Height := Max(0, Round(Height));
  end;
  Inc(Count);
end;

procedure AddMeta(var Info: TWebPageInfo; var Count: Integer; Element: TElement);
var
  Name: string;
begin
  if Count >= ItemLimit then
    Exit;
  Name := Element.GetAttribute('name');
  if Name = '' then
    Name := Element.GetAttribute('http-equiv');
  if Name = '' then
    Name := Element.GetAttribute('property');
  if Name = '' then
  begin
    if not Element.HasAttribute('charset') then
      Exit;
    Name := 'charset';
    if Count = Length(Info.Meta) then
      SetLength(Info.Meta, Count * 2 + 8);
    Info.Meta[Count].Name := Name;
    Info.Meta[Count].Content := Element.GetAttribute('charset');
    Inc(Count);
    Exit;
  end;
  if Count = Length(Info.Meta) then
    SetLength(Info.Meta, Count * 2 + 8);
  Info.Meta[Count].Name := Name;
  Info.Meta[Count].Content := Element.GetAttribute('content');
  Inc(Count);
end;

function IsIconLink(Element: TElement): Boolean;
var
  Relation: string;
begin
  Relation := ' ' + LowerCase(Element.GetAttribute('rel')) + ' ';
  Result := Pos(' icon ', Relation) > 0;
end;

function RenderModeOf(Document: TDocument): string;
begin
  if Document.Mode = DocumentModeQuirks then
    Result := 'Quirks mode'
  else
    Result := 'Standards compliance mode';
end;

function CollectPageInfo(Document: TDocument; Layout: TDocumentLayout): TWebPageInfo;
var
  Node: TNode;
  Element: TElement;
  Name, Background: string;
  MediaCount, MetaCount: Integer;
begin
  Result := Default(TWebPageInfo);
  if Document = nil then
    Exit;
  Result.Url := Document.Url;
  Result.Title := Document.Title;
  Result.Referrer := Document.Referrer;
  Result.ContentType := Document.ContentType;
  Result.Encoding := Document.CharacterSet;
  Result.RenderMode := RenderModeOf(Document);
  Result.LastModified := Document.LastModified;
  MediaCount := 0;
  MetaCount := 0;
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      Name := Element.LocalName;
      if Name = 'img' then
        AddMedia(Result, MediaCount, ResolvedAttribute(Element, 'src'), 'Image', Element.GetAttribute('alt'), Layout,
          Element)
      else if (Name = 'input') and (LowerCase(Element.GetAttribute('type')) = 'image') then
        AddMedia(Result, MediaCount, ResolvedAttribute(Element, 'src'), 'Input image', Element.GetAttribute('alt'), Layout,
          Element)
      else if (Name = 'link') and IsIconLink(Element) then
        AddMedia(Result, MediaCount, ResolvedAttribute(Element, 'href'), 'Icon', '', nil, Element)
      else if Name = 'meta' then
        AddMeta(Result, MetaCount, Element)
      else if Name = 'form' then
        Inc(Result.FormCount)
      else if ((Name = 'a') or (Name = 'area')) and Element.HasAttribute('href') then
        Inc(Result.LinkCount);
      Background := BackgroundImageUrlOf(Layout, Element);
      if Background <> '' then
        AddMedia(Result, MediaCount, Background, 'Background', '', Layout, Element);
    end;
    Node := Node.NextInTree(Document);
  end;
  SetLength(Result.Media, MediaCount);
  SetLength(Result.Meta, MetaCount);
end;

end.
