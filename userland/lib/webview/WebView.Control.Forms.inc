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

procedure TWebView.ControlEdited(Element: TElement);
begin
  FireEvent(Element, 'input', True);
  InvalidateViewport;
  RequestFrame;
  PostWake;
end;

procedure TWebView.FireInputEvent(Element: TElement; const InputType, Data: string);
begin
  DispatchInputEvent(Element, InputType, Data, (InputType = 'insertText') or (InputType = 'insertFromPaste'));
  InvalidateViewport;
  RequestFrame;
  PostWake;
end;

function TWebView.DispatchKeyboardEvent(const EventType: string; Code, Character, Modifiers: LongWord): Boolean;
var
  Target: TObject;
begin
  Result := True;
  if FDocument = nil then
    Exit;
  if (FFocusedElement <> nil) and FFocusedElement.IsConnected then
    Target := FFocusedElement
  else if FDocument.Body <> nil then
    Target := FDocument.Body
  else if FDocument.DocumentElement <> nil then
    Target := FDocument.DocumentElement
  else
    Target := FDocument;
  Result := DispatchKeyEvent(Target, EventType, Code, Character, Modifiers);
  PostWake;
end;

{ HTML 4.10.21.2: Enter in a field presses the form's default button (its
  first submit button) or, without one, submits the form. }
procedure TWebView.SubmitImplicitly(Field: TElement);
var
  Form: TElement;
  Node: TNode;
begin
  Form := FormOwnerOf(Field);
  if Form = nil then
    Exit;
  Node := Form.NextInTree(Form);
  while Node <> nil do
  begin
    if Node.IsElement and (FormControlKindOf(TElement(Node)) = FormControlSubmit) and
      (FormOwnerOf(TElement(Node)) = Form) then
    begin
      if not IsDisabledControl(TElement(Node)) then
        ActivateControl(TElement(Node));
      Exit;
    end;
    Node := Node.NextInTree(Form);
  end;
  SubmitForm(Form, nil);
end;

{ The editing a key does in the focused text control (after the page let
  its keydown through): characters, Backspace and Delete (Ctrl: a word),
  the arrows, Home and End (Shift extends the selection), Ctrl+A, Ctrl+C,
  Ctrl+X and Ctrl+V, Enter (a line break in a text area, the form's
  submission in a field). }
function TWebView.TypeIntoField(Code, Character, Modifiers: LongWord): Boolean;
var
  Kind: TFormControlKind;
  Element: TElement;
  Edit: TTextEdit;
  Start, Finish, MaximumLength: Integer;
  Direction, Before: string;
  Control, Shift, MultiLine, ReadOnly: Boolean;

  procedure Commit(const InputType, Data: string);
  begin
    if Edit.Value <> Before then
      SetTextControlValue(Element, Edit.Value);
    SetTextSelection(Element, Edit.SelectionStart, Edit.SelectionEnd, Edit.Direction);
    if Edit.Value <> Before then
      FireInputEvent(Element, InputType, Data)
    else
    begin
      InvalidateViewport;
      RequestFrame;
    end;
  end;

  procedure InsertText(const Text, InputType: string);
  begin
    if ReadOnly then
      Exit;
    if (MaximumLength >= 0) and (Utf16CountOf(Edit.Value) - (Edit.SelectionEnd - Edit.SelectionStart) +
      Utf16CountOf(Text) > MaximumLength) then
      Exit;
    Edit.Insert(Text, MultiLine);
    Commit(InputType, Text);
  end;

begin
  Result := False;
  Element := FFocusedElement;
  if (Element = nil) or not IsTextControl(Element) or IsDisabledControl(Element) then
    Exit;
  Kind := FormControlKindOf(Element);
  MultiLine := Kind = FormControlTextArea;
  ReadOnly := Element.HasAttribute('readonly');
  MaximumLength := -1;
  if Element.HasAttribute('maxlength') then
    MaximumLength := StrToIntDef(Element.GetAttribute('maxlength'), -1);
  Control := (Modifiers and ModifierControl) <> 0;
  Shift := (Modifiers and ModifierShift) <> 0;
  Edit.Value := TextControlValue(Element);
  Before := Edit.Value;
  GetTextSelection(Element, Start, Finish, Direction);
  Edit.SetSelection(Start, Finish, Direction);
  Result := True;
  if Control then
  begin
    case Code of
      KeyA:
        begin
          Edit.Move(MoveAll, False);
          Commit('', '');
        end;
      KeyC:
        if Edit.HasSelectedText and (Kind <> FormControlPassword) then
          SetClipboardText(Edit.SelectedText);
      KeyX:
        if Edit.HasSelectedText and not ReadOnly and (Kind <> FormControlPassword) then
        begin
          SetClipboardText(Edit.SelectedText);
          Edit.DeleteBackward(False);
          Commit('deleteByCut', '');
        end;
      KeyV:
        InsertText(ClipboardText, 'insertFromPaste');
      KeyBackspace:
        if not ReadOnly and Edit.DeleteBackward(True) then
          Commit('deleteWordBackward', '');
      KeyDelete:
        if not ReadOnly and Edit.DeleteForward(True) then
          Commit('deleteWordForward', '');
      KeyArrowLeft:
        begin
          Edit.Move(MoveWordLeft, Shift);
          Commit('', '');
        end;
      KeyArrowRight:
        begin
          Edit.Move(MoveWordRight, Shift);
          Commit('', '');
        end;
      KeyHome:
        begin
          Edit.SetSelection(0, 0, 'none');
          Commit('', '');
        end;
      KeyEnd:
        begin
          Edit.SetSelection(Utf16CountOf(Edit.Value), Utf16CountOf(Edit.Value), 'none');
          Commit('', '');
        end;
    else
      Result := False;
    end;
    Exit;
  end;
  case Code of
    KeyBackspace:
      if not ReadOnly and Edit.DeleteBackward(False) then
        Commit('deleteContentBackward', '');
    KeyDelete:
      if not ReadOnly and Edit.DeleteForward(False) then
        Commit('deleteContentForward', '');
    KeyArrowLeft:
      begin
        Edit.Move(MoveCharacterLeft, Shift);
        Commit('', '');
      end;
    KeyArrowRight:
      begin
        Edit.Move(MoveCharacterRight, Shift);
        Commit('', '');
      end;
    KeyHome:
      begin
        Edit.Move(MoveLineStart, Shift);
        Commit('', '');
      end;
    KeyEnd:
      begin
        Edit.Move(MoveLineEnd, Shift);
        Commit('', '');
      end;
    KeyArrowUp, KeyArrowDown:
      if MultiLine then
      begin
        if Code = KeyArrowUp then
          Edit.Move(MoveLineUp, Shift)
        else
          Edit.Move(MoveLineDown, Shift);
        Commit('', '');
      end
      else
        Result := False;
    KeyTab, KeyEscape:
      Result := False;
  else
    if IsEnterKey(Code) then
    begin
      if MultiLine then
        InsertText(#10, 'insertLineBreak')
      else
        SubmitImplicitly(Element);
    end
    else if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierAlt) = 0) then
      InsertText(CodePointText(Character), 'insertText')
    else
      Result := False;
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
  if not FireClick(Control) then
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
  if not FireClick(Element) then
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
        if Id <> '' then
          Target := Node.NodeDocument.GetElementById(Id)
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
  Source, Destination: TNavigable;
begin
  { A form in a frame submits from (and by default into) its frame. }
  Source := NavigableForNode(Form);
  if (Form = nil) or (Source = nil) or (Source.Loader = nil) then
    Exit;
  if not FireEvent(Form, 'submit', True, True) then
    Exit;
  if not BuildFormSubmission(Form, Submitter, Source.Loader, Target, Options) then
    Exit;
  Options.Source := Source.Loader;
  Destination := Source.ChooseNavigable(Trim(Form.GetAttribute('target')));
  if Destination = nil then
    Destination := Source;
  if Destination = FPage.Navigable then
  begin
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
    FPage.Navigable.SaveScrollPosition(ScrollX, ScrollY);
  end;
  Destination.Navigate(Target, Options);
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
