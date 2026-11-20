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
  The user agent style sheet for HTML: the CSS of the HTML Standard's
  rendering section (15.3 Non-replaced elements, 15.4 Replaced
  elements, 15.5 Widgets), and the additions that apply in quirks
  mode. Both are parsed once, when first needed, and shared by every
  style engine.
}
unit Css.UserAgentStyleSheet;

{$mode objfpc}
{$H+}

interface

uses
  Css.Stylesheets;

function UserAgentStyleSheet: TCssStyleSheet;
function QuirksModeStyleSheet: TCssStyleSheet;

const
  UserAgentCss: PChar =
    '@namespace "http://www.w3.org/1999/xhtml";'#10 +
    { 15.3.1 Hidden elements }
    'area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp, script, style, template,'#10 +
    'title { display: none; }'#10 +
    '[hidden]:not([hidden=until-found i]):not(embed) { display: none; }'#10 +
    '[hidden=until-found i]:not(embed) { content-visibility: hidden; }'#10 +
    'embed[hidden] { display: inline; height: 0; width: 0; }'#10 +
    'input[type=hidden i] { display: none !important; }'#10 +
    '@media (scripting) { noscript { display: none !important; } }'#10 +
    { 15.3.2 The page }
    'html, body { display: block; }'#10 +
    'body { margin: 8px; }'#10 +
    { 15.3.3 Flow content }
    'address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr, legend, listing,'#10 +
    'main, p, plaintext, pre, search, xmp { display: block; }'#10 +
    'blockquote, figure, listing, p, plaintext, pre, xmp { margin-block: 1em; }'#10 +
    'blockquote, figure { margin-inline: 40px; }'#10 +
    'address { font-style: italic; }'#10 +
    'listing, plaintext, pre, xmp { font-family: monospace; white-space: pre; }'#10 +
    'dialog:not([open]) { display: none; }'#10 +
    'dialog { position: absolute; inset-inline-start: 0; inset-inline-end: 0; width: fit-content;'#10 +
    '  height: fit-content; margin: auto; border: solid; padding: 1em; background-color: Canvas;'#10 +
    '  color: CanvasText; }'#10 +
    'dialog:modal { position: fixed; overflow: auto; inset-block: 0; max-width: calc(100% - 6px - 2em);'#10 +
    '  max-height: calc(100% - 6px - 2em); }'#10 +
    'dialog::backdrop { background: rgba(0, 0, 0, 0.1); }'#10 +
    '[popover]:not(:popover-open):not(dialog[open]) { display: none; }'#10 +
    'dialog:popover-open { display: block; }'#10 +
    '[popover] { position: fixed; inset: 0; width: fit-content; height: fit-content; margin: auto;'#10 +
    '  border: solid; padding: 0.25em; overflow: auto; color: CanvasText; background-color: Canvas; }'#10 +
    ':popover-open::backdrop { position: fixed; inset: 0; pointer-events: none !important;'#10 +
    '  background-color: transparent; }'#10 +
    'slot { display: contents; }'#10 +
    { 15.3.4 Phrasing content }
    'cite, dfn, em, i, var { font-style: italic; }'#10 +
    'b, strong { font-weight: bolder; }'#10 +
    'code, kbd, samp, tt { font-family: monospace; }'#10 +
    'big { font-size: larger; }'#10 +
    'small { font-size: smaller; }'#10 +
    'sub { vertical-align: sub; }'#10 +
    'sup { vertical-align: super; }'#10 +
    'sub, sup { line-height: normal; font-size: smaller; }'#10 +
    'ruby { display: ruby; }'#10 +
    'rt { display: ruby-text; }'#10 +
    ':link { color: #0000EE; }'#10 +
    ':visited { color: #551A8B; }'#10 +
    ':link:active, :visited:active { color: #FF0000; }'#10 +
    ':link, :visited { text-decoration: underline; cursor: pointer; }'#10 +
    ':focus-visible { outline: auto; }'#10 +
    'mark { background: yellow; color: black; }'#10 +
    'abbr[title], acronym[title] { text-decoration: dotted underline; }'#10 +
    'ins, u { text-decoration: underline; }'#10 +
    'del, s, strike { text-decoration: line-through; }'#10 +
    'q::before { content: open-quote; }'#10 +
    'q::after { content: close-quote; }'#10 +
    'nobr { white-space: nowrap; }'#10 +
    'nobr wbr { white-space: normal; }'#10 +
    { 15.3.5 Bidirectional text }
    '[dir]:dir(ltr), bdi:dir(ltr), input[type=tel i]:dir(ltr) { direction: ltr; }'#10 +
    '[dir]:dir(rtl), bdi:dir(rtl) { direction: rtl; }'#10 +
    'address, blockquote, center, div, figure, figcaption, footer, form, header, hr, legend, listing, main, p,'#10 +
    'plaintext, pre, summary, xmp, article, aside, h1, h2, h3, h4, h5, h6, hgroup, nav, section, search, table,'#10 +
    'caption, colgroup, col, thead, tbody, tfoot, tr, td, th, dir, dd, dl, dt, menu, ol, ul, li, bdi, output,'#10 +
    '[dir=ltr i], [dir=rtl i], [dir=auto i] { unicode-bidi: isolate; }'#10 +
    'bdo, bdo[dir] { unicode-bidi: isolate-override; }'#10 +
    'input[dir=auto i]:is([type=search i], [type=tel i], [type=url i], [type=email i]), textarea[dir=auto i],'#10 +
    'pre[dir=auto i] { unicode-bidi: plaintext; }'#10 +
    { 15.3.6 Sections and headings }
    'article, aside, h1, h2, h3, h4, h5, h6, hgroup, nav, section { display: block; }'#10 +
    'h1 { margin-block: 0.67em; font-size: 2.00em; font-weight: bold; }'#10 +
    'h2 { margin-block: 0.83em; font-size: 1.50em; font-weight: bold; }'#10 +
    'h3 { margin-block: 1.00em; font-size: 1.17em; font-weight: bold; }'#10 +
    'h4 { margin-block: 1.33em; font-size: 1.00em; font-weight: bold; }'#10 +
    'h5 { margin-block: 1.67em; font-size: 0.83em; font-weight: bold; }'#10 +
    'h6 { margin-block: 2.33em; font-size: 0.67em; font-weight: bold; }'#10 +
    { 15.3.7 Lists }
    'dir, dd, dl, dt, menu, ol, ul { display: block; }'#10 +
    'li { display: list-item; text-align: match-parent; }'#10 +
    'dir, dl, menu, ol, ul { margin-block: 1em; }'#10 +
    ':is(dir, dl, menu, ol, ul) :is(dir, dl, menu, ol, ul) { margin-block: 0; }'#10 +
    'dd { margin-inline-start: 40px; }'#10 +
    'dir, menu, ol, ul { padding-inline-start: 40px; }'#10 +
    'ol, ul, menu { counter-reset: list-item; }'#10 +
    'ol { list-style-type: decimal; }'#10 +
    'dir, menu, ul { list-style-type: disc; }'#10 +
    ':is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: circle; }'#10 +
    ':is(dir, menu, ol, ul) :is(dir, menu, ol, ul) :is(dir, menu, ul) { list-style-type: square; }'#10 +
    { 15.3.8 Tables }
    'table { display: table; }'#10 +
    'caption { display: table-caption; }'#10 +
    'colgroup, colgroup[hidden] { display: table-column-group; }'#10 +
    'col, col[hidden] { display: table-column; }'#10 +
    'thead, thead[hidden] { display: table-header-group; }'#10 +
    'tbody, tbody[hidden] { display: table-row-group; }'#10 +
    'tfoot, tfoot[hidden] { display: table-footer-group; }'#10 +
    'tr, tr[hidden] { display: table-row; }'#10 +
    'td, th { display: table-cell; }'#10 +
    'colgroup[hidden], col[hidden], thead[hidden], tbody[hidden], tfoot[hidden], tr[hidden] {'#10 +
    '  visibility: collapse; }'#10 +
    'table { box-sizing: border-box; border-spacing: 2px; border-collapse: separate; text-indent: initial; }'#10 +
    'td, th { padding: 1px; }'#10 +
    'th { font-weight: bold; }'#10 +
    'caption { text-align: center; }'#10 +
    'thead, tbody, tfoot, table > tr { vertical-align: middle; }'#10 +
    'tr, td, th { vertical-align: inherit; }'#10 +
    'thead, tbody, tfoot, tr { border-color: inherit; }'#10 +
    'table[rules=none i], table[rules=groups i], table[rules=rows i], table[rules=cols i], table[rules=all i],'#10 +
    'table[frame=void i], table[frame=above i], table[frame=below i], table[frame=hsides i],'#10 +
    'table[frame=lhs i], table[frame=rhs i], table[frame=vsides i], table[frame=box i], table[frame=border i]'#10 +
    '{ border-style: hidden; }'#10 +
    'table[rules=all i] > tr > td, table[rules=all i] > tr > th, table[rules=all i] > :is(thead, tbody, tfoot)'#10 +
    '  > tr > :is(td, th) { border-width: 1px; border-style: solid; }'#10 +
    'table, td, th { border-color: gray; }'#10 +
    { 15.3.10 Form controls }
    'input, select, button, textarea { letter-spacing: initial; word-spacing: initial; line-height: initial;'#10 +
    '  text-transform: initial; text-indent: initial; text-shadow: initial; appearance: auto; }'#10 +
    'input, select, textarea { text-align: initial; }'#10 +
    'input:is([type=reset i], [type=button i], [type=submit i]), button { text-align: center; }'#10 +
    'input, button { display: inline-block; }'#10 +
    'input[type=hidden i], input[type=file i], input[type=image i] { appearance: none; }'#10 +
    'input:is([type=radio i], [type=checkbox i], [type=reset i], [type=button i], [type=submit i],'#10 +
    '  [type=color i], [type=search i]), select, button { box-sizing: border-box; }'#10 +
    'textarea { white-space: pre-wrap; }'#10 +
    { 15.3.11 The hr element }
    'hr { color: gray; border-style: inset; border-width: 1px; margin-block: 0.5em; margin-inline: auto;'#10 +
    '  overflow: hidden; }'#10 +
    { 15.3.12 The fieldset and legend elements }
    'fieldset { display: block; margin-inline: 2px; border: groove 2px ButtonBorder;'#10 +
    '  padding-block: 0.35em 0.625em; padding-inline: 0.75em; min-inline-size: min-content; }'#10 +
    'legend { padding-inline: 2px; }'#10 +
    { 15.4 Replaced elements }
    'iframe { border: 2px inset; }'#10 +
    'video { object-fit: contain; }'#10 +
    { 15.5 Widgets }
    'details, summary { display: block; }'#10 +
    'details > summary:first-of-type { display: list-item; counter-increment: list-item 0;'#10 +
    '  list-style: disclosure-closed inside; }'#10 +
    'details[open] > summary:first-of-type { list-style-type: disclosure-open; }'#10 +
    'marquee { display: inline-block; text-align: initial; overflow: hidden !important; }'#10 +
    'meter, progress { appearance: auto; }'#10 +
    'select { display: inline-block; }'#10 +
    'textarea { display: inline-block; }'#10;

  QuirksModeCss: PChar =
    '@namespace "http://www.w3.org/1999/xhtml";'#10 +
    'form { margin-block-end: 1em; }'#10 +
    'table { font-weight: initial; font-style: initial; font-variant: initial; font-size: initial;'#10 +
    '  line-height: initial; white-space: initial; text-align: initial; }'#10 +
    'input:not([type=image i]), textarea { box-sizing: border-box; }'#10 +
    'img[align=left i] { margin-right: 3px; }'#10 +
    'img[align=right i] { margin-left: 3px; }'#10;

implementation

uses
  Css.Parser;

var
  UserAgentSheet: TCssStyleSheet = nil;
  QuirksSheet: TCssStyleSheet = nil;

function UserAgentStyleSheet: TCssStyleSheet;
begin
  if UserAgentSheet = nil then
    UserAgentSheet := ParseStyleSheet(string(UserAgentCss), coUserAgent, 'about:user-agent');
  Result := UserAgentSheet;
end;

function QuirksModeStyleSheet: TCssStyleSheet;
begin
  if QuirksSheet = nil then
    QuirksSheet := ParseStyleSheet(string(QuirksModeCss), coUserAgent, 'about:quirks');
  Result := QuirksSheet;
end;

finalization
  UserAgentSheet.Free;
  QuirksSheet.Free;
end.
