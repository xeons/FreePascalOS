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
  Value parsers for SVG's painting properties (SVG 2 13.2 and 13.5,
  CSS Fill and Stroke):

  - <paint>: none | <color> | <url> [none | <color>]? | context-fill |
    context-stroke. A url() with a fallback is a space separated list of
    the two.
  - stroke-dasharray: none | the lengths, percentages and numbers of the
    pattern, separated by commas or white space (or both); a list
    separated by commas.
}
unit Css.SvgParsers;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values;

function ParsePaint(var Cursor: TCssTokenCursor): TCssValue;
function ParseStrokeDasharray(var Cursor: TCssTokenCursor): TCssValue;

implementation

uses
  Css.Keywords, Css.ValueParser, Css.ColorParser;

function ParsePaint(var Cursor: TCssTokenCursor): TCssValue;
var
  Url, Fallback: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone, kwContextFill, kwContextStroke]);
  if Result <> nil then
    Exit;
  Url := ParseUrlValue(Cursor);
  if Url = nil then
    Exit(ParseColor(Cursor));
  Cursor.SkipWhitespace;
  if Cursor.AtEnd then
    Exit(Url);
  Fallback := ParseKeyword(Cursor, [kwNone]);
  if Fallback = nil then
    Fallback := ParseColor(Cursor);
  if Fallback = nil then
  begin
    Url.Release;
    Exit(nil);
  end;
  Result := NewListOf(lsSpace, [Url, Fallback]);
end;

function ParseStrokeDasharray(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsComma);
  repeat
    Cursor.SkipWhitespace;
    if Cursor.AtEnd then
      Break;
    if Cursor.PeekKind = tkComma then
    begin
      Cursor.Next;
      Continue;
    end;
    Item := ParseLengthPercentage(Cursor, True);
    if Item = nil then
      Item := ParseNumber(Cursor, True);
    if Item = nil then
    begin
      Result.Release;
      Exit(nil);
    end;
    Result.Add(Item);
  until False;
  if Result.Count = 0 then
  begin
    Result.Release;
    Result := nil;
  end;
end;

end.
