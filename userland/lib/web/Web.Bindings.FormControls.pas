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
  The bindings' entry to Web.Dom.FormControls (the shared form control
  state and values), with the context the call sites have. What it says:
  the basics of form controls (HTML Standard 4.10) the bindings need:
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
  Web.Dom.FormControls,
  Web.Bindings.Context;

type
  TInputValueMode = Web.Dom.FormControls.TInputValueMode;

const
  ValueModeValue = Web.Dom.FormControls.ValueModeValue;
  ValueModeDefault = Web.Dom.FormControls.ValueModeDefault;
  ValueModeDefaultOn = Web.Dom.FormControls.ValueModeDefaultOn;
  ValueModeFilename = Web.Dom.FormControls.ValueModeFilename;

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

function InputValue(Context: TBindingContext; Input: TElement): string;
begin
  Result := Web.Dom.FormControls.InputValue(Input);
end;

procedure SetInputValue(Context: TBindingContext; Input: TElement; const Value: string);
begin
  Web.Dom.FormControls.SetInputValue(Input, Value);
end;

function InputChecked(Context: TBindingContext; Input: TElement): Boolean;
begin
  Result := Web.Dom.FormControls.InputChecked(Input);
end;

procedure SetInputChecked(Context: TBindingContext; Input: TElement; Checked: Boolean);
begin
  Web.Dom.FormControls.SetInputChecked(Input, Checked);
end;

function TextAreaValue(Context: TBindingContext; TextArea: TElement): string;
begin
  Result := Web.Dom.FormControls.TextAreaValue(TextArea);
end;

procedure SetTextAreaValue(Context: TBindingContext; TextArea: TElement; const Value: string);
begin
  Web.Dom.FormControls.SetTextAreaValue(TextArea, Value);
end;

function OptionSelected(Context: TBindingContext; Option: TElement): Boolean;
begin
  Result := Web.Dom.FormControls.OptionSelected(Option);
end;

procedure SetOptionSelected(Context: TBindingContext; Option: TElement; Selected: Boolean);
begin
  Web.Dom.FormControls.SetOptionSelected(Option, Selected);
end;

function SelectSelectedIndex(Context: TBindingContext; Select: TElement): Integer;
begin
  Result := Web.Dom.FormControls.SelectSelectedIndex(Select);
end;

procedure SetSelectSelectedIndex(Context: TBindingContext; Select: TElement; Index: Integer);
begin
  Web.Dom.FormControls.SetSelectSelectedIndex(Select, Index);
end;

function InputType(Input: TElement): string;
begin
  Result := Web.Dom.FormControls.InputType(Input);
end;

function InputValueMode(Input: TElement): TInputValueMode;
begin
  Result := Web.Dom.FormControls.InputValueMode(Input);
end;

function OptionText(Option: TElement): string;
begin
  Result := Web.Dom.FormControls.OptionText(Option);
end;

function OptionValue(Option: TElement): string;
begin
  Result := Web.Dom.FormControls.OptionValue(Option);
end;

function OptionSelect(Option: TElement): TElement;
begin
  Result := Web.Dom.FormControls.OptionSelect(Option);
end;

function SelectOptions(Select: TElement): TNodeArray;
begin
  Result := Web.Dom.FormControls.SelectOptions(Select);
end;

function FormOwner(Element: TElement): TElement;
begin
  Result := Web.Dom.FormControls.FormOwner(Element);
end;

function CollapseAsciiWhitespace(const Text: string): string;
begin
  Result := Web.Dom.FormControls.CollapseAsciiWhitespace(Text);
end;

end.
