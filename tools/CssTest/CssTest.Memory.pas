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
  Styles a synthetic page (a few thousand elements under the user
  agent sheet and a typical author sheet) and reports the memory per
  computed style and how much is shared.
}
unit CssTest.Memory;

{$mode objfpc}
{$H+}

interface

procedure RunMemoryTests;

implementation

uses
  SysUtils, DateUtils, TestChecks, Css.Atoms, Css.Values, Css.Stylesheets, Css.Parser, Css.ElementAdapter,
  Css.StyleStructs, Css.ComputedStyle, Css.StyleEngine, Css.RuleIndex, CssTest.Tree;

const
  AuthorSheet =
    ':root { --accent: #336699; --gap: 8px; font-family: system-ui, sans-serif; }'#10 +
    'body { margin: 0; line-height: 1.4; color: #222; }'#10 +
    'header.site { display: flex; gap: var(--gap); padding: 1rem; background: var(--accent); color: white; }'#10 +
    'nav a { color: inherit; text-decoration: none; padding: 0 0.5em; }'#10 +
    'nav a:hover { text-decoration: underline; }'#10 +
    'main { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 1em; }'#10 +
    'section { padding: var(--gap); border-bottom: 1px solid #ddd; }'#10 +
    'section > h2 { font-size: 1.25rem; margin: 0 0 0.5em; color: var(--accent); }'#10 +
    'article.card { border: 1px solid #ccc; border-radius: 6px; padding: 12px; box-shadow: 0 1px 2px rgba(0,0,0,.1); }'#10 +
    'article.card:nth-child(odd) { background: #fafafa; }'#10 +
    'article.card.featured { border-color: var(--accent); }'#10 +
    '.card p { margin: 0.5em 0; }'#10 +
    '.card p:first-of-type { font-weight: 600; }'#10 +
    '.card .meta { font-size: 0.85em; color: #666; }'#10 +
    '.card a.more { color: var(--accent); }'#10 +
    'ul.tags { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: 4px; }'#10 +
    'ul.tags li { padding: 2px 6px; background: #eef; border-radius: 3px; font-size: 0.8em; }'#10 +
    '@media (max-width: 600px) { main { grid-template-columns: 1fr; } }'#10 +
    'footer { padding: 2em; text-align: center; font-size: small; }';

function BuildPage(out Count: Integer): TTestElement;
var
  Html, Body, Header, Nav, Main, Section, Article, Tags, Footer: TTestElement;
  SectionIndex, ArticleIndex, Index: Integer;
  Classes: string;
begin
  Html := AddElement(nil, 'html', ['lang', 'en']);
  AddElement(AddElement(Html, 'head', []), 'title', []);
  Body := AddElement(Html, 'body', []);
  Header := AddElement(Body, 'header', ['class', 'site']);
  Nav := AddElement(Header, 'nav', []);
  for Index := 1 to 6 do
    AddElement(Nav, 'a', ['href', '#' + IntToStr(Index)]).States := [esLink];
  Main := AddElement(Body, 'main', []);
  for SectionIndex := 1 to 12 do
  begin
    Section := AddElement(Main, 'section', ['id', 's' + IntToStr(SectionIndex)]);
    AddElement(Section, 'h2', []);
    for ArticleIndex := 1 to 12 do
    begin
      Classes := 'card';
      if ArticleIndex mod 5 = 0 then
        Classes := 'card featured';
      Article := AddElement(Section, 'article', ['class', Classes]);
      AddElement(Article, 'h3', []);
      AddElement(Article, 'p', []);
      AddElement(Article, 'p', []);
      AddElement(Article, 'p', ['class', 'meta']);
      AddElement(AddElement(Article, 'p', []), 'a', ['class', 'more', 'href', 'x']).States := [esLink];
      Tags := AddElement(Article, 'ul', ['class', 'tags']);
      for Index := 1 to 4 do
        AddElement(Tags, 'li', []);
    end;
  end;
  Footer := AddElement(Body, 'footer', []);
  AddElement(Footer, 'small', []);
  Count := CountElements(Html);
  Result := Html;
end;

procedure KeepStyle(Element: TCssElement; Style: TCssComputedStyle; Data: Pointer);
begin
  TTestElement(Element).Style.Release;
  TTestElement(Element).Style := Style.AddRef;
end;

procedure RunMemoryTests;
var
  Adapter: TTestAdapter;
  Engine: TCssStyleEngine;
  Sheet: TCssStyleSheet;
  Root: TTestElement;
  Count, Index, Collected: Integer;
  Elements: array of TTestElement;
  Styles: array of TCssComputedStyle;
  Report: TCssMemoryReport;
  Started: TDateTime;
  Milliseconds: Int64;
  Statistics: TCssStyleStatistics;
begin
  Adapter := TTestAdapter.Create;
  Engine := TCssStyleEngine.Create(Adapter);
  Sheet := ParseStyleSheet(AuthorSheet, coAuthor);
  Engine.AddStyleSheet(Sheet);
  Root := BuildPage(Count);
  try
    Started := Now;
    Engine.StyleTree(Root, nil, @KeepStyle, nil);
    Milliseconds := MilliSecondsBetween(Now, Started);
    SetLength(Elements, Count);
    Collected := 0;
    CollectElements(Root, Elements, Collected);
    SetLength(Styles, Count);
    for Index := 0 to Count - 1 do
      Styles[Index] := Elements[Index].Style;
    Report := Engine.MemoryReport(Count, Styles);
    Statistics := Engine.Statistics;
    WriteLn(Format('info synthetic page: %d elements styled in %d ms (%d rules indexed)',
      [Count, Milliseconds, Engine.Rules.Count]));
    WriteLn(Format('info %d distinct computed styles (%.1f elements per style); %d shared without cascading',
      [Report.UniqueStyles, Report.StyleSharingRatio, Statistics.SharedStyles]));
    WriteLn(Format('info %d distinct style structs, each used by %.1f styles on average; %d interned',
      [Report.LiveStructs, Report.StructSharingRatio, Engine.StructCache.Count]));
    WriteLn(Format('info %.1f bytes of computed style per element (%d bytes for a style with nothing shared)',
      [Report.BytesPerElement, Report.UnsharedBytesPerStyle]));
    WriteLn(Format('info selectors tested %d, matched %d, rejected by the bloom filter %d',
      [Statistics.SelectorsTested, Statistics.SelectorsMatched, Statistics.FilterRejections]));
    Check(Collected = Count, 'every element was collected');
    Check(Report.StyleSharingRatio > 10, 'elements share computed styles (more than 10 per style)');
    Check(Report.StructSharingRatio > 3, 'styles share structs (more than 3 per struct)');
    Check(Report.BytesPerElement < 200, 'less than 200 bytes of computed style per element');
    Check(Statistics.FilterRejections > 0, 'the bloom filter rejects selectors');
    Check(Elements[Count - 2].Style.FontSize = 13, 'the footer''s font-size: small is 13px');
    Check(Abs(Elements[Count - 1].Style.FontSize - 13 / 1.2) < 1E-3, 'small is smaller than the footer');
  finally
    Root.Free;
    Engine.Free;
    Sheet.Free;
    Adapter.Free;
  end;
  Check(LiveStyleCount = 0, 'no computed style outlives the engine and the tree');
  Check(LiveStructCount = 0, 'no style struct outlives the engine and the tree');
end;

end.
