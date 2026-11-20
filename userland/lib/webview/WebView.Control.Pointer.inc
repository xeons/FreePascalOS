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

{ WebView.Control: the pointer, element states, links, the focus, context menus. }

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

function TWebView.StatesOf(Element: TElement): TCssElementStates;
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
      Node := Node.ParentNode;
    end;
  end;
end;

procedure TWebView.ApplyStates(Element: TElement);
begin
  if (FLayout <> nil) and (Element <> nil) and Element.IsConnected then
    FLayout.SetElementStates(Element, StatesOf(Element));
end;

{ Chain becomes Element and its ancestors; every element that joined or
  left gets its states again. }
procedure TWebView.SetChain(var Chain: TElementChain; Element: TElement);
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
    Node := Node.ParentNode;
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

procedure TWebView.SetFocusedElement(Element: TElement; ShowFocus: Boolean);
var
  Old: TElement;
  Node: TNode;
begin
  if (Element = FFocusedElement) and (ShowFocus = FFocusVisible) then
    Exit;
  Old := FFocusedElement;
  FFocusedElement := Element;
  FFocusVisible := ShowFocus;
  if Element <> nil then
    Element.Retain;
  if Old <> nil then
  begin
    { The old one and its ancestors lose :focus and :focus-within. }
    Node := Old;
    while Node <> nil do
    begin
      if Node.IsElement then
        ApplyStates(TElement(Node));
      Node := Node.ParentNode;
    end;
    if Old.IsConnected then
      FireEvent(Old, 'blur');
    Old.Release;
  end;
  Node := Element;
  while Node <> nil do
  begin
    if Node.IsElement then
      ApplyStates(TElement(Node));
    Node := Node.ParentNode;
  end;
  if Element <> nil then
    FireEvent(Element, 'focus');
  RequestFrame;
  InvalidateViewport;
  PostWake;
end;

procedure TWebView.SetStatus(const Value: string);
begin
  if Value = FStatusText then
    Exit;
  FStatusText := Value;
  if Assigned(FOnStatusText) then
    FOnStatusText(Self, Value);
end;

procedure TWebView.UpdateHover(CssX, CssY: Double);
var
  Hit: THitTestResult;
  Link, Control: TElement;
  Shape: LongWord;
begin
  if FPainter = nil then
    Exit;
  if FLayout.NeedsUpdate then
    UpdateLayout;
  Hit := FPainter.HitTest(CssX, CssY);
  SetChain(FHoverChain, Hit.Element);
  Link := LinkElementOf(Hit.Node);
  if Link <> nil then
    SetStatus(ResolveLink(Link))
  else
    SetStatus('');
  Shape := PointerShapeForCursor(Hit.Box, (Hit.Node <> nil) and Hit.Node.IsText, Link <> nil);
  Control := FormControlOf(Hit.Node);
  if (Control <> nil) and (Shape = PointerTextBeam) and
     not (FormControlKindOf(Control) in [FormControlText, FormControlPassword, FormControlTextArea]) then
    Shape := PointerArrow
  else if (Control <> nil) and (FormControlKindOf(Control) in [FormControlText, FormControlPassword,
     FormControlTextArea]) and (Shape = PointerArrow) then
    Shape := PointerTextBeam;
  PointerShape := Shape;
end;

procedure TWebView.ClearHover;
begin
  SetChain(FHoverChain, nil);
  SetStatus('');
end;

function TWebView.ResolveLink(Link: TElement): string;
var
  Target: TUrlRecord;
begin
  Result := '';
  if (Link = nil) or (FPage = nil) or (FPage.Navigable.Loader = nil) then
    Exit;
  if FPage.Navigable.Loader.ResolveUrl(Trim(Link.GetAttribute('href')), Target) then
    Result := SerializeUrl(Target);
end;

function TWebView.DispositionFor(Button, Modifiers: LongWord; Link: TElement): TLinkDisposition;
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
    Target := LowerCase(Trim(Link.GetAttribute('target')));
    if (Target = '_blank') or ((Target <> '') and (Target <> '_self') and (Target <> '_top') and
       (Target <> '_parent')) then
      Result := LinkInNewTab;
  end;
end;

procedure TWebView.ActivateLink(Link: TElement; Disposition: TLinkDisposition);
var
  UrlText: string;
  Target: TUrlRecord;
  Options: TNavigateOptions;
  Handled: Boolean;
  ScrollX, ScrollY: Single;
begin
  UrlText := ResolveLink(Link);
  if UrlText = '' then
    Exit;
  if (Disposition = LinkInView) and not FireEvent(Link, 'click', True, True) then
    Exit;
  if not ParseUrl(UrlText, Target) or (Target.Scheme = 'javascript') then
    Exit;
  Handled := False;
  if Assigned(FOnLinkClicked) then
    FOnLinkClicked(Self, UrlText, Disposition, Handled);
  if Handled then
    Exit;
  Options := DefaultNavigateOptions;
  Options.UserInitiated := True;
  Options.Source := FPage.Navigable.Loader;
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

procedure TWebView.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Hit: THitTestResult;
  Control, Link: TElement;
  Position, WordStart, WordEnd: TTextPosition;
  Now: QWord;
  Scale: Double;
begin
  inherited PointerDown(X, Y, Button);
  SetFocus;
  FLastPointerX := X;
  FLastPointerY := Y;
  if FPainter = nil then
    Exit;
  if FLayout.NeedsUpdate then
    UpdateLayout;
  Scale := DeviceScale;
  Hit := FPainter.HitTest(X / Scale, Y / Scale);
  if Button = ButtonMiddle then
  begin
    FPressButton := ButtonMiddle;
    HoldElement(FPressedLink, LinkElementOf(Hit.Node));
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
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
    Exit;
  end;
  if Link <> nil then
  begin
    SetFocusedElement(Link, False);
    Exit;
  end;
  SetFocusedElement(nil, False);
  Position := TextPositionAt(X, Y);
  Now := GetTickCount64;
  if (Now - FLastClickTime < DoubleClickMilliseconds) and not MovedPast(X, Y, FLastClickX, FLastClickY) and
     (Position.Run >= 0) then
  begin
    FTextIndex.WordAround(Position, WordStart, WordEnd);
    SetSelection(WordStart, WordEnd);
    FLastClickTime := 0;
    FSelecting := False;
    Exit;
  end;
  FLastClickTime := Now;
  FLastClickX := X;
  FLastClickY := Y;
  FSelecting := True;
  SetSelection(Position, Position);
end;

procedure TWebView.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Scale: Double;
begin
  inherited PointerMove(X, Y, Buttons);
  FLastPointerX := X;
  FLastPointerY := Y;
  if FPainter = nil then
    Exit;
  Scale := DeviceScale;
  if FPressButton = ButtonLeft then
  begin
    if not FDragged and MovedPast(X, Y, FPressX, FPressY) then
      FDragged := True;
    if FSelecting and FDragged then
    begin
      { Dragging past the top or bottom scrolls. }
      if Y < 0 then
        ScrollBy(0, Y / Scale)
      else if Y > ViewportPixelHeight then
        ScrollBy(0, (Y - ViewportPixelHeight) / Scale);
      SetSelection(FSelectionAnchor, TextPositionAt(X, Y));
    end;
    Exit;
  end;
  UpdateHover(X / Scale, Y / Scale);
end;

procedure TWebView.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Hit: THitTestResult;
  Scale: Double;
  Link, Control: TElement;
begin
  inherited PointerUp(X, Y, Button);
  if (FPainter = nil) or (Button <> FPressButton) then
    Exit;
  Scale := DeviceScale;
  Hit := FPainter.HitTest(X / Scale, Y / Scale);
  Link := FPressedLink;
  Control := FPressedControl;
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
  if not FDragged then
  begin
    if (Control <> nil) and (FormControlOf(Hit.Node) = Control) then
      ActivateControl(Control)
    else if (Link <> nil) and (LinkElementOf(Hit.Node) = Link) then
      ActivateLink(Link, DispositionFor(ButtonLeft, HeldModifiers, Link))
    else if Hit.Element <> nil then
      ClickElement(Hit.Element);
  end;
  HoldElement(FPressedLink, nil);
  HoldElement(FPressedControl, nil);
end;

procedure TWebView.PointerLeave;
begin
  inherited PointerLeave;
  if FPressButton = 0 then
    ClearHover;
end;

procedure TWebView.FocusChanged;
begin
  inherited FocusChanged;
  InvalidateViewport;
end;

{ ---- context menus ---- }

procedure TWebView.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
var
  Info: TWebContextInfo;
  Hit: THitTestResult;
  Link, Control: TElement;
  Handled: Boolean;
  Scale: Double;
begin
  Info := Default(TWebContextInfo);
  Info.X := X;
  Info.Y := Y;
  Info.FromKeyboard := FromKeyboard;
  Info.SelectedText := SelectedText;
  if FPainter <> nil then
  begin
    Scale := DeviceScale;
    Hit := FPainter.HitTest(X / Scale, Y / Scale);
    Link := LinkElementOf(Hit.Node);
    if Link <> nil then
    begin
      Info.LinkUrl := ResolveLink(Link);
      Info.LinkText := Trim(Link.TextContent);
    end;
    if (Hit.Element <> nil) and (Hit.Element.LocalName = 'img') and (FPage <> nil) and (FPage.Navigable.Loader <> nil) then
      Info.ImageUrl := Hit.Element.GetAttribute('src');
    Control := FormControlOf(Hit.Node);
    Info.InTextField := (Control <> nil) and (FormControlKindOf(Control) in [FormControlText, FormControlPassword,
      FormControlTextArea]);
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

procedure TWebView.ShowOwnContextMenu(constref Info: TWebContextInfo);
var
  Window: TControlWindow;
  Item: TMenuItem;
begin
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
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
  ShowPopupMenu(Window, FOwnMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Info.X),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Info.Y), @OwnMenuChosen);
end;

procedure TWebView.OwnMenuChosen(Item: TMenuItem);
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
      SetClipboardText(FMenuLink);
    CommandSelectAll:
      SelectAll;
  end;
end;
