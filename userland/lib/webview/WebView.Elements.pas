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
  What the web view asks of the elements under the pointer and in the
  focus: the link an element belongs to (a or area with href), whether
  it takes the focus, the kind of form control it is, the form it
  belongs to, and the pointer shape the CSS cursor property asks for.
}
unit WebView.Elements;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.Layout.Boxes;

type
  TFormControlKind = (FormControlNone, FormControlText, FormControlPassword, FormControlTextArea,
    FormControlCheckbox, FormControlRadio, FormControlSubmit, FormControlReset, FormControlButton,
    FormControlSelect);

{ The a or area element with href at or above Node, nil if none. }
function LinkElementOf(Node: TNode): TElement;
{ An element the keyboard can reach (links, controls, tabindex >= 0). }
function IsFocusableElement(Element: TElement): Boolean;
function FormControlKindOf(Element: TElement): TFormControlKind;
{ The form control at or above Node (the nearest), nil if none. }
function FormControlOf(Node: TNode): TElement;
function IsDisabledControl(Element: TElement): Boolean;
{ The element's form owner: its form attribute's form, else the nearest
  form ancestor. }
function FormOwnerOf(Element: TElement): TElement;
{ The Windowing pointer shape for the CSS cursor of the box under the
  pointer; auto: the text beam over text, the hand over links. }
function PointerShapeForCursor(Box: TLayoutBox; OverText, OverLink: Boolean): LongWord;
{ The elements the keyboard visits in tree order. }
function NextFocusableElement(Document: TDocument; Current: TElement; Forward: Boolean): TElement;

implementation

uses
  SysUtils,
  Css.Keywords,
  Css.PropertyIds,
  Css.ComputedStyle,
  Windowing.Protocol,
  Web.Atoms;

var
  AtomA, AtomArea, AtomInput, AtomButton, AtomSelect, AtomTextArea, AtomForm, AtomHref, AtomType, AtomDisabled,
    AtomTabIndex, AtomFormAttribute, AtomFieldset: TAtom;

procedure MakeAtoms;
begin
  AtomA := Atomize('a');
  AtomArea := Atomize('area');
  AtomInput := Atomize('input');
  AtomButton := Atomize('button');
  AtomSelect := Atomize('select');
  AtomTextArea := Atomize('textarea');
  AtomForm := Atomize('form');
  AtomHref := Atomize('href');
  AtomType := Atomize('type');
  AtomDisabled := Atomize('disabled');
  AtomTabIndex := Atomize('tabindex');
  AtomFormAttribute := AtomForm;
  AtomFieldset := Atomize('fieldset');
end;

function LinkElementOf(Node: TNode): TElement;
var
  Element: TElement;
begin
  Result := nil;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      if (Element.IsHtmlElement(AtomA) or Element.IsHtmlElement(AtomArea)) and Element.HasAttributeAtom(AtomHref) then
        Exit(Element);
    end;
    Node := Node.ParentNode;
  end;
end;

function FormControlKindOf(Element: TElement): TFormControlKind;
var
  InputType: string;
begin
  Result := FormControlNone;
  if Element = nil then
    Exit;
  if Element.IsHtmlElement(AtomInput) then
  begin
    InputType := LowerCase(Trim(Element.AttributeValueOf(AtomType)));
    if (InputType = 'checkbox') then
      Result := FormControlCheckbox
    else if InputType = 'radio' then
      Result := FormControlRadio
    else if (InputType = 'submit') or (InputType = 'image') then
      Result := FormControlSubmit
    else if InputType = 'reset' then
      Result := FormControlReset
    else if InputType = 'button' then
      Result := FormControlButton
    else if InputType = 'password' then
      Result := FormControlPassword
    else if (InputType = 'hidden') or (InputType = 'file') or (InputType = 'range') or (InputType = 'color') then
      Result := FormControlNone
    else
      Result := FormControlText;
  end
  else if Element.IsHtmlElement(AtomButton) then
  begin
    InputType := LowerCase(Trim(Element.AttributeValueOf(AtomType)));
    if InputType = 'reset' then
      Result := FormControlReset
    else if InputType = 'button' then
      Result := FormControlButton
    else
      Result := FormControlSubmit;
  end
  else if Element.IsHtmlElement(AtomSelect) then
    Result := FormControlSelect
  else if Element.IsHtmlElement(AtomTextArea) then
    Result := FormControlTextArea;
end;

function FormControlOf(Node: TNode): TElement;
begin
  Result := nil;
  while Node <> nil do
  begin
    if Node.IsElement and (FormControlKindOf(TElement(Node)) <> FormControlNone) then
      Exit(TElement(Node));
    Node := Node.ParentNode;
  end;
end;

function IsDisabledControl(Element: TElement): Boolean;
var
  Node: TNode;
begin
  Result := Element.HasAttributeAtom(AtomDisabled);
  if Result then
    Exit;
  Node := Element.ParentNode;
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).IsHtmlElement(AtomFieldset) and TElement(Node).HasAttributeAtom(AtomDisabled) then
      Exit(True);
    Node := Node.ParentNode;
  end;
end;

function IsFocusableElement(Element: TElement): Boolean;
var
  TabIndex: Integer;
begin
  if Element = nil then
    Exit(False);
  if Element.HasAttributeAtom(AtomTabIndex) then
  begin
    TabIndex := StrToIntDef(Trim(Element.AttributeValueOf(AtomTabIndex)), 0);
    Exit(TabIndex >= 0);
  end;
  if LinkElementOf(Element) = Element then
    Exit(True);
  Result := (FormControlKindOf(Element) <> FormControlNone) and not IsDisabledControl(Element);
end;

function FormOwnerOf(Element: TElement): TElement;
var
  Id: string;
  Node: TNode;
  Found: TElement;
begin
  Result := nil;
  if Element = nil then
    Exit;
  Id := Element.AttributeValueOf(AtomFormAttribute);
  if (Id <> '') and not Element.IsHtmlElement(AtomForm) and (Element.OwnerDocument <> nil) then
  begin
    Found := Element.OwnerDocument.GetElementById(Id);
    if (Found <> nil) and Found.IsHtmlElement(AtomForm) then
      Exit(Found);
  end;
  Node := Element.ParentNode;
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).IsHtmlElement(AtomForm) then
      Exit(TElement(Node));
    Node := Node.ParentNode;
  end;
end;

function PointerShapeForCursor(Box: TLayoutBox; OverText, OverLink: Boolean): LongWord;
var
  Cursor: TCssKeyword;
begin
  Cursor := kwAuto;
  if (Box <> nil) and (Box.Style <> nil) then
    Cursor := Box.Style.Keyword(cpCursor);
  case Cursor of
    kwPointer:
      Result := PointerHand;
    kwText, kwVerticalText:
      Result := PointerTextBeam;
    kwWait, kwProgress:
      Result := PointerBusy;
    kwCrosshair, kwCell:
      Result := PointerCrosshair;
    kwMove, kwAllScroll, kwGrab, kwGrabbing:
      Result := PointerMove;
    kwNotAllowed, kwNoDrop:
      Result := PointerNotAllowed;
    kwEwResize, kwColResize, kwEResize, kwWResize:
      Result := PointerResizeHorizontal;
    kwNsResize, kwRowResize, kwNResize, kwSResize:
      Result := PointerResizeVertical;
    kwNwseResize, kwNwResize, kwSeResize:
      Result := PointerResizeDiagonalDown;
    kwNeswResize, kwNeResize, kwSwResize:
      Result := PointerResizeDiagonalUp;
    kwDefault, kwNone:
      Result := PointerArrow;
  else
    if OverLink then
      Result := PointerHand
    else if OverText then
      Result := PointerTextBeam
    else
      Result := PointerArrow;
  end;
end;

function NextFocusableElement(Document: TDocument; Current: TElement; Forward: Boolean): TElement;
var
  Node: TNode;
  Previous: TElement;
begin
  Result := nil;
  if Document = nil then
    Exit;
  if Forward then
  begin
    if Current <> nil then
      Node := Current.NextInTree(Document)
    else
      Node := Document;
    while Node <> nil do
    begin
      if Node.IsElement and IsFocusableElement(TElement(Node)) then
        Exit(TElement(Node));
      Node := Node.NextInTree(Document);
    end;
  end
  else
  begin
    { Tree order backwards: the last focusable one before Current. }
    Previous := nil;
    Node := Document;
    while (Node <> nil) and (Node <> Current) do
    begin
      if Node.IsElement and IsFocusableElement(TElement(Node)) then
        Previous := TElement(Node);
      Node := Node.NextInTree(Document);
    end;
    Result := Previous;
  end;
end;

initialization
  MakeAtoms;
end.
