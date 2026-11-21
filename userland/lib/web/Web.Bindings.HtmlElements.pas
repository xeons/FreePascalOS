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
  bindings/HtmlElements.webidl: what the HTML element interfaces do
  beyond reflection: click() with checkbox and radio activation, focus
  events, innerText (as text content until layout can say better),
  dataset, style, the hyperlink URL parts, form controls' values and
  checkedness (Web.Bindings.FormControls), constraint validation basics
  (required, custom validity), select and option, form elements and
  submission by GET through the environment, template content, script
  text and async.

  Layout answers (offsetWidth and the like) are 0 until layout lands;
  images report no natural size; media are paused.
}
unit Web.Bindings.HtmlElements;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.HtmlElements.Members.inc}

implementation

uses
  Web.Dom.FormControls,
  Web.Dom.Focus,
  SysUtils,
  Math,
  Js.Objects,
  Js.Conversions,
  Url.Records,
  Url.Parser,
  Url.Accessors,
  Url.FormEncoding,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Dom.Exceptions,
  Web.Encoding.Utf8,
  Web.Bindings.Context,
  Web.Bindings.FormControls,
  Web.Bindings.Collections,
  Web.Bindings.Reflection,
  Web.Bindings.Style,
  Web.Bindings.UrlResolution,
  Web.ScriptEnvironment;

type
  TFormElementsCollection = class(THtmlCollection)
  protected
    function Matches(Element: TElement): Boolean; override;
  end;

  TSelectedOptionsCollection = class(THtmlCollection)
  protected
    function Matches(Element: TElement): Boolean; override;
  public
    Context: TBindingContext;
  end;

function IsListedElement(Element: TElement): Boolean;
begin
  Result := Element.IsHtml and ((Element.LocalNameAtom = AtomButton) or (Element.LocalNameAtom = AtomFieldset) or
    (Element.LocalNameAtom = AtomInput) or (Element.LocalNameAtom = AtomObject) or
    (Element.LocalNameAtom = AtomOutput) or (Element.LocalNameAtom = AtomSelect) or
    (Element.LocalNameAtom = AtomTextarea));
end;

function TFormElementsCollection.Matches(Element: TElement): Boolean;
begin
  Result := IsListedElement(Element) and not (Element.IsHtmlElement(AtomInput) and (InputType(Element) = 'image')) and
    (FormOwner(Element) = Root);
end;

function TSelectedOptionsCollection.Matches(Element: TElement): Boolean;
begin
  Result := Element.IsHtmlElement(AtomOption) and (OptionSelect(Element) = Root) and
    OptionSelected(Context, Element);
end;

function ThisElement(const Call: TBindingCall): TElement; inline;
begin
  Result := TElement(Call.Target);
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function Text(const Call: TBindingCall; const Value: string): TJsValue; inline;
begin
  Result := Context(Call).TextValue(Value);
end;

function Nothing: TJsValue; inline;
begin
  Result := JsUndefined;
end;

{ A token list over an attribute, owned by its wrapper; the element's
  wrapper keeps the element alive. }
function TokenList(const Call: TBindingCall; const AttributeName: string): TJsValue;
begin
  Result := Context(Call).WrapObject(TDomTokenList.Create(ThisElement(Call), Atomize(AttributeName)),
    InterfaceDOMTokenList, True, Call.This);
end;

function FormValue(const Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(FormOwner(ThisElement(Call)));
end;

{ Constraint validation, the basics: disabled and readonly controls are
  barred; a required control with no value and a custom error are
  invalid. checkValidity fires invalid at an invalid control. }
function ControlValue(const Call: TBindingCall; Element: TElement): string;
begin
  if Element.IsHtmlElement(AtomInput) then
    Result := InputValue(Context(Call), Element)
  else if Element.IsHtmlElement(AtomTextarea) then
    Result := TextAreaValue(Context(Call), Element)
  else if Element.IsHtmlElement(AtomSelect) then
  begin
    if SelectSelectedIndex(Context(Call), Element) < 0 then
      Result := ''
    else
      Result := OptionValue(TElement(SelectOptions(Element)[SelectSelectedIndex(Context(Call), Element)]));
  end
  else
    Result := '';
end;

function WillValidate(Element: TElement): Boolean;
begin
  Result := not Element.HasAttributeAtom(AtomDisabled) and not Element.HasAttributeAtom(AtomReadonly) and
    not (Element.IsHtmlElement(AtomInput) and ((InputType(Element) = 'hidden') or (InputType(Element) = 'reset') or
    (InputType(Element) = 'button'))) and not Element.IsHtmlElement(AtomFieldset) and
    not Element.IsHtmlElement(AtomOutput) and not Element.IsHtmlElement(AtomObject) and
    not (Element.IsHtmlElement(AtomButton) and (AsciiLowerCase(Element.AttributeValueOf(AtomType)) = 'button'));
end;

function IsValid(const Call: TBindingCall; Element: TElement): Boolean;
var
  State: TFormControlState;
begin
  if not WillValidate(Element) then
    Exit(True);
  State := Context(Call).FindFormState(Element);
  if (State <> nil) and (State.CustomValidity <> '') then
    Exit(False);
  if Element.HasAttributeAtom(AtomRequired) then
  begin
    if Element.IsHtmlElement(AtomInput) and ((InputType(Element) = 'checkbox') or (InputType(Element) = 'radio')) then
      Exit(InputChecked(Context(Call), Element));
    if ControlValue(Call, Element) = '' then
      Exit(False);
  end;
  Result := True;
end;

function CheckValidity(const Call: TBindingCall; Element: TElement): Boolean;
var
  Event: TEvent;
begin
  Result := IsValid(Call, Element);
  if Result then
    Exit;
  Event := TEvent.Create('invalid', False, True);
  try
    Element.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

function SetCustomValidity(const Call: TBindingCall): TJsValue;
begin
  Context(Call).FormState(ThisElement(Call)).CustomValidity := Call.Text(0);
  Result := JsUndefined;
end;

{ HTMLElement }

procedure FireSimpleEvent(Element: TElement; const EventType: string; Bubbles: Boolean);
var
  Event: TEvent;
begin
  Event := TEvent.Create(EventType, Bubbles, False);
  try
    Element.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

function HTMLElement_click(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Event: TMouseEvent;
  WasChecked, IsCheckable: Boolean;
begin
  Result := JsUndefined;
  Element := ThisElement(Call);
  if Element.HasAttributeAtom(AtomDisabled) and IsListedElement(Element) then
    Exit;
  IsCheckable := Element.IsHtmlElement(AtomInput) and
    ((InputType(Element) = 'checkbox') or (InputType(Element) = 'radio'));
  WasChecked := IsCheckable and InputChecked(Context(Call), Element);
  if IsCheckable then
  begin
    if InputType(Element) = 'checkbox' then
      SetInputChecked(Context(Call), Element, not WasChecked)
    else
      SetInputChecked(Context(Call), Element, True);
  end;
  Event := TMouseEvent.Create('click', True, True);
  try
    Event.Composed := True;
    Event.HasView := True;
    Event.Detail := 1;
    Event.TimeStamp := Context(Call).Now;
    if not Element.DispatchEvent(Event) then
    begin
      if IsCheckable then
        SetInputChecked(Context(Call), Element, WasChecked);
      Exit;
    end;
  finally
    Event.Release;
  end;
  if IsCheckable and (WasChecked <> InputChecked(Context(Call), Element)) then
  begin
    FireSimpleEvent(Element, 'input', True);
    FireSimpleEvent(Element, 'change', True);
  end;
end;

function HTMLElement_focus(var Call: TBindingCall): TJsValue;
begin
  FocusElement(ThisElement(Call));
  Result := Nothing;
end;

function HTMLElement_blur(var Call: TBindingCall): TJsValue;
begin
  UnfocusElement(ThisElement(Call));
  Result := Nothing;
end;

function HTMLElement_get_contentEditable(var Call: TBindingCall): TJsValue;
var
  Value: string;
begin
  if not ThisElement(Call).HasAttributeAtom(AtomContenteditable) then
    Exit(Text(Call, 'inherit'));
  Value := AsciiLowerCase(ThisElement(Call).AttributeValueOf(AtomContenteditable));
  if (Value = '') or (Value = 'true') then
    Result := Text(Call, 'true')
  else if Value = 'false' then
    Result := Text(Call, 'false')
  else if Value = 'plaintext-only' then
    Result := Text(Call, 'plaintext-only')
  else
    Result := Text(Call, 'inherit');
end;

function HTMLElement_set_contentEditable(var Call: TBindingCall): TJsValue;
var
  Value: string;
begin
  Value := AsciiLowerCase(Call.Text(0));
  if Value = 'inherit' then
    ThisElement(Call).RemoveAttributeAtom(AtomContenteditable)
  else if (Value = 'true') or (Value = 'false') or (Value = 'plaintext-only') then
    ThisElement(Call).SetAttributeAtom(AtomContenteditable, NamespaceNone, Value)
  else
    RaiseDomError(SyntaxError, '''' + Call.Text(0) + ''' is not true, false, plaintext-only or inherit');
  Result := Nothing;
end;

function HTMLElement_get_isContentEditable(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Value: string;
begin
  Element := ThisElement(Call);
  while Element <> nil do
  begin
    if Element.HasAttributeAtom(AtomContenteditable) then
    begin
      Value := AsciiLowerCase(Element.AttributeValueOf(AtomContenteditable));
      if (Value = '') or (Value = 'true') or (Value = 'plaintext-only') then
        Exit(JsTrue);
      if Value = 'false' then
        Exit(JsFalse);
    end;
    Element := Element.ParentElement;
  end;
  Result := JsFalse;
end;

function HTMLElement_get_dataset(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call), InterfaceDOMStringMap, False, Call.This);
end;

function HTMLElement_get_style(var Call: TBindingCall): TJsValue;
begin
  Result := InlineStyleObject(Context(Call), ThisElement(Call), Call.This);
end;

function HTMLElement_get_innerText(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ThisElement(Call).TextContent);
end;

{ The text with line breaks as br elements, in a fragment. }
function TextWithBreaks(Element: TElement; const Value: string): TDocumentFragment;
var
  Document: TDocument;
  Start, Index: Integer;
begin
  Document := Element.NodeDocument;
  Result := Document.CreateDocumentFragment;
  Start := 1;
  Index := 1;
  while Index <= Length(Value) + 1 do
  begin
    if (Index > Length(Value)) or (Value[Index] in [#10, #13]) then
    begin
      if Index > Start then
        Result.AppendChild(Document.CreateTextNode(Copy(Value, Start, Index - Start)));
      if Index <= Length(Value) then
      begin
        Result.AppendChild(Document.CreateElement('br'));
        if (Value[Index] = #13) and (Index < Length(Value)) and (Value[Index + 1] = #10) then
          Inc(Index);
      end;
      Start := Index + 1;
    end;
    Inc(Index);
  end;
end;

function HTMLElement_set_innerText(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).ReplaceChildren([TextWithBreaks(ThisElement(Call), Call.Text(0))]);
  Result := Nothing;
end;

function HTMLElement_get_outerText(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ThisElement(Call).TextContent);
end;

function HTMLElement_set_outerText(var Call: TBindingCall): TJsValue;
begin
  if ThisElement(Call).ParentNode = nil then
    RaiseDomError(NoModificationAllowedError, 'the element has no parent');
  ThisElement(Call).ReplaceWith([TextWithBreaks(ThisElement(Call), Call.Text(0))]);
  Result := Nothing;
end;

function IsFocusableByDefault(Element: TElement): Boolean;
begin
  Result := Element.IsHtml and (((Element.LocalNameAtom = AtomA) and Element.HasAttributeAtom(AtomHref)) or
    (Element.LocalNameAtom = AtomInput) or (Element.LocalNameAtom = AtomButton) or
    (Element.LocalNameAtom = AtomSelect) or (Element.LocalNameAtom = AtomTextarea) or
    (Element.LocalNameAtom = AtomIframe) or (Element.LocalNameAtom = AtomSummary));
end;

function HTMLElement_get_tabIndex(var Call: TBindingCall): TJsValue;
var
  Value: Int64;
begin
  if ThisElement(Call).HasAttributeAtom(AtomTabindex) and
    ParseHtmlInteger(ThisElement(Call).AttributeValueOf(AtomTabindex), Value) and (Value >= -2147483648) and
    (Value <= 2147483647) then
    Exit(JsNumber(Value));
  if IsFocusableByDefault(ThisElement(Call)) then
    Result := JsInteger(0)
  else
    Result := JsInteger(-1);
end;

function HTMLElement_set_tabIndex(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).SetAttributeAtom(AtomTabindex, NamespaceNone, IntToStr(Call.Int(0)));
  Result := Nothing;
end;

function HTMLElement_get_translate(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Value: string;
begin
  Element := ThisElement(Call);
  while Element <> nil do
  begin
    if Element.HasAttributeAtom(AtomTranslate) then
    begin
      Value := AsciiLowerCase(Element.AttributeValueOf(AtomTranslate));
      if (Value = '') or (Value = 'yes') then
        Exit(JsTrue);
      if Value = 'no' then
        Exit(JsFalse);
    end;
    Element := Element.ParentElement;
  end;
  Result := JsTrue;
end;

function HTMLElement_set_translate(var Call: TBindingCall): TJsValue;
begin
  if Call.Flag(0) then
    ThisElement(Call).SetAttributeAtom(AtomTranslate, NamespaceNone, 'yes')
  else
    ThisElement(Call).SetAttributeAtom(AtomTranslate, NamespaceNone, 'no');
  Result := Nothing;
end;

function HTMLElement_get_offsetParent(var Call: TBindingCall): TJsValue;
begin
  Result := JsNull;
end;

function HTMLElement_get_offsetTop(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function HTMLElement_get_offsetLeft(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function HTMLElement_get_offsetWidth(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function HTMLElement_get_offsetHeight(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

{ HTMLHyperlinkElementUtils: the URL of the href attribute. }

function HyperlinkUrl(const Call: TBindingCall; out Url: TUrlRecord): Boolean;
begin
  Result := ThisElement(Call).HasAttributeAtom(AtomHref) and
    ResolveUrl(ThisElement(Call).NodeDocument, ThisElement(Call).AttributeValueOf(AtomHref), Url);
end;

type
  TUrlGetter = function(constref Url: TUrlRecord): string;
  TUrlSetter = procedure(var Url: TUrlRecord; const Value: string);

function HyperlinkPart(const Call: TBindingCall; Getter: TUrlGetter): TJsValue;
var
  Url: TUrlRecord;
begin
  if HyperlinkUrl(Call, Url) then
    Result := Text(Call, Getter(Url))
  else
    Result := Text(Call, '');
end;

function SetHyperlinkPart(const Call: TBindingCall; Setter: TUrlSetter): TJsValue;
var
  Url: TUrlRecord;
begin
  Result := Nothing;
  if not HyperlinkUrl(Call, Url) or Url.OpaquePath then
    Exit;
  Setter(Url, Call.Text(0));
  ThisElement(Call).SetAttributeAtom(AtomHref, NamespaceNone, SerializeUrl(Url));
end;

function HTMLHyperlinkElementUtils_get_origin(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetOrigin);
end;

function HTMLHyperlinkElementUtils_get_protocol(var Call: TBindingCall): TJsValue;
var
  Url: TUrlRecord;
begin
  if HyperlinkUrl(Call, Url) then
    Result := Text(Call, GetProtocol(Url))
  else
    Result := Text(Call, ':');
end;

function HTMLHyperlinkElementUtils_set_protocol(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetProtocol);
end;

function HTMLHyperlinkElementUtils_get_username(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetUsername);
end;

function HTMLHyperlinkElementUtils_set_username(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetUsername);
end;

function HTMLHyperlinkElementUtils_get_password(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetPassword);
end;

function HTMLHyperlinkElementUtils_set_password(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetPassword);
end;

function HTMLHyperlinkElementUtils_get_host(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetHost);
end;

function HTMLHyperlinkElementUtils_set_host(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetHost);
end;

function HTMLHyperlinkElementUtils_get_hostname(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetHostname);
end;

function HTMLHyperlinkElementUtils_set_hostname(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetHostname);
end;

function HTMLHyperlinkElementUtils_get_port(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetPort);
end;

function HTMLHyperlinkElementUtils_set_port(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetPort);
end;

function HTMLHyperlinkElementUtils_get_pathname(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetPathname);
end;

function HTMLHyperlinkElementUtils_set_pathname(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetPathname);
end;

function HTMLHyperlinkElementUtils_get_search(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetSearch);
end;

function HTMLHyperlinkElementUtils_set_search(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetSearch);
end;

function HTMLHyperlinkElementUtils_get_hash(var Call: TBindingCall): TJsValue;
begin
  Result := HyperlinkPart(Call, @GetHash);
end;

function HTMLHyperlinkElementUtils_set_hash(var Call: TBindingCall): TJsValue;
begin
  Result := SetHyperlinkPart(Call, @SetHash);
end;

{ HTMLAnchorElement, HTMLLinkElement, HTMLIFrameElement, HTMLStyleElement }

function HTMLAnchorElement_get_relList(var Call: TBindingCall): TJsValue;
begin
  Result := TokenList(Call, 'rel');
end;

function HTMLAnchorElement_get_text(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ThisElement(Call).TextContent);
end;

function HTMLAnchorElement_set_text(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

function HTMLLinkElement_get_relList(var Call: TBindingCall): TJsValue;
begin
  Result := TokenList(Call, 'rel');
end;

function HTMLIFrameElement_get_sandbox(var Call: TBindingCall): TJsValue;
begin
  Result := TokenList(Call, 'sandbox');
end;

function HTMLIFrameElement_get_contentDocument(var Call: TBindingCall): TJsValue;
var
  Frame: TBindingContext;
begin
  Frame := Context(Call).FrameOf(ThisElement(Call));
  if Frame = nil then
    Exit(JsNull);
  Result := Frame.WrapNode(Frame.Document);
end;

function HTMLIFrameElement_get_contentWindow(var Call: TBindingCall): TJsValue;
var
  Frame: TBindingContext;
begin
  Frame := Context(Call).FrameOf(ThisElement(Call));
  if Frame = nil then
    Exit(JsNull);
  Result := JsObjectValue(Frame.Engine.GlobalObject);
end;

function HTMLStyleElement_get_blocking(var Call: TBindingCall): TJsValue;
begin
  Result := TokenList(Call, 'blocking');
end;

function HTMLStyleElement_get_disabled(var Call: TBindingCall): TJsValue;
begin
  Result := JsFalse;
end;

function HTMLStyleElement_set_disabled(var Call: TBindingCall): TJsValue;
begin
  Result := Nothing;
end;

{ HTMLImageElement, HTMLMediaElement }

function HTMLImageElement_get_naturalWidth(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function HTMLImageElement_get_naturalHeight(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(0);
end;

function HTMLImageElement_get_complete(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

function HTMLImageElement_get_currentSrc(var Call: TBindingCall): TJsValue;
var
  Resolved: string;
begin
  if not ThisElement(Call).HasAttributeAtom(AtomSrc) or
    not ResolveUrlText(ThisElement(Call).NodeDocument, ThisElement(Call).AttributeValueOf(AtomSrc), Resolved) then
    Resolved := '';
  Result := Text(Call, Resolved);
end;

function HTMLMediaElement_get_paused(var Call: TBindingCall): TJsValue;
begin
  Result := JsTrue;
end;

{ HTMLInputElement }

function HTMLInputElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLInputElement_get_checked(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(InputChecked(Context(Call), ThisElement(Call)));
end;

function HTMLInputElement_set_checked(var Call: TBindingCall): TJsValue;
begin
  SetInputChecked(Context(Call), ThisElement(Call), Call.Flag(0));
  Result := Nothing;
end;

function HTMLInputElement_get_indeterminate(var Call: TBindingCall): TJsValue;
var
  State: TFormControlState;
begin
  State := Context(Call).FindFormState(ThisElement(Call));
  Result := JsBoolean((State <> nil) and State.Indeterminate);
end;

function HTMLInputElement_set_indeterminate(var Call: TBindingCall): TJsValue;
begin
  Context(Call).FormState(ThisElement(Call)).Indeterminate := Call.Flag(0);
  Result := Nothing;
end;

function HTMLInputElement_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, InputType(ThisElement(Call)));
end;

function HTMLInputElement_set_type(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).SetAttributeAtom(AtomType, NamespaceNone, Call.Text(0));
  Result := Nothing;
end;

function HTMLInputElement_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, InputValue(Context(Call), ThisElement(Call)));
end;

function HTMLInputElement_set_value(var Call: TBindingCall): TJsValue;
begin
  if (InputValueMode(ThisElement(Call)) = ValueModeFilename) and (Call.Text(0) <> '') then
    RaiseDomError(InvalidStateError, 'a file input''s value can only be cleared');
  SetInputValue(Context(Call), ThisElement(Call), Call.Text(0));
  Result := Nothing;
end;

function HTMLInputElement_get_valueAsNumber(var Call: TBindingCall): TJsValue;
var
  Number: Double;
  TypeName: string;
begin
  TypeName := InputType(ThisElement(Call));
  if ((TypeName = 'number') or (TypeName = 'range')) and
    ParseHtmlFloat(InputValue(Context(Call), ThisElement(Call)), Number) then
    Result := JsNumber(Number)
  else
    Result := JsDouble(NaN);
end;

function HTMLInputElement_set_valueAsNumber(var Call: TBindingCall): TJsValue;
var
  TypeName: string;
begin
  TypeName := InputType(ThisElement(Call));
  if (TypeName <> 'number') and (TypeName <> 'range') then
    RaiseDomError(InvalidStateError, 'valueAsNumber does not apply to this input');
  if IsNan(Call.Number(0)) then
    SetInputValue(Context(Call), ThisElement(Call), '')
  else if IsInfinite(Call.Number(0)) then
    raise EBindingTypeError.Create('the value is not finite')
  else
    SetInputValue(Context(Call), ThisElement(Call), NumberToString(Call.Number(0)));
  Result := Nothing;
end;

function HTMLInputElement_get_willValidate(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(WillValidate(ThisElement(Call)));
end;

function HTMLInputElement_checkValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLInputElement_reportValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLInputElement_setCustomValidity(var Call: TBindingCall): TJsValue;
begin
  Result := SetCustomValidity(Call);
end;

function HasSelection(Element: TElement): Boolean;
begin
  Result := IsTextControl(Element);
end;

procedure SelectAllText(Element: TElement);
begin
  SetTextSelection(Element, 0, Utf16Length(TextControlValue(Element)), 'none');
end;

function SelectionPart(var Call: TBindingCall; Part: Integer): TJsValue;
var
  Start, Finish: Integer;
  Direction: string;
begin
  if not HasSelection(ThisElement(Call)) then
    Exit(JsNull);
  GetTextSelection(ThisElement(Call), Start, Finish, Direction);
  case Part of
    0: Result := JsInteger(Start);
    1: Result := JsInteger(Finish);
  else
    Result := Text(Call, Direction);
  end;
end;

procedure SetSelectionPart(var Call: TBindingCall; Part: Integer);
var
  Start, Finish: Integer;
  Direction: string;
begin
  if not HasSelection(ThisElement(Call)) then
    RaiseDomError(InvalidStateError, 'this element has no selection');
  GetTextSelection(ThisElement(Call), Start, Finish, Direction);
  case Part of
    0:
      begin
        Start := Integer(Call.Int(0));
        if Finish < Start then
          Finish := Start;
      end;
    1:
      begin
        Finish := Integer(Call.Int(0));
        if Start > Finish then
          Start := Finish;
      end;
  else
    Direction := Call.Text(0);
  end;
  SetTextSelection(ThisElement(Call), Start, Finish, Direction);
end;

procedure SetSelectionRangeOf(var Call: TBindingCall);
var
  Direction: string;
begin
  if not HasSelection(ThisElement(Call)) then
    RaiseDomError(InvalidStateError, 'this element has no selection');
  Direction := 'none';
  if Call.Present(2) then
    Direction := Call.Text(2);
  SetTextSelection(ThisElement(Call), Integer(Call.Int(0)), Integer(Call.Int(1)), Direction);
end;

function HTMLInputElement_select(var Call: TBindingCall): TJsValue;
begin
  if HasSelection(ThisElement(Call)) then
    SelectAllText(ThisElement(Call));
  Result := Nothing;
end;

function HTMLInputElement_get_selectionStart(var Call: TBindingCall): TJsValue;
begin
  Result := SelectionPart(Call, 0);
end;

function HTMLInputElement_set_selectionStart(var Call: TBindingCall): TJsValue;
begin
  SetSelectionPart(Call, 0);
  Result := Nothing;
end;

function HTMLInputElement_get_selectionEnd(var Call: TBindingCall): TJsValue;
begin
  Result := SelectionPart(Call, 1);
end;

function HTMLInputElement_set_selectionEnd(var Call: TBindingCall): TJsValue;
begin
  SetSelectionPart(Call, 1);
  Result := Nothing;
end;

function HTMLInputElement_get_selectionDirection(var Call: TBindingCall): TJsValue;
begin
  Result := SelectionPart(Call, 2);
end;

function HTMLInputElement_set_selectionDirection(var Call: TBindingCall): TJsValue;
begin
  SetSelectionPart(Call, 2);
  Result := Nothing;
end;

function HTMLInputElement_setSelectionRange(var Call: TBindingCall): TJsValue;
begin
  SetSelectionRangeOf(Call);
  Result := Nothing;
end;

{ HTMLButtonElement }

function HTMLButtonElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLButtonElement_get_willValidate(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(WillValidate(ThisElement(Call)));
end;

function HTMLButtonElement_checkValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLButtonElement_reportValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLButtonElement_setCustomValidity(var Call: TBindingCall): TJsValue;
begin
  Result := SetCustomValidity(Call);
end;

{ HTMLTextAreaElement }

function HTMLTextAreaElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLTextAreaElement_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'textarea');
end;

function HTMLTextAreaElement_get_defaultValue(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ThisElement(Call).TextContent);
end;

function HTMLTextAreaElement_set_defaultValue(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

function HTMLTextAreaElement_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, TextAreaValue(Context(Call), ThisElement(Call)));
end;

function HTMLTextAreaElement_set_value(var Call: TBindingCall): TJsValue;
begin
  SetTextAreaValue(Context(Call), ThisElement(Call), Call.Text(0));
  Result := Nothing;
end;

function HTMLTextAreaElement_get_textLength(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Utf16Length(TextAreaValue(Context(Call), ThisElement(Call))));
end;

function HTMLTextAreaElement_get_willValidate(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(WillValidate(ThisElement(Call)));
end;

function HTMLTextAreaElement_checkValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLTextAreaElement_reportValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLTextAreaElement_setCustomValidity(var Call: TBindingCall): TJsValue;
begin
  Result := SetCustomValidity(Call);
end;

function HTMLTextAreaElement_select(var Call: TBindingCall): TJsValue;
begin
  SelectAllText(ThisElement(Call));
  Result := Nothing;
end;

function HTMLTextAreaElement_get_selectionStart(var Call: TBindingCall): TJsValue;
begin
  Result := SelectionPart(Call, 0);
end;

function HTMLTextAreaElement_set_selectionStart(var Call: TBindingCall): TJsValue;
begin
  SetSelectionPart(Call, 0);
  Result := Nothing;
end;

function HTMLTextAreaElement_get_selectionEnd(var Call: TBindingCall): TJsValue;
begin
  Result := SelectionPart(Call, 1);
end;

function HTMLTextAreaElement_set_selectionEnd(var Call: TBindingCall): TJsValue;
begin
  SetSelectionPart(Call, 1);
  Result := Nothing;
end;

function HTMLTextAreaElement_get_selectionDirection(var Call: TBindingCall): TJsValue;
begin
  Result := SelectionPart(Call, 2);
end;

function HTMLTextAreaElement_set_selectionDirection(var Call: TBindingCall): TJsValue;
begin
  SetSelectionPart(Call, 2);
  Result := Nothing;
end;

function HTMLTextAreaElement_setSelectionRange(var Call: TBindingCall): TJsValue;
begin
  SetSelectionRangeOf(Call);
  Result := Nothing;
end;

{ HTMLSelectElement }

function HTMLSelectElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLSelectElement_get_type(var Call: TBindingCall): TJsValue;
begin
  if ThisElement(Call).HasAttributeAtom(AtomMultiple) then
    Result := Text(Call, 'select-multiple')
  else
    Result := Text(Call, 'select-one');
end;

function HTMLSelectElement_get_options(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(TOptionsCollection.Create(ThisElement(Call)), InterfaceHTMLOptionsCollection,
    True, Call.This);
end;

function HTMLSelectElement_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Length(SelectOptions(ThisElement(Call))));
end;

function HTMLSelectElement_item(var Call: TBindingCall): TJsValue;
var
  Options: TNodeArray;
begin
  Options := SelectOptions(ThisElement(Call));
  if (Call.Number(0) < 0) or (Call.Number(0) >= Length(Options)) then
    Exit(JsNull);
  Result := Context(Call).WrapNode(Options[Trunc(Call.Number(0))]);
end;

function HTMLSelectElement_namedItem(var Call: TBindingCall): TJsValue;
var
  Options: TNodeArray;
  Index: Integer;
begin
  Options := SelectOptions(ThisElement(Call));
  for Index := 0 to High(Options) do
    if (TElement(Options[Index]).AttributeValueOf(AtomId) = Call.Text(0)) or
      (TElement(Options[Index]).AttributeValueOf(AtomName) = Call.Text(0)) then
      Exit(Context(Call).WrapNode(Options[Index]));
  Result := JsNull;
end;

function HTMLSelectElement_add(var Call: TBindingCall): TJsValue;
var
  Before: TNode;
  Options: TNodeArray;
begin
  Before := nil;
  if Call.Arguments[1].Kind = bvNative then
    Before := TNode(Call.Native(1))
  else if Call.Arguments[1].Kind = bvNumber then
  begin
    Options := SelectOptions(ThisElement(Call));
    if (Call.Number(1) >= 0) and (Call.Number(1) < Length(Options)) then
      Before := Options[Trunc(Call.Number(1))];
  end;
  if (Before <> nil) and (Before.ParentNode <> nil) then
    Before.ParentNode.InsertBefore(TNode(Call.Native(0)), Before)
  else
    ThisElement(Call).AppendChild(TNode(Call.Native(0)));
  Result := Nothing;
end;

function HTMLSelectElement_remove(var Call: TBindingCall): TJsValue;
var
  Options: TNodeArray;
begin
  Result := Nothing;
  if not Call.Present(0) then
  begin
    ThisElement(Call).Remove;
    Exit;
  end;
  Options := SelectOptions(ThisElement(Call));
  if (Call.Number(0) >= 0) and (Call.Number(0) < Length(Options)) then
    Options[Trunc(Call.Number(0))].Remove;
end;

function HTMLSelectElement_get_selectedOptions(var Call: TBindingCall): TJsValue;
var
  Items: TSelectedOptionsCollection;
begin
  Items := TSelectedOptionsCollection.Create(ThisElement(Call));
  Items.Context := Context(Call);
  Result := Context(Call).WrapObject(Items, InterfaceHTMLCollection, True, Call.This);
end;

function HTMLSelectElement_get_selectedIndex(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(SelectSelectedIndex(Context(Call), ThisElement(Call)));
end;

function HTMLSelectElement_set_selectedIndex(var Call: TBindingCall): TJsValue;
begin
  SetSelectSelectedIndex(Context(Call), ThisElement(Call), Call.Int(0));
  Result := Nothing;
end;

function HTMLSelectElement_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ControlValue(Call, ThisElement(Call)));
end;

function HTMLSelectElement_set_value(var Call: TBindingCall): TJsValue;
var
  Options: TNodeArray;
  Index: Integer;
begin
  Options := SelectOptions(ThisElement(Call));
  for Index := 0 to High(Options) do
    if OptionValue(TElement(Options[Index])) = Call.Text(0) then
    begin
      SetSelectSelectedIndex(Context(Call), ThisElement(Call), Index);
      Exit(Nothing);
    end;
  SetSelectSelectedIndex(Context(Call), ThisElement(Call), -1);
  Result := Nothing;
end;

function HTMLSelectElement_get_willValidate(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(WillValidate(ThisElement(Call)));
end;

function HTMLSelectElement_checkValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLSelectElement_reportValidity(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(CheckValidity(Call, ThisElement(Call)));
end;

function HTMLSelectElement_setCustomValidity(var Call: TBindingCall): TJsValue;
begin
  Result := SetCustomValidity(Call);
end;

{ HTMLOptionElement }

function HTMLOptionElement_get_form(var Call: TBindingCall): TJsValue;
var
  Select: TElement;
begin
  Select := OptionSelect(ThisElement(Call));
  if Select = nil then
    Exit(JsNull);
  Result := Context(Call).WrapNode(FormOwner(Select));
end;

function HTMLOptionElement_get_selected(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(OptionSelected(Context(Call), ThisElement(Call)));
end;

function HTMLOptionElement_set_selected(var Call: TBindingCall): TJsValue;
begin
  SetOptionSelected(Context(Call), ThisElement(Call), Call.Flag(0));
  Result := Nothing;
end;

function HTMLOptionElement_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, OptionValue(ThisElement(Call)));
end;

function HTMLOptionElement_set_value(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).SetAttributeAtom(AtomValue, NamespaceNone, Call.Text(0));
  Result := Nothing;
end;

function HTMLOptionElement_get_text(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, OptionText(ThisElement(Call)));
end;

function HTMLOptionElement_set_text(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

function HTMLOptionElement_get_index(var Call: TBindingCall): TJsValue;
var
  Select: TElement;
  Options: TNodeArray;
  Index: Integer;
begin
  Select := OptionSelect(ThisElement(Call));
  if Select = nil then
    Exit(JsInteger(0));
  Options := SelectOptions(Select);
  for Index := 0 to High(Options) do
    if Options[Index] = ThisElement(Call) then
      Exit(JsInteger(Index));
  Result := JsInteger(0);
end;

{ HTMLFormElement }

function HTMLFormElement_get_elements(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(TFormElementsCollection.Create(ThisElement(Call)),
    InterfaceHTMLFormControlsCollection, True, Call.This);
end;

function FormControls(Form: TElement): TNodeArray;
var
  Node: TNode;
  Root: TNode;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  Root := Form.GetRootNode;
  Node := Root;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and IsListedElement(TElement(Node)) and
      (FormOwner(TElement(Node)) = Form) then
    begin
      SetLength(Result, Count + 1);
      Result[Count] := Node;
      Inc(Count);
    end;
    Node := Node.NextInTree(Root);
  end;
end;

function HTMLFormElement_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(Length(FormControls(ThisElement(Call))));
end;

function HTMLFormElement_checkValidity(var Call: TBindingCall): TJsValue;
var
  Controls: TNodeArray;
  Index: Integer;
  Valid: Boolean;
begin
  Valid := True;
  Controls := FormControls(ThisElement(Call));
  for Index := 0 to High(Controls) do
    if not CheckValidity(Call, TElement(Controls[Index])) then
      Valid := False;
  Result := JsBoolean(Valid);
end;

function HTMLFormElement_reportValidity(var Call: TBindingCall): TJsValue;
begin
  Result := HTMLFormElement_checkValidity(Call);
end;

{ The form data of the controls as name-value pairs (text values only:
  no files). }
function FormDataSet(const Call: TBindingCall; Form, Submitter: TElement): TNameValueList;
var
  Controls: TNodeArray;
  Index, Count: Integer;
  Control: TElement;
  Name, TypeName: string;
  Options: TNodeArray;
  OptionIndex: Integer;

  procedure Add(const PairName, Value: string);
  begin
    SetLength(Result, Count + 1);
    Result[Count].Name := PairName;
    Result[Count].Value := Value;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  Controls := FormControls(Form);
  for Index := 0 to High(Controls) do
  begin
    Control := TElement(Controls[Index]);
    Name := Control.AttributeValueOf(AtomName);
    if (Name = '') or Control.HasAttributeAtom(AtomDisabled) then
      Continue;
    if Control.IsHtmlElement(AtomInput) then
    begin
      TypeName := InputType(Control);
      if (TypeName = 'checkbox') or (TypeName = 'radio') then
      begin
        if InputChecked(Context(Call), Control) then
          Add(Name, InputValue(Context(Call), Control));
      end
      else if (TypeName = 'submit') or (TypeName = 'image') then
      begin
        if Control = Submitter then
          Add(Name, InputValue(Context(Call), Control));
      end
      else if (TypeName <> 'reset') and (TypeName <> 'button') and (TypeName <> 'file') then
        Add(Name, InputValue(Context(Call), Control));
    end
    else if Control.IsHtmlElement(AtomButton) then
    begin
      if Control = Submitter then
        Add(Name, Control.AttributeValueOf(AtomValue));
    end
    else if Control.IsHtmlElement(AtomSelect) then
    begin
      Options := SelectOptions(Control);
      for OptionIndex := 0 to High(Options) do
        if OptionSelected(Context(Call), TElement(Options[OptionIndex])) and
          not TElement(Options[OptionIndex]).HasAttributeAtom(AtomDisabled) then
          Add(Name, OptionValue(TElement(Options[OptionIndex])));
    end
    else if Control.IsHtmlElement(AtomTextarea) then
      Add(Name, TextAreaValue(Context(Call), Control));
  end;
end;

{ Form submission: GET forms navigate to the action with the form data
  as the query (through the environment); POST needs request bodies,
  which navigation does not take yet. }
procedure SubmitForm(const Call: TBindingCall; Form, Submitter: TElement);
var
  Action: TUrlRecord;
  ActionText, Method: string;
begin
  Method := AsciiLowerCase(Form.AttributeValueOf(AtomMethod));
  if Method = 'post' then
    RaiseUnsupported('form submission by POST');
  if Method = 'dialog' then
    Exit;
  ActionText := Form.AttributeValueOf(AtomAction);
  if not ResolveUrl(Form.NodeDocument, ActionText, Action) then
    Exit;
  Action.HasQuery := True;
  Action.Query := SerializeFormEncoded(FormDataSet(Call, Form, Submitter));
  Context(Call).Environment.Navigate(Context(Call), SerializeUrl(Action), False);
end;

function HTMLFormElement_submit(var Call: TBindingCall): TJsValue;
begin
  SubmitForm(Call, ThisElement(Call), nil);
  Result := Nothing;
end;

function HTMLFormElement_requestSubmit(var Call: TBindingCall): TJsValue;
var
  Event: TEvent;
  Proceed: Boolean;
begin
  Result := Nothing;
  if not ThisElement(Call).HasAttributeAtom(Atomize('novalidate')) and
    (HTMLFormElement_checkValidity(Call) = JsFalse) then
    Exit;
  Event := TEvent.Create('submit', True, True);
  try
    Proceed := ThisElement(Call).DispatchEvent(Event);
  finally
    Event.Release;
  end;
  if Proceed then
    SubmitForm(Call, ThisElement(Call), TElement(Call.Native(0)));
end;

procedure ResetState(State: TFormControlState);
begin
  if State = nil then
    Exit;
  State.ValueDirty := False;
  State.CheckedDirty := False;
  State.SelectedDirty := False;
end;

function HTMLFormElement_reset(var Call: TBindingCall): TJsValue;
var
  Event: TEvent;
  Controls, Options: TNodeArray;
  Index, Position: Integer;
begin
  Result := Nothing;
  Event := TEvent.Create('reset', True, True);
  try
    if not ThisElement(Call).DispatchEvent(Event) then
      Exit;
  finally
    Event.Release;
  end;
  Controls := FormControls(ThisElement(Call));
  for Index := 0 to High(Controls) do
  begin
    ResetState(Context(Call).FindFormState(TElement(Controls[Index])));
    if TElement(Controls[Index]).IsHtmlElement(AtomSelect) then
    begin
      Options := SelectOptions(TElement(Controls[Index]));
      for Position := 0 to High(Options) do
        ResetState(Context(Call).FindFormState(TElement(Options[Position])));
    end;
  end;
end;

{ Other form-associated elements }

function HTMLLabelElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function IsLabelable(Element: TElement): Boolean;
begin
  Result := Element.IsHtml and ((Element.LocalNameAtom = AtomButton) or (Element.LocalNameAtom = AtomMeter) or
    (Element.LocalNameAtom = AtomOutput) or (Element.LocalNameAtom = AtomProgress) or
    (Element.LocalNameAtom = AtomSelect) or (Element.LocalNameAtom = AtomTextarea) or
    ((Element.LocalNameAtom = AtomInput) and (InputType(Element) <> 'hidden')));
end;

function HTMLLabelElement_get_control(var Call: TBindingCall): TJsValue;
var
  Label_: TElement;
  Node: TNode;
  Target: TElement;
begin
  Label_ := ThisElement(Call);
  if Label_.HasAttributeAtom(AtomFor) then
  begin
    Target := nil;
    if Label_.IsConnected then
      Target := Label_.NodeDocument.GetElementById(Label_.AttributeValueOf(AtomFor));
    if (Target <> nil) and IsLabelable(Target) then
      Exit(Context(Call).WrapNode(Target));
    Exit(JsNull);
  end;
  Node := Label_.FirstChild;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and IsLabelable(TElement(Node)) then
      Exit(Context(Call).WrapNode(Node));
    Node := Node.NextInTree(Label_);
  end;
  Result := JsNull;
end;

function HTMLFieldSetElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLFieldSetElement_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'fieldset');
end;

function HTMLLegendElement_get_form(var Call: TBindingCall): TJsValue;
var
  Parent: TElement;
begin
  Parent := ThisElement(Call).ParentElement;
  if (Parent = nil) or not Parent.IsHtmlElement(AtomFieldset) then
    Exit(JsNull);
  Result := Context(Call).WrapNode(FormOwner(Parent));
end;

function HTMLObjectElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLOutputElement_get_form(var Call: TBindingCall): TJsValue;
begin
  Result := FormValue(Call);
end;

function HTMLOutputElement_get_type(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, 'output');
end;

function HTMLOutputElement_get_defaultValue(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ThisElement(Call).TextContent);
end;

function HTMLOutputElement_set_defaultValue(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

function HTMLOutputElement_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ThisElement(Call).TextContent);
end;

function HTMLOutputElement_set_value(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

{ HTMLScriptElement, HTMLTemplateElement, HTMLTitleElement,
  HTMLDialogElement }

function ChildTextContent(Element: TElement): string;
var
  Child: TNode;
begin
  Result := '';
  Child := Element.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType in [NodeTypeText, NodeTypeCDataSection] then
      Result := Result + TCharacterData(Child).Data;
    Child := Child.NextSibling;
  end;
end;

function HTMLScriptElement_get_async(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(((ThisElement(Call).ElementState and ElementStateForceAsync) <> 0) or
    ThisElement(Call).HasAttributeAtom(AtomAsync));
end;

function HTMLScriptElement_set_async(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).ElementState := ThisElement(Call).ElementState and not ElementStateForceAsync;
  if Call.Flag(0) then
    ThisElement(Call).SetAttributeAtom(AtomAsync, NamespaceNone, '')
  else
    ThisElement(Call).RemoveAttributeAtom(AtomAsync);
  Result := Nothing;
end;

function HTMLScriptElement_get_text(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ChildTextContent(ThisElement(Call)));
end;

function HTMLScriptElement_set_text(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

function HTMLScriptElement_supports(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(Call.Text(0) = 'classic');
end;

function HTMLTemplateElement_get_content(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisElement(Call).TemplateContent);
end;

function HTMLTitleElement_get_text(var Call: TBindingCall): TJsValue;
begin
  Result := Text(Call, ChildTextContent(ThisElement(Call)));
end;

function HTMLTitleElement_set_text(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).TextContent := Call.Text(0);
  Result := Nothing;
end;

function HTMLDialogElement_get_returnValue(var Call: TBindingCall): TJsValue;
var
  State: TFormControlState;
begin
  State := Context(Call).FindFormState(ThisElement(Call));
  if State = nil then
    Result := Text(Call, '')
  else
    Result := Text(Call, State.Value);
end;

function HTMLDialogElement_set_returnValue(var Call: TBindingCall): TJsValue;
begin
  Context(Call).FormState(ThisElement(Call)).Value := Call.Text(0);
  Result := Nothing;
end;

end.
