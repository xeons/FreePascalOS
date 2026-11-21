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
  bindings/Style.webidl: an element's style attribute as a
  CSSStyleDeclaration (CSSOM 6.7), over libcss's declaration parser and
  blocks. The block is parsed again when the attribute's text changed;
  every change serializes the block back into the attribute.

  The CSS properties are reached by name on the wrapper (camel-cased
  "backgroundColor", "cssFloat", "webkitTransform", or as written,
  "background-color"): TStyleDeclarationWrapper answers [[Get]], [[Set]]
  and [[HasProperty]] for them instead of a prototype accessor pair per
  property and spelling (some 1800 functions per context).

  getComputedStyle answers with the inline declarations, read only,
  until the style system (Web.Style*) can compute styles.
}
unit Web.Bindings.Style;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Dom,
  Web.Bindings.Types,
  Web.Bindings.Context;

{$I Web.Bindings.Style.Members.inc}

{ The CSSStyleDeclaration of an element's style attribute. }
function InlineStyleObject(Context: TBindingContext; Element: TElement; OwnerWrapper: TJsValue): TJsValue;
{ getComputedStyle's (read only) declaration. }
function ComputedStyleObject(Context: TBindingContext; Element: TElement; OwnerWrapper: TJsValue): TJsValue;

type
  { Told after script changed a rule's declarations. }
  TRuleStyleChanged = procedure(Context: TBindingContext; Rule: TObject);

{ The CSSStyleDeclaration of the style rule (or keyframe) RuleWrapper
  wraps (CSSStyleRule.style): the rule's own block, changed in place;
  Changed is called after each change. }
function RuleStyleObject(Context: TBindingContext; RuleWrapper: TBindingWrapper; Changed: TRuleStyleChanged): TJsValue;

implementation

uses
  SysUtils,
  Js.Strings,
  Js.Runtime,
  Js.Objects,
  Js.Conversions,
  Css.Atoms,
  Css.Tokens,
  Css.Tokenizer,
  Css.Values,
  Css.PropertyIds,
  Css.Properties,
  Css.Shorthands,
  Css.Declarations,
  Css.Parser,
  Css.Stylesheets,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Exceptions,
  Web.Bindings.Strings,
  Web.Bindings.Exotic;

type
  { What a CSSStyleDeclaration is over: a declaration block it reads and
    replaces. }
  TStyleDeclarationData = class
  protected
    FReadOnly: Boolean;
    { Takes Updated as the declarations. }
    procedure ReplaceBlock(Updated: TCssDeclarationBlock); virtual; abstract;
  public
    function Block: TCssDeclarationBlock; virtual; abstract;
    procedure CheckWritable;
    procedure SetCssText(const Text: string);
    function PropertyValue(const Name: string): string;
    function PropertyPriority(const Name: string): string;
    procedure SetProperty(const Name, Value, Priority: string);
    function RemoveProperty(const Name: string): string;
  end;

  TInlineStyle = class(TStyleDeclarationData)
  private
    FElement: TElement;
    FSource: string;
    FBlock: TCssDeclarationBlock;
  protected
    procedure ReplaceBlock(Updated: TCssDeclarationBlock); override;
  public
    constructor Create(Element: TElement; ReadOnly: Boolean);
    destructor Destroy; override;
    function Block: TCssDeclarationBlock; override;
  end;

  { A style rule's or keyframe's declarations (the rule is the native
    object of RuleWrapper, nil once the rule is gone). }
  TRuleStyle = class(TStyleDeclarationData)
  private
    FRuleWrapper: TBindingWrapper;
    FEmpty: TCssDeclarationBlock;
    FChanged: TRuleStyleChanged;
    function RuleBlock: TCssDeclarationBlock;
  protected
    procedure ReplaceBlock(Updated: TCssDeclarationBlock); override;
  public
    constructor Create(RuleWrapper: TBindingWrapper; Changed: TRuleStyleChanged);
    destructor Destroy; override;
    function Block: TCssDeclarationBlock; override;
  end;

  TStyleDeclarationWrapper = class(TIndexedWrapper)
  private
    function StyleProperty(R: TJsRealm; Key: TJsValue; out Name: string): Boolean;
  public
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
  end;

{ TInlineStyle }

constructor TInlineStyle.Create(Element: TElement; ReadOnly: Boolean);
begin
  inherited Create;
  FElement := Element;
  FReadOnly := ReadOnly;
end;

destructor TInlineStyle.Destroy;
begin
  FBlock.Free;
  inherited Destroy;
end;

function TInlineStyle.Block: TCssDeclarationBlock;
var
  Source: string;
begin
  Source := FElement.AttributeValueOf(AtomStyle);
  if (FBlock = nil) or (Source <> FSource) then
  begin
    FreeAndNil(FBlock);
    FBlock := ParseStyleAttribute(Source);
    FSource := Source;
  end;
  Result := FBlock;
end;

procedure TInlineStyle.ReplaceBlock(Updated: TCssDeclarationBlock);
begin
  FBlock.Free;
  FBlock := Updated;
  FSource := FBlock.Serialize;
  FElement.SetAttributeAtom(AtomStyle, NamespaceNone, FSource);
end;

{ TRuleStyle }

constructor TRuleStyle.Create(RuleWrapper: TBindingWrapper; Changed: TRuleStyleChanged);
begin
  inherited Create;
  FRuleWrapper := RuleWrapper;
  FChanged := Changed;
  FEmpty := TCssDeclarationBlock.Create;
end;

destructor TRuleStyle.Destroy;
begin
  FEmpty.Free;
  inherited Destroy;
end;

function TRuleStyle.RuleBlock: TCssDeclarationBlock;
var
  Rule: TObject;
begin
  Result := nil;
  Rule := TObject(FRuleWrapper.NativeData);
  if Rule is TCssStyleRule then
    Result := TCssStyleRule(Rule).Declarations
  else if Rule is TCssKeyframeRule then
    Result := TCssKeyframeRule(Rule).Declarations;
end;

function TRuleStyle.Block: TCssDeclarationBlock;
begin
  Result := RuleBlock;
  if Result = nil then
    Result := FEmpty;
end;

{ The rule's block is changed in place: the style engine's index points
  at it. }
procedure TRuleStyle.ReplaceBlock(Updated: TCssDeclarationBlock);
var
  Target: TCssDeclarationBlock;
  Index: Integer;
  Declaration: PCssDeclaration;
begin
  try
    Target := RuleBlock;
    if Target = nil then
      Exit;
    Target.Clear;
    for Index := 0 to Updated.Count - 1 do
    begin
      Declaration := Updated.Item(Index);
      Target.Add(Declaration^.Id, Declaration^.Value.AddRef, Declaration^.Important, Declaration^.Shorthand,
        Declaration^.CustomName);
    end;
    if Assigned(FChanged) then
      FChanged(FRuleWrapper.Binding.Context, TObject(FRuleWrapper.NativeData));
  finally
    Updated.Free;
  end;
end;

{ TStyleDeclarationData }

procedure TStyleDeclarationData.CheckWritable;
begin
  if FReadOnly then
    RaiseDomError(NoModificationAllowedError, 'this declaration is read only');
end;

procedure TStyleDeclarationData.SetCssText(const Text: string);
begin
  CheckWritable;
  ReplaceBlock(ParseStyleAttribute(Text));
end;

function TStyleDeclarationData.PropertyValue(const Name: string): string;
begin
  Result := Block.PropertyValue(Name);
end;

function TStyleDeclarationData.PropertyPriority(const Name: string): string;
var
  Id: TCssPropertyId;
  Declaration: PCssDeclaration;
  Longhands: TCssPropertyIdArray;
  Index: Integer;
begin
  Result := '';
  Id := PropertyByName(Name);
  if Id = cpInvalid then
    Exit;
  if Id = cpCustom then
    Declaration := Block.FindCustom(InternAtom(Name))
  else if IsShorthand(Id) then
  begin
    Longhands := ShorthandLonghands(Id);
    for Index := 0 to High(Longhands) do
    begin
      Declaration := Block.Find(Longhands[Index]);
      if (Declaration = nil) or not Declaration^.Important then
        Exit;
    end;
    Exit('important');
  end
  else
    Declaration := Block.Find(Id);
  if (Declaration <> nil) and Declaration^.Important then
    Result := 'important';
end;

{ A copy of Source without the declarations of the property Name. }
function BlockWithout(Source: TCssDeclarationBlock; const Name: string): TCssDeclarationBlock;
var
  Id: TCssPropertyId;
  Longhands: TCssPropertyIdArray;
  Index, Position: Integer;
  Declaration: PCssDeclaration;
  Skip: Boolean;
  CustomName: TCssAtom;
begin
  Id := PropertyByName(Name);
  Longhands := nil;
  CustomName := NoAtom;
  if Id = cpCustom then
    CustomName := InternAtom(Name)
  else if IsShorthand(Id) then
    Longhands := ShorthandLonghands(Id)
  else if Id <> cpInvalid then
  begin
    SetLength(Longhands, 1);
    Longhands[0] := Id;
  end;
  Result := TCssDeclarationBlock.Create;
  for Index := 0 to Source.Count - 1 do
  begin
    Declaration := Source.Item(Index);
    Skip := (CustomName <> NoAtom) and (Declaration^.Id = cpCustom) and (Declaration^.CustomName = CustomName);
    for Position := 0 to High(Longhands) do
      if Declaration^.Id = Longhands[Position] then
        Skip := True;
    if not Skip then
      Result.Add(Declaration^.Id, Declaration^.Value.AddRef, Declaration^.Important, Declaration^.Shorthand,
        Declaration^.CustomName);
  end;
end;

procedure TStyleDeclarationData.SetProperty(const Name, Value, Priority: string);
var
  Parsed, Updated: TCssDeclarationBlock;
  Cursor: TCssTokenCursor;
  Important: Boolean;
  Index: Integer;
  Declaration: PCssDeclaration;
begin
  CheckWritable;
  if Value = '' then
  begin
    RemoveProperty(Name);
    Exit;
  end;
  if (Priority <> '') and not SameText(Priority, 'important') then
    Exit;
  Important := Priority <> '';
  Parsed := TCssDeclarationBlock.Create;
  try
    Cursor := TCssTokenCursor.Create(TokenizeCss(Value));
    if not Parsed.AddParsed(Name, TrimRange(Cursor), Important) then
      Exit;
    Updated := BlockWithout(Block, Name);
    for Index := 0 to Parsed.Count - 1 do
    begin
      Declaration := Parsed.Item(Index);
      Updated.Add(Declaration^.Id, Declaration^.Value.AddRef, Declaration^.Important, Declaration^.Shorthand,
        Declaration^.CustomName);
    end;
    ReplaceBlock(Updated);
  finally
    Parsed.Free;
  end;
end;

function TStyleDeclarationData.RemoveProperty(const Name: string): string;
begin
  CheckWritable;
  Result := PropertyValue(Name);
  if Result = '' then
    Exit;
  ReplaceBlock(BlockWithout(Block, Name));
end;

{ Property names from script: "backgroundColor" is background-color,
  "webkitTransform" and "WebkitTransform" are -webkit-transform. }
function DashedName(const Name: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Name) do
    if Name[Index] in ['A'..'Z'] then
      Result := Result + '-' + Chr(Ord(Name[Index]) + 32)
    else
      Result := Result + Name[Index];
  if Copy(Result, 1, 7) = 'webkit-' then
    Result := '-' + Result;
end;

function CssPropertyName(const Name: string): string;
begin
  Result := '';
  if (Name = '') or (Name[1] = '-') and (Copy(Name, 1, 2) = '--') then
    Exit;
  if Name = 'cssFloat' then
    Exit('float');
  if Pos('-', Name) > 0 then
  begin
    if (PropertyByName(Name) <> cpInvalid) and (AsciiLowercase(Name) = Name) then
      Result := Name;
    Exit;
  end;
  Result := DashedName(Name);
  if PropertyByName(Result) = cpInvalid then
    Result := '';
end;

{ TStyleDeclarationWrapper }

function TStyleDeclarationWrapper.StyleProperty(R: TJsRealm; Key: TJsValue; out Name: string): Boolean;
begin
  Name := '';
  if not JsIsString(Key) or (NativeData = nil) then
    Exit(False);
  Name := CssPropertyName(JsStringToText(R.Heap, JsAsString(Key)));
  Result := Name <> '';
end;

function TStyleDeclarationWrapper.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Name: string;
begin
  if StyleProperty(R, Key, Name) and (Proto.HasProperty(R, Key) = 0) then
    Exit(Binding.Context.TextValue(TStyleDeclarationData(NativeData).PropertyValue(Name)));
  Result := inherited Get(R, Key, Receiver);
end;

function TStyleDeclarationWrapper.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  Name: string;
  Text: TJsString;
begin
  if (Receiver = JsObjectValue(Self)) and StyleProperty(R, Key, Name) and (Proto.HasProperty(R, Key) = 0) then
  begin
    if Value = JsNull then
      Text := JsAsString(Binding.Context.TextValue(''))
    else
      Text := ToJsString(R, Value);
    if Text = nil then
      Exit(-1);
    try
      TStyleDeclarationData(NativeData).SetProperty(Name, JsStringToText(R.Heap, Text), '');
    except
      on Error: Exception do
      begin
        Binding.Context.ThrowFromException(Error);
        Exit(-1);
      end;
    end;
    Exit(1);
  end;
  Result := inherited SetValue(R, Key, Value, Receiver);
end;

function TStyleDeclarationWrapper.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Name: string;
begin
  if StyleProperty(R, Key, Name) then
    Exit(1);
  Result := inherited HasProperty(R, Key);
end;

function InlineStyleObject(Context: TBindingContext; Element: TElement; OwnerWrapper: TJsValue): TJsValue;
begin
  Result := Context.WrapObjectAs(TStyleDeclarationWrapper, TInlineStyle.Create(Element, False),
    InterfaceCSSStyleProperties, True, OwnerWrapper);
end;

function ComputedStyleObject(Context: TBindingContext; Element: TElement; OwnerWrapper: TJsValue): TJsValue;
begin
  Result := Context.WrapObjectAs(TStyleDeclarationWrapper, TInlineStyle.Create(Element, True),
    InterfaceCSSStyleProperties, True, OwnerWrapper);
end;

function RuleStyleObject(Context: TBindingContext; RuleWrapper: TBindingWrapper; Changed: TRuleStyleChanged): TJsValue;
begin
  Result := Context.WrapObjectAs(TStyleDeclarationWrapper, TRuleStyle.Create(RuleWrapper, Changed),
    InterfaceCSSStyleProperties, True, JsObjectValue(RuleWrapper));
end;

{ CSSStyleDeclaration }

function ThisStyle(const Call: TBindingCall): TStyleDeclarationData; inline;
begin
  Result := TStyleDeclarationData(Call.Target);
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function CSSStyleDeclaration_get_cssText(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisStyle(Call).Block.Serialize);
end;

function CSSStyleDeclaration_set_cssText(var Call: TBindingCall): TJsValue;
begin
  ThisStyle(Call).SetCssText(Call.Text(0));
  Result := JsUndefined;
end;

function CSSStyleDeclaration_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisStyle(Call).Block.Count);
end;

function CSSStyleDeclaration_item(var Call: TBindingCall): TJsValue;
var
  Block: TCssDeclarationBlock;
  Declaration: PCssDeclaration;
begin
  Block := ThisStyle(Call).Block;
  if (Call.Number(0) < 0) or (Call.Number(0) >= Block.Count) then
  begin
    if Call.Member = nil then
      Exit(JsUndefined);
    Exit(Context(Call).TextValue(''));
  end;
  Declaration := Block.Item(Trunc(Call.Number(0)));
  if Declaration^.Id = cpCustom then
    Result := Context(Call).TextValue(Css.Atoms.AtomText(Declaration^.CustomName))
  else
    Result := Context(Call).TextValue(PropertyName(Declaration^.Id));
end;

function CSSStyleDeclaration_getPropertyValue(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisStyle(Call).PropertyValue(Call.Text(0)));
end;

function CSSStyleDeclaration_getPropertyPriority(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisStyle(Call).PropertyPriority(Call.Text(0)));
end;

function CSSStyleDeclaration_setProperty(var Call: TBindingCall): TJsValue;
begin
  ThisStyle(Call).SetProperty(Call.Text(0), Call.Text(1), Call.Text(2));
  Result := JsUndefined;
end;

function CSSStyleDeclaration_removeProperty(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisStyle(Call).RemoveProperty(Call.Text(0)));
end;

function CSSStyleDeclaration_get_parentRule(var Call: TBindingCall): TJsValue;
begin
  if (Call.Target is TRuleStyle) and (TRuleStyle(Call.Target).FRuleWrapper.NativeData <> nil) then
    Result := JsObjectValue(TRuleStyle(Call.Target).FRuleWrapper)
  else
    Result := JsNull;
end;

function CSSStyleProperties_get_cssFloat(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisStyle(Call).PropertyValue('float'));
end;

function CSSStyleProperties_set_cssFloat(var Call: TBindingCall): TJsValue;
begin
  ThisStyle(Call).SetProperty('float', Call.Text(0), '');
  Result := JsUndefined;
end;

end.
