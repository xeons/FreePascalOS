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
  An SVG document: the tree of nodes, its elements by id, how its nodes
  are restyled for <use> and where its text's fonts come from, and its
  natural size (the root's width and height when they are absolute,
  the viewBox's ratio).

  LoadSvgDocument reads a file (Svg.Xml) and styles it (Svg.Styling).
  An embedder builds the tree itself (TSvgDocument.Create over a root
  it made, styles set) and may resolve ids the tree does not have
  (OnFindExternal: inline SVG's <use href="#icon"> pointing at a symbol
  elsewhere in the page); nodes it returns are adopted and freed with
  the document.
}
unit Svg.Document;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Css.ComputedStyle,
  Svg.Nodes,
  Svg.Numbers,
  Svg.Styling,
  Svg.Fonts,
  Svg.ImageReferences;

type
  TSvgDocument = class;

  { The subtree for an id the document does not have (a new tree, whose
    root is the element with that id), or nil. }
  TSvgFindExternalEvent = function(Document: TSvgDocument; const Id: string): TSvgNode of object;

  TSvgDocument = class
  private
    FRoot: TSvgNode;
    FIds: TStringList;
    FExternal: TList;
    FExternalIds: TStringList;
    FStyler: TSvgStyler;
    FResolver: TSvgStyleResolver;
    FFontSource: TSvgFontSource;
    FOnFindExternal: TSvgFindExternalEvent;
    FImages: TSvgImageCache;
    procedure IndexIds(Node: TSvgNode);
    function GetImages: TSvgImageCache;
    function GetFontSource: TSvgFontSource;
  public
    { Takes Root. }
    constructor Create(Root: TSvgNode);
    destructor Destroy; override;
    { Styles the tree with its own <style> sheets (a file's). }
    procedure StyleWithOwnSheets(RootParentStyle: TCssComputedStyle);
    function FindById(const Id: string): TSvgNode;
    { An IRI reference: "#id" (or "url(#id)"); nil when it names
      nothing here. }
    function FindByReference(const Reference: string): TSvgNode;
    { The root's natural size in CSS pixels and its viewBox. }
    function HasNaturalWidth: Boolean;
    function HasNaturalHeight: Boolean;
    function NaturalWidth: Double;
    function NaturalHeight: Double;
    function HasViewBox: Boolean;
    function ViewBox: TSvgViewBox;
    { Width / height from the size or the viewBox, 0 when neither. }
    function NaturalRatio: Double;
    property Root: TSvgNode read FRoot;
    { Restyles content a <use> instantiates (nil: their own styles). }
    property StyleResolver: TSvgStyleResolver read FResolver write FResolver;
    property FontSource: TSvgFontSource read GetFontSource write FFontSource;
    property OnFindExternal: TSvgFindExternalEvent read FOnFindExternal write FOnFindExternal;
    { The pictures <image> elements refer to. }
    property Images: TSvgImageCache read GetImages;
  end;

{ Parses and styles an SVG file; raises ESvgError (Svg.Xml) when it has
  no root element or the root is not <svg>. }
function LoadSvgDocument(const Data: TBytes): TSvgDocument;
function LoadSvgDocumentFromText(const Text: string): TSvgDocument;
{ True when Data looks like an SVG file: text whose first element is
  svg (after an XML declaration, comments, a doctype). }
function LooksLikeSvg(const Data: TBytes): Boolean;

implementation

uses
  Svg.Xml;

constructor TSvgDocument.Create(Root: TSvgNode);
begin
  inherited Create;
  FRoot := Root;
  FIds := TStringList.Create;
  FIds.CaseSensitive := True;
  FIds.Sorted := True;
  FIds.Duplicates := dupIgnore;
  FExternal := TList.Create;
  FExternalIds := TStringList.Create;
  FExternalIds.CaseSensitive := True;
  FExternalIds.Sorted := True;
  IndexIds(Root);
end;

destructor TSvgDocument.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FExternal.Count - 1 do
    TSvgNode(FExternal[Index]).Free;
  FExternal.Free;
  FExternalIds.Free;
  FStyler.Free;
  FImages.Free;
  FRoot.Free;
  FIds.Free;
  inherited Destroy;
end;

procedure TSvgDocument.IndexIds(Node: TSvgNode);
var
  Child: TSvgNode;
  Id: string;
begin
  Id := Node.Id;
  if Id <> '' then
    FIds.AddObject(Id, Node);
  Child := Node.FirstElementChild;
  while Child <> nil do
  begin
    IndexIds(Child);
    Child := Child.NextElementSibling;
  end;
end;

procedure TSvgDocument.StyleWithOwnSheets(RootParentStyle: TCssComputedStyle);
begin
  if FStyler = nil then
    FStyler := TSvgStyler.Create(FRoot);
  FStyler.StyleDocument(FRoot, RootParentStyle);
  FResolver := FStyler;
end;

function TSvgDocument.GetImages: TSvgImageCache;
begin
  if FImages = nil then
    FImages := TSvgImageCache.Create;
  Result := FImages;
end;

function TSvgDocument.GetFontSource: TSvgFontSource;
begin
  if FFontSource <> nil then
    Result := FFontSource
  else
    Result := SystemSvgFontSource;
end;

function TSvgDocument.FindById(const Id: string): TSvgNode;
var
  Index: Integer;
  Found: TSvgNode;
begin
  Result := nil;
  if Id = '' then
    Exit;
  if FIds.Find(Id, Index) then
    Exit(TSvgNode(FIds.Objects[Index]));
  if FExternalIds.Find(Id, Index) then
    Exit(TSvgNode(FExternalIds.Objects[Index]));
  if not Assigned(FOnFindExternal) then
    Exit;
  Found := FOnFindExternal(Self, Id);
  { Remember misses too, so they are asked once. }
  FExternalIds.AddObject(Id, Found);
  if Found <> nil then
    FExternal.Add(Found);
  Result := Found;
end;

function TSvgDocument.FindByReference(const Reference: string): TSvgNode;
var
  Text: string;
begin
  Text := Trim(Reference);
  if (Length(Text) > 5) and (LowerCase(Copy(Text, 1, 4)) = 'url(') and (Text[Length(Text)] = ')') then
  begin
    Text := Trim(Copy(Text, 5, Length(Text) - 5));
    if (Length(Text) >= 2) and (Text[1] in ['"', '''']) and (Text[Length(Text)] = Text[1]) then
      Text := Copy(Text, 2, Length(Text) - 2);
  end;
  { Only references within the document (a local fragment). }
  if (Text = '') or (Text[1] <> '#') then
    Exit(nil);
  Result := FindById(Copy(Text, 2, Length(Text)));
end;

function AbsoluteLength(Root: TSvgNode; const Name: string; out Value: Double): Boolean;
var
  Length: TSvgLength;
  Viewport: TSvgViewport;
begin
  Value := 0;
  if not ParseLength(Root.Attribute(Name), Length) or (Length.UnitKind = LengthPercent) or (Length.Value <= 0) then
    Exit(False);
  Viewport.Width := 0;
  Viewport.Height := 0;
  Viewport.FontSize := 16;
  Value := ResolveLength(Length, DirectionOther, Viewport);
  Result := Value > 0;
end;

function TSvgDocument.HasNaturalWidth: Boolean;
var
  Value: Double;
begin
  Result := AbsoluteLength(FRoot, 'width', Value);
end;

function TSvgDocument.HasNaturalHeight: Boolean;
var
  Value: Double;
begin
  Result := AbsoluteLength(FRoot, 'height', Value);
end;

function TSvgDocument.NaturalWidth: Double;
begin
  AbsoluteLength(FRoot, 'width', Result);
end;

function TSvgDocument.NaturalHeight: Double;
begin
  AbsoluteLength(FRoot, 'height', Result);
end;

function TSvgDocument.HasViewBox: Boolean;
var
  Box: TSvgViewBox;
begin
  Result := ParseViewBox(FRoot.Attribute('viewBox'), Box) and (Box.Width > 0) and (Box.Height > 0);
end;

function TSvgDocument.ViewBox: TSvgViewBox;
begin
  if not ParseViewBox(FRoot.Attribute('viewBox'), Result) then
    Result := Default(TSvgViewBox);
end;

function TSvgDocument.NaturalRatio: Double;
var
  Box: TSvgViewBox;
begin
  Result := 0;
  if HasNaturalWidth and HasNaturalHeight then
    Exit(NaturalWidth / NaturalHeight);
  if HasViewBox then
  begin
    Box := ViewBox;
    Result := Box.Width / Box.Height;
  end;
end;

function LoadSvgDocumentFromText(const Text: string): TSvgDocument;
var
  Root: TSvgNode;
begin
  Root := ParseSvgXml(Text);
  if not Root.IsKind(SvgSvg) then
  begin
    Root.Free;
    raise ESvgError.Create('the root element is not svg');
  end;
  Result := TSvgDocument.Create(Root);
  try
    Result.StyleWithOwnSheets(nil);
  except
    Result.Free;
    raise;
  end;
end;

function LoadSvgDocument(const Data: TBytes): TSvgDocument;
begin
  Result := LoadSvgDocumentFromText(SvgBytesToText(Data));
end;

function LooksLikeSvg(const Data: TBytes): Boolean;
var
  Count: Integer;
  Text: string;
  Position: Integer;
  Close: Integer;
begin
  Result := False;
  Count := Length(Data);
  if Count > 4096 then
    Count := 4096;
  if Count < 5 then
    Exit;
  SetLength(Text, Count);
  Move(Data[0], Text[1], Count);
  Position := 1;
  if Copy(Text, 1, 3) = #$EF#$BB#$BF then
    Position := 4;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and (Text[Position] in [' ', #9, #10, #13]) do
      Inc(Position);
    if (Position > Length(Text)) or (Text[Position] <> '<') then
      Exit;
    if Copy(Text, Position, 4) = '<!--' then
    begin
      Close := Pos('-->', Text, Position);
      if Close > 0 then
        Inc(Close, 2);
    end
    else if (Copy(Text, Position, 2) = '<?') or (Copy(Text, Position, 2) = '<!') then
      Close := Pos('>', Text, Position)
    else
    begin
      Inc(Position);
      { The root: svg, perhaps with a prefix. }
      Close := Position;
      while (Close <= Length(Text)) and (Text[Close] in ['A'..'Z', 'a'..'z', '0'..'9', ':', '_', '-', '.']) do
        Inc(Close);
      Text := Copy(Text, Position, Close - Position);
      Exit((Text = 'svg') or ((Length(Text) > 4) and (Copy(Text, Length(Text) - 3, 4) = ':svg')));
    end;
    if Close = 0 then
      Exit;
    { A doctype with an internal subset may hold '>' in its brackets. }
    if (Copy(Text, Position, 9) = '<!DOCTYPE') and (Pos('[', Copy(Text, Position, Close - Position)) > 0) then
    begin
      Close := Pos(']', Text, Position);
      if Close = 0 then
        Exit;
      Close := Pos('>', Text, Close);
      if Close = 0 then
        Exit;
    end;
    Position := Close + 1;
  end;
end;

end.
