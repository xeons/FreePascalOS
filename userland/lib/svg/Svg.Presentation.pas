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
  SVG's presentation attributes (SVG 2 6.6): attributes such as fill,
  stroke-width or font-size that set the CSS property of the same name,
  below every author rule (specificity 0). Both libsvg's styling and
  libweb's (for SVG elements in HTML) turn them into declarations with
  PresentationDeclaration.

  Their values are CSS values, except that lengths may leave out the
  unit (font-size="12" is 12px), as attributes always could.

  transform is left to the elements (the attribute's own syntax, and
  SVG's transform-origin), as are the geometry attributes (x, y, width,
  r, d ...), which libsvg reads itself.
}
unit Svg.Presentation;

{$mode objfpc}
{$H+}

interface

{ "name:value;" for a presentation attribute, '' for any other. }
function PresentationDeclaration(const Name, Value: string): string;
function IsPresentationAttribute(const Name: string): Boolean;

implementation

uses
  SysUtils;

const
  PresentationNames: array[0..47] of string = ('alignment-baseline', 'baseline-shift', 'clip-path', 'clip-rule',
    'color', 'color-interpolation', 'color-interpolation-filters', 'color-rendering', 'cursor', 'direction',
    'display', 'dominant-baseline', 'fill', 'fill-opacity', 'fill-rule', 'filter', 'flood-color', 'flood-opacity',
    'font-family', 'font-size', 'font-size-adjust', 'font-stretch', 'font-style', 'font-variant', 'font-weight',
    'image-rendering', 'letter-spacing', 'lighting-color', 'marker-end', 'marker-mid', 'marker-start', 'mask',
    'opacity', 'overflow', 'paint-order', 'pointer-events', 'shape-rendering', 'stop-color', 'stop-opacity',
    'stroke', 'stroke-dasharray', 'stroke-dashoffset', 'stroke-linecap', 'stroke-linejoin', 'stroke-miterlimit',
    'stroke-opacity', 'stroke-width', 'text-anchor');
  MorePresentationNames: array[0..6] of string = ('text-decoration', 'text-rendering', 'unicode-bidi',
    'vector-effect', 'visibility', 'word-spacing', 'writing-mode');
  { Properties whose attribute may be a bare number of pixels. }
  LengthNames: array[0..5] of string = ('font-size', 'letter-spacing', 'word-spacing', 'baseline-shift',
    'stroke-width', 'stroke-dashoffset');

function InList(const Name: string; const List: array of string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if List[Index] = Name then
      Exit(True);
  Result := False;
end;

function IsPresentationAttribute(const Name: string): Boolean;
begin
  Result := InList(Name, PresentationNames) or InList(Name, MorePresentationNames);
end;

function IsBareNumber(const Text: string): Boolean;
var
  Index: Integer;
  Digits: Boolean;
begin
  Digits := False;
  for Index := 1 to Length(Text) do
    case Text[Index] of
      '0'..'9': Digits := True;
      '+', '-':
        if Index <> 1 then
          Exit(False);
      '.', 'e', 'E': ;
      else
        Exit(False);
    end;
  Result := Digits;
end;

function PresentationDeclaration(const Name, Value: string): string;
var
  Text: string;
begin
  Result := '';
  if not IsPresentationAttribute(Name) then
    Exit;
  Text := Trim(Value);
  if Text = '' then
    Exit;
  { A semicolon or brace would reach past the declaration. }
  if (Pos(';', Text) > 0) or (Pos('{', Text) > 0) or (Pos('}', Text) > 0) then
    Exit;
  if InList(Name, LengthNames) and IsBareNumber(Text) then
    Text := Text + 'px';
  Result := Name + ':' + Text + ';';
end;

end.
