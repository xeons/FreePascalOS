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

{ WebView.Engine: the pointer, element states, links, the focus, context menus. }

const
  { Logical units the pointer moves, button held, before it drags. }
  DragThreshold = 3;
  DoubleClickMilliseconds = 500;

function ChainContains(constref Chain: TElementChain; Element: TElement): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Chain) do
    if Chain[Index] = Element then
      Exit(True);
  Result := False;
end;

function TWebEngineView.StatesOf(Element: TElement): TCssElementStates;
var
  Node: TNode;
begin
  Result := [];
  if ChainContains(FHoverChain, Element) then
    Include(Result, esHover);
  if ChainContains(FActiveChain, Element) then
    Include(Result, esActive);
  if FFocusedElement <> nil then
  begin
    if Element = FFocusedElement then
    begin
      Include(Result, esFocus);
      if FFocusVisible then
        Include(Result, esFocusVisible);
    end;
    Node := FFocusedElement;
    while Node <> nil do
    begin
      if Node = Element then
      begin
        Include(Result, esFocusWithin);
        Break;
      end;
      Node := NodeAbove(Node);
    end;
  end;
end;

procedure TWebEngineView.ApplyStates(Element: TElement);
var
  TargetLayout: TDocumentLayout;
begin
  if (Element = nil) or not Element.IsConnected then
    Exit;
  { An element of a frame's document: that document's layout. }
  TargetLayout := LayoutForDocument(Element.NodeDocument);
  if TargetLayout <> nil then
    TargetLayout.SetElementStates(Element, StatesOf(Element));
end;

{ Chain becomes Element and its ancestors; every element that joined or
  left gets its states again. }
procedure TWebEngineView.SetChain(var Chain: TElementChain; Element: TElement);
var
  OldChain, NewChain: TElementChain;
  Node: TNode;
  Index: Integer;
begin
  NewChain := nil;
  Node := Element;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      SetLength(NewChain, Length(NewChain) + 1);
      NewChain[High(NewChain)] := TElement(Node);
      TElement(Node).Retain;
    end;
    Node := NodeAbove(Node);
  end;
  if (Length(NewChain) = Length(Chain)) and ((Length(Chain) = 0) or (NewChain[0] = Chain[0])) then
  begin
    for Index := 0 to High(NewChain) do
      NewChain[Index].Release;
    Exit;
  end;
  OldChain := Chain;
  Chain := NewChain;
  for Index := 0 to High(OldChain) do
    if not ChainContains(NewChain, OldChain[Index]) then
      ApplyStates(OldChain[Index]);
  for Index := 0 to High(NewChain) do
    if not ChainContains(OldChain, NewChain[Index]) then
      ApplyStates(NewChain[Index]);
  for Index := 0 to High(OldChain) do
    OldChain[Index].Release;
  RequestFrame;
end;

procedure TWebEngineView.SetFocusedElement(Element: TElement; ShowFocus: Boolean);
begin
  if (Element = FFocusedElement) and (ShowFocus = FFocusVisible) then
    Exit;
  FFocusVisible := ShowFocus;
  { The focusing steps fire the events; the document tells FocusMoved.
    Moving into another document (a frame) blurs the old one's first. }
  if (FFocusedElement <> nil) and ((Element = nil) or (Element.NodeDocument <> FFocusedElement.NodeDocument)) then
    UnfocusElement(FFocusedElement);
  if Element <> nil then
    FocusElement(Element);
  if (Element <> nil) and (Element.NodeDocument.FocusedElement <> FFocusedElement) then
    FocusMoved(Element.NodeDocument.FocusedElement)
  else if (Element = nil) and (FDocument <> nil) and (FDocument.FocusedElement <> FFocusedElement) then
    FocusMoved(FDocument.FocusedElement)
  else
    FocusMoved(FFocusedElement);
end;

procedure TWebEngineView.FocusMoved(Element: TElement);
var
  Old: TElement;
  Node: TNode;
begin
  Old := FFocusedElement;
  if Element <> nil then
    Element.Retain;
  FFocusedElement := Element;
  if Old <> nil then
  begin
    { The old one and its ancestors lose :focus and :focus-within. }
    Node := Old;
    while Node <> nil do
    begin
      if Node.IsElement then
        ApplyStates(TElement(Node));
      Node := NodeAbove(Node);
    end;
    if (Old <> Element) and Old.IsConnected and IsTextControl(Old) and (TextControlValue(Old) <> FFocusValue) then
      FireEvent(Old, 'change', True);
    Old.Release;
  end;
  if (Element <> nil) and IsTextControl(Element) and (Element <> Old) then
    FFocusValue := TextControlValue(Element);
  Node := Element;
  while Node <> nil do
  begin
    if Node.IsElement then
      ApplyStates(TElement(Node));
    Node := NodeAbove(Node);
  end;
  RequestFrame;
  InvalidateViewport;
  PostWake;
end;

procedure TWebEngineView.SetStatus(const Value: string);
begin
  if Value = FStatusText then
    Exit;
  FStatusText := Value;
  if Assigned(FOnStatusText) then
    FOnStatusText(Self, Value);
end;

{ The hit's node and element stay alive while the page's handlers run
  (they may remove them from the document); its box is not used after
  an event, since a handler may lay out again. }
procedure RetainHit(constref Hit: THitTestResult);
begin
  if Hit.Node <> nil then
    Hit.Node.Retain;
  if Hit.Element <> nil then
    Hit.Element.Retain;
end;

procedure ReleaseHit(constref Hit: THitTestResult);
begin
  if Hit.Element <> nil then
    Hit.Element.Release;
  if Hit.Node <> nil then
    Hit.Node.Release;
end;

{ mouseleave at the elements of OldChain the pointer left (innermost
  first), or (Entering) mouseenter at those of NewChain it entered
  (outermost first); their pointer events come with them. }
procedure TWebEngineView.FireBoundaryEvents(constref OldChain, NewChain: TElementChain; Entering: Boolean);
var
  Index: Integer;
begin
  if not Entering then
  begin
    for Index := 0 to High(OldChain) do
      if not ChainContains(NewChain, OldChain[Index]) then
        FireMouse(OldChain[Index], 'mouseleave', 0, 0);
    Exit;
  end;
  for Index := High(NewChain) downto 0 do
    if not ChainContains(OldChain, NewChain[Index]) then
      FireMouse(NewChain[Index], 'mouseenter', 0, 0);
end;

procedure TWebEngineView.UpdateHover(CssX, CssY: Double);
var
  Hit: THitTestResult;
  Link, Control, Old: TElement;
  Shape: LongWord;
  Path: TFramePath;
  Status: string;
  OldChain, NewChain: TElementChain;
  Index: Integer;
begin
  if FPainter = nil then
    Exit;
  if FLayout.NeedsUpdate then
    UpdateLayout;
  Hit := HitTestDeep(CssX, CssY, Path);
  Old := nil;
  if Length(FHoverChain) > 0 then
  begin
    Old := FHoverChain[0];
    Old.Retain;
  end;
  { The chains before and after, held for the boundary events. }
  OldChain := Copy(FHoverChain);
  for Index := 0 to High(OldChain) do
    OldChain[Index].Retain;
  SetChain(FHoverChain, Hit.Element);
  NewChain := Copy(FHoverChain);
  for Index := 0 to High(NewChain) do
    NewChain[Index].Retain;
  { What the hit shows - the link's address, the pointer shape from the
    box's style - is read before any event: the page's handlers may lay
    out again (reading a size) or change the document, which frees the
    hit's box and its style and may free its text node. }
  Link := LinkElementOf(Hit.Node);
  if Link <> nil then
    Status := ResolveLink(Link)
  else
    Status := '';
  Shape := PointerShapeForCursor(Hit.Box, (Hit.Node <> nil) and Hit.Node.IsText, Link <> nil);
  Control := FormControlOf(Hit.Node);
  if (Control <> nil) and (Shape = PointerTextBeam) and
     not (FormControlKindOf(Control) in [FormControlText, FormControlPassword, FormControlTextArea]) then
    Shape := PointerArrow
  else if (Control <> nil) and (FormControlKindOf(Control) in [FormControlText, FormControlPassword,
     FormControlTextArea]) and (Shape = PointerArrow) then
    Shape := PointerTextBeam;
  Hit.Box := nil;
  Hit.Node := nil;
  { mouseout and mouseover where the element under the pointer changed,
    then mousemove at it; it is held here, not only by the hover chain
    (a handler may make the view let go of the chain: a new document). }
  if Hit.Element <> nil then
    Hit.Element.Retain;
  try
    if Old <> Hit.Element then
    begin
      if Old <> nil then
        FireMouse(Old, 'mouseout', 0, 0);
      FireBoundaryEvents(OldChain, NewChain, False);
      if Hit.Element <> nil then
        FireMouse(Hit.Element, 'mouseover', 0, 0);
      FireBoundaryEvents(OldChain, NewChain, True);
    end;
    if Hit.Element <> nil then
      FireMouse(Hit.Element, 'mousemove', 0, 0);
  finally
    if Old <> nil then
      Old.Release;
    if Hit.Element <> nil then
      Hit.Element.Release;
    for Index := 0 to High(OldChain) do
      OldChain[Index].Release;
    for Index := 0 to High(NewChain) do
      NewChain[Index].Release;
  end;
  SetStatus(Status);
  PointerShape := Shape;
end;

procedure TWebEngineView.ClearHover;
begin
  SetChain(FHoverChain, nil);
  SetStatus('');
end;

function TWebEngineView.ResolveLink(Link: TElement): string;
var
  Target: TUrlRecord;
  Source: TNavigable;
begin
  Result := '';
  if Link = nil then
    Exit;
  { Against the base URL of the link's own document (a frame's too). }
  Source := NavigableForNode(Link);
  if (Source = nil) or (Source.Loader = nil) then
    Exit;
  if Source.Loader.ResolveUrl(Trim(Link.GetAttribute('href')), Target) then
    Result := SerializeUrl(Target);
end;

function TWebEngineView.DispositionFor(Button, Modifiers: LongWord; Link: TElement): TLinkDisposition;
var
  Target: string;
begin
  Result := LinkInView;
  if (Button = ButtonMiddle) or ((Modifiers and ModifierControl) <> 0) then
    Result := LinkInBackgroundTab
  else if (Modifiers and ModifierShift) <> 0 then
    Result := LinkInNewWindow
  else if Link <> nil then
  begin
    { _blank, or a name no navigable of the page has. }
    Target := Trim(Link.GetAttribute('target'));
    if (NavigableForNode(Link) <> nil) and (NavigableForNode(Link).ChooseNavigable(Target) = nil) then
      Result := LinkInNewTab;
  end;
end;

procedure TWebEngineView.ActivateLink(Link: TElement; Disposition: TLinkDisposition);
var
  UrlText: string;
  Target: TUrlRecord;
  Options: TNavigateOptions;
  Handled: Boolean;
  ScrollX, ScrollY: Single;
  Source, Destination: TNavigable;
begin
  UrlText := ResolveLink(Link);
  if UrlText = '' then
    Exit;
  if (Disposition = LinkInView) and not FireClick(Link) then
    Exit;
  if not ParseUrl(UrlText, Target) or (Target.Scheme = 'javascript') then
    Exit;
  { The link's target chooses the navigable: its own (a frame's), the
    parent, the top, a frame by name. }
  Source := NavigableForNode(Link);
  Destination := Source.ChooseNavigable(Trim(Link.GetAttribute('target')));
  if (Destination <> nil) and (Destination.Parent <> nil) and (Disposition = LinkInView) then
  begin
    Options := DefaultNavigateOptions;
    Options.UserInitiated := True;
    Options.Source := Source.Loader;
    Destination.Navigate(Target, Options);
    PostWake;
    Exit;
  end;
  Handled := False;
  if Assigned(FOnLinkClicked) then
    FOnLinkClicked(Self, UrlText, Disposition, Handled);
  if Handled then
    Exit;
  Options := DefaultNavigateOptions;
  Options.UserInitiated := True;
  Options.Source := Source.Loader;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  FPage.Navigable.SaveScrollPosition(ScrollX, ScrollY);
  FPage.Navigable.Navigate(Target, Options);
  PostWake;
end;

{ Logical units between the press and the pointer now. }
function MovedPast(X, Y, FromX, FromY: LongInt): Boolean;
begin
  Result := (Abs(X - FromX) > Scaled(DragThreshold)) or (Abs(Y - FromY) > Scaled(DragThreshold));
end;

procedure HoldElement(var Slot: TElement; Element: TElement);
begin
  if Slot = Element then
    Exit;
  if Element <> nil then
    Element.Retain;
  if Slot <> nil then
    Slot.Release;
  Slot := Element;
end;

function DomButtonOf(Button: LongWord): SmallInt;
begin
  if Button = ButtonMiddle then
    Result := 1
  else if Button = ButtonLeft then
    Result := 0
  else
    Result := 2;
end;

function ButtonsBitOf(Button: LongWord): Word;
begin
  if Button = ButtonMiddle then
    Result := 4
  else if Button = ButtonLeft then
    Result := 1
  else
    Result := 2;
end;

procedure TWebEngineView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Hit: THitTestResult;
  Scale: Double;
  Path: TFramePath;
begin
  inherited PointerDown(X, Y, Button);
  NoteUserGesture;
  SetFocus;
  FLastPointerX := X;
  FLastPointerY := Y;
  if FPainter = nil then
    Exit;
  if FLayout.NeedsUpdate then
    UpdateLayout;
  Scale := DeviceScale;
  Hit := HitTestDeep(X / Scale, Y / Scale, Path);
  FButtonsHeld := FButtonsHeld or ButtonsBitOf(Button);
  CountClick(X, Y, Button);
  RetainHit(Hit);
  try
    PressAt(Hit, Length(Path) > 0, X, Y, Button);
  finally
    ReleaseHit(Hit);
  end;
end;

{ The left button pressed again soon at the same place: a double, then a
  triple click (MouseEvent.detail); any other press starts again. }
procedure TWebEngineView.CountClick(X, Y: LongInt; Button: LongWord);
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if (Button = ButtonLeft) and (FClickCount > 0) and (Now - FLastClickTime < DoubleClickMilliseconds) and
     not MovedPast(X, Y, FLastClickX, FLastClickY) then
    Inc(FClickCount)
  else
    FClickCount := 1;
  if FClickCount > 3 then
    FClickCount := 1;
  FLastClickTime := Now;
  FLastClickX := X;
  FLastClickY := Y;
end;

procedure TWebEngineView.PressAt(constref Hit: THitTestResult; InFrame: Boolean; X, Y: LongInt; Button: LongWord);
var
  Control, Link: TElement;
  Position: TTextPosition;
  Proceed: Boolean;
begin
  { A cancelled mousedown keeps the focus and the selection as they are. }
  Proceed := FireMouse(Hit.Element, 'mousedown', DomButtonOf(Button), FClickCount);
  if Button = ButtonMiddle then
  begin
    FPressButton := ButtonMiddle;
    HoldElement(FPressedLink, LinkElementOf(Hit.Node));
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
  HoldElement(FPressedTarget, Hit.Element);
  if not Proceed then
  begin
    FPressButton := ButtonLeft;
    FPressX := X;
    FPressY := Y;
    FDragged := False;
    HoldElement(FPressedLink, LinkElementOf(Hit.Node));
    HoldElement(FPressedControl, FormControlOf(Hit.Node));
    Exit;
  end;
  FPressButton := ButtonLeft;
  FPressX := X;
  FPressY := Y;
  FDragged := False;
  SetChain(FActiveChain, Hit.Element);
  Link := LinkElementOf(Hit.Node);
  Control := FormControlOf(Hit.Node);
  if (Control <> nil) and IsDisabledControl(Control) then
    Control := nil;
  HoldElement(FPressedLink, Link);
  HoldElement(FPressedControl, Control);
  if Control <> nil then
  begin
    SetFocusedElement(Control, False);
    if (FormControlKindOf(Control) = FormControlRange) and Control.IsConnected then
      StartRangeDrag(Control, X);
    Exit;
  end;
  if Link <> nil then
  begin
    SetFocusedElement(Link, False);
    Exit;
  end;
  { Inside a frame its document has the focus (no element of it); its
    text is not selected. }
  if InFrame then
  begin
    SetFocusedElement(nil, False);
    ClearSelection;
    Exit;
  end;
  SetFocusedElement(nil, False);
  { The handlers above (mousedown, focus and blur) may have changed the
    document or laid it out: the place in the text is found now, in the
    index as the layout is now. }
  Position := TextPositionAt(X, Y);
  if (FClickCount >= 2) and (Position.Run >= 0) then
  begin
    if FClickCount = 2 then
    begin
      if FSelection.SelectWordAt(Position) then
        InvalidateViewport;
    end
    else if FSelection.SelectLineAt(Position) then
      InvalidateViewport;
    FSelecting := False;
    Exit;
  end;
  FSelecting := True;
  SetSelection(Position, Position);
end;

procedure TWebEngineView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Scale: Double;
begin
  inherited PointerMove(X, Y, Buttons);
  Scale := DeviceScale;
  { movementX and movementY: the motion since the last move. }
  FMovementX := (X - FLastPointerX) / Scale;
  FMovementY := (Y - FLastPointerY) / Scale;
  FLastPointerX := X;
  FLastPointerY := Y;
  if FPainter = nil then
    Exit;
  if FPressButton = ButtonLeft then
  begin
    if not FDragged and MovedPast(X, Y, FPressX, FPressY) then
      FDragged := True;
    { The page sees the pointer move while the button is held too. }
    FireMoveWhilePressed(X / Scale, Y / Scale);
    if (FRangeControl <> nil) and FRangeControl.IsConnected then
    begin
      MoveRangeTo(FRangeControl, X);
      Exit;
    end;
    if FSelecting and FDragged and (FPressButton = ButtonLeft) then
    begin
      { Dragging past the top or bottom scrolls (and goes on scrolling
        every frame while the pointer stays there). }
      if not AutoscrollSelection then
        ExtendSelectionTo(X, Y)
      else
        RequestFrame;
    end;
    Exit;
  end;
  UpdateHover(X / Scale, Y / Scale);
end;

{ mousemove at the element under the pointer, held while it is
  dispatched; nothing of the hit is used after it. }
procedure TWebEngineView.FireMoveWhilePressed(CssX, CssY: Double);
var
  Hit: THitTestResult;
  Path: TFramePath;
  Target: TElement;
begin
  if FLayout.NeedsUpdate then
    UpdateLayout;
  Hit := HitTestDeep(CssX, CssY, Path);
  Target := Hit.Element;
  if Target = nil then
    Exit;
  Target.Retain;
  try
    FireMouse(Target, 'mousemove', 0, 0);
  finally
    Target.Release;
  end;
end;

procedure TWebEngineView.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Hit: THitTestResult;
  Scale: Double;
  Path: TFramePath;
begin
  NoteUserGesture;
  inherited PointerUp(X, Y, Button);
  FLastPointerX := X;
  FLastPointerY := Y;
  FButtonsHeld := FButtonsHeld and not ButtonsBitOf(Button);
  if FPainter = nil then
    Exit;
  Scale := DeviceScale;
  Hit := HitTestDeep(X / Scale, Y / Scale, Path);
  RetainHit(Hit);
  try
    ReleaseAt(Hit, Button);
  finally
    ReleaseHit(Hit);
  end;
end;

procedure TWebEngineView.ReleaseAt(constref Hit: THitTestResult; Button: LongWord);
var
  Link, Control, Target: TElement;
begin
  FireMouse(Hit.Element, 'mouseup', DomButtonOf(Button), FClickCount);
  if Button <> FPressButton then
    Exit;
  { Held here while they are acted on: the handlers of the click may make
    the view let go of the pressed elements. }
  Link := nil;
  Control := nil;
  Target := nil;
  HoldElement(Link, FPressedLink);
  HoldElement(Control, FPressedControl);
  HoldElement(Target, FPressedTarget);
  try
    FPressButton := 0;
    if Button = ButtonMiddle then
    begin
      if (Link <> nil) and (LinkElementOf(Hit.Node) = Link) then
        ActivateLink(Link, DispositionFor(ButtonMiddle, HeldModifiers, Link));
      HoldElement(FPressedLink, nil);
      Exit;
    end;
    SetChain(FActiveChain, nil);
    FSelecting := False;
    EndRangeDrag;
    if not FDragged then
    begin
      if (Control <> nil) and (FormControlOf(Hit.Node) = Control) then
        ActivateControl(Control)
      else if (Link <> nil) and (LinkElementOf(Hit.Node) = Link) then
        ActivateLink(Link, DispositionFor(ButtonLeft, HeldModifiers, Link))
      else if (Hit.Element <> nil) and (Hit.Element = Target) then
      begin
        ClickElement(Hit.Element);
        if (FClickCount = 2) and Hit.Element.IsConnected then
          FireMouse(Hit.Element, 'dblclick', 0, 2);
      end;
    end;
    HoldElement(FPressedLink, nil);
    HoldElement(FPressedControl, nil);
    HoldElement(FPressedTarget, nil);
  finally
    HoldElement(Link, nil);
    HoldElement(Control, nil);
    HoldElement(Target, nil);
  end;
end;

procedure TWebEngineView.PointerLeave;
begin
  inherited PointerLeave;
  if FPressButton = 0 then
    ClearHover;
end;

procedure TWebEngineView.FocusChanged;
begin
  inherited FocusChanged;
  InvalidateViewport;
end;

{ ---- context menus ---- }

procedure TWebEngineView.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Info: TWebContextInfo;
  Hit: THitTestResult;
  Link, Control: TElement;
  Handled: Boolean;
  Scale: Double;
  Path: TFramePath;
begin
  Info := Default(TWebContextInfo);
  Info.X := X;
  Info.Y := Y;
  Info.FromKeyboard := FromKeyboard;
  Info.SelectedText := SelectedText;
  Info.CanCopy := Info.SelectedText <> '';
  if FPainter <> nil then
  begin
    Scale := DeviceScale;
    Hit := HitTestDeep(X / Scale, Y / Scale, Path);
    RetainHit(Hit);
    try
      if not FromKeyboard and not FireMouse(Hit.Element, 'contextmenu', 2, 0) then
        Exit;
      Link := LinkElementOf(Hit.Node);
      if Link <> nil then
      begin
        Info.LinkUrl := ResolveLink(Link);
        Info.LinkText := Trim(Link.TextContent);
      end;
      if (Hit.Element <> nil) and (Hit.Element.LocalName = 'img') then
        Info.ImageUrl := ResolvedAttribute(Hit.Element, 'src');
      Control := FormControlOf(Hit.Node);
      Info.InTextField := (Control <> nil) and (FormControlKindOf(Control) in [FormControlText, FormControlPassword,
        FormControlTextArea]);
      if Hit.Element <> nil then
      begin
        Info.IsEditable := Info.InTextField or IsEditableElement(Hit.Element);
        Info.BackgroundImageUrl := NearestBackgroundImageUrl(LayoutForDocument(Hit.Element.NodeDocument), Hit.Element);
        if Hit.Element.NodeDocument <> FDocument then
          Info.FrameUrl := Hit.Element.NodeDocument.Url;
      end;
    finally
      ReleaseHit(Hit);
    end;
  end;
  Handled := False;
  if Assigned(FOnContextMenuRequested) then
    FOnContextMenuRequested(Self, Info, Handled);
  if not Handled then
    ShowOwnContextMenu(Info);
end;

const
  CommandBack = 1;
  CommandForward = 2;
  CommandReload = 3;
  CommandCopy = 4;
  CommandCopyLink = 5;
  CommandSelectAll = 6;

procedure TWebEngineView.PopupMenu(Menu: TMenuItem; X, Y: LongInt; OnChosen: TMenuItemEvent);
var
  Window: TControlWindow;
begin
  if Assigned(FOnPopupMenu) and FOnPopupMenu(Self, Menu, X, Y, OnChosen) then
    Exit;
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  ShowPopupMenu(Window, Menu, Window.ScreenLeft + Unscaled(PixelBounds.Left + X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Y), OnChosen);
end;

procedure TWebEngineView.ShowOwnContextMenu(constref Info: TWebContextInfo);
var
  Item: TMenuItem;
begin
  FOwnMenu.Free;
  FOwnMenu := TMenuItem.Create('');
  FMenuLink := Info.LinkUrl;
  Item := FOwnMenu.Add('&Back');
  Item.Tag := CommandBack;
  Item.Enabled := CanGoBack;
  Item := FOwnMenu.Add('&Forward');
  Item.Tag := CommandForward;
  Item.Enabled := CanGoForward;
  Item := FOwnMenu.Add('&Reload');
  Item.Tag := CommandReload;
  FOwnMenu.AddSeparator;
  Item := FOwnMenu.Add('&Copy', nil, 'Ctrl+C');
  Item.Tag := CommandCopy;
  Item.Enabled := Info.SelectedText <> '';
  if Info.LinkUrl <> '' then
  begin
    Item := FOwnMenu.Add('Copy &Link Address');
    Item.Tag := CommandCopyLink;
  end;
  Item := FOwnMenu.Add('Select &All', nil, 'Ctrl+A');
  Item.Tag := CommandSelectAll;
  PopupMenu(FOwnMenu, Info.X, Info.Y, @OwnMenuChosen);
end;

procedure TWebEngineView.OwnMenuChosen(Item: TMenuItem);
begin
  case Item.Tag of
    CommandBack:
      GoBack;
    CommandForward:
      GoForward;
    CommandReload:
      Reload;
    CommandCopy:
      CopySelection;
    CommandCopyLink:
      WriteClipboard(FMenuLink);
    CommandSelectAll:
      SelectAll;
  end;
end;
