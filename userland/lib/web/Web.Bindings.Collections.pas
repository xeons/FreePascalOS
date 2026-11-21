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
  bindings/Collections.webidl: NodeList, HTMLCollection, NamedNodeMap
  and DOMTokenList over Web.Dom's classes; DOMStringMap (dataset) over
  the element's data-* attributes (its native object is the element);
  HTMLOptionsCollection over a select element's options.
}
unit Web.Bindings.Collections;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Dom,
  Web.Bindings.Types;

{$I Web.Bindings.Collections.Members.inc}

type
  { A select element's options (its list of options): the option
    children and the options of its optgroup children. }
  TOptionsCollection = class(THtmlCollection)
  protected
    function Matches(Element: TElement): Boolean; override;
  end;

implementation

uses
  SysUtils,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Exceptions,
  Web.Bindings.Context,
  Web.Bindings.FormControls;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

{ NodeList }

function NodeList_item(var Call: TBindingCall): TJsValue;
var
  List: TNodeList;
begin
  List := TNodeList(Call.Target);
  if (Call.Number(0) < 0) or (Call.Number(0) >= List.Length) then
    Exit(JsNull);
  Result := Context(Call).WrapNode(List.Item(Trunc(Call.Number(0))));
end;

function NodeList_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(TNodeList(Call.Target).Length);
end;

{ HTMLCollection }

function HTMLCollection_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(THtmlCollection(Call.Target).Length);
end;

function HTMLCollection_item(var Call: TBindingCall): TJsValue;
var
  Items: THtmlCollection;
begin
  Items := THtmlCollection(Call.Target);
  if (Call.Number(0) < 0) or (Call.Number(0) >= Items.Length) then
    Exit(JsNull);
  Result := Context(Call).WrapNode(Items.Item(Trunc(Call.Number(0))));
end;

function HTMLCollection_namedItem(var Call: TBindingCall): TJsValue;
begin
  if Call.Text(0) = '' then
    Exit(JsNull);
  Result := Context(Call).WrapNode(THtmlCollection(Call.Target).NamedItem(Call.Text(0)));
end;

procedure AddUnique(var Names: TStringArray; var Count: Integer; const Name: string);
var
  Index: Integer;
begin
  if Name = '' then
    Exit;
  for Index := 0 to Count - 1 do
    if Names[Index] = Name then
      Exit;
  if Count >= Length(Names) then
    SetLength(Names, Count * 2 + 8);
  Names[Count] := Name;
  Inc(Count);
end;

function HTMLCollection_supportedNames(var Call: TBindingCall): TJsValue;
var
  Items: THtmlCollection;
  Names: TStringArray;
  Index, Count: Integer;
  Element: TElement;
begin
  Items := THtmlCollection(Call.Target);
  Names := nil;
  Count := 0;
  for Index := 0 to Items.Length - 1 do
  begin
    Element := Items.Item(Index);
    AddUnique(Names, Count, Element.AttributeValueOf(AtomId));
    if Element.IsHtml then
      AddUnique(Names, Count, Element.AttributeValueOf(AtomName));
  end;
  SetLength(Names, Count);
  Result := Context(Call).StringArray(Names);
end;

{ NamedNodeMap }

function ThisMap(const Call: TBindingCall): TNamedNodeMap; inline;
begin
  Result := TNamedNodeMap(Call.Target);
end;

function NamedNodeMap_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisMap(Call).Length);
end;

function NamedNodeMap_item(var Call: TBindingCall): TJsValue;
begin
  if (Call.Number(0) < 0) or (Call.Number(0) >= ThisMap(Call).Length) then
    Exit(JsNull);
  Result := Context(Call).WrapNode(ThisMap(Call).Item(Trunc(Call.Number(0))));
end;

function NamedNodeMap_getNamedItem(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisMap(Call).GetNamedItem(Call.Text(0)));
end;

function NamedNodeMap_getNamedItemNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisMap(Call).GetNamedItemNS(Call.Text(0), Call.Text(1)));
end;

function NamedNodeMap_setNamedItem(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisMap(Call).SetNamedItem(TAttr(Call.Native(0))));
end;

function NamedNodeMap_setNamedItemNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisMap(Call).SetNamedItem(TAttr(Call.Native(0))));
end;

function NamedNodeMap_removeNamedItem(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisMap(Call).RemoveNamedItem(Call.Text(0)));
end;

function NamedNodeMap_removeNamedItemNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisMap(Call).RemoveNamedItemNS(Call.Text(0), Call.Text(1)));
end;

function NamedNodeMap_supportedNames(var Call: TBindingCall): TJsValue;
var
  Names: TStringArray;
  Index, Count: Integer;
begin
  Names := nil;
  Count := 0;
  for Index := 0 to ThisMap(Call).Length - 1 do
    AddUnique(Names, Count, ThisMap(Call).Item(Index).Name);
  SetLength(Names, Count);
  Result := Context(Call).StringArray(Names);
end;

{ DOMTokenList }

function ThisTokens(const Call: TBindingCall): TDomTokenList; inline;
begin
  Result := TDomTokenList(Call.Target);
end;

procedure CheckToken(const Token: string);
var
  Index: Integer;
begin
  if Token = '' then
    RaiseDomError(SyntaxError, 'the token is empty');
  for Index := 1 to Length(Token) do
    if Token[Index] in [#9, #10, #12, #13, ' '] then
      RaiseDomError(InvalidCharacterError, 'the token has white space');
end;

function TokenArguments(const Call: TBindingCall): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Call.Count);
  for Index := 0 to Call.Count - 1 do
  begin
    CheckToken(Call.Arguments[Index].Text);
    Result[Index] := Call.Arguments[Index].Text;
  end;
end;

function DOMTokenList_get_length(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisTokens(Call).Length);
end;

function DOMTokenList_item(var Call: TBindingCall): TJsValue;
begin
  if (Call.Number(0) < 0) or (Call.Number(0) >= ThisTokens(Call).Length) then
    Exit(JsNull);
  Result := Context(Call).TextValue(ThisTokens(Call).Item(Trunc(Call.Number(0))));
end;

function DOMTokenList_contains(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisTokens(Call).Contains(Call.Text(0)));
end;

function DOMTokenList_add(var Call: TBindingCall): TJsValue;
begin
  ThisTokens(Call).Add(TokenArguments(Call));
  Result := JsUndefined;
end;

function DOMTokenList_remove(var Call: TBindingCall): TJsValue;
begin
  ThisTokens(Call).Remove(TokenArguments(Call));
  Result := JsUndefined;
end;

function DOMTokenList_toggle(var Call: TBindingCall): TJsValue;
var
  Force: Integer;
begin
  CheckToken(Call.Text(0));
  if Call.Present(1) then
    Force := Ord(Call.Flag(1))
  else
    Force := -1;
  Result := JsBoolean(ThisTokens(Call).Toggle(Call.Text(0), Force));
end;

function DOMTokenList_replace(var Call: TBindingCall): TJsValue;
begin
  CheckToken(Call.Text(0));
  CheckToken(Call.Text(1));
  Result := JsBoolean(ThisTokens(Call).Replace(Call.Text(0), Call.Text(1)));
end;

{ The supported tokens of rel on link, a and area, and of sandbox (HTML
  4.6.6 and 4.8.5). }
function SupportedTokens(Tokens: TDomTokenList; out List: string): Boolean;
var
  Name, Attribute: string;
begin
  Result := True;
  Name := Tokens.Element.LocalName;
  Attribute := NameOfAtom(Tokens.AttributeName);
  if (Attribute = 'rel') and (Name = 'link') then
    List := ' alternate dns-prefetch expect icon manifest modulepreload next pingback preconnect prefetch preload ' +
      'search stylesheet '
  else if (Attribute = 'rel') and ((Name = 'a') or (Name = 'area') or (Name = 'form')) then
    List := ' noreferrer noopener opener '
  else if (Attribute = 'sandbox') and (Name = 'iframe') then
    List := ' allow-downloads allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups ' +
      'allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts ' +
      'allow-top-navigation allow-top-navigation-by-user-activation allow-top-navigation-to-custom-protocols '
  else
    Result := False;
end;

function DOMTokenList_supports(var Call: TBindingCall): TJsValue;
var
  List: string;
begin
  if not SupportedTokens(ThisTokens(Call), List) then
    raise EBindingTypeError.Create('this token list has no supported tokens');
  Result := JsBoolean(Pos(' ' + LowerCase(Call.Text(0)) + ' ', List) > 0);
end;

function DOMTokenList_get_value(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisTokens(Call).Value);
end;

function DOMTokenList_set_value(var Call: TBindingCall): TJsValue;
begin
  ThisTokens(Call).Value := Call.Text(0);
  Result := JsUndefined;
end;

{ DOMStringMap: data-foo-bar is dataset.fooBar. }

function DataAttributeName(const Name: string): string;
var
  Index: Integer;
begin
  Result := 'data-';
  for Index := 1 to Length(Name) do
  begin
    if (Name[Index] = '-') and (Index < Length(Name)) and (Name[Index + 1] in ['a'..'z']) then
      RaiseDomError(SyntaxError, '''' + Name + ''' has a dash before a lowercase letter');
    if Name[Index] in ['A'..'Z'] then
      Result := Result + '-' + Chr(Ord(Name[Index]) + 32)
    else
      Result := Result + Name[Index];
  end;
end;

function DatasetName(const AttributeName: string): string;
var
  Index: Integer;
begin
  Result := '';
  Index := 6;
  while Index <= Length(AttributeName) do
  begin
    if (AttributeName[Index] = '-') and (Index < Length(AttributeName)) and
      (AttributeName[Index + 1] in ['a'..'z']) then
    begin
      Result := Result + Chr(Ord(AttributeName[Index + 1]) - 32);
      Inc(Index, 2);
      Continue;
    end;
    Result := Result + AttributeName[Index];
    Inc(Index);
  end;
end;

function IsDataAttribute(const Name: string): Boolean;
begin
  Result := (Length(Name) > 5) and (Copy(Name, 1, 5) = 'data-');
end;

function DOMStringMap_namedGetter(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Name: string;
  Atom: TAtom;
begin
  Element := TElement(Call.Target);
  Name := Call.Text(0);
  if Pos('-', Name) > 0 then
  begin
    { A name with a dash before a lowercase letter names nothing. }
    try
      Name := DataAttributeName(Name);
    except
      on EDomException do
        Exit(JsUndefined);
    end;
  end
  else
    Name := DataAttributeName(Name);
  Atom := FindAtom(Name);
  if (Atom = AtomNone) or not Element.HasAttributeAtom(Atom) then
    Exit(JsUndefined);
  Result := Context(Call).TextValue(Element.AttributeValueOf(Atom));
end;

function DOMStringMap_namedSetter(var Call: TBindingCall): TJsValue;
begin
  TElement(Call.Target).SetAttribute(DataAttributeName(Call.Text(0)), Call.Text(1));
  Result := JsUndefined;
end;

function DOMStringMap_namedDeleter(var Call: TBindingCall): TJsValue;
begin
  TElement(Call.Target).RemoveAttribute(DataAttributeName(Call.Text(0)));
  Result := JsUndefined;
end;

function DOMStringMap_supportedNames(var Call: TBindingCall): TJsValue;
var
  Element: TElement;
  Names: TStringArray;
  Index, Count: Integer;
  Attribute: PAttributeRecord;
  Name: string;
begin
  Element := TElement(Call.Target);
  Names := nil;
  Count := 0;
  for Index := 0 to Element.AttributeCount - 1 do
  begin
    Attribute := Element.AttributeAt(Index);
    Name := NameOfAtom(Attribute^.LocalName);
    if (Attribute^.NamespaceId = NamespaceNone) and IsDataAttribute(Name) then
      AddUnique(Names, Count, DatasetName(Name));
  end;
  SetLength(Names, Count);
  Result := Context(Call).StringArray(Names);
end;

{ HTMLOptionsCollection: the collection's root is the select element. }

function TOptionsCollection.Matches(Element: TElement): Boolean;
var
  Parent: TNode;
begin
  if not Element.IsHtmlElement(AtomOption) then
    Exit(False);
  Parent := Element.ParentNode;
  if Parent = Root then
    Exit(True);
  Result := (Parent <> nil) and (Parent.NodeType = NodeTypeElement) and
    TElement(Parent).IsHtmlElement(AtomOptgroup) and (Parent.ParentNode = Root);
end;

function OptionsSelect(const Call: TBindingCall): TElement; inline;
begin
  Result := TElement(TOptionsCollection(Call.Target).Root);
end;

function HTMLOptionsCollection_get_selectedIndex(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(SelectSelectedIndex(Context(Call), OptionsSelect(Call)));
end;

function HTMLOptionsCollection_set_selectedIndex(var Call: TBindingCall): TJsValue;
begin
  SetSelectSelectedIndex(Context(Call), OptionsSelect(Call), Trunc(Call.Number(0)));
  Result := JsUndefined;
end;

function HTMLOptionsCollection_add(var Call: TBindingCall): TJsValue;
var
  Select: TElement;
  Before: TNode;
  Options: TNodeArray;
begin
  Select := OptionsSelect(Call);
  Before := nil;
  if Call.Arguments[1].Kind = bvNative then
    Before := TNode(Call.Native(1))
  else if Call.Arguments[1].Kind = bvNumber then
  begin
    Options := SelectOptions(Select);
    if (Call.Number(1) >= 0) and (Call.Number(1) < Length(Options)) then
      Before := Options[Trunc(Call.Number(1))];
  end;
  if (Before <> nil) and (Before.ParentNode <> nil) then
    Before.ParentNode.InsertBefore(TNode(Call.Native(0)), Before)
  else
    Select.AppendChild(TNode(Call.Native(0)));
  Result := JsUndefined;
end;

function HTMLOptionsCollection_remove(var Call: TBindingCall): TJsValue;
var
  Options: TNodeArray;
begin
  Options := SelectOptions(OptionsSelect(Call));
  if (Call.Number(0) >= 0) and (Call.Number(0) < Length(Options)) then
    Options[Trunc(Call.Number(0))].Remove;
  Result := JsUndefined;
end;

end.
