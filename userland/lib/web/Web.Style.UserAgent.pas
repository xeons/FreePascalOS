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
  The engine's own additions to the HTML user agent style sheet: the
  looks of form controls (which the HTML Standard leaves to the user
  agent), the center element, and the like. A user agent origin sheet,
  after libcss's.
}
unit Web.Style.UserAgent;

{$mode objfpc}
{$H+}

interface

uses
  Css.Stylesheets;

{ The sheet (made once, shared, never freed by callers). }
function EngineUserAgentSheet: TCssStyleSheet;

implementation

uses
  Css.Parser;

const
  EngineUserAgentCss: PChar =
    '@namespace "http://www.w3.org/1999/xhtml";'#10 +
    'center { display: block; text-align: -webkit-center; }'#10 +
    'input, select, textarea, button { font: 13.333px sans-serif; color: FieldText; }'#10 +
    'input, textarea { background-color: Field; border: 2px inset ButtonBorder; padding: 1px 2px; }'#10 +
    'input:is([type=submit i], [type=reset i], [type=button i]), button {'#10 +
    '  background-color: ButtonFace; color: ButtonText; border: 2px outset ButtonBorder; padding: 1px 6px; }'#10 +
    'input:is([type=checkbox i], [type=radio i]) { margin: 3px 3px 3px 4px; padding: 0; border: none;'#10 +
    '  background-color: transparent; }'#10 +
    'input[type=range i] { margin: 2px; padding: 0; border: none; background-color: transparent; }'#10 +
    'select { background-color: ButtonFace; border: 1px solid ButtonBorder; padding: 1px 2px; }'#10 +
    'textarea { overflow: auto; }'#10 +
    'option, optgroup { display: none; }'#10 +
    'fieldset { min-inline-size: auto; }'#10 +
    'summary { cursor: default; }'#10 +
    'img { overflow: clip; }'#10 +
    { The Fullscreen API's rendering: the element fills the viewport,
      above everything (the top layer, by z-index). }
    ':not(:root):fullscreen { position: fixed !important; inset: 0 !important; margin: 0 !important;'#10 +
    '  box-sizing: border-box !important; min-width: 0 !important; max-width: none !important;'#10 +
    '  min-height: 0 !important; max-height: none !important; width: 100% !important; height: 100% !important;'#10 +
    '  transform: none !important; z-index: 2147483647 !important; object-fit: contain; }'#10 +
    'iframe:fullscreen { border: none !important; padding: 0 !important; }'#10 +
    'img:fullscreen, video:fullscreen, canvas:fullscreen { background-color: black; }'#10;

var
  Sheet: TCssStyleSheet = nil;

function EngineUserAgentSheet: TCssStyleSheet;
begin
  if Sheet = nil then
    Sheet := ParseStyleSheet(EngineUserAgentCss, coUserAgent);
  Result := Sheet;
end;

finalization
  Sheet.Free;
end.
