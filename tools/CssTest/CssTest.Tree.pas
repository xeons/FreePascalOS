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
  A small element tree for the libcss tests, and the element adapter
  that shows it to the style engine (what libweb does for its DOM).
}
unit CssTest.Tree;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Declarations, Css.ElementAdapter, Css.ComputedStyle;

const
  HtmlNamespace = 'http://www.w3.org/1999/xhtml';

type
  TTestElement = class
  public
    LocalName: TCssAtom;
    Namespace: TCssAtom;
    Id: TCssAtom;
    Classes: array of TCssAtom;
    AttributeNames: array of TCssAtom;
    AttributeValues: array of string;
    Parent: TTestElement;
    Children: array of TTestElement;
    Index: Integer;
    States: TCssElementStates;
    Language: string;
    HasText: Boolean;
    StyleAttribute: TCssDeclarationBlock;
    Style: TCssComputedStyle;
    destructor Destroy; override;
    function Child(Position: Integer): TTestElement;
    function Attribute(const Name: string): string;
  end;

  TTestAdapter = class(TCssElementAdapter)
  public
    Quirks: TCssQuirksMode;
    function LocalName(Element: TCssElement): TCssAtom; override;
    function NamespaceUri(Element: TCssElement): TCssAtom; override;
    function IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean; override;
    function Id(Element: TCssElement): TCssAtom; override;
    function ClassCount(Element: TCssElement): Integer; override;
    function ClassAt(Element: TCssElement; Index: Integer): TCssAtom; override;
    function FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom; out Value: string): Boolean; override;
    function AttributeCount(Element: TCssElement): Integer; override;
    procedure AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace, AttributeName: TCssAtom;
      out Value: string); override;
    function Parent(Element: TCssElement): TCssElement; override;
    function PreviousSibling(Element: TCssElement): TCssElement; override;
    function NextSibling(Element: TCssElement): TCssElement; override;
    function FirstChild(Element: TCssElement): TCssElement; override;
    function LastChild(Element: TCssElement): TCssElement; override;
    function IsEmpty(Element: TCssElement): Boolean; override;
    function States(Element: TCssElement): TCssElementStates; override;
    function Language(Element: TCssElement): string; override;
    function Direction(Element: TCssElement): TCssDirection; override;
    function QuirksMode: TCssQuirksMode; override;
    function StyleAttribute(Element: TCssElement): TCssDeclarationBlock; override;
  end;

{ A new element under Parent (nil for the root); Attributes are name,
  value pairs (id, class and style are understood). }
function AddElement(Parent: TTestElement; const Name: string; const Attributes: array of string): TTestElement;
{ Every element of the tree in document order. }
procedure CollectElements(Root: TTestElement; var List: array of TTestElement; var Count: Integer);
function CountElements(Root: TTestElement): Integer;

implementation

uses
  SysUtils, Css.Parser;

destructor TTestElement.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to High(Children) do
    Children[Position].Free;
  StyleAttribute.Free;
  Style.Release;
  inherited Destroy;
end;

function TTestElement.Child(Position: Integer): TTestElement;
begin
  Result := Children[Position];
end;

function TTestElement.Attribute(const Name: string): string;
var
  Position: Integer;
  Atom: TCssAtom;
begin
  Atom := InternAtom(Name);
  for Position := 0 to High(AttributeNames) do
    if AttributeNames[Position] = Atom then
      Exit(AttributeValues[Position]);
  Result := '';
end;

function AddElement(Parent: TTestElement; const Name: string; const Attributes: array of string): TTestElement;
var
  Position, ClassIndex: Integer;
  AttributeName, Value: string;
  Words: TStringArray;
begin
  Result := TTestElement.Create;
  Result.LocalName := InternAtom(LowerCase(Name));
  Result.Namespace := InternAtom(HtmlNamespace);
  Result.Parent := Parent;
  if Parent <> nil then
  begin
    Result.Index := Length(Parent.Children);
    SetLength(Parent.Children, Result.Index + 1);
    Parent.Children[Result.Index] := Result;
  end;
  Position := 0;
  while Position + 1 <= High(Attributes) do
  begin
    AttributeName := LowerCase(Attributes[Position]);
    Value := Attributes[Position + 1];
    SetLength(Result.AttributeNames, Length(Result.AttributeNames) + 1);
    SetLength(Result.AttributeValues, Length(Result.AttributeValues) + 1);
    Result.AttributeNames[High(Result.AttributeNames)] := InternAtom(AttributeName);
    Result.AttributeValues[High(Result.AttributeValues)] := Value;
    if AttributeName = 'id' then
      Result.Id := InternAtom(Value)
    else if AttributeName = 'class' then
    begin
      Words := Value.Split([' '], TStringSplitOptions.ExcludeEmpty);
      SetLength(Result.Classes, Length(Words));
      for ClassIndex := 0 to High(Words) do
        Result.Classes[ClassIndex] := InternAtom(Words[ClassIndex]);
    end
    else if AttributeName = 'style' then
      Result.StyleAttribute := ParseStyleAttribute(Value)
    else if AttributeName = 'lang' then
      Result.Language := Value;
    Inc(Position, 2);
  end;
end;

procedure CollectElements(Root: TTestElement; var List: array of TTestElement; var Count: Integer);
var
  Position: Integer;
begin
  List[Count] := Root;
  Inc(Count);
  for Position := 0 to High(Root.Children) do
    CollectElements(Root.Children[Position], List, Count);
end;

function CountElements(Root: TTestElement): Integer;
var
  Position: Integer;
begin
  Result := 1;
  for Position := 0 to High(Root.Children) do
    Inc(Result, CountElements(Root.Children[Position]));
end;

function AsElement(Element: TCssElement): TTestElement; inline;
begin
  Result := TTestElement(Element);
end;

function TTestAdapter.LocalName(Element: TCssElement): TCssAtom;
begin
  Result := AsElement(Element).LocalName;
end;

function TTestAdapter.NamespaceUri(Element: TCssElement): TCssAtom;
begin
  Result := AsElement(Element).Namespace;
end;

function TTestAdapter.IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean;
begin
  Result := AsElement(Element).Namespace = InternAtom(HtmlNamespace);
end;

function TTestAdapter.Id(Element: TCssElement): TCssAtom;
begin
  Result := AsElement(Element).Id;
end;

function TTestAdapter.ClassCount(Element: TCssElement): Integer;
begin
  Result := Length(AsElement(Element).Classes);
end;

function TTestAdapter.ClassAt(Element: TCssElement; Index: Integer): TCssAtom;
begin
  Result := AsElement(Element).Classes[Index];
end;

function TTestAdapter.FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom; out Value: string): Boolean;
var
  Position: Integer;
  Item: TTestElement;
begin
  Item := AsElement(Element);
  Value := '';
  if AttributeNamespace <> NoAtom then
    Exit(False);
  for Position := 0 to High(Item.AttributeNames) do
    if Item.AttributeNames[Position] = AttributeName then
    begin
      Value := Item.AttributeValues[Position];
      Exit(True);
    end;
  Result := False;
end;

function TTestAdapter.AttributeCount(Element: TCssElement): Integer;
begin
  Result := Length(AsElement(Element).AttributeNames);
end;

procedure TTestAdapter.AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace, AttributeName: TCssAtom;
  out Value: string);
begin
  AttributeNamespace := NoAtom;
  AttributeName := AsElement(Element).AttributeNames[Index];
  Value := AsElement(Element).AttributeValues[Index];
end;

function TTestAdapter.Parent(Element: TCssElement): TCssElement;
begin
  Result := AsElement(Element).Parent;
end;

function TTestAdapter.PreviousSibling(Element: TCssElement): TCssElement;
var
  Item: TTestElement;
begin
  Item := AsElement(Element);
  if (Item.Parent = nil) or (Item.Index = 0) then
    Result := nil
  else
    Result := Item.Parent.Children[Item.Index - 1];
end;

function TTestAdapter.NextSibling(Element: TCssElement): TCssElement;
var
  Item: TTestElement;
begin
  Item := AsElement(Element);
  if (Item.Parent = nil) or (Item.Index >= High(Item.Parent.Children)) then
    Result := nil
  else
    Result := Item.Parent.Children[Item.Index + 1];
end;

function TTestAdapter.FirstChild(Element: TCssElement): TCssElement;
var
  Item: TTestElement;
begin
  Item := AsElement(Element);
  if Length(Item.Children) = 0 then
    Result := nil
  else
    Result := Item.Children[0];
end;

function TTestAdapter.LastChild(Element: TCssElement): TCssElement;
var
  Item: TTestElement;
begin
  Item := AsElement(Element);
  if Length(Item.Children) = 0 then
    Result := nil
  else
    Result := Item.Children[High(Item.Children)];
end;

function TTestAdapter.IsEmpty(Element: TCssElement): Boolean;
begin
  Result := (Length(AsElement(Element).Children) = 0) and not AsElement(Element).HasText;
end;

function TTestAdapter.States(Element: TCssElement): TCssElementStates;
begin
  Result := AsElement(Element).States;
end;

function TTestAdapter.Language(Element: TCssElement): string;
var
  Item: TTestElement;
begin
  Item := AsElement(Element);
  while Item <> nil do
  begin
    if Item.Language <> '' then
      Exit(Item.Language);
    Item := Item.Parent;
  end;
  Result := '';
end;

function TTestAdapter.Direction(Element: TCssElement): TCssDirection;
var
  Item: TTestElement;
  Value: string;
begin
  Item := AsElement(Element);
  while Item <> nil do
  begin
    Value := LowerCase(Item.Attribute('dir'));
    if Value = 'rtl' then
      Exit(dirRightToLeft);
    if Value = 'ltr' then
      Exit(dirLeftToRight);
    Item := Item.Parent;
  end;
  Result := dirLeftToRight;
end;

function TTestAdapter.QuirksMode: TCssQuirksMode;
begin
  Result := Quirks;
end;

function TTestAdapter.StyleAttribute(Element: TCssElement): TCssDeclarationBlock;
begin
  Result := AsElement(Element).StyleAttribute;
end;

end.
