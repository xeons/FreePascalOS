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

{ WebView.Engine: frames - the pointer goes into them (hit testing
  through their documents), each document's own layout and navigable,
  where a frame's viewport is in the view's, and the mouse events. }

function TWebEngineView.HitTestDeep(CssX, CssY: Double; out Path: TFramePath): THitTestResult;
begin
  Path := nil;
  Result := Default(THitTestResult);
  if FPainter = nil then
    Exit;
  Result := HitTestThroughFrames(FPainter, FLayout, CssX, CssY, Path);
end;

function TWebEngineView.LayoutForDocument(Document: TDocument): TDocumentLayout;
var
  View: TFrameView;
begin
  if (Document = nil) or (Document = FDocument) then
    Exit(FLayout);
  View := FrameViewOfDocument(Document);
  if View <> nil then
    Result := View.Layout
  else
    Result := nil;
end;

function TWebEngineView.NavigableForNode(Node: TNode): TNavigable;
begin
  Result := nil;
  if Node <> nil then
    Result := TNavigable.OfDocument(Node.NodeDocument);
  if (Result = nil) and (FPage <> nil) then
    Result := FPage.Navigable;
end;

function TWebEngineView.ViewportOriginOf(Document: TDocument; out X, Y: Single): Boolean;
var
  TargetLayout: TDocumentLayout;
begin
  Result := DocumentViewportOrigin(FLayout, Document, X, Y, TargetLayout);
end;

{ The node above Node, going from a frame's document to its element in
  the parent document (so :hover and :focus-within reach the iframe). }
function NodeAbove(Node: TNode): TNode;
var
  View: TFrameView;
begin
  if Node is TDocument then
  begin
    View := FrameViewOfDocument(TDocument(Node));
    if View <> nil then
      Result := View.Container
    else
      Result := nil;
  end
  else
    Result := Node.ParentNode;
end;

{ The pointer as Target's document sees it, for its mouse events. }
procedure TWebEngineView.FillMouseInit(Target: TNode; out Init: TMouseEventInit);
var
  OriginX, OriginY, ScrollX, ScrollY, BoxX, BoxY, BoxWidth, BoxHeight: Single;
  TargetLayout: TDocumentLayout;
  Scale: Double;
begin
  Init := Default(TMouseEventInit);
  Scale := DeviceScale;
  Init.ClientX := FLastPointerX / Scale;
  Init.ClientY := FLastPointerY / Scale;
  Init.ScreenX := Unscaled(PixelBounds.Left + FLastPointerX);
  Init.ScreenY := Unscaled(PixelBounds.Top + FLastPointerY);
  if Host <> nil then
    if Host.OwnerWindow is TControlWindow then
    begin
      Inc(Init.ScreenX, TControlWindow(Host.OwnerWindow).ScreenLeft);
      Inc(Init.ScreenY, TControlWindow(Host.OwnerWindow).ScreenTop);
    end;
  Init.Modifiers := HeldModifiers;
  if Target = nil then
    Exit;
  if DocumentViewportOrigin(FLayout, Target.NodeDocument, OriginX, OriginY, TargetLayout) then
  begin
    Init.ClientX := Init.ClientX - OriginX;
    Init.ClientY := Init.ClientY - OriginY;
  end;
  if TargetLayout = nil then
    Exit;
  TargetLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Init.ScrollX := ScrollX;
  Init.ScrollY := ScrollY;
  if TargetLayout.NodeBounds(Target, BoxX, BoxY, BoxWidth, BoxHeight) then
  begin
    Init.OffsetX := Init.ClientX + ScrollX - BoxX;
    Init.OffsetY := Init.ClientY + ScrollY - BoxY;
  end;
end;

function TWebEngineView.FireMouse(Target: TNode; const EventType: string; Button: SmallInt; Detail: LongInt): Boolean;
var
  Init: TMouseEventInit;
begin
  if Target = nil then
    Exit(True);
  FillMouseInit(Target, Init);
  Init.Button := Button;
  Init.Buttons := FButtonsHeld;
  Init.Detail := Detail;
  Result := DispatchMouseEvent(Target, EventType, Init);
  PostWake;
end;

function TWebEngineView.FireClick(Element: TElement): Boolean;
begin
  Result := FireMouse(Element, 'click', 0, 1);
end;

{ The innermost scroll container under the pointer scrolls, else the
  frame's viewport, then the same outwards: the frames the pointer is in,
  innermost first, then the page. }
function TWebEngineView.ScrollThroughFrames(CssX, CssY, DeltaX, DeltaY: Double): Boolean;
var
  Path: TFramePath;
  Hit: THitTestResult;
  Level: Integer;
  View: TFrameView;
begin
  Result := False;
  HitTestDeep(CssX, CssY, Path);
  Level := High(Path);
  while Level >= 0 do
  begin
    View := Path[Level].View;
    if View.Painter <> nil then
    begin
      Hit := View.HitTest(CssX - Path[Level].OriginX, CssY - Path[Level].OriginY);
      if ScrollBoxChain(View.Layout, Hit.Box, DeltaX, DeltaY) then
        Exit(True);
      if View.ScrollViewportBy(DeltaX, DeltaY) then
      begin
        InvalidateViewport;
        RequestFrame;
        Exit(True);
      end;
    end;
    Dec(Level);
  end;
end;
