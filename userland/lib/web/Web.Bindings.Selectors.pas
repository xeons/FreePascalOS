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
  Selectors from script (DOM Standard "scope-match a selectors string"):
  querySelector, querySelectorAll, matches and closest with libcss's
  selector parser and matcher over the style system's element adapter
  (Web.Style.Adapter), so script sees the same states as styling: the
  ones the DOM knows (link, checked, disabled, required, ...) and the
  ones the web view sets (hover, active, focus, focus-visible,
  focus-within).
  Parsed selector lists are cached by their text (a few recent ones).
}
unit Web.Bindings.Selectors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.Selectors,
  Css.SelectorParser,
  Css.SelectorMatching,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Dom.Exceptions;

function QuerySelector(Root: TNode; const Selectors: string): TElement;
function QuerySelectorAll(Root: TNode; const Selectors: string): TNodeArray;
function ElementMatches(Element: TElement; const Selectors: string): Boolean;
function ElementClosest(Element: TElement; const Selectors: string): TElement;

implementation

uses
  Web.Style.Adapter;

var
  CachedTexts: array[0..15] of string;
  CachedLists: array[0..15] of TCssSelectorList;
  NextCacheSlot: Integer;

function ParsedSelectors(const Text: string): TCssSelectorList;
var
  Index: Integer;
begin
  for Index := 0 to High(CachedTexts) do
    if (CachedLists[Index] <> nil) and (CachedTexts[Index] = Text) then
      Exit(CachedLists[Index]);
  Result := ParseSelectorText(Text);
  if Result = nil then
    RaiseDomError(SyntaxError, '''' + Text + ''' is not a valid selector');
  CachedLists[NextCacheSlot].Free;
  CachedLists[NextCacheSlot] := Result;
  CachedTexts[NextCacheSlot] := Text;
  NextCacheSlot := (NextCacheSlot + 1) mod Length(CachedTexts);
end;

type
  TQuery = record
    Adapter: TDomElementAdapter;
    Matcher: TCssSelectorMatcher;
    List: TCssSelectorList;
  end;

procedure StartQuery(out Query: TQuery; Scope: TNode; const Selectors: string);
begin
  Query.List := ParsedSelectors(Selectors);
  Query.Adapter := TDomElementAdapter.Create(Scope.NodeDocument);
  Query.Matcher := TCssSelectorMatcher.Create(Query.Adapter);
  if Scope.NodeType = NodeTypeElement then
    Query.Matcher.Scope := Scope
  else
    Query.Matcher.Scope := nil;
end;

procedure FinishQuery(var Query: TQuery);
begin
  Query.Matcher.Free;
  Query.Adapter.Free;
end;

function QuerySelector(Root: TNode; const Selectors: string): TElement;
var
  Query: TQuery;
  Node: TNode;
begin
  Result := nil;
  StartQuery(Query, Root, Selectors);
  try
    Node := Root.FirstChild;
    while Node <> nil do
    begin
      if (Node.NodeType = NodeTypeElement) and Query.Matcher.MatchesList(Query.List, Node) then
        Exit(TElement(Node));
      Node := Node.NextInTree(Root);
    end;
  finally
    FinishQuery(Query);
  end;
end;

function QuerySelectorAll(Root: TNode; const Selectors: string): TNodeArray;
var
  Query: TQuery;
  Node: TNode;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  StartQuery(Query, Root, Selectors);
  try
    Node := Root.FirstChild;
    while Node <> nil do
    begin
      if (Node.NodeType = NodeTypeElement) and Query.Matcher.MatchesList(Query.List, Node) then
      begin
        if Count >= Length(Result) then
          SetLength(Result, Count * 2 + 8);
        Result[Count] := Node;
        Inc(Count);
      end;
      Node := Node.NextInTree(Root);
    end;
  finally
    FinishQuery(Query);
  end;
  SetLength(Result, Count);
end;

function ElementMatches(Element: TElement; const Selectors: string): Boolean;
var
  Query: TQuery;
begin
  StartQuery(Query, Element, Selectors);
  try
    Result := Query.Matcher.MatchesList(Query.List, Element);
  finally
    FinishQuery(Query);
  end;
end;

function ElementClosest(Element: TElement; const Selectors: string): TElement;
var
  Query: TQuery;
begin
  StartQuery(Query, Element, Selectors);
  try
    Result := Element;
    while Result <> nil do
    begin
      if Query.Matcher.MatchesList(Query.List, Result) then
        Exit;
      Result := Result.ParentElement;
    end;
  finally
    FinishQuery(Query);
  end;
end;

procedure FreeCache;
var
  Index: Integer;
begin
  for Index := 0 to High(CachedLists) do
    FreeAndNil(CachedLists[Index]);
end;

finalization
  FreeCache;
end.
