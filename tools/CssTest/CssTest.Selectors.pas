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
  Selectors: specificity, and matching against a small tree through
  the element adapter (with and without the ancestor bloom filter).
}
unit CssTest.Selectors;

{$mode objfpc}
{$H+}

interface

procedure RunSelectorTests;

implementation

uses
  SysUtils, TestChecks, Css.Atoms, Css.Selectors, Css.SelectorParser, Css.SelectorMatching, Css.BloomFilter,
  Css.ElementAdapter, CssTest.Tree;

procedure CheckSpecificity(const Text: string; A, B, C: Integer);
var
  List: TCssSelectorList;
  Expected: LongWord;
begin
  List := ParseSelectorText(Text);
  try
    Expected := LongWord(A) shl 20 or LongWord(B) shl 10 or LongWord(C);
    Check((List <> nil) and (List.MaxSpecificity = Expected), Format('specificity of %s is (%d,%d,%d)', [Text, A, B, C]));
    if (List <> nil) and (List.MaxSpecificity <> Expected) then
      WriteLn(Format('     got (%d,%d,%d)', [List.MaxSpecificity shr 20, (List.MaxSpecificity shr 10) and 1023,
        List.MaxSpecificity and 1023]));
  finally
    List.Free;
  end;
end;

procedure TestSpecificity;
begin
  CheckSpecificity('*', 0, 0, 0);
  CheckSpecificity('li', 0, 0, 1);
  CheckSpecificity('ul li', 0, 0, 2);
  CheckSpecificity('ul ol+li', 0, 0, 3);
  CheckSpecificity('h1 + *[rel=up]', 0, 1, 1);
  CheckSpecificity('ul ol li.red', 0, 1, 3);
  CheckSpecificity('li.red.level', 0, 2, 1);
  CheckSpecificity('#x34y', 1, 0, 0);
  CheckSpecificity('#s12:not(foo)', 1, 0, 1);
  CheckSpecificity('.foo :is(.bar, #baz)', 1, 1, 0);
  CheckSpecificity(':where(#a, .b) p', 0, 0, 1);
  CheckSpecificity('a::before', 0, 0, 2);
  CheckSpecificity(':nth-child(2n of .a, #b)', 1, 1, 0);
  CheckSpecificity(':has(> .a #b)', 1, 1, 0);
  CheckSpecificity('a:hover', 0, 1, 1);
end;

type
  TMatchFixture = record
    Adapter: TTestAdapter;
    Matcher: TCssSelectorMatcher;
    Root, Body, Main, List, First, Second, Third, Last, Link, Empty, Svg: TTestElement;
  end;

procedure BuildFixture(out Fixture: TMatchFixture);
begin
  Fixture.Adapter := TTestAdapter.Create;
  Fixture.Root := AddElement(nil, 'html', ['lang', 'en-US']);
  Fixture.Body := AddElement(Fixture.Root, 'body', ['dir', 'rtl']);
  Fixture.Main := AddElement(Fixture.Body, 'div', ['id', 'Main', 'class', 'box  big', 'data-x', 'one two',
    'lang', 'fr', 'type', 'TEXT']);
  Fixture.List := AddElement(Fixture.Main, 'ul', ['class', 'list']);
  Fixture.First := AddElement(Fixture.List, 'li', ['class', 'item a']);
  Fixture.Second := AddElement(Fixture.List, 'li', ['class', 'item b', 'title', 'en-gb']);
  Fixture.Third := AddElement(Fixture.List, 'li', ['class', 'item a']);
  Fixture.Last := AddElement(Fixture.List, 'p', []);
  Fixture.Link := AddElement(Fixture.Second, 'a', ['href', 'http://example.org/x.pdf']);
  Fixture.Link.States := [esLink, esHover];
  Fixture.Empty := AddElement(Fixture.Main, 'span', []);
  Fixture.Svg := AddElement(Fixture.Body, 'foreignObject', []);
  Fixture.Svg.LocalName := InternAtom('foreignObject');
  Fixture.Svg.Namespace := InternAtom('http://www.w3.org/2000/svg');
  Fixture.First.HasText := True;
  Fixture.Matcher := TCssSelectorMatcher.Create(Fixture.Adapter);
end;

procedure FreeFixture(var Fixture: TMatchFixture);
begin
  Fixture.Matcher.Free;
  Fixture.Root.Free;
  Fixture.Adapter.Free;
end;

procedure CheckMatch(var Fixture: TMatchFixture; const Text: string; Element: TTestElement; Expected: Boolean;
  const Name: string);
var
  List: TCssSelectorList;
  Matched: Boolean;
  Filter: TCssAncestorFilter;
begin
  List := ParseSelectorText(Text);
  if List = nil then
  begin
    Check(False, 'selector parses: ' + Text);
    Exit;
  end;
  try
    Matched := Fixture.Matcher.MatchesList(List, Element);
    Check(Matched = Expected, Text + ' on ' + Name);
    { The same with the ancestor filter set up for the element. }
    Filter := TCssAncestorFilter.Create;
    try
      Filter.SetUpFor(Fixture.Adapter, Element);
      Fixture.Matcher.Filter := Filter;
      Matched := (List.Count > 0) and Fixture.Matcher.Matches(List.Items[0], Element);
      Fixture.Matcher.Filter := nil;
      if List.Count = 1 then
        Check(Matched = Expected, Text + ' on ' + Name + ' with the bloom filter');
    finally
      Filter.Free;
    end;
  finally
    List.Free;
  end;
end;

procedure TestMatching;
var
  F: TMatchFixture;
  List: TCssSelectorList;
  Filter: TCssAncestorFilter;
begin
  BuildFixture(F);
  try
    CheckMatch(F, 'li', F.First, True, 'first li');
    CheckMatch(F, 'LI', F.First, True, 'first li (type case)');
    CheckMatch(F, 'foreignobject', F.Svg, False, 'svg element (case-sensitive)');
    CheckMatch(F, 'foreignObject', F.Svg, True, 'svg element');
    CheckMatch(F, '#Main', F.Main, True, 'main');
    CheckMatch(F, '#main', F.Main, False, 'main (id case)');
    CheckMatch(F, '.box.big', F.Main, True, 'main');
    CheckMatch(F, 'div > ul > li.a', F.Third, True, 'third li');
    CheckMatch(F, 'body li', F.First, True, 'first li');
    CheckMatch(F, 'html > li', F.First, False, 'first li');
    CheckMatch(F, '.box li + li', F.Second, True, 'second li');
    CheckMatch(F, 'li + li', F.First, False, 'first li');
    CheckMatch(F, '.a ~ .a', F.Third, True, 'third li');
    CheckMatch(F, '.a ~ .b', F.Second, True, 'second li');
    CheckMatch(F, '.b ~ .a ~ p', F.Last, True, 'p');
    CheckMatch(F, 'div li a', F.Link, True, 'link');
    CheckMatch(F, 'ul > a', F.Link, False, 'link');
    CheckMatch(F, '[data-x]', F.Main, True, 'main');
    CheckMatch(F, '[data-x~=two]', F.Main, True, 'main');
    CheckMatch(F, '[data-x~="one two"]', F.Main, False, 'main');
    CheckMatch(F, '[title|=en]', F.Second, True, 'second li');
    CheckMatch(F, '[href^=http][href$=".pdf"][href*=example]', F.Link, True, 'link');
    CheckMatch(F, '[href$=".PDF"]', F.Link, False, 'link');
    CheckMatch(F, '[href$=".PDF" i]', F.Link, True, 'link');
    CheckMatch(F, '[type=text]', F.Main, True, 'main (type value is case-insensitive in HTML)');
    CheckMatch(F, '[type=text s]', F.Main, False, 'main');
    CheckMatch(F, '[*|data-x]', F.Main, True, 'main');
    CheckMatch(F, ':first-child', F.First, True, 'first li');
    CheckMatch(F, ':last-child', F.Last, True, 'p');
    CheckMatch(F, 'li:last-of-type', F.Third, True, 'third li');
    CheckMatch(F, ':only-of-type', F.Last, True, 'p');
    CheckMatch(F, ':nth-child(2)', F.Second, True, 'second li');
    CheckMatch(F, ':nth-child(odd)', F.Third, True, 'third li');
    CheckMatch(F, ':nth-child(-n+2)', F.Third, False, 'third li');
    CheckMatch(F, ':nth-last-child(2)', F.Third, True, 'third li');
    CheckMatch(F, ':nth-of-type(3)', F.Third, True, 'third li');
    CheckMatch(F, ':nth-child(2 of .a)', F.Third, True, 'third li');
    CheckMatch(F, ':nth-child(1 of .b)', F.Second, True, 'second li');
    CheckMatch(F, ':root', F.Root, True, 'html');
    CheckMatch(F, ':root', F.Body, False, 'body');
    CheckMatch(F, ':empty', F.Empty, True, 'span');
    CheckMatch(F, ':empty', F.First, False, 'first li (it has text)');
    CheckMatch(F, ':is(ul, ol) > li:not(.b)', F.First, True, 'first li');
    CheckMatch(F, ':is(ul, ol) > li:not(.b)', F.Second, False, 'second li');
    CheckMatch(F, ':where(.list) li', F.First, True, 'first li');
    CheckMatch(F, ':not(.a, .b)', F.Last, True, 'p');
    CheckMatch(F, 'ul:has(> li.b)', F.List, True, 'list');
    CheckMatch(F, 'ul:has(a[href])', F.List, True, 'list');
    CheckMatch(F, 'ul:has(> a)', F.List, False, 'list');
    CheckMatch(F, 'li:has(+ li.b)', F.First, True, 'first li');
    CheckMatch(F, 'li:has(~ p)', F.Second, True, 'second li');
    CheckMatch(F, 'div:has(.b a)', F.Main, True, 'main');
    CheckMatch(F, 'a:hover', F.Link, True, 'link');
    CheckMatch(F, ':link:not(:visited)', F.Link, True, 'link');
    CheckMatch(F, ':any-link', F.Link, True, 'link');
    CheckMatch(F, ':focus', F.Link, False, 'link');
    CheckMatch(F, ':lang(fr)', F.First, True, 'first li (inherits the language)');
    CheckMatch(F, ':lang(en)', F.Body, True, 'body');
    CheckMatch(F, ':lang("*-US")', F.Body, True, 'body');
    CheckMatch(F, ':dir(rtl)', F.First, True, 'first li');
    CheckMatch(F, ':dir(ltr)', F.Root, True, 'html');
    CheckMatch(F, '&', F.Root, True, 'html (top-level nesting selector is :scope)');
    CheckMatch(F, ':scope > body', F.Body, True, 'body');
    { Pseudo-elements match only when asked for. }
    List := ParseSelectorText('li::before');
    try
      Check(not F.Matcher.Matches(List.Items[0], F.First), 'li::before does not match the li itself');
      Check(F.Matcher.Matches(List.Items[0], F.First, peBefore), 'li::before matches the li''s ::before');
    finally
      List.Free;
    end;
    { The bloom filter rejects without walking. }
    List := ParseSelectorText('table td');
    Filter := TCssAncestorFilter.Create;
    try
      Filter.SetUpFor(F.Adapter, F.First);
      F.Matcher.Filter := Filter;
      Check(not F.Matcher.PassesFilter(List.Items[0]), 'the bloom filter rejects "table td" under ul');
      List.Free;
      List := ParseSelectorText('.box .list li');
      Check(F.Matcher.PassesFilter(List.Items[0]), 'the bloom filter passes ".box .list li"');
      F.Matcher.Filter := nil;
    finally
      Filter.Free;
      List.Free;
    end;
    { Quirks mode: class and id selectors ignore ASCII case. }
    F.Adapter.Quirks := qmQuirks;
    F.Matcher.Refresh;
    CheckMatch(F, '#main.BOX', F.Main, True, 'main in quirks mode');
    F.Adapter.Quirks := qmNoQuirks;
    F.Matcher.Refresh;
  finally
    FreeFixture(F);
  end;
end;

procedure RunSelectorTests;
begin
  TestSpecificity;
  TestMatching;
end;

end.
