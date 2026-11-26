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
  Tokenizer cases (CSS Syntax 3) and parse-and-serialize round trips of
  style sheets, values and shorthands.
}
unit CssTest.Syntax;

{$mode objfpc}
{$H+}

interface

procedure RunSyntaxTests;

implementation

uses
  SysUtils, TestChecks, Css.Tokens, Css.Tokenizer, Css.Serialization, Css.Values, Css.PropertyIds,
  Css.Properties, Css.Grammar, Css.Declarations, Css.Stylesheets, Css.Parser, Css.Shorthands,
  Css.PropertyParsers;

{ The tokens as "kind:text" words. }
function Describe(const Source: string): string;
const
  Names: array[TCssTokenKind] of string = ('ident', 'function', 'at', 'hash', 'string', 'bad-string', 'url',
    'bad-url', 'delim', 'number', 'percentage', 'dimension', 'ws', 'cdo', 'cdc', 'colon', 'semicolon', 'comma',
    '[', ']', '(', ')', '{', '}', 'eof');
var
  Tokens: TCssTokenArray;
  Index: Integer;
  Token: PCssToken;
  Text: string;
begin
  Tokens := TokenizeCss(Source);
  Result := '';
  for Index := 0 to High(Tokens) do
  begin
    Token := @Tokens[Index];
    if Token^.Kind = tkEof then
      Break;
    Text := Names[Token^.Kind];
    case Token^.Kind of
      tkIdent, tkFunction, tkAtKeyword, tkString, tkUrl, tkDelim:
        Text := Text + ':' + Token^.Text;
      tkHash:
        if tfIdHash in Token^.Flags then
          Text := Text + ':id:' + Token^.Text
        else
          Text := Text + ':' + Token^.Text;
      tkNumber, tkPercentage:
        begin
          Text := Text + ':' + SerializeNumber(Token^.Number);
          if tfInteger in Token^.Flags then
            Text := Text + 'i';
        end;
      tkDimension:
        Text := Text + ':' + SerializeNumber(Token^.Number) + ':' + Token^.Text;
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Text;
  end;
end;

procedure CheckTokens(const Source, Expected: string);
var
  Actual: string;
begin
  Actual := Describe(Source);
  Check(Actual = Expected, 'tokens of ' + Source);
  if Actual <> Expected then
    WriteLn('     got: ', Actual);
end;

procedure TestTokenizer;
begin
  CheckTokens('a{color:red}', 'ident:a { ident:color colon ident:red }');
  CheckTokens('#abc #1a', 'hash:id:abc ws hash:1a');
  CheckTokens('12 +3.5 -.5e2 10% 4px 1e3x', 'number:12i ws number:3.5 ws number:-50 ws percentage:10i ws ' +
    'dimension:4:px ws dimension:1000:x');
  CheckTokens('"a\"b" ''c\41 d''', 'string:a"b ws string:cAd');
  CheckTokens('"line'#10'x"', 'bad-string ws ident:x string:');
  CheckTokens('a\'#10, 'ident:a delim:\ ws');
  CheckTokens('url( a.png ) url("b") url(a b)', 'url:a.png ws function:url string:b ) ws bad-url');
  CheckTokens('/* c */ a /**/ b', 'ws ident:a ws ws ident:b');
  CheckTokens('<!-- --> @media -->', 'cdo ws cdc ws at:media ws cdc');
  CheckTokens('\31 23 -\-x --var', 'ident:123 ws ident:--x ws ident:--var');
  CheckTokens('a\', 'ident:a' + #$EF#$BF#$BD);
  CheckTokens('U+0-7F', 'ident:U number:0i dimension:-7:F');
  CheckTokens('1.0 2.', 'number:1 ws number:2i delim:.');
  CheckTokens('é', 'ident:é');
  CheckTokens('a'#0'b', 'ident:a' + #$EF#$BF#$BD + 'b');
  CheckTokens('x'#13#10'y', 'ident:x ws ident:y');
  CheckTokens(':not(a,b)[x]', 'colon function:not ident:a comma ident:b ) [ ident:x ]');
  Check(SerializeIdentifier('1a') = '\31 a', 'identifier starting with a digit is escaped');
  Check(SerializeIdentifier('a b') = 'a\ b', 'identifier with a space is escaped');
  Check(SerializeString('a"b\') = '"a\"b\\"', 'string escaping');
  Check(SerializeNumber(0.1 + 0.2) = '0.3', 'number serialization rounds to six decimals');
  Check(SerializeTokenArray(TokenizeCss('a /**/ b 1px  2')) = 'a b 1px 2', 'token serialization collapses spaces');
  Check(SerializeTokenArray(TokenizeCss('a/**/b')) = 'a/**/b', 'token serialization keeps idents apart');
end;

procedure CheckValue(const PropertyName, Text, Expected: string);
var
  Value: TCssValue;
  Actual: string;
begin
  Value := ParseLonghandValue(PropertyByName(PropertyName), TCssTokenCursor.Create(TokenizeCss(Text)));
  if Value = nil then
    Actual := '(invalid)'
  else
    Actual := Value.Serialize;
  Value.Release;
  Check(Actual = Expected, PropertyName + ': ' + Text);
  if Actual <> Expected then
    WriteLn('     got: ', Actual, ' expected: ', Expected);
end;

procedure TestValues;
begin
  CheckValue('width', '10px', '10px');
  CheckValue('width', '0', '0px');
  CheckValue('width', '-1px', '(invalid)');
  CheckValue('margin-top', '-1px', '-1px');
  CheckValue('width', 'calc(100% - 2em + 3px)', 'calc(100% - 2em + 3px)');
  CheckValue('width', 'calc(2px * 3 + 1in)', 'calc(102px)');
  CheckValue('width', 'calc(1px+2px)', '(invalid)');
  CheckValue('width', 'min(10px, 2em)', 'min(10px, 2em)');
  CheckValue('width', 'clamp(10px, 50%, 1in)', 'clamp(10px, 50%, 96px)');
  CheckValue('width', 'calc(10px * 2px)', '(invalid)');
  CheckValue('opacity', 'calc(1 / 2)', 'calc(0.5)');
  CheckValue('rotate', 'calc(asin(1))', 'calc(90deg)');
  CheckValue('width', 'calc(round(up, 12px, 5px))', 'calc(15px)');
  CheckValue('width', 'fit-content(20%)', 'fit-content(20%)');
  { Legacy line clamping. }
  CheckValue('-webkit-line-clamp', '3', '3');
  CheckValue('-webkit-line-clamp', 'none', 'none');
  CheckValue('-webkit-line-clamp', '2px', '(invalid)');
  CheckValue('-webkit-box-orient', 'vertical', 'vertical');
  CheckValue('-webkit-box-orient', 'block-axis', 'block-axis');
  CheckValue('color', 'RED', 'rgb(255, 0, 0)');
  CheckValue('color', '#0f08', 'rgba(0, 255, 0, 0.533)');
  CheckValue('color', 'rgb(255 0 0 / 50%)', 'rgba(255, 0, 0, 0.5)');
  CheckValue('color', 'rgb(255, 0%, 0)', '(invalid)');
  CheckValue('color', 'hsl(120deg 100% 25% / 0.5)', 'rgba(0, 128, 0, 0.5)');
  CheckValue('color', 'oklch(70% 0.1 200)', 'oklch(0.7 0.1 200)');
  CheckValue('color', 'lab(50 none -30)', 'lab(50 none -30)');
  CheckValue('color', 'color(display-p3 1 0 0 / 0.25)', 'color(display-p3 1 0 0 / 0.25)');
  CheckValue('color', 'currentColor', 'currentcolor');
  CheckValue('color', 'Canvas', 'canvas');
  CheckValue('color', 'color-mix(in oklch, currentcolor 30%, blue)', 'color-mix(in oklch, currentcolor 30%, rgb(0, 0, 255))');
  CheckValue('background-image', 'linear-gradient(to right, red 10%, blue)',
    'linear-gradient(to right, rgb(255, 0, 0) 10%, rgb(0, 0, 255))');
  CheckValue('background-image', 'radial-gradient(circle at top left, red, 30%, blue 50px), url(a.png)',
    'radial-gradient(circle at left top, rgb(255, 0, 0), 30%, rgb(0, 0, 255) 50px), url("a.png")');
  CheckValue('background-image', 'conic-gradient(from 45deg in oklch, red, blue 90deg)',
    'conic-gradient(from 45deg in oklch, rgb(255, 0, 0), rgb(0, 0, 255) 90deg)');
  CheckValue('background-image', 'linear-gradient(red)', '(invalid)');
  CheckValue('transform', 'translate(10px, 20%) rotate(45deg) scale(1.5)', 'translate(10px, 20%) rotate(45deg) scale(1.5)');
  CheckValue('transform', 'rotate(10px)', '(invalid)');
  CheckValue('display', 'inline flow-root', 'inline-block');
  CheckValue('display', 'block flex', 'flex');
  CheckValue('display', 'inline list-item', 'inline list-item');
  CheckValue('display', 'flex block', 'flex');
  CheckValue('display', 'block inline', '(invalid)');
  CheckValue('display', 'grid list-item', '(invalid)');
  CheckValue('grid-template-columns', '[a] repeat(auto-fill, minmax(100px, 1fr)) [b c] 20px',
    '[a] repeat(auto-fill, minmax(100px, 1fr)) [b c] 20px');
  CheckValue('grid-template-areas', '"a a b" "c c b"', '"a a b" "c c b"');
  CheckValue('grid-template-areas', '"a b a"', '(invalid)');
  CheckValue('grid-row-start', 'span 2 foo', 'span 2 foo');
  CheckValue('grid-row-start', '0', '(invalid)');
  CheckValue('box-shadow', '1px 2px 3px red inset, 0 0 black', 'rgb(255, 0, 0) 1px 2px 3px inset, rgb(0, 0, 0) 0px 0px');
  CheckValue('font-family', 'Helvetica Neue, "Arial", sans-serif', 'Helvetica Neue, "Arial", sans-serif');
  CheckValue('font-weight', '1001', '(invalid)');
  CheckValue('text-decoration-line', 'underline overline', 'underline overline');
  CheckValue('text-decoration-line', 'underline underline', '(invalid)');
  CheckValue('content', '"a" counter(x, upper-roman) attr(title) / "alt"', '"a" counter(x, upper-roman) attr(title) / "alt"');
  CheckValue('transition-timing-function', 'cubic-bezier(0.1, 2, 0.3, 1), steps(4, jump-end)',
    'cubic-bezier(0.1, 2, 0.3, 1), steps(4, jump-end)');
  CheckValue('transition-timing-function', 'cubic-bezier(2, 0, 0, 1)', '(invalid)');
  CheckValue('object-position', 'left 10px top', 'left 10px top');
  CheckValue('aspect-ratio', '16 / 9', '16 / 9');
  CheckValue('width', 'var(--x)', '(invalid)');
end;

procedure CheckShorthand(const Name, Text, Expected: string);
var
  Block: TCssDeclarationBlock;
  Actual: string;
begin
  Block := TCssDeclarationBlock.Create;
  try
    if Block.AddParsed(Name, TCssTokenCursor.Create(TokenizeCss(Text)), False) then
      Actual := Block.Serialize
    else
      Actual := '(invalid)';
  finally
    Block.Free;
  end;
  Check(Actual = Expected, Name + ': ' + Text);
  if Actual <> Expected then
    WriteLn('     got: ', Actual, #10'     expected: ', Expected);
end;

procedure CheckLonghand(const Name, Text, Longhand, Expected: string);
var
  Block: TCssDeclarationBlock;
  Actual: string;
begin
  Block := TCssDeclarationBlock.Create;
  try
    Block.AddParsed(Name, TCssTokenCursor.Create(TokenizeCss(Text)), False);
    Actual := Block.PropertyValue(Longhand);
  finally
    Block.Free;
  end;
  Check(Actual = Expected, Name + ': ' + Text + ' gives ' + Longhand);
  if Actual <> Expected then
    WriteLn('     got: ', Actual, ' expected: ', Expected);
end;

procedure TestShorthands;
begin
  CheckShorthand('margin', '1px 2px 1px 2px', 'margin: 1px 2px;');
  CheckShorthand('padding', '1px 2px 3px', 'padding: 1px 2px 3px;');
  CheckShorthand('margin', 'inherit', 'margin: inherit;');
  CheckShorthand('margin', '1px var(--x)', 'margin: 1px var(--x);');
  CheckShorthand('inset', '0 auto', 'inset: 0px auto;');
  CheckShorthand('gap', '1em', 'gap: 1em;');
  CheckShorthand('overflow', 'hidden auto', 'overflow: hidden auto;');
  CheckShorthand('border-top', 'solid 2px red', 'border-top: 2px solid rgb(255, 0, 0);');
  CheckShorthand('flex', '1', 'flex: 1 1 0%;');
  CheckShorthand('flex', 'none', 'flex: 0 0 auto;');
  CheckShorthand('flex', 'auto', 'flex: 1 1 auto;');
  CheckShorthand('flex', '2 30px', 'flex: 2 1 30px;');
  CheckShorthand('margin', '1px 2px 3px 4px 5px', '(invalid)');
  CheckShorthand('grid-row', 'a', 'grid-row: a;');
  CheckShorthand('grid-row', '2 / span 3', 'grid-row: 2 / span 3;');
  CheckShorthand('place-items', 'center', 'place-items: center;');
  CheckLonghand('border', '1px solid', 'border-left-color', 'currentcolor');
  CheckLonghand('border', '1px solid', 'border-image-slice', '100%');
  CheckLonghand('border-radius', '1px 2px / 3px', 'border-bottom-left-radius', '2px 3px');
  CheckLonghand('font', 'italic bold 12px/1.5 "Helvetica Neue", serif', 'line-height', '1.5');
  CheckLonghand('font', 'italic bold 12px/1.5 "Helvetica Neue", serif', 'font-family', '"Helvetica Neue", serif');
  CheckLonghand('font', 'small-caps 1em serif', 'font-variant-caps', 'small-caps');
  CheckLonghand('font', '12px', 'font-size', '');
  CheckLonghand('background', 'url(x.png) no-repeat center / cover, blue', 'background-size', 'cover, auto');
  CheckLonghand('background', 'url(x.png) no-repeat center / cover, blue', 'background-color', 'rgb(0, 0, 255)');
  CheckLonghand('background', 'url(x.png) no-repeat center / cover, blue', 'background-position-x', 'center, 0%');
  CheckLonghand('background', 'red, blue', 'background-color', '');
  CheckLonghand('mask', 'url(i.svg) no-repeat center / 20px, linear-gradient(red, blue)', 'mask-size', '20px, auto');
  CheckLonghand('mask', 'url(i.svg) no-repeat center / 20px', 'mask-repeat', 'no-repeat');
  CheckLonghand('mask', 'url(i.svg) content-box luminance', 'mask-clip', 'content-box');
  CheckLonghand('mask', 'url(i.svg) content-box luminance', 'mask-mode', 'luminance');
  CheckLonghand('-webkit-mask', 'url(i.svg) no-repeat', 'mask-repeat', 'no-repeat');
  CheckLonghand('mask-position', 'right 4px top', 'mask-position-x', 'right 4px');
  CheckLonghand('-webkit-mask-size', 'contain', 'mask-size', 'contain');
  CheckLonghand('transition', 'opacity 1s ease-in .5s, transform 2s', 'transition-delay', '0.5s, 0s');
  CheckLonghand('transition', 'opacity 1s ease-in .5s, transform 2s', 'transition-property', 'opacity, transform');
  CheckLonghand('animation', 'spin 2s infinite linear', 'animation-iteration-count', 'infinite');
  CheckLonghand('animation', 'spin 2s infinite linear', 'animation-name', 'spin');
  CheckLonghand('list-style', 'none', 'list-style-type', 'none');
  CheckLonghand('list-style', 'none', 'list-style-image', 'none');
  CheckLonghand('list-style', 'square inside', 'list-style-position', 'inside');
  CheckLonghand('text-decoration', 'underline dotted red', 'text-decoration-style', 'dotted');
  CheckLonghand('grid-template', '"a a" 40px "b c" 1fr / 1fr 2fr', 'grid-template-rows', '40px 1fr');
  CheckLonghand('grid-template', '"a a" 40px "b c" 1fr / 1fr 2fr', 'grid-template-columns', '1fr 2fr');
  CheckLonghand('grid', 'auto-flow dense 40px / 1fr 1fr', 'grid-auto-flow', 'dense');
  CheckLonghand('grid', 'auto-flow dense 40px / 1fr 1fr', 'grid-auto-rows', '40px');
  CheckLonghand('margin-inline', '1px 2px', 'margin-inline-end', '2px');
  CheckLonghand('columns', '3 10em', 'column-width', '10em');
  CheckLonghand('outline', 'dashed', 'outline-color', 'auto');
  CheckLonghand('all', 'unset', 'color', 'unset');
  CheckLonghand('all', 'unset', 'direction', '');
end;

procedure CheckSheet(const Source, Expected: string);
var
  Sheet: TCssStyleSheet;
  Actual: string;
begin
  Sheet := ParseStyleSheet(Source, coAuthor);
  try
    Actual := Trim(Sheet.Serialize);
  finally
    Sheet.Free;
  end;
  Check(Actual = Expected, 'sheet: ' + Source);
  if Actual <> Expected then
    WriteLn('     got: ', Actual, #10'     expected: ', Expected);
end;

procedure TestSheets;
begin
  CheckSheet('a { color : red ; ; }', 'a { color: rgb(255, 0, 0); }');
  CheckSheet('a{}b{color:blue', 'a { }'#10'b { color: rgb(0, 0, 255); }');
  CheckSheet('bad { color: ; width: 10px; foo: bar }', 'bad { width: 10px; }');
  CheckSheet('a { color: red !important; color: blue }', 'a { color: rgb(255, 0, 0) !important; }');
  CheckSheet('a { color: red; color: blue }', 'a { color: rgb(0, 0, 255); }');
  CheckSheet('a::before:hover, :is(p, ..bad) { }', 'a::before:hover, :is(p) { }');
  CheckSheet('a, b:foo { color: red } c { color: red }', 'c { color: rgb(255, 0, 0); }');
  CheckSheet('@import "a.css" layer(x) supports(display: grid) print; a { }',
    '@import url("a.css") layer(x) supports(display: grid) print;'#10'a { }');
  CheckSheet('a { } @import "late.css";', 'a { }');
  CheckSheet('@media screen and (min-width:600px),print{p{margin:0}}',
    '@media screen and (min-width: 600px), print {'#10'  p { margin: 0px; }'#10'}');
  CheckSheet('@media (400px <= width < 700px) { }', '@media (400px <= width < 700px) {'#10'}');
  CheckSheet('@media garbage!{ a { } }', '@media not all {'#10'  a { }'#10'}');
  CheckSheet('@supports (display: grid) and (not (display: foo)) { a { } }',
    '@supports (display: grid) and (not (display: foo)) {'#10'  a { }'#10'}');
  CheckSheet('@layer a, b.c; @layer { x { } }', '@layer a, b.c;'#10'@layer {'#10'  x { }'#10'}');
  CheckSheet('.card { padding: 4px; & .t { color: red } > p { margin: 0 } color: blue }',
    '.card { padding: 4px;'#10'  & .t { color: rgb(255, 0, 0); }'#10'  & > p { margin: 0px; }'#10 +
    '  color: rgb(0, 0, 255);'#10'}');
  CheckSheet('a { b:hover { color: red } }', 'a {'#10'  & b:hover { color: rgb(255, 0, 0); }'#10'}');
  CheckSheet('@keyframes spin { from { opacity: 0 } 50% { opacity: .5 !important; color: red } to { opacity: 1 } }',
    '@keyframes spin {'#10'  0% { opacity: 0; }'#10'  50% { color: rgb(255, 0, 0); }'#10'  100% { opacity: 1; }'#10'}');
  CheckSheet('@font-face { font-family: "My Font"; src: url(a.woff2) format("woff2"), local(Arial) }',
    '@font-face { font-family: "My Font"; src: url("a.woff2") format("woff2"), local(Arial); }');
  CheckSheet('@namespace svg url(http://www.w3.org/2000/svg); svg|rect, *|*, |p { }',
    '@namespace svg url("http://www.w3.org/2000/svg");'#10'svg|rect, *|*, |p { }');
  CheckSheet('undeclared|rect { }', '');
  CheckSheet('@page :first { margin: 1in }', '@page :first { margin: 1in; }');
  CheckSheet('@property --x { syntax: "<length>"; inherits: false; initial-value: 0px }',
    '@property --x { syntax: "<length>"; inherits: false; initial-value: 0px; }');
  CheckSheet('@container card (min-width: 400px) { a { } }', '@container card (min-width: 400px) {'#10'  a { }'#10'}');
  CheckSheet('a { --x: { a: b }; --y:; --z:  1px  2px }', 'a { --x: { a: b }; --y: ; --z: 1px 2px; }');
  CheckSheet('<!-- a { } -->', 'a { }');
  CheckSheet('a[href^="http" i]:nth-child(2n+1 of .x):not(.y) ~ b { }',
    'a[href^="http" i]:nth-child(2n+1 of .x):not(.y) ~ b { }');
  CheckSheet(':nth-child( -n + 3 ), :nth-last-of-type(odd), :nth-child(+5) { }',
    ':nth-child(-n+3), :nth-last-of-type(2n+1), :nth-child(5) { }');
  CheckSheet(':nth-child(2n + - 1) { }', '');
  CheckSheet(':has(> img, + p) :lang(en, "fr-CA") :dir(rtl) { }', ':has(> img, + p) :lang(en, fr-CA) :dir(rtl) { }');
end;

procedure RunSyntaxTests;
begin
  TestTokenizer;
  TestValues;
  TestShorthands;
  TestSheets;
end;

end.
