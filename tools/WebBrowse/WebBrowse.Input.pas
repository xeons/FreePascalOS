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
  webbrowse's user: key presses and clicks as the web view gives them to a
  page. A key is keydown (and keypress for a character) at the focused
  element or the body, then, unless the page cancelled it, what it does
  in a text field (libwebview's WebView.FieldEditing: typing, deleting,
  moving the caret, Enter submitting the form), Tab moving the focus,
  Enter following a focused link; then keyup. A click is mousedown,
  mouseup and click at an element, then a link followed or a control
  focused. Key names are KeyboardEvent codes ("Enter", "ArrowDown",
  "KeyA") with "ctrl+", "shift+" and "alt+" before them.
}
unit WebBrowse.Input;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom,
  Web.Navigation.Navigables,
  WebView.FieldEditing;

type
  TPageInput = class
  private
    FNavigable: TNavigable;
    FEditor: TTextFieldEditor;
    FClipboard: string;
    { The focused text field and its value when it got the focus (change
      fires when the focus leaves it changed, as the web view does). }
    FFocusField: TElement;
    FFocusValue: string;
    procedure FocusChecked(Document: TDocument);
    procedure FieldEdited(Element: TElement; const InputType, Data: string);
    procedure FieldSubmitted(Element: TElement);
    function ReadClipboard: string;
    procedure WriteClipboard(const Text: string);
    function KeyTarget(Document: TDocument): TObject;
    procedure FollowLink(Link: TElement);
  public
    constructor Create(Navigable: TNavigable);
    destructor Destroy; override;
    { One key press and release in Document. }
    procedure PressKey(Document: TDocument; ScanCode, Character, Modifiers: LongWord);
    { Types Character (a code point; #10 is Enter). }
    procedure TypeCharacter(Document: TDocument; Character: LongWord);
    { A key by name ("Enter", "ctrl+KeyA"); False when the name is unknown. }
    function PressNamedKey(Document: TDocument; const Name: string): Boolean;
    { A click in the middle of Element. }
    procedure Click(Element: TElement);
  end;

implementation

uses
  SysUtils,
  Url.Records,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Dom.Focus,
  Web.Dom.FormControls,
  Web.Navigation.Events,
  Web.Bindings.UrlResolution,
  WebView.KeyNames,
  WebView.Elements,
  WebView.MouseEvents,
  WebView.Forms,
  Web.Dom.AccessKeys;

const
  SystemShift = $01;
  SystemControl = $02;
  SystemAlt = $04;
  ScanTab = $0F;
  ScanEnter = $1C;

constructor TPageInput.Create(Navigable: TNavigable);
begin
  inherited Create;
  FNavigable := Navigable;
  FEditor := TTextFieldEditor.Create;
  FEditor.OnEdited := @FieldEdited;
  FEditor.OnSubmit := @FieldSubmitted;
  FEditor.OnReadClipboard := @ReadClipboard;
  FEditor.OnWriteClipboard := @WriteClipboard;
end;

destructor TPageInput.Destroy;
begin
  if FFocusField <> nil then
    FFocusField.Release;
  FEditor.Free;
  inherited Destroy;
end;

procedure TPageInput.FocusChecked(Document: TDocument);
var
  Focused, Old: TElement;
begin
  Focused := Document.FocusedElement;
  if Focused = FFocusField then
    Exit;
  Old := FFocusField;
  FFocusField := nil;
  if Old <> nil then
  begin
    if Old.IsConnected and IsTextControl(Old) and (TextControlValue(Old) <> FFocusValue) then
      FireEvent(Old, 'change', True);
    Old.Release;
  end;
  { The change listeners may have moved the focus again. }
  Focused := Document.FocusedElement;
  if (Focused <> nil) and IsTextControl(Focused) then
  begin
    Focused.Retain;
    FFocusField := Focused;
    FFocusValue := TextControlValue(Focused);
  end;
end;

procedure TPageInput.FieldEdited(Element: TElement; const InputType, Data: string);
begin
  DispatchInputEvent(Element, InputType, Data, (InputType = 'insertText') or (InputType = 'insertFromPaste'));
end;

{ Implicit submission: the form's default button is pressed, else the
  form submitted. }
procedure TPageInput.FieldSubmitted(Element: TElement);
var
  Form, Button: TElement;
begin
  Form := FormOwnerOf(Element);
  if Form = nil then
    Exit;
  Button := DefaultButtonOf(Form);
  if Button = nil then
    SubmitFormIn(FNavigable, Form, nil)
  else if not IsDisabledControl(Button) then
    Click(Button);
end;

function TPageInput.ReadClipboard: string;
begin
  Result := FClipboard;
end;

procedure TPageInput.WriteClipboard(const Text: string);
begin
  FClipboard := Text;
end;

function TPageInput.KeyTarget(Document: TDocument): TObject;
begin
  if (Document.FocusedElement <> nil) and Document.FocusedElement.IsConnected then
    Result := Document.FocusedElement
  else if Document.Body <> nil then
    Result := Document.Body
  else
    Result := Document;
end;

procedure TPageInput.FollowLink(Link: TElement);
var
  Target: TUrlRecord;
  Options: TNavigateOptions;
begin
  if (FNavigable.Loader = nil) or
    not ResolveUrl(Link.NodeDocument, Link.GetAttribute('href'), Target) then
    Exit;
  Options := Default(TNavigateOptions);
  Options.Source := FNavigable.Loader;
  FNavigable.Navigate(Target, Options);
end;

{ The element whose access key the key is (Web.Dom.AccessKeys). }
function AccessKeyElement(ScanCode, Character: LongWord; Document: TDocument): TElement;
var
  KeyCode: string;
begin
  Result := nil;
  KeyCode := DomKeyOf(ScanCode, Character).Code;
  if (Length(KeyCode) = 4) and (Copy(KeyCode, 1, 3) = 'Key') then
    Result := FindAccessKeyElement(Document, LowerCase(KeyCode[4]))
  else if (Length(KeyCode) = 6) and (Copy(KeyCode, 1, 5) = 'Digit') then
    Result := FindAccessKeyElement(Document, KeyCode[6]);
end;

procedure TPageInput.PressKey(Document: TDocument; ScanCode, Character, Modifiers: LongWord);
var
  Focused, Next: TElement;
  Action: TFieldAction;
  Options: TFieldActionOptions;
  Typed: string;
begin
  if Document = nil then
    Exit;
  Document.Retain;
  try
    FocusChecked(Document);
    if DispatchKeyEvent(KeyTarget(Document), 'keydown', ScanCode, Character, Modifiers) and
      (not ((Character >= 32) and (Character <> 127) and ((Modifiers and (SystemControl or SystemAlt)) = 0)) or
      DispatchKeyEvent(KeyTarget(Document), 'keypress', ScanCode, Character, Modifiers)) then
    begin
      Focused := Document.FocusedElement;
      if ((Modifiers and SystemAlt) <> 0) and ((Modifiers and SystemShift) <> 0) and
        ((Modifiers and SystemControl) = 0) and (AccessKeyElement(ScanCode, Character, Document) <> nil) then
      begin
        { An access key, as the web view takes it. }
        Next := AccessKeyElement(ScanCode, Character, Document);
        FocusElement(Next);
        Click(Next);
      end
      else if IsEditableTextField(Focused) and FieldActionOfKey(ScanCode, Character, Modifiers, Action, Options, Typed) and
        FEditor.Perform(Focused, Action, Typed, Options) then
        { typed }
      else if ScanCode = ScanTab then
      begin
        Next := NextFocusableElement(Document, Focused, (Modifiers and SystemShift) = 0);
        if Next <> nil then
          FocusElement(Next);
      end
      else if (ScanCode = ScanEnter) and (Focused <> nil) and (LinkElementOf(Focused) = Focused) then
        FollowLink(Focused)
      else if (ScanCode = ScanEnter) and (Focused <> nil) and
        (FormControlKindOf(Focused) in [FormControlSubmit, FormControlButton]) then
        Click(Focused);
    end;
    DispatchKeyEvent(KeyTarget(Document), 'keyup', ScanCode, Character, Modifiers);
    FocusChecked(Document);
  finally
    Document.Release;
  end;
end;

procedure TPageInput.TypeCharacter(Document: TDocument; Character: LongWord);
var
  ScanCode: LongWord;
  Shifted: Boolean;
begin
  if Character = 10 then
  begin
    PressKey(Document, ScanEnter, 13, 0);
    Exit;
  end;
  ScanCode := ScanCodeOfCharacter(Character, Shifted);
  if Shifted then
    PressKey(Document, ScanCode, Character, SystemShift)
  else
    PressKey(Document, ScanCode, Character, 0);
end;

function TPageInput.PressNamedKey(Document: TDocument; const Name: string): Boolean;
var
  Rest, Prefix: string;
  Modifiers, ScanCode, Character: LongWord;
begin
  Rest := Name;
  Modifiers := 0;
  while Pos('+', Rest) > 1 do
  begin
    Prefix := LowerCase(Copy(Rest, 1, Pos('+', Rest) - 1));
    Delete(Rest, 1, Pos('+', Rest));
    if Prefix = 'ctrl' then
      Modifiers := Modifiers or SystemControl
    else if Prefix = 'shift' then
      Modifiers := Modifiers or SystemShift
    else if Prefix = 'alt' then
      Modifiers := Modifiers or SystemAlt
    else
      Exit(False);
  end;
  ScanCode := ScanCodeOfKeyCode(Rest);
  if ScanCode = 0 then
    Exit(False);
  Character := 0;
  if Rest = 'Enter' then
    Character := 13
  else if (Length(Rest) = 4) and (Copy(Rest, 1, 3) = 'Key') then
  begin
    Character := Ord(LowerCase(Rest[4]));
    if (Modifiers and SystemShift) <> 0 then
      Character := Ord(Rest[4]);
  end
  else if Rest = 'Space' then
    Character := 32;
  if (Character = 0) and (Rest = 'Backspace') then
    Character := 8;
  PressKey(Document, ScanCode, Character, Modifiers);
  Result := True;
end;

{ A trusted MouseEvent of the primary button, with its pointer event as
  the web view gives them (WebView.MouseEvents). }
function FireMouseEvent(Target: TElement; const EventType: string): Boolean;
var
  Init: TMouseEventInit;
begin
  Init := Default(TMouseEventInit);
  if EventType = 'mousedown' then
    Init.Buttons := 1;
  Init.Detail := 1;
  Result := DispatchMouseEvent(Target, EventType, Init);
end;

procedure TPageInput.Click(Element: TElement);
var
  Kind: TFormControlKind;
  Link: TElement;
begin
  if Element = nil then
    Exit;
  Element.Retain;
  try
    if FireMouseEvent(Element, 'mousedown') and IsFocusableArea(Element) then
      FocusElement(Element);
    if Element.NodeDocument <> nil then
      FocusChecked(Element.NodeDocument);
    FireMouseEvent(Element, 'mouseup');
    if not FireMouseEvent(Element, 'click') then
      Exit;
    Kind := FormControlKindOf(Element);
    if Kind = FormControlSubmit then
      SubmitFormIn(FNavigable, FormOwnerOf(Element), Element)
    else if Kind = FormControlCheckbox then
      ToggleCheckbox(Element)
    else
    begin
      Link := LinkElementOf(Element);
      if Link <> nil then
        FollowLink(Link);
    end;
  finally
    Element.Release;
  end;
end;

end.
