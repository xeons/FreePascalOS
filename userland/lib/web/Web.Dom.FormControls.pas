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
  Form controls' state and values (HTML Standard 4.10), shared by the
  script bindings, the web view and the styler: an input's type and value
  mode, its value and checkedness (with the dirty flags: what script and
  the user change is the state, not the attributes), radio groups, a
  textarea's raw value, options' selectedness and a select's selected
  index, the text selection of a text control, and the form owner (the
  nearest form ancestor; the form attribute is not looked at yet). The
  state lives with the element (its rare data), so every window and the
  view see the same value.
}
unit Web.Dom.FormControls;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom;

type
  { The state of a form control that is not in its attributes. }
  TFormControlState = class
  public
    Value: string;
    ValueDirty: Boolean;
    Checked: Boolean;
    CheckedDirty: Boolean;
    Selected: Boolean;
    SelectedDirty: Boolean;
    Indeterminate: Boolean;
    CustomValidity: string;
    { The text selection of a text control, in UTF-16 code units of its
      value (start = end: the caret). }
    SelectionStart: Integer;
    SelectionEnd: Integer;
    { 'forward', 'backward' or 'none'. }
    SelectionDirection: string;
    HasSelection: Boolean;
  end;

  TInputValueMode = (ValueModeValue, ValueModeDefault, ValueModeDefaultOn, ValueModeFilename);

{ The state of Element, made on first use; Find gives nil if it has none. }
function FormControlState(Element: TElement): TFormControlState;
function FindFormControlState(Element: TElement): TFormControlState;

function InputType(Input: TElement): string;
function InputValueMode(Input: TElement): TInputValueMode;
function InputValue(Input: TElement): string;
procedure SetInputValue(Input: TElement; const Value: string);
function InputChecked(Input: TElement): Boolean;
procedure SetInputChecked(Input: TElement; Checked: Boolean);

function TextAreaValue(TextArea: TElement): string;
procedure SetTextAreaValue(TextArea: TElement; const Value: string);

function OptionSelected(Option: TElement): Boolean;
procedure SetOptionSelected(Option: TElement; Selected: Boolean);
function OptionText(Option: TElement): string;
function OptionValue(Option: TElement): string;
function OptionSelect(Option: TElement): TElement;
{ A select's options in tree order (children and optgroup children). }
function SelectOptions(Select: TElement): TNodeArray;
function SelectSelectedIndex(Select: TElement): Integer;
procedure SetSelectSelectedIndex(Select: TElement; Index: Integer);

function FormOwner(Element: TElement): TElement;
{ Strips and collapses ASCII white space. }
function CollapseAsciiWhitespace(const Text: string): string;

{ Text controls (text-like inputs and textareas). }
function IsTextControl(Element: TElement): Boolean;
{ The value of a text control (an input's or a textarea's). }
function TextControlValue(Element: TElement): string;
{ The user's edit: the value changes (dirty) and the selection is kept
  where the caller puts it. }
procedure SetTextControlValue(Element: TElement; const Value: string);
{ The selection in UTF-16 code units of the value; a control whose
  selection was never set has the caret at the end. }
procedure GetTextSelection(Element: TElement; out SelectionStart, SelectionEnd: Integer; out Direction: string);
procedure SetTextSelection(Element: TElement; SelectionStart, SelectionEnd: Integer; const Direction: string = 'none');

implementation

uses
  Web.Encoding.Utf8;

{ The state is not in the attributes: the document's observers (the
  styler, the layout) are told. }
procedure StateChanged(Element: TElement);
var
  Document: TDocument;
begin
  Document := Element.NodeDocument;
  if Document <> nil then
    Document.NotifyControlStateChanged(Element);
end;

function FormControlState(Element: TElement): TFormControlState;
begin
  Result := FindFormControlState(Element);
  if Result = nil then
  begin
    Result := TFormControlState.Create;
    Element.SetFormStateObject(Result);
  end;
end;

function FindFormControlState(Element: TElement): TFormControlState;
begin
  Result := TFormControlState(Element.FormStateObject);
end;

function InputType(Input: TElement): string;
const
  KnownTypes: array[0..21] of string = ('hidden', 'text', 'search', 'tel', 'url', 'email', 'password', 'date',
    'month', 'week', 'time', 'datetime-local', 'number', 'range', 'color', 'checkbox', 'radio', 'file', 'submit',
    'image', 'reset', 'button');
var
  Value: string;
  Index: Integer;
begin
  Value := AsciiLowerCase(Input.AttributeValueOf(AtomType));
  for Index := 0 to High(KnownTypes) do
    if KnownTypes[Index] = Value then
      Exit(Value);
  Result := 'text';
end;

function InputValueMode(Input: TElement): TInputValueMode;
var
  TypeName: string;
begin
  TypeName := InputType(Input);
  if (TypeName = 'hidden') or (TypeName = 'submit') or (TypeName = 'image') or (TypeName = 'reset') or
    (TypeName = 'button') then
    Result := ValueModeDefault
  else if (TypeName = 'checkbox') or (TypeName = 'radio') then
    Result := ValueModeDefaultOn
  else if TypeName = 'file' then
    Result := ValueModeFilename
  else
    Result := ValueModeValue;
end;

function StripNewlines(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Text) do
    if not (Text[Index] in [#10, #13]) then
      Result := Result + Text[Index];
end;

function SanitizeValue(Input: TElement; const Value: string): string;
var
  TypeName: string;
begin
  TypeName := InputType(Input);
  if (TypeName = 'text') or (TypeName = 'search') or (TypeName = 'tel') or (TypeName = 'password') then
    Result := StripNewlines(Value)
  else if (TypeName = 'url') or (TypeName = 'email') then
    Result := Trim(StripNewlines(Value))
  else if TypeName = 'color' then
  begin
    Result := AsciiLowerCase(Value);
    if (Length(Result) <> 7) or (Result[1] <> '#') then
      Result := '#000000';
  end
  else
    Result := Value;
end;

function InputValue(Input: TElement): string;
var
  State: TFormControlState;
begin
  case InputValueMode(Input) of
    ValueModeDefault:
      Result := Input.AttributeValueOf(AtomValue);
    ValueModeDefaultOn:
      if Input.HasAttributeAtom(AtomValue) then
        Result := Input.AttributeValueOf(AtomValue)
      else
        Result := 'on';
    ValueModeFilename:
      Result := '';
  else
    begin
      State := FindFormControlState(Input);
      if (State <> nil) and State.ValueDirty then
        Result := State.Value
      else
        Result := SanitizeValue(Input, Input.AttributeValueOf(AtomValue));
    end;
  end;
end;

procedure SetInputValue(Input: TElement; const Value: string);
var
  State: TFormControlState;
begin
  case InputValueMode(Input) of
    ValueModeDefault, ValueModeDefaultOn:
      Input.SetAttributeAtom(AtomValue, NamespaceNone, Value);
    ValueModeFilename:
      ;
  else
    begin
      State := FormControlState(Input);
      State.Value := SanitizeValue(Input, Value);
      State.ValueDirty := True;
      { A value set from outside puts the caret at its end. }
      State.HasSelection := False;
      StateChanged(Input);
    end;
  end;
end;

function InputChecked(Input: TElement): Boolean;
var
  State: TFormControlState;
begin
  State := FindFormControlState(Input);
  if (State <> nil) and State.CheckedDirty then
    Result := State.Checked
  else
    Result := Input.HasAttributeAtom(AtomChecked);
end;

procedure UncheckRadioGroup(Input: TElement);
var
  Root, Node: TNode;
  Name: string;
  Other: TElement;
  State: TFormControlState;
begin
  Name := Input.AttributeValueOf(AtomName);
  if Name = '' then
    Exit;
  Root := Input.GetRootNode;
  Node := Root;
  while Node <> nil do
  begin
    if (Node <> Input) and (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomInput) then
    begin
      Other := TElement(Node);
      if (InputType(Other) = 'radio') and (Other.AttributeValueOf(AtomName) = Name) and
        (FormOwner(Other) = FormOwner(Input)) then
      begin
        State := FormControlState(Other);
        State.Checked := False;
        State.CheckedDirty := True;
        StateChanged(Other);
      end;
    end;
    Node := Node.NextInTree(Root);
  end;
end;

procedure SetInputChecked(Input: TElement; Checked: Boolean);
var
  State: TFormControlState;
begin
  State := FormControlState(Input);
  State.Checked := Checked;
  State.CheckedDirty := True;
  StateChanged(Input);
  if Checked and (InputType(Input) = 'radio') then
    UncheckRadioGroup(Input);
end;

function TextAreaValue(TextArea: TElement): string;
var
  State: TFormControlState;
begin
  State := FindFormControlState(TextArea);
  if (State <> nil) and State.ValueDirty then
    Result := State.Value
  else
    Result := TextArea.TextContent;
end;

procedure SetTextAreaValue(TextArea: TElement; const Value: string);
var
  State: TFormControlState;
begin
  State := FormControlState(TextArea);
  State.Value := StringReplace(StringReplace(Value, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  State.ValueDirty := True;
  State.HasSelection := False;
  StateChanged(TextArea);
end;

function CollapseAsciiWhitespace(const Text: string): string;
var
  Index: Integer;
  InSpace: Boolean;
begin
  Result := '';
  InSpace := False;
  for Index := 1 to Length(Text) do
    if Text[Index] in [#9, #10, #12, #13, ' '] then
      InSpace := True
    else
    begin
      if InSpace and (Result <> '') then
        Result := Result + ' ';
      InSpace := False;
      Result := Result + Text[Index];
    end;
end;

function OptionText(Option: TElement): string;
begin
  Result := CollapseAsciiWhitespace(Option.TextContent);
end;

function OptionValue(Option: TElement): string;
begin
  if Option.HasAttributeAtom(AtomValue) then
    Result := Option.AttributeValueOf(AtomValue)
  else
    Result := OptionText(Option);
end;

function OptionSelect(Option: TElement): TElement;
var
  Parent: TNode;
begin
  Result := nil;
  Parent := Option.ParentNode;
  if (Parent <> nil) and (Parent.NodeType = NodeTypeElement) and TElement(Parent).IsHtmlElement(AtomOptgroup) then
    Parent := Parent.ParentNode;
  if (Parent <> nil) and (Parent.NodeType = NodeTypeElement) and TElement(Parent).IsHtmlElement(AtomSelect) then
    Result := TElement(Parent);
end;

function SelectOptions(Select: TElement): TNodeArray;
var
  Child, Grandchild: TNode;
  Count: Integer;

  procedure Add(Node: TNode);
  begin
    if Count >= Length(Result) then
      SetLength(Result, Count * 2 + 8);
    Result[Count] := Node;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  Child := Select.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = NodeTypeElement then
    begin
      if TElement(Child).IsHtmlElement(AtomOption) then
        Add(Child)
      else if TElement(Child).IsHtmlElement(AtomOptgroup) then
      begin
        Grandchild := Child.FirstChild;
        while Grandchild <> nil do
        begin
          if (Grandchild.NodeType = NodeTypeElement) and TElement(Grandchild).IsHtmlElement(AtomOption) then
            Add(Grandchild);
          Grandchild := Grandchild.NextSibling;
        end;
      end;
    end;
    Child := Child.NextSibling;
  end;
  SetLength(Result, Count);
end;

function ExplicitlySelected(Option: TElement): Boolean;
var
  State: TFormControlState;
begin
  State := FindFormControlState(Option);
  if (State <> nil) and State.SelectedDirty then
    Result := State.Selected
  else
    Result := Option.HasAttributeAtom(AtomSelected);
end;

function SelectSelectedIndex(Select: TElement): Integer;
var
  Options: TNodeArray;
  Index: Integer;
begin
  Options := SelectOptions(Select);
  for Index := 0 to High(Options) do
    if ExplicitlySelected(TElement(Options[Index])) then
      Exit(Index);
  if not Select.HasAttributeAtom(AtomMultiple) then
    for Index := 0 to High(Options) do
      if not TElement(Options[Index]).HasAttributeAtom(AtomDisabled) then
        Exit(Index);
  Result := -1;
end;

procedure SetSelectSelectedIndex(Select: TElement; Index: Integer);
var
  Options: TNodeArray;
  Position: Integer;
  State: TFormControlState;
begin
  Options := SelectOptions(Select);
  for Position := 0 to High(Options) do
  begin
    State := FormControlState(TElement(Options[Position]));
    State.Selected := Position = Index;
    State.SelectedDirty := True;
  end;
  StateChanged(Select);
end;

function OptionSelected(Option: TElement): Boolean;
var
  Select: TElement;
  Options: TNodeArray;
  Index: Integer;
begin
  Select := OptionSelect(Option);
  if (Select = nil) or Select.HasAttributeAtom(AtomMultiple) then
    Exit(ExplicitlySelected(Option));
  Index := SelectSelectedIndex(Select);
  Options := SelectOptions(Select);
  Result := (Index >= 0) and (Options[Index] = Option);
end;

procedure SetOptionSelected(Option: TElement; Selected: Boolean);
var
  Select: TElement;
  Options: TNodeArray;
  Index: Integer;
  State: TFormControlState;
begin
  Select := OptionSelect(Option);
  if Selected and (Select <> nil) and not Select.HasAttributeAtom(AtomMultiple) then
  begin
    Options := SelectOptions(Select);
    for Index := 0 to High(Options) do
      if Options[Index] = Option then
      begin
        SetSelectSelectedIndex(Select, Index);
        Exit;
      end;
  end;
  State := FormControlState(Option);
  State.Selected := Selected;
  State.SelectedDirty := True;
  StateChanged(Option);
end;

function FormOwner(Element: TElement): TElement;
begin
  Result := Element.ParentElement;
  while (Result <> nil) and not Result.IsHtmlElement(AtomForm) do
    Result := Result.ParentElement;
end;

function IsTextControl(Element: TElement): Boolean;
var
  TypeName: string;
begin
  if Element.IsHtmlElement(AtomTextarea) then
    Exit(True);
  if not Element.IsHtmlElement(AtomInput) then
    Exit(False);
  TypeName := InputType(Element);
  Result := (TypeName = 'text') or (TypeName = 'search') or (TypeName = 'url') or (TypeName = 'tel') or
    (TypeName = 'password') or (TypeName = 'email') or (TypeName = 'number');
end;

function TextControlValue(Element: TElement): string;
begin
  if Element.IsHtmlElement(AtomTextarea) then
    Result := TextAreaValue(Element)
  else
    Result := InputValue(Element);
end;

procedure SetTextControlValue(Element: TElement; const Value: string);
var
  State: TFormControlState;
  Keep: Boolean;
  Start, Finish: Integer;
  Direction: string;
begin
  GetTextSelection(Element, Start, Finish, Direction);
  State := FormControlState(Element);
  Keep := State.HasSelection;
  if Element.IsHtmlElement(AtomTextarea) then
    SetTextAreaValue(Element, Value)
  else
    SetInputValue(Element, Value);
  if Keep then
    SetTextSelection(Element, Start, Finish, Direction);
end;

procedure GetTextSelection(Element: TElement; out SelectionStart, SelectionEnd: Integer; out Direction: string);
var
  State: TFormControlState;
  Length_: Integer;
begin
  Length_ := Utf16Length(TextControlValue(Element));
  State := FindFormControlState(Element);
  if (State = nil) or not State.HasSelection then
  begin
    SelectionStart := Length_;
    SelectionEnd := Length_;
    Direction := 'none';
    Exit;
  end;
  SelectionStart := State.SelectionStart;
  SelectionEnd := State.SelectionEnd;
  if SelectionEnd > Length_ then
    SelectionEnd := Length_;
  if SelectionStart > SelectionEnd then
    SelectionStart := SelectionEnd;
  Direction := State.SelectionDirection;
end;

procedure SetTextSelection(Element: TElement; SelectionStart, SelectionEnd: Integer; const Direction: string);
var
  State: TFormControlState;
  Length_: Integer;
begin
  Length_ := Utf16Length(TextControlValue(Element));
  if SelectionEnd > Length_ then
    SelectionEnd := Length_;
  if SelectionEnd < 0 then
    SelectionEnd := 0;
  if SelectionStart > SelectionEnd then
    SelectionStart := SelectionEnd;
  if SelectionStart < 0 then
    SelectionStart := 0;
  State := FormControlState(Element);
  State.SelectionStart := SelectionStart;
  State.SelectionEnd := SelectionEnd;
  if (Direction = 'forward') or (Direction = 'backward') then
    State.SelectionDirection := Direction
  else
    State.SelectionDirection := 'none';
  State.HasSelection := True;
end;

{ The cloning steps of input and textarea. }
procedure CloneFormControlState(Source, Copy: TElement);
var
  State, CopyState: TFormControlState;
begin
  if not (Source.IsHtmlElement(AtomInput) or Source.IsHtmlElement(AtomTextarea)) then
    Exit;
  State := FindFormControlState(Source);
  if State = nil then
    Exit;
  CopyState := FormControlState(Copy);
  CopyState.Value := State.Value;
  CopyState.ValueDirty := State.ValueDirty;
  CopyState.Checked := State.Checked;
  CopyState.CheckedDirty := State.CheckedDirty;
end;

initialization
  FormStateCloning := @CloneFormControlState;
end.
