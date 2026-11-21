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
  its keydown through), as a WebView.FieldEditing action: characters,
  Backspace and Delete (Ctrl: a word), the arrows, Home and End (Shift
  extends the selection), Ctrl+A, Ctrl+C, Ctrl+X and Ctrl+V, Enter (a line
  break in a text area, the form's submission in a field). }
function TWebView.TypeIntoField(Code, Character, Modifiers: LongWord): Boolean;
var
  Action: TFieldAction;
  Options: TFieldActionOptions;
  Typed: string;
begin
  Result := False;
  if not IsEditableTextField(FFocusedElement) then
    Exit;
  Options := [];
  if (Modifiers and ModifierControl) <> 0 then
    Include(Options, FieldByWord);
  if (Modifiers and ModifierShift) <> 0 then
    Include(Options, FieldExtend);
  Typed := '';
  if FieldByWord in Options then
  begin
    case Code of
      KeyA: Action := FieldSelectAll;
      KeyC: Action := FieldCopy;
      KeyX: Action := FieldCut;
      KeyV: Action := FieldPaste;
      KeyBackspace: Action := FieldDeleteBackward;
      KeyDelete: Action := FieldDeleteForward;
      KeyArrowLeft: Action := FieldMoveLeft;
      KeyArrowRight: Action := FieldMoveRight;
      KeyHome: Action := FieldValueStart;
      KeyEnd: Action := FieldValueEnd;
    else
      Exit;
    end;
  end
  else
    case Code of
      KeyBackspace: Action := FieldDeleteBackward;
      KeyDelete: Action := FieldDeleteForward;
      KeyArrowLeft: Action := FieldMoveLeft;
      KeyArrowRight: Action := FieldMoveRight;
      KeyArrowUp: Action := FieldMoveUp;
      KeyArrowDown: Action := FieldMoveDown;
      KeyHome: Action := FieldLineStart;
      KeyEnd: Action := FieldLineEnd;
      KeyTab, KeyEscape:
        Exit;
    else
      if IsEnterKey(Code) then
        Action := FieldLineBreak
      else if (Character >= 32) and (Character <> 127) and ((Modifiers and ModifierAlt) = 0) then
      begin
        Action := FieldTypeText;
        Typed := CodePointText(Character);
      end
      else
        Exit;
    end;
  Result := FFieldEditor.Perform(FFocusedElement, Action, Typed, Options);
end;

procedure TWebView.FieldSelectionMoved(Element: TElement);
begin
  InvalidateViewport;
  RequestFrame;
end;

function TWebView.ReadClipboard: string;
begin
  Result := ClipboardText;
end;

procedure TWebView.WriteClipboard(const Value: string);
begin
  SetClipboardText(Value);
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
  { The click's listeners may remove the control or move the focus away
    (which releases the focused element): it is held until its
    activation is done. }
  Control.Retain;
  try
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
        if Control.IsConnected then
          OpenSelectMenu(Control);
    end;
  finally
    Control.Release;
  end;
  PostWake;
end;

{ A click on something that is not a link or a control: a label acts on
  its control, a summary opens or closes its details. }
procedure TWebView.ClickElement(Element: TElement);
begin
  Element.Retain;
  try
    if FireEvent(Element, 'click', True, True) then
      ActOnClick(Element);
  finally
    Element.Release;
  end;
  PostWake;
end;

procedure TWebView.ActOnClick(Element: TElement);
var
  Node, Inner: TNode;
  Target: TElement;
  Id: string;
begin
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
end;

procedure TWebView.SubmitForm(Form, Submitter: TElement);
var
  Target: TUrlRecord;
  Options: TNavigateOptions;
  ScrollX, ScrollY: Single;
begin
  if (Form = nil) or (FPage = nil) or (FPage.Navigable.Loader = nil) then
    Exit;
  { The submit event's listeners may take the form (and the submitter)
    out of the document. }
  Form.Retain;
  if Submitter <> nil then
    Submitter.Retain;
  try
    if not FireEvent(Form, 'submit', True, True) then
      Exit;
    if (FPage.Navigable.Loader = nil) or
      not BuildFormSubmission(Form, Submitter, FPage.Navigable.Loader, Target, Options) then
      Exit;
  finally
    if Submitter <> nil then
      Submitter.Release;
    Form.Release;
  end;
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
