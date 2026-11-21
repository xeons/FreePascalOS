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
  Form controls as the web view works them, through the DOM (the
  engine has no separate control state yet, so a control's value is
  its value attribute, a text area's its text, a check box's its
  checked attribute; layout draws what they say):

  - typing into text fields and text areas (characters, Backspace, a
    line break in a text area);
  - check boxes toggled, radio buttons checked with the others of their
    group (same name and form owner) unchecked;
  - a select's options, and choosing one;
  - building a form submission (HTML's "constructing the entry list"
    in brief, application/x-www-form-urlencoded): GET puts the entries
    in the action URL's query, POST in the body.
}
unit WebView.Forms;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Navigation.Navigables;

type
  TSelectOption = record
    Element: TElement;
    Text: string;
    Selected: Boolean;
    Disabled: Boolean;
  end;
  TSelectOptionArray = array of TSelectOption;

function ControlValue(Element: TElement): string;
procedure SetControlValue(Element: TElement; const Value: string);
{ Value with its last character (UTF-8) taken off. }
function WithoutLastCharacter(const Value: string): string;
procedure ToggleCheckbox(Element: TElement);
procedure CheckRadioButton(Element: TElement);
function SelectOptions(Select: TElement): TSelectOptionArray;
procedure ChooseSelectOption(Select, Option: TElement);
{ The navigation a form's submission makes; False when it makes none. }
function BuildFormSubmission(Form, Submitter: TElement; Context: TLoadingContext; out Url: TUrlRecord;
  out Options: TNavigateOptions): Boolean;
{ HTML 4.10.21.2: the form's default button (its first submit button in
  tree order), nil without one. }
function DefaultButtonOf(Form: TElement): TElement;
{ Submits Form in Navigable: the submit event (cancelable), then the
  navigation its entries make; False when nothing was submitted. Form
  and Submitter are held while the page's listeners run. }
function SubmitFormIn(Navigable: TNavigable; Form, Submitter: TElement): Boolean;

implementation

uses
  Web.Dom.FormControls,
  Web.Navigation.Events,
  Url.Parser,
  Url.FormEncoding,
  Web.Atoms,
  WebView.Elements;

var
  AtomValue, AtomChecked, AtomName, AtomType, AtomOption, AtomSelected, AtomDisabled, AtomAction, AtomMethod,
    AtomMultiple, AtomInput, AtomForm, AtomOptgroup, AtomLabel: TAtom;

procedure MakeAtoms;
begin
  AtomValue := Atomize('value');
  AtomChecked := Atomize('checked');
  AtomName := Atomize('name');
  AtomType := Atomize('type');
  AtomOption := Atomize('option');
  AtomSelected := Atomize('selected');
  AtomDisabled := Atomize('disabled');
  AtomAction := Atomize('action');
  AtomMethod := Atomize('method');
  AtomMultiple := Atomize('multiple');
  AtomInput := Atomize('input');
  AtomForm := Atomize('form');
  AtomOptgroup := Atomize('optgroup');
  AtomLabel := Atomize('label');
end;

function ControlValue(Element: TElement): string;
begin
  Result := TextControlValue(Element);
end;

procedure SetControlValue(Element: TElement; const Value: string);
begin
  SetTextControlValue(Element, Value);
end;

function WithoutLastCharacter(const Value: string): string;
var
  Last: Integer;
begin
  Last := Length(Value);
  { Back over continuation bytes to the character's lead byte. }
  while (Last > 1) and ((Ord(Value[Last]) and $C0) = $80) do
    Dec(Last);
  Result := Copy(Value, 1, Last - 1);
end;

procedure ToggleCheckbox(Element: TElement);
begin
  SetInputChecked(Element, not InputChecked(Element));
end;

procedure CheckRadioButton(Element: TElement);
begin
  SetInputChecked(Element, True);
end;

function OptionText(Option: TElement): string;
begin
  if Option.HasAttributeAtom(AtomLabel) then
    Result := Option.AttributeValueOf(AtomLabel)
  else
    Result := Trim(Option.TextContent);
end;

function SelectOptions(Select: TElement): TSelectOptionArray;
var
  Node: TNode;
  Option: TElement;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  Node := Select.NextInTree(Select);
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).IsHtmlElement(AtomOption) then
    begin
      Option := TElement(Node);
      SetLength(Result, Count + 1);
      Result[Count].Element := Option;
      Result[Count].Text := OptionText(Option);
      Result[Count].Selected := OptionSelected(Option);
      Result[Count].Disabled := Option.HasAttributeAtom(AtomDisabled) or
        ((Option.ParentElement <> nil) and Option.ParentElement.IsHtmlElement(AtomOptgroup) and
         Option.ParentElement.HasAttributeAtom(AtomDisabled));
      Inc(Count);
    end;
    Node := Node.NextInTree(Select);
  end;
end;

procedure ChooseSelectOption(Select, Option: TElement);
begin
  SetOptionSelected(Option, True);
end;

function OptionValue(Option: TElement): string;
begin
  if Option.HasAttributeAtom(AtomValue) then
    Result := Option.AttributeValueOf(AtomValue)
  else
    Result := Trim(Option.TextContent);
end;

procedure AddEntry(var List: TNameValueList; const Name, Value: string);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)].Name := Name;
  List[High(List)].Value := Value;
end;

procedure AddSelectEntries(var List: TNameValueList; Select: TElement; const Name: string);
var
  Options: TSelectOptionArray;
  Index: Integer;
  AnySelected: Boolean;
begin
  Options := SelectOptions(Select);
  AnySelected := False;
  for Index := 0 to High(Options) do
    if Options[Index].Selected and not Options[Index].Disabled then
    begin
      AddEntry(List, Name, OptionValue(Options[Index].Element));
      AnySelected := True;
      if not Select.HasAttributeAtom(AtomMultiple) then
        Exit;
    end;
  { A single select shows its first option when none is selected. }
  if not AnySelected and not Select.HasAttributeAtom(AtomMultiple) then
    for Index := 0 to High(Options) do
      if not Options[Index].Disabled then
      begin
        AddEntry(List, Name, OptionValue(Options[Index].Element));
        Exit;
      end;
end;

function FormEntries(Form, Submitter: TElement): TNameValueList;
var
  Node: TNode;
  Element: TElement;
  Name: string;
  Kind: TFormControlKind;
  Document: TDocument;
begin
  Result := nil;
  Document := Form.OwnerDocument;
  Node := Document;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      Kind := FormControlKindOf(Element);
      Name := Element.AttributeValueOf(AtomName);
      if (Kind <> FormControlNone) and (Name <> '') and not IsDisabledControl(Element) and
         (FormOwnerOf(Element) = Form) then
        case Kind of
          FormControlCheckbox, FormControlRadio:
            if InputChecked(Element) then
            begin
              if Element.HasAttributeAtom(AtomValue) then
                AddEntry(Result, Name, Element.AttributeValueOf(AtomValue))
              else
                AddEntry(Result, Name, 'on');
            end;
          FormControlSubmit, FormControlButton, FormControlReset:
            if (Element = Submitter) and (Kind = FormControlSubmit) then
              AddEntry(Result, Name, Element.AttributeValueOf(AtomValue));
          FormControlSelect:
            AddSelectEntries(Result, Element, Name);
          FormControlTextArea:
            AddEntry(Result, Name, StringReplace(TextAreaValue(Element), #10, #13#10, [rfReplaceAll]));
        else
          AddEntry(Result, Name, InputValue(Element));
        end;
    end;
    Node := Node.NextInTree(Document);
  end;
end;

function BuildFormSubmission(Form, Submitter: TElement; Context: TLoadingContext; out Url: TUrlRecord;
  out Options: TNavigateOptions): Boolean;
var
  Action, Method, Encoded: string;
begin
  Result := False;
  Options := DefaultNavigateOptions;
  Url := Default(TUrlRecord);
  if (Form = nil) or (Context = nil) then
    Exit;
  Action := Trim(Form.AttributeValueOf(AtomAction));
  Method := LowerCase(Trim(Form.AttributeValueOf(AtomMethod)));
  if (Submitter <> nil) and Submitter.HasAttribute('formaction') then
    Action := Trim(Submitter.GetAttribute('formaction'));
  if (Submitter <> nil) and Submitter.HasAttribute('formmethod') then
    Method := LowerCase(Trim(Submitter.GetAttribute('formmethod')));
  if Action = '' then
    Url := Context.DocumentUrl
  else if not Context.ResolveUrl(Action, Url) then
    Exit;
  if (Url.Scheme <> 'http') and (Url.Scheme <> 'https') and (Url.Scheme <> 'file') then
    Exit;
  Encoded := SerializeFormEncoded(FormEntries(Form, Submitter));
  Options.UserInitiated := True;
  if Method = 'post' then
  begin
    Options.Method := 'POST';
    Options.Body := BytesOf(Encoded);
    Options.ContentType := 'application/x-www-form-urlencoded';
  end
  else
  begin
    Url.HasQuery := True;
    Url.Query := Encoded;
  end;
  Url.HasFragment := False;
  Url.Fragment := '';
  Result := True;
end;

function DefaultButtonOf(Form: TElement): TElement;
var
  Node: TNode;
begin
  Result := nil;
  if Form = nil then
    Exit;
  Node := Form.NextInTree(Form);
  while Node <> nil do
  begin
    if Node.IsElement and (FormControlKindOf(TElement(Node)) = FormControlSubmit) and
      (FormOwnerOf(TElement(Node)) = Form) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Form);
  end;
end;

function SubmitFormIn(Navigable: TNavigable; Form, Submitter: TElement): Boolean;
var
  Target: TUrlRecord;
  Options: TNavigateOptions;
begin
  Result := False;
  { HTML 4.10.21.3: a form that is not in a document cannot navigate
    (before the submit event and after it). }
  if (Form = nil) or not Form.IsConnected or (Navigable = nil) or (Navigable.Loader = nil) then
    Exit;
  { The submit event's listeners may take the form (and the submitter)
    out of the document. }
  Form.Retain;
  if Submitter <> nil then
    Submitter.Retain;
  try
    if not FireEvent(Form, 'submit', True, True) or not Form.IsConnected then
      Exit;
    if (Navigable.Loader = nil) or not BuildFormSubmission(Form, Submitter, Navigable.Loader, Target, Options) then
      Exit;
  finally
    if Submitter <> nil then
      Submitter.Release;
    Form.Release;
  end;
  Options.Source := Navigable.Loader;
  Navigable.Navigate(Target, Options);
  Result := True;
end;

initialization
  MakeAtoms;

end.
