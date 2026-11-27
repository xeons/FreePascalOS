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
  The cascade and computed values through the style engine: origins,
  !important, layers, inline styles, revert, inheritance, em, rem,
  percentages, calc(), var(), media queries and colors.
}
unit CssTest.Cascade;

{$mode objfpc}
{$H+}

interface

procedure RunCascadeTests;

implementation

uses
  SysUtils, Math, TestChecks, Css.Atoms, Css.Keywords, Css.Tokens, Css.Tokenizer, Css.Colors, Css.ColorParser,
  Css.Values, Css.PropertyIds, Css.Properties, Css.Stylesheets, Css.Parser, Css.MediaQueries,
  Css.ElementAdapter, Css.ComputedValues, Css.ComputedStyle, Css.StyleEngine, Css.Supports, Css.Selectors,
  Css.CustomProperties, Css.Serialization, Css.NameInvalidation, CssTest.Tree;

type
  TStyler = record
    Adapter: TTestAdapter;
    Engine: TCssStyleEngine;
    Sheets: array of TCssStyleSheet;
    Root: TTestElement;
  end;

procedure KeepStyle(Element: TCssElement; Style: TCssComputedStyle; Data: Pointer);
begin
  TTestElement(Element).Style.Release;
  TTestElement(Element).Style := Style.AddRef;
end;

procedure StartStyler(out Styler: TStyler; UserAgent: Boolean);
begin
  Styler.Adapter := TTestAdapter.Create;
  Styler.Engine := TCssStyleEngine.Create(Styler.Adapter, UserAgent);
  Styler.Sheets := nil;
  Styler.Root := nil;
end;

procedure AddSheet(var Styler: TStyler; const Source: string; Origin: TCssOrigin);
var
  Sheet: TCssStyleSheet;
begin
  Sheet := ParseStyleSheet(Source, Origin);
  SetLength(Styler.Sheets, Length(Styler.Sheets) + 1);
  Styler.Sheets[High(Styler.Sheets)] := Sheet;
  Styler.Engine.AddStyleSheet(Sheet);
end;

procedure StyleAll(var Styler: TStyler);
begin
  Styler.Engine.StyleTree(Styler.Root, nil, @KeepStyle, nil);
end;

procedure StopStyler(var Styler: TStyler);
var
  Index: Integer;
begin
  Styler.Root.Free;
  Styler.Engine.Free;
  for Index := 0 to High(Styler.Sheets) do
    Styler.Sheets[Index].Free;
  Styler.Adapter.Free;
end;

function Computed(Element: TTestElement; const PropertyName: string): string;
begin
  Result := Element.Style.SerializeProperty(PropertyByName(PropertyName));
end;

procedure CheckComputed(Element: TTestElement; const PropertyName, Expected, Name: string);
var
  Actual: string;
begin
  Actual := Computed(Element, PropertyName);
  Check(Actual = Expected, Name + ': ' + PropertyName + ' is ' + Expected);
  if Actual <> Expected then
    WriteLn('     got: ', Actual);
end;

procedure TestOrigins;
var
  S: TStyler;
  Html, Target: TTestElement;
begin
  StartStyler(S, False);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    Target := AddElement(Html, 'p', ['id', 't', 'class', 'c', 'style', 'margin-top: 7px; margin-bottom: 1px !important']);
    AddSheet(S, 'p { color: red; padding-top: 1px !important; margin-left: 1px; border-top-style: solid !important; }',
      coUserAgent);
    AddSheet(S, 'p { color: green; padding-top: 2px !important; margin-left: 2px; }', coUser);
    AddSheet(S,
      '#t { color: blue; padding-top: 3px !important; border-top-style: dotted !important; margin-top: 9px !important; }'#10 +
      'p.c { color: yellow; margin-bottom: 9px !important }'#10 +
      'p { margin-right: 1px } p { margin-right: 2px }'#10 +
      'p { margin-left: 3px }', coAuthor);
    StyleAll(S);
    CheckComputed(Target, 'color', 'rgb(0, 0, 255)', 'author beats user and user agent; id beats class');
    CheckComputed(Target, 'padding-top', '1px', 'important user agent beats important user and author');
    CheckComputed(Target, 'border-top-style', 'solid', 'important user agent beats important author');
    CheckComputed(Target, 'margin-left', '3px', 'normal author beats normal user');
    CheckComputed(Target, 'margin-right', '2px', 'later rule wins at equal specificity');
    CheckComputed(Target, 'margin-top', '9px', 'important rule beats normal style attribute');
    CheckComputed(Target, 'margin-bottom', '1px', 'important style attribute beats important rule');
  finally
    StopStyler(S);
  end;
end;

procedure TestLayers;
var
  S: TStyler;
  Html, Target: TTestElement;
begin
  StartStyler(S, False);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    Target := AddElement(Html, 'div', ['id', 'x', 'class', 'k']);
    AddSheet(S,
      '@layer base, theme;'#10 +
      '@layer theme { div { color: red; padding-top: 1px !important; margin-top: 1px } }'#10 +
      '@layer base { #x { color: blue; padding-top: 2px !important; margin-top: 2px; border-top-style: solid } }'#10 +
      '@layer theme.sub { div { margin-left: 4px; border-top-style: dashed } }'#10 +
      '@layer theme { div { margin-left: 5px } }'#10 +
      'div { margin-top: 3px }'#10 +
      '@layer { div { margin-bottom: 1px } } @layer { div { margin-bottom: 2px } }'#10 +
      '.k { margin-right: 6px } @layer z { #x.k { margin-right: 7px !important } }'#10 +
      '@layer revert { div { padding-left: 1px } div { padding-left: revert-layer } }', coAuthor);
    StyleAll(S);
    CheckComputed(Target, 'color', 'rgb(255, 0, 0)', 'a later layer beats an earlier one despite specificity');
    CheckComputed(Target, 'padding-top', '2px', 'important declarations: the earlier layer wins');
    CheckComputed(Target, 'margin-top', '3px', 'unlayered beats layered');
    CheckComputed(Target, 'margin-left', '5px', 'a layer''s own rules beat its sublayers''');
    CheckComputed(Target, 'border-top-style', 'dashed', 'a sublayer of a later layer beats an earlier layer');
    CheckComputed(Target, 'margin-bottom', '2px', 'anonymous layers are ordered by appearance');
    CheckComputed(Target, 'margin-right', '7px', 'an important layered declaration beats a normal unlayered one');
    CheckComputed(Target, 'padding-left', '0px', 'revert-layer rolls back to the previous layer');
  finally
    StopStyler(S);
  end;
end;

procedure TestRevertAndKeywords;
var
  S: TStyler;
  Html, Body, Target, Child: TTestElement;
begin
  StartStyler(S, False);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    Body := AddElement(Html, 'body', []);
    Target := AddElement(Body, 'div', []);
    Child := AddElement(Target, 'span', []);
    AddSheet(S, 'div { display: block; margin-top: 4px } span { display: inline }', coUserAgent);
    AddSheet(S,
      'body { color: rgb(1, 2, 3); border-top-color: rgb(9, 9, 9); padding-top: 5px; font-size: 20px }'#10 +
      'div { display: flex; margin-top: revert; color: initial; border-top-color: inherit; padding-top: inherit }'#10 +
      'span { color: unset; padding-top: unset; display: revert; letter-spacing: 1em }'#10 +
      'div { --c: 1px }', coAuthor);
    StyleAll(S);
    CheckComputed(Target, 'margin-top', '4px', 'revert rolls back to the user agent origin');
    CheckComputed(Target, 'color', 'rgb(0, 0, 0)', 'initial color is canvastext');
    CheckComputed(Target, 'border-top-color', 'rgb(9, 9, 9)', 'inherit on a reset property');
    CheckComputed(Target, 'padding-top', '5px', 'inherit padding');
    CheckComputed(Child, 'color', 'rgb(0, 0, 0)', 'unset inherits an inherited property');
    CheckComputed(Child, 'padding-top', '0px', 'unset resets a reset property');
    CheckComputed(Child, 'display', 'inline', 'revert to the user agent display');
    CheckComputed(Child, 'letter-spacing', '20px', 'em is the element''s font size');
    CheckComputed(Body, 'display', 'inline', 'nothing sets body''s display');
    CheckComputed(Html, 'display', 'block', 'the root is blockified');
  finally
    StopStyler(S);
  end;
end;

procedure TestComputedValues;
var
  S: TStyler;
  Html, Body, Outer, Inner, Leaf, Floated: TTestElement;
begin
  StartStyler(S, False);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    Body := AddElement(Html, 'body', []);
    Outer := AddElement(Body, 'div', ['class', 'outer']);
    Inner := AddElement(Outer, 'div', ['class', 'inner', 'style', '--local: 3px; margin-left: var(--local)']);
    Leaf := AddElement(Inner, 'span', ['class', 'leaf']);
    Floated := AddElement(Body, 'span', ['class', 'floated']);
    S.Engine.SetEnvironment(DefaultMediaEnvironment);
    AddSheet(S,
      ':root { font-size: 20px; --gap: 1rem; --double: calc(var(--gap) * 2); --a: var(--b); --b: var(--a);'#10 +
      '  --color: rgb(10, 20, 30) }'#10 +
      'body { font-size: 0.8em; line-height: 1.5 }'#10 +
      '.outer { font-size: 150%; width: calc(50% - 2em); padding: var(--gap) var(--double);'#10 +
      '  margin-top: var(--a, 7px); margin-bottom: var(--missing, 11px); border: medium solid var(--color);'#10 +
      '  height: 10vh; min-width: 2in; line-height: 2em; outline: 3px dashed }'#10 +
      '.inner { font-size: larger; margin-right: 1rem; padding-left: calc(10px + 5%); text-indent: 2ch;'#10 +
      '  border-top-style: solid; border-top-width: 0.3px; font-weight: bolder; opacity: 150% }'#10 +
      '.leaf { font-weight: lighter; font-size: calc(1em + 2px); width: min(10px, 5%); color: currentcolor;'#10 +
      '  border-left-color: currentcolor; margin: var(--gap) }'#10 +
      '.floated { float: left; display: inline-flex; position: relative }'#10 +
      '@media (min-width: 1000px) { .floated { z-index: 3 } }'#10 +
      '@media (max-width: 500px) { .floated { z-index: 4 } }'#10 +
      '@media (prefers-color-scheme: dark) { .floated { order: 9 } }', coAuthor);
    StyleAll(S);
    CheckComputed(Html, 'font-size', '20px', 'root font size');
    CheckComputed(Body, 'font-size', '16px', 'em against the parent');
    CheckComputed(Outer, 'font-size', '24px', 'percentage against the parent');
    CheckComputed(Outer, 'width', 'calc(50% - 48px)', 'calc with em made absolute, percentage kept');
    CheckComputed(Outer, 'padding-top', '20px', 'var() with rem');
    CheckComputed(Outer, 'padding-right', '40px', 'var() inside a var() inside calc()');
    CheckComputed(Outer, 'margin-top', '7px', 'a property in a var() cycle is invalid: the fallback applies');
    Check(Html.Style.CustomProperty('--a') = '', 'custom properties in a cycle are invalid');
    CheckComputed(Outer, 'margin-bottom', '11px', 'var() fallback');
    CheckComputed(Outer, 'border-top-width', '3px', 'medium border');
    CheckComputed(Outer, 'border-left-color', 'rgb(10, 20, 30)', 'var() in a shorthand');
    CheckComputed(Outer, 'height', '80px', 'vh against the viewport');
    CheckComputed(Outer, 'min-width', '192px', 'inches');
    CheckComputed(Outer, 'line-height', '48px', 'line-height in em is a length');
    CheckComputed(Body, 'line-height', '1.5', 'a line-height number stays a number');
    CheckComputed(Outer, 'outline-width', '3px', 'outline width');
    CheckComputed(Outer, 'border-bottom-width', '3px', 'border widths of every side');
    CheckComputed(Inner, 'font-size', '28.8px', 'larger');
    CheckComputed(Inner, 'margin-right', '20px', 'rem');
    CheckComputed(Inner, 'margin-left', '3px', 'a custom property from the style attribute');
    CheckComputed(Inner, 'padding-left', 'calc(5% + 10px)', 'length plus percentage');
    CheckComputed(Inner, 'text-indent', '28.8px', 'ch is half an em');
    CheckComputed(Inner, 'border-top-width', '1px', 'a thin border snaps to a device pixel');
    CheckComputed(Inner, 'border-bottom-width', '0px', 'no border style, no border width');
    CheckComputed(Inner, 'font-weight', '700', 'bolder');
    CheckComputed(Inner, 'opacity', '1', 'opacity is clamped');
    CheckComputed(Leaf, 'font-weight', '400', 'lighter');
    CheckComputed(Leaf, 'font-size', '30.8px', 'calc with em against the parent');
    CheckComputed(Leaf, 'width', 'min(10px, 5%)', 'min() with a percentage stays a calculation');
    CheckComputed(Leaf, 'border-left-color', 'currentcolor', 'currentcolor stays');
    CheckComputed(Leaf, 'margin-top', '20px', 'an inherited custom property');
    CheckComputed(Leaf, 'line-height', '48px', 'line-height inherits its computed length');
    CheckComputed(Floated, 'display', 'flex', 'a float is blockified');
    CheckComputed(Floated, 'z-index', '3', '@media (min-width) matches');
    CheckComputed(Floated, 'order', '0', 'prefers-color-scheme: dark does not match by default');
    Check(Abs(Leaf.Style.Length(cpWidth, 100) - 5) < 1E-4, 'min(10px, 5%) resolves against 100px to 5px');
    Check(Abs(Outer.Style.Length(cpWidth, 200) - 52) < 1E-4, 'calc(50% - 48px) resolves against 200px to 52px');
    Check(Inner.Style.CustomProperty('--double') = 'calc(1rem * 2)', 'custom properties hold substituted tokens');
    { Shorthands and logical properties (getComputedStyle asks for any). }
    CheckComputed(Outer, 'padding', '20px 40px', 'a shorthand from its longhands');
    CheckComputed(Outer, 'border-top', '3px solid rgb(10, 20, 30)', 'a border side');
    CheckComputed(Outer, 'border', '', 'a shorthand that cannot be written is empty');
    CheckComputed(Leaf, 'margin', '20px', 'four equal sides');
    CheckComputed(Outer, 'overflow', 'visible', 'a pair of equal values');
    CheckComputed(Inner, 'margin-inline-end', '20px', 'a logical longhand is its physical one');
    CheckComputed(Inner, 'padding-inline', 'calc(5% + 10px) 0px', 'a logical pair');
  finally
    StopStyler(S);
  end;
end;

{ CSS Values 4, 10.9: a top-level calculation that comes to NaN is 0,
  one that comes to infinity the largest finite length (a video page's
  player box whose aspect ratio a script set to NaN). }
procedure TestCalcCensoring;
var
  S: TStyler;
  Html, Box: TTestElement;
begin
  StartStyler(S, False);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    Box := AddElement(Html, 'div', ['style', '--ratio: NaN; padding-top: calc(var(--ratio) / 1 * 100%);' +
      ' margin-left: calc(NaN * 1px); width: calc(infinity * 1px); height: calc(-infinity * 1em)']);
    S.Engine.SetEnvironment(DefaultMediaEnvironment);
    StyleAll(S);
    Check(Abs(Box.Style.Length(cpPaddingTop, 200)) < 1E-4, 'calc() of NaN percent resolves to 0 (' +
      FloatToStr(Box.Style.Length(cpPaddingTop, 200)) + ')');
    Check(Abs(Box.Style.Length(cpMarginLeft, 200)) < 1E-4, 'calc() of NaN px resolves to 0 (' +
      FloatToStr(Box.Style.Length(cpMarginLeft, 200)) + ')');
    Check(Abs(Box.Style.Length(cpWidth, 200) - 17895697) < 2, 'calc() of infinity px is the largest length (' +
      FloatToStr(Box.Style.Length(cpWidth, 200)) + ')');
    Check(Abs(Box.Style.Length(cpHeight, 200) + 17895697) < 2, 'calc() of -infinity em is the most negative (' +
      FloatToStr(Box.Style.Length(cpHeight, 200)) + ')');
  finally
    StopStyler(S);
  end;
end;

procedure TestUserAgentSheet;
var
  S: TStyler;
  Html, Body, Heading, Link, Item, Table, Hidden: TTestElement;
  BeforeStyle: TCssComputedStyle;
begin
  StartStyler(S, True);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    AddElement(Html, 'head', []);
    Body := AddElement(Html, 'body', []);
    Heading := AddElement(Body, 'h1', []);
    Link := AddElement(Body, 'a', ['href', 'x']);
    Link.States := [esLink];
    Item := AddElement(AddElement(Body, 'ul', []), 'li', []);
    Table := AddElement(Body, 'table', []);
    Hidden := AddElement(Body, 'div', ['hidden', '']);
    AddSheet(S, 'q::before { color: red }', coAuthor);
    StyleAll(S);
    CheckComputed(Body, 'margin-top', '8px', 'body margin');
    CheckComputed(Heading, 'font-size', '32px', 'h1 font size');
    CheckComputed(Heading, 'margin-top', '21.44px', 'h1 margin');
    CheckComputed(Heading, 'font-weight', '700', 'h1 weight');
    CheckComputed(Link, 'color', 'rgb(0, 0, 238)', 'link color');
    CheckComputed(Link, 'text-decoration-line', 'underline', 'link underline');
    CheckComputed(Item, 'display', 'list-item', 'li display');
    CheckComputed(Item.Parent, 'padding-left', '40px', 'list padding (logical to physical)');
    CheckComputed(Item.Parent, 'list-style-type', 'disc', 'list style');
    CheckComputed(Table, 'display', 'table', 'table display');
    CheckComputed(Table, 'border-spacing', '2px', 'table border spacing');
    CheckComputed(Hidden, 'display', 'none', '[hidden]');
    CheckComputed(Html.Child(0), 'display', 'none', 'head');
    BeforeStyle := S.Engine.ResolvePseudoStyle(Link, Link.Style, peBefore);
    Check(BeforeStyle = nil, 'no rule for a::before, no style');
    BeforeStyle.Release;
  finally
    StopStyler(S);
  end;
end;

procedure CheckMedia(const Query: string; const Environment: TCssMediaEnvironment; Expected: Boolean);
var
  List: TCssMediaQueryList;
begin
  List := ParseMediaQueryText(Query);
  try
    Check(List.Matches(Environment) = Expected, '@media ' + Query);
  finally
    List.Free;
  end;
end;

procedure TestMediaQueries;
var
  Environment: TCssMediaEnvironment;
begin
  Environment := DefaultMediaEnvironment;
  Environment.Width := 800;
  Environment.Height := 600;
  Environment.Resolution := 2;
  CheckMedia('screen', Environment, True);
  CheckMedia('print', Environment, False);
  CheckMedia('not print', Environment, True);
  CheckMedia('only screen and (min-width: 600px)', Environment, True);
  CheckMedia('(width >= 800px)', Environment, True);
  CheckMedia('(width > 800px)', Environment, False);
  CheckMedia('(400px <= width <= 900px)', Environment, True);
  CheckMedia('(900px > width > 400px)', Environment, True);
  CheckMedia('(max-width: 50em)', Environment, True);
  CheckMedia('(max-width: 49em)', Environment, False);
  { calc() with relative units (developer.mozilla.org's layout): 50rem
    is 800px. }
  CheckMedia('(width < calc(1rem * 2 + 15rem + 2rem + 31rem))', Environment, False);
  CheckMedia('(width <= calc(1rem * 2 + 15rem + 2rem + 31rem))', Environment, True);
  CheckMedia('(width < calc(50vw + 401px))', Environment, True);
  CheckMedia('(orientation: landscape)', Environment, True);
  CheckMedia('(aspect-ratio: 4/3)', Environment, True);
  CheckMedia('(min-aspect-ratio: 16/9)', Environment, False);
  CheckMedia('(min-resolution: 2dppx)', Environment, True);
  CheckMedia('(resolution: 192dpi)', Environment, True);
  CheckMedia('(resolution > 2x)', Environment, False);
  CheckMedia('(hover) and (pointer: fine)', Environment, True);
  CheckMedia('(any-pointer: coarse)', Environment, False);
  CheckMedia('(prefers-reduced-motion)', Environment, False);
  CheckMedia('(prefers-reduced-motion: no-preference)', Environment, True);
  CheckMedia('(prefers-color-scheme: light)', Environment, True);
  CheckMedia('(color)', Environment, True);
  CheckMedia('(monochrome)', Environment, False);
  CheckMedia('(color-gamut: srgb)', Environment, True);
  CheckMedia('(color-gamut: p3)', Environment, False);
  CheckMedia('(width > 100px) or (unknown-feature)', Environment, True);
  CheckMedia('not (unknown-feature)', Environment, False);
  CheckMedia('(width: garbage)', Environment, False);
  CheckMedia('(width < 100px), (height < 700px)', Environment, True);
  CheckMedia('foo and', Environment, False);
  CheckMedia('', Environment, True);
  Environment.DarkColorScheme := True;
  Environment.ReducedMotion := True;
  CheckMedia('(prefers-color-scheme: dark) and (prefers-reduced-motion: reduce)', Environment, True);
  Check(SupportsConditionText('(display: grid)'), '@supports (display: grid)');
  Check(not SupportsConditionText('(display: nonsense)'), '@supports (display: nonsense) is false');
  Check(SupportsConditionText('(not (color: nonsense)) and selector(a > b:has(c))'), '@supports with not, and, selector()');
  Check(not SupportsConditionText('not (color: nonsense) and (color: red)'), '@supports: not cannot be followed by and');
  Check(SupportsConditionText('(--x: anything)'), '@supports a custom property');
  Check(not SupportsConditionText('(display: grid) and (foo)'), '@supports with an unknown part is false');
end;

procedure CheckColorVector(const Text: string; Red, Green, Blue: Double);
var
  Value: TCssValue;
  Color: TCssColor;
begin
  Value := ParseColorText(Text);
  if (Value = nil) or not ResolveColor(Value, TransparentColor, False, Color) then
  begin
    Check(False, 'color parses: ' + Text);
    Value.Release;
    Exit;
  end;
  Value.Release;
  Color := ConvertColor(Color, csSrgb);
  Check((Abs(Color.Components[0] - Red) < 2E-4) and (Abs(Color.Components[1] - Green) < 2E-4) and
    (Abs(Color.Components[2] - Blue) < 2E-4), Format('%s is srgb(%.4f %.4f %.4f)', [Text, Red, Green, Blue]));
  if not ((Abs(Color.Components[0] - Red) < 2E-4) and (Abs(Color.Components[1] - Green) < 2E-4) and
    (Abs(Color.Components[2] - Blue) < 2E-4)) then
    WriteLn(Format('     got %.6f %.6f %.6f', [Color.Components[0], Color.Components[1], Color.Components[2]]));
end;

procedure TestColors;
var
  Color, Back: TCssColor;
  Space: TCssColorSpace;
begin
  {$I CssTest.ColorVectors.inc}
  { Round trips through every space. }
  Color := MakeRgbColor(0.2, 0.4, 0.6, 1);
  for Space := Low(TCssColorSpace) to High(TCssColorSpace) do
  begin
    Back := ConvertColor(ConvertColor(Color, Space), csSrgb);
    Check((Abs(Back.Components[0] - 0.2) < 1E-6) and (Abs(Back.Components[1] - 0.4) < 1E-6) and
      (Abs(Back.Components[2] - 0.6) < 1E-6), 'sRGB round trip through ' + ColorSpaceName(Space));
  end;
  Check(ColorToRgba8(ConvertColor(MakeColor(csDisplayP3, 1, 0, 0, 1), csSrgb)).Red = 255,
    'display-p3 red clips to sRGB red');
end;

function TokensText(Properties: TCssCustomProperties; const Name: string): string;
var
  Tokens: TCssTokenArray;
begin
  if Properties.Find(InternAtom(Name), Tokens) then
    Result := SerializeTokenArray(Tokens)
  else
    Result := '(none)';
end;

{ Layered custom property sets: a child set holds only its differences
  from the flat set below, is flattened past a few dozen, and a set
  equal to its parent's is the parent's. }
procedure TestCustomPropertySets;
var
  Root, Child, Grandchild, Same: TCssCustomProperties;
  Index: Integer;
begin
  Root := TCssCustomProperties.Over(nil);
  for Index := 0 to 99 do
    Root.Put(InternAtom('--root-' + IntToStr(Index)), TokenizeCss(IntToStr(Index) + 'px'));
  Root := Root.Finish(nil);
  Check(Root.Count = 100, 'custom properties: a flat set has its entries');

  Child := TCssCustomProperties.Over(Root);
  Child.Put(InternAtom('--root-5'), TokenizeCss('red'));
  Child.Put(InternAtom('--own'), TokenizeCss('1'));
  Child.Remove(InternAtom('--root-7'));
  Child := Child.Finish(Root);
  Check(Child <> Root, 'custom properties: a set with differences is its own');
  Check(TokensText(Child, '--root-5') = 'red', 'custom properties: a difference hides the base value');
  Check(TokensText(Child, '--root-6') = '6px', 'custom properties: the rest comes from the base');
  Check(TokensText(Child, '--root-7') = '(none)', 'custom properties: a removed name is gone');
  Check(Child.Count = 100, 'custom properties: one added, one removed');

  Grandchild := TCssCustomProperties.Over(Child);
  Grandchild.Put(InternAtom('--deeper'), TokenizeCss('2'));
  Grandchild := Grandchild.Finish(Child);
  Check(TokensText(Grandchild, '--root-5') = 'red', 'custom properties: differences are carried down');
  Check(TokensText(Grandchild, '--root-7') = '(none)', 'custom properties: removals are carried down');
  Check(TokensText(Grandchild, '--deeper') = '2', 'custom properties: and the set''s own');

  Same := TCssCustomProperties.Over(Child);
  Same := Same.Finish(Child);
  Check(Same = Child, 'custom properties: a set with nothing changed is the parent''s');
  Same.Release;

  Same := TCssCustomProperties.Over(Root);
  Same.Put(InternAtom('--root-5'), TokenizeCss('red'));
  Same.Put(InternAtom('--own'), TokenizeCss('1'));
  Same.Remove(InternAtom('--root-7'));
  Same := Same.Finish(Root);
  Check(Same.Equals(Child) and Child.Equals(Same), 'custom properties: equal sets made apart are equal');
  Check(not Grandchild.Equals(Child), 'custom properties: a set with one more is not equal');
  Same.Release;

  Same := TCssCustomProperties.Over(Grandchild);
  for Index := 0 to 49 do
    Same.Put(InternAtom('--many-' + IntToStr(Index)), TokenizeCss(IntToStr(Index)));
  Same := Same.Finish(Grandchild);
  Check(Same.Count = 151, 'custom properties: a set with many differences, flattened, has them all');
  Check((TokensText(Same, '--root-5') = 'red') and (TokensText(Same, '--root-7') = '(none)') and
    (TokensText(Same, '--many-49') = '49') and (TokensText(Same, '--root-99') = '99px'),
    'custom properties: flattening keeps every value');
  Same.Release;

  Grandchild.Release;
  Child.Release;
  Root.Release;
end;

{ Elements declaring no custom property share their parent's set, also
  with registered properties that do not inherit (their initial values
  are what the parent has). }
procedure TestCustomPropertySharing;
var
  S: TStyler;
  Html, Body, Plain, Declaring, Below: TTestElement;
begin
  StartStyler(S, False);
  try
    Html := AddElement(nil, 'html', []);
    S.Root := Html;
    Body := AddElement(Html, 'body', []);
    Plain := AddElement(Body, 'div', []);
    Declaring := AddElement(Body, 'div', ['class', 'declaring']);
    Below := AddElement(Declaring, 'span', []);
    AddSheet(S,
      '@property --local { syntax: "<length>"; inherits: false; initial-value: 4px }'#10 +
      '@property --shared { syntax: "<color>"; inherits: true; initial-value: red }'#10 +
      ':root { --a: 1px; --b: 2px }'#10 +
      '.declaring { --a: 9px; --local: 7px; --shared: blue; width: var(--local); height: var(--a) }'#10 +
      'span { width: var(--local); height: var(--b) }', coAuthor);
    StyleAll(S);
    Check(Body.Style.Custom = Html.Style.Custom, 'custom property sharing: an element declaring none shares');
    Check(Plain.Style.Custom = Html.Style.Custom, 'custom property sharing: also with registered properties');
    Check(Declaring.Style.Custom <> Html.Style.Custom, 'custom property sharing: a declaring element has its own');
    CheckComputed(Declaring, 'width', '7px', 'custom property sharing: a non-inherited registered value');
    CheckComputed(Below, 'width', '4px', 'custom property sharing: not inherited, the initial value below');
    CheckComputed(Below, 'height', '2px', 'custom property sharing: the root''s value through the layer');
    Check(TokensText(Below.Style.Custom, '--shared') = 'blue', 'custom property sharing: an inherited registered value');
    Check(TokensText(Plain.Style.Custom, '--local') = '4px', 'custom property sharing: the initial value everywhere');
  finally
    StopStyler(S);
  end;
end;

{ What a class, id or attribute change asks to be styled again, by
  where the selectors have the name. }
procedure TestNameInvalidation;
var
  S: TStyler;

  procedure CheckName(Kind: TCssSelectorNameKind; const Name: string; Expected: TCssNameInvalidation;
    const What: string);
  begin
    Check(S.Engine.NameInvalidation(Kind, InternAtom(Name)) = Expected, 'name invalidation: ' + What);
  end;

begin
  StartStyler(S, False);
  try
    S.Root := AddElement(nil, 'html', []);
    AddSheet(S,
      '.a .b { color: red } .c + .d { color: red } #x { color: red } [data-y] > p { color: red }'#10 +
      ':is(.e .f) { color: red } .g:has(.h) { color: red } li:nth-child(2 of .k) { color: red }'#10 +
      '.Mixed { color: red } :not(.n) { color: red } .s ~ div .t { color: red }', coAuthor);
    CheckName(snClass, 'a', [niDescendants], 'left of a descendant combinator');
    CheckName(snClass, 'b', [niSelf], 'the subject');
    CheckName(snClass, 'c', [niSiblings], 'left of a sibling combinator');
    CheckName(snId, 'x', [niSelf], 'an id');
    CheckName(snAttribute, 'data-y', [niDescendants], 'an attribute');
    CheckName(snClass, 'e', [niSelf, niDescendants, niSiblings], 'in a complex argument');
    CheckName(snClass, 'f', [niSelf], 'the subject of an argument');
    CheckName(snClass, 'h', [niEverywhere], 'inside :has()');
    CheckName(snClass, 'k', [niEverywhere], 'the selector of :nth-child(of)');
    CheckName(snClass, 'mixed', [niSelf], 'any case');
    CheckName(snClass, 'n', [niSelf], 'inside :not()');
    CheckName(snClass, 's', [niSiblings], 'left of siblings and descendants');
    CheckName(snClass, 'unknown', [], 'a name no selector has');
  finally
    StopStyler(S);
  end;
end;

procedure RunCascadeTests;
begin
  TestOrigins;
  TestLayers;
  TestRevertAndKeywords;
  TestComputedValues;
  TestCalcCensoring;
  TestUserAgentSheet;
  TestMediaQueries;
  TestColors;
  TestCustomPropertySets;
  TestCustomPropertySharing;
  TestNameInvalidation;
end;

end.
