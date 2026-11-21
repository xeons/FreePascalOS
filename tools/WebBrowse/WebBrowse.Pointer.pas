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
  webbrowse's pointer: hovering and dragging as the web view does them.
  A hover hit-tests the point (or takes an element), moves :hover to
  the chain under it and fires mouseout, mouseover and mousemove; a
  drag presses at one point, moves to another and releases, selecting
  the text between them through the page's text index (libwebview's,
  so the selection is the one the browser would make).
}
unit WebBrowse.Pointer;

{$mode objfpc}
{$H+}

interface

uses
  Css.ElementAdapter,
  Web.Dom,
  Web.Layout.Document,
  Web.Paint.Painter,
  WebView.TextIndex;

type
  TPagePointer = class
  private
    FLayout: TDocumentLayout;
    FPainter: TDocumentPainter;
    FHovered: array of TElement;
    FTextIndex: TPageTextIndex;
    procedure SetHoverChain(Element: TElement);
    procedure FireAt(Target: TElement; const EventType: string; X, Y: Double; Buttons: Word);
    function TextPositionAt(X, Y: Double): TTextPosition;
  public
    constructor Create;
    destructor Destroy; override;
    { The document's layout and painter changed (nil: no document). }
    procedure Attach(Layout: TDocumentLayout; Painter: TDocumentPainter);
    { The pointer moved to a viewport point (CSS px). }
    procedure HoverAt(X, Y: Double);
    { The pointer moved onto Element (no hit test: hidden or covered
      elements get the events too, as a script driving them would). }
    procedure HoverElement(Element: TElement);
    { Pressed at one viewport point, dragged to the other, released;
      the selected text, or '' when nothing was selected. }
    function Drag(FromX, FromY, ToX, ToY: Double): string;
  end;

implementation

uses
  SysUtils,
  Web.Dom.Exceptions,
  WebView.MouseEvents,
  WebView.SelectionMapping;

constructor TPagePointer.Create;
begin
  inherited Create;
  FTextIndex := TPageTextIndex.Create;
end;

destructor TPagePointer.Destroy;
begin
  Attach(nil, nil);
  FTextIndex.Free;
  inherited Destroy;
end;

procedure TPagePointer.Attach(Layout: TDocumentLayout; Painter: TDocumentPainter);
var
  Index: Integer;
begin
  for Index := 0 to High(FHovered) do
    FHovered[Index].Release;
  FHovered := nil;
  FTextIndex.Clear;
  FLayout := Layout;
  FPainter := Painter;
end;

function ChainHas(const Chain: array of TElement; Element: TElement): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Chain) do
    if Chain[Index] = Element then
      Exit(True);
  Result := False;
end;

procedure TPagePointer.SetHoverChain(Element: TElement);
var
  Chain: array of TElement;
  Node: TNode;
  Index: Integer;
begin
  Chain := nil;
  Node := Element;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      SetLength(Chain, Length(Chain) + 1);
      Chain[High(Chain)] := TElement(Node);
      TElement(Node).Retain;
    end;
    Node := Node.ParentNode;
  end;
  for Index := 0 to High(FHovered) do
    if not ChainHas(Chain, FHovered[Index]) and FHovered[Index].IsConnected then
      FLayout.SetElementStates(FHovered[Index], []);
  for Index := 0 to High(Chain) do
    if not ChainHas(FHovered, Chain[Index]) then
      FLayout.SetElementStates(Chain[Index], [esHover]);
  for Index := 0 to High(FHovered) do
    FHovered[Index].Release;
  FHovered := Chain;
end;

procedure TPagePointer.FireAt(Target: TElement; const EventType: string; X, Y: Double; Buttons: Word);
var
  Init: TMouseEventInit;
  ScrollX, ScrollY: Single;
begin
  if Target = nil then
    Exit;
  Init := Default(TMouseEventInit);
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Init.ClientX := X;
  Init.ClientY := Y;
  Init.ScrollX := ScrollX;
  Init.ScrollY := ScrollY;
  Init.ScreenX := Round(X);
  Init.ScreenY := Round(Y);
  Init.Buttons := Buttons;
  Init.Detail := 1;
  Target.Retain;
  try
    DispatchMouseEvent(Target, EventType, Init);
  finally
    Target.Release;
  end;
end;

procedure TPagePointer.HoverElement(Element: TElement);
var
  Old: TElement;
begin
  if FLayout = nil then
    Exit;
  Old := nil;
  if Length(FHovered) > 0 then
  begin
    Old := FHovered[0];
    Old.Retain;
  end;
  if Element <> nil then
    Element.Retain;
  try
    SetHoverChain(Element);
    if Old <> Element then
    begin
      FireAt(Old, 'mouseout', 0, 0, 0);
      FireAt(Element, 'mouseover', 0, 0, 0);
    end;
    FireAt(Element, 'mousemove', 0, 0, 0);
  finally
    if Element <> nil then
      Element.Release;
    if Old <> nil then
      Old.Release;
  end;
end;

procedure TPagePointer.HoverAt(X, Y: Double);
var
  Hit: THitTestResult;
begin
  if (FLayout = nil) or (FPainter = nil) then
    Exit;
  if FLayout.NeedsUpdate then
    FLayout.Update;
  FPainter.Refresh;
  Hit := FPainter.HitTest(X, Y);
  HoverElement(Hit.Element);
end;

function TPagePointer.TextPositionAt(X, Y: Double): TTextPosition;
var
  ScrollX, ScrollY: Single;
begin
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Result := FTextIndex.PositionAt(X + ScrollX, Y + ScrollY, ScrollX, ScrollY);
end;

function TPagePointer.Drag(FromX, FromY, ToX, ToY: Double): string;
var
  Hit: THitTestResult;
  Pressed: TElement;
  Anchor, Focus: TTextPosition;
  AnchorNode, FocusNode: TNode;
  AnchorOffset, FocusOffset: Integer;
  Document: TDocument;
begin
  Result := '';
  if (FLayout = nil) or (FPainter = nil) then
    Exit;
  if FLayout.NeedsUpdate then
    FLayout.Update;
  FPainter.Refresh;
  Hit := FPainter.HitTest(FromX, FromY);
  Pressed := Hit.Element;
  if Pressed = nil then
    Exit;
  Document := Pressed.NodeDocument;
  Document.Retain;
  Pressed.Retain;
  try
    HoverElement(Pressed);
    FireAt(Pressed, 'mousedown', FromX, FromY, 1);
    { The handlers may have changed the page: hit and index again. }
    if FLayout.NeedsUpdate then
      FLayout.Update;
    FPainter.Refresh;
    FTextIndex.Build(FPainter.DisplayList);
    Anchor := TextPositionAt(FromX, FromY);
    HoverAt(ToX, ToY);
    if Length(FHovered) > 0 then
      FireAt(FHovered[0], 'mousemove', ToX, ToY, 1);
    if FLayout.NeedsUpdate then
      FLayout.Update;
    FPainter.Refresh;
    FTextIndex.Build(FPainter.DisplayList);
    Focus := TextPositionAt(ToX, ToY);
    if (Anchor.Run >= 0) and (Focus.Run >= 0) and
      TextPositionToDomPoint(FTextIndex, Anchor, AnchorNode, AnchorOffset) and
      TextPositionToDomPoint(FTextIndex, Focus, FocusNode, FocusOffset) and
      AnchorNode.IsConnected and FocusNode.IsConnected and
      (AnchorNode.NodeDocument = Document) and (FocusNode.NodeDocument = Document) then
    begin
      try
        Document.Selection.SetBaseAndExtent(AnchorNode, AnchorOffset, FocusNode, FocusOffset);
        Result := FTextIndex.TextBetween(Anchor, Focus);
      except
        on EDomException do
          Document.Selection.RemoveAllRanges;
      end;
    end;
    if Length(FHovered) > 0 then
      FireAt(FHovered[0], 'mouseup', ToX, ToY, 0);
  finally
    Pressed.Release;
    Document.Release;
  end;
end;

end.
