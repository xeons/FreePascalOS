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
  The basics of form controls (HTML Standard 4.10) the bindings need:
  an input's type and value mode, its value and checkedness (with the
  dirty flags: script changes the state, not the attributes), radio
  groups, a textarea's value, options' selectedness and a select's
  selected index and value, and the form owner (the nearest form
  ancestor; the form attribute is not looked at yet).
}
unit Web.Bindings.FormControls;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Bindings.Context;

type
  TInputValueMode = (ValueModeValue, ValueModeDefault, ValueModeDefaultOn, ValueModeFilename);

function InputType(Input: TElement): string;
function InputValueMode(Input: TElement): TInputValueMode;
function InputValue(Context: TBindingContext; Input: TElement): string;
procedure SetInputValue(Context: TBindingContext; Input: TElement; const Value: string);
function InputChecked(Context: TBindingContext; Input: TElement): Boolean;
procedure SetInputChecked(Context: TBindingContext; Input: TElement; Checked: Boolean);

function TextAreaValue(Context: TBindingContext; TextArea: TElement): string;
procedure SetTextAreaValue(Context: TBindingContext; TextArea: TElement; const Value: string);

function OptionSelected(Context: TBindingContext; Option: TElement): Boolean;
procedure SetOptionSelected(Context: TBindingContext; Option: TElement; Selected: Boolean);
function OptionText(Option: TElement): string;
function OptionValue(Option: TElement): string;
function OptionSelect(Option: TElement): TElement;
{ A select's options in tree order (children and optgroup children). }
function SelectOptions(Select: TElement): TNodeArray;
function SelectSelectedIndex(Context: TBindingContext; Select: TElement): Integer;
procedure SetSelectSelectedIndex(Context: TBindingContext; Select: TElement; Index: Integer);

function FormOwner(Element: TElement): TElement;
{ Strips and collapses ASCII white space. }
function CollapseAsciiWhitespace(const Text: string): string;

implementation

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

function InputValue(Context: TBindingContext; Input: TElement): string;
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
      State := Context.FindFormState(Input);
      if (State <> nil) and State.ValueDirty then
        Result := State.Value
      else
        Result := SanitizeValue(Input, Input.AttributeValueOf(AtomValue));
    end;
  end;
end;

procedure SetInputValue(Context: TBindingContext; Input: TElement; const Value: string);
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
      State := Context.FormState(Input);
      State.Value := SanitizeValue(Input, Value);
      State.ValueDirty := True;
    end;
  end;
end;

function InputChecked(Context: TBindingContext; Input: TElement): Boolean;
var
  State: TFormControlState;
begin
  State := Context.FindFormState(Input);
  if (State <> nil) and State.CheckedDirty then
    Result := State.Checked
  else
    Result := Input.HasAttributeAtom(AtomChecked);
end;

procedure UncheckRadioGroup(Context: TBindingContext; Input: TElement);
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
        State := Context.FormState(Other);
        State.Checked := False;
        State.CheckedDirty := True;
      end;
    end;
    Node := Node.NextInTree(Root);
  end;
end;

procedure SetInputChecked(Context: TBindingContext; Input: TElement; Checked: Boolean);
var
  State: TFormControlState;
begin
  State := Context.FormState(Input);
  State.Checked := Checked;
  State.CheckedDirty := True;
  if Checked and (InputType(Input) = 'radio') then
    UncheckRadioGroup(Context, Input);
end;

function TextAreaValue(Context: TBindingContext; TextArea: TElement): string;
var
  State: TFormControlState;
begin
  State := Context.FindFormState(TextArea);
  if (State <> nil) and State.ValueDirty then
    Result := State.Value
  else
    Result := TextArea.TextContent;
end;

procedure SetTextAreaValue(Context: TBindingContext; TextArea: TElement; const Value: string);
var
  State: TFormControlState;
begin
  State := Context.FormState(TextArea);
  State.Value := StringReplace(StringReplace(Value, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  State.ValueDirty := True;
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

function ExplicitlySelected(Context: TBindingContext; Option: TElement): Boolean;
var
  State: TFormControlState;
begin
  State := Context.FindFormState(Option);
  if (State <> nil) and State.SelectedDirty then
    Result := State.Selected
  else
    Result := Option.HasAttributeAtom(AtomSelected);
end;

function SelectSelectedIndex(Context: TBindingContext; Select: TElement): Integer;
var
  Options: TNodeArray;
  Index: Integer;
begin
  Options := SelectOptions(Select);
  for Index := 0 to High(Options) do
    if ExplicitlySelected(Context, TElement(Options[Index])) then
      Exit(Index);
  if not Select.HasAttributeAtom(AtomMultiple) then
    for Index := 0 to High(Options) do
      if not TElement(Options[Index]).HasAttributeAtom(AtomDisabled) then
        Exit(Index);
  Result := -1;
end;

procedure SetSelectSelectedIndex(Context: TBindingContext; Select: TElement; Index: Integer);
var
  Options: TNodeArray;
  Position: Integer;
  State: TFormControlState;
begin
  Options := SelectOptions(Select);
  for Position := 0 to High(Options) do
  begin
    State := Context.FormState(TElement(Options[Position]));
    State.Selected := Position = Index;
    State.SelectedDirty := True;
  end;
end;

function OptionSelected(Context: TBindingContext; Option: TElement): Boolean;
var
  Select: TElement;
  Options: TNodeArray;
  Index: Integer;
begin
  Select := OptionSelect(Option);
  if (Select = nil) or Select.HasAttributeAtom(AtomMultiple) then
    Exit(ExplicitlySelected(Context, Option));
  Index := SelectSelectedIndex(Context, Select);
  Options := SelectOptions(Select);
  Result := (Index >= 0) and (Options[Index] = Option);
end;

procedure SetOptionSelected(Context: TBindingContext; Option: TElement; Selected: Boolean);
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
        SetSelectSelectedIndex(Context, Select, Index);
        Exit;
      end;
  end;
  State := Context.FormState(Option);
  State.Selected := Selected;
  State.SelectedDirty := True;
end;

function FormOwner(Element: TElement): TElement;
begin
  Result := Element.ParentElement;
  while (Result <> nil) and not Result.IsHtmlElement(AtomForm) do
    Result := Result.ParentElement;
end;

end.
