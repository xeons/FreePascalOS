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
  The web view's pointer handling without the control, for host tools
  (webbrowse's scroll, drag, click and copy steps; the web load test's
  pointer fuzz): the same steps in the same order as
  WebView.Engine.Pointer.inc - the hover's chain and the pointer shape
  read from the hit before the page's events, every element an event is
  fired at held while it is dispatched, nothing of a hit used after an
  event, the place in the text looked up again (WebView.PageSelection,
  the web view's own selection) after the handlers ran; mousemove while
  pressed, the click count in mousedown and mouseup, dblclick, a word
  on a double and the line on a triple click, the drag's focus following
  the wheel and the autoscroll past the viewport's edges.
}
unit WebBrowse.Pointer;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.Layout.Document,
  Web.Paint.Painter,
  WebView.PageSelection;

type
  { Asked before the pointer reads the layout: the host lays out (or,
    as the web view with a slow layout, leaves it for later). }
  TLayOutRequest = procedure(Force: Boolean) of object;

  TPagePointer = class
  private
    FDocument: TDocument;
    FLayout: TDocumentLayout;
    FPainter: TDocumentPainter;
    FSelection: TPageSelection;
    FOnLayOut: TLayOutRequest;
    FViewportHeight: Single;
    FHover: array of TElement;
    FPressed: Boolean;
    FDragged: Boolean;
    FSelecting: Boolean;
    FPressX, FPressY: Single;
    FPointerX, FPointerY: Single;
    procedure BringLayoutUpToDate;
    procedure SetHover(Element: TElement);
    procedure Fire(Target: TNode; const EventType: string; Button: SmallInt; Detail: LongInt);
    function HitAt(X, Y: Single): THitTestResult;
    procedure ExtendTo(X, Y: Single);
    procedure Autoscroll;
  public
    { Hits whose box had a cursor of its own (read before the events). }
    Shapes: Integer;
    destructor Destroy; override;
    { The page the pointer is over (nil: none); the hover is let go. }
    procedure Attach(Document: TDocument; Layout: TDocumentLayout; Painter: TDocumentPainter;
      Selection: TPageSelection);
    { Viewport CSS px. }
    procedure MoveTo(X, Y: Single);
    procedure Press(X, Y: Single; ClickCount: Integer);
    procedure Release(X, Y: Single; ClickCount: Integer);
    { The pointer's scroll container (else the viewport) by Delta CSS px. }
    procedure Wheel(Delta: Single);
    { A frame: a drag held past an edge scrolls on. }
    procedure Frame;
    procedure Drag(FromX, FromY, ToX, ToY: Single; Steps: Integer);
    procedure ClickAt(X, Y: Single; Count: Integer);
    { Lets go of the hover chain and the press. }
    procedure LetGo;
    property OnLayOut: TLayOutRequest read FOnLayOut write FOnLayOut;
    property ViewportHeight: Single read FViewportHeight write FViewportHeight;
  end;

implementation

uses
  Css.ElementAdapter,
  Css.PropertyIds,
  Css.Keywords,
  Web.Layout.Boxes,
  WebView.MouseEvents,
  WebView.TextGroups,
  WebView.TextIndex;

{ TPagePointer }

procedure TPagePointer.Attach(Document: TDocument; Layout: TDocumentLayout; Painter: TDocumentPainter;
  Selection: TPageSelection);
begin
  LetGo;
  FDocument := Document;
  FLayout := Layout;
  FPainter := Painter;
  FSelection := Selection;
end;

procedure TPagePointer.BringLayoutUpToDate;
begin
  if FLayout = nil then
    Exit;
  if Assigned(FOnLayOut) then
    FOnLayOut(False)
  else if FLayout.NeedsUpdate then
    FLayout.Update;
end;

procedure TPagePointer.Drag(FromX, FromY, ToX, ToY: Single; Steps: Integer);
var
  Step: Integer;
begin
  if Steps < 1 then
    Steps := 1;
  Press(FromX, FromY, 1);
  for Step := 1 to Steps do
    MoveTo(FromX + (ToX - FromX) * Step / Steps, FromY + (ToY - FromY) * Step / Steps);
  Release(ToX, ToY, 1);
end;

procedure TPagePointer.ClickAt(X, Y: Single; Count: Integer);
var
  Index: Integer;
begin
  for Index := 1 to Count do
  begin
    Press(X, Y, Index);
    Release(X, Y, Index);
  end;
end;

destructor TPagePointer.Destroy;
begin
  LetGo;
  inherited Destroy;
end;

procedure TPagePointer.LetGo;
begin
  SetHover(nil);
  FPressed := False;
  FSelecting := False;
end;

{ The chain under the pointer, each element retained, with :hover. }
procedure TPagePointer.SetHover(Element: TElement);
var
  Old: array of TElement;
  Node: TNode;
  Index: Integer;
begin
  Old := FHover;
  FHover := nil;
  Node := Element;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      SetLength(FHover, Length(FHover) + 1);
      FHover[High(FHover)] := TElement(Node);
      TElement(Node).Retain;
    end;
    Node := Node.ParentNode;
  end;
  for Index := 0 to High(Old) do
  begin
    if (FLayout <> nil) and Old[Index].IsConnected and (Old[Index].NodeDocument = FDocument) then
      FLayout.SetElementStates(Old[Index], []);
    Old[Index].Release;
  end;
  for Index := 0 to High(FHover) do
    if (FLayout <> nil) and FHover[Index].IsConnected and (FHover[Index].NodeDocument = FDocument) then
      FLayout.SetElementStates(FHover[Index], [esHover]);
end;

procedure TPagePointer.Fire(Target: TNode; const EventType: string; Button: SmallInt; Detail: LongInt);
var
  Init: TMouseEventInit;
begin
  if Target = nil then
    Exit;
  Init := Default(TMouseEventInit);
  Init.ClientX := FPointerX;
  Init.ClientY := FPointerY;
  Init.Button := Button;
  if FPressed then
    Init.Buttons := 1;
  Init.Detail := Detail;
  Target.Retain;
  try
    DispatchMouseEvent(Target, EventType, Init);
  finally
    Target.Release;
  end;
end;

function TPagePointer.HitAt(X, Y: Single): THitTestResult;
begin
  Result := Default(THitTestResult);
  if FPainter = nil then
    Exit;
  BringLayoutUpToDate;
  Result := FPainter.HitTest(X, Y);
end;

procedure TPagePointer.ExtendTo(X, Y: Single);
var
  View: TTextViewport;
  Focus: TTextPosition;
begin
  if FLayout = nil then
    Exit;
  BringLayoutUpToDate;
  View := ViewportOfLayout(FLayout);
  Focus := FSelection.PositionAt(X + View.ScrollX, Y + View.ScrollY, View);
  if Focus.Run >= 0 then
    FSelection.Extend(Focus);
end;

procedure TPagePointer.Autoscroll;
var
  ScrollX, ScrollY: Single;
begin
  if not (FSelecting and FDragged) or (FLayout = nil) then
    Exit;
  if (FPointerY >= 0) and (FPointerY <= FViewportHeight) then
    Exit;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  if FPointerY < 0 then
    FLayout.SetScrollOffset(nil, ScrollX, ScrollY + FPointerY)
  else
    FLayout.SetScrollOffset(nil, ScrollX, ScrollY + FPointerY - FViewportHeight);
  ExtendTo(FPointerX, FPointerY);
end;

procedure TPagePointer.MoveTo(X, Y: Single);
var
  Hit: THitTestResult;
  Old, Target: TElement;
begin
  FPointerX := X;
  FPointerY := Y;
  if FPressed then
  begin
    if (Abs(X - FPressX) > 3) or (Abs(Y - FPressY) > 3) then
      FDragged := True;
    Hit := HitAt(X, Y);
    Target := Hit.Element;
    Hit := Default(THitTestResult);
    Fire(Target, 'mousemove', 0, 0);
    if FSelecting and FDragged and FPressed then
    begin
      if (Y < 0) or (Y > FViewportHeight) then
        Autoscroll
      else
        ExtendTo(X, Y);
    end;
    Exit;
  end;
  Hit := HitAt(X, Y);
  Old := nil;
  if Length(FHover) > 0 then
  begin
    Old := FHover[0];
    Old.Retain;
  end;
  SetHover(Hit.Element);
  { As the web view: what the hit shows is read before any event. }
  if (Hit.Box <> nil) and (Hit.Box.Style <> nil) and (Hit.Box.Style.Keyword(cpCursor) <> kwAuto) then
    Inc(Shapes);
  Target := Hit.Element;
  Hit := Default(THitTestResult);
  if Target <> nil then
    Target.Retain;
  try
    if Old <> Target then
    begin
      Fire(Old, 'mouseout', 0, 0);
      Fire(Target, 'mouseover', 0, 0);
    end;
    Fire(Target, 'mousemove', 0, 0);
  finally
    if Old <> nil then
      Old.Release;
    if Target <> nil then
      Target.Release;
  end;
end;

procedure TPagePointer.Press(X, Y: Single; ClickCount: Integer);
var
  Hit: THitTestResult;
  Target: TElement;
  View: TTextViewport;
  Position: TTextPosition;
  Proceed: Boolean;
  Init: TMouseEventInit;
begin
  FPointerX := X;
  FPointerY := Y;
  Hit := HitAt(X, Y);
  Target := Hit.Element;
  Hit := Default(THitTestResult);
  FPressed := True;
  FPressX := X;
  FPressY := Y;
  FDragged := False;
  FSelecting := False;
  Proceed := True;
  if Target <> nil then
  begin
    Target.Retain;
    try
      Init := Default(TMouseEventInit);
      Init.ClientX := X;
      Init.ClientY := Y;
      Init.Buttons := 1;
      Init.Detail := ClickCount;
      Proceed := DispatchMouseEvent(Target, 'mousedown', Init);
    finally
      Target.Release;
    end;
  end;
  if not Proceed or (FLayout = nil) then
    Exit;
  { The handlers may have laid out or changed the document: the place in
    the text is found now. }
  BringLayoutUpToDate;
  View := ViewportOfLayout(FLayout);
  Position := FSelection.PositionAt(X + View.ScrollX, Y + View.ScrollY, View);
  if (ClickCount = 2) and (Position.Run >= 0) then
    FSelection.SelectWordAt(Position)
  else if (ClickCount = 3) and (Position.Run >= 0) then
    FSelection.SelectLineAt(Position)
  else
  begin
    FSelecting := True;
    FSelection.Select(Position, Position);
  end;
end;

procedure TPagePointer.Release(X, Y: Single; ClickCount: Integer);
var
  Hit: THitTestResult;
  Target: TElement;
begin
  FPointerX := X;
  FPointerY := Y;
  Hit := HitAt(X, Y);
  Target := Hit.Element;
  Hit := Default(THitTestResult);
  if Target <> nil then
    Target.Retain;
  try
    Fire(Target, 'mouseup', 0, ClickCount);
    FPressed := False;
    FSelecting := False;
    if not FDragged and (Target <> nil) then
    begin
      Fire(Target, 'click', 0, ClickCount);
      if (ClickCount = 2) and Target.IsConnected then
        Fire(Target, 'dblclick', 0, 2);
    end;
  finally
    if Target <> nil then
      Target.Release;
  end;
end;

procedure TPagePointer.Wheel(Delta: Single);
var
  Hit: THitTestResult;
  Box: TLayoutBox;
  ScrollX, ScrollY: Single;
  Scrolled: Boolean;
begin
  if FLayout = nil then
    Exit;
  { The innermost scroll container under the pointer, read from the hit
    at once (no script runs in between). }
  Hit := HitAt(FPointerX, FPointerY);
  Box := Hit.Box;
  Scrolled := False;
  while (Box <> nil) and not Scrolled do
  begin
    if (bfScrollContainer in Box.Flags) and (Box.Kind <> bkViewport) and (Box.Node <> nil) then
    begin
      FLayout.SetScrollOffset(Box.Node, Box.ScrollX, Box.ScrollY + Delta);
      Scrolled := True;
    end;
    Box := Box.Parent;
  end;
  if not Scrolled then
  begin
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
    FLayout.SetScrollOffset(nil, ScrollX, ScrollY + Delta);
  end;
  if FSelecting and FDragged and FPressed then
    ExtendTo(FPointerX, FPointerY);
end;

procedure TPagePointer.Frame;
begin
  if FPressed then
    Autoscroll;
end;

end.
