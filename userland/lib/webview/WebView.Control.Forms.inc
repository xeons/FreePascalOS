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

{ WebView.Control: form controls, labels and details. }

function CodePointToUtf8(CodePoint: LongWord): string;
begin
  if CodePoint < $80 then
    Result := Chr(CodePoint)
  else if CodePoint < $800 then
    Result := Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Chr($E0 or (CodePoint shr 12)) + Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F))
  else
    Result := Chr($F0 or (CodePoint shr 18)) + Chr($80 or ((CodePoint shr 12) and $3F)) +
      Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
end;

procedure TWebView.ControlEdited(Element: TElement);
begin
  FireEvent(Element, 'input', True);
  InvalidateViewport;
  RequestFrame;
  PostWake;
end;

function TWebView.TypeIntoField(Code, Character, Modifiers: LongWord): Boolean;
var
  Kind: TFormControlKind;
  Value, Pasted: string;
  Element: TElement;
begin
  Result := False;
  Element := FFocusedElement;
  if Element = nil then
    Exit;
  Kind := FormControlKindOf(Element);
  if not (Kind in [FormControlText, FormControlPassword, FormControlTextArea]) then
    Exit;
  if Element.HasAttribute('readonly') or IsDisabledControl(Element) then
    Exit;
  Value := ControlValue(Element);
  if (Modifiers and ModifierControl) <> 0 then
  begin
    if Code = KeyV then
    begin
      Pasted := ClipboardText;
      if Kind <> FormControlTextArea then
      begin
        if Pos(#10, Pasted) > 0 then
          Pasted := Copy(Pasted, 1, Pos(#10, Pasted) - 1);
        Pasted := StringReplace(Pasted, #13, '', [rfReplaceAll]);
      end;
      SetControlValue(Element, Value + Pasted);
      ControlEdited(Element);
      Exit(True);
    end;
    Exit;
  end;
  if Code = KeyTab then
    Exit;
  if Code = KeyBackspace then
  begin
    if Value <> '' then
    begin
      SetControlValue(Element, WithoutLastCharacter(Value));
      ControlEdited(Element);
    end;
    Exit(True);
  end;
  if Code = KeyEscape then
  begin
    SetFocusedElement(nil, False);
    Exit(True);
  end;
  if IsEnterKey(Code) then
  begin
    if Kind = FormControlTextArea then
    begin
      SetControlValue(Element, Value + #10);
      ControlEdited(Element);
    end
    else
    begin
      FireEvent(Element, 'change', True);
      SubmitForm(FormOwnerOf(Element), nil);
    end;
    Exit(True);
  end;
  if (Code = KeyArrowLeft) or (Code = KeyArrowRight) or (Code = KeyHome) or (Code = KeyEnd) or (Code = KeyDelete) then
    Exit(True);
  if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierAlt) = 0) then
  begin
    SetControlValue(Element, Value + CodePointToUtf8(Character));
    ControlEdited(Element);
    Exit(True);
  end;
end;

procedure TWebView.ActivateControl(Control: TElement);
var
  Kind: TFormControlKind;
begin
  if (Control = nil) or IsDisabledControl(Control) then
    Exit;
  Kind := FormControlKindOf(Control);
  if Kind in [FormControlText, FormControlPassword, FormControlTextArea] then
  begin
    SetFocusedElement(Control, FFocusVisible and (Control = FFocusedElement));
    InvalidateViewport;
    Exit;
  end;
  if not FireEvent(Control, 'click', True, True) then
    Exit;
  case Kind of
    FormControlCheckbox:
      begin
        ToggleCheckbox(Control);
        ControlEdited(Control);
        FireEvent(Control, 'change', True);
      end;
    FormControlRadio:
      if not Control.HasAttribute('checked') then
      begin
        CheckRadioButton(Control);
        ControlEdited(Control);
        FireEvent(Control, 'change', True);
      end;
    FormControlSubmit:
      SubmitForm(FormOwnerOf(Control), Control);
    FormControlSelect:
      OpenSelectMenu(Control);
  end;
  PostWake;
end;

{ A click on something that is not a link or a control: a label acts on
  its control, a summary opens or closes its details. }
procedure TWebView.ClickElement(Element: TElement);
var
  Node, Inner: TNode;
  Target: TElement;
  Id: string;
begin
  if not FireEvent(Element, 'click', True, True) then
    Exit;
  Node := Element;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      if TElement(Node).LocalName = 'label' then
      begin
        Target := nil;
        Id := TElement(Node).GetAttribute('for');
        if (Id <> '') and (FDocument <> nil) then
          Target := FDocument.GetElementById(Id)
        else
        begin
          Inner := Node.NextInTree(Node);
          while Inner <> nil do
          begin
            if Inner.IsElement and (FormControlKindOf(TElement(Inner)) <> FormControlNone) then
            begin
              Target := TElement(Inner);
              Break;
            end;
            Inner := Inner.NextInTree(Node);
          end;
        end;
        if (Target <> nil) and (FormControlKindOf(Target) <> FormControlNone) then
        begin
          SetFocusedElement(Target, False);
          if not (FormControlKindOf(Target) in [FormControlText, FormControlPassword, FormControlTextArea]) then
            ActivateControl(Target);
        end;
        Exit;
      end;
      if (TElement(Node).LocalName = 'summary') and (TElement(Node).ParentElement <> nil) and
         (TElement(Node).ParentElement.LocalName = 'details') then
      begin
        TElement(Node).ParentElement.ToggleAttribute('open');
        FireEvent(TElement(Node).ParentElement, 'toggle');
        RequestFrame;
        PostWake;
        Exit;
      end;
    end;
    Node := Node.ParentNode;
  end;
  PostWake;
end;

procedure TWebView.SubmitForm(Form, Submitter: TElement);
var
  Target: TUrlRecord;
  Options: TNavigateOptions;
  ScrollX, ScrollY: Single;
begin
  if (Form = nil) or (FPage = nil) or (FPage.Navigable.Loader = nil) then
    Exit;
  if not FireEvent(Form, 'submit', True, True) then
    Exit;
  if not BuildFormSubmission(Form, Submitter, FPage.Navigable.Loader, Target, Options) then
    Exit;
  Options.Source := FPage.Navigable.Loader;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  FPage.Navigable.SaveScrollPosition(ScrollX, ScrollY);
  FPage.Navigable.Navigate(Target, Options);
  PostWake;
end;

procedure TWebView.OpenSelectMenu(Select: TElement);
var
  Options: TSelectOptionArray;
  Index: Integer;
  Item: TMenuItem;
  Window: TControlWindow;
  X, Y, Width, Height: Single;
  ScrollX, ScrollY: Single;
  Scale: Double;
begin
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) or (FLayout = nil) then
    Exit;
  if not FLayout.NodeBounds(Select, X, Y, Width, Height) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  Options := SelectOptions(Select);
  if Length(Options) = 0 then
    Exit;
  FSelectMenu.Free;
  FSelectMenu := TMenuItem.Create('');
  for Index := 0 to High(Options) do
  begin
    Item := FSelectMenu.Add(StringReplace(Options[Index].Text, '&', '&&', [rfReplaceAll]));
    Item.Tag := Index;
    Item.Checked := Options[Index].Selected;
    Item.Enabled := not Options[Index].Disabled;
  end;
  HoldElement(FSelectElement, Select);
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Scale := DeviceScale;
  ShowPopupMenu(Window, FSelectMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left + Round((X - ScrollX) * Scale)),
    Window.ScreenTop + Unscaled(PixelBounds.Top + Round((Y + Height - ScrollY) * Scale)), @SelectOptionChosen);
end;

procedure TWebView.SelectOptionChosen(Item: TMenuItem);
var
  Options: TSelectOptionArray;
begin
  if (FSelectElement = nil) or not FSelectElement.IsConnected then
    Exit;
  Options := SelectOptions(FSelectElement);
  if (Item.Tag < 0) or (Item.Tag > High(Options)) then
    Exit;
  ChooseSelectOption(FSelectElement, Options[Item.Tag].Element);
  ControlEdited(FSelectElement);
  FireEvent(FSelectElement, 'change', True);
end;
