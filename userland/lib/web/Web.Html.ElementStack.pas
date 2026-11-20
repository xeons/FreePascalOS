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
  The stack of open elements. Index 0 is the first (top) element, the
  html element; the last is the current node. The "has an element in
  scope" checks walk from the current node up to a scope boundary.
}
unit Web.Html.ElementStack;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms,
  Web.Dom,
  Web.Html.ElementKinds;

type
  TElementStack = class
  private
    FItems: TElementArray;
    FCount: Integer;
    function GetItem(Index: Integer): TElement; inline;
  public
    procedure Push(Element: TElement);
    function Pop: TElement;
    function Current: TElement; inline;
    function IndexOf(Element: TElement): Integer;
    function Contains(Element: TElement): Boolean; inline;
    procedure RemoveAt(Index: Integer);
    procedure Remove(Element: TElement);
    procedure InsertAt(Index: Integer; Element: TElement);
    procedure Replace(OldElement, NewElement: TElement);
    procedure Clear;
    { The last (closest to the current node) HTML element named Name. }
    function LastIndexOfHtml(Name: TAtom): Integer;
    function ContainsHtml(Name: TAtom): Boolean;
    function HasInScope(Name: TAtom; Scope: TScope): Boolean;
    function HasElementInScope(Element: TElement; Scope: TScope): Boolean;
    function HasHeadingInScope: Boolean;
    { Pops until an HTML element named Name has been popped. }
    procedure PopUntilHtml(Name: TAtom);
    procedure PopUntilHeading;
    procedure PopUntilElement(Element: TElement);
    { Pops while the current node is not one of the HTML names. }
    procedure PopUntilCurrentIsOneOf(const Names: array of TAtom);
    property Count: Integer read FCount;
    property Items[Index: Integer]: TElement read GetItem; default;
  end;

implementation

function TElementStack.GetItem(Index: Integer): TElement;
begin
  Result := FItems[Index];
end;

procedure TElementStack.Push(Element: TElement);
begin
  if FCount >= Length(FItems) then
    SetLength(FItems, FCount * 2 + 16);
  FItems[FCount] := Element;
  Inc(FCount);
end;

function TElementStack.Pop: TElement;
begin
  Dec(FCount);
  Result := FItems[FCount];
  FItems[FCount] := nil;
end;

function TElementStack.Current: TElement;
begin
  if FCount = 0 then
    Result := nil
  else
    Result := FItems[FCount - 1];
end;

function TElementStack.IndexOf(Element: TElement): Integer;
begin
  Result := FCount - 1;
  while (Result >= 0) and (FItems[Result] <> Element) do
    Dec(Result);
end;

function TElementStack.Contains(Element: TElement): Boolean;
begin
  Result := IndexOf(Element) >= 0;
end;

procedure TElementStack.RemoveAt(Index: Integer);
var
  Position: Integer;
begin
  for Position := Index + 1 to FCount - 1 do
    FItems[Position - 1] := FItems[Position];
  Dec(FCount);
  FItems[FCount] := nil;
end;

procedure TElementStack.Remove(Element: TElement);
var
  Index: Integer;
begin
  Index := IndexOf(Element);
  if Index >= 0 then
    RemoveAt(Index);
end;

procedure TElementStack.InsertAt(Index: Integer; Element: TElement);
var
  Position: Integer;
begin
  Push(nil);
  Position := FCount - 1;
  while Position > Index do
  begin
    FItems[Position] := FItems[Position - 1];
    Dec(Position);
  end;
  FItems[Index] := Element;
end;

procedure TElementStack.Replace(OldElement, NewElement: TElement);
var
  Index: Integer;
begin
  Index := IndexOf(OldElement);
  if Index >= 0 then
    FItems[Index] := NewElement;
end;

procedure TElementStack.Clear;
begin
  while FCount > 0 do
    Pop;
end;

function TElementStack.LastIndexOfHtml(Name: TAtom): Integer;
begin
  Result := FCount - 1;
  while (Result >= 0) and not FItems[Result].IsHtmlElement(Name) do
    Dec(Result);
end;

function TElementStack.ContainsHtml(Name: TAtom): Boolean;
begin
  Result := LastIndexOfHtml(Name) >= 0;
end;

function TElementStack.HasInScope(Name: TAtom; Scope: TScope): Boolean;
var
  Index: Integer;
  Node: TElement;
begin
  Index := FCount - 1;
  while Index >= 0 do
  begin
    Node := FItems[Index];
    if Node.IsHtmlElement(Name) then
      Exit(True);
    if IsScopeBoundary(Node, Scope) then
      Exit(False);
    Dec(Index);
  end;
  Result := False;
end;

function TElementStack.HasElementInScope(Element: TElement; Scope: TScope): Boolean;
var
  Index: Integer;
  Node: TElement;
begin
  Index := FCount - 1;
  while Index >= 0 do
  begin
    Node := FItems[Index];
    if Node = Element then
      Exit(True);
    if IsScopeBoundary(Node, Scope) then
      Exit(False);
    Dec(Index);
  end;
  Result := False;
end;

function TElementStack.HasHeadingInScope: Boolean;
var
  Index: Integer;
  Node: TElement;
begin
  Index := FCount - 1;
  while Index >= 0 do
  begin
    Node := FItems[Index];
    if Node.IsHtml and IsHeadingName(Node.LocalNameAtom) then
      Exit(True);
    if IsScopeBoundary(Node, ScopeDefault) then
      Exit(False);
    Dec(Index);
  end;
  Result := False;
end;

procedure TElementStack.PopUntilHtml(Name: TAtom);
begin
  while FCount > 0 do
    if Pop.IsHtmlElement(Name) then
      Exit;
end;

procedure TElementStack.PopUntilHeading;
var
  Node: TElement;
begin
  while FCount > 0 do
  begin
    Node := Pop;
    if Node.IsHtml and IsHeadingName(Node.LocalNameAtom) then
      Exit;
  end;
end;

procedure TElementStack.PopUntilElement(Element: TElement);
begin
  while FCount > 0 do
    if Pop = Element then
      Exit;
end;

procedure TElementStack.PopUntilCurrentIsOneOf(const Names: array of TAtom);
var
  Index: Integer;
  Node: TElement;
begin
  while FCount > 0 do
  begin
    Node := Current;
    if Node.IsHtml then
      for Index := 0 to High(Names) do
        if Node.LocalNameAtom = Names[Index] then
          Exit;
    Pop;
  end;
end;

end.
